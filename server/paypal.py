"""Staged PayPal observations and explicit, one-to-one bank associations."""
import datetime as dt
import hashlib
import re
from decimal import Decimal
from urllib.parse import urlencode
import store
import exchange_rates


def validate_start(value=None):
    if value is None: return (dt.date.today() - dt.timedelta(days=90)).isoformat()
    if not isinstance(value, str): raise ValueError('Choose a valid PayPal start date')
    start = dt.date.fromisoformat(value)
    if not store.history_start(7) <= start <= dt.date.today():
        raise ValueError('Choose a PayPal start date within the last seven years')
    return start.isoformat()


def sync(progress=None, date_from=None):
    start = validate_start(date_from)
    downloaded_dates = []
    session = store.read('session-paypal.json', {})
    if not session.get('accounts'):
        raise ValueError('Authorize a PayPal account first.')
    staged = store.read('paypal-observations.json', {})
    for account in session['accounts']:
        account_id = 'paypal-' + hashlib.sha256(str(account.get('identification_hash') or account['account_id']).encode()).hexdigest()[:24]
        params = {'date_from': start, 'strategy': 'longest'}
        seen = set()
        while True:
            page = store.api('/accounts/' + account['uid'] + '/transactions?' + urlencode(params))
            for raw in page['transactions']:
                reference = raw.get('entry_reference')
                if not reference:
                    raise ValueError('PayPal record has no stable reference; previous download preserved.')
                identity = hashlib.sha256((account_id + reference).encode()).hexdigest()[:32]
                debit = raw['credit_debit_indicator'] == 'DBIT'
                merchant = (raw.get('creditor' if debit else 'debtor') or {}).get('name')
                description = merchant or ' · '.join(raw.get('remittance_information') or []) or raw.get('note') or 'PayPal payment'
                staged[identity] = dict(id=identity, accountId=account_id, institution='PayPal', provider='enablebanking', kind='purchase',
                    externalId=reference, description=description, date=(raw.get('transaction_date') or raw.get('booking_date') or raw['value_date'])[:10],
                    amount=int(Decimal(raw['transaction_amount']['amount'])*100)*(-1 if debit else 1),
                    currency=raw['transaction_amount']['currency'], status=raw.get('status'), raw=raw)
                downloaded_dates.append(staged[identity]['date'])
            if progress: progress(f'PayPal: {len(staged)} payments downloaded')
            cursor = page.get('continuation_key')
            if not cursor: break
            if cursor in seen or len(seen) >= 1000: raise ValueError('Invalid PayPal pagination')
            seen.add(cursor)
            params['continuation_key'] = cursor
    store.write('paypal-observations.json', staged)
    store.write('paypal-sync.json', {'at': dt.datetime.now(dt.timezone.utc).isoformat(), 'requestedFrom':start,
        'earliestReturned':min(downloaded_dates, default=None), 'latestReturned':max(downloaded_dates, default=None), 'returnedCount':len(downloaded_dates)})


def eligible(observation, bank, owners):
    return (bank.get('status') == 'BOOK' and observation.get('status') == 'BOOK'
        and bank['amount'] * observation['amount'] > 0
        and re.search(r'PAYPAL|PYPL', bank['description'], re.I)
        and owners.get(bank['accountId']) == owners.get(observation['accountId']))


def review(query='', observation_id=None):
    observations = store.read('paypal-observations.json', {})
    links = store.read('paypal-associations.json', {})
    owners = store.read('profiles.json', {}).get('accountUsers', {})
    # Canonical bank payments, including existing manual merges.
    snapshot = store.snapshot()
    banks = snapshot['transactions']
    nicknames = snapshot.get('profiles', {}).get('accountNicknames', {})
    labels = {a['id']: nicknames.get(a['id']) or a['label'] for a in snapshot['accounts']}
    used = set(links.values())
    table = exchange_rates.Table()
    tolerance = Decimal(str(store.read('preferences.json', {}).get('fxTolerancePercent',10)))
    rows = []
    for o in observations.values():
        if o['id'] in links or observation_id and o['id'] != observation_id: continue
        candidates = []
        for b in banks:
            if b['id'] in used or any(s.get('institution') == 'PayPal' for s in b.get('sourceRecords', [])): continue
            if not eligible(o, b, owners): continue
            gap = (dt.date.fromisoformat(b['date']) - dt.date.fromisoformat(o['date'])).days
            if abs(gap) > 31: continue
            if query and query.casefold() not in f"{b['description']} {b['date']} {abs(b['amount'])/100:.2f}".casefold(): continue
            exact = o['amount'] == b['amount'] and o['currency'] == b['currency'] and 0 <= gap <= 7
            converted = None
            difference = None
            if o['currency'] != b['currency']:
                converted = table.convert(o['amount'], o['currency'], b['currency'], o['date'])
                if converted is None: continue
                difference = abs(Decimal(b['amount'])-converted[0])/abs(converted[0])*100
                if difference > tolerance: continue
            fx = converted is not None and 0 <= gap <= 7
            candidates.append(dict(id=b['id'], description=b['description'], date=b['date'], amount=b['amount'], currency=b['currency'],
                expectedAmount=float(converted[0]) if converted else None, rateDate=converted[1] if converted else None, differencePercent=float(difference) if difference is not None else None,
                accountId=b['accountId'], accountLabel=labels.get(b['accountId'], 'Bank account'), delay=gap, rule='exact' if exact else 'fx' if fx else 'nearby'))
        candidates.sort(key=lambda b: ({'exact':0,'fx':1,'nearby':2}[b['rule']],b['differencePercent'] or 0,abs(b['delay']),abs(b['amount']-o['amount'])))
        rows.append({'observation':{k:v for k,v in o.items() if k!='raw'}, 'candidates': candidates})
    claims = {}
    for row in rows:
        for c in row['candidates']:
            if c['rule']=='exact': claims[c['id']] = claims.get(c['id'],0)+1
    for row in rows:
        exact = [c for c in row['candidates'] if c['rule']=='exact']
        row['rule'] = 'exact' if len(exact)==1 and claims[exact[0]['id']]==1 else 'fx' if any(c['rule']=='fx' for c in row['candidates']) else 'unmatched'
    return {'rows':rows, 'confirmed':len(links), 'exchangeRates':table.status(), 'tolerancePercent':float(tolerance), 'history':store.read('paypal-sync.json',{}), 'lastSync':store.read('paypal-sync.json',{}).get('at')}


def confirm(pairs):
    if not isinstance(pairs,list) or not pairs or len(pairs)>5000: raise ValueError('Select 1 to 5000 associations')
    available = {r['observation']['id']:r for r in review()['rows']}
    links = store.read('paypal-associations.json', {})
    for pair in pairs:
        oid, bid = pair['observationId'], pair['bankId']
        if oid in links or bid in links.values(): raise ValueError('A payment is already associated; refresh the review')
        if oid not in available or bid not in {c['id'] for c in available[oid]['candidates']}:
            raise ValueError('Association no longer eligible; refresh the review')
        links[oid] = bid
    store.write('paypal-associations.json',links)
