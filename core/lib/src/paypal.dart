import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'casefold.dart';
import 'classification.dart';
import 'compat.dart';
import 'ledger_store.dart';
import 'provider.dart';

const ecbUrl = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.xml';
Map<String, dynamic> parseRates(String content) {
  final rates = <String, dynamic>{}, document = XmlDocument.parse(content);
  for (final element in document.descendants.whereType<XmlElement>()) {
    final date = element.getAttribute('time');
    if (date == null) continue;
    dateOnly(date);
    final currencies = <String, dynamic>{'EUR': '1'};
    for (final child in element.childElements) {
      final currency = child.getAttribute('currency'),
          value = child.getAttribute('rate');
      if (currency == null || value == null) continue;
      if (Exact.parse(value).compareTo(Exact(BigInt.zero)) <= 0) {
        invalid('Invalid ECB rate');
      }
      currencies[currency] = value;
    }
    if (currencies.length > 1) rates[date] = currencies;
  }
  if (rates.isEmpty) invalid('ECB download contains no exchange rates');
  return rates;
}

class RateTable {
  final Map data;
  late final Map rates = data['rates'] ?? {};
  late final List<String> days = rates.keys.cast<String>().toList()..sort();
  RateTable(this.data);
  Map<String, dynamic> status() => {
    'source': 'ECB',
    'downloadedAt': data['downloadedAt'],
    'from': days.isEmpty ? null : days.first,
    'to': days.isEmpty ? null : days.last,
  };
  (Exact, String)? convert(
    int amount,
    String source,
    String target,
    String date,
  ) {
    var lo = 0, hi = days.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (days[mid].compareTo(date) <= 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo == 0) return null;
    final rateDate = days[lo - 1];
    if (dateOnly(date).difference(dateOnly(rateDate)).inDays > 7) return null;
    final table = rates[rateDate];
    if (table[source] == null || table[target] == null) return null;
    return (
      Exact(BigInt.from(amount)) *
          Exact.parse(table[target]) /
          Exact.parse(table[source]),
      rateDate,
    );
  }
}

String paypalStart(dynamic value, [DateTime? now]) {
  final today = dateOnly(day(now ?? DateTime.now()));
  if (value == null) return day(today.subtract(const Duration(days: 90)));
  if (value is! String) invalid('Choose a valid PayPal start date');
  final start = dateOnly(value);
  if (start.isBefore(historyStart(7, today)) || start.isAfter(today)) {
    invalid('Choose a PayPal start date within the last seven years');
  }
  return day(start);
}

bool paypalEligible(Map observation, Map bank, Map owners) =>
    bank['status'] == 'BOOK' &&
    observation['status'] == 'BOOK' &&
    bank['amount'] * observation['amount'] > 0 &&
    RegExp(
      r'PAYPAL|PYPL',
      caseSensitive: false,
    ).hasMatch(bank['description']) &&
    owners[bank['accountId']] == owners[observation['accountId']];

class Paypal {
  final LedgerStore store;
  final BankApi api;
  final http.Client client;
  Paypal(this.store, this.api, this.client);
  Future<void> downloadRates({void Function(String)? progress}) async {
    progress?.call('Downloading ECB historical exchange rates…');
    final response = await client
        .get(Uri.parse(ecbUrl))
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw StateError('ECB download failed (${response.statusCode})');
    }
    await store.write('exchange-rates.json', {
      'source': 'ECB',
      'url': ecbUrl,
      'downloadedAt': DateTime.now().toUtc().toIso8601String(),
      'rates': parseRates(utf8.decode(response.bodyBytes)),
    });
  }

  Future<void> sync({dynamic dateFrom, void Function(String)? progress}) async {
    final start = paypalStart(dateFrom),
        dates = <String>[],
        session = store.read('session-paypal.json', {});
    if (!present(session['accounts'])) {
      invalid('Authorize a PayPal account first.');
    }
    final staged = store.read('paypal-observations.json', {});
    for (final account in session['accounts']) {
      final accountId = paypalAccountId(account),
          params = {'date_from': start, 'strategy': 'longest'},
          seen = <String>{};
      while (true) {
        final page = await api(
          '/accounts/${Uri.encodeComponent(account['uid'])}/transactions?${Uri(queryParameters: params).query}',
        );
        for (final raw in page['transactions']) {
          final reference = raw['entry_reference'];
          if (!present(reference)) {
            invalid(
              'PayPal record has no stable reference; previous download preserved.',
            );
          }
          final id = hashText('$accountId$reference', 32),
              debit = raw['credit_debit_indicator'] == 'DBIT',
              merchant = raw[debit ? 'creditor' : 'debtor']?['name'];
          final description = present(merchant)
              ? merchant
              : present(raw['remittance_information'])
              ? (raw['remittance_information'] as List).join(' · ')
              : present(raw['note'])
              ? raw['note']
              : 'PayPal payment';
          staged[id] = {
            'id': id,
            'accountId': accountId,
            'institution': 'PayPal',
            'provider': 'enablebanking',
            'kind': 'purchase',
            'externalId': reference,
            'description': description,
            'date':
                (raw['transaction_date'] ??
                        raw['booking_date'] ??
                        raw['value_date'])
                    .substring(0, 10),
            'amount':
                cents(raw['transaction_amount']['amount']) * (debit ? -1 : 1),
            'currency': raw['transaction_amount']['currency'],
            'status': raw['status'],
            'raw': raw,
          };
          dates.add(staged[id]['date']);
        }
        progress?.call('PayPal: ${staged.length} payments downloaded');
        final cursor = page['continuation_key'];
        if (!present(cursor)) break;
        if (seen.length >= 1000 || !seen.add(cursor)) {
          invalid('Invalid PayPal pagination');
        }
        params['continuation_key'] = cursor;
      }
    }
    dates.sort();
    await store.write('paypal-observations.json', staged);
    await store.write('paypal-sync.json', {
      'at': DateTime.now().toUtc().toIso8601String(),
      'requestedFrom': start,
      'earliestReturned': dates.isEmpty ? null : dates.first,
      'latestReturned': dates.isEmpty ? null : dates.last,
      'returnedCount': dates.length,
    });
  }

  Map<String, dynamic> review({String query = '', dynamic observationId}) {
    final observations = store.read('paypal-observations.json', {}),
        links = store.read('paypal-associations.json', {}),
        owners = store.read('profiles.json', {})['accountUsers'] ?? {};
    final snapshot = store.snapshot(),
        banks = snapshot['transactions'],
        nicknames = snapshot['profiles']['accountNicknames'] ?? {},
        labels = {
          for (final a in snapshot['accounts'])
            a['id']: nicknames[a['id']] ?? a['label'],
        };
    final used = (links as Map).values.toSet(),
        table = RateTable(store.read('exchange-rates.json', {})),
        tolerance = Exact.parse(
          store.read('preferences.json', {})['fxTolerancePercent'] ?? 10,
        ),
        rows = <dynamic>[];
    for (final o in (observations as Map).values) {
      if (links.containsKey(o['id']) ||
          observationId != null && o['id'] != observationId) {
        continue;
      }
      final candidates = <Map<String, dynamic>>[];
      for (final b in banks) {
        if (used.contains(b['id']) ||
            (b['sourceRecords'] as List).any(
              (s) => s['institution'] == 'PayPal',
            ) ||
            !paypalEligible(o, b, owners)) {
          continue;
        }
        final gap = dateOnly(b['date']).difference(dateOnly(o['date'])).inDays;
        if (gap.abs() > 31) continue;
        if (query.isNotEmpty &&
            !casefold(
              '${b['description']} ${b['date']} ${(b['amount'].abs() / 100).toStringAsFixed(2)}',
            ).contains(casefold(query))) {
          continue;
        }
        final exact =
            o['amount'] == b['amount'] &&
            o['currency'] == b['currency'] &&
            gap >= 0 &&
            gap <= 7;
        (Exact, String)? converted;
        Exact? difference;
        if (o['currency'] != b['currency']) {
          converted = table.convert(
            o['amount'],
            o['currency'],
            b['currency'],
            o['date'],
          );
          if (converted == null) continue;
          difference =
              (Exact(BigInt.from(b['amount'])) - converted.$1).abs /
              converted.$1.abs *
              Exact(BigInt.from(100));
          if (difference.compareTo(tolerance) > 0) continue;
        }
        final fx = converted != null && gap >= 0 && gap <= 7;
        candidates.add({
          'id': b['id'],
          'description': b['description'],
          'date': b['date'],
          'amount': b['amount'],
          'currency': b['currency'],
          'expectedAmount': converted?.$1.toDouble(),
          'rateDate': converted?.$2,
          'differencePercent': difference?.toDouble(),
          'accountId': b['accountId'],
          'accountLabel': labels[b['accountId']] ?? 'Bank account',
          'delay': gap,
          'rule': exact
              ? 'exact'
              : fx
              ? 'fx'
              : 'nearby',
        });
      }
      candidates.sort((a, b) {
        for (final pair in [
          (
            <String, int>{'exact': 0, 'fx': 1, 'nearby': 2}[a['rule']]!,
            <String, int>{'exact': 0, 'fx': 1, 'nearby': 2}[b['rule']]!,
          ),
          (
            (a['differencePercent'] ?? 0) as num,
            (b['differencePercent'] ?? 0) as num,
          ),
          ((a['delay'] as int).abs(), (b['delay'] as int).abs()),
          (
            (a['amount'] - o['amount']).abs() as num,
            (b['amount'] - o['amount']).abs() as num,
          ),
        ]) {
          final c = pair.$1.compareTo(pair.$2);
          if (c != 0) return c;
        }
        return 0;
      });
      rows.add({
        'observation': Map<String, dynamic>.from(o)..remove('raw'),
        'candidates': candidates,
      });
    }
    final claims = <dynamic, int>{};
    for (final r in rows) {
      for (final c in r['candidates']) {
        if (c['rule'] == 'exact') claims[c['id']] = (claims[c['id']] ?? 0) + 1;
      }
    }
    for (final r in rows) {
      final exact = (r['candidates'] as List)
          .where((c) => c['rule'] == 'exact')
          .toList();
      r['rule'] = exact.length == 1 && claims[exact.first['id']] == 1
          ? 'exact'
          : (r['candidates'] as List).any((c) => c['rule'] == 'fx')
          ? 'fx'
          : 'unmatched';
    }
    final history = store.read('paypal-sync.json', {});
    return {
      'rows': rows,
      'confirmed': links.length,
      'exchangeRates': table.status(),
      'tolerancePercent': tolerance.toDouble(),
      'history': history,
      'lastSync': history['at'],
    };
  }

  Future<void> confirm(dynamic pairs) async {
    if (pairs is! List || pairs.isEmpty || pairs.length > 5000) {
      invalid('Select 1 to 5000 associations');
    }
    final available = {
          for (final r in review()['rows']) r['observation']['id']: r,
        },
        links = store.read('paypal-associations.json', {});
    for (final pair in pairs) {
      final oid = pair['observationId'], bid = pair['bankId'];
      if (links.containsKey(oid) || links.values.contains(bid)) {
        invalid('A payment is already associated; refresh the review');
      }
      if (!available.containsKey(oid) ||
          !(available[oid]['candidates'] as List).any((c) => c['id'] == bid)) {
        invalid('Association no longer eligible; refresh the review');
      }
      links[oid] = bid;
    }
    await store.write('paypal-associations.json', links);
  }
}
