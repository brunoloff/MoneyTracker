import datetime as dt
import http.client
import ssl
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch
from cryptography import x509
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
import bank_callback
import connections
import store


class CallbackTests(unittest.TestCase):
    def test_https_callback_connects_once_redirects_and_reports_completion(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(store, 'PRIVATE', Path(directory)):
            store.write('connection-pending.json', {
                'state': 'expected', 'attempt': 'test-attempt', 'created': time.time(),
                'aspsp': {'name': 'Bankinter', 'country': 'PT'}})
            app = SimpleNamespace(server_port=8765, touch=Mock())
            server = bank_callback.start(app, port=0)
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            cert = Path(directory) / 'callback-cert.pem'
            context = ssl.create_default_context(cafile=str(cert))
            def get(path, host=None):
                client = http.client.HTTPSConnection('localhost', server.server_port, context=context, timeout=5)
                try:
                    client.request('GET', path, headers={'Host': host} if host else {})
                    response = client.getresponse()
                    result = response.status, dict(response.getheaders()), response.read()
                    return result
                finally:
                    client.close()
            session = {'session_id': 'new', 'aspsp': {'name': 'Bankinter', 'country': 'PT'},
                       'accounts': [{'uid': 'one', 'identification_hash': 'stable', 'account_id': {'iban': 'PT1234'}}]}
            with patch.object(store, 'api', return_value=session) as api:
                self.assertEqual(get('/callback?state=wrong&code=x')[0], 400)
                self.assertEqual(get('/callback?state=expected&code=x', 'evil.test')[0], 403)
                api.assert_not_called()
                status, headers, _ = get('/callback?state=expected&code=single-use')
                self.assertEqual(status, 303)
                self.assertEqual(headers['Location'], 'http://localhost:8765/')
                self.assertEqual(headers['Referrer-Policy'], 'no-referrer')
                self.assertEqual(headers['Cache-Control'], 'no-store')
                api.assert_called_once_with('/sessions', {'code': 'single-use'})
                self.assertEqual(get('/callback?state=expected&code=single-use')[0], 400)
                api.assert_called_once()
            self.assertEqual(connections.authorization_status('test-attempt')['status'], 'complete')
            self.assertEqual(len(store.read('ledger.json', {})['accounts']), 1)
            self.assertEqual(connections.authorization_status('different-attempt')['status'], 'error')
            self.assertEqual((Path(directory) / 'callback-key.pem').stat().st_mode & 0o777, 0o600)

    def test_certificate_reused_and_expired_authorization_is_reported(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(store, 'PRIVATE', Path(directory)):
            root = Path(directory)
            bank_callback.tls_context(root)
            original = (root / 'callback-cert.pem').read_bytes()
            bank_callback.tls_context(root)
            self.assertEqual((root / 'callback-cert.pem').read_bytes(), original)
            names = x509.load_pem_x509_certificate(original).extensions.get_extension_for_class(x509.SubjectAlternativeName).value
            self.assertIn('localhost', names.get_values_for_type(x509.DNSName))
            store.write('connection-pending.json', {'state': 'expected', 'attempt': 'old', 'created': 0})
            with patch.object(store, 'api') as api:
                with self.assertRaises(ValueError):
                    connections.complete_callback('https://localhost:8443/callback?state=expected&code=x')
                api.assert_not_called()
            self.assertEqual(connections.authorization_status('old')['status'], 'error')
