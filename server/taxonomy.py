"""Stable category/tag IDs with editable labels; one level of subcategories."""
import re

COLORS = {'Food': '00A5AA', 'Shopping': '388DF0', 'Travel': 'FF8B37', 'Transport': '6380BB', 'Rent': 'CF769B', 'Bills': '9870ED', 'Health': 'D8666C', 'Entertainment': '93A0B4', 'Other': '93A0B4', 'Salary': '008F84', 'Other income': '008F84', 'Transfer': '93A0B4', 'Uncategorized': '93A0B4'}
SPECIAL = {'Salary', 'Other income', 'Transfer'}

def defaults():
    return {'categories': [{'id': name, 'name': name, 'parent': None, 'color': color} for name, color in COLORS.items()], 'tags': []}

def validate(config, used_categories=(), used_tags=()):
    if not isinstance(config, dict): raise ValueError('Invalid settings')
    categories, tags = config.get('categories'), config.get('tags')
    if not isinstance(categories, list) or not isinstance(tags, list) or len(categories) > 200 or len(tags) > 200:
        raise ValueError('Use at most 200 categories and tags')
    def entries(rows):
        result, identities, names = [], set(), set()
        for row in rows:
            identity, name = row.get('id'), row.get('name')
            if not isinstance(identity, str) or not identity or len(identity) > 100 or identity in identities or identity == 'all': raise ValueError('Invalid or duplicate ID')
            if not isinstance(name, str) or not name.strip() or len(name.strip()) > 60 or name.strip().casefold() in names: raise ValueError('Names must be unique and non-empty (up to 60 characters)')
            result.append({**row, 'name': name.strip()}); identities.add(identity); names.add(name.strip().casefold())
        return result, identities
    categories, ids = entries(categories)
    tags, tag_ids = entries(tags)
    if 'Uncategorized' not in ids or not set(used_categories) <= ids or not set(used_tags) <= tag_ids:
        raise ValueError('Keep Uncategorized and transfer categories in use before deleting; used tags cannot be deleted')
    by_id = {c['id']: c for c in categories}
    for c in categories:
        parent = c.get('parent')
        if c['id'] == 'Uncategorized' and (c['name'] != 'Uncategorized' or parent is not None or c.get('color') != COLORS['Uncategorized']):
            raise ValueError('Uncategorized cannot be changed')
        if parent == 'Uncategorized': raise ValueError('Uncategorized cannot have subcategories')
        if not re.fullmatch('[0-9a-fA-F]{6}', c.get('color', '')): raise ValueError('Invalid category color')
        if c['id'] in COLORS and parent: raise ValueError('Built-in categories remain main categories')
        if parent and (parent not in ids or parent == c['id'] or by_id[parent].get('parent')): raise ValueError('Choose a main category as parent')
    return {'categories': [{'id': c['id'], 'name': c['name'], 'parent': c.get('parent'), 'color': c['color'].upper()} for c in categories],
            'tags': [{'id': t['id'], 'name': t['name']} for t in tags]}
