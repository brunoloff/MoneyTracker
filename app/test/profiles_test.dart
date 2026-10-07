import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/main.dart';
import 'widget_test.dart' show data, payment;

void main() {
  test('User views scope accounts, merged totals and salary dates', () async {
    Map<String, dynamic>? preference;
    final l = Ledger(
      clock: () => DateTime(2026, 9, 27),
      client: MockClient((r) async {
        preference = jsonDecode(r.body);
        return http.Response('{"ok":true}', 200);
      }),
    );
    final snapshot = data([
      payment('alice salary', '2026-09-10', 100000, 'Salary'),
      {
        ...payment('bob salary', '2026-09-20', 200000, 'Salary'),
        'accountId': 'two',
      },
      {
        ...payment('merged', '2026-09-25', -1000, 'Food'),
        'accountIds': ['one', 'two'],
      },
      {
        ...payment('unassigned', '2026-09-25', -2000, 'Food'),
        'accountId': 'three',
      },
    ]);
    snapshot['accounts'] = [
      {'id': 'one', 'label': 'A'},
      {'id': 'two', 'label': 'B'},
      {'id': 'three', 'label': 'C'},
    ];
    snapshot['profiles'] = {
      'users': [
        {'id': 'alice', 'name': 'Alice'},
        {'id': 'bob', 'name': 'Bob'},
      ],
      'accountUsers': {'one': 'alice', 'two': 'bob'},
    };
    l.ingest(snapshot);
    expect(l.spent, 3000);
    await l.selectUser('alice');
    expect(preference, {'selectedUser': 'alice'});
    expect(l.userAccounts.length, 1);
    expect(l.spent, 1000);
    expect(l.lastSalary, DateTime(2026, 9, 10));
    await l.selectUser('bob');
    expect(l.spent, 1000);
    expect(l.income, 200000);
    expect(l.lastSalary, DateTime(2026, 9, 20));
    await l.selectUser('unassigned');
    expect(l.spent, 2000);
    expect(l.lastSalary, isNull);
    l.dispose();
  });
  testWidgets('Preferences creates a user and persists account assignment', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final snapshot = data([]);
    Map<String, dynamic>? saved;
    final l = Ledger(
      client: MockClient((r) async {
        if (r.url.path == '/api/profiles') {
          saved = jsonDecode(r.body);
          snapshot['profiles'] = saved;
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
    await tester.tap(find.text('Preferences').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preferences-section-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add user'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'User name'),
      'Alice',
    );
    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preferences').first);
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alice').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save users and accounts'));
    await tester.tap(find.text('Save users and accounts'));
    await tester.pumpAndSettle();
    expect(saved?['users'][0]['name'], 'Alice');
    expect(saved?['accountUsers']['one'], saved?['users'][0]['id']);
    expect(find.text('Users and accounts saved.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
