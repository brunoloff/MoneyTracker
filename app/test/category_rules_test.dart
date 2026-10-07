import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/rules_page.dart';
import 'classification_test.dart' show taxonomy;
import 'widget_test.dart' show data;

void main() {
  setUpAll(() async {
    await (FontLoader(
      'MoneySans',
    )..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final width in [390.0, 1100.0]) {
    testWidgets(
      'Category rules consolidate and empty subcategories can be edited at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final snapshot = {
          ...data([]),
          'taxonomy': taxonomy(),
          'rules': [
            for (final name in ['Supermarket', 'Restaurant'])
              {
                'id': name,
                'name': name,
                'category': 'Food',
                'enabled': true,
                'groups': [
                  [
                    {
                      'field': 'description',
                      'operator': 'contains',
                      'value': name,
                    },
                  ],
                ],
              },
          ],
        };
        Map<String, dynamic>? saved;
        final ledger = Ledger(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/save')) {
              saved = jsonDecode(r.body)['rule'];
            }
            return http.Response(
              jsonEncode(r.method == 'GET' ? snapshot : {'ok': true}),
              200,
            );
          }),
        )..ingest(snapshot);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              theme: ThemeData(fontFamily: 'MoneySans', useMaterial3: true),
              home: Scaffold(
                body: SingleChildScrollView(child: RulesPage(ledger: ledger)),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> capture(String name) async {
          if (!const bool.fromEnvironment('RULE_SCREENSHOTS')) return;
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '/tmp/moneytracker-$name-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('rules');
        await tester.tap(find.byKey(const ValueKey('category-rule-Food')));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextFormField, 'Rule name'), findsNothing);
        expect(find.text('Supermarket'), findsOneWidget);
        expect(find.text('Restaurant'), findsOneWidget);
        await capture('rule-editor');
        await tester.ensureVisible(find.text('Save rule'));
        await tester.tap(find.text('Save rule'));
        await tester.pumpAndSettle();
        expect(saved!['kind'], 'category');
        expect(saved!['groups'].length, 2);
        await tester.ensureVisible(
          find.byKey(const ValueKey('category-rule-groceries')),
        );
        await tester.tap(find.byKey(const ValueKey('category-rule-groceries')));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextFormField, 'Match text'), findsNothing);
        await tester.tap(find.text('OR group'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Match text'),
          'Corner shop',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Save rule'));
        await tester.tap(find.text('Save rule'));
        await tester.pumpAndSettle();
        expect(saved!['category'], 'groceries');
        expect(saved!['groups'][0][0]['value'], 'Corner shop');
        expect(tester.takeException(), isNull);
        ledger.dispose();
      },
    );
  }
  testWidgets('An additional rule can add tags without assigning a category', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    final snapshot = {...data([]), 'taxonomy': taxonomy()};
    final ledger = Ledger(
      client: MockClient((r) async {
        if (r.url.path.endsWith('/save')) saved = jsonDecode(r.body)['rule'];
        return http.Response(
          jsonEncode(r.method == 'GET' ? snapshot : {'ok': true}),
          200,
        );
      }),
    )..ingest(snapshot);
    await tester.pumpWidget(MaterialApp(home: RuleEditor(ledger: ledger)));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Rule name'),
      'Work receipts',
    );
    await tester.tap(find.byKey(const ValueKey('rule-category-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep category unchanged'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Work'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Match text'),
      'Company',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save rule'));
    await tester.tap(find.text('Save rule'));
    await tester.pumpAndSettle();
    expect(saved!['category'], isNull);
    expect(saved!['tags'], ['work']);
    expect(saved!['kind'], 'extra');
    expect(tester.takeException(), isNull);
    ledger.dispose();
  });
}
