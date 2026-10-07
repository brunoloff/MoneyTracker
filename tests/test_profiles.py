import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
from profiles import validate

class ProfileTests(unittest.TestCase):
    def test_names_and_assignments(self):
        config = validate({'users': [{'id': 'a', 'name': ' Alice '}, {'id': 'b', 'name': 'Bob'}], 'accountUsers': {'one': 'a', 'two': 'b'}}, {'one', 'two'})
        self.assertEqual(config['users'][0]['name'], 'Alice')
        self.assertEqual(config['accountUsers']['two'], 'b')

    def test_reject_invalid_assignments_and_names(self):
        for config in [
            {'users': [], 'accountUsers': {'one': 'unknown'}},
            {'users': [{'id': 'a', 'name': 'Alice'}], 'accountUsers': {'missing': 'a'}},
            {'users': [{'id': 'all', 'name': 'Alice'}], 'accountUsers': {}},
            {'users': [{'id': 'a', 'name': 'Alice'}, {'id': 'b', 'name': 'alice'}], 'accountUsers': {}},
            {'users': [{'id': 'a', 'name': ' '}], 'accountUsers': {}},
        ]:
            with self.assertRaises(ValueError): validate(config, {'one'})

    def test_removing_users_can_leave_accounts_unassigned(self):
        self.assertEqual(validate({'users': [], 'accountUsers': {}}, {'one'}), {'users': [], 'accountUsers': {}})

    def test_nicknames_are_trimmed_and_blanks_clear_them(self):
        result = validate({'users': [], 'accountUsers': {},
                           'accountNicknames': {'one': ' Daily spending ', 'two': ' '}}, {'one', 'two'})
        self.assertEqual(result['accountNicknames'], {'one': 'Daily spending'})

    def test_reject_invalid_nicknames(self):
        for nicknames in [[], {'missing': 'Name'}, {'one': 123}, {'one': 'x' * 61}]:
            with self.assertRaises(ValueError):
                validate({'users': [], 'accountUsers': {}, 'accountNicknames': nicknames}, {'one'})
