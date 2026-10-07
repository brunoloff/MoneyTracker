"""Loopback-only service. Never serve the project root or private files."""
import argparse
import gzip
import json
import mimetypes
import secrets
import threading
import requests
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse
import store
import rules
import profiles
import paypal
import exchange_rates
import connections
import bank_callback
import undo
import contextlib
import version
from lifecycle import IdleServer

TOKEN = store.read('app-token.json', {}).get('token') or secrets.token_urlsafe(32)
store.write('app-token.json', {'token':TOKEN})
STATE = {'syncing': False, 'syncError': None, 'syncProgress': None}
LOCK = undo.LOCK
RUNNING_REVISION = version.revision(store.ROOT) if hasattr(store,'ROOT') else 'test'

def sync_job(years=None, target="banks", account_id=None, date_from=None):
    try:
        with undo.action(store.PRIVATE, 'Refresh Enable Banking accounts' if target == 'accounts' else 'Download exchange rates' if target == 'rates' else 'Sync PayPal' if target == 'paypal' else 'Download bank history' if years else 'Sync bank accounts'):
            if target == 'accounts':
                STATE['accountRefresh'] = connections.refresh(progress=lambda message: STATE.update(syncProgress=message))
            elif target == 'rates':
                exchange_rates.download(progress=lambda message: STATE.update(syncProgress=message))
            elif target == 'paypal':
                paypal.sync(progress=lambda message: STATE.update(syncProgress=message), date_from=date_from)
            else:
                store.sync(years=years, account_id_filter=account_id, progress=lambda message: STATE.update(syncProgress=message))
        STATE['syncError'] = None
    except Exception as exc:
        STATE['syncError'] = str(exc)
    finally:
        STATE['syncing'] = False
        STATE['syncProgress'] = None

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def send(self, status, data, content_type='application/json', cookie=False):
        # Static files are already encoded, including Flutter's JSON manifests.
        body = data if isinstance(data, bytes) else json.dumps(data).encode()
        compressed = False
        headers = getattr(self, 'headers', {})
        encodings = headers.get('Accept-Encoding', '')
        accepts_gzip = any(part.strip() == 'gzip' for part in encodings.split(','))
        if len(body) > 1024 and content_type == 'application/json' and accepts_gzip:
            body = gzip.compress(body, compresslevel=1)
            compressed = True
        if status < 400 and getattr(self, 'path', '') != '/api/health' and hasattr(getattr(self, 'server', None), 'touch'):
            self.server.touch()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Vary', 'Accept-Encoding')
        if compressed: self.send_header('Content-Encoding', 'gzip')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        if cookie: self.send_header('Set-Cookie', f'moneytracker={TOKEN}; HttpOnly; SameSite=Strict; Path=/')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def trusted_host(self):
        return self.headers.get('Host') in {f'localhost:{self.server.server_port}', f'127.0.0.1:{self.server.server_port}'}
    def authenticated(self):
        cookie = SimpleCookie()
        try: cookie.load(self.headers.get('Cookie',''))
        except Exception: return False
        candidate = cookie['moneytracker'].value if 'moneytracker' in cookie else ''
        native = self.headers.get('Authorization','').removeprefix('Bearer ')
        return secrets.compare_digest(candidate, TOKEN) or secrets.compare_digest(native, TOKEN)
    def do_GET(self):
        if not self.trusted_host(): return self.send(403, {'error':'Invalid host'})
        path = urlparse(self.path).path
        if path == '/api/health':
            return self.send(200, {'app': 'moneytracker', 'protocol': 1, 'revision':RUNNING_REVISION})
        if path == '/api/ledger':
            if not self.authenticated(): return self.send(401, {'error':'Open MoneyTracker from its local home page.'})
            with LOCK:
                return self.send(200, {**store.client_snapshot(), **STATE, 'undoHistory':undo.status(store.PRIVATE)})
        if path == '/api/status':
            if not self.authenticated(): return self.send(401, {'error':'Open MoneyTracker from its local home page.'})
            return self.send(200, STATE)
        if path.startswith('/api/'): return self.send(404, {'error':'Not found'})
        root = self.server.web_root.resolve()
        target = (root / unquote(path).lstrip('/')).resolve()
        if not target.is_relative_to(root): return self.send(403, {'error':'Forbidden'})
        if target.is_dir(): target = target / 'index.html'
        if not target.is_file(): return self.send(404, {'error':'Not found'})
        self.send(200, target.read_bytes(), mimetypes.guess_type(target.name)[0] or 'application/octet-stream', cookie=path in ['/', '/index.html'])
    def do_POST(self):
        if not self.trusted_host() or not self.authenticated(): return self.send(403, {'error':'Unauthorized'})
        origin = self.headers.get('Origin')
        if origin and origin not in {f'http://localhost:{self.server.server_port}', f'http://127.0.0.1:{self.server.server_port}'}:
            return self.send(403, {'error':'Invalid origin'})
        if self.headers.get('Content-Type','').split(';')[0] != 'application/json':
            return self.send(415, {'error':'JSON required'})
        try:
            length = int(self.headers.get('Content-Length','0'))
            if length > (1048576 if self.path == '/api/paypal/confirm' else 1048576 if self.path.startswith('/api/rules/') or self.path == '/api/taxonomy' else 8192) or length < 0: return self.send(413, {'error':'Request too large'})
            body = json.loads(self.rfile.read(length) or b'{}')
            if STATE['syncing'] and self.path not in ('/api/keepalive','/api/paypal/review','/api/rules/preview','/api/connections/status'):
                return self.send(409, {'error':'Wait for the current sync to finish before changing data or undoing'})
            labels = {'/api/connections/finish':'Connect bank account', '/api/rules/save':'Save classification rule','/api/rules/delete':'Delete classification rule',
                '/api/rules/move':'Reorder classification rules','/api/taxonomy':'Edit categories and tags',
                '/api/tags':'Edit payment tags','/api/category':'Change payment category',
                '/api/paypal/confirm':'Confirm PayPal associations','/api/merge':'Merge payments',
                '/api/unmerge':'Unmerge payments','/api/profiles':'Edit users and accounts','/api/preferences':'Change preferences'}
            group = body.get('actionId') if self.path == '/api/paypal/confirm' else None
            if group is not None and (not isinstance(group,str) or not 1 <= len(group) <= 80): raise ValueError('Invalid action ID')
            if self.path in ('/api/undo','/api/redo'):
                undo.restore(store.PRIVATE,redo=self.path == '/api/redo')
                return self.send(200, {'ok':True})
            context = undo.action(store.PRIVATE,labels[self.path],group) if self.path in labels else contextlib.nullcontext()
            with context, LOCK:
                if self.path == '/api/restart':
                    self.send(200, {'ok':True})
                    threading.Thread(target=self.server.shutdown, daemon=True).start()
                    return
                elif self.path == '/api/connections/banks':
                    return self.send(200, {'banks': connections.institutions(body.get('country'))})
                elif self.path == '/api/connections/status':
                    return self.send(200, connections.authorization_status(body.get('attempt')))
                elif self.path == '/api/connections/start':
                    if self.server.callback_error:
                        raise ValueError(self.server.callback_error)
                    return self.send(200, connections.start(body))
                elif self.path == '/api/connections/finish':
                    result = connections.finish(body.get('callback'))
                    # Let the action commit before reporting success.
                elif self.path == '/api/keepalive':
                    return self.send(200, {'ok': True})
                elif self.path == '/api/rules/preview':
                    rule = rules.validate(body['rule'], store.category_ids(), [t['id'] for t in store.classification_settings()['tags']])
                    rule['enabled'] = True
                    current = store.snapshot()
                    roots = {c['id']: c.get('parent') or c['id'] for c in current['taxonomy']['categories']}
                    ordered = current['rules']
                    earlier = ordered[:next((i for i, r in enumerate(ordered) if r['id'] == rule['id']), len(ordered))]
                    matches = []
                    for row in current['transactions']:
                        if store.rule_matches(rule, row, roots):
                            reason = ('Manual category' if row['reviewed'] else ('Earlier rule' if any(r.get('category') and store.rule_matches(r, row, roots) for r in earlier) else None)) if rule.get('category') else None
                            matches.append({'id': row['id'], 'description': row['description'], 'date': row['date'], 'amount': row['amount'], 'category': row['category'], 'blockedBy': reason})
                    return self.send(200, {'matches': matches, 'category': rule['category']})
                elif self.path == '/api/rules/save':
                    rule = rules.validate(body['rule'], store.category_ids(), [t['id'] for t in store.classification_settings()['tags']])
                    ordered = store.read('rules.json', [])
                    index = next((i for i, r in enumerate(ordered) if r['id'] == rule['id']), len(ordered))
                    if rule.get('kind') == 'category':
                        ordered = rules.save_category(ordered, rule)
                    elif index == len(ordered):
                        if len(ordered) >= 300: raise ValueError('Too many rules')
                        ordered.append(rule)
                    else: ordered[index] = rule
                    store.write('rules.json', ordered)
                elif self.path == '/api/rules/delete':
                    store.write('rules.json', [{**r, 'groups': []} if r.get('kind') == 'category' and r['id'] == body['id'] else r for r in store.read('rules.json', []) if r['id'] != body['id'] or r.get('kind') == 'category'])
                elif self.path == '/api/rules/move':
                    ordered = store.read('rules.json', [])
                    index = next(i for i, r in enumerate(ordered) if r['id'] == body['id'])
                    delta = body['delta']
                    if delta not in (-1, 1) or not 0 <= index + delta < len(ordered): raise ValueError('Invalid move')
                    ordered[index], ordered[index + delta] = ordered[index + delta], ordered[index]
                    store.write('rules.json', ordered)
                elif self.path == '/api/taxonomy':
                    store.save_taxonomy(body)
                elif self.path == '/api/tags':
                    payment = next((r for r in store.snapshot()['transactions'] if r['id'] == body.get('id')), None)
                    allowed = {t['id'] for t in store.classification_settings()['tags']}
                    values = body.get('tags')
                    if not payment or not isinstance(values, list) or not all(isinstance(t, str) and t in allowed for t in values): raise ValueError('Invalid tags')
                    saved = store.read('tags.json', {})
                    # Replace the combined payment's tags without changing its linked observations.
                    for identity in [payment['id']] + store.read('merges.json', {}).get(payment['id'], []): saved[identity] = []
                    saved[payment['id']] = sorted(set(values))
                    store.write('tags.json', saved)
                elif self.path == '/api/category':
                    row = next((t for t in store.snapshot()['transactions'] if t['id']==body.get('id')), None)
                    category = body.get('category')
                    if not row or category not in store.category_ids(): return self.send(400, {'error':'Invalid payment or category'})
                    if store.root_category(category) in ['Salary','Other income'] and row['amount'] <= 0: return self.send(400, {'error':'Income category requires an incoming payment'})
                    data = store.read('categories.json', {})
                    data[row['id']] = category
                    store.write('categories.json', data)
                elif self.path == '/api/paypal/review':
                    return self.send(200, paypal.review(str(body.get('query', '')), body.get('observationId')))
                elif self.path == '/api/paypal/confirm':
                    paypal.confirm(body['pairs'])
                elif self.path == '/api/merge':
                    store.merge(body['primaryId'], body['secondaryId'])
                elif self.path == '/api/unmerge':
                    store.unmerge(body['id'])
                elif self.path == '/api/profiles':
                    accounts = {a['id'] for a in store.snapshot().get('accounts', [])}
                    existing = store.read('profiles.json', {})
                    config = profiles.validate({**body, 'accountNicknames': body.get('accountNicknames', existing.get('accountNicknames', {}))}, accounts)
                    store.write('profiles.json', config)
                    prefs = store.read('preferences.json', {'period': 'month'})
                    if prefs.get('selectedUser', 'all') not in {'all', 'unassigned', *(u['id'] for u in config['users'])}:
                        prefs['selectedUser'] = 'all'
                        store.write('preferences.json', prefs)
                elif self.path == '/api/preferences':
                    prefs = store.read('preferences.json', {'period': 'month'})
                    if 'period' in body:
                        if body['period'] not in ['month', 'salary']: return self.send(400, {'error': 'Invalid period'})
                        prefs['period'] = body['period']
                    if 'selectedUser' in body:
                        users = store.read('profiles.json', {'users': []})['users']
                        if body['selectedUser'] not in {'all', 'unassigned', *(u['id'] for u in users)}: return self.send(400, {'error': 'Invalid user'})
                        prefs['selectedUser'] = body['selectedUser']
                    if 'periodCount' in body:
                        count = body['periodCount']
                        if type(count) is not int or not 1 <= count <= 24: return self.send(400, {'error': 'Choose 1 to 24 periods'})
                        prefs['periodCount'] = count
                    if 'undoLimit' in body:
                        value = body['undoLimit']
                        if type(value) is not int or not 0 <= value <= 10000: raise ValueError('Choose 0 (unlimited) to 10000 undo steps')
                        prefs['undoLimit'] = value
                    if 'fxTolerancePercent' in body:
                        value = body['fxTolerancePercent']
                        if type(value) not in (int, float) or not 0 <= value <= 100: raise ValueError('Choose a tolerance from 0 to 100 percent')
                        prefs['fxTolerancePercent'] = value
                    if 'monthlyAverage' in body:
                        if type(body['monthlyAverage']) is not bool: return self.send(400, {'error': 'Invalid average setting'})
                        prefs['monthlyAverage'] = body['monthlyAverage']
                    store.write('preferences.json', prefs)
                elif self.path in ('/api/sync', '/api/history', '/api/paypal/sync'):
                    years = body.get('years') if self.path == '/api/history' else None
                    if self.path == '/api/history': store.history_start(years)
                    target = 'paypal' if self.path == '/api/paypal/sync' else body.get('target', 'banks')
                    if target not in ('banks', 'paypal', 'rates', 'accounts'): raise ValueError('Unknown sync source')
                    date_from = paypal.validate_start(body.get('dateFrom')) if target == 'paypal' else None
                    if not STATE['syncing']:
                        STATE['syncing'] = True
                        STATE['syncError'] = None
                        if target == 'accounts': STATE['accountRefresh'] = None
                        STATE['syncProgress'] = 'Starting bank download…'
                        threading.Thread(target=sync_job, args=(years, target, body.get("accountId"), date_from), daemon=True).start()
                    return self.send(202, STATE)
                else: return self.send(404, {'error':'Not found'})
            self.send(200, {'ok':True, **(result if self.path == '/api/connections/finish' else {}), 'undoHistory':undo.status(store.PRIVATE)})
        except ValueError as exc: self.send(400, {'error': str(exc)})
        except (RuntimeError, requests.RequestException) as exc: self.send(502, {'error': str(exc)})
        except (KeyError, TypeError, StopIteration, AttributeError): self.send(400, {'error':'Invalid request'})

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--web-root', type=Path, default=store.ROOT/'app/build/web')
    parser.add_argument('--idle-minutes', type=float, default=30)
    args = parser.parse_args()
    if not 0 < args.idle_minutes < float('inf'): parser.error('--idle-minutes must be positive and finite')
    with undo.action(store.PRIVATE, 'Initialize history'):
        pass
    server = IdleServer(('127.0.0.1', args.port), Handler, idle_seconds=args.idle_minutes * 60, busy=lambda: STATE['syncing'])
    server.web_root = args.web_root
    callback_server = None
    server.callback_error = None
    try:
        callback_server = bank_callback.start(server)
    except (OSError, ValueError) as exc:
        server.callback_error = 'The local HTTPS callback could not start on port 8443. Close any other service using that port and reopen MoneyTracker.'
        print(server.callback_error, flush=True)
    print(f'MoneyTracker: http://localhost:{args.port}', flush=True)
    try:
        server.serve_forever()
    finally:
        if callback_server is not None:
            callback_server.shutdown()
            callback_server.server_close()
        server.server_close()
