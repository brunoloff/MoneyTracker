import copy
import datetime as dt
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import urlparse, parse_qs
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
import store


class HistoryTests(unittest.TestCase):
    def test_year_validation_and_leap_date(self):
        self.assertEqual(store.history_start(1, dt.date(2024, 2, 29)), dt.date(2023, 2, 28))
        for value in (None, True, 0, 21, '2'):
            with self.assertRaises(ValueError): store.history_start(value)

    def setUp(self):
        self.account = {'uid': 'bank-uid', 'identification_hash': 'stable', 'account_id': {'iban': 'XX1234'}}
        self.account_id = store.stable_account_id(self.account)
        self.raw = {'entry_reference': 'new', 'transaction_amount': {'amount': '12.34', 'currency': 'EUR'}, 'credit_debit_indicator': 'DBIT', 'transaction_date': dt.date.today().isoformat(), 'remittance_information': ['Shop'], 'status': 'BOOK'}
        old = store.normalize({**self.raw, 'entry_reference': 'old'}, self.account_id)
        self.saved = {'session.json': {'accounts': [self.account]}, 'ledger.json': {'transactions': [old], 'historyFrom': '2020-01-01'}}
        self.read = patch.object(store, 'read', side_effect=lambda name, default: copy.deepcopy(self.saved.get(name, default)))
        self.write = patch.object(store, 'write', side_effect=lambda name, value: self.saved.__setitem__(name, copy.deepcopy(value)))
        self.read.start(); self.write.start()
        self.addCleanup(self.read.stop); self.addCleanup(self.write.stop)

    def test_pages_empty_continuation_and_repeat_import_no_duplicates(self):
        requests = []
        def api(path):
            if path.endswith('/balances'): return {'balances': []}
            query = parse_qs(urlparse(path).query)
            requests.append(query)
            if 'continuation_key' not in query: return {'transactions': [], 'continuation_key': 'page2'}
            return {'transactions': [self.raw], 'continuation_key': None}
        with patch.object(store, 'api', side_effect=api):
            store.sync(years=2)
            self.assertEqual(len(self.saved['ledger.json']['transactions']), 2)
            self.assertEqual(self.saved['ledger.json']['historyImport']['added'], 1)
            self.assertEqual(requests[0]['strategy'], ['longest'])
            self.assertEqual(requests[0]['date_from'], requests[1]['date_from'])
            store.sync(years=2)
            self.assertEqual(len(self.saved['ledger.json']['transactions']), 2)
            self.assertEqual(self.saved['ledger.json']['historyImport']['added'], 0)
            self.assertEqual(self.saved['ledger.json']['historyFrom'], '2020-01-01')

    def test_failure_preserves_ledger(self):
        original = copy.deepcopy(self.saved['ledger.json'])
        with patch.object(store, 'api', side_effect=RuntimeError('Bank unavailable')):
            with self.assertRaises(RuntimeError): store.sync(years=1)
        self.assertEqual(self.saved['ledger.json'], original)

    def test_regular_sync_keeps_booked_history_when_bank_returns_nothing(self):
        with patch.object(store, 'api', side_effect=lambda p: {'balances': []} if p.endswith('/balances') else {'transactions': []}):
            store.sync()
        self.assertEqual(len(self.saved['ledger.json']['transactions']), 1)
        self.assertEqual(self.saved['ledger.json']['historyFrom'], '2020-01-01')
