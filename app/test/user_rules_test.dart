import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_tracker/category_picker.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/main.dart';
import 'package:money_tracker/rule_pool_picker.dart';
import 'package:money_tracker/rules_page.dart';
import 'package:money_tracker_core/money_tracker_core.dart';
import 'widget_test.dart' show data, payment;

Map<String, dynamic> rule(String id, String text, {String? user}) => {
  'id': id,
  'name': 'Food',
  'kind': 'category',
  'category': 'Food',
  'enabled': true,
  'userId': ?user,
  'groups': [
    [
      {'field': 'description', 'operator': 'contains', 'value': text},
    ],
  ],
};

void main() {
  setUpAll(() async {
    await (FontLoader('MoneySans')
          ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  test(
    'pool defaults use current user, then canonical owner, and drafts copy only that pool',
    () {
      final l = Ledger()
        ..ingest({
          ...data([payment('p', '2026-10-01', -100, 'Food')]),
          'profiles': {
            'users': [
              {'id': 'alice', 'name': 'Alice'},
              {'id': 'bob', 'name': 'Bob'},
            ],
            'accountUsers': {'one': 'alice'},
          },
          'rules': [
            rule('shared', 'Shared'),
            rule('alice', 'Alice', user: 'alice'),
            rule('bob', 'Bob', user: 'bob'),
          ],
        });
      addTearDown(l.dispose);
      expect(l.defaultRuleUser(l.payments.single), 'alice');
      l.selectedUser = 'bob';
      expect(l.defaultRuleUser(l.payments.single), 'bob');
      l.selectedUser = 'all';
      expect(l.defaultRuleUser(), isNull);
      final personal = categoryRuleDraft(l, 'Food', userId: 'alice');
      expect(personal['id'], 'alice');
      expect(personal['userId'], 'alice');
      expect(personal['groups'].single.single['value'], 'Alice');
      final draft = ruleWithTransactionTerm(personal, 'New');
      expect(draft['userId'], 'alice');
      expect(draft['groups'].length, 2);
      expect(l.rules[1]['groups'].length, 1);
      expect(categoryRuleDraft(l, 'Food')['id'], 'shared');
    },
  );

  for (final width in [390.0, 1100.0]) {
    testWidgets(
      'configure pools and add personal/shared terms independently at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'moneytracker-rule-pools-ui-',
        );
        final service = MoneyTrackerService(
          temp.path,
          bankApi: (path, [body]) async =>
              throw StateError('Unexpected network'),
        );
        addTearDown(() async {
          await service.close();
          temp.deleteSync(recursive: true);
        });
        await service.store.write('ledger.json', {
          ...data([payment('merchant', '2026-10-01', -100, 'Uncategorized')]),
          'accounts': [
            {'id': 'one', 'label': 'Alice account', 'balance': 70000},
            {'id': 'two', 'label': 'Bob account', 'balance': 40000},
          ],
        });
        await service.store.write('profiles.json', {
          'users': [
            {'id': 'alice', 'name': 'Alice'},
            {'id': 'bob', 'name': 'Bob'},
          ],
          'accountUsers': {'one': 'alice', 'two': 'bob'},
        });
        await service.store.write('preferences.json', {
          'selectedUser': 'alice',
          'period': 'month',
        });
        await service.store.write('rules.json', [
          rule('shared', 'Common shop'),
          rule('alice', 'Alice shop', user: 'alice'),
          rule('bob', 'Bob shop', user: 'bob'),
        ]);
        final l = Ledger(
          clock: () => DateTime(2026, 10, 26),
          client: MockClient((r) async {
            final result = await service.request(
              r.method,
              r.url.path,
              r.body.isEmpty
                  ? {}
                  : Map<String, dynamic>.from(jsonDecode(r.body)),
            );
            return http.Response(jsonEncode(result.data), result.status);
          }),
        )..ingest(service.store.snapshot());
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MoneyTrackerApp(ledger: l),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> click(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        Future<void> pool(String? id) async {
          await click(find.byType(RulePoolPicker));
          await click(find.text(l.rulePoolName(id)).last);
        }

        Future<void> chooseFood() async {
          final choice = find.byKey(const ValueKey('choose-category-Food'));
          final scroll = find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(Scrollable),
              )
              .first;
          for (
            var i = 0;
            i < 20 && choice.hitTestable().evaluate().isEmpty;
            i++
          ) {
            await tester.drag(scroll, const Offset(0, -100));
            await tester.pumpAndSettle();
          }
          expect(choice.hitTestable(), findsOneWidget);
          await tester.tap(choice);
          await tester.pumpAndSettle();
        }

        Future<void> capture(String name) async {
          if (!const bool.fromEnvironment('RULE_POOL_SCREENSHOTS')) return;
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '/tmp/moneytracker-rule-pools-$name-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await click(find.text('Rules').first);
        expect(find.text('Alice: personal rules'), findsOneWidget);
        await capture('page');
        await click(find.text('New rule'));
        expect(find.text('Alice: personal rules'), findsOneWidget);
        await click(find.byTooltip('Back'));
        l.selectedUser = 'bob';
        l.changed();
        await tester.pumpAndSettle();
        expect(find.text('Bob: personal rules'), findsOneWidget);
        l.selectedUser = 'alice';
        l.changed();
        await tester.pumpAndSettle();
        expect(find.text('Alice: personal rules'), findsOneWidget);

        await click(find.byKey(const ValueKey('category-rule-Food')));
        expect(find.text('Alice shop'), findsOneWidget);
        expect(find.text('Common shop'), findsNothing);
        expect(find.text('Bob shop'), findsNothing);
        await click(find.byTooltip('Back'));
        await pool(null);
        await click(find.byKey(const ValueKey('category-rule-Food')));
        expect(find.text('Common shop'), findsOneWidget);
        expect(find.text('Alice shop'), findsNothing);
        await click(find.byTooltip('Back'));
        await pool('bob');
        await click(
          find.widgetWithText(SwitchListTile, 'Apply shared rules for Bob'),
        );
        expect(
          service.store.read('profiles.json', {})['users'][1]['useSharedRules'],
          false,
        );
        expect(l.users[0]['useSharedRules'], isNull);
        await click(
          find.widgetWithText(SwitchListTile, 'Apply personal rules for Bob'),
        );
        expect(
          service.store.read(
            'profiles.json',
            {},
          )['users'][1]['usePersonalRules'],
          false,
        );

        await click(find.text('Overview').first);

        Future<void> openAddTerm() async {
          await click(find.byKey(const ValueKey('category-merchant')));
          await click(find.text('Add term to existing rule'));
        }

        await openAddTerm();
        expect(find.byType(CategoryPicker), findsOneWidget);
        expect(find.text('Alice: personal rules'), findsOneWidget);
        await capture('add-term');
        await chooseFood();
        expect(find.text('Alice shop'), findsOneWidget);
        expect(find.text('Example merchant'), findsOneWidget);
        expect(find.text('Common shop'), findsNothing);
        expect(find.text('Bob shop'), findsNothing);
        await capture('editor');
        await click(find.text('Save rule'));
        expect(l.payments.single.category, 'Food');
        final stored = service.store.read('rules.json', []) as List;
        expect(
          stored.singleWhere((r) => r['id'] == 'alice')['groups'].length,
          2,
        );
        expect(
          stored.singleWhere((r) => r['id'] == 'shared')['groups'].length,
          1,
        );
        expect(stored.singleWhere((r) => r['id'] == 'bob')['groups'].length, 1);

        await openAddTerm();
        await pool(null);
        await chooseFood();
        expect(find.text('Common shop'), findsOneWidget);
        expect(find.text('Alice shop'), findsNothing);
        await click(find.text('Save rule'));
        final updated = service.store.read('rules.json', []) as List;
        expect(
          updated.singleWhere((r) => r['id'] == 'shared')['groups'].length,
          2,
        );
        expect(
          updated.singleWhere((r) => r['id'] == 'alice')['groups'].length,
          2,
        );
        expect(
          updated.singleWhere((r) => r['id'] == 'bob')['groups'].length,
          1,
        );
        expect(l.payments.single.ruleName, 'Food');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
