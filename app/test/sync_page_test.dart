import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/sync_page.dart';
import 'widget_test.dart' show data;
import 'golden_checks.dart';

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
    'PayPal history uses the dedicated endpoint and forwards start date',
    () async {
      final requests = <http.Request>[];
      final l = Ledger(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode(request.method == 'GET' ? data([]) : {}),
            200,
          );
        }),
      );
      await l.sync(target: 'paypal', dateFrom: '2020-01-01');
      final post = requests.firstWhere((r) => r.method == 'POST');
      expect(post.url.path, '/api/paypal/sync');
      expect(jsonDecode(post.body)['dateFrom'], '2020-01-01');
      l.dispose();
    },
  );

  for (final failSecond in [false, true]) {
    testWidgets('Large confirmations batch safely; failure=$failSecond', (
      tester,
    ) async {
      final confirmed = <String>{};
      final sizes = <int>[];
      String id(int i) => i.toString().padLeft(32, '0');
      final l = Ledger(
        client: MockClient((request) async {
          if (request.url.path == '/api/paypal/confirm') {
            expect(request.bodyBytes.length, lessThan(8192));
            final pairs = jsonDecode(request.body)['pairs'] as List;
            sizes.add(pairs.length);
            if (failSecond && sizes.length == 2) {
              return http.Response('{"error":"Temporary failure"}', 503);
            }
            confirmed.addAll(pairs.map((p) => p['observationId'] as String));
            return http.Response('{}', 200);
          }
          if (request.url.path == '/api/ledger') {
            return http.Response(jsonEncode(data([])), 200);
          }
          return http.Response(
            jsonEncode({
              'rows': [
                for (var i = 0; i < 85; i++)
                  if (!confirmed.contains(id(i)))
                    {
                      'rule': 'exact',
                      'observation': {
                        'id': id(i),
                        'description': 'Payment $i',
                        'date': '2026-09-08',
                        'amount': -899,
                        'currency': 'EUR',
                      },
                      'candidates': [
                        {
                          'id': id(i + 1000),
                          'description': 'PayPal',
                          'date': '2026-09-10',
                          'amount': -899,
                          'currency': 'EUR',
                          'rule': 'exact',
                        },
                      ],
                    },
              ],
            }),
            200,
          );
        }),
      );
      l.ingest(data([]));
      l.loading = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SyncPage(ledger: l)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review pending (85)'));
      await tester.tap(find.text('Review pending (85)'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Confirm 85 selected'));
      await tester.tap(find.text('Confirm 85 selected'));
      await tester.pumpAndSettle();
      expect(sizes, failSecond ? [40, 40] : [40, 40, 5]);
      expect(confirmed.length, failSecond ? 40 : 85);
      if (failSecond) {
        expect(
          find.textContaining('40 associations confirmed before the error'),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      l.dispose();
    });
  }

  for (final width in [390.0, 1100.0]) {
    testWidgets('Review and explicitly confirm PayPal at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var confirmed = false;
      final l = Ledger(
        client: MockClient((request) async {
          if (request.url.path == '/api/paypal/confirm') {
            final body = jsonDecode(request.body);
            expect(body['pairs'], [
              {'observationId': 'fx', 'bankId': 'fx-bank'},
              {'observationId': 'p', 'bankId': 'b'},
            ]);
            confirmed = true;
            return http.Response('{}', 200);
          }
          if (request.url.path == '/api/ledger') {
            return http.Response(jsonEncode(data([])), 200);
          }
          return http.Response(
            jsonEncode({
              'rows': confirmed
                  ? []
                  : [
                      {
                        'rule': 'exact',
                        'observation': {
                          'id': 'p',
                          'description': 'Spotify',
                          'date': '2026-09-08',
                          'amount': -899,
                          'currency': 'EUR',
                        },
                        'candidates': [
                          {
                            'id': 'b',
                            'description': 'PayPal Europe',
                            'date': '2026-09-10',
                            'amount': -899,
                            'currency': 'EUR',
                            'delay': 2,
                            'rule': 'exact',
                          },
                        ],
                      },
                      {
                        'rule': 'fx',
                        'observation': {
                          'id': 'fx',
                          'description': 'Donation',
                          'date': '2026-09-08',
                          'amount': -2500,
                          'currency': 'USD',
                        },
                        'candidates': [
                          {
                            'id': 'b',
                            'description': 'PayPal Europe',
                            'date': '2026-09-10',
                            'amount': -899,
                            'currency': 'EUR',
                            'delay': 2,
                            'rule': 'fx',
                          },
                          {
                            'id': 'fx-bank',
                            'description': 'PayPal Europe',
                            'date': '2026-09-10',
                            'amount': -2245,
                            'currency': 'EUR',
                            'delay': 2,
                            'rule': 'fx',
                            'expectedAmount': -2153.0,
                            'differencePercent': 4.27,
                            'rateDate': '2026-09-08',
                          },
                        ],
                      },
                    ],
            }),
            200,
          );
        }),
      );
      l.ingest(data([]));
      l.loading = false;
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'MoneySans'),
          home: Scaffold(
            body: SingleChildScrollView(child: SyncPage(ledger: l)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('paypal-history-start')));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review pending (2)'));
      await tester.pumpAndSettle();
      expect(confirmed, false);
      await expectLinuxGolden(
        find.byType(MaterialApp),
        'goldens/paypal-review-${width.toInt()}.png',
      );
      expect(tester.widget<Checkbox>(find.byType(Checkbox).first).value, true);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('Confirm 1 selected'), findsOneWidget);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exact amount and currency (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Spotify'), findsNothing);
      expect(find.text('Confirm 2 selected'), findsOneWidget);
      await tester.tap(find.text('Confirm 2 selected'));
      await tester.pumpAndSettle();
      expect(confirmed, true);
      expect(find.textContaining('No pending PayPal'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      l.dispose();
    });
  }
}
