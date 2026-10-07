#!/usr/bin/env python3
"""Single-instance Linux desktop launcher. No compilation or bank sync on launch."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import urllib.error
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = ROOT / '.private'
URL = 'http://localhost:8765/'
sys.path.insert(0,str(ROOT/'server'))
from version import revision


def request(path, body=None):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    headers={}
    if path != 'api/health':
        token=json.loads((PRIVATE/'app-token.json').read_text())['token']
        headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'}
    req=urllib.request.Request(URL+path,data=json.dumps(body).encode() if body is not None else None,headers=headers)
    with opener.open(req,timeout=3) as response: return json.load(response)

def health():
    try:
        data=request('api/health')
        return data if isinstance(data,dict) and data.get('app')=='moneytracker' and data.get('protocol')==1 else None
    except (OSError,ValueError): return None

def ready():
    return health() is not None

def legacy_server_pid(proc=Path('/proc')):
    # One-time upgrade for old servers without the restart API. Verify both the
    # exact project script and ownership of the listening socket before signalling.
    sockets=set()
    for line in (proc/'net/tcp').read_text().splitlines()[1:]:
        fields=line.split()
        if fields[1]=='0100007F:223D' and fields[3]=='0A': sockets.add(fields[9])
    matches=[]
    for entry in proc.iterdir():
        if not entry.name.isdigit(): continue
        try:
            args=(entry/'cmdline').read_bytes().decode().split('\0')
            cwd=(entry/'cwd').resolve()
            if not any(arg and (cwd/arg).resolve()==(ROOT/'server/main.py').resolve() for arg in args[1:]): continue
            if not any(os.readlink(fd) in {'socket:['+s+']' for s in sockets} for fd in (entry/'fd').iterdir()): continue
            matches.append(int(entry.name))
        except (OSError,ValueError): continue
    if len(matches)!=1: raise RuntimeError('Cannot identify the old MoneyTracker server safely. Close its terminal once, then reopen this icon.')
    return matches[0]

def stop_outdated(info):
    for _ in range(240):
        if not request('api/status').get('syncing'): break
        time.sleep(0.5)
    else: raise RuntimeError('A sync is still running. Reopen MoneyTracker after it finishes to apply the update.')
    if info.get('revision'):
        request('api/restart',{})
    else:
        os.kill(legacy_server_pid(),signal.SIGTERM)
    for _ in range(80):
        if not ready(): return
        time.sleep(0.25)
    raise RuntimeError('MoneyTracker has not finished stopping. Please try the icon again shortly.')


def start_server():
    PRIVATE.mkdir(mode=0o700, exist_ok=True)
    # Serialize double-clicks; the server also holds its port exclusively.
    with (PRIVATE / 'launcher.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current=health()
        if current:
            if current.get('revision') == revision(ROOT): return
            stop_outdated(current)
        if not (ROOT / 'app/build/web/main.dart.js').is_file():
            raise RuntimeError('The web build is missing. Build MoneyTracker first; see README.md.')
        log_path = PRIVATE / 'server.log'
        fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, 'ab') as log:
            process = subprocess.Popen(
                [sys.executable, str(ROOT / 'server/main.py')], cwd=ROOT,
                stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                start_new_session=True, close_fds=True,
            )
        for _ in range(60):
            if ready():
                return
            if process.poll() is not None:
                break
            time.sleep(0.25)
        if process.poll() is None:
            process.terminate()
        raise RuntimeError(f'MoneyTracker could not start. See {log_path}. Another app may be using port 8765.')


def open_browser():
    browser = shutil.which('firefox-developer-edition') or shutil.which('xdg-open')
    if not browser:
        raise RuntimeError(f'No default-browser launcher found. Open {URL} manually.')
    subprocess.Popen([browser, URL], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)


def main():
    try:
        start_server()
        open_browser()
    except Exception as exc:
        message = str(exc)
        print(message, file=sys.stderr)
        if shutil.which('notify-send'):
            subprocess.run(['notify-send', '--urgency=critical', 'MoneyTracker', message], check=False)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
