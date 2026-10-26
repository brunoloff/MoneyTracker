import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'casefold.dart';
import 'classification.dart';
import 'compat.dart';
import 'ledger_store.dart';
import 'provider.dart';
import 'sync_start.dart';

const ecbUrl = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.xml';
const ecbIncrementalUrl =
    'https://data-api.ecb.europa.eu/service/data/EXR/D..EUR.SP00.A';
Map<String, dynamic> parseIncrementalRates(String content) {
  final result = <String, dynamic>{};
  final document = XmlDocument.parse(content);
  for (final series in document.descendants.whereType<XmlElement>().where(
    (e) => e.name.local == 'Series',
  )) {
    final keys = {
      for (final e in series.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'Value',
      ))
        e.getAttribute('id'): e.getAttribute('value'),
    };
    final currency = keys['CURRENCY'];
    if (keys['FREQ'] != 'D' ||
        keys['CURRENCY_DENOM'] != 'EUR' ||
        currency == null) {
      continue;
    }
    for (final observation in series.childElements.where(
      (e) => e.name.local == 'Obs',
    )) {
      final fields = {
        for (final e in observation.childElements)
          e.name.local: e.getAttribute('value'),
      };
      final date = fields['ObsDimension'], value = fields['ObsValue'];
      if (date == null || value == null) invalid('Invalid ECB observation');
      dateOnly(date);
      if (Exact.parse(value).compareTo(Exact(BigInt.zero)) <= 0) {
        invalid('Invalid ECB rate');
      }
      result.putIfAbsent(date, () => <String, dynamic>{'EUR': '1'})[currency] =
          value;
    }
  }
  if (result.isEmpty) invalid('ECB download contains no exchange rates');
  return result;
}

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
    !(bank['tags'] as List? ?? []).contains('ignored') &&
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
    final previous = store.read('exchange-rates.json', {});
    final known = Map<String, dynamic>.from(previous['rates'] ?? {});
    final days = known.keys.toList()..sort();
    final url = days.isEmpty
        ? Uri.parse(ecbUrl)
        : Uri.parse(ecbIncrementalUrl).replace(
            queryParameters: {
              'startPeriod': days.last,
              'format': 'genericdata',
              'detail': 'dataonly',
            },
          );
    progress?.call(
      days.isEmpty
          ? 'Downloading ECB historical exchange rates…'
          : 'Downloading ECB exchange rates from ${days.last}…',
    );
    final response = await client.get(url).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200 &&
        !(response.statusCode == 204 && known.isNotEmpty)) {
      throw StateError('ECB download failed (${response.statusCode})');
    }
    if (response.statusCode == 200) {
      final fetched = days.isEmpty
          ? parseRates(utf8.decode(response.bodyBytes))
          : parseIncrementalRates(utf8.decode(response.bodyBytes));
      for (final entry in fetched.entries) {
        known[entry.key] = {
          ...Map<String, dynamic>.from(known[entry.key] ?? {}),
          ...entry.value as Map,
        };
      }
    }
    await store.write('exchange-rates.json', {
      'source': 'ECB',
      'url': url.toString(),
      'downloadedAt': DateTime.now().toUtc().toIso8601String(),
      'rates': known,
    });
  }

  Future<void> sync({dynamic dateFrom, void Function(String)? progress}) async {
    final dates = <String>[], session = store.read('session-paypal.json', {});
    if (!present(session['accounts'])) {
      invalid('Authorize a PayPal account first.');
    }
    final staged = store.read('paypal-observations.json', {});
    final starts = <String, String>{};
    for (final account in session['accounts']) {
      final accountId = paypalAccountId(account);
      final floor = day(historyStart(7));
      final automatic = incrementalStart((staged as Map).values, accountId);
      final start = dateFrom == null
          ? (automatic.compareTo(floor) < 0 ? floor : automatic)
          : paypalStart(dateFrom);
      starts[accountId] = start;
      final params = {
            'date_from': start,
            if (dateFrom != null) 'strategy': 'longest',
          },
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
          final date =
              (raw['transaction_date'] ??
                          raw['booking_date'] ??
                          raw['value_date'])
                      .substring(0, 10)
                  as String;
          if (date.compareTo(start) < 0) continue;
          staged[id] = {
            'id': id,
            'accountId': accountId,
            'institution': 'PayPal',
            'provider': 'enablebanking',
            'kind': 'purchase',
            'externalId': reference,
            'description': description,
            'date': date,
            'amount':
                cents(raw['transaction_amount']['amount']) * (debit ? -1 : 1),
            'currency': raw['transaction_amount']['currency'],
            'status': raw['status'],
            'raw': raw,
          };
          dates.add(staged[id]['date']);
        }
        progress?.call('PayPal from $start: ${dates.length} payments received');
        final cursor = page['continuation_key'];
        if (!present(cursor)) break;
        if (seen.length >= 1000 || !seen.add(cursor)) {
          invalid('Invalid PayPal pagination');
        }
        params['continuation_key'] = cursor;
      }
    }
    dates.sort();
    final requested = starts.values.toList()..sort();
    await store.write('paypal-observations.json', staged);
    await store.write('paypal-sync.json', {
      'at': DateTime.now().toUtc().toIso8601String(),
      'requestedFrom': requested.isEmpty ? null : requested.first,
      'accountStarts': starts,
      'earliestReturned': dates.isEmpty ? null : dates.first,
      'latestReturned': dates.isEmpty ? null : dates.last,
      'returnedCount': dates.length,
    });
  }

  Map<String, dynamic> review({String query = '', dynamic observationId}) {
    final observations = store.read('paypal-observations.json', {}),
        links = store.read('paypal-associations.json', {}),
        tags = store.read('tags.json', {}),
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
        rows = <dynamic>[],
        ignored = <dynamic>[];
    for (final o in (observations as Map).values) {
      if ((tags[o['id']] as List? ?? []).contains('ignored')) {
        ignored.add({
          ...Map<String, dynamic>.from(o)..remove('raw'),
          'tags': ['ignored'],
        });
        continue;
      }
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
      'ignored': ignored,
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

  Future<void> ignore(dynamic id, dynamic ignored) async {
    final observations = store.read('paypal-observations.json', {});
    if (id is! String || ignored is! bool || !observations.containsKey(id)) {
      invalid('Unknown PayPal payment');
    }
    if (store.read('paypal-associations.json', {}).containsKey(id)) {
      invalid('This payment is already associated with a bank movement');
    }
    final tags = store.read('tags.json', {});
    final values = <dynamic>{...tags[id] ?? []}..remove('ignored');
    if (ignored) {
      values.add('ignored');
      await store.ensureIgnoredTag();
    }
    tags[id] = values.toList()..sort();
    await store.write('tags.json', tags);
  }

  Future<void> ignoreUnmatched(dynamic ids) async {
    if (ids is! List || ids.isEmpty || ids.any((id) => id is! String)) {
      invalid('Choose at least one unmatched PayPal payment');
    }
    final available = {
      for (final row in review()['rows'])
        if (row['rule'] == 'unmatched') row['observation']['id'],
    };
    if (!ids.every(available.contains)) {
      invalid(
        'Some payments now have suggested matches or are no longer pending; refresh the review',
      );
    }
    await store.ensureIgnoredTag();
    final tags = store.read('tags.json', {});
    for (final id in ids) {
      tags[id] = <dynamic>{...tags[id] ?? [], 'ignored'}.toList()..sort();
    }
    await store.write('tags.json', tags);
  }
}
