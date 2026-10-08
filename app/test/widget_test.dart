import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_tracker/main.dart';
import 'package:money_tracker/ledger.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

Map<String, dynamic> payment(
  String id,
  String date,
  int amount,
  String category, {
  bool reviewed = true,
  String status = 'BOOK',
}) => {
  'id': id,
  'accountId': 'one',
  'date': date,
  'amount': amount,
  'description': 'Example $id',
  'category': category,
  'reviewed': reviewed,
  'status': status,
  'source': 'Test bank',
};
Map<String, dynamic> data(List<Map<String, dynamic>> rows) => {
  'transactions': rows,
  'accounts': [
    {'id': 'one', 'label': 'Current account'},
  ],
  'preferences': {'period': 'month'},
};
void main() {
  test('Month boundaries, cents, pending and transfers', () {
    final l = Ledger(clock: () => DateTime(2026, 9, 27));
    l.ingest(
      data([
        payment('before', '2026-08-31', -100, 'Food'),
        payment('start', '2026-09-01', -1234, 'Food'),
        payment('pending', '2026-09-15', -500, 'Food', status: 'PDNG'),
        payment('transfer', '2026-09-16', -10000, 'Transfer'),
        payment('income', '2026-09-20', 250000, 'Salary'),
        payment('next', '2026-10-01', -200, 'Food'),
      ]),
    );
    expect(l.spent, 1234);
    expect(l.income, 250000);
    expect(l.totals, {'Food': 1234});
    expect(l.visible.length, 4);
    l.dispose();
  });
  test('Salary period needs confirmed income, includes salary day', () {
    final l = Ledger(clock: () => DateTime(2026, 9, 27));
    l.ingest(
      data([
        payment('guess', '2026-09-25', 10000, 'Salary', reviewed: false),
        payment('salary', '2026-09-20', 250000, 'Salary'),
        payment('food', '2026-09-20', -1500, 'Food'),
        payment('old', '2026-09-19', -2000, 'Food'),
      ]),
    );
    l.period = 'salary';
    expect(l.lastSalary, DateTime(2026, 9, 20));
    expect(l.spent, 1500);
    l.payments = [];
    expect(l.start, isNull);
    expect(l.spent, 0);
    l.dispose();
  });
  test('Filtering list does not change period category totals', () {
    final l = Ledger(clock: () => DateTime(2026, 9, 27));
    l.ingest(
      data([
        payment('food', '2026-09-20', -1500, 'Food'),
        payment('bill', '2026-09-20', -2000, 'Bills'),
      ]),
    );
    l.filter(categoryName: 'Food');
    expect(l.visible.length, 1);
    expect(l.spent, 3500);
    l.dispose();
  });
  test(
    'Salary periods have exclusive next boundary and deduplicate salary days',
    () {
      final l = Ledger(clock: () => DateTime(2026, 9, 27));
      l.ingest(
        data([
          payment('aug', '2026-08-25', 200000, 'Salary'),
          payment('sep', '2026-09-25', 200000, 'Salary'),
          payment('bonus', '2026-09-25', 10000, 'Salary'),
          payment('future', '2026-10-25', 200000, 'Salary'),
          payment('old expense', '2026-08-25', -1500, 'Food'),
          payment('last day', '2026-09-24', -2500, 'Food'),
          payment('new expense', '2026-09-25', -3000, 'Food'),
        ]),
      );
      l.period = 'salary';
      expect(l.salaryDates.length, 2);
      expect(l.spent, 3000);
      l.moveSalary(1);
      expect(l.start, DateTime(2026, 8, 25));
      expect(l.end, DateTime(2026, 9, 25));
      expect(l.spent, 4000);
      expect(l.income, 200000);
      expect(l.canPreviousSalary, false);
      l.moveSalary(-1);
      expect(l.spent, 3000);
      l.filter(accountId: 'missing');
      expect(l.start, isNull);
      expect(l.canNextSalary, false);
      l.dispose();
    },
  );
  test('User salary rules also establish period boundaries', () {
    final l = Ledger(clock: () => DateTime(2026, 9, 27));
    l.ingest(
      data([
        {
          ...payment('salary', '2026-09-25', 200000, 'Salary', reviewed: false),
          'classificationRule': {'name': 'Employer'},
        },
      ]),
    );
    l.period = 'salary';
    expect(l.start, DateTime(2026, 9, 25));
    l.dispose();
  });
  for (final width in [390.0, 1100.0]) {
    testWidgets('Rule preview and save from tabs at $width', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final snapshot = data([]);
      Map<String, dynamic>? saved;
      final l = Ledger(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/preview')) {
            return http.Response(
              jsonEncode({
                'matches': [
                  {
                    'description': 'Test shop',
                    'date': '2026-09-25',
                    'amount': -500,
                    'category': 'Other',
                    'blockedBy': null,
                  },
                ],
              }),
              200,
            );
          }
          if (r.url.path.endsWith('/save')) {
            saved = jsonDecode(r.body)['rule'];
            snapshot['rules'] = [
              {...saved!, 'id': 'test-rule'},
            ];
          }
          return http.Response(
            jsonEncode(r.method == 'GET' ? snapshot : {'ok': true}),
            200,
          );
        }),
      );
      l.ingest(snapshot);
      await tester.pumpWidget(MoneyTrackerApp(ledger: l));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rules'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New rule'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Rule name'),
        'Test rule',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Match text'),
        'shop',
      );
      await tester.ensureVisible(find.text('AND condition'));
      await tester.tap(find.text('AND condition'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Match text').last,
        'test',
      );
      await tester.ensureVisible(find.text('OR group'));
      await tester.tap(find.text('OR group'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Match text').last,
        'market',
      );
      await tester.ensureVisible(find.text('Preview matches'));
      await tester.tap(find.text('Preview matches'));
      await tester.pumpAndSettle();
      expect(find.text('1 matches · 1 eligible for this rule'), findsOneWidget);
      await tester.ensureVisible(find.text('Save rule'));
      await tester.tap(find.text('Save rule'));
      await tester.pumpAndSettle();
      expect(saved?['groups'], [
        [
          {'field': 'description', 'operator': 'contains', 'value': 'shop'},
          {'field': 'description', 'operator': 'contains', 'value': 'test'},
        ],
        [
          {'field': 'description', 'operator': 'contains', 'value': 'market'},
        ],
      ]);
      expect(find.text('Test rule'), findsOneWidget);
      await tester.ensureVisible(find.text('Overview'));
      await tester.tap(find.text('Overview'));
      await tester.pumpAndSettle();
      expect(find.text('Spent'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [390.0, 1100.0]) {
    testWidgets('Dashboard and preferences fit at $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final snapshot = data([
        payment('Groceries', '2026-09-24', -5432, 'Food'),
        payment('salary', '2026-09-01', 250000, 'Salary'),
      ]);
      final ledger = Ledger(
        clock: () => DateTime(2026, 9, 27),
        client: MockClient(
          (r) async => http.Response(
            jsonEncode(r.method == 'GET' ? snapshot : {'ok': true}),
            200,
          ),
        ),
      );
      ledger.ingest(snapshot);
      await tester.pumpWidget(MoneyTrackerApp(ledger: ledger));
      await tester.pumpAndSettle();
      expect(find.text('Spent'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final preferences = find.byTooltip('Preferences').evaluate().isNotEmpty
          ? find.byTooltip('Preferences')
          : find.text('Preferences').first;
      await tester.ensureVisible(preferences);
      await tester.tap(preferences);
      await tester.pumpAndSettle();
      expect(find.text('Calendar month'), findsOneWidget);
      await tester.tap(find.text('Since last salary'));
      await tester.pumpAndSettle();
      expect(ledger.period, 'salary');
      await tester.ensureVisible(find.text('Overview'));
      await tester.ensureVisible(find.text('Overview'));
      await tester.tap(find.text('Overview'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Example Groceries'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Example Groceries'));
      await tester.pumpAndSettle();
      expect(find.text('Purchase details'), findsOneWidget);
      expect(find.text('Save category'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
