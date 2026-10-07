import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/main.dart';
import 'package:money_tracker/taxonomy_settings.dart';
import 'package:money_tracker/rules_page.dart';
import 'widget_test.dart' show payment, data;

Map<String, dynamic> taxonomy() => {
  'categories': [
    for (final c in categories)
      {'id': c, 'name': c, 'parent': null, 'color': '008F84'},
    {
      'id': 'groceries',
      'name': 'Groceries',
      'parent': 'Food',
      'color': '00A5AA',
    },
  ],
  'tags': [
    {'id': 'holiday', 'name': 'Holiday'},
    {'id': 'work', 'name': 'Work'},
  ],
};
void main() {
  test('Subcategories roll up while category and tag filters intersect', () {
    final l = Ledger(clock: () => DateTime(2026, 9, 27));
    l.ingest({
      ...data([
        {
          ...payment('groceries', '2026-09-01', -1000, 'groceries'),
          'tags': ['holiday'],
        },
        {
          ...payment('meal', '2026-09-01', -2000, 'Food'),
          'tags': ['work'],
        },
        {
          ...payment('hotel', '2026-09-01', -5000, 'Travel'),
          'tags': ['holiday'],
        },
      ]),
      'taxonomy': taxonomy(),
    });
    expect(l.totals, {'Travel': 5000, 'Food': 3000});
    l.filter(categoryName: 'Food');
    l.tag = 'holiday';
    expect(l.visible.map((p) => p.id), ['groceries']);
    l.tag = 'all';
    l.filter(search: 'work');
    expect(l.visible.map((p) => p.id), ['meal']);
    expect(l.spent, 8000);
    l.dispose();
  });
  testWidgets('Settings saves a new subcategory and tag', (tester) async {
    final snapshot = {...data([]), 'taxonomy': taxonomy()};
    Map<String, dynamic>? saved;
    final l = Ledger(
      client: MockClient((r) async {
        if (r.url.path == '/api/taxonomy') {
          saved = jsonDecode(r.body);
          snapshot['taxonomy'] = saved;
        }
        return http.Response(
          jsonEncode(r.method == 'GET' ? snapshot : {'ok': true}),
          200,
        );
      }),
    );
    l.ingest(snapshot);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: TaxonomySettings(ledger: l)),
        ),
      ),
    );
    await tester.tap(find.text('Manage categories and subcategories'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('add-subcategory-Food')),
    );
    await tester.tap(find.byKey(const ValueKey('add-subcategory-Food')));
    await tester.pumpAndSettle();
    final group = find.byKey(const ValueKey('group-Food'));
    final subcategory = find
        .descendant(
          of: group,
          matching: find.widgetWithText(TextFormField, 'Subcategory name'),
        )
        .last;
    await tester.ensureVisible(subcategory);
    await tester.enterText(subcategory, 'Restaurants');
    await tester.ensureVisible(find.text('Manage tags'));
    await tester.tap(find.text('Manage tags'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add tag'));
    await tester.tap(find.text('Add tag'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.widgetWithText(TextFormField, 'Tag name').last,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Tag name').last,
      'Reimbursable',
    );
    await tester.ensureVisible(find.text('Save categories and tags'));
    await tester.tap(find.text('Save categories and tags'));
    await tester.pumpAndSettle();
    expect(saved?['categories'].last['parent'], 'Food');
    expect(saved?['categories'].last['name'], 'Restaurants');
    expect(saved?['tags'].last['name'], 'Reimbursable');
    expect(find.text('Categories and tags saved.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    l.dispose();
  });
  for (final width in [390.0, 1100.0]) {
    testWidgets(
      'Bubble selects subcategory, saves tags and seeds rule at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final row = payment('purchase', '2026-09-24', -1000, 'Other');
        final snapshot = {
          ...data([row]),
          'taxonomy': taxonomy(),
        };
        final l = Ledger(
          clock: () => DateTime(2026, 9, 27),
          client: MockClient((r) async {
            if (r.url.path == '/api/category') {
              row['category'] = jsonDecode(r.body)['category'];
            }
            if (r.url.path == '/api/tags') {
              row['tags'] = jsonDecode(r.body)['tags'];
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
        Future<void> openPicker() async {
          await tester.ensureVisible(
            find.byKey(const ValueKey('category-purchase')),
          );
          await tester.tap(find.byKey(const ValueKey('category-purchase')));
          await tester.pumpAndSettle();
          expect(find.text('Choose a category'), findsOneWidget);
          expect(find.text('Purchase details'), findsNothing);
        }

        await openPicker();
        final chip = find.widgetWithText(ActionChip, 'Food / Groceries');
        await tester.ensureVisible(chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
        expect(l.payments.single.category, 'groceries');
        await openPicker();
        await tester.ensureVisible(find.widgetWithText(FilterChip, 'Holiday'));
        await tester.tap(find.widgetWithText(FilterChip, 'Holiday'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Save tags'));
        await tester.tap(find.text('Save tags'));
        await tester.pumpAndSettle();
        expect(l.payments.single.tags, ['holiday']);
        await openPicker();
        await tester.ensureVisible(
          find.text('Make rule based on this transaction'),
        );
        await tester.tap(find.text('Make rule based on this transaction'));
        await tester.pumpAndSettle();
        final input = tester.widget<EditableText>(
          find.descendant(
            of: find.widgetWithText(TextFormField, 'Match text'),
            matching: find.byType(EditableText),
          ),
        );
        expect(input.controller.text, 'Example purchase');
        expect(find.byType(RuleEditor), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
