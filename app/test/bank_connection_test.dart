import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_tracker/bank_connection.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/preferences_page.dart';
import 'widget_test.dart' show data;

void main() {
  for (final width in [390.0, 1100.0]) {
    testWidgets('Bankinter authorization and account refresh at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var connected = false;
      var refreshed = false;
      var approved = false;
      Map<String, dynamic> snapshot() => {
        ...data([]),
        'accounts': connected
            ? [
                {
                  'id': 'bankinter',
                  'label': 'Current account ··1234',
                  'source': 'Bankinter',
                },
              ]
            : [],
      };
      final ledger = Ledger(
        client: MockClient((r) async {
          final body = r.method == 'POST' ? jsonDecode(r.body) : {};
          Object response;
          switch (r.url.path) {
            case '/api/connections/banks':
              expect(body['country'], 'PT');
              response = {
                'banks': [
                  {'name': 'Bankinter', 'country': 'PT'},
                ],
              };
            case '/api/connections/start':
              expect(body['name'], 'Bankinter');
              response = {
                'url': 'https://auth.enablebanking.com/test',
                'attempt': 'test-attempt',
              };
            case '/api/connections/status':
              expect(body['attempt'], 'test-attempt');
              connected = approved;
              response = approved
                  ? {'status': 'complete', 'message': 'Bankinter connected.'}
                  : {'status': 'pending'};
            case '/api/sync':
              expect(body['target'], 'accounts');
              refreshed = true;
              response = {'syncing': false};
            default:
              response = snapshot();
          }
          return http.Response(jsonEncode(response), 200);
        }),
      )..ingest(snapshot());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PreferencesPage(ledger: ledger)),
          ),
        ),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('preferences-section-2')),
      );
      await tester.tap(find.byKey(const ValueKey('preferences-section-2')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Connect or renew a bank'));
      await tester.tap(find.text('Connect or renew a bank'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find banks'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bankinter').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Create authorization link'));
      await tester.tap(find.text('Create authorization link'));
      await tester.pumpAndSettle();
      expect(find.text('Open bank authorization'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Final callback URL'),
        findsNothing,
      );
      approved = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        find.byType(BankConnection),
        findsNothing,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join(' | '),
      );
      expect(ledger.accounts.single['source'], 'Bankinter');
      await tester.ensureVisible(find.text('Refresh Enable Banking accounts'));
      await tester.tap(find.text('Refresh Enable Banking accounts'));
      await tester.pumpAndSettle();
      expect(refreshed, true);
      expect(tester.takeException(), isNull);
      ledger.dispose();
    });
  }
}
