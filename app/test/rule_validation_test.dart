import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/rules_page.dart';
import 'widget_test.dart' show data;

void main() {
  testWidgets(
    'Seeded text survives reselecting Description and saves without preview',
    (tester) async {
      Map<String, dynamic>? saved;
      final l = Ledger(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/save')) saved = jsonDecode(r.body)['rule'];
          return http.Response(
            jsonEncode(r.method == 'GET' ? data([]) : {'ok': true}),
            200,
          );
        }),
      );
      l.ingest(data([]));
      await tester.pumpWidget(
        MaterialApp(
          home: RuleEditor(
            ledger: l,
            rule: {
              'name': 'Merchant rule',
              'category': 'Food',
              'enabled': true,
              'groups': [
                [
                  {
                    'field': 'description',
                    'operator': 'contains',
                    'value': 'Original merchant',
                  },
                ],
              ],
            },
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('rule-category-selector')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('choose-category-Shopping')),
      );
      await tester.tap(find.byKey(const ValueKey('choose-category-Shopping')));
      await tester.pumpAndSettle();
      for (final field in [
        'Description',
        'Source',
        'Direction',
        'Description',
      ]) {
        final selector = find.byType(DropdownButtonFormField<String>).first;
        await tester.ensureVisible(selector);
        await tester.tap(selector);
        await tester.pumpAndSettle();
        await tester.tap(find.text(field).last);
        await tester.pumpAndSettle();
      }
      expect(find.text('Original merchant'), findsOneWidget);
      await tester.ensureVisible(find.text('Save rule'));
      await tester.tap(find.text('Save rule'));
      await tester.pumpAndSettle();
      expect(saved?['groups'][0][0]['value'], 'Original merchant');
      expect(saved?['category'], 'Shopping');
      l.dispose();
    },
  );
}
