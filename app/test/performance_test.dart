import 'dart:convert';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/main.dart';
import 'widget_test.dart' show payment, data;

Map<String, dynamic> largeData(int count) => {
  ...data([
    payment('salary', '2026-09-01', 500000, 'Salary'),
    for (var i = 0; i < count; i++)
      payment('$i', i.isEven ? '2026-09-10' : '2026-08-10', -123, 'Food'),
  ]),
  'preferences': {'period': 'salary'},
};

void main() {
  test('30k rows: one aggregate pass, reused across widgets and search', () {
    final l = Ledger(clock: () => DateTime(2026, 9, 27));
    final watch = Stopwatch()..start();
    l.ingest(largeData(30000));
    expect(l.spent, 15000 * 123);
    expect(l.income, 500000);
    expect(l.totals, {'Food': 15000 * 123});
    expect(l.visible.length, 15001);
    final cold = watch.elapsedMicroseconds;
    final selected = l.selectionPasses, summary = l.summaryPasses;
    watch.reset();
    for (var i = 0; i < 100; i++) {
      expect(l.spent, 15000 * 123);
      expect(l.totals['Food'], 15000 * 123);
      l.filter(search: 'Example $i');
      expect(
        l.visible.every((p) => p.description.contains('Example $i')),
        true,
      );
    }
    debugPrint(
      '30,001 rows: ingest + initial calculations ${cold / 1000} ms; '
      '100 searches ${watch.elapsedMicroseconds / 1000} ms',
    );
    expect(l.selectionPasses, selected);
    expect(l.summaryPasses, summary);
    final visible = l.visible;
    l.changed();
    expect(identical(l.visible, visible), true);
    l.monthlyAverage = true;
    l.displayAmount(l.spent);
    expect(l.summaryPasses, summary);
    l.period = 'month';
    l.moveMonth(-1);
    expect(l.spent, 15000 * 123);
    expect(l.summaryPasses, summary + 1);
    expect(l.selectionPasses, selected);
    l.dispose();
  });

  test(
    'Refresh, taxonomy, owner and midnight changes invalidate appropriate caches',
    () {
      var now = DateTime(2026, 9, 27);
      final l = Ledger(clock: () => now);
      final payload = data([
        payment('salary', '2026-09-01', 10000, 'pay'),
        payment('next', '2026-09-28', 20000, 'pay'),
        payment('food', '2026-09-15', -100, 'Food'),
      ]);
      l.ingest({
        ...payload,
        'taxonomy': {
          'categories': [
            for (final c in categories) {'id': c, 'name': c},
            {'id': 'pay', 'name': 'Pay', 'parent': 'Salary'},
          ],
          'tags': [],
        },
      });
      l.period = 'salary';
      expect(l.start, DateTime(2026, 9, 1));
      expect(l.spent, 100);
      now = DateTime(2026, 9, 28);
      expect(l.start, DateTime(2026, 9, 28));
      expect(l.spent, 0);
      l.selectedUser = 'unassigned';
      expect(l.income, 20000);
      l.accountUsers = {'one': 'person'};
      expect(l.income, 0);
      expect(l.visible, isEmpty);
      l.ingest(data([payment('replacement', '2026-09-10', -700, 'Travel')]));
      expect(l.spent, 700);
      expect(l.totals, {'Travel': 700});
      l.dispose();
    },
  );

  testWidgets('Inactive overview does not calculate until selected again', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final l = Ledger(clock: () => DateTime(2026, 9, 27));
    l.ingest(largeData(3000));
    await tester.pumpWidget(MoneyTrackerApp(ledger: l));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preferences').first);
    await tester.pumpAndSettle();
    final count = l.summaryPasses;
    l.periodCount = 2;
    l.changed();
    await tester.pumpAndSettle();
    expect(l.summaryPasses, count);
    await tester.tap(find.text('Overview').first);
    await tester.pumpAndSettle();
    expect(l.summaryPasses, count + 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Sync polls status without repeatedly downloading transactions', (
    tester,
  ) async {
    var ledgerRequests = 0, statusRequests = 0;
    final l = Ledger(
      client: MockClient((request) async {
        if (request.url.path == '/api/status') {
          statusRequests++;
          return http.Response(
            jsonEncode({
              'syncing': statusRequests < 2,
              'syncProgress': 'Page 2',
            }),
            200,
          );
        }
        ledgerRequests++;
        return http.Response(
          jsonEncode({...data([]), 'syncing': ledgerRequests == 1}),
          200,
        );
      }),
    );
    await l.load();
    await tester.pump(const Duration(seconds: 3));
    expect(statusRequests, 1);
    expect(ledgerRequests, 1);
    expect(l.syncProgress, 'Page 2');
    await tester.pump(const Duration(seconds: 3));
    expect(statusRequests, 2);
    expect(ledgerRequests, 2);
    expect(l.syncing, false);
    l.dispose();
  });
}
