import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from import_cgd_xlsx import money, parse_rows, plan


class CgdImportTests(unittest.TestCase):
    def setUp(self):
        self.rows = [
            ['CGD'], [], ['Conta', '123 - EUR - Conta à ordem'],
            ['Data de início', '01-01-2024'], ['Data de fim', '31-01-2024'], [],
            ['Data mov.', 'Data valor', 'Descrição', 'Débito', 'Crédito',
             'Saldo contabilístico', 'Saldo disponível', 'Categoria'],
            ['03-01-2024', '02-01-2024', 'Shop ', '1,00', None, '98,00', '98,00', 'COMPRAS'],
            ['02-01-2024', '02-01-2024', 'Shop ', '1,00', None, '99,00', '99,00', 'COMPRAS'],
            ['02-01-2024', '02-01-2024', 'Shop ', '1,00', None, '100,00', '100,00', 'COMPRAS'],
            [' ', ' ', ' ', ' ', 'Saldo contabilístico', '98,00 EUR', ' ', ' '],
        ]
        self.ledger = {'accounts': [{'id': 'a', 'source': 'CGD', 'kind': 'CACC', 'balance': 9800}],
                       'transactions': [{'id': 'original', 'accountId': 'a', 'date': '2024-01-02',
                                         'bookingDate': '2024-01-03', 'amount': -100,
                                         'description': 'Shop', 'status': 'BOOK', 'category': 'Food'}]}

    def test_currency_is_exact_and_rejects_malformed_values(self):
        self.assertEqual(money('25.247,67'), 2524767)
        self.assertEqual(money('-1,23'), -123)
        self.assertEqual(money(1.23), 123)
        for value in ('1,234', '1.23,45', 'NaN', float('inf')):
            with self.assertRaises(ValueError): money(value)

    def test_validates_balance_chain_footer_and_debit_credit(self):
        self.assertEqual(len(parse_rows(self.rows)), 3)
        for row, column, value in [(8, 5, '90,00'), (10, 5, '99,00 EUR'), (8, 4, '2,00'), (8, 0, '02-02-2024')]:
            rows = copy.deepcopy(self.rows)
            rows[row][column] = value
            with self.assertRaises(ValueError): parse_rows(rows)

    def test_preserves_existing_and_identical_purchases_and_is_idempotent(self):
        before = copy.deepcopy(self.ledger)
        rows = parse_rows(self.rows)
        after, report = plan(self.ledger, rows, 'a', {'sourceFile': 'test.xlsx'})
        self.assertEqual((report['added'], report['matched']), (2, 1))
        self.assertEqual(self.ledger, before)
        self.assertIn(before['transactions'][0], after['transactions'])
        self.assertEqual(after['accounts'], before['accounts'])
        repeated, report = plan(after, rows, 'a', {'sourceFile': 'renamed.xlsx'})
        self.assertEqual(report['added'], 0)
        self.assertEqual(repeated, after)

    def test_unmatched_overlap_or_wrong_account_refused(self):
        rows = parse_rows(self.rows)
        rows[0]['description'] = 'Different'
        with self.assertRaises(ValueError): plan(self.ledger, rows, 'a', {})
        rows = parse_rows(self.rows)[1:]
        with self.assertRaises(ValueError): plan(self.ledger, rows, 'a', {})


if __name__ == '__main__':
    unittest.main()
