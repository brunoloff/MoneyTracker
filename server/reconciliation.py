"""Conservative suggestions linking purchase observations to booked bank payments.

Suggestions are never proof of identity and never mutate the ledger. Match exact
signed amounts/currencies, permitting posting delays. Fee/FX/split allocations
need explicit handling rather than an amount tolerance that hides differences.
"""
from collections import defaultdict
from datetime import date
import re


def suggest_matches(observations, payments, account_ids, days=7):
    if type(days) is not int or not 0 <= days <= 31:
        raise ValueError('Date window must be 0 to 31 days')
    allowed = set(account_ids)
    index = defaultdict(list)
    for payment in payments:
        if payment.get('status') != 'BOOK':
            continue
        sources = payment.get('sourceRecords') or [payment]
        # Do not attach another PayPal observation to an already reconciled payment.
        if any(s.get('institution', s.get('source', '')).casefold() == 'paypal' for s in sources):
            continue
        if not allowed.intersection(payment.get('accountIds') or [payment['accountId']]):
            continue
        index[(payment['currency'], payment['amount'])].append(payment)
    result = []
    contested = defaultdict(set)
    for observation in observations:
        matches = []
        if observation.get('status') == 'BOOK' and observation.get('kind') == 'purchase':
            purchased = date.fromisoformat(observation['date'][:10])
            for payment in index[(observation['currency'], observation['amount'])]:
                bank_dates = {payment['date'][:10]}
                if payment.get('bookingDate'):
                    bank_dates.add(payment['bookingDate'][:10])
                offsets = [(date.fromisoformat(d) - purchased).days for d in bank_dates]
                offset = min(offsets, key=abs)
                if abs(offset) > days:
                    continue
                descriptions = [payment['description']] + [s.get('description', '') for s in payment.get('sourceRecords', [])]
                paypal_hint = any(re.search(r'PAYPAL|PYPL', d, re.I) for d in descriptions)
                matches.append({'paymentId': payment['id'], 'dayOffset': offset,
                                'paypalMention': paypal_hint,
                                'reasons': ['Exact signed amount and currency',
                                            f'Date difference: {offset:+d} days'] +
                                           (['Bank description mentions PayPal'] if paypal_hint else [])})
                contested[payment['id']].add(observation['id'])
        matches.sort(key=lambda m: (not m['paypalMention'], abs(m['dayOffset']), m['paymentId']))
        result.append({'observationId': observation['id'], 'candidates': matches})
    for row in result:
        for match in row['candidates']:
            match['competingObservations'] = len(contested[match['paymentId']])
        row['ambiguous'] = len(row['candidates']) > 1 or any(m['competingObservations'] > 1 for m in row['candidates'])
        row['requiresReview'] = True
    return result
