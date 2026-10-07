"""Local normalized ledger; amounts are integer minor units, never floats."""
import datetime as dt
import hashlib
import json
import re
import rules
import undo
import taxonomy
import sys
from decimal import Decimal
from pathlib import Path
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
from bank_test import PRIVATE, api

CATEGORIES = ['Uncategorized', 'Food', 'Shopping', 'Travel', 'Transport', 'Rent', 'Bills', 'Health', 'Entertainment', 'Other', 'Salary', 'Other income', 'Transfer']
RULES = [
    ('Food', r'PINGO DOCE|CONTINENTE|LIDL|ALDI|AUCHAN|SPAR|RESTAUR|QUIOSQUE|CERV|PASTEL|SUPERMERC|CAF[EÉ]'),
    ('Shopping', r'AMAZON|WWW\.AMA|FNAC|IKEA|DECATHLON|ZARA'),
    ('Transport', r'UBER(?!.*EATS)|BOLT|METRO|CP COMBO|CARRIS|VIA VERDE|GALP|REPSOL'),
    ('Bills', r'VODAFONE|MEO |NOS |EDP|ENDESA|EPAL|AGUA|IMPOSTO|COMISS|COM SB'),
    ('Health', r'FARM[AÁ]CIA|HOSPITAL|CLINIC'),
    ('Travel', r'RYANAIR|EASYJET|TAP |HOTEL|AIRBNB|BOOKING|BETTERROAMING'),
    ('Entertainment', r'NETFLIX|SPOTIFY|CINEMA'),
]

def read(name, default):
    return undo.read(PRIVATE,name,default)

def write(name, value):
    undo.write(PRIVATE,name,value)

def classification_settings():
    config = read('taxonomy.json', taxonomy.defaults())
    if not any(c['id'] == 'Uncategorized' for c in config['categories']):
        config['categories'].insert(0, {'id': 'Uncategorized', 'name': 'Uncategorized', 'parent': None, 'color': '93A0B4'})
    return config

def root_category(identity):
    return next((c.get('parent') or identity for c in classification_settings()['categories'] if c['id'] == identity), identity)

def rule_matches(rule, payment, roots=None):
    root = roots.get(rule['category'], rule['category']) if roots is not None else root_category(rule['category'])
    return rules.matches({**rule, 'category': root}, payment)

def category_ids():
    return [c['id'] for c in classification_settings()['categories']]

def save_taxonomy(config):
    old = {c['id']: c for c in classification_settings()['categories']}
    remaining = {c['id'] for c in config.get('categories', [])}
    removed = old.keys() - remaining
    transfers = config.get('categoryTransfers', {})
    if not isinstance(transfers, dict) or set(transfers) != removed:
        raise ValueError('Choose a destination for every deleted category')
    for source, target in transfers.items():
        if source == 'Uncategorized' or target not in remaining:
            raise ValueError('Choose an existing destination; Uncategorized cannot be deleted')
        if any(c.get('parent') == source for c in config.get('categories', [])):
            raise ValueError('Delete or move subcategories before deleting their parent')
    ledger = read('ledger.json', {})
    overrides = read('categories.json', {})
    saved_rules = read('rules.json', [])
    # Pin moved visible assignments so a later bank refresh cannot reset them.
    if removed:
        for payment in snapshot()['transactions']:
            if payment['category'] in transfers:
                overrides[payment['id']] = transfers[payment['category']]
    for row in ledger.get('transactions', []):
        row['category'] = transfers.get(row['category'], row['category'])
    overrides = {key: transfers.get(value, value) for key, value in overrides.items()}
    saved_rules = rules.transfer_categories(saved_rules, transfers, {c['id']: c['name'] for c in config['categories']})
    used_categories = {r['category'] for r in ledger.get('transactions', [])}
    used_categories.update(overrides.values())
    used_categories.update(r['category'] for r in saved_rules if r.get('category'))
    used_tags = {tag for tags in read('tags.json', {}).values() for tag in tags}
    used_tags.update(tag for r in saved_rules for tag in r.get('tags', []))
    validated = taxonomy.validate(config, used_categories, used_tags)
    roots = {c['id']: c.get('parent') or c['id'] for c in validated['categories']}
    names = {c['id']: c['name'] for c in validated['categories']}
    for rule in saved_rules:
        if rule.get('kind') == 'category': rule['name'] = names[rule['category']]
    # Income-only rule actions would stop matching expenses after migration.
    for source, target in transfers.items():
        if roots[target] in {'Salary', 'Other income'} and (old[source].get('parent') or source) not in {'Salary', 'Other income'}:
            raise ValueError('Choose a non-income destination for this category')
    with undo.action(PRIVATE, 'Edit categories and tags'):
        if removed:
            write('ledger.json', ledger)
            write('categories.json', overrides)
        if saved_rules != read('rules.json', []): write('rules.json', saved_rules)
        write('taxonomy.json', validated)

def suggest(description, amount, allowed=None):
    allowed = set(category_ids()) if allowed is None else allowed
    if amount > 0:
        return 'Other income' if 'Other income' in allowed else 'Uncategorized'
    for category, pattern in RULES:
        if re.search(pattern, description, re.I):
            return category if category in allowed else 'Uncategorized'
    return 'Uncategorized'

def normalize(raw, account_id, allowed=None, source='CGD'):
    currency = raw['transaction_amount']['currency']
    if currency != 'EUR':
        raise ValueError('This first version only supports EUR; refusing to mix currencies.')
    amount = int((Decimal(raw['transaction_amount']['amount']) * 100).quantize(Decimal('1')))
    amount = abs(amount) * (-1 if raw['credit_debit_indicator'] == 'DBIT' else 1)
    description = ' · '.join(raw.get('remittance_information') or []) or raw.get('note') or 'Bank transaction'
    date = raw.get('transaction_date') or raw.get('booking_date') or raw.get('value_date')
    if not date:
        raise ValueError('Transaction has no date')
    reference = raw.get('entry_reference') or raw.get('transaction_id')
    # Hash IDs only inside their account namespace. Preserve raw source records locally.
    fallback = json.dumps(raw, sort_keys=True, separators=(',', ':'))
    identity = str(reference) if reference else fallback
    key = hashlib.sha256((account_id + ':' + identity).encode()).hexdigest()[:32]
    return {'id': key, 'accountId': account_id, 'date': date[:10],
            'bookingDate': raw.get('booking_date'), 'amount': amount, 'currency': currency,
            'description': description.strip(), 'category': suggest(description, amount, allowed),
            'reviewed': False, 'status': raw.get('status', 'BOOK'), 'source': source,
            'purchaseDetails': [], 'relatedSourceIds': [], 'hasStableId': bool(reference),
            'sourceRecord': {'id': key, 'provider': 'enablebanking', 'institution': source, 'kind': 'bank_movement', 'externalId': reference, 'accountId': account_id, 'date': date[:10], 'description': description.strip(), 'amount': amount, 'currency': currency}}

def stable_account_id(account, source='CGD'):
    identity = account.get('identification_hash') or json.dumps(account.get('account_id'), sort_keys=True)
    if not identity or identity == 'null':
        raise ValueError('Bank account has no stable identity')
    return hashlib.sha256(('enablebanking:' + source + ':' + identity).encode()).hexdigest()[:24]

def history_start(years, today=None):
    if type(years) is not int or not 1 <= years <= 20:
        raise ValueError('Choose 1 to 20 years')
    today = today or dt.date.today()
    try:
        return today.replace(year=today.year - years)
    except ValueError:
        return today.replace(year=today.year - years, day=28)


def sync(years=None, progress=None, account_id_filter=None):
    import connections
    sessions = connections.bank_sessions()
    session = sessions[-1] if sessions else {}
    selected_accounts = {}
    for saved in sessions:
        source = connections.source_name(saved)
        for account in saved.get('accounts', []):
            selected_accounts[stable_account_id(account, source)] = (account, source)
    if not selected_accounts:
        raise ValueError('No bank connection. Authorize a bank in Users & accounts first.')
    start = (history_start(years) if years is not None else dt.date.today() - dt.timedelta(days=90)).isoformat()
    previous = read('ledger.json', {})
    accounts, transactions, coverage = [], [], []
    allowed_categories = set(category_ids())
    if account_id_filter and account_id_filter not in selected_accounts:
        raise ValueError('Unknown bank account')
    for index, (account_id, (a, source)) in enumerate(selected_accounts.items(), 1):
        if account_id_filter and account_id != account_id_filter: continue
        uid = a['uid']
        balances = api(f'/accounts/{uid}/balances')['balances']
        kind = a.get('cash_account_type', '')
        identity = a.get('account_id') or {}
        iban = identity.get('iban') or ''
        label = ('Card' if kind == 'CARD' else 'Current account') + (f' ··{iban[-4:]}' if iban else f' {index}')
        balance = next((b['balance_amount'] for b in balances if b['balance_type'] == 'ITAV'), None)
        accounts.append({'id': account_id, 'label': label, 'source': source, 'kind': kind,
                         'balance': int(Decimal(balance['amount'])*100) if balance and balance['currency']=='EUR' else None})
        continuation, seen = None, set()
        raw_rows = []
        while True:
            params = {'date_from': start}
            if years is not None: params['strategy'] = 'longest'
            if continuation: params['continuation_key'] = continuation
            page = api(f'/accounts/{uid}/transactions?' + urlencode(params))
            raw_rows.extend(page['transactions'])
            if progress: progress(f"Account {index}/{len(selected_accounts)}: {len(raw_rows)} records received")
            continuation = page.get('continuation_key')
            if not continuation: break
            if len(seen) >= 10000: raise ValueError('Too many bank pages; previous import preserved')
            if continuation in seen: raise ValueError('Repeated bank pagination cursor')
            seen.add(continuation)
        write(f'raw-{index}.json', raw_rows)
        # Preserve identical no-ID movements rather than silently losing legitimate purchases.
        occurrences = {}
        unique = {}
        for raw in raw_rows:
            row = normalize(raw, account_id, allowed_categories, source)
            if years is not None and row['date'] < start: continue
            if not row['hasStableId']:
                count = occurrences.get(row['id'], 0)
                occurrences[row['id']] = count + 1
                row['id'] += f'-{count}'
            unique[row['id']] = row
        transactions.extend(unique.values())
        coverage.append({'accountId': account_id, 'label': label, 'count': len(unique), 'earliest': min((t['date'] for t in unique.values()), default=None)})
    # Bank history may be truncated. Keep booked records and overlay refreshed IDs;
    # only the ordinary recent sync replaces missing pending records in its window.
    old = previous.get('transactions', [])
    synced_ids = {a['id'] for a in accounts}
    retained = {t['id']: t for t in old if t['accountId'] not in synced_ids or (account_id_filter and t['accountId'] != account_id_filter) or years is not None or t['date'] < start or t['status'] == 'BOOK'}
    retained.update({t['id']: t for t in transactions})
    transactions = sorted(retained.values(), key=lambda t: (t['date'], t['id']), reverse=True)
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    refreshed_ids = {a['id'] for a in accounts}
    accounts += [a for a in previous.get('accounts', []) if a['id'] not in refreshed_ids]
    result = {**previous, 'accounts': accounts, 'transactions': transactions, 'syncedAt': now,
              'consentUntil': session.get('access', {}).get('valid_until')}
    known_start = min((t['date'] for t in transactions), default=previous.get('historyFrom', start))
    result['historyFrom'] = min(previous.get('historyFrom', known_start), known_start)
    if years is not None:
        result['historyImport'] = {'years': years, 'requestedFrom': start, 'completedAt': now,
                                  'added': len(retained.keys() - {t['id'] for t in old}), 'accounts': coverage}
    write('ledger.json', result)
    return len(transactions)

def snapshot():
    config = classification_settings()
    roots = {c['id']: c.get('parent') or c['id'] for c in config['categories']}
    result = read('ledger.json', {'accounts':[], 'transactions':[], 'syncedAt':None})
    overrides = read('categories.json', {})
    groups = read('merges.json', {})
    tags = read('tags.json', {})
    classification_rules = read('rules.json', [])
    category_rules = [r for r in classification_rules if r.get('category') and r.get('enabled', True)]
    tag_rules = [r for r in classification_rules if r.get('tags') and r.get('enabled', True)]
    records = {row['id']: row for row in result['transactions']}
    merged_children = {child for parent, children in groups.items() if parent in records for child in children if child != parent}
    paypal_rows = read('paypal-observations.json', {})
    paypal_links = read('paypal-associations.json', {})
    paypal_by_bank = {bid: paypal_rows[oid] for oid, bid in paypal_links.items() if oid in paypal_rows}
    payments = []
    for row in result['transactions']:
        if row['id'] in merged_children:
            continue
        ids = [row['id']] + groups.get(row['id'], [])
        observations = [records[i] for i in dict.fromkeys(ids) if i in records]
        row['sourceRecords'] = [o.get('sourceRecord', {'id':o['id'], 'institution':o['source'], 'kind':'bank_movement', 'description':o['description'], 'date':o['date'], 'amount':o['amount'], 'currency':o['currency'], 'accountId':o['accountId']}) for o in observations]
        row['accountIds'] = list(dict.fromkeys(o['accountId'] for o in observations))
        for observation in observations:
            if observation['id'] in paypal_by_bank:
                paypal = paypal_by_bank[observation['id']]
                row['sourceRecords'].append({k:v for k,v in paypal.items() if k != 'raw'})
                row['description'] = paypal['description']
                row['accountIds'].append(paypal['accountId'])
        row['merged'] = len(observations) > 1
        row['tags'] = sorted({tag for observation in observations for tag in tags.get(observation['id'], [])})
        row['classificationRule'] = None
        row['reviewed'] = False
        for rule in category_rules:
            if rule_matches(rule, row, roots):
                row['category'] = rule['category']
                row['classificationRule'] = {'id': rule['id'], 'name': rule['name']}
                break
        for rule in tag_rules:
            if rule_matches(rule, row, roots):
                row['tags'] = sorted(set(row['tags']) | set(rule['tags']))
        if row['id'] in overrides:
            row['classificationRule'] = None
            row['category'] = overrides[row['id']]
            row['reviewed'] = True
        payments.append(row)
    paypal_accounts = {o['accountId'] for o in paypal_rows.values()}
    result.setdefault('accounts', [])
    result['accounts'] += [{'id': aid, 'label': 'PayPal', 'source': 'PayPal', 'kind': 'PAYPAL', 'balance': None} for aid in sorted(paypal_accounts) if aid not in {a['id'] for a in result['accounts']}]
    result['taxonomy'] = config
    result['rules'] = classification_rules
    result['transactions'] = payments
    result['profiles'] = read('profiles.json', {'users': [], 'accountUsers': {}})
    result['preferences'] = read('preferences.json', {'period':'month'})
    return result

def client_snapshot():
    """Do not send redundant storage records or import audit metadata to the UI.

    Full provenance remains in the local ledger; linked source details needed by
    search, rule creation and the transaction dialog remain in sourceRecords.
    """
    result = snapshot()
    for row in result['transactions']:
        row.pop('sourceRecord', None)
        for source in row['sourceRecords']:
            for key in ('sha256', 'sourceFile', 'sheet', 'row', 'availableBalance', 'bankCategory', 'balance'):
                source.pop(key, None)
    result.pop('fileImports', None)
    return result


def merge(primary_id, secondary_id):
    if primary_id == secondary_id:
        raise ValueError('Choose two different payments')
    payments = {p['id']:p for p in snapshot()['transactions']}
    if primary_id not in payments or secondary_id not in payments:
        raise ValueError('Payment no longer available; reload first')
    a, b = payments[primary_id], payments[secondary_id]
    if (a['amount'], a['currency'], a['status']) != (b['amount'], b['currency'], b['status']):
        raise ValueError('This version merges only equal amounts, currency and status; splits and fees need separate reconciliation')
    groups = read('merges.json', {})
    groups[primary_id] = list(dict.fromkeys(groups.get(primary_id, []) + [secondary_id] + groups.pop(secondary_id, [])))
    write('merges.json', groups)

def unmerge(primary_id):
    groups = read('merges.json', {})
    groups.pop(primary_id, None)
    write('merges.json', groups)

if __name__ == '__main__':
    with undo.action(PRIVATE, 'Sync bank accounts'):
        print(f'Imported {sync()} transactions.')
