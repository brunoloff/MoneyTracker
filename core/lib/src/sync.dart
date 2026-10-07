import 'classification.dart';
import 'compat.dart';
import 'ledger_store.dart';
import 'provider.dart';

class BankSync {
  final LedgerStore store;
  final BankApi api;
  BankSync(this.store, this.api);
  Future<int> sync({
    dynamic years,
    dynamic accountFilter,
    void Function(String)? progress,
  }) async {
    final sessions = store.bankSessions(),
        session = sessions.isEmpty ? <String, dynamic>{} : sessions.last;
    final selected = <String, MapEntry<Map, String>>{};
    for (final saved in sessions) {
      final source = sourceName(saved);
      for (final a in saved['accounts'] ?? []) {
        selected[stableAccountId(a, source)] = MapEntry(a, source);
      }
    }
    if (selected.isEmpty) {
      invalid(
        'No bank connection. Authorize a bank in Users & accounts first.',
      );
    }
    final start = day(
          years != null
              ? historyStart(years)
              : dateOnly(
                  day(DateTime.now()),
                ).subtract(const Duration(days: 90)),
        ),
        previous = store.read('ledger.json', {});
    if (accountFilter != null && !selected.containsKey(accountFilter)) {
      invalid('Unknown bank account');
    }
    final accounts = <dynamic>[],
        downloaded = <dynamic>[],
        coverage = <dynamic>[],
        allowed = store.categoryIds;
    var index = 0;
    for (final e in selected.entries) {
      index++;
      if (accountFilter != null && accountFilter != e.key) continue;
      final a = e.value.key,
          source = e.value.value,
          id = e.key,
          uid = Uri.encodeComponent(a['uid']);
      final balances =
              (await api('/accounts/$uid/balances'))['balances'] as List,
          kind = a['cash_account_type'] ?? '',
          iban = a['account_id']?['iban'] ?? '';
      final label =
          (kind == 'CARD' ? 'Card' : 'Current account') +
          (iban.isNotEmpty
              ? ' ··${iban.substring(iban.length - 4)}'
              : ' $index');
      final available = balances
              .where((b) => b['balance_type'] == 'ITAV')
              .toList(),
          balance = available.isEmpty
              ? null
              : available.first['balance_amount'];
      accounts.add({
        'id': id,
        'label': label,
        'source': source,
        'kind': kind,
        'balance': balance != null && balance['currency'] == 'EUR'
            ? cents(balance['amount'])
            : null,
      });
      String? continuation;
      final seen = <String>{}, rawRows = <dynamic>[];
      while (true) {
        final query = {
          'date_from': start,
          if (years != null) 'strategy': 'longest',
          'continuation_key': ?continuation,
        };
        final page = await api(
          '/accounts/$uid/transactions?${Uri(queryParameters: query).query}',
        );
        rawRows.addAll(page['transactions']);
        progress?.call(
          'Account $index/${selected.length}: ${rawRows.length} records received',
        );
        continuation = page['continuation_key'];
        if (!present(continuation)) break;
        if (seen.length >= 10000) {
          invalid('Too many bank pages; previous import preserved');
        }
        if (!seen.add(continuation!)) {
          invalid('Repeated bank pagination cursor');
        }
      }
      await store.write('raw-$index.json', rawRows);
      final occurrences = <String, int>{}, unique = <String, dynamic>{};
      for (final raw in rawRows) {
        final row = normalize(raw, id, allowed, source);
        if (years != null && (row['date'] as String).compareTo(start) < 0) {
          continue;
        }
        if (row['hasStableId'] != true) {
          final count = occurrences[row['id']] ?? 0;
          occurrences[row['id']] = count + 1;
          row['id'] = '${row['id']}-$count';
        }
        unique[row['id']] = row;
      }
      downloaded.addAll(unique.values);
      final dates = unique.values.map((t) => t['date'] as String).toList()
        ..sort();
      coverage.add({
        'accountId': id,
        'label': label,
        'count': unique.length,
        'earliest': dates.isEmpty ? null : dates.first,
      });
    }
    final old = previous['transactions'] ?? [],
        syncedIds = accounts.map((a) => a['id']).toSet(),
        retained = <dynamic, dynamic>{};
    for (final t in old) {
      if (!syncedIds.contains(t['accountId']) ||
          years != null ||
          (t['date'] as String).compareTo(start) < 0 ||
          t['status'] == 'BOOK') {
        retained[t['id']] = t;
      }
    }
    for (final t in downloaded) {
      retained[t['id']] = t;
    }
    final transactions = retained.values.toList()
      ..sort((a, b) {
        final d = (b['date'] as String).compareTo(a['date']);
        return d != 0 ? d : (b['id'] as String).compareTo(a['id']);
      });
    final now = DateTime.now().toUtc().toIso8601String();
    accounts.addAll([
      for (final a in previous['accounts'] ?? [])
        if (!syncedIds.contains(a['id'])) a,
    ]);
    final result = <String, dynamic>{
      ...Map<String, dynamic>.from(previous),
      'accounts': accounts,
      'transactions': transactions,
      'syncedAt': now,
      'consentUntil': session['access']?['valid_until'],
    };
    final dates = transactions.map((t) => t['date'] as String).toList()..sort(),
        knownStart = dates.isEmpty
            ? previous['historyFrom'] ?? start
            : dates.first;
    result['historyFrom'] =
        previous['historyFrom'] != null &&
            (previous['historyFrom'] as String).compareTo(knownStart) < 0
        ? previous['historyFrom']
        : knownStart;
    if (years != null) {
      result['historyImport'] = {
        'years': years,
        'requestedFrom': start,
        'completedAt': now,
        'added': retained.keys
            .toSet()
            .difference((old as List).map((t) => t['id']).toSet())
            .length,
        'accounts': coverage,
      };
    }
    await store.write('ledger.json', result);
    return transactions.length;
  }
}
