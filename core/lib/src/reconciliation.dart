import 'casefold.dart';
import 'classification.dart';
import 'compat.dart';

List<Map<String, dynamic>> suggestMatches(
  List<Map<String, dynamic>> observations,
  List<Map<String, dynamic>> payments,
  Set<dynamic> accountIds, {
  int days = 7,
}) {
  if (days < 0 || days > 31) invalid('Date window must be 0 to 31 days');
  final index = <String, List<Map<String, dynamic>>>{};
  for (final payment in payments) {
    if (payment['status'] != 'BOOK') continue;
    final sources = present(payment['sourceRecords'])
        ? payment['sourceRecords'] as List
        : [payment];
    if (sources.any(
      (s) => casefold(s['institution'] ?? s['source'] ?? '') == 'paypal',
    )) {
      continue;
    }
    final accounts = present(payment['accountIds'])
        ? payment['accountIds'] as List
        : [payment['accountId']];
    if (!accounts.any(accountIds.contains)) continue;
    index
        .putIfAbsent('${payment['currency']}:${payment['amount']}', () => [])
        .add(payment);
  }
  final result = <Map<String, dynamic>>[],
      contested = <dynamic, Set<dynamic>>{};
  for (final observation in observations) {
    final matches = <Map<String, dynamic>>[];
    if (observation['status'] == 'BOOK' && observation['kind'] == 'purchase') {
      final purchased = dateOnly(
        (observation['date'] as String).substring(0, 10),
      );
      for (final payment
          in index['${observation['currency']}:${observation['amount']}'] ??
              <Map<String, dynamic>>[]) {
        final bankDates = <String>{
          (payment['date'] as String).substring(0, 10),
          if (present(payment['bookingDate']))
            (payment['bookingDate'] as String).substring(0, 10),
        };
        final offsets =
            bankDates
                .map((d) => dateOnly(d).difference(purchased).inDays)
                .toList()
              ..sort((a, b) => a.abs().compareTo(b.abs()));
        final offset = offsets.first;
        if (offset.abs() > days) continue;
        final descriptions = [
          payment['description'],
          for (final s in payment['sourceRecords'] ?? [])
            s['description'] ?? '',
        ];
        final hint = descriptions.any(
          (d) => RegExp(r'PAYPAL|PYPL', caseSensitive: false).hasMatch(d),
        );
        matches.add({
          'paymentId': payment['id'],
          'dayOffset': offset,
          'paypalMention': hint,
          'reasons': [
            'Exact signed amount and currency',
            'Date difference: ${offset >= 0 ? '+' : ''}$offset days',
            if (hint) 'Bank description mentions PayPal',
          ],
        });
        contested.putIfAbsent(payment['id'], () => {}).add(observation['id']);
      }
    }
    matches.sort((a, b) {
      final h = (a['paypalMention'] == true ? 0 : 1).compareTo(
        b['paypalMention'] == true ? 0 : 1,
      );
      if (h != 0) return h;
      final d = (a['dayOffset'] as int).abs().compareTo(
        (b['dayOffset'] as int).abs(),
      );
      return d != 0 ? d : (a['paymentId'] as String).compareTo(b['paymentId']);
    });
    result.add({'observationId': observation['id'], 'candidates': matches});
  }
  for (final row in result) {
    final candidates = row['candidates'] as List;
    for (final c in candidates) {
      c['competingObservations'] = contested[c['paymentId']]!.length;
    }
    row['ambiguous'] =
        candidates.length > 1 ||
        candidates.any((c) => c['competingObservations'] > 1);
    row['requiresReview'] = true;
  }
  return result;
}
