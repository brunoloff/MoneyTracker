import copy
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
import taxonomy
import store
import rules

class TaxonomyTests(unittest.TestCase):
    def config(self):
        value = taxonomy.defaults()
        value['categories'].append({'id': 'groceries', 'name': 'Groceries', 'parent': 'Food', 'color': '00A5AA'})
        value['tags'] = [{'id': 'holiday', 'name': 'Holiday'}]
        return value

    def test_rename_preserves_identity_and_subcategory(self):
        config = self.config()
        config['categories'][0]['name'] = 'Meals'
        self.assertEqual(taxonomy.validate(config)['categories'][-1]['parent'], 'Food')
        self.assertEqual(taxonomy.validate(config)['categories'][0]['id'], 'Food')

    def test_reject_cycles_deep_hierarchies_and_deleting_used_labels(self):
        config = self.config()
        config['categories'][-1]['parent'] = 'groceries'
        with self.assertRaises(ValueError): taxonomy.validate(config)
        config = self.config()
        config['categories'].append({'id': 'deep', 'name': 'Deep', 'parent': 'groceries', 'color': '00A5AA'})
        with self.assertRaises(ValueError): taxonomy.validate(config)
        with self.assertRaises(ValueError): taxonomy.validate(taxonomy.defaults(), used_categories={'groceries'})
        with self.assertRaises(ValueError): taxonomy.validate(taxonomy.defaults(), used_tags={'holiday'})

    def test_any_linked_description_can_match_the_same_rule(self):
        rule = rules.validate({'name': 'Books', 'category': 'Shopping', 'groups': [[{'field': 'description', 'operator': 'contains', 'value': 'book'}]]}, store.CATEGORIES)
        bank = {'description': 'CARD 123', 'institution': 'CGD'}
        paypal = {'description': 'Book purchase', 'institution': 'PayPal'}
        self.assertTrue(rules.matches(rule, {'amount': -100, 'sourceRecords': [bank, paypal]}))
        self.assertTrue(rules.matches(rule, {'amount': -100, 'sourceRecords': [paypal, bank]}))
        self.assertFalse(rules.matches(rule, {'amount': -100, 'sourceRecords': [bank]}))

    def test_salary_subcategory_cannot_classify_outgoing_payment(self):
        rule = {'category': 'pay', 'groups': [[{'field': 'description', 'operator': 'contains', 'value': 'employer'}]]}
        self.assertFalse(store.rule_matches(rule, {'amount': -100, 'description': 'employer'}, {'pay': 'Salary'}))

    def test_merged_tags_are_combined_without_modifying_observations(self):
        rows = [{'id': identity, 'accountId': identity, 'description': 'Purchase', 'date': '2026-09-01', 'amount': -100, 'currency': 'EUR', 'source': 'CGD', 'status': 'BOOK', 'category': 'Other'} for identity in ['a', 'b']]
        saved = {'ledger.json': {'transactions': rows}, 'merges.json': {'a': ['b']}, 'tags.json': {'a': ['one'], 'b': ['two', 'one']}}
        with patch.object(store, 'read', side_effect=lambda name, default: copy.deepcopy(saved.get(name, default))):
            payment = store.snapshot()['transactions'][0]
        self.assertEqual(payment['tags'], ['one', 'two'])
        self.assertEqual(len(rows), 2)


class UncategorizedTests(unittest.TestCase):
    def test_protected_definition(self):
        for field, value in [('name', 'Unknown'), ('color', '000000'), ('parent', 'Other')]:
            config = taxonomy.defaults()
            next(c for c in config['categories'] if c['id'] == 'Uncategorized')[field] = value
            with self.assertRaises(ValueError): taxonomy.validate(config)
        config = taxonomy.defaults()
        config['categories'] = [c for c in config['categories'] if c['id'] != 'Uncategorized']
        with self.assertRaises(ValueError): taxonomy.validate(config)
        config = taxonomy.defaults()
        config['categories'].append({'id': 'child', 'name': 'Child', 'parent': 'Uncategorized', 'color': '93A0B4'})
        with self.assertRaises(ValueError): taxonomy.validate(config)

    def test_unmatched_expense_defaults_to_uncategorized(self):
        self.assertEqual(store.suggest('Unknown merchant', -123), 'Uncategorized')
        self.assertIn('Other', store.category_ids())

class CategoryDeletionTests(unittest.TestCase):
    def test_delete_moves_all_assignments_and_undo_restores_them(self):
        import tempfile
        import undo
        with tempfile.TemporaryDirectory() as directory, patch.object(store, 'PRIVATE', Path(directory)):
            original = taxonomy.defaults()
            with undo.action(Path(directory), 'Fixture'):
                store.write('taxonomy.json', original)
                store.write('ledger.json', {'transactions': [{'id': 'a', 'category': 'Food', 'amount': -100, 'date': '2026-09-01', 'accountId': 'one', 'description': 'LIDL', 'currency': 'EUR', 'source': 'CGD', 'status': 'BOOK'}]})
                store.write('categories.json', {'a': 'Food'})
                store.write('rules.json', [{'id': 'rule', 'name': 'Food rule', 'category': 'Food', 'groups': []}])
            config = copy.deepcopy(original)
            config['categories'] = [c for c in config['categories'] if c['id'] != 'Food']
            config['categoryTransfers'] = {'Food': 'Other'}
            store.save_taxonomy(config)
            self.assertEqual(store.read('ledger.json', {})['transactions'][0]['category'], 'Other')
            self.assertEqual(store.read('categories.json', {}), {'a': 'Other'})
            self.assertEqual(store.read('rules.json', []), [{'id': 'rule', 'name': 'Other', 'category': 'Other', 'kind': 'category', 'enabled': True, 'groups': []}])
            self.assertEqual(store.suggest('LIDL', -100), 'Uncategorized')
            undo.restore(Path(directory))
            self.assertEqual(store.read('taxonomy.json', {}), original)
            self.assertEqual(store.read('categories.json', {}), {'a': 'Food'})
            self.assertEqual(store.read('rules.json', []), [{'id': 'rule', 'name': 'Food rule', 'category': 'Food', 'groups': []}])
            self.assertEqual(store.read('ledger.json', {})['transactions'][0]['category'], 'Food')

    def test_requires_destination_and_rejects_parent_with_children(self):
        config = TaxonomyTests().config()
        with patch.object(store, 'classification_settings', return_value=config), patch.object(store, 'write') as write:
            changed = copy.deepcopy(config)
            changed['categories'] = [c for c in changed['categories'] if c['id'] != 'Food']
            with self.assertRaises(ValueError): store.save_taxonomy(changed)
            changed['categoryTransfers'] = {'Food': 'Other'}
            with self.assertRaises(ValueError): store.save_taxonomy(changed)
            changed['categoryTransfers'] = {'Food': 'nonexistent'}
            with self.assertRaises(ValueError): store.save_taxonomy(changed)
            write.assert_not_called()
