"""Exercise response serialization without opening a server or private ledger."""
import importlib.util
import io
import gzip
import json
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


class ResponseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fake_store = types.ModuleType('store')
        fake_store.read = lambda *args: {'token': 'test-token'}
        fake_store.write = lambda *args: None
        path = Path(__file__).resolve().parents[1] / 'server/main.py'
        spec = importlib.util.spec_from_file_location('response_test_server', path)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {'store': fake_store}):
            spec.loader.exec_module(module)
        cls.handler_type = module.Handler

    def handler(self):
        handler = object.__new__(self.handler_type)
        handler.wfile = io.BytesIO()
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock()
        return handler

    def test_static_json_is_sent_unchanged(self):
        handler = self.handler()
        data = b'[{"family":"MoneySans","fonts":[]}]'
        handler.send(200, data, 'application/json')
        self.assertEqual(handler.wfile.getvalue(), data)
        handler.send_header.assert_any_call('Content-Length', str(len(data)))

    def test_api_object_is_encoded_as_json(self):
        handler = self.handler()
        handler.send(200, {'ok': True})
        self.assertEqual(handler.wfile.getvalue(), b'{"ok": true}')

    def test_binary_asset_is_sent_unchanged(self):
        handler = self.handler()
        data = b'\x00asm\x01\x00\x00\x00'
        handler.send(200, data, 'application/wasm')
        self.assertEqual(handler.wfile.getvalue(), data)

    def test_large_json_gzip_round_trip_and_opt_out(self):
        data = {'transactions': [{'description': 'Example payment'}] * 1000}
        handler = self.handler()
        handler.headers = {'Accept-Encoding': 'gzip, deflate'}
        handler.send(200, data)
        compressed = handler.wfile.getvalue()
        self.assertEqual(json.loads(gzip.decompress(compressed)), data)
        self.assertLess(len(compressed), len(json.dumps(data)) // 5)
        handler.send_header.assert_any_call('Content-Encoding', 'gzip')
        handler = self.handler()
        handler.headers = {'Accept-Encoding': 'gzip;q=0'}
        handler.send(200, data)
        self.assertEqual(json.loads(handler.wfile.getvalue()), data)
