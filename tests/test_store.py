import sys, unittest, tempfile
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'server'))
import store
class StoreTests(unittest.TestCase):
 def raw(self,**kw):
  return {'entry_reference':'ref','transaction_amount':{'amount':'12.34','currency':'EUR'},'credit_debit_indicator':'DBIT','booking_date':'2026-09-27','transaction_date':'2026-09-25','remittance_information':['PINGO DOCE'],'status':'BOOK',**kw}
 def test_exact_money_and_transaction_date(self):
  p=store.normalize(self.raw(),'account');self.assertEqual(p['amount'],-1234);self.assertEqual(p['date'],'2026-09-25');self.assertEqual(p['category'],'Food');self.assertFalse(p['reviewed'])
 def test_id_scoped_to_account(self):
  self.assertNotEqual(store.normalize(self.raw(),'a')['id'],store.normalize(self.raw(),'b')['id'])
 def test_income_is_not_automatically_salary(self):
  self.assertEqual(store.normalize(self.raw(credit_debit_indicator='CRDT'),'a')['category'],'Other income')
 def test_currency_not_silently_mixed(self):
  with self.assertRaises(ValueError):store.normalize(self.raw(transaction_amount={'amount':'1','currency':'USD'}),'a')
 def test_category_override_survives_snapshot(self):
  row=store.normalize(self.raw(),'a')
  def read(name,default):return {'transactions':[row.copy()]} if name=='ledger.json' else {row['id']:'Rent'} if name=='categories.json' else default
  with patch.object(store,'read',side_effect=read):
   result=store.snapshot()['transactions'][0];self.assertEqual(result['category'],'Rent');self.assertTrue(result['reviewed'])
if __name__=='__main__':unittest.main()

class MergeTests(unittest.TestCase):
 def setUp(self):
  self.data={'ledger.json':{'accounts':[],'transactions':[
   {'id':'a','accountId':'one','description':'Bank purchase','category':'Other','source':'CGD','date':'2026-09-25','amount':-1234,'currency':'EUR','status':'BOOK','reviewed':False},
   {'id':'b','accountId':'two','description':'PayPal item','category':'Shopping','source':'PayPal','date':'2026-09-24','amount':-1234,'currency':'EUR','status':'BOOK','reviewed':False}]}}
  import copy
  self.r=patch.object(store,'read',side_effect=lambda n,d:copy.deepcopy(self.data.get(n,d)))
  self.w=patch.object(store,'write',side_effect=lambda n,v:self.data.__setitem__(n,copy.deepcopy(v)))
  self.r.start();self.w.start();self.addCleanup(self.r.stop);self.addCleanup(self.w.stop)
 def test_merge_counts_once_and_preserves_both_sources(self):
  store.merge('a','b');rows=store.snapshot()['transactions'];self.assertEqual(len(rows),1);self.assertEqual(rows[0]['amount'],-1234);self.assertEqual(len(rows[0]['sourceRecords']),2);self.assertEqual(rows[0]['accountIds'],['one','two']);self.assertEqual(len(self.data['ledger.json']['transactions']),2)
 def test_undo_restores_original_records_and_categories(self):
  store.merge('a','b');store.unmerge('a');rows=store.snapshot()['transactions'];self.assertEqual(len(rows),2);self.assertEqual(rows[1]['category'],'Shopping')
 def test_rejects_incompatible_amounts(self):
  self.data['ledger.json']['transactions'][1]['amount']=-1300
  with self.assertRaises(ValueError):store.merge('a','b')
 def test_identity_survives_session_renewal(self):
  self.assertEqual(store.stable_account_id({'uid':'old','identification_hash':'same'}),store.stable_account_id({'uid':'new','identification_hash':'same'}))

class ClientSnapshotTests(unittest.TestCase):
 def test_compact_response_preserves_linked_descriptions_and_storage(self):
  import copy
  source={'id':'x','provider':'cgd_xlsx','description':'Original merchant','sha256':'audit','bankCategory':'COMPRAS'}
  ledger={'transactions':[{'id':'x','accountId':'a','date':'2024-01-01','amount':-100,'currency':'EUR','description':'Original merchant','category':'Other','source':'CGD','status':'BOOK','sourceRecord':source}], 'fileImports':[{'audit':'keep'}]}
  before=copy.deepcopy(ledger)
  with patch.object(store,'read',side_effect=lambda n,d:copy.deepcopy(ledger if n=='ledger.json' else d)):
   result=store.client_snapshot()
  self.assertEqual(ledger,before)
  row=result['transactions'][0]
  self.assertNotIn('sourceRecord',row)
  self.assertNotIn('fileImports',result)
  self.assertEqual(row['sourceRecords'][0]['description'],'Original merchant')
  self.assertNotIn('sha256',row['sourceRecords'][0])
