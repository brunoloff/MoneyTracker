import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
from reconciliation import suggest_matches

class ReconciliationTests(unittest.TestCase):
    def setUp(self):
        self.paypal = {'id': 'pp', 'date': '2026-09-01', 'amount': -1234, 'currency': 'EUR', 'status': 'BOOK', 'kind': 'purchase'}
        self.bank = {'id': 'bank', 'accountId': 'mine', 'date': '2026-09-03', 'amount': -1234, 'currency': 'EUR', 'status': 'BOOK', 'description': 'PAYPAL SHOP'}
    def match(self, **changes):
        return suggest_matches([self.paypal], [{**self.bank, **changes}], ['mine'])[0]
    def test_posting_delay_with_explanation(self):
        match = self.match()['candidates'][0]
        self.assertEqual(match['dayOffset'], 2)
        self.assertTrue(match['paypalMention'])
        self.assertTrue(self.match()['requiresReview'])
    def test_booking_date_also_considered(self):
        self.assertEqual(self.match(date='2026-10-01', bookingDate='2026-09-02')['candidates'][0]['dayOffset'], 1)
    def test_wrong_owner_sign_currency_status_or_date_never_matches(self):
        for change in [{'accountId': 'someone-else'}, {'amount': 1234}, {'amount': -1235}, {'currency': 'USD'}, {'status': 'PDNG'}, {'date': '2026-10-01'}]:
            self.assertEqual(self.match(**change)['candidates'], [])
    def test_ambiguous_repeated_amounts_and_competing_purchases(self):
        rows = suggest_matches([self.paypal, {**self.paypal, 'id': 'pp2'}], [self.bank], ['mine'])
        self.assertTrue(all(r['ambiguous'] for r in rows))
        self.assertEqual(rows[0]['candidates'][0]['competingObservations'], 2)
        row = suggest_matches([self.paypal], [self.bank, {**self.bank, 'id': 'bank2'}], ['mine'])[0]
        self.assertTrue(row['ambiguous'])
    def test_no_duplicate_link_or_funding_transaction_match(self):
        self.assertEqual(self.match(sourceRecords=[{'institution': 'PayPal'}])['candidates'], [])
        self.paypal['kind'] = 'funding'
        self.assertEqual(self.match()['candidates'], [])
    def test_window_validation(self):
        for days in [-1, 32, True]:
            with self.assertRaises(ValueError): suggest_matches([], [], [], days)
