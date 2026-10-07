import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/main.dart';
import 'package:money_tracker/rules_page.dart';
import 'package:money_tracker/category_picker.dart';
import 'classification_test.dart' show taxonomy;
import 'widget_test.dart' show data, payment;

Map<String, dynamic> existing() => {
  'id': 'existing',
  'name': 'Groceries',
  'category': 'Food',
  'enabled': true,
  'groups': [
    [
      {'field': 'description', 'operator': 'contains', 'value': 'old shop'},
      {'field': 'direction', 'operator': 'equals', 'value': 'expense'},
    ],
  ],
};
void main() {
  test('Adds a top-level OR group without mutating the original AND group', () {
    final original = existing();
    final draft = ruleWithTransactionTerm(original, 'New shop');
    expect(original['groups'].length, 1);
    expect(draft['id'], original['id']);
    expect(draft['groups'][0], original['groups'][0]);
    expect(draft['groups'][1], [
      {'field': 'description', 'operator': 'contains', 'value': 'New shop'},
    ]);
    original['groups'] = List.generate(2000, (_) => []);
    expect(() => ruleWithTransactionTerm(original, 'Shop'), throwsStateError);
  });
  for (final width in [390.0, 1100.0]) {
    for (final target in ['Food', 'groceries', 'tag-rule']) {
      testWidgets('Transaction adds term to $target at $width', (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final snapshot = {
          ...data([payment('new-shop', '2026-09-20', -100, 'Food')]),
          'taxonomy': taxonomy(),
          'rules': [
            existing(),
            {
              ...existing(),
              'id': 'tag-rule',
              'name': 'Work purchases',
              'kind': 'extra',
              'category': null,
              'tags': ['work'],
            },
            {
              ...existing(),
              'id': 'paused-rule',
              'name': 'Paused exception',
              'enabled': false,
            },
            {
              ...existing(),
              'id': 'full-rule',
              'category': 'Shopping',
              'groups': List.generate(
                2000,
                (i) => [
                  {
                    'field': 'description',
                    'operator': 'contains',
                    'value': '$i',
                  },
                ],
              ),
            },
          ],
        };
        Map<String, dynamic>? saved;
        final l = Ledger(
          clock: () => DateTime(2026, 9, 27),
          client: MockClient((r) async {
            if (r.url.path.endsWith('/save')) {
              saved = jsonDecode(r.body)['rule'];
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
        String? clipboard;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = call.arguments['text'];
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final merchant = find.text('Example new-shop').first;
        await tester.ensureVisible(merchant);
        await tester.tap(merchant);
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(SelectableText, 'Example new-shop'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Copy description').first);
        await tester.pumpAndSettle();
        expect(clipboard, 'Example new-shop');
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
        await tester.pumpAndSettle();
        final chip = find.byKey(const ValueKey('category-new-shop'));
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
        final action = find.text('Add term to existing rule');
        await tester.ensureVisible(action);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(find.byType(CategoryPicker), findsOneWidget);
        expect(find.text('Labels'), findsOneWidget);
        final fullChip = find.byKey(const ValueKey('choose-category-Shopping'));
        expect(tester.widget<ActionChip>(fullChip).onPressed, isNull);
        final dialogScroll = find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text('Other rules'),
          150,
          scrollable: dialogScroll,
        );
        expect(find.text('Other rules'), findsOneWidget);
        expect(
          find.textContaining('Maximum of 2000 OR groups'),
          findsOneWidget,
        );
        expect(
          tester
              .getTopLeft(find.textContaining('Maximum of 2000 OR groups'))
              .dy,
          lessThan(tester.getTopLeft(find.text('Other rules')).dy),
        );
        await tester.scrollUntilVisible(
          find.text('Paused exception'),
          100,
          scrollable: dialogScroll,
        );
        expect(find.text('Paused exception'), findsOneWidget);
        final choice = target == 'tag-rule'
            ? find.text('Work purchases')
            : find.byKey(ValueKey('choose-category-$target'));
        if (target != 'tag-rule') {
          tester.state<ScrollableState>(dialogScroll).position.jumpTo(0);
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(choice);
        await tester.tap(choice);
        await tester.pumpAndSettle();
        expect(saved, isNull);
        expect(l.rules.first['groups'].length, 1);
        await tester.ensureVisible(find.text('Save rule'));
        await tester.tap(find.text('Save rule'));
        await tester.pumpAndSettle();
        if (target == 'groceries') {
          expect(saved?['category'], 'groceries');
          expect(saved?['groups'].length, 1);
          expect(saved?['groups'][0][0]['value'], 'Example new-shop');
        } else {
          expect(saved?['id'], target == 'Food' ? 'existing' : 'tag-rule');
          expect(saved?['groups'][0], existing()['groups'][0]);
          expect(saved?['groups'][1][0]['value'], 'Example new-shop');
          if (target == 'tag-rule') {
            expect(saved?['category'], isNull);
            expect(saved?['tags'], ['work']);
          }
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
