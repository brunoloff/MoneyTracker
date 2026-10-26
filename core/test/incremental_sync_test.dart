import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:money_tracker_core/money_tracker_core.dart';
import 'package:money_tracker_core/src/compat.dart';
import 'package:money_tracker_core/src/ledger_store.dart';
import 'package:money_tracker_core/src/paypal.dart';
import 'package:money_tracker_core/src/provider.dart';
import 'package:money_tracker_core/src/sync_start.dart';

const oldRates =
    '<Envelope><Cube><Cube time="2026-10-20"><Cube currency="USD" rate="1.1"/><Cube currency="GBP" rate="0.8"/></Cube><Cube time="2026-10-19"><Cube currency="USD" rate="1.05"/></Cube></Cube></Envelope>';
String deltaRates({String value = '1.2'}) =>
    '<GenericData><Series><SeriesKey><Value id="FREQ" value="D"/><Value id="CURRENCY" value="USD"/><Value id="CURRENCY_DENOM" value="EUR"/></SeriesKey><Obs><ObsDimension value="2026-10-20"/><ObsValue value="$value"/></Obs><Obs><ObsDimension value="2026-10-21"/><ObsValue value="1.3"/></Obs></Series></GenericData>';
Map<String, dynamic> account(String id) => {
  'uid': id,
  'identification_hash': id,
};
Map<String, dynamic> raw(
  String reference,
  String date, {
  String status = 'BOOK',
}) => {
  'entry_reference': reference,
  'transaction_date': date,
  'status': status,
  'credit_debit_indicator': 'DBIT',
  'transaction_amount': {'amount': '10.00', 'currency': 'EUR'},
  'remittance_information': ['PAYPAL Example'],
};
Map<String, dynamic> observation(String id, String aid, String date) => {
  'id': id,
  'accountId': aid,
  'date': date,
  'status': 'BOOK',
  'amount': -1000,
  'currency': 'EUR',
  'description': 'Example',
};
void main() {
  late Directory directory;
  late MoneyTrackerService service;
  void open({BankApi? api, http.Client? client}) {
    service = MoneyTrackerService(
      directory.path,
      encryptionKey: Uint8List.fromList(List.filled(32, 7)),
      bankApi:
          api ??
          (path, [body]) async =>
              throw StateError('Unexpected bank request: $path'),
      httpClient:
          client ??
          MockClient((_) async => throw StateError('Unexpected HTTP request')),
    );
  }

  setUp(() {
    directory = Directory.systemTemp.createTempSync('incremental-sync-');
  });
  tearDown(() async {
    await service.close();
    directory.deleteSync(recursive: true);
  });
  Future<void> banks(List<String> ids) =>
      service.store.write('bank-sessions.json', [
        {'accounts': ids.map(account).toList()},
      ]);
  Future<void> paypal(List<String> ids) => service.store.write(
    'session-paypal.json',
    {'accounts': ids.map(account).toList()},
  );

  test(
    'inclusive start is per-account, ignores future dates and revisits pending rows',
    () {
      open();
      final rows = [
        observation('a', 'one', '2026-10-20'),
        observation('b', 'two', '2026-10-24'),
        observation('future', 'one', '2026-12-01'),
      ];
      expect(
        incrementalStart(rows, 'one', now: DateTime(2026, 10, 26)),
        '2026-10-20',
      );
      rows.add({...observation('p', 'one', '2026-10-15'), 'status': 'PDNG'});
      expect(
        incrementalStart(rows, 'one', now: DateTime(2026, 10, 26)),
        '2026-10-15',
      );
      expect(
        incrementalStart(rows, 'two', now: DateTime(2026, 10, 26)),
        '2026-10-24',
      );
      expect(
        incrementalStart(rows, 'new', now: DateTime(2026, 10, 26)),
        '2026-07-28',
      );
    },
  );

  test(
    'bank accounts have independent inclusive windows and pagination preserves parameters',
    () async {
      final queries = <String, List<Map<String, String>>>{};
      open(
        api: (path, [body]) async {
          final uri = Uri.parse(path), uid = Uri.parse(path).pathSegments[1];
          if (path.endsWith('/balances')) return {'balances': []};
          queries.putIfAbsent(uid, () => []).add(uri.queryParameters);
          if (!uri.queryParameters.containsKey('continuation_key')) {
            return {'transactions': [], 'continuation_key': 'next'};
          }
          return {
            'transactions': [
              raw('new-$uid', uri.queryParameters['date_from']!),
            ],
          };
        },
      );
      await banks(['one', 'two']);
      final one = stableAccountId(account('one')),
          two = stableAccountId(account('two'));
      await service.store.write('ledger.json', {
        'accounts': [],
        'transactions': [
          observation('old-one', one, '2026-10-20')..['category'] = 'Food',
          observation('old-two', two, '2026-10-24')..['category'] = 'Food',
        ],
      });
      await service.request('POST', '/api/sync');
      await service.waitForSync();
      expect(service.state['syncError'], isNull);
      expect(queries['one']!.first, {'date_from': '2026-10-20'});
      expect(queries['two']!.first, {'date_from': '2026-10-24'});
      expect(queries['one']!.last, {
        'date_from': '2026-10-20',
        'continuation_key': 'next',
      });
      expect(service.store.read('ledger.json', {})['transactions'].length, 4);
      await service.request('POST', '/api/sync');
      await service.waitForSync();
      expect(service.store.read('ledger.json', {})['transactions'].length, 4);
      await service.request('POST', '/api/history', {'years': 2});
      await service.waitForSync();
      expect(queries['one']!.last['strategy'], 'longest');
      expect(queries['one']!.last['date_from'], day(historyStart(2)));
    },
  );

  test(
    'rates fetch history once then merge inclusive SDMX deltas without losing currencies',
    () async {
      final requests = <Uri>[];
      var invalid = false, empty = false;
      open(
        client: MockClient((r) async {
          requests.add(r.url);
          return http.Response(
            requests.length == 1
                ? oldRates
                : deltaRates(value: invalid ? '-1' : '1.2'),
            empty ? 204 : 200,
          );
        }),
      );
      Future<void> sync() async {
        await service.request('POST', '/api/sync', {'target': 'rates'});
        await service.waitForSync();
      }

      await sync();
      await sync();
      expect(service.state['syncError'], isNull);
      expect(requests.first.toString(), ecbUrl);
      expect(requests.last.host, 'data-api.ecb.europa.eu');
      expect(requests.last.queryParameters['startPeriod'], '2026-10-20');
      final rates = service.store.read('exchange-rates.json', {})['rates'];
      expect(rates['2026-10-19']['USD'], '1.05');
      expect(rates['2026-10-20'], {'EUR': '1', 'USD': '1.2', 'GBP': '0.8'});
      expect(rates['2026-10-21']['USD'], '1.3');
      invalid = true;
      await sync();
      expect(service.state['syncError'], contains('Invalid ECB rate'));
      expect(service.store.read('exchange-rates.json', {})['rates'], rates);
      expect(requests.last.queryParameters['startPeriod'], '2026-10-21');
      empty = true;
      await sync();
      expect(service.state['syncError'], isNull);
      expect(service.store.read('exchange-rates.json', {})['rates'], rates);
    },
  );

  test(
    'sync everything orders stages, commits results and groups Undo',
    () async {
      final calls = <String>[];
      open(
        client: MockClient((r) async {
          calls.add('rates');
          return http.Response(oldRates, 200);
        }),
        api: (path, [body]) async {
          if (path.endsWith('/balances')) {
            calls.add('balances');
            expect(
              service.store.read('exchange-rates.json', {})['rates'],
              isNotEmpty,
            );
            return {'balances': []};
          }
          if (path.contains('/p/')) {
            calls.add('paypal');
            expect(
              service.store.read('ledger.json', {})['transactions'],
              hasLength(1),
            );
          } else {
            calls.add('bank');
          }
          return {
            'transactions': [raw('new', '2026-10-25')],
          };
        },
      );
      await banks(['b']);
      await paypal(['p']);
      final before = service.journal.status()['count'] as int;
      await service.request('POST', '/api/sync', {'target': 'all'});
      await service.waitForSync();
      expect(service.state['syncError'], isNull);
      expect(calls, ['rates', 'balances', 'bank', 'paypal']);
      expect(service.state['syncResult'], contains('PayPal updated'));
      expect(service.journal.status()['count'], before + 1);
      await service.request('POST', '/api/undo');
      expect(service.store.read('ledger.json', {})['transactions'], isNull);
      expect(service.store.read('exchange-rates.json', {})['rates'], isNull);
      expect(service.store.read('paypal-observations.json', {}), isEmpty);
    },
  );

  test(
    'combined sync skips absent connections and stops after a failing stage',
    () async {
      var failBank = false, paypalCalled = false;
      open(
        client: MockClient((r) async => http.Response(oldRates, 200)),
        api: (path, [body]) async {
          if (path.contains('/p/')) paypalCalled = true;
          if (failBank) throw StateError('bank unavailable');
          return {'balances': [], 'transactions': []};
        },
      );
      await service.request('POST', '/api/sync', {'target': 'all'});
      await service.waitForSync();
      expect(service.state['syncError'], isNull);
      expect(service.state['syncResult'], contains('Banks skipped'));
      expect(service.state['syncResult'], contains('PayPal skipped'));
      await banks(['b']);
      await paypal(['p']);
      failBank = true;
      // Existing rates make this an incremental request; return valid SDMX.
      await service.store.write('exchange-rates.json', {});
      await service.request('POST', '/api/sync', {'target': 'all'});
      await service.waitForSync();
      expect(service.state['syncError'], contains('Bank statements failed'));
      expect(service.state['syncing'], false);
      expect(
        service.store.read('exchange-rates.json', {})['rates'],
        isNotEmpty,
      );
      expect(paypalCalled, false);
      expect(service.store.read('ledger.json', {}), isEmpty);
    },
  );

  test(
    'PayPal incremental start is per account; only explicit history uses longest',
    () async {
      final starts = <String, Map<String, String>>{};
      open(
        api: (path, [body]) async {
          final uri = Uri.parse(path);
          starts[uri.pathSegments[1]] = uri.queryParameters;
          return {
            'transactions': [
              raw('before', '2020-01-01'),
              raw('new', '2026-10-25'),
            ],
          };
        },
      );
      await paypal(['one', 'two']);
      await service.store.write('paypal-observations.json', {
        'a': observation('a', paypalAccountId(account('one')), '2026-10-20'),
        'b': observation('b', paypalAccountId(account('two')), '2026-10-23'),
      });
      await service.request('POST', '/api/paypal/sync');
      await service.waitForSync();
      expect(service.state['syncError'], isNull);
      expect(starts['one'], {'date_from': '2026-10-20'});
      expect(starts['two'], {'date_from': '2026-10-23'});
      expect(service.store.read('paypal-observations.json', {}).length, 4);
      await service.request('POST', '/api/paypal/sync', {
        'dateFrom': '2021-01-01',
      });
      await service.waitForSync();
      expect(starts['one'], {'date_from': '2021-01-01', 'strategy': 'longest'});
      expect(service.store.read('paypal-observations.json', {}).length, 4);
    },
  );

  test(
    'ignored PayPal persists across sync and restart, cannot match, and supports Undo and Restore',
    () async {
      Future<Map<String, dynamic>> api(
        String path, [
        Map<String, dynamic>? body,
      ]) async => {
        'transactions': [
          raw('ref', day(DateTime.now().subtract(const Duration(days: 1)))),
        ],
      };
      open(api: api);
      await paypal(['p']);
      await service.request('POST', '/api/paypal/sync');
      await service.waitForSync();
      final id = hashText('${paypalAccountId(account('p'))}ref', 32);
      expect(
        (await service.request('POST', '/api/paypal/ignore', {
          'observationId': id,
          'ignored': true,
        })).status,
        200,
      );
      expect(service.paypal.review()['rows'], isEmpty);
      expect(service.paypal.review()['ignored'].single['tags'], ['ignored']);
      expect(service.store.taxonomy()['tags'].single['id'], 'ignored');
      expect(
        (await service.request('POST', '/api/paypal/confirm', {
          'pairs': [
            {'observationId': id, 'bankId': 'missing'},
          ],
        })).status,
        400,
      );
      await service.request('POST', '/api/undo');
      expect(service.paypal.review()['rows'], hasLength(1));
      await service.request('POST', '/api/redo');
      await service.request('POST', '/api/paypal/sync');
      await service.waitForSync();
      expect(service.paypal.review()['rows'], isEmpty);
      await service.close();
      open(api: api);
      expect(service.paypal.review()['ignored'], hasLength(1));
      expect(
        (await service.request('POST', '/api/paypal/ignore', {
          'observationId': id,
          'ignored': false,
        })).status,
        200,
      );
      expect(service.paypal.review()['rows'], hasLength(1));
      expect(service.store.read('paypal-observations.json', {}), contains(id));
      final config = service.store.taxonomy();
      config['tags'] = [];
      expect(
        (await service.request('POST', '/api/taxonomy', config)).status,
        400,
      );
    },
  );
  test(
    'bulk ignore is atomic, refuses changed matches and has one Undo step',
    () async {
      open();
      await service.store.write('ledger.json', {
        'accounts': [
          {'id': 'bank', 'label': 'Bank'},
        ],
        'transactions': [
          {
            ...observation('bank-row', 'bank', '2026-10-20'),
            'description': 'PAYPAL',
            'category': 'Food',
            'amount': -100,
          },
        ],
      });
      await service.store.write('paypal-observations.json', {
        'exact': {
          ...observation('exact', 'paypal', '2026-10-20'),
          'amount': -100,
        },
        'one': {...observation('one', 'paypal', '2026-10-20'), 'amount': -200},
        'two': {...observation('two', 'paypal', '2026-10-20'), 'amount': -300},
      });
      expect(
        (await service.request('POST', '/api/paypal/ignore-unmatched', {
          'observationIds': ['one', 'exact'],
        })).status,
        400,
      );
      expect(service.store.read('tags.json', {}), isEmpty);
      final before = service.journal.status()['count'] as int;
      expect(
        (await service.request('POST', '/api/paypal/ignore-unmatched', {
          'observationIds': ['one', 'two'],
        })).status,
        200,
      );
      expect(
        service.paypal.review()['rows'].single['observation']['id'],
        'exact',
      );
      expect(service.paypal.review()['ignored'], hasLength(2));
      expect(service.journal.status()['count'], before + 1);
      await service.request('POST', '/api/undo');
      expect(service.paypal.review()['rows'], hasLength(3));
      expect(service.paypal.review()['ignored'], isEmpty);
    },
  );
}
