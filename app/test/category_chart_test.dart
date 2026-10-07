import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_tracker/main.dart';
import 'package:money_tracker/ledger.dart';
import 'classification_test.dart' show taxonomy;
import 'widget_test.dart' show data, payment;

void main() {
  for (final width in [390.0, 1100.0]) {
    testWidgets('Category chart expands, filters and collapses at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ledger = Ledger(clock: () => DateTime(2026, 9, 27));
      ledger.ingest({
        ...data([
          payment('grocery', '2026-09-01', -1000, 'groceries'),
          payment('meal', '2026-09-02', -2000, 'Food'),
        ]),
        'taxonomy': taxonomy(),
      });
      await tester.pumpWidget(MoneyTrackerApp(ledger: ledger));
      await tester.pumpAndSettle();
      final parent = find.byKey(const ValueKey('chart-category-Food'));
      final child = find.byKey(const ValueKey('chart-category-groceries'));
      expect(child, findsNothing);
      final passes = ledger.summaryPasses;
      await tester.ensureVisible(parent);
      await tester.tap(parent);
      await tester.pumpAndSettle();
      expect(child, findsOneWidget);
      expect(ledger.category, 'all');
      expect(ledger.directCategoryTotals['groceries'], 1000);
      expect(ledger.totals['Food'], 3000);
      await tester.tap(find.byKey(const ValueKey('chart-bar-groceries')));
      await tester.pumpAndSettle();
      expect(ledger.visible.map((p) => p.id), ['grocery']);
      expect(ledger.summaryPasses, passes);
      await tester.tap(parent);
      await tester.pumpAndSettle();
      expect(child, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
