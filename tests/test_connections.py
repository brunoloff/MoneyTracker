import copy
import datetime as dt
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
import store
import connections
import undo


class ConnectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.private = patch.object(store, 'PRIVATE', self.root)
        self.private.start()
        self.addCleanup(self.private.stop)
        self.account = {'uid': 'old', 'identification_hash': 'one', 'account_id': {'iban': 'PT1234'}, 'cash_account_type': 'CACC'}
        self.cgd = {'session_id': 'cgd', 'aspsp': {'name': 'Caixa Geral de Depósitos', 'country': 'PT'}, 'accounts': [self.account]}
        store.write('session.json', self.cgd)
        self.old_id = store.stable_account_id(self.account)
        store.write('ledger.json', {'accounts': [{'id': self.old_id, 'source': 'CGD', 'label': 'Old'}], 'transactions': []})
        store.write('profiles.json', {'users': [{'id': 'bruno', 'name': 'Bruno'}], 'accountUsers': {self.old_id: 'bruno'}})

    def pending(self):
        store.write('connection-pending.json', {'state': 'expected', 'created': time.time(),
                    'aspsp': {'name': 'Bankinter', 'country': 'PT'}})

    def bankinter(self):
        return {'session_id': 'new-session', 'aspsp': {'name': 'Bankinter', 'country': 'PT'},
                'accounts': [{**self.account, 'uid': 'new', 'identification_hash': 'two'}]}

    def test_authorize_bankinter_preserves_accounts_ownership_and_supports_undo(self):
        self.pending()
        with patch.object(store, 'api', return_value=self.bankinter()) as api:
            with undo.action(self.root, 'Connect bank account'):
                result = connections.finish('https://localhost:8443/callback?state=expected&code=single-use')
            api.assert_called_once_with('/sessions', {'code': 'single-use'})
        self.assertEqual(result['added'], 1)
        self.assertEqual(len(store.read('ledger.json', {})['accounts']), 2)
        self.assertEqual(store.read('profiles.json', {})['accountUsers'], {self.old_id: 'bruno'})
        self.assertEqual(len(connections.bank_sessions()), 2)
        undo.restore(self.root)
        self.assertEqual(len(store.read('ledger.json', {})['accounts']), 1)
        # Undo local metadata never revokes bank consent or restores authorization codes.
        self.assertEqual(store.read('connection-pending.json', {}), {})

    def test_callback_validation_never_exchanges_wrong_state_host_or_expired_code(self):
        self.pending()
        with patch.object(store, 'api') as api:
            for url in ['https://evil.test/callback?state=expected&code=x',
                        'https://localhost:8443/callback?state=wrong&code=x',
                        'https://localhost:8443/callback?state=expected&error=denied']:
                with self.assertRaises(ValueError): connections.finish(url)
            store.write('connection-pending.json', {'created': 0, 'state': 'expected'})
            with self.assertRaises(ValueError): connections.finish('https://localhost:8443/callback?state=expected&code=x')
            api.assert_not_called()

    def test_start_uses_personal_pt_bank_and_90_day_maximum(self):
        def api(path, body=None):
            if path.startswith('/aspsps'):
                return {'aspsps': [{'name': 'Bankinter', 'country': 'PT', 'maximum_consent_validity': 86400 * 180}]}
            if path == '/application':
                return {'redirect_urls': ['https://localhost:8443/callback']}
            self.assertEqual(body['aspsp'], {'name': 'Bankinter', 'country': 'PT'})
            self.assertEqual(body['psu_type'], 'personal')
            days = (dt.datetime.fromisoformat(body['access']['valid_until']) - dt.datetime.now(dt.timezone.utc)).total_seconds()/86400
            self.assertAlmostEqual(days, 90, places=3)
            return {'url': 'https://auth.enablebanking.com/example'}
        with patch.object(store, 'api', side_effect=api):
            self.assertIn('url', connections.start({'name': 'Bankinter', 'country': 'PT'}))

    def test_refresh_adds_new_accounts_without_transactions_and_preserves_metadata(self):
        def api(path):
            if path.startswith('/sessions/'):
                return {'status': 'AUTHORIZED', 'accounts_data': [
                    {'uid': 'old', 'identification_hash': 'one'},
                    {'uid': 'extra', 'identification_hash': 'extra'}]}
            return {**self.account, 'uid': 'extra', 'identification_hash': 'extra'}
        with patch.object(store, 'api', side_effect=api) as api:
            result = connections.refresh()
        self.assertEqual(result['added'], 1)
        self.assertEqual(store.read('session.json', {})['accounts'][0]['account_id'], {'iban': 'PT1234'})
        self.assertEqual(store.read('ledger.json', {})['transactions'], [])
        self.assertFalse(any('/transactions' in c.args[0] for c in api.call_args_list))
        with patch.object(store, 'api', side_effect=api.side_effect):
            self.assertEqual(connections.refresh()['added'], 0)

    def test_bankinter_sync_and_reauthorization_keep_stable_identity(self):
        saved = self.bankinter()
        store.write('bank-sessions.json', [saved, {**saved, 'accounts': [{**saved['accounts'][0], 'uid': 'renewed'}]}])
        bank_id = store.stable_account_id(saved['accounts'][0], 'Bankinter')
        raw = {'entry_reference': 'purchase', 'transaction_amount': {'amount': '12.34', 'currency': 'EUR'},
               'credit_debit_indicator': 'DBIT', 'transaction_date': dt.date.today().isoformat(),
               'remittance_information': ['Shop'], 'status': 'BOOK'}
        def api(path):
            self.assertIn('/accounts/renewed/', path)
            return {'balances': []} if path.endswith('/balances') else {'transactions': [raw]}
        with patch.object(store, 'api', side_effect=api):
            store.sync(account_id_filter=bank_id)
        row = store.read('ledger.json', {})['transactions'][0]
        self.assertEqual(row['source'], 'Bankinter')
        self.assertEqual(row['sourceRecord']['institution'], 'Bankinter')
        self.assertEqual(len(store.read('ledger.json', {})['accounts']), 2)
