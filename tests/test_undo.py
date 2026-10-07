import json
from contextlib import closing
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
import undo
import store
import paypal

class UndoTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
    def read(self,name): return undo.read(self.root,name,None)
    def test_multifile_sync_undo_redo_persists_and_removes_new_files(self):
        (self.root/'ledger.json').write_text('{"old":1}')
        with undo.action(self.root,'Sync bank accounts'):
            undo.write(self.root,'ledger.json',{'new':2})
            undo.write(self.root,'raw-1.json',[3])
            self.assertEqual(self.read('ledger.json'),{'new':2})
            self.assertEqual(json.loads((self.root/'ledger.json').read_text()),{'old':1})
        self.assertEqual(undo.status(self.root)['undo'],'Sync bank accounts')
        undo.restore(self.root)
        self.assertEqual(self.read('ledger.json'),{'old':1})
        self.assertFalse((self.root/'raw-1.json').exists())
        self.assertEqual(undo.status(self.root)['redo'],'Sync bank accounts')
        undo.restore(self.root,redo=True)
        self.assertEqual(self.read('ledger.json'),{'new':2})
        self.assertEqual(self.read('raw-1.json'),[3])
    def test_failed_action_leaves_no_partial_changes(self):
        with self.assertRaises(ValueError):
            with undo.action(self.root,'Failed sync'):
                undo.write(self.root,'ledger.json',{'partial':True})
                raise ValueError('provider failed')
        self.assertIsNone(self.read('ledger.json'))
        self.assertIsNone(undo.status(self.root)['undo'])
    def test_confirmation_batches_are_one_action(self):
        for data in [{'a':'b'},{'a':'b','c':'d'}]:
            with undo.action(self.root,'Confirm PayPal associations','group-1'):
                undo.write(self.root,'paypal-associations.json',data)
        undo.restore(self.root)
        self.assertIsNone(self.read('paypal-associations.json'))
        self.assertIsNone(undo.status(self.root)['undo'])
        undo.restore(self.root,redo=True)
        self.assertEqual(self.read('paypal-associations.json'),{'a':'b','c':'d'})
    def test_branch_after_undo_drops_redo_and_noop_does_not(self):
        undo.write(self.root,'preferences.json',{'x':1})
        undo.write(self.root,'preferences.json',{'x':2})
        undo.restore(self.root)
        undo.write(self.root,'preferences.json',{'x':1})
        self.assertIsNotNone(undo.status(self.root)['redo'])
        undo.write(self.root,'preferences.json',{'x':3})
        self.assertIsNone(undo.status(self.root)['redo'])
        undo.restore(self.root)
        self.assertEqual(self.read('preferences.json'),{'x':1})
    def test_credentials_not_restored_or_journaled(self):
        with undo.action(self.root,'Update'):
            undo.write(self.root,'session.json',{'token':'new'})
            undo.write(self.root,'rules.json',[])
        undo.restore(self.root)
        self.assertEqual(self.read('session.json'),{'token':'new'})
        with closing(undo.connect(self.root)) as db:
            self.assertNotIn('token',str(db.execute('SELECT before_map,after_map FROM actions').fetchall()))
    def test_recover_interrupted_multifile_commit(self):
        atomic=undo.atomic
        def interrupted(path,data):
            if path.name=='tags.json': raise OSError('interrupted')
            atomic(path,data)
        with patch.object(undo,'atomic',side_effect=interrupted), self.assertRaises(OSError):
            with undo.action(self.root,'Edit two files'):
                undo.write(self.root,'rules.json',[1])
                undo.write(self.root,'tags.json',{'x':['y']})
        with closing(undo.connect(self.root)) as db: undo.recover(self.root,db)
        self.assertEqual(self.read('tags.json'),{'x':['y']})
        undo.restore(self.root)
        self.assertIsNone(self.read('rules.json'))
        self.assertIsNone(self.read('tags.json'))
    def test_external_changes_not_overwritten(self):
        undo.write(self.root,'rules.json',[1])
        (self.root/'rules.json').write_text('[2]')
        with self.assertRaisesRegex(ValueError,'outside undo history'): undo.restore(self.root)
        self.assertEqual(self.read('rules.json'),[2])
    def test_real_paypal_sync_and_confirmation_roundtrip(self):
        raw=dict(entry_reference='ref',credit_debit_indicator='DBIT',creditor={'name':'Shop'},transaction_date='2026-09-08',transaction_amount={'amount':'25.00','currency':'EUR'},status='BOOK')
        (self.root/'session-paypal.json').write_text(json.dumps({'accounts':[{'uid':'u','identification_hash':'stable'}]}))
        with patch.object(store,'PRIVATE',self.root), patch.object(store,'api',return_value={'transactions':[raw]}):
            with undo.action(self.root,'Sync PayPal'): paypal.sync(date_from='2026-09-01')
            self.assertEqual(len(store.read('paypal-observations.json',{})),1)
            undo.restore(self.root)
            self.assertEqual(store.read('paypal-observations.json',{}),{})
            self.assertEqual(store.read('paypal-sync.json',{}),{})
            undo.restore(self.root,redo=True)
            self.assertEqual(len(store.read('paypal-observations.json',{})),1)
    def test_retention_prunes_old_steps_and_unused_blobs(self):
        (self.root/'preferences.json').write_text('{"undoLimit":2}')
        for i in range(5): undo.write(self.root,'rules.json',[i])
        self.assertEqual(undo.status(self.root)['count'],2)
        undo.restore(self.root);undo.restore(self.root)
        self.assertEqual(self.read('rules.json'),[2])
        with self.assertRaises(ValueError):undo.restore(self.root)
        with closing(undo.connect(self.root)) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM blobs').fetchone()[0],3)
        undo.restore(self.root,redo=True)
        self.assertEqual(self.read('rules.json'),[3])
    def test_unlimited_and_reducing_limit(self):
        (self.root/'preferences.json').write_text('{"undoLimit":0}')
        for i in range(105):undo.write(self.root,'rules.json',[i])
        self.assertEqual(undo.status(self.root)['count'],105)
        undo.write(self.root,'preferences.json',{'undoLimit':10})
        self.assertEqual(undo.status(self.root)['count'],10)
        undo.restore(self.root)
        self.assertEqual(undo.status(self.root)['limit'],0)
        self.assertEqual(undo.status(self.root)['count'],10)

    def test_every_persisted_app_dataset_is_reversible(self):
        for name in undo.FILES:
            with self.subTest(name=name):
                undo.write(self.root,name,{'example':1})
                undo.restore(self.root)
                self.assertIsNone(self.read(name))
                undo.restore(self.root,redo=True)
                self.assertEqual(self.read(name),{'example':1})


class UndoApiTests(unittest.TestCase):
    def setUp(self):
        import importlib.util
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.scope=patch.object(store,'PRIVATE',self.root);self.scope.start();self.addCleanup(self.scope.stop)
        spec=importlib.util.spec_from_file_location('undo_api_test_server',Path(__file__).resolve().parents[1]/'server/main.py')
        self.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.module)
    def post(self,path,body):
        import io
        from unittest.mock import Mock
        handler=object.__new__(self.module.Handler)
        raw=json.dumps(body).encode()
        handler.path=path
        handler.headers={'Content-Type':'application/json','Content-Length':str(len(raw))}
        handler.rfile=io.BytesIO(raw)
        handler.trusted_host=lambda:True
        handler.authenticated=lambda:True
        handler.send=Mock()
        handler.do_POST()
        return handler.send.call_args.args
    def test_preferences_api_records_undo_redo(self):
        status,result=self.post('/api/preferences',{'period':'salary'})
        self.assertEqual(status,200)
        self.assertEqual(result['undoHistory']['undo'],'Change preferences')
        self.assertEqual(self.post('/api/undo',{})[0],200)
        self.assertIsNone(store.read('preferences.json',None))
        self.assertEqual(self.post('/api/redo',{})[0],200)
        self.assertEqual(store.read('preferences.json',{})['period'],'salary')
    def test_sync_job_one_action_and_failure_rollback(self):
        def fetch(**kwargs):
            store.write('ledger.json',{'transactions':[]})
            store.write('raw-1.json',[1])
        with patch.object(store,'sync',side_effect=fetch): self.module.sync_job()
        self.assertEqual(undo.status(self.root)['undo'],'Sync bank accounts')
        undo.restore(self.root)
        self.assertIsNone(store.read('ledger.json',None))
        def failed(**kwargs):
            fetch()
            raise ValueError('bank offline')
        with patch.object(store,'sync',side_effect=failed): self.module.sync_job()
        self.assertEqual(self.module.STATE['syncError'],'bank offline')
        self.assertIsNone(store.read('ledger.json',None))
        self.assertIsNone(undo.status(self.root)['undo'])
    def test_mutations_rejected_while_syncing(self):
        self.module.STATE['syncing']=True
        self.assertEqual(self.post('/api/undo',{})[0],409)
        self.assertEqual(self.post('/api/preferences',{'period':'salary'})[0],409)
