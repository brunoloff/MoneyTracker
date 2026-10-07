import copy
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
import rules
import store


def condition(value, field='description', operator='contains'):
    return {'field': field, 'operator': operator, 'value': value}


def rule(groups, **kw):
    return rules.validate({'name': 'Groceries', 'category': 'Food', 'groups': groups, **kw}, store.CATEGORIES)


class RulesTests(unittest.TestCase):
    def test_or_and_and_case_insensitive_operators(self):
        r = rule([[condition('pingo', operator='starts_with'), condition('cafe', operator='not_contains')], [condition('market', operator='ends_with')]])
        self.assertTrue(rules.matches(r, {'description': 'PINGO DOCE', 'amount': -100}))
        self.assertFalse(rules.matches(r, {'description': 'PINGO CAFE', 'amount': -100}))
        self.assertTrue(rules.matches(r, {'description': 'Supermarket', 'amount': -100}))
        self.assertFalse(rules.matches(r, {'description': 'marketplace', 'amount': -100}))

    def test_and_conditions_must_match_same_source(self):
        r = rule([[condition('book'), condition('PayPal', field='source', operator='equals')]])
        p = {'amount': -100, 'sourceRecords': [{'description': 'book', 'institution': 'CGD'}, {'description': 'purchase', 'institution': 'PayPal'}]}
        self.assertFalse(rules.matches(r, p))
        p['sourceRecords'][1]['description'] = 'Book order'
        self.assertTrue(rules.matches(r, p))

    def test_reject_empty_or_unknown_conditions(self):
        for groups in ([], [[]], [[condition('')]], [[condition('x', operator='regex')]]):
            with self.assertRaises(ValueError): rule(groups)

    def test_salary_only_income_and_disabled_rules(self):
        r = rule([[condition('salary')]], category='Salary')
        self.assertFalse(rules.matches(r, {'amount': -100, 'description': 'salary'}))
        self.assertTrue(rules.matches(r, {'amount': 100, 'description': 'salary'}))
        r['enabled'] = False
        self.assertFalse(rules.matches(r, {'amount': 100, 'description': 'salary'}))

    def test_precedence_manual_and_rule_deletion_reverts(self):
        row = {'id': 'one', 'accountId': 'a', 'date': '2026-09-01', 'amount': -100, 'currency': 'EUR', 'source': 'CGD', 'description': 'Book shop', 'category': 'Other', 'status': 'BOOK', 'reviewed': False}
        first = rule([[condition('book')]], category='Shopping')
        second = rule([[condition('shop')]], category='Entertainment')
        saved = {'ledger.json': {'transactions': [row]}, 'rules.json': [first, second]}
        with patch.object(store, 'read', side_effect=lambda n, d: copy.deepcopy(saved.get(n, d))):
            p = store.snapshot()['transactions'][0]
            self.assertEqual(p['category'], 'Shopping')
            self.assertEqual(p['classificationRule']['id'], first['id'])
            saved['categories.json'] = {'one': 'Bills'}
            self.assertEqual(store.snapshot()['transactions'][0]['category'], 'Bills')
            saved['categories.json'] = {}
            saved['rules.json'] = []
            self.assertEqual(store.snapshot()['transactions'][0]['category'], 'Other')

class CategoryRuleTests(unittest.TestCase):
    def test_consolidate_dnf_without_losing_and_or_disabled_rules(self):
        a = rule([[condition('shop'), condition('PayPal', field='source')]], id='a')
        b = rule([[condition('market')]], id='b')
        disabled = rule([[condition('paused')]], id='paused', enabled=False)
        other = rule([[condition('exception')]], id='other', category='Shopping')
        draft = rules.category_draft('Food', 'Food', [a, other, b, disabled])
        saved = rules.save_category([a, other, b, disabled], draft)
        self.assertEqual([r['id'] for r in saved], ['a', 'other', 'paused'])
        self.assertEqual(saved[0]['groups'], a['groups'] + b['groups'])
        self.assertFalse(rules.matches(saved[0], {'description': 'shop', 'source': 'CGD', 'amount': -100}))
        self.assertTrue(rules.matches(saved[0], {'description': 'market', 'amount': -100}))
        self.assertFalse(saved[-1]['enabled'])

    def test_category_deletion_merges_destination_dnf_and_preserves_paused_terms(self):
        source = rule([[condition('book')]], id='source', category='Shopping')
        dest = rule([[condition('shop'), condition('CGD', field='source')]], id='dest')
        paused = rule([[condition('paused')]], id='paused', category='Shopping', enabled=False)
        result = rules.transfer_categories([dest, source, paused], {'Shopping': 'Food'}, {'Food': 'Meals'})
        active = [r for r in result if r.get('enabled', True)]
        self.assertEqual(len(active), 1)
        self.assertEqual(active[0]['groups'], dest['groups'] + source['groups'])
        self.assertEqual(active[0]['name'], 'Meals')
        self.assertEqual(result[-1]['category'], 'Food')
        self.assertFalse(result[-1]['enabled'])

    def test_empty_category_rule_matches_nothing_and_large_dnf_can_be_saved(self):
        empty = rule([], kind='category')
        self.assertFalse(rules.matches(empty, {'description': 'Anything', 'amount': -100}))
        large = rule([[condition(str(i))] for i in range(30)], kind='category')
        self.assertEqual(len(large['groups']), 30)

    def test_tag_rules_run_after_category_matches_and_manual_override(self):
        row = {'id': 'one', 'accountId': 'a', 'date': '2026-09-01', 'amount': -100, 'currency': 'EUR', 'source': 'CGD', 'description': 'Book shop', 'category': 'Other', 'status': 'BOOK'}
        classifier = rule([[condition('book')]], category='Shopping')
        tagger = rules.validate({'name': 'Work', 'category': None, 'tags': ['work'], 'groups': [[condition('book')]]}, store.CATEGORIES, ['work'])
        saved = {'ledger.json': {'transactions': [row]}, 'rules.json': [classifier, tagger], 'categories.json': {'one': 'Food'}}
        with patch.object(store, 'read', side_effect=lambda n, d: copy.deepcopy(saved.get(n, d))):
            result = store.snapshot()['transactions'][0]
        self.assertEqual(result['category'], 'Food')
        self.assertEqual(result['tags'], ['work'])

    def test_category_transfer_dnf_and_transactions_undo_together(self):
        import tempfile
        import taxonomy
        import undo
        with tempfile.TemporaryDirectory() as directory, patch.object(store, 'PRIVATE', Path(directory)):
            before = [rule([[condition('food')]], id='food'), rule([[condition('books')]], id='books', category='Shopping')]
            with undo.action(Path(directory), 'Fixture'):
                store.write('taxonomy.json', taxonomy.defaults())
                store.write('rules.json', before)
                store.write('ledger.json', {'transactions': []})
            config = taxonomy.defaults()
            config['categories'] = [c for c in config['categories'] if c['id'] != 'Shopping']
            config['categoryTransfers'] = {'Shopping': 'Food'}
            store.save_taxonomy(config)
            merged = store.read('rules.json', [])
            self.assertEqual(len(merged), 1)
            self.assertEqual(merged[0]['groups'], before[0]['groups'] + before[1]['groups'])
            undo.restore(Path(directory))
            self.assertEqual(store.read('rules.json', []), before)
            self.assertIn('Shopping', store.category_ids())
