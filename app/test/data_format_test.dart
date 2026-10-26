import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_tracker/data_format_panel.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/main.dart';
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
      'format notice is clear, acknowledges once, and stays available in Preferences at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final snapshot = {
          ...data([]),
          'dataFormat': {
            'version': 4,
            'journalVersion': 1,
            'noticePending': true,
            'lastMigration': {
              'from': 3,
              'to': 4,
              'kind': 'registration',
              'backupKind': 'local-copy',
              'backupLocation': '/example/data/backups/before-data-v4-example',
              'backupAvailable': true,
            },
          },
        };
        var acknowledgements = 0;
        final l = Ledger(
          client: MockClient((r) async {
            if (r.url.path == '/api/data-format/acknowledge') {
              acknowledgements++;
              (snapshot['dataFormat'] as Map)['noticePending'] = false;
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
            child: MoneyTrackerApp(ledger: l),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Your data is ready: format v4'), findsOneWidget);
        expect(find.textContaining('v3 to v4'), findsOneWidget);
        expect(
          find.textContaining('some older releases lack version checks'),
          findsOneWidget,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('acknowledge-data-format')),
        );
        if (const bool.fromEnvironment('FORMAT_SCREENSHOTS')) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '/tmp/moneytracker-data-format-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.byKey(const ValueKey('acknowledge-data-format')));
        await tester.pumpAndSettle();
        expect(acknowledgements, 1);
        expect(find.text('Your data is ready: format v4'), findsNothing);
        final preferences = find.byTooltip('Preferences').evaluate().isNotEmpty
            ? find.byTooltip('Preferences')
            : find.text('Preferences').first;
        await tester.ensureVisible(preferences);
        await tester.tap(preferences);
        await tester.pumpAndSettle();
        final section = find.byKey(const ValueKey('preferences-section-7'));
        await tester.ensureVisible(section);
        await tester.tap(section);
        await tester.pumpAndSettle();
        expect(find.byType(DataFormatPanel).hitTestable(), findsOneWidget);
        expect(find.text('Data format and updates'), findsOneWidget);
        expect(find.textContaining('Your data: v4'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
