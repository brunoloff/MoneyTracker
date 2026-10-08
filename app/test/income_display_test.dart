import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/main.dart';
import 'widget_test.dart' show data, payment;

void main() {
  test(
    'reference income uses preceding complete months and original scope',
    () {
      final l = Ledger(clock: () => DateTime(2027, 1, 15));
      addTearDown(l.dispose);
      l.ingest(
        data([
          payment('old', '2026-09-30', 990000, 'Other income'),
          payment('october', '2026-10-01', 30000, 'Other income'),
          // November intentionally has no income.
          payment('december', '2026-12-31', 90000, 'Other income'),
          payment('transfer', '2026-12-01', 700000, 'Transfer'),
          payment(
            'pending',
            '2026-12-01',
            700000,
            'Other income',
            status: 'PDNG',
          ),
          payment('current', '2027-01-01', 20000, 'Salary'),
          payment('spent', '2027-01-02', -5000, 'Food'),
        ]),
      );
      expect(l.displayedIncome, 20000);
      l.incomeMode = 'last_month';
      expect(l.displayedIncome, 90000);
      l.incomeMode = 'average';
      expect(l.displayedIncome, 40000); // Divide by all three months.
      expect(l.income, 20000);
      expect(l.spent, 5000);
      expect(l.visible.map((p) => p.id), ['spent', 'current']);
      l.category = 'Food';
      l.query = 'does not match income';
      expect(l.displayedIncome, 40000); // Same summary filter semantics.
      l.moveMonth(-1);
      expect(
        l.displayedIncome,
        340000,
      ); // September–November, relative to December.
      l.account = 'missing';
      expect(l.displayedIncome, 0);
      l.account = 'all';
      l.periodCount = 2;
      expect(l.canChooseIncome, false);
      expect(l.displayedIncome, l.displayAmount(l.income));
      l.period = 'salary';
      expect(l.canChooseIncome, false);
      expect(l.displayedIncome, l.displayAmount(l.income));
      expect(l.incomeMode, 'average');
    },
  );

  test('reference history gap is visible and preferences restore', () {
    final l = Ledger(clock: () => DateTime(2027, 1, 15));
    addTearDown(l.dispose);
    l.ingest({
      ...data([]),
      'historyFrom': '2026-12-01',
      'preferences': {
        'period': 'month',
        'incomeMode': 'average',
        'incomeAverageMonths': 6,
      },
    });
    expect(l.incomeMode, 'average');
    expect(l.incomeAverageMonths, 6);
    expect(l.incompleteIncomeHistory, true);
    l.incomeMode = 'this_month';
    expect(l.incompleteIncomeHistory, false);
  });

  for (final width in [390.0, 1100.0]) {
    testWidgets('income controls save independently and fit at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final saved = <String, dynamic>{};
      final l = Ledger(
        clock: () => DateTime(2027, 1, 15),
        client: MockClient((r) async {
          expect(r.url.path, '/api/preferences');
          saved.addAll(jsonDecode(r.body) as Map<String, dynamic>);
          return http.Response('{"ok":true}', 200);
        }),
      );
      l.ingest(data([payment('income', '2026-12-01', 60000, 'Other income')]));
      await tester.pumpWidget(MoneyTrackerApp(ledger: l));
      await tester.pumpAndSettle();
      expect(find.text('Your money, clearly.'), findsNothing);
      expect(find.text('All your payments, in one place.'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('income-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last month').last);
      await tester.pumpAndSettle();
      expect(l.displayedIncome, 60000);
      await tester.tap(find.byKey(const ValueKey('income-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Average over last X months'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('income-average-months')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 months').last);
      await tester.pumpAndSettle();
      expect(saved, {'incomeMode': 'average', 'incomeAverageMonths': 2});
      expect(l.displayedIncome, 30000);
      expect(l.periodCount, 1);
      expect(l.income, 0);
      expect(tester.takeException(), isNull);
      await l.setRange(count: 2);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('income-mode')), findsNothing);
      await l.setRange(count: 1);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('income-average-months')),
        findsOneWidget,
      );
      expect(l.incomeAverageMonths, 2);
    });
  }

  test('failed preference save keeps the last saved income choice', () async {
    final l = Ledger(
      client: MockClient(
        (_) async => http.Response('{"error":"test failure"}', 400),
      ),
    );
    addTearDown(l.dispose);
    await l.setIncomeDisplay(mode: 'average', months: 12);
    expect(l.incomeMode, 'this_month');
    expect(l.incomeAverageMonths, 3);
    expect(l.saving, false);
    expect(l.error, contains('Could not save income display'));
  });
}
