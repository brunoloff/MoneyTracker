import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/taxonomy_settings.dart';
import 'classification_test.dart' show taxonomy;
import 'widget_test.dart' show data;
import 'golden_checks.dart';

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
    testWidgets('Compact categories edit and transfer at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final snapshot = {...data([]), 'taxonomy': taxonomy()};
      Map<String, dynamic>? saved;
      final ledger = Ledger(
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
      )..ingest(snapshot);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'MoneySans', useMaterial3: true),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: TaxonomySettings(ledger: ledger),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Manage categories and subcategories'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLinuxGolden(
        find.byType(MaterialApp),
        'goldens/categories-${width.toInt()}.png',
      );
      final food = find.byKey(const ValueKey('group-Food'));
      final name = find.descendant(
        of: food,
        matching: find.widgetWithText(TextFormField, 'Category name'),
      );
      await tester.enterText(name, 'Meals');
      final parentDelete = find.descendant(
        of: food,
        matching: find.byTooltip('Remove subcategories before deleting'),
      );
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: parentDelete,
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      final childDelete = find.descendant(
        of: food,
        matching: find.byTooltip('Delete category'),
      );
      await tester.tap(childDelete);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Move and delete'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Meals').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move and delete'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save categories and tags'));
      await tester.tap(find.text('Save categories and tags'));
      await tester.pumpAndSettle();
      expect(saved!['categoryTransfers'], {'groceries': 'Food'});
      expect(
        (saved!['categories'] as List).any((c) => c['id'] == 'groceries'),
        false,
      );
      expect(
        (saved!['categories'] as List).firstWhere(
          (c) => c['id'] == 'Food',
        )['name'],
        'Meals',
      );
      expect(tester.takeException(), isNull);
      ledger.dispose();
    });
  }
}
