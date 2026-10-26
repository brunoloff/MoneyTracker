import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_tracker/borrowing_page.dart';
import 'package:money_tracker/category_picker.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/main.dart';
import 'package:money_tracker_core/money_tracker_core.dart';
import 'widget_test.dart' show data, payment;

void main() {
  setUpAll(() async {
    await (FontLoader(
      'MoneySans',
    )..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  test(
    'special categories and their children are excluded from all income and expense summaries',
    () {
      final l = Ledger(clock: () => DateTime(2026, 10, 26));
      addTearDown(l.dispose);
      l.ingest({
        ...data([
          payment('food', '2026-10-01', -300, 'Food'),
          payment('salary', '2026-10-01', 10000, 'Salary'),
          payment('sep-pay', '2026-09-01', 9000, 'Salary'),
          for (final category in [
            borrowingCategory,
            'Ignored',
            'Transfer',
            'work-advance',
          ]) ...[
            payment('$category-out', '2026-10-01', -10000, category),
            payment('$category-in', '2026-10-01', 10000, category),
            payment('$category-old', '2026-09-01', 10000, category),
          ],
          {
            ...payment('legacy ignored', '2026-10-01', -90000, 'Food'),
            'tags': ['ignored'],
          },
        ]),
        'taxonomy': {
          'categories': [
            for (final c in categories) {'id': c, 'name': c, 'parent': null},
            {
              'id': 'work-advance',
              'name': 'Work advance',
              'parent': borrowingCategory,
            },
          ],
          'tags': [],
        },
      });
      expect(l.spent, 300);
      expect(l.income, 10000);
      expect(l.displayedNet, 9700);
      expect(l.totals, {'Food': 300});
      l.incomeMode = 'last_month';
      expect(l.displayedIncome, 9000);
      l.incomeMode = 'average';
      l.incomeAverageMonths = 3;
      expect(l.displayedIncome, 3000);
      l.category = borrowingCategory;
      expect(
        l.visible.length,
        4,
      ); // Both the category and its child remain visible.
    },
  );
  testWidgets(
    'shared selector puts stable special categories before ordinary categories',
    (tester) async {
      final l = Ledger();
      addTearDown(l.dispose);
      l.categorySettings = [
        for (final c in categories.reversed)
          {'id': c, 'name': c, 'parent': null},
      ];
      expect(
        l.categoryIds.take(specialCategoryOrder.length),
        specialCategoryOrder,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CategoryPicker(
                ledger: l,
                selected: 'Food',
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      final chips = tester.widgetList<ActionChip>(find.byType(ActionChip));
      expect(
        chips.take(6).map((c) => (c.label as Text).data),
        specialCategoryOrder,
      );
    },
  );
  for (final width in [390.0, 1100.0]) {
    testWidgets(
      'create, classify, nest and restore a borrowing group at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = Directory.systemTemp.createTempSync(
          'moneytracker-borrowing-ui-',
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
        await service.store.write(
          'ledger.json',
          data([
            {
              ...payment('hotel', '2026-10-01', -10000, borrowingCategory),
              'currency': 'EUR',
            },
            {
              ...payment('train', '2026-10-02', -2000, borrowingCategory),
              'currency': 'EUR',
            },
            {
              ...payment('refund', '2026-10-03', 9000, borrowingCategory),
              'currency': 'EUR',
            },
            {
              ...payment('later', '2026-10-04', 3000, borrowingCategory),
              'currency': 'EUR',
            },
          ]),
        );
        final l = Ledger(
          clock: () => DateTime(2026, 10, 26),
          client: MockClient((r) async {
            final response = await service.request(
              r.method,
              r.url.path,
              r.body.isEmpty
                  ? {}
                  : Map<String, dynamic>.from(jsonDecode(r.body)),
            );
            return http.Response(jsonEncode(response.data), response.status);
          }),
        )..ingest(service.store.snapshot());
        addTearDown(l.dispose);
        expect(l.borrowingBalance, 0);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              theme: ThemeData(
                fontFamily: 'MoneySans',
                useMaterial3: true,
                colorSchemeSeed: const Color(0xff008f84),
              ),
              home: BorrowingPage(ledger: l),
            ),
          ),
        );
        Future<void> click(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        Future<void> capture(String name) async {
          if (!const bool.fromEnvironment('BORROWING_SCREENSHOTS')) return;
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

        await tester.enterText(
          find.widgetWithText(TextField, 'Group name'),
          'Business trip to Paris',
        );
        for (final id in ['hotel', 'train', 'refund']) {
          await click(find.byKey(ValueKey('borrow-select-$id')));
        }
        expect(find.text('3 selected · Leftover −€30.00'), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const ValueKey('create-borrowing-group')),
        );
        await capture('borrowing-create');
        await click(find.byKey(const ValueKey('create-borrowing-group')));
        expect(l.borrowingGroups.length, 1);
        expect(l.payments.length, 2);
        expect(l.spent, 0);
        expect(l.borrowingBalance, 0);
        final parent = l.borrowingGroups.single;
        await click(find.byKey(ValueKey('borrowing-group-${parent.id}')));
        expect(find.text('Leftover −€30.00'), findsOneWidget);
        await capture('borrowing-group');
        await click(find.byKey(const ValueKey('classify-leftover')));
        await click(find.byKey(const ValueKey('choose-category-Travel')));
        await click(find.text('Save category'));
        expect(l.spent, 3000);
        expect(l.displayedNet, -3000);
        expect(l.borrowingBalance, 3000);
        await click(find.byKey(const ValueKey('classify-leftover')));
        await click(
          find.byKey(const ValueKey('choose-category-Borrowing and Deposits')),
        );
        await click(find.text('Save category'));
        expect(l.spent, 0);
        expect(l.borrowingBalance, 0);
        await click(find.byTooltip('Back'));
        await tester.ensureVisible(
          find.widgetWithText(TextField, 'Group name'),
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Group name'),
          'Final repayment',
        );
        await click(
          find.byKey(ValueKey('borrow-select-${parent.leftover.id}')),
        );
        await click(find.byKey(const ValueKey('borrow-select-later')));
        await click(find.byKey(const ValueKey('create-borrowing-group')));
        expect(l.borrowingGroups.length, 2);
        expect(l.payments.single.amount, 0);
        expect(l.borrowingBalance, 0);
        final child = l.borrowingGroups.last;
        await click(find.byKey(ValueKey('borrowing-group-${parent.id}')));
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const ValueKey('delete-borrowing-group')),
              )
              .onPressed,
          isNull,
        );
        await click(find.text('View later group'));
        await click(find.byKey(const ValueKey('delete-borrowing-group')));
        await click(find.widgetWithText(FilledButton, 'Delete group'));
        expect(l.borrowingGroups.length, 1);
        expect(l.borrowingGroups.any((g) => g.id == child.id), false);
        await click(find.byKey(const ValueKey('delete-borrowing-group')));
        await click(find.widgetWithText(FilledButton, 'Delete group'));
        expect(l.borrowingGroups, isEmpty);
        expect(l.payments.length, 4);
        expect(l.borrowingBalance, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('a virtual payment links to its group from the dashboard', (
    tester,
  ) async {
    final leftover = {
      ...payment('leftover', '2026-10-03', -1000, borrowingCategory),
      'settlementGroupId': 'trip',
    };
    final l = Ledger(clock: () => DateTime(2026, 10, 26))
      ..ingest({
        ...data([leftover]),
        'borrowingGroups': [
          {
            'id': 'trip',
            'description': 'Work trip',
            'transactions': [
              payment('hotel', '2026-10-01', -1000, borrowingCategory),
            ],
            'leftover': leftover,
          },
        ],
      });
    await tester.pumpWidget(MoneyTrackerApp(ledger: l));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Example leftover').first,
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Example leftover').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('view-borrowing-group')),
    );
    await tester.tap(find.byKey(const ValueKey('view-borrowing-group')));
    await tester.pumpAndSettle();
    expect(find.text('Work trip'), findsOneWidget);
    expect(find.text('Borrowing group'), findsOneWidget);
  });
}
