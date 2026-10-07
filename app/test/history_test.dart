import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/main.dart';
import 'widget_test.dart' show data;

void main() {
  for (final width in [390.0, 1100.0]) {
    testWidgets('Download older history from preferences at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Map<String, dynamic>? request;
      final snapshot = data([]);
      final l = Ledger(
        client: MockClient((r) async {
          if (r.url.path == '/api/history') {
            request = jsonDecode(r.body);
            snapshot['historyImport'] = {
              'years': 3,
              'requestedFrom': '2023-09-27',
              'completedAt': '2026-09-27T12:00:00Z',
              'added': 42,
              'accounts': [
                {
                  'label': 'Test account',
                  'count': 42,
                  'earliest': '2024-01-01',
                },
              ],
            };
          }
          return http.Response(
            jsonEncode(r.method == 'GET' ? snapshot : {'syncing': true}),
            200,
          );
        }),
      );
      l.ingest(snapshot);
      await tester.pumpWidget(MoneyTrackerApp(ledger: l));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byTooltip('Preferences').evaluate().isNotEmpty
            ? find.byTooltip('Preferences')
            : find.text('Preferences').first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('preferences-section-1')),
      );
      await tester.tap(find.byKey(const ValueKey('preferences-section-1')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(DropdownButtonFormField<int>, 'Years back'),
      );
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<int>, 'Years back'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('3').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Download history'));
      await tester.tap(find.text('Download history'));
      await tester.pumpAndSettle();
      expect(request, {'years': 3});
      expect(find.textContaining('42 new records'), findsOneWidget);
      expect(find.textContaining('earliest 2024-01-01'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
