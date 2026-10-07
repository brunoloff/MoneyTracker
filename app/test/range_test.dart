import 'package:flutter/material.dart';
import 'package:money_tracker/main.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:money_tracker/ledger.dart';
import 'widget_test.dart' show payment, data;

void main() {
  for (final width in [390.0, 1100.0]) {
    testWidgets('Range and average controls fit at $width', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final l = Ledger(
        clock: () => DateTime(2026, 9, 27),
        client: MockClient((r) async => http.Response('{"ok":true}', 200)),
      );
      l.ingest(data([payment('food', '2026-09-01', -30000, 'Food')]));
      await tester.pumpWidget(MoneyTrackerApp(ledger: l));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3').last);
      await tester.pumpAndSettle();
      expect(l.periodCount, 3);
      await tester.ensureVisible(find.text('Monthly average'));
      await tester.tap(find.text('Monthly average'));
      await tester.pumpAndSettle();
      expect(l.showAverage, true);
      expect(l.displayAmount(l.spent), 10000);
      expect(find.text('By month'), findsOneWidget);
      expect(find.text('By salary'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  test(
    'Multi-month totals and averages cross year boundaries without changing payments',
    () {
      final l = Ledger(clock: () => DateTime(2027, 1, 15));
      l.ingest(
        data([
          payment('outside', '2026-10-31', -99999, 'Food'),
          payment('first', '2026-11-01', -10000, 'Food'),
          payment('second', '2026-12-01', -20000, 'Food'),
          payment('third', '2027-01-01', -30000, 'Food'),
          payment('after', '2027-02-01', -99999, 'Food'),
        ]),
      );
      l.periodCount = 3;
      expect(l.start, DateTime(2026, 11, 1));
      expect(l.end, DateTime(2027, 2, 1));
      expect(l.spent, 60000);
      l.monthlyAverage = true;
      expect(l.displayAmount(l.spent), 20000);
      expect(l.visible.length, 3);
      expect(l.visible.first.amount, -30000);
      l.moveMonth(-1);
      expect(l.start, DateTime(2026, 10, 1));
      expect(l.end, DateTime(2027, 1, 1));
      l.dispose();
    },
  );
  test(
    'Multiple salary periods retain exclusive end and use calendar month equivalents',
    () {
      final l = Ledger(clock: () => DateTime(2026, 9, 27));
      l.ingest(
        data([
          payment('june', '2026-06-20', 200000, 'Salary'),
          payment('july', '2026-07-20', 200000, 'Salary'),
          payment('august', '2026-08-20', 200000, 'Salary'),
          payment('september', '2026-09-20', 200000, 'Salary'),
          payment('expense', '2026-08-20', -10000, 'Food'),
          payment('next expense', '2026-09-20', -50000, 'Food'),
        ]),
      );
      l.period = 'salary';
      l.periodCount = 2;
      l.monthlyAverage = true;
      expect(l.start, DateTime(2026, 8, 20));
      expect(l.spent, 60000);
      expect(l.monthDivisor, closeTo(12 / 31 + 27 / 30, 0.00001));
      l.moveSalary(1);
      expect(l.start, DateTime(2026, 7, 20));
      expect(l.end, DateTime(2026, 9, 20));
      expect(l.spent, 10000);
      expect(l.monthDivisor, closeTo(12 / 31 + 1 + 19 / 30, 0.00001));
      expect(l.canPreviousSalary, true);
      l.moveSalary(1);
      expect(l.canPreviousSalary, false);
      l.periodCount = 24;
      expect(l.effectiveCount, 2);
      expect(l.start, DateTime(2026, 6, 20));
      l.dispose();
    },
  );
  test('Settings restored and history gaps made explicit', () {
    final l = Ledger(clock: () => DateTime(2026, 9, 27));
    l.ingest({
      ...data([]),
      'historyFrom': '2026-08-01',
      'preferences': {
        'period': 'month',
        'periodCount': 3,
        'monthlyAverage': true,
      },
    });
    expect(l.periodCount, 3);
    expect(l.showAverage, true);
    expect(l.incompleteHistory, true);
    expect(l.displayAmount(100), 33);
    l.periodCount = 1;
    expect(l.showAverage, false);
    expect(l.incompleteHistory, false);
    l.dispose();
  });
}
