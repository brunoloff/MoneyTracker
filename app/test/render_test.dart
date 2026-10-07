import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_tracker/main.dart';
import 'package:money_tracker/ledger.dart';
import 'golden_checks.dart';

void main() {
  setUpAll(() async {
    final fonts = FontLoader('MoneySans')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    await fonts.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final width in [390.0, 1100.0]) {
    testWidgets('Render dashboard $width', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final l = Ledger(clock: () => DateTime(2026, 9, 27));
      final names = [
        'Grocery store',
        'Bookshop',
        'Weekend hotel',
        'Internet provider',
        'Other purchase',
        'Salary',
      ];
      final cats = ['Food', 'Shopping', 'Travel', 'Bills', 'Other', 'Salary'];
      final amounts = [-41200, -29800, -23700, -20100, -13600, 250000];
      l.ingest({
        'accounts': [
          {'id': 'one', 'label': 'Current account'},
        ],
        'syncedAt': '2026-09-27T10:00:00Z',
        'preferences': {'period': 'month'},
        'transactions': List.generate(
          6,
          (i) => {
            'id': '$i',
            'accountId': 'one',
            'description': names[i],
            'amount': amounts[i],
            'category': cats[i],
            'date': '2026-09-${24 - i}',
            'source': 'Example bank',
            'status': 'BOOK',
            'reviewed': i == 5,
          },
        ),
      });
      await tester.pumpWidget(MoneyTrackerApp(ledger: l));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLinuxGolden(
        find.byType(MaterialApp),
        'goldens/dashboard-${width.toInt()}.png',
      );
    });
  }
}
