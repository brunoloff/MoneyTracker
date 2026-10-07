import 'dart:convert';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/setup_page.dart';

void main() {
  Future<void> scroll(
    WidgetTester tester,
    Finder finder,
    double delta, {
    Finder? scrollable,
  }) async {
    await tester.scrollUntilVisible(
      finder,
      delta,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  for (final width in [390.0, 1100.0]) {
    testWidgets('own-key setup validates and continues at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var saved = false, finished = false;
      final ledger = Ledger(
        client: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({'configured': false, 'hasData': false}),
              200,
            );
          }
          expect(request.url.path, '/api/setup/credentials');
          final body = jsonDecode(request.body);
          expect(body['appId'], 'own-app');
          expect(body['pem'], contains('PRIVATE KEY'));
          saved = true;
          return http.Response(
            jsonEncode({
              'configured': true,
              'message': 'Application and key verified.',
            }),
            200,
          );
        }),
      );
      addTearDown(ledger.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SetupPage(
            ledger: ledger,
            onFinished: () => finished = true,
            pickKey: () async => XFile.fromData(
              Uint8List.fromList(
                utf8.encode(
                  '-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----',
                ),
              ),
              name: 'own-app.pem',
              path: 'own-app.pem',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your accounts, your keys'), findsOneWidget);
      expect(find.text('Import existing MoneyTracker data'), findsOneWidget);
      await scroll(
        tester,
        find.text('Select private key PEM'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Select private key PEM'));
      await tester.pumpAndSettle();
      expect(find.text('own-app.pem'), findsOneWidget);
      await tester.ensureVisible(find.text('Verify and save keys'));
      await tester.tap(find.text('Verify and save keys'));
      await tester.pumpAndSettle();
      expect(saved, true);
      await scroll(
        tester,
        find.text('Connect a bank'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Connect a bank'), findsOneWidget);
      await tester.ensureVisible(find.text('Continue to MoneyTracker'));
      await tester.tap(find.text('Continue to MoneyTracker'));
      await tester.pumpAndSettle();
      expect(finished, true);
      expect(tester.takeException(), null);
    });
  }
  testWidgets('failed verification stays editable and keeps onboarding open', (
    tester,
  ) async {
    final ledger = Ledger(
      client: MockClient(
        (request) async => request.method == 'GET'
            ? http.Response('{"configured":false,"hasData":false}', 200)
            : http.Response('{"error":"Add the redirect URL first"}', 400),
      ),
    );
    addTearDown(ledger.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SetupPage(
          ledger: ledger,
          onFinished: () {},
          pickKey: () async => XFile.fromData(
            Uint8List.fromList(utf8.encode('PRIVATE KEY synthetic')),
            name: 'own-app.pem',
            path: 'own-app.pem',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await scroll(
      tester,
      find.text('Select private key PEM'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Select private key PEM'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Verify and save keys'));
    await tester.tap(find.text('Verify and save keys'));
    await tester.pumpAndSettle();
    await scroll(tester, find.text('Add the redirect URL first'), 200);
    expect(find.text('Add the redirect URL first'), findsOneWidget);
    expect(find.text('Connect a bank'), findsNothing);
    expect(find.text('own-app.pem'), findsOneWidget);
    expect(tester.takeException(), null);
  });
  testWidgets('old data import reports preserved payments and history', (
    tester,
  ) async {
    var imported = false;
    final ledger = Ledger(
      client: MockClient((request) async {
        if (request.url.path == '/api/setup/import') {
          expect(jsonDecode(request.body)['path'], '/synthetic/.private');
          imported = true;
          return http.Response(
            '{"transactions":12,"accounts":2,"undoSteps":8}',
            200,
          );
        }
        if (request.url.path == '/api/ledger') {
          return http.Response(
            '{"transactions":[],"accounts":[],"profiles":{"users":[]},"preferences":{}}',
            200,
          );
        }
        return http.Response(
          jsonEncode({'configured': imported, 'hasData': imported}),
          200,
        );
      }),
    );
    addTearDown(ledger.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SetupPage(
          ledger: ledger,
          onFinished: () {},
          pickDirectory: () async => '/synthetic/.private',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import existing MoneyTracker data'));
    await tester.pumpAndSettle();
    expect(imported, true);
    await scroll(tester, find.byKey(const ValueKey('setup-message')), 300);
    expect(
      find.textContaining('12 payments, 2 accounts and 8 undo steps copied'),
      findsOneWidget,
    );
    expect(find.text('Import existing MoneyTracker data'), findsNothing);
  });
}
