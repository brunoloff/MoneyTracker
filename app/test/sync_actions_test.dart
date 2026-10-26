import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_tracker/ledger.dart';
import 'package:money_tracker/sync_page.dart';
import 'widget_test.dart' show data, payment;

void main() {
  test(
    'ignored entries do not affect spending, income, salary dates or reference income',
    () {
      final l = Ledger(clock: () => DateTime(2026, 10, 26));
      addTearDown(l.dispose);
      l.ingest(
        data([
          {
            ...payment('ignored-spend', '2026-10-01', -99900, 'Food'),
            'tags': ['ignored'],
          },
          {
            ...payment('ignored-salary', '2026-10-01', 99900, 'Salary'),
            'tags': ['ignored'],
          },
          {
            ...payment('ignored-history', '2026-09-01', 99900, 'Other income'),
            'tags': ['ignored'],
          },
          payment('spend', '2026-10-01', -1000, 'Food'),
          payment('income', '2026-09-01', 6000, 'Other income'),
        ]),
      );
      expect(l.spent, 1000);
      expect(l.income, 0);
      expect(l.salaryDates, isEmpty);
      expect(l.totals, {'Food': 1000});
      l.incomeMode = 'last_month';
      expect(l.displayedIncome, 6000);
      l.incomeMode = 'average';
      expect(l.displayedIncome, 2000);
      expect(l.displayedNet, 1000);
    },
  );

  for (final width in [390.0, 1100.0]) {
    testWidgets('one sync action requests all sources at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? target;
      final l = Ledger(
        client: MockClient((r) async {
          if (r.url.path == '/api/sync') {
            target = jsonDecode(r.body)['target'];
            return http.Response('{}', 202);
          }
          if (r.method == 'GET') {
            return http.Response(jsonEncode(data([])), 200);
          }
          return http.Response('{"rows":[]}', 200);
        }),
      );
      l.ingest(data([]));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SyncPage(ledger: l)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sync-everything')));
      await tester.pumpAndSettle();
      expect(target, 'all');
      expect(find.text('Review PayPal associations'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      l.dispose();
    });

    testWidgets('ignore and restore preserve other review choices at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var ignored = false;
      final requests = <bool>[];
      final observation = {
        'id': 'gone',
        'description': 'Unmatched purchase',
        'date': '2026-10-01',
        'amount': -1000,
        'currency': 'EUR',
      };
      final l = Ledger(
        client: MockClient((r) async {
          if (r.url.path == '/api/paypal/ignore') {
            final body = jsonDecode(r.body);
            expect(body['observationId'], 'gone');
            ignored = body['ignored'];
            requests.add(ignored);
            return http.Response('{}', 200);
          }
          if (r.method == 'GET') {
            return http.Response(jsonEncode(data([])), 200);
          }
          return http.Response(
            jsonEncode({
              'rows': [
                {
                  'rule': 'exact',
                  'observation': {
                    ...observation,
                    'id': 'keep',
                    'description': 'Matched purchase',
                  },
                  'candidates': [
                    {
                      'id': 'bank',
                      'rule': 'exact',
                      'amount': -1000,
                      'currency': 'EUR',
                      'date': '2026-10-01',
                    },
                  ],
                },
                if (!ignored)
                  {
                    'rule': 'unmatched',
                    'observation': observation,
                    'candidates': [],
                  },
              ],
              'ignored': [
                if (ignored)
                  {
                    ...observation,
                    'tags': ['ignored'],
                  },
              ],
            }),
            200,
          );
        }),
      );
      l.ingest(data([]));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SyncPage(ledger: l)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review pending (2)'));
      await tester.tap(find.text('Review pending (2)'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(Checkbox).first);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('Confirm 0 selected'), findsOneWidget);
      final ignore = find.byKey(const ValueKey('ignore-paypal-gone'));
      await tester.ensureVisible(ignore);
      await tester.tap(ignore);
      await tester.pumpAndSettle();
      expect(ignored, true);
      expect(find.byKey(const ValueKey('ignore-paypal-gone')), findsNothing);
      expect(find.text('Confirm 0 selected'), findsOneWidget);
      await tester.ensureVisible(find.text('Ignored (1)'));
      await tester.tap(find.text('Ignored (1)'));
      await tester.pumpAndSettle();
      final restore = find.byKey(const ValueKey('restore-paypal-gone'));
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(requests, [true, false]);
      expect(find.byKey(const ValueKey('ignore-paypal-gone')), findsOneWidget);
      expect(find.text('Confirm 0 selected'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      l.dispose();
    });
  }
  for (final width in [390.0, 1100.0]) {
    testWidgets('bulk ignore preserves chosen pairs at $width', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ignored = <String>{};
      List<dynamic>? sent;
      final l = Ledger(
        client: MockClient((r) async {
          if (r.url.path == '/api/paypal/ignore-unmatched') {
            sent = jsonDecode(r.body)['observationIds'];
            ignored.addAll(sent!.cast<String>());
            return http.Response('{}', 200);
          }
          if (r.method == 'GET') {
            return http.Response(jsonEncode(data([])), 200);
          }
          Map<String, dynamic> observation(String id) => {
            'id': id,
            'description': id,
            'date': '2026-10-20',
            'amount': -100,
            'currency': 'EUR',
          };
          return http.Response(
            jsonEncode({
              'rows': [
                for (final id in ['exact', 'fx', 'manual', 'one', 'two'])
                  if (!ignored.contains(id))
                    {
                      'rule': ['exact', 'fx'].contains(id) ? id : 'unmatched',
                      'observation': observation(id),
                      'candidates': [
                        if (['exact', 'fx', 'manual'].contains(id))
                          {
                            ...observation('bank-$id'),
                            'rule': id == 'manual' ? 'nearby' : id,
                          },
                      ],
                    },
              ],
              'ignored': [for (final id in ignored) observation(id)],
            }),
            200,
          );
        }),
      );
      l.ingest(data([]));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: SyncPage(ledger: l)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review pending (5)'));
      await tester.tap(find.text('Review pending (5)'));
      await tester.pumpAndSettle();
      final manual = find.byKey(const ValueKey('paypal-choice-manual'));
      await tester.ensureVisible(manual);
      await tester.tap(manual);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('bank-manual'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm 3 selected'), findsOneWidget);
      final bulk = find.byKey(const ValueKey('ignore-all-unmatched'));
      await tester.ensureVisible(bulk);
      await tester.tap(bulk);
      await tester.pumpAndSettle();
      expect(sent, ['one', 'two']);
      expect(find.text('Confirm 3 selected'), findsOneWidget);
      expect(find.text('Ignored (2)'), findsOneWidget);
      expect(find.byKey(const ValueKey('ignore-all-unmatched')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      l.dispose();
    });
  }
}
