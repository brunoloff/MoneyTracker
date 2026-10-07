"""Development-only golden fixtures from the retired Python core. No bank data."""
from pathlib import Path
import copy, json, sys, tempfile, base64, hashlib
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'server'),str(ROOT/'scripts')]
import store, rules, taxonomy, profiles, undo
from import_cgd_xlsx import parse_rows, plan
fixtures={}
allowed=set(store.CATEGORIES)
normal=[]
for desc in ['PINGO DOCE','Straße café','東京 😀','İstanbul','Cafe\nNew line','"quote" \\ slash','UBER EATS','Uber trip','AMAZON','NETFLIX']:
 for amount in ['12.34','1.005','1.015','-3.335','0.001','1000000.01','1e-2']:
  for stable in [True,False]:
   raw={'transaction_amount':{'amount':amount,'currency':'EUR'},'credit_debit_indicator':'DBIT','transaction_date':'2026-09-25','remittance_information':[desc],'status':'BOOK'}
   if stable: raw['entry_reference']='ref:'+desc
   normal.append({'raw':raw,'account':'a','source':'CGD','expected':store.normalize(raw,'a',allowed)})
for number in [1e-7, 1e-5, 1e-4, 1e15, 1e16, 1e20, 1e21, -0.0]:
 raw={'transaction_amount':{'amount':'1.00','currency':'EUR'},'credit_debit_indicator':'DBIT','transaction_date':'2026-09-25','note':'Unicode é😀','metadata':number}
 normal.append({'raw':raw,'account':'a','source':'CGD','expected':store.normalize(raw,'a',allowed)})
fixtures['normalization']=normal
fixtures['accounts']=[{'account':a,'source':s,'expected':store.stable_account_id(a,s)} for a in [{'uid':'old','identification_hash':'same'},{'account_id':{'iban':'PT1234','other':{'identification':'é😀'}}}] for s in ['CGD','Other bank']]
fixtures['matching']=[]
for field in ['description','source','direction']:
 for op in ['contains','starts_with','ends_with','equals','not_contains']:
  for value in ['strasse','σ','i̇','expense','CGD','😀','missing']:
   r={'id':'r','name':'Test','enabled':True,'category':'Food','groups':[[{'field':field,'operator':op,'value':value}]]}
   payment={'amount':-100,'description':'Straße Σ İ 😀','source':'CGD'}
   fixtures['matching'].append({'rule':r,'payment':payment,'expected':rules.matches(r,payment)})
# Synthetic projection with manual edits, merged provenance, PayPal and tags.
row=lambda i,a,d: dict(id=i,accountId=a,date='2026-09-25',amount=-100,currency='EUR',description=d,category='Other',source='CGD',status='BOOK',reviewed=False,purchaseDetails=[],relatedSourceIds=[])
base={'ledger.json':{'accounts':[{'id':'a','label':'Current','source':'CGD','kind':'CACC'}],'transactions':[row('1','a','Bank PAYPAL'),row('2','b','Other bank')]},'taxonomy.json':{**taxonomy.defaults(),'tags':[{'id':'x','name':'Work'}]},'merges.json':{'1':['2']},'tags.json':{'2':['x']},'categories.json':{'1':'Rent'},'paypal-observations.json':{'p':{'id':'p','accountId':'pp','description':'Merchant','institution':'PayPal','date':'2026-09-24','amount':-100,'currency':'EUR','raw':{'secret':'local'}}},'paypal-associations.json':{'p':'2'},'rules.json':[{'id':'r','name':'Shop','category':'Shopping','groups':[[{'field':'description','operator':'contains','value':'Merchant'}]]}]}
with patch.object(store,'read',side_effect=lambda n,d:copy.deepcopy(base.get(n,d))):
 fixtures['snapshot']={'files':base,'expected':store.snapshot(),'client':store.client_snapshot()}
ordered=[{'id':'paused','name':'Paused','category':'Food','enabled':False,'kind':'category','groups':[[{'field':'description','operator':'contains','value':'old'}]]},{'id':'active','name':'Active','category':'Food','enabled':True,'groups':[[{'field':'description','operator':'contains','value':'new'}]]},{'id':'extra','name':'Exception','category':'Food','kind':'extra','groups':[[{'field':'source','operator':'equals','value':'CGD'}]]}]
fixtures['rules']={'ordered':ordered,'draft':rules.category_draft('Food','Food',ordered),'emptyDraft':rules.category_draft('Travel','Travel',[]),'transfer':rules.transfer_categories(ordered,{'Food':'Shopping'},{'Shopping':'Shopping'})}
rows=[['CGD'],[],['Conta','123 - EUR - Conta à ordem'],['Data de início','01-01-2024'],['Data de fim','31-01-2024'],[],['Data mov.','Data valor','Descrição','Débito','Crédito','Saldo contabilístico','Saldo disponível','Categoria'],['03-01-2024','02-01-2024','Shop ','1,00',None,'98,00','98,00','COMPRAS'],['02-01-2024','02-01-2024','Shop ','1,00',None,'99,00','99,00','COMPRAS'],['02-01-2024','02-01-2024','Shop ','1,00',None,'100,00','100,00','COMPRAS'],[' ',' ',' ',' ','Saldo contabilístico','98,00 EUR',' ',' ']]
ledger={'accounts':[{'id':'a','source':'CGD','kind':'CACC','balance':9800}],'transactions':[{'id':'original','accountId':'a','date':'2024-01-02','bookingDate':'2024-01-03','amount':-100,'description':'Shop','status':'BOOK','category':'Food'}]}
records=parse_rows(rows);result,report=plan(ledger,records,'a',{'sourceFile':'test.xlsx'})
fixtures['spreadsheet']={'rows':rows,'ledger':ledger,'records':records,'result':result,'report':report}
with tempfile.TemporaryDirectory() as path:
 root=Path(path)
 with undo.action(root,'First action'): undo.write(root,'categories.json',{'é😀':'Food'})
 with undo.action(root,'Second action'): undo.write(root,'categories.json',{'é😀':'Rent'})
 db=undo.connect(root)
 fixtures['journal']={'files':{f.name:base64.b64encode(f.read_bytes()).decode() for f in root.glob('*.json')},'blobs':[{'id':r[0],'data':base64.b64encode(r[1]).decode()} for r in db.execute('SELECT * FROM blobs')],'actions':[dict(zip(['id','label','group','created','before','after'],r)) for r in db.execute('SELECT * FROM actions')],'cursor':2}
 db.close()
(ROOT/'core/test/fixtures/python_golden.json').write_text(json.dumps(fixtures,ensure_ascii=False,indent=2))
# Generate a real XLSX fixture, with dates represented by Excel serials.
import openpyxl,datetime
book=openpyxl.Workbook();sheet=book.active;sheet.title='comprovativo'
for row in rows:sheet.append(row)
for row in [4,5,8,9,10]:
 for col in ([2] if row in [4,5] else [1,2]):
  cell=sheet.cell(row,col);cell.value=datetime.datetime.strptime(cell.value,'%d-%m-%Y');cell.number_format='dd-mm-yyyy'
book.save(ROOT/'core/test/fixtures/cgd_synthetic.xlsx')
print('Generated synthetic Python golden and XLSX fixtures.')
