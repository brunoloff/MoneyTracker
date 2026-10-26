import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/main.dart';
import 'widget_test.dart' show data, payment;

void main() {
  test(
    'current totals follow the user across all accounts, dates and filters',
    () {
      final l = Ledger(clock: () => DateTime(2026, 10, 26));
      addTearDown(l.dispose);
      final snapshot = {
        ...data([
          payment('advance', '2024-01-01', -5000, borrowingCategory),
          payment('repaid', '2026-10-01', 2000, borrowingCategory),
          {
            ...payment('deposit', '2026-09-01', -1000, 'deposit'),
            'accountId': 'two',
          },
          {
            ...payment('merged', '2026-10-02', -500, borrowingCategory),
            'accountIds': ['one', 'two'],
          },
          {
            ...payment('bob', '2026-10-03', 8000, borrowingCategory),
            'accountId': 'three',
          },
          {
            ...payment('unassigned', '2026-10-04', -200, borrowingCategory),
            'accountId': 'four',
          },
          payment('expense', '2026-10-01', -700, 'Food'),
          payment(
            'pending',
            '2026-10-01',
            -99999,
            borrowingCategory,
            status: 'PDNG',
          ),
          {
            ...payment('ignored', '2026-10-01', -99999, borrowingCategory),
            'tags': ['ignored'],
          },
          payment('ignored category', '2026-10-01', -99999, 'Ignored'),
        ]),
        'accounts': [
          {'id': 'one', 'label': 'Current', 'balance': 10000},
          {'id': 'two', 'label': 'Card', 'balance': -3000},
          {'id': 'three', 'label': 'PayPal', 'balance': null},
          {'id': 'four', 'label': 'Savings', 'balance': 90000},
        ],
        'profiles': {
          'users': [
            {'id': 'alice', 'name': 'Alice'},
            {'id': 'bob', 'name': 'Bob'},
            {'id': 'empty', 'name': 'Empty'},
          ],
          'accountUsers': {'one': 'alice', 'two': 'alice', 'three': 'bob'},
        },
        'taxonomy': {
          'categories': [
            for (final c in categories) {'id': c, 'name': c, 'parent': null},
            {'id': 'deposit', 'name': 'Deposit', 'parent': borrowingCategory},
          ],
          'tags': [],
        },
      };
      l.ingest(snapshot);
      expect(l.accountBalance, 97000);
      expect(l.unavailableBalanceCount, 1);
      expect(l.borrowingBalance, 3300);
      l.selectedUser = 'alice';
      expect(l.accountBalance, 7000);
      expect(l.unavailableBalanceCount, 0);
      expect(l.borrowingBalance, -4500);
      l.filter(
        accountId: 'one',
        categoryName: 'Food',
        search: 'expense',
        flow: 'out',
      );
      l.tag = 'some tag';
      l.minimumAmount = 100000;
      l.month = DateTime(2020);
      l.period = 'salary';
      l.periodCount = 12;
      l.monthlyAverage = true;
      l.incomeMode = 'average';
      expect(l.accountBalance, 7000);
      expect(l.borrowingBalance, -4500);
      l.selectedUser = 'bob';
      expect(l.accountBalance, isNull);
      expect(l.unavailableBalanceCount, 1);
      expect(l.borrowingBalance, 8000);
      l.selectedUser = 'unassigned';
      expect(l.accountBalance, 90000);
      expect(l.unavailableBalanceCount, 0);
      expect(l.borrowingBalance, -200);
      l.selectedUser = 'empty';
      expect(l.accountBalance, isNull);
      expect(l.unavailableBalanceCount, 0);
      expect(l.borrowingBalance, 0);
    },
  );

  test(
    'totals refresh after sync, ownership and category changes; zero is known',
    () {
      final l = Ledger();
      addTearDown(l.dispose);
      final snapshot = {
        ...data([payment('advance', '2026-01-01', -1000, 'custom')]),
        'accounts': [
          {'id': 'one', 'label': 'Current', 'balance': 0},
        ],
        'profiles': {
          'users': [
            {'id': 'alice', 'name': 'Alice'},
          ],
          'accountUsers': {'one': 'alice'},
        },
        'preferences': {'selectedUser': 'alice'},
      };
      l.ingest(snapshot);
      expect(l.accountBalance, 0);
      expect(l.unavailableBalanceCount, 0);
      expect(l.borrowingBalance, 0);
      l.categorySettings = [
        ...l.categorySettings,
        {'id': 'custom', 'name': 'Custom', 'parent': borrowingCategory},
      ];
      expect(l.borrowingBalance, -1000);
      l.accountUsers = {};
      expect(l.accountBalance, isNull);
      expect(l.borrowingBalance, 0);
      l.ingest({
        ...snapshot,
        'transactions': [
          payment('advance', '2026-01-01', -600, borrowingCategory),
        ],
        'accounts': [
          {'id': 'one', 'label': 'Current', 'balance': 12000},
        ],
      });
      expect(l.accountBalance, 12000);
      expect(l.borrowingBalance, -600);
    },
  );

  for (final width in [390.0, 1100.0]) {
    testWidgets('current totals and unavailable balance states at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final l = Ledger(clock: () => DateTime(2026, 10, 26));
      final snapshot = {
        ...data([payment('advance', '2024-01-01', -15000, borrowingCategory)]),
        'accounts': [
          {'id': 'one', 'label': 'Current', 'balance': 70000},
          {'id': 'two', 'label': 'PayPal', 'balance': null},
        ],
      };
      l.ingest(snapshot);
      await tester.pumpWidget(MoneyTrackerApp(ledger: l));
      await tester.pumpAndSettle();
      final accounts = find.byKey(const ValueKey('account-balance'));
      final borrowing = find.byKey(const ValueKey('borrowing-balance'));
      expect(
        find.descendant(of: accounts, matching: find.text('€700.00')),
        findsOneWidget,
      );
      expect(
        find.text('Partial total · 1 of 2 balances unavailable.'),
        findsOneWidget,
      );
      expect(
        find.descendant(of: borrowing, matching: find.text('−€150.00')),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(accounts).dy,
        lessThan(tester.getTopLeft(find.text('Spent')).dy),
      );
      l.filter(accountId: 'two', search: 'nothing', categoryName: 'Food');
      l.moveMonth(-12);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: accounts, matching: find.text('€700.00')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: borrowing, matching: find.text('−€150.00')),
        findsOneWidget,
      );

      l.ingest({
        ...snapshot,
        'accounts': [
          {'id': 'one', 'label': 'Current'},
        ],
      });
      l.changed();
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: accounts, matching: find.text('—')),
        findsOneWidget,
      );
      expect(
        find.text('Balance unavailable for this account.'),
        findsOneWidget,
      );

      l.ingest({
        ...snapshot,
        'accounts': [
          {'id': 'one', 'label': 'Current', 'balance': 0},
        ],
      });
      l.changed();
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: accounts, matching: find.text('€0.00')),
        findsOneWidget,
      );
      expect(find.text('Latest reported balance · 1 account.'), findsOneWidget);

      l.ingest({...snapshot, 'accounts': []});
      l.changed();
      await tester.pumpAndSettle();
      expect(find.text('No accounts for this user.'), findsOneWidget);
      expect(
        find.descendant(of: borrowing, matching: find.text('€0.00')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
