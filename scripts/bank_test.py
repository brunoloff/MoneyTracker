"""Small read-only Enable Banking diagnostic. Secrets stay in .private/."""
import base64
import datetime as dt
import getpass
import json
import os
from pathlib import Path
import secrets
import sys
import time
from urllib.parse import urlparse, parse_qs
import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

ROOT = Path(__file__).resolve().parent.parent
PRIVATE = ROOT / '.private'
PRIVATE.mkdir(mode=0o700, exist_ok=True)
os.chmod(PRIVATE, 0o700)

def save(name, data):
    path = PRIVATE / name
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as out:
        json.dump(data, out)

def api(path, body=None):
    keys = list(ROOT.glob('*.pem'))
    if len(keys) != 1:
        raise RuntimeError('Expected exactly one application PEM file')
    p = keys[0]
    def enc(value):
        return base64.urlsafe_b64encode(value).rstrip(b'=')
    now = int(time.time())
    msg = b'.'.join(enc(json.dumps(v, separators=(',', ':')).encode()) for v in [
        {'typ':'JWT', 'alg':'RS256', 'kid':p.stem},
        {'iss':'enablebanking.com', 'aud':'api.enablebanking.com', 'iat':now, 'exp':now+600}])
    key = serialization.load_pem_private_key(p.read_bytes(), password=None)
    token = (msg+b'.'+enc(key.sign(msg, padding.PKCS1v15(), hashes.SHA256()))).decode()
    r = requests.request('POST' if body is not None else 'GET',
        'https://api.enablebanking.com'+path, json=body,
        headers={'Authorization':'Bearer '+token}, timeout=60)
    if not r.ok:
        data = r.json()
        raise RuntimeError(f"HTTP {r.status_code}: {data.get('error')} {data.get('message')}")
    return r.json()

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'banks':
        banks = api('/aspsps?country=PT')['aspsps']
        save('banks.json', banks)
        for bank in banks:
            if any(s in bank['name'].lower() for s in ['caixa geral', 'bankinter', 'millennium', 'comercial portugu', 'revolut']):
                print(json.dumps(bank))
    elif cmd == 'auth':
        name = sys.argv[2]
        banks = json.loads((PRIVATE/'banks.json').read_text())
        bank = next(b for b in banks if b['name'] == name)
        state = secrets.token_urlsafe(32)
        validity = min(3600, bank['maximum_consent_validity'])
        request = {'access':{'valid_until':(dt.datetime.now(dt.timezone.utc)+dt.timedelta(seconds=validity)).isoformat()},
                   'aspsp':{'name':name, 'country':'PT'}, 'state':state,
                   'redirect_url':'https://localhost:8443/callback', 'psu_type':'personal'}
        response = api('/auth', request)
        save('pending.json', {'state':state, 'bank':name})
        print(response['url'])
    elif cmd == 'finish':
        url = getpass.getpass('Paste the final localhost callback URL (hidden): ')
        parsed = urlparse(url)
        if (parsed.scheme, parsed.netloc, parsed.path) != ('https','localhost:8443','/callback'):
            raise RuntimeError('Unexpected callback address')
        query = parse_qs(parsed.query)
        pending = json.loads((PRIVATE/'pending.json').read_text())
        if not secrets.compare_digest(query.get('state',[''])[0], pending['state']):
            raise RuntimeError('Authorization state mismatch')
        if 'error' in query:
            raise RuntimeError('Bank authorization was not completed')
        session = api('/sessions', {'code':query['code'][0]})
        save('session.json', session)
        (PRIVATE/'pending.json').unlink()
        print('Authorized accounts:', len(session['accounts']))
    elif cmd == 'fetch':
        session = json.loads((PRIVATE/'session.json').read_text())
        for i, account in enumerate(session['accounts'], 1):
            uid = account['uid']
            balances = api(f'/accounts/{uid}/balances')
            # Retrieve all pages in a bounded recent window before selecting latest five.
            start = (dt.date.today()-dt.timedelta(days=90)).isoformat()
            from urllib.parse import urlencode
            transactions = []
            continuation = None
            while True:
                params = {'date_from':start}
                if continuation: params['continuation_key'] = continuation
                page = api(f'/accounts/{uid}/transactions?'+urlencode(params))
                transactions.extend(page['transactions'])
                continuation = page.get('continuation_key')
                if not continuation: break
            transactions.sort(key=lambda t:(t.get('booking_date') or t.get('value_date') or ''), reverse=True)
            result = {'account_number':i, 'balances':balances, 'latest_transactions':transactions[:5],
                      'history_from':start, 'transactions_in_window':len(transactions)}
            save(f'result-{i}.json', result)
            print(json.dumps(result, ensure_ascii=False, indent=2))
