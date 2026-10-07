import copy
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
import paypal
import store

class PayPalTests(unittest.TestCase):
    def setUp(self):
        self.bank = dict(id='bank',accountId='b',date='2026-09-10',description='PayPal Europe',amount=-2500,currency='EUR',status='BOOK',source='CGD',category='Other')
        self.observation = dict(id='pp',accountId='p',date='2026-09-08',description='Merchant',amount=-2500,currency='EUR',status='BOOK',institution='PayPal')
        self.data = {'ledger.json':{'accounts':[],'transactions':[self.bank]},'paypal-observations.json':{'pp':self.observation}}
        self.r=patch.object(store,'read',side_effect=lambda n,d:copy.deepcopy(self.data.get(n,d)))
        self.w=patch.object(store,'write',side_effect=lambda n,v:self.data.__setitem__(n,copy.deepcopy(v)))
        self.r.start();self.w.start();self.addCleanup(self.r.stop);self.addCleanup(self.w.stop)
    def test_exact_review_and_confirm_preserves_total_and_sources(self):
        self.assertEqual(paypal.review()['rows'][0]['rule'],'exact')
        paypal.confirm([{'observationId':'pp','bankId':'bank'}])
        self.assertEqual(paypal.review()['rows'],[])
        rows=store.snapshot()['transactions']
        self.assertEqual(len(rows),1);self.assertEqual(rows[0]['amount'],-2500)
        self.assertEqual(rows[0]['description'],'Merchant');self.assertEqual(len(rows[0]['sourceRecords']),2)
        self.assertEqual(self.bank['description'],'PayPal Europe')
    def test_fx_keeps_bank_amount_currency(self):
        self.data['exchange-rates.json']={'rates':{'2026-09-08':{'EUR':'1','USD':'1.1'}}}
        self.observation['currency']='USD'
        self.bank['amount']=-2245
        self.assertEqual(paypal.review()['rows'][0]['rule'],'fx')
        paypal.confirm([{'observationId':'pp','bankId':'bank'}])
        row=store.snapshot()['transactions'][0]
        self.assertEqual((row['amount'],row['currency']),(-2245,'EUR'))
        self.assertEqual(row['sourceRecords'][-1]['currency'],'USD')
    def test_nonpaypal_wrong_owner_pending_wrong_sign_excluded(self):
        for field,value in [('description','Other merchant'),('status','PDNG'),('amount',2500)]:
            old=self.bank[field];self.bank[field]=value
            self.assertEqual(paypal.review()['rows'][0]['candidates'],[])
            self.bank[field]=old
        self.data['profiles.json']={'accountUsers':{'b':'alice','p':'bob'}}
        self.assertEqual(paypal.review()['rows'][0]['candidates'],[])
    def test_competing_exact_not_strong_and_duplicate_confirmation_atomic(self):
        self.data['paypal-observations.json']['pp2']={**self.observation,'id':'pp2'}
        self.assertTrue(all(r['rule']=='unmatched' for r in paypal.review()['rows']))
        with self.assertRaises(ValueError):
            paypal.confirm([{'observationId':'pp','bankId':'bank'},{'observationId':'pp2','bankId':'bank'}])
        self.assertNotIn('paypal-associations.json',self.data)
    def test_search_and_date_limit(self):
        self.assertEqual(len(paypal.review('25.00')['rows'][0]['candidates']),1)
        self.bank['date']='2026-10-20'
        self.assertEqual(paypal.review()['rows'][0]['candidates'],[])
    def test_single_bank_sync_preserves_other_account_pending(self):
        session_accounts=[{'uid':'u1','identification_hash':'first'},{'uid':'u2','identification_hash':'second'}]
        first,second=[store.stable_account_id(a) for a in session_accounts]
        self.data['session.json']={'accounts':session_accounts}
        self.data['ledger.json']={'accounts':[{'id':first,'label':'First'},{'id':second,'label':'Second'}],
            'transactions':[{**self.bank,'accountId':second,'status':'PDNG','date':store.dt.date.today().isoformat()}]}
        calls=[]
        def api(path):
            calls.append(path)
            return {'balances':[]} if path.endswith('/balances') else {'transactions':[]}
        with patch.object(store,'api',side_effect=api): store.sync(account_id_filter=first)
        self.assertTrue(all('/u1/' in path for path in calls))
        self.assertEqual(len(self.data['ledger.json']['transactions']),1)
        self.assertEqual(len(self.data['ledger.json']['accounts']),2)

    def test_more_than_100_associations_in_one_confirmation(self):
        pairs=[{'observationId':f'p{i}', 'bankId':f'b{i}'} for i in range(120)]
        rows=[{'observation':{'id':p['observationId']},'candidates':[{'id':p['bankId']}]} for p in pairs]
        with patch.object(paypal,'review',return_value={'rows':rows}): paypal.confirm(pairs)
        self.assertEqual(len(self.data['paypal-associations.json']),120)

    def test_requested_history_range_and_actual_coverage(self):
        self.data['session-paypal.json']={'accounts':[{'uid':'u','identification_hash':'stable'}]}
        raw=dict(entry_reference='ref',credit_debit_indicator='DBIT',creditor={'name':'Shop'},transaction_date='2026-09-08',transaction_amount={'amount':'25.00','currency':'EUR'},status='BOOK')
        with patch.object(store,'api',return_value={'transactions':[raw]}) as api:
            paypal.sync(date_from='2024-01-01')
        self.assertIn('date_from=2024-01-01',api.call_args.args[0])
        self.assertEqual(self.data['paypal-sync.json']['requestedFrom'],'2024-01-01')
        self.assertEqual(self.data['paypal-sync.json']['earliestReturned'],'2026-09-08')
        self.assertIn('pp',self.data['paypal-observations.json'])
        for invalid in ['2000-01-01','2099-01-01','bad',4]:
            with self.assertRaises(ValueError): paypal.validate_start(invalid)

    def test_repeated_sync_stable_and_staged(self):
        self.data['session-paypal.json']={'accounts':[{'uid':'u','identification_hash':'stable'}]}
        raw=dict(entry_reference='ref',credit_debit_indicator='DBIT',creditor={'name':'Shop'},transaction_date='2026-09-08',transaction_amount={'amount':'25.00','currency':'EUR'},status='BOOK')
        with patch.object(store,'api',return_value={'transactions':[raw]}):
            paypal.sync(); first=copy.deepcopy(self.data['paypal-observations.json']);paypal.sync()
        self.assertEqual(first,self.data['paypal-observations.json'])
        self.assertEqual(len(self.data['ledger.json']['transactions']),1)

if __name__ == '__main__': unittest.main()
