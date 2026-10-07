"""Validated CGD current-account XLSX backfill. Dry-run unless --apply is given.

Stop the local server before applying. Requires openpyxl for read-only extraction.
Only adds transactions strictly older than existing account coverage; ambiguous
overlaps fail closed. Existing rows, balances, rules and manual edits stay intact.
"""
import argparse
from collections import defaultdict, deque
import datetime as dt
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'server'))
import store


def money(value):
    text = str(value or '').strip()
    if not text:
        return 0
    if isinstance(value, str):
        if not re.fullmatch(r'-?(?:\d+|\d{1,3}(?:\.\d{3})+),\d{2}', text):
            raise ValueError('Expected Portuguese currency with two decimal places')
        text = text.replace('.', '').replace(',', '.')
    cents = Decimal(text) * 100
    if not cents.is_finite() or cents != cents.to_integral_value():
        raise ValueError('Invalid currency precision')
    return int(cents)


def date(value):
    if isinstance(value, dt.datetime):
        return value.date().isoformat()
    if isinstance(value, dt.date):
        return value.isoformat()
    return dt.datetime.strptime(str(value).strip(), '%d-%m-%Y').date().isoformat()


def parse_rows(rows):
    expected = ['Data mov.', 'Data valor', 'Descrição', 'Débito', 'Crédito',
                'Saldo contabilístico', 'Saldo disponível', 'Categoria']
    if [str(c or '').strip() for c in rows[6]] != expected:
        raise ValueError('Unrecognized CGD column layout')
    if ' - EUR - ' not in str(rows[2][1]):
        raise ValueError('Expected an EUR account export')
    start, end = date(rows[3][1]), date(rows[4][1])
    records = []
    footer = None
    for number, row in enumerate(rows[7:], 8):
        values = [str(c or '').strip() for c in row]
        if not any(values):
            continue
        if not values[0] and values[4] == 'Saldo contabilístico':
            footer = money(values[5].removesuffix(' EUR'))
            continue
        if footer is not None:
            raise ValueError('Unexpected rows after closing balance')
        debit, credit = money(row[3]), money(row[4])
        if debit < 0 or credit < 0 or bool(debit) == bool(credit):
            raise ValueError(f'Row {number}: expected one positive debit or credit')
        record = {'date': date(row[0]), 'valueDate': date(row[1]),
                  'description': values[2], 'amount': credit - debit,
                  'balance': money(row[5]), 'availableBalance': money(row[6]),
                  'bankCategory': values[7], 'row': number}
        if not record['description'] or not start <= record['date'] <= end:
            raise ValueError(f'Row {number}: invalid description or reporting date')
        records.append(record)
    if not records or footer != records[0]['balance']:
        raise ValueError('Missing or inconsistent closing balance')
    for newer, older in zip(records, records[1:]):
        if newer['date'] < older['date'] or newer['balance'] - older['balance'] != newer['amount']:
            raise ValueError(f"Balance/date continuity failed at row {newer['row']}")
    return records


def match_key(row):
    return ((row.get('bookingDate') or row['date'])[:10], row['amount'],
            ' '.join(row['description'].upper().split()))


def plan(ledger, records, account_id, source):
    account = next(a for a in ledger['accounts'] if a['id'] == account_id)
    if account['source'] != 'CGD' or account['kind'] != 'CACC':
        raise ValueError('Choose a CGD current account')
    existing = [t for t in ledger['transactions'] if t['accountId'] == account_id]
    if not existing:
        raise ValueError('Existing account history is required to verify overlap')
    by_key = defaultdict(deque)
    for row in existing:
        if row['status'] == 'BOOK':
            by_key[match_key(row)].append(row)
    earliest = min(match_key(t)[0] for t in existing)
    added, links = [], []
    allowed_categories = set(store.category_ids())
    occurrences = defaultdict(int)
    for record in records:
        key = match_key(record)
        candidates = by_key[key]
        if candidates:
            matched = candidates.popleft()
            links.append({'row': record['row'], 'transactionId': matched['id']})
            continue
        if record['date'] >= earliest:
            raise ValueError(f"Unmatched overlap at spreadsheet row {record['row']}; review before import")
        identity = json.dumps([account_id, key, record['valueDate'], record['balance']], ensure_ascii=False)
        occurrence = occurrences[identity]
        occurrences[identity] += 1
        identity = hashlib.sha256(f'cgd-xlsx:{identity}:{occurrence}'.encode()).hexdigest()[:32]
        observation = {**record, **source, 'id': identity, 'accountId': account_id,
                       'provider': 'cgd_xlsx', 'institution': 'CGD', 'kind': 'bank_movement',
                       'externalId': None, 'currency': 'EUR'}
        added.append({'id': identity, 'accountId': account_id, 'date': record['date'],
                      'bookingDate': record['date'], 'amount': record['amount'], 'currency': 'EUR',
                      'description': record['description'], 'category': store.suggest(record['description'], record['amount'], allowed_categories),
                      'reviewed': False, 'status': 'BOOK', 'source': 'CGD', 'hasStableId': False,
                      'purchaseDetails': [], 'relatedSourceIds': [], 'sourceRecord': observation})
        links.append({'row': record['row'], 'transactionId': identity})
    if not any(link['transactionId'] in {t['id'] for t in existing} for link in links):
        raise ValueError('No matching overlap to verify account assignment')
    result = {**ledger, 'transactions': sorted(ledger['transactions'] + added,
                                               key=lambda t: (t['date'], t['id']), reverse=True)}
    if len({t['id'] for t in result['transactions']}) != len(result['transactions']):
        raise ValueError('Transaction identity collision')
    result['historyFrom'] = min(t['date'] for t in result['transactions'])
    report = {**source, 'accountId': account_id, 'rows': len(records), 'added': len(added),
              'matched': len(records) - len(added), 'from': min(r['date'] for r in records),
              'through': max(r['date'] for r in records), 'links': links}
    return result, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', type=Path)
    parser.add_argument('--account', required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    import openpyxl
    data = args.file.read_bytes()
    import io
    workbook = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=False)
    try:
        if workbook.sheetnames != ['comprovativo']:
            raise ValueError('Expected one comprovativo sheet')
        records = parse_rows(list(workbook.active.values))
    finally:
        workbook.close()
    path = store.PRIVATE / 'ledger.json'
    original = path.read_bytes()
    source = {'sourceFile': args.file.name, 'sha256': hashlib.sha256(data).hexdigest(), 'sheet': 'comprovativo'}
    result, report = plan(json.loads(original), records, args.account, source)
    if args.apply and report['added']:
        # The existing server does not share a filesystem writer lock. Refuse a
        # live default server rather than race a background sync or UI update.
        with socket.socket() as probe:
            if probe.connect_ex(('127.0.0.1', 8765)) == 0:
                raise ValueError('Stop MoneyTracker before applying the import')
        stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        folder = store.PRIVATE / 'imports' / stamp
        folder.mkdir(parents=True, mode=0o700)
        os.chmod(folder.parent, 0o700)
        report['completedAt'] = dt.datetime.now(dt.timezone.utc).isoformat()
        for name, content in [('ledger-before.json', original), ('source.xlsx', data),
                              ('report.json', json.dumps(report, indent=2).encode())]:
            with open(folder / name, 'xb') as output:
                os.chmod(folder / name, 0o600)
                output.write(content)
        if path.read_bytes() != original:
            raise ValueError('Ledger changed during import; retry after stopping writers')
        result['fileImports'] = result.get('fileImports', []) + [{k: v for k, v in report.items() if k != 'links'}]
        with store.undo.action(store.PRIVATE, 'Import bank spreadsheet'):
            store.write('ledger.json', result)
        print('Backup and audit:', folder.relative_to(ROOT))
    print(json.dumps({k: v for k, v in report.items() if k not in ('links', 'sha256')}, indent=2))


if __name__ == '__main__':
    main()
