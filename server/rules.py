"""Validated, ordered DNF classification rules. No executable expressions."""
import uuid

FIELDS = {'description', 'source', 'direction'}
OPERATORS = {'contains', 'starts_with', 'ends_with', 'equals', 'not_contains'}


def validate(rule, categories, tags=()):
    if not isinstance(rule, dict):
        raise ValueError('Rule must be an object')
    name = rule.get('name', '')
    groups = rule.get('groups')
    if not isinstance(name, str) or not name.strip() or len(name) > 100:
        raise ValueError('Give the rule a name (up to 100 characters)')
    tag_ids = rule.get('tags', [])
    if not isinstance(tag_ids, list) or any(not isinstance(t, str) or t not in tags for t in tag_ids):
        raise ValueError('Choose existing tags')
    special = rule.get('kind') == 'category'
    if (rule.get('category') not in categories and not (rule.get('category') is None and tag_ids)) or not isinstance(rule.get('enabled', True), bool):
        raise ValueError('Invalid category or enabled flag')
    if not isinstance(groups, list) or not (0 if special else 1) <= len(groups) <= 2000:
        raise ValueError('Use up to 2000 OR groups (an empty category rule matches nothing)')
    clean = []
    for group in groups:
        if not isinstance(group, list) or not 1 <= len(group) <= 12:
            raise ValueError('Each group needs 1 to 12 AND conditions')
        conditions = []
        for condition in group:
            if not isinstance(condition, dict):
                raise ValueError('Invalid condition')
            field, op, value = (condition.get(k) for k in ('field', 'operator', 'value'))
            if field not in FIELDS or op not in OPERATORS:
                raise ValueError('Unknown field or operator')
            if not isinstance(value, str) or not value.strip() or len(value) > 2000:
                raise ValueError('Each condition needs a value (up to 2000 characters)')
            if field == 'direction' and (op != 'equals' or value not in ('income', 'expense')):
                raise ValueError('Direction must equal income or expense')
            conditions.append({'field': field, 'operator': op, 'value': value.strip()})
        clean.append(conditions)
    identity = rule.get('id') or str(uuid.uuid4())
    if not isinstance(identity, str) or len(identity) > 100:
        raise ValueError('Invalid rule ID')
    result = {'id': identity, 'name': name.strip(), 'category': rule.get('category'),
              'enabled': rule.get('enabled', True), 'groups': clean}
    if tag_ids: result['tags'] = sorted(set(tag_ids))
    if rule.get('kind') == 'extra': result['kind'] = 'extra'
    if special:
        if tag_ids: raise ValueError('Use an additional rule for tags')
        result['kind'] = 'category'
    return result


def matches(rule, payment):
    if not rule.get('enabled', True):
        return False
    if rule['category'] in ('Salary', 'Other income') and payment['amount'] <= 0:
        return False
    # An AND group must match one source record, never unrelated fields across records.
    observations = payment.get('sourceRecords') or [payment]
    def condition_matches(c, record):
        field = c['field']
        if field == 'direction':
            actual = 'income' if payment['amount'] > 0 else 'expense'
        elif field == 'source':
            actual = record.get('institution', record.get('source', ''))
        else:
            actual = record.get(field, '')
        actual, value = str(actual).casefold(), c['value'].casefold()
        return {'contains': lambda: value in actual,
                'not_contains': lambda: value not in actual,
                'starts_with': lambda: actual.startswith(value),
                'ends_with': lambda: actual.endswith(value),
                'equals': lambda: actual == value}[c['operator']]()
    return any(all(condition_matches(c, record) for c in group)
               for record in observations for group in rule['groups'])


def category_draft(category, name, ordered):
    candidates = [r for r in ordered if r.get('category') == category and r.get('kind') != 'extra' and not r.get('tags')
                  and (r.get('enabled', True) or r.get('kind') == 'category')]
    groups = []
    for rule in candidates:
        # Paused canonical rules are kept separate when active rules exist.
        if not rule.get('enabled', True) and any(r.get('enabled', True) for r in candidates):
            continue
        for group in rule['groups']:
            if group not in groups: groups.append(group)
    return {'id': candidates[0]['id'] if candidates else 'category-' + str(uuid.uuid5(uuid.NAMESPACE_URL, category)),
            'name': name, 'category': category, 'kind': 'category',
            'enabled': any(r.get('enabled', True) for r in candidates) if candidates else True, 'groups': groups}


def save_category(ordered, rule):
    category = rule['category']
    result, inserted = [], False
    for old in ordered:
        same = old.get('category') == category and old.get('kind') != 'extra' and not old.get('tags')
        if same and (old.get('enabled', True) or old.get('kind') == 'category'):
            if not old.get('enabled', True) and old['id'] != rule['id'] and rule.get('enabled', True):
                result.append({**old, 'kind': 'extra'})
                continue
            if not inserted:
                result.append(rule); inserted = True
        else:
            result.append(old)
    if not inserted: result.append(rule)
    return result


def transfer_categories(ordered, transfers, names):
    result = [dict(r) for r in ordered]
    for source, target in transfers.items():
        for rule in result:
            if rule.get('category') == source:
                rule['category'] = target
                if not rule.get('enabled', True):
                    rule['kind'] = 'extra'
        active = [r for r in result if r.get('category') == target and r.get('kind') != 'extra' and not r.get('tags') and r.get('enabled', True)]
        if active:
            draft = category_draft(target, names[target], active)
            result = save_category(result, draft)
    return result
