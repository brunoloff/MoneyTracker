"""Persistent, compressed undo journal for local application data.

Actions stage writes before committing. A durable pending manifest makes a
multi-file commit/undo recoverable after interruption. Credentials are excluded.
"""
import contextlib
import datetime as dt
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import threading

LOCK = threading.RLock()
LOCAL = threading.local()
FILES = {'ledger.json','categories.json','merges.json','tags.json','taxonomy.json',
         'profiles.json','preferences.json','rules.json','paypal-observations.json',
         'paypal-associations.json','paypal-sync.json','exchange-rates.json'}

def tracked(name):
    return name in FILES or (name.startswith('raw-') and name.endswith('.json') and '/' not in name)

def sync_directory(path):
    fd = os.open(path,os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)

def atomic(path, data):
    if data is None:
        path.unlink(missing_ok=True)
        sync_directory(path.parent)
        return
    temp = path.with_name(path.name + '.undo-tmp')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd,'wb') as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())
    temp.replace(path)
    sync_directory(path.parent)

def connect(root):
    root = Path(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = root/'undo.sqlite3'
    db = sqlite3.connect(path)
    os.chmod(path,0o600)
    db.executescript('''
    CREATE TABLE IF NOT EXISTS blobs (id TEXT PRIMARY KEY, data BLOB NOT NULL);
    CREATE TABLE IF NOT EXISTS actions (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT NOT NULL,
      group_id TEXT, created TEXT NOT NULL, before_map TEXT NOT NULL, after_map TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), cursor INTEGER NOT NULL, pending TEXT);
    INSERT OR IGNORE INTO state VALUES(1,0,NULL);
    ''')
    return db

def digest(data):
    return hashlib.sha256(data).hexdigest() if data is not None else None

def blob(db,data):
    key = digest(data)
    if key is not None:
        db.execute('INSERT OR IGNORE INTO blobs VALUES(?,?)',(key,gzip.compress(data,compresslevel=3)))
    return key

def recover(root,db):
    pending = db.execute('SELECT pending FROM state WHERE id=1').fetchone()[0]
    if pending is None: return
    for name,key in json.loads(pending).items():
        if not tracked(name): raise ValueError('Invalid undo journal file')
        data = gzip.decompress(db.execute('SELECT data FROM blobs WHERE id=?',(key,)).fetchone()[0]) if key else None
        atomic(Path(root)/name,data)
    db.execute('UPDATE state SET pending=NULL WHERE id=1')
    db.commit()

def retention(root):
    path=Path(root)/'preferences.json'
    prefs=json.loads(path.read_bytes()) if path.exists() else {}
    value=prefs.get('undoLimit',100)
    return value if type(value) is int and 0 <= value <= 10000 else 100

def prune(root,db):
    limit=retention(root)
    if not limit: return
    excess=db.execute('SELECT id FROM actions ORDER BY id DESC LIMIT -1 OFFSET ?',(limit,)).fetchall()
    if not excess: return
    db.executemany('DELETE FROM actions WHERE id=?',excess)
    referenced=set()
    for before,after in db.execute('SELECT before_map,after_map FROM actions'):
        referenced.update(json.loads(before).values())
        referenced.update(json.loads(after).values())
    unused=[(key,) for (key,) in db.execute('SELECT id FROM blobs') if key not in referenced]
    db.executemany('DELETE FROM blobs WHERE id=?',unused)
    db.commit()

def read(root,name,default):
    active = getattr(LOCAL,'action',None)
    if active and active['root']==Path(root) and name in active['writes']:
        return json.loads(active['writes'][name])
    path=Path(root)/name
    return json.loads(path.read_bytes()) if path.exists() else default

@contextlib.contextmanager
def action(root,label,group_id=None):
    root=Path(root)
    if getattr(LOCAL,'action',None):
        yield
        return
    root.mkdir(mode=0o700,parents=True,exist_ok=True)
    # Serialize cooperating processes; the UI can read committed files during a download.
    fd=os.open(root/'undo.lock',os.O_CREAT|os.O_RDWR,0o600)
    with os.fdopen(fd,'a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        with LOCK, contextlib.closing(connect(root)) as db:
            recover(root,db)
        current={'root':root,'writes':{}}
        LOCAL.action=current
        try:
            yield
            with LOCK, contextlib.closing(connect(root)) as db:
                before,after={},{}
                for name,data in current['writes'].items():
                    path=root/name
                    old=path.read_bytes() if path.exists() else None
                    if old==data: continue
                    before[name]=blob(db,old)
                    after[name]=blob(db,data)
                if not after: return
                cursor=db.execute('SELECT cursor FROM state WHERE id=1').fetchone()[0]
                latest=db.execute('SELECT id,group_id,before_map,after_map FROM actions ORDER BY id DESC LIMIT 1').fetchone()
                if group_id and latest and latest[0]==cursor and latest[1]==group_id:
                    first=json.loads(latest[2]); final=json.loads(latest[3])
                    for name,key in before.items(): first.setdefault(name,key)
                    final.update(after)
                    db.execute('UPDATE actions SET before_map=?,after_map=? WHERE id=?',(json.dumps(first),json.dumps(final),cursor))
                else:
                    db.execute('DELETE FROM actions WHERE id>?',(cursor,))
                    cursor=db.execute('INSERT INTO actions(label,group_id,created,before_map,after_map) VALUES(?,?,?,?,?)',
                        (label,group_id,dt.datetime.now(dt.timezone.utc).isoformat(),json.dumps(before),json.dumps(after))).lastrowid
                db.execute('UPDATE state SET cursor=?,pending=? WHERE id=1',(cursor,json.dumps(after)))
                db.commit()
                recover(root,db)
                prune(root,db)
        finally:
            LOCAL.action=None

def write(root,name,value):
    data=json.dumps(value).encode()
    if not tracked(name):
        atomic(Path(root)/name,data)
        return
    if getattr(LOCAL,'action',None):
        LOCAL.action['writes'][name]=data
    else:
        with action(root,'Update '+name.removesuffix('.json').replace('-',' ')):
            LOCAL.action['writes'][name]=data

def status(root):
    with LOCK, contextlib.closing(connect(root)) as db:
        # Recovery is performed by startup or writers, never while another action downloads.
        cursor=db.execute('SELECT cursor FROM state WHERE id=1').fetchone()[0]
        previous=db.execute('SELECT label FROM actions WHERE id=?',(cursor,)).fetchone()
        following=db.execute('SELECT label FROM actions WHERE id>? ORDER BY id LIMIT 1',(cursor,)).fetchone()
        return {'undo':previous[0] if previous else None,'redo':following[0] if following else None, 'limit':retention(root), 'count':db.execute('SELECT COUNT(*) FROM actions').fetchone()[0]}

def restore(root,redo=False):
    root=Path(root)
    fd=os.open(root/'undo.lock',os.O_CREAT|os.O_RDWR,0o600)
    with os.fdopen(fd,'a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        with LOCK, contextlib.closing(connect(root)) as db:
            recover(root,db)
            cursor=db.execute('SELECT cursor FROM state WHERE id=1').fetchone()[0]
            row=db.execute('SELECT id,before_map,after_map FROM actions WHERE id>? ORDER BY id LIMIT 1',(cursor,)).fetchone() if redo else db.execute('SELECT id,before_map,after_map FROM actions WHERE id=?',(cursor,)).fetchone()
            if not row: raise ValueError('Nothing to redo' if redo else 'Nothing to undo')
            expected=json.loads(row[1] if redo else row[2])
            for name,key in expected.items():
                path=root/name
                if digest(path.read_bytes() if path.exists() else None)!=key:
                    raise ValueError('Data changed outside undo history; refusing to overwrite it')
            target=row[2] if redo else row[1]
            new_cursor=row[0] if redo else db.execute('SELECT COALESCE(MAX(id),0) FROM actions WHERE id<?',(row[0],)).fetchone()[0]
            db.execute('UPDATE state SET cursor=?,pending=? WHERE id=1',(new_cursor,target))
            db.commit()
            recover(root,db)
