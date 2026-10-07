"""Read-only matching experiment on saved data; private report, no ledger writes."""
import hashlib
import json
import re
import sys
from collections import Counter
from datetime import date
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'server'))
from store import snapshot
from bank_test import PRIVATE, save


def run():
    before = hashlib.sha256((PRIVATE / 'ledger.json').read_bytes()).hexdigest()
    bank = snapshot()['transactions']
    raw = json.loads((PRIVATE / 'paypal-transactions-test.json').read_text())['transactions']
    observations = [dict(id=t['entry_reference'], date=t['transaction_date'],
                         amount=int(Decimal(t['transaction_amount']['amount']) * 100) * (-1 if t['credit_debit_indicator'] == 'DBIT' else 1),
                         currency=t['transaction_amount']['currency'],
                         merchant=(t.get('creditor') or {}).get('name') or '', status=t['status']) for t in raw]
    bank = [b for b in bank if b['status'] == 'BOOK' and b['source'] != 'PayPal']

    def candidates(o, low, high, hint=False, tolerance=0, ignore_amount=False):
        result = []
        for b in bank:
            delta = (date.fromisoformat(b['date'][:10]) - date.fromisoformat(o['date'])).days
            marked = bool(re.search(r'PAYPAL|PYPL', b['description'], re.I))
            if not low <= delta <= high or hint and not marked:
                continue
            if b['amount'] * o['amount'] <= 0:
                continue
            if not ignore_amount and (b['currency'] != o['currency'] or abs(b['amount'] - o['amount']) > tolerance):
                continue
            result.append(dict(id=b['id'], date=b['date'], amount=b['amount'], currency=b['currency'],
                               description=b['description'], accountId=b['accountId'], delay=delta, paypal=marked))
        return result

    variants = {
        'Exact amount, same day': (0, 0, False, 0),
        'Exact amount, +/-3 days': (-3, 3, False, 0),
        'Exact amount, +/-7 days': (-7, 7, False, 0),
        'Exact amount, 0..7 days, PayPal marker': (0, 7, True, 0),
        'Within EUR 0.50, 0..7 days, PayPal marker': (0, 7, True, 50),
    }
    report = {'observations': len(observations), 'currencies': dict(Counter(o['currency'] for o in observations)), 'methods': {}}
    for name, args in variants.items():
        rows = [{'observation': o, 'candidates': candidates(o, *args)} for o in observations]
        claims = Counter(c['id'] for row in rows for c in row['candidates'])
        safe = [r for r in rows if len(r['candidates']) == 1 and claims[r['candidates'][0]['id']] == 1]
        report['methods'][name] = dict(unique_one_to_one=len(safe), unmatched=sum(not r['candidates'] for r in rows),
            ambiguous=sum(bool(r['candidates']) for r in rows)-len(safe), rows=rows,
            delay_counts=dict(Counter(r['candidates'][0]['delay'] for r in safe)),
            unmarked_unique=sum(not r['candidates'][0]['paypal'] for r in safe))
    strict = report['methods']['Exact amount, 0..7 days, PayPal marker']
    used = {r['candidates'][0]['id'] for r in strict['rows'] if len(r['candidates']) == 1}
    report['unmatched_analysis'] = [dict(observation=r['observation'], remaining_date_only_candidates=[c for c in candidates(r['observation'],0,7,True,ignore_amount=True) if c['id'] not in used]) for r in strict['rows'] if not r['candidates']]
    # Shift dates as a negative control: genuine monthly recurrence can fool amount/date alone.
    shifted = []
    from datetime import timedelta
    for shift in (7, 14):
        counts = []
        for o in observations:
            moved = dict(o, date=(date.fromisoformat(o['date']) + timedelta(days=shift)).isoformat())
            counts.append(len(candidates(moved,0,7,True)))
        shifted.append({'shift_days':shift,'observations_with_candidates':sum(bool(n) for n in counts)})
    report['shifted_date_controls'] = shifted
    assert before == hashlib.sha256((PRIVATE / 'ledger.json').read_bytes()).hexdigest()
    save('paypal-matching-evaluation.json', report)
    print(json.dumps({k:v for k,v in report.items() if k!='methods'},ensure_ascii=False,indent=2))
    for name, result in report['methods'].items():
        print(name, json.dumps({k:v for k,v in result.items() if k!='rows'}))
        if '0.50' in name or '+/-7' in name:
            for row in result['rows']:
                if len(row['candidates'])>1:
                    print('AMBIGUOUS',json.dumps(row,ensure_ascii=False))

if __name__ == '__main__':
    run()
