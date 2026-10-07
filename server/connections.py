"""Refresh account metadata from existing Enable Banking authorizations."""
from urllib.parse import quote
import hashlib
import requests
import store
import undo


def paypal_account_id(account):
    return 'paypal-' + hashlib.sha256(str(account.get('identification_hash') or account['account_id']).encode()).hexdigest()[:24]


def refresh(progress=None):
    ledger = store.read('ledger.json', {'accounts': [], 'transactions': []})
    known = {a['id']: a for a in ledger.get('accounts', [])}
    added, checked, warnings = 0, 0, []
    extra = store.read('bank-sessions.json', [])
    entries_to_refresh = [(filename, store.read(filename, {})) for filename in ['session.json', 'session-paypal.json']]
    entries_to_refresh += [(index, session) for index, session in enumerate(extra)]
    seen = set()
    active = []
    for filename, session in reversed(entries_to_refresh):
        source = source_name(session)
        identities = {paypal_account_id(a) if source == 'PayPal' else store.stable_account_id(a, source)
                      for a in session.get('accounts', [])}
        if identities and identities <= seen:
            continue
        seen.update(identities)
        active.append((filename, session))
    for filename, session in reversed(active):
        source = source_name(session)
        if not session.get('session_id'):
            continue
        if progress:
            progress(f'Checking {source} accounts…')
        try:
            remote = store.api('/sessions/' + quote(session['session_id'], safe=''))
            if remote.get('status') != 'AUTHORIZED':
                raise ValueError('Authorization has expired or is inactive. Authorize this connection again.')
            old = {a['uid']: a for a in session.get('accounts', [])}
            accounts = []
            for item in remote['accounts_data']:
                # GET session only returns IDs/hashes. Preserve one-time metadata.
                account = {**old.get(item['uid'], {}), **item}
                if item['uid'] not in old:
                    details = store.api('/accounts/' + quote(item['uid'], safe='') + '/details')
                    account = {**details, **item}
                accounts.append(account)
            updated = {**session, 'accounts': accounts, 'access': remote.get('access', session.get('access'))}
            entries = []
            for index, account in enumerate(accounts, 1):
                identity = paypal_account_id(account) if source == 'PayPal' else store.stable_account_id(account, source)
                kind = 'PAYPAL' if source == 'PayPal' else account.get('cash_account_type', '')
                iban = (account.get('account_id') or {}).get('iban', '')
                label = 'PayPal' if source == 'PayPal' else ('Card' if kind == 'CARD' else 'Current account')
                label += f' ··{iban[-4:]}' if iban else (f' {index}' if source != 'PayPal' else '')
                entries.append({'id': identity, 'label': label, 'source': source, 'kind': kind,
                                'balance': known.get(identity, {}).get('balance')})
            # Only commit this connection after all required metadata was retrieved.
            if isinstance(filename, int):
                extra[filename] = updated
                store.write('bank-sessions.json', extra)
            else:
                store.write(filename, updated)
            for entry in entries:
                if entry['id'] not in known:
                    added += 1
                known[entry['id']] = {**known.get(entry['id'], {}), **entry}
            checked += 1
        except (RuntimeError, ValueError, KeyError, requests.RequestException) as exc:
            warnings.append(f'{source}: {exc}')
    ledger['accounts'] = list(known.values())
    store.write('ledger.json', ledger)
    return {'added': added, 'checked': checked, 'warnings': warnings,
            'message': f'{added} new account(s) found. Accounts linked only in the Enable Banking control panel need a separate bank authorization in MoneyTracker.'}


def source_name(session):
    name = session.get('aspsp', {}).get('name', 'CGD')
    return 'CGD' if name in ('CGD', 'Caixa Geral de Depósitos') else name


def bank_sessions():
    legacy = store.read('session.json', None)
    return ([legacy] if legacy else []) + store.read('bank-sessions.json', [])


def institutions(country):
    if not isinstance(country, str) or len(country) != 2 or not country.isalpha():
        raise ValueError('Choose a two-letter country code')
    return [{'name': b['name'], 'country': b['country']}
            for b in store.api('/aspsps?country=' + country.upper())['aspsps']
            if 'personal' in b.get('psu_types', ['personal'])]


def start(body):
    import datetime as dt
    import secrets
    import time
    country, name = body.get('country'), body.get('name')
    if not isinstance(country, str) or len(country) != 2 or not country.isalpha() or not isinstance(name, str):
        raise ValueError('Choose a bank and country')
    bank = next((b for b in store.api('/aspsps?country=' + country.upper())['aspsps']
                 if b['name'] == name and 'personal' in b.get('psu_types', ['personal'])), None)
    if not bank:
        raise ValueError('Bank is not available for personal accounts')
    redirect = 'https://localhost:8443/callback'
    if redirect not in store.api('/application')['redirect_urls']:
        raise ValueError('Register https://localhost:8443/callback as a redirect URL in Enable Banking first')
    state = secrets.token_urlsafe(32)
    attempt = secrets.token_urlsafe(24)
    validity = min(90 * 86400, bank['maximum_consent_validity'])
    request = {'aspsp': {'name': name, 'country': country.upper()}, 'state': state,
               'redirect_url': redirect, 'psu_type': 'personal',
               'access': {'valid_until': (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=validity)).isoformat()}}
    response = store.api('/auth', request)
    store.write('connection-pending.json', {'state': state, 'created': time.time(),
                'aspsp': request['aspsp'], 'redirect': redirect, 'attempt': attempt})
    return {'url': response['url'], 'attempt': attempt}


def finish(callback, automatic=False):
    import secrets
    import time
    from urllib.parse import urlparse, parse_qs
    pending = store.read('connection-pending.json', {})
    if not pending or time.time() - pending['created'] > 3600:
        raise ValueError('Authorization expired. Start again.')
    if not isinstance(callback, str):
        raise ValueError('Paste the callback URL')
    parsed = urlparse(callback.strip())
    if (parsed.scheme, parsed.netloc, parsed.path) != ('https', 'localhost:8443', '/callback'):
        raise ValueError('Paste the final https://localhost:8443/callback URL')
    query = parse_qs(parsed.query)
    if not secrets.compare_digest(query.get('state', [''])[0], pending['state']):
        raise ValueError('Authorization state mismatch. Use the most recent authorization link.')
    if 'error' in query or not query.get('code'):
        raise ValueError('Bank authorization was not completed')
    session = store.api('/sessions', {'code': query['code'][0]})
    if any(session.get('aspsp', {}).get(k) != pending['aspsp'][k] for k in ('name', 'country')):
        raise ValueError('Bank authorization returned an unexpected institution')
    if not session.get('accounts'):
        raise ValueError('No accessible accounts returned. Link this account in the Enable Banking control panel first, then authorize again.')
    # Store credentials separately from undoable local account metadata.
    if source_name(session) == 'PayPal':
        store.write('session-paypal.json', session)
    else:
        saved = store.read('bank-sessions.json', [])
        saved.append(session)
        store.write('bank-sessions.json', saved)
    store.write('connection-pending.json', {'attempt': pending.get('attempt'), 'created': pending['created'], 'completing': True} if automatic else {})
    ledger = store.read('ledger.json', {'accounts': [], 'transactions': []})
    known = {a['id']: a for a in ledger.get('accounts', [])}
    source = source_name(session)
    added = 0
    for index, account in enumerate(session['accounts'], 1):
        identity = paypal_account_id(account) if source == 'PayPal' else store.stable_account_id(account, source)
        if identity not in known:
            added += 1
        iban = (account.get('account_id') or {}).get('iban', '')
        kind = 'PAYPAL' if source == 'PayPal' else account.get('cash_account_type', '')
        label = ('PayPal' if source == 'PayPal' else 'Card' if kind == 'CARD' else 'Current account')
        label += f' ··{iban[-4:]}' if iban else f' {index}'
        known[identity] = {**known.get(identity, {}), 'id': identity, 'source': source, 'kind': kind,
                           'label': label, 'balance': known.get(identity, {}).get('balance')}
    ledger['accounts'] = list(known.values())
    store.write('ledger.json', ledger)
    return {'added': added, 'message': f'{source} connected. {added} new account(s) added. Use Sync to download transactions.'}


def authorization_status(attempt):
    import time
    if not isinstance(attempt, str) or not attempt:
        raise ValueError('Missing authorization attempt')
    result = store.read('connection-result.json', {})
    if result.get('attempt') == attempt:
        return {k: v for k, v in result.items() if k != 'attempt'}
    pending = store.read('connection-pending.json', {})
    if pending.get('attempt') != attempt:
        return {'status': 'error', 'message': 'This authorization was replaced. Start again.'}
    if time.time() - pending['created'] > 3600:
        return {'status': 'error', 'message': 'Authorization expired. Start again.'}
    return {'status': 'pending'}


def complete_callback(callback):
    import secrets
    from urllib.parse import urlparse, parse_qs
    with undo.action(store.PRIVATE, 'Connect bank account'):
        pending = store.read('connection-pending.json', {})
        state = parse_qs(urlparse(callback).query).get('state', [''])[0]
        if not pending.get('state') or not secrets.compare_digest(state, pending['state']):
            raise ValueError('Invalid or already completed authorization. Return to MoneyTracker.')
        # Only failures of the current, authenticated attempt reach the waiting app.
        try:
            result = finish(callback, automatic=True)
        except (ValueError, RuntimeError, requests.RequestException) as exc:
            message = str(exc) if isinstance(exc, ValueError) else 'Bank authorization could not be completed. Please start again.'
            store.write('connection-result.json', {'attempt': pending.get('attempt'), 'status': 'error', 'message': message})
            raise ValueError(message) from None
    # Publish success only after the undoable account update has committed.
    store.write('connection-result.json', {'attempt': pending.get('attempt'), 'status': 'complete', **result})
    return result
