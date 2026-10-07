import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/main.dart';
import 'widget_test.dart' show data, payment;

void main() {
  for (final width in [390.0, 1100.0]) {
    testWidgets('Undo and redo refresh the dashboard at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var undone = false;
      Map<String, dynamic> state() => {
        ...data(undone ? [] : [payment('x', '2026-09-08', -100, 'Food')]),
        'undoHistory': {
          'undo': undone ? null : 'Sync bank accounts',
          'redo': undone ? 'Sync bank accounts' : null,
        },
      };
      final l = Ledger(
        clock: () => DateTime(2026, 9, 28),
        client: MockClient((request) async {
          if (request.url.path == '/api/undo') {
            undone = true;
            return http.Response('{}', 200);
          }
          if (request.url.path == '/api/redo') {
            undone = false;
            return http.Response('{}', 200);
          }
          return http.Response(jsonEncode(state()), 200);
        }),
      );
      l.ingest(state());
      await tester.pumpWidget(MoneyTrackerApp(ledger: l));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Undo / redo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo: Sync bank accounts'));
      await tester.pumpAndSettle();
      expect(l.payments, isEmpty);
      expect(l.undoLabel, isNull);
      await tester.tap(find.byTooltip('Undo / redo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Redo: Sync bank accounts'));
      await tester.pumpAndSettle();
      expect(l.payments.length, 1);
      expect(l.redoLabel, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
