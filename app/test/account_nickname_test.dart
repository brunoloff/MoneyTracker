import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/preferences_page.dart';
import 'widget_test.dart' show data;

void main() {
  testWidgets('Save and clear an account nickname', (tester) async {
    final snapshot = data([]);
    final ledger = Ledger(
      client: MockClient((request) async {
        if (request.url.path == '/api/profiles') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final nicknames = body['accountNicknames'] as Map<String, dynamic>;
          nicknames.removeWhere(
            (key, value) => (value as String).trim().isEmpty,
          );
          snapshot['profiles'] = body;
        }
        return http.Response(
          jsonEncode(request.method == 'GET' ? snapshot : {'ok': true}),
          200,
        );
      }),
    )..ingest(snapshot);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: PreferencesPage(ledger: ledger)),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('preferences-section-2')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('account-nickname-one'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'Everyday spending');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save users and accounts'));
    await tester.tap(find.text('Save users and accounts'));
    await tester.pumpAndSettle();
    expect(ledger.accountLabel('one'), 'Everyday spending');
    expect(ledger.accounts.single['label'], 'Current account');
    // A fresh bank label cannot overwrite the separately stored nickname.
    (snapshot['accounts'] as List).first['label'] = 'Updated bank label';
    ledger.ingest(snapshot);
    expect(ledger.accountLabel('one'), 'Everyday spending');
    await tester.ensureVisible(field);
    await tester.enterText(field, '');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save users and accounts'));
    await tester.tap(find.text('Save users and accounts'));
    await tester.pumpAndSettle();
    expect(ledger.accountLabel('one'), 'Updated bank label');
    expect(tester.takeException(), isNull);
    ledger.dispose();
  });
}
