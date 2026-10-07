import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:test/test.dart';
import 'package:money_tracker_core/money_tracker_core.dart';
import 'package:money_tracker_core/src/classification.dart';
import 'package:money_tracker_core/src/compat.dart';
import 'package:money_tracker_core/src/journal.dart';
import 'package:money_tracker_core/src/ledger_store.dart';
import 'package:money_tracker_core/src/paypal.dart';
import 'package:money_tracker_core/src/provider.dart';
import 'package:money_tracker_core/src/reconciliation.dart';
import 'package:money_tracker_core/src/xlsx_import.dart';

final golden =
    jsonDecode(File('test/fixtures/python_golden.json').readAsStringSync())
        as Map;
Map<String, dynamic> raw({
  String? reference = 'ref',
  String amount = '12.34',
  String description = 'PINGO DOCE',
  String status = 'BOOK',
  String date = '2026-09-25',
}) => {
  'if': null,
  'entry_reference': ?reference,
  'transaction_amount': {'amount': amount, 'currency': 'EUR'},
  'credit_debit_indicator': 'DBIT',
  'transaction_date': date,
  'remittance_information': [description],
  'status': status,
};
Map<String, dynamic> payment(
  String id, {
  String account = 'a',
  int amount = -100,
  String description = 'PAYPAL merchant',
  String currency = 'EUR',
  String date = '2026-09-25',
}) => {
  'id': id,
  'accountId': account,
  'date': date,
  'amount': amount,
  'currency': currency,
  'description': description,
  'category': 'Other',
  'source': 'CGD',
  'status': 'BOOK',
  'reviewed': false,
  'purchaseDetails': [],
};
void installLegacy(Journal j) {
  final f = golden['journal'];
  for (final e in (f['files'] as Map).entries) {
    j.atomic(e.key, base64Decode(e.value));
  }
  for (final b in f['blobs']) {
    j.db.execute('INSERT INTO blobs VALUES(?,?)', [
      b['id'],
      base64Decode(b['data']),
    ]);
  }
  for (final a in f['actions']) {
    j.db.execute('INSERT INTO actions VALUES(?,?,?,?,?,?)', [
      a['id'],
      a['label'],
      a['group'],
      a['created'],
      a['before'],
      a['after'],
    ]);
  }
  j.db.execute('UPDATE state SET cursor=?', [f['cursor']]);
}

void main() {
  late Directory temp;
  late MoneyTrackerService service;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('moneytracker-test-');
    service = MoneyTrackerService(
      temp.path,
      encryptionKey: Uint8List.fromList(List.filled(32, 7)),
      bankApi: (path, [body]) async =>
          throw StateError('Unexpected network request: $path'),
    );
  });
  tearDown(() async {
    await service.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });
  group('Python compatibility fixtures', () {
    var i = 0;
    for (final f in golden['normalization']) {
      test('transaction ${i++} preserves exact cents and legacy ID', () {
        expect(
          normalize(
            f['raw'],
            f['account'],
            categoryColors.keys.toSet(),
            f['source'],
          ),
          f['expected'],
        );
      });
    }
    i = 0;
    for (final f in golden['accounts']) {
      test('stable account ${i++}', () {
        expect(stableAccountId(f['account'], f['source']), f['expected']);
      });
    }
    i = 0;
    for (final f in golden['matching']) {
      test('Unicode rule ${i++}', () {
        expect(ruleMatches(f['rule'], f['payment']), f['expected']);
      });
    }
    test('merged PayPal projection and manual edits unchanged', () async {
      final fixture = golden['snapshot'];
      await service.journal.action('Fixture', () async {
        for (final e in (fixture['files'] as Map).entries) {
          await service.store.write(e.key, e.value);
        }
      });
      expect(service.store.snapshot(), fixture['expected']);
      expect(service.store.snapshot(client: true), fixture['client']);
      expect(
        service.store.read('ledger.json', {}),
        fixture['files']['ledger.json'],
      );
    });
    test('category draft, UUID5, paused rules and transfer priority', () {
      final f = golden['rules'], ordered = maps(f['ordered']);
      expect(categoryDraft('Food', 'Food', ordered), f['draft']);
      expect(categoryDraft('Travel', 'Travel', []), f['emptyDraft']);
      expect(
        transferCategories(
          ordered,
          {'Food': 'Shopping'},
          {'Shopping': 'Shopping'},
        ),
        f['transfer'],
      );
    });
    test('spreadsheet amounts IDs overlaps and duplicate purchases', () {
      final f = golden['spreadsheet'],
          records = parseSpreadsheetRows(
            (f['rows'] as List)
                .map((r) => (r as List).cast<dynamic>())
                .toList(),
          );
      expect(records, f['records']);
      final plan = planSpreadsheet(f['ledger'], records, 'a', {
        'sourceFile': 'test.xlsx',
      }, categoryColors.keys.toSet());
      expect(plan.$1, f['result']);
      expect(plan.$2, f['report']);
      expect(
        planSpreadsheet(plan.$1, records, 'a', {
          'sourceFile': 'renamed.xlsx',
        }, categoryColors.keys.toSet()).$1,
        plan.$1,
      );
    });
    test('real OOXML dates and styles parse identically', () {
      expect(
        parseSpreadsheetRows(
          readWorkbook(
            File('test/fixtures/cgd_synthetic.xlsx').readAsBytesSync(),
          ),
        ),
        golden['spreadsheet']['records'],
      );
    });
  });
  test(
    'history dates preserve leap days when the target year supports them',
    () {
      expect(day(historyStart(4, DateTime.utc(2024, 2, 29))), '2020-02-29');
      expect(day(historyStart(1, DateTime.utc(2024, 2, 29))), '2023-02-28');
      expect(() => cents('1000000000000000000000'), throwsFormatException);
    },
  );
  test('legacy SQLite/gzip undo and redo retains original byte hashes', () {
    installLegacy(service.journal);
    expect(service.journal.status()['undo'], 'Second action');
    service.journal.restore();
    expect(service.store.read('categories.json', {}), {'é😀': 'Food'});
    service.journal.restore();
    expect(service.journal.file('categories.json').existsSync(), false);
    service.journal.restore(redo: true);
    service.journal.restore(redo: true);
    expect(service.store.read('categories.json', {}), {'é😀': 'Rent'});
  });
  test('pending manifest recovers old journal and checks blob hashes', () {
    installLegacy(service.journal);
    final target = golden['journal']['actions'][0]['after'];
    service.journal.db.execute('UPDATE state SET cursor=1,pending=?', [target]);
    service.journal.recover();
    expect(service.store.read('categories.json', {}), {'é😀': 'Food'});
  });
  test(
    'failed action leaves all tracked files and history unchanged',
    () async {
      await service.store.write('categories.json', {'a': 'Food'});
      final before = service.journal.file('categories.json').readAsBytesSync(),
          status = service.journal.status();
      await expectLater(
        service.journal.action('Failed', () async {
          await service.store.write('categories.json', {'a': 'Rent'});
          await service.store.write('tags.json', {
            'a': ['x'],
          });
          throw StateError('Fail');
        }),
        throwsStateError,
      );
      expect(service.journal.file('categories.json').readAsBytesSync(), before);
      expect(service.journal.file('tags.json').existsSync(), false);
      expect(service.journal.status(), status);
    },
  );
  test('readers see committed files during background staging', () async {
    await service.store.write('categories.json', {'a': 'Food'});
    final staged = Completer<void>(), release = Completer<void>();
    final work = service.journal.action('Staged', () async {
      await service.store.write('categories.json', {'a': 'Rent'});
      expect(service.store.read('categories.json', {}), {'a': 'Rent'});
      staged.complete();
      await release.future;
    });
    await staged.future;
    expect(service.store.read('categories.json', {}), {'a': 'Food'});
    release.complete();
    await work;
    expect(service.store.read('categories.json', {}), {'a': 'Rent'});
  });
  test(
    'grouped confirmations, new branch, retention and external-edit refusal',
    () async {
      await service.journal.action(
        'Group',
        () => service.store.write('categories.json', {'a': 'Food'}),
        group: 'g',
      );
      await service.journal.action(
        'Group',
        () => service.store.write('categories.json', {'a': 'Rent'}),
        group: 'g',
      );
      expect(service.journal.status()['count'], 1);
      service.journal.restore();
      expect(service.journal.file('categories.json').existsSync(), false);
      await service.store.write('categories.json', {'a': 'Other'});
      expect(service.journal.status()['redo'], null);
      service.journal.atomic('categories.json', utf8.encode('{}'));
      expect(() => service.journal.restore(), throwsFormatException);
    },
  );
  test('undo limit prunes references and zero means unlimited', () async {
    await service.store.write('preferences.json', {'undoLimit': 2});
    for (var i = 0; i < 5; i++) {
      await service.store.write('categories.json', {'a': '$i'});
    }
    expect(service.journal.status()['count'], 2);
    await service.store.write('preferences.json', {'undoLimit': 0});
    for (var i = 0; i < 5; i++) {
      await service.store.write('categories.json', {'a': 'unlimited$i'});
    }
    expect(service.journal.status()['count'], 8);
  });
  test(
    'credentials and sessions encrypted, tampering fails, excluded from history',
    () async {
      await service.store.write('session.json', {'secret': 'not plain text'});
      expect(service.journal.status()['count'], 0);
      expect(service.store.read('session.json', {}), {
        'secret': 'not plain text',
      });
      final file = service.journal.file('session.json'),
          bytes = file.readAsBytesSync();
      expect(
        utf8.decode(bytes, allowMalformed: true),
        isNot(contains('not plain text')),
      );
      bytes[bytes.length - 1] ^= 1;
      file.writeAsBytesSync(bytes);
      expect(() => service.store.read('session.json', {}), throwsA(anything));
    },
  );
  test('invalid filenames cannot escape the data directory', () {
    for (final name in ['../ledger.json', '..\\ledger.json', '/etc/passwd']) {
      expect(() => service.journal.file(name), throwsFormatException);
    }
  });
  test('merge undo manual category and income guard', () async {
    await service.store.write('ledger.json', {
      'accounts': [],
      'transactions': [payment('a'), payment('b', account: 'b')],
    });
    expect(
      (await service.request('POST', '/api/merge', {
        'primaryId': 'a',
        'secondaryId': 'b',
      })).status,
      200,
    );
    expect(service.store.snapshot()['transactions'].length, 1);
    expect(
      (await service.request('POST', '/api/category', {
        'id': 'a',
        'category': 'Salary',
      })).status,
      400,
    );
    await service.request('POST', '/api/category', {
      'id': 'a',
      'category': 'Rent',
    });
    expect(service.store.snapshot()['transactions'].first['reviewed'], true);
    await service.request('POST', '/api/undo');
    await service.request('POST', '/api/undo');
    expect(service.store.snapshot()['transactions'].length, 2);
  });
  test('AND conditions cannot mix different provenance records', () {
    final p = payment('p')
      ..['sourceRecords'] = [
        {'institution': 'CGD', 'description': 'Bank'},
        {'institution': 'PayPal', 'description': 'Shop'},
      ];
    final r = {
      'category': 'Food',
      'groups': [
        [
          {'field': 'source', 'operator': 'equals', 'value': 'CGD'},
          {'field': 'description', 'operator': 'contains', 'value': 'Shop'},
        ],
      ],
    };
    expect(ruleMatches(r, p), false);
  });
  test(
    'taxonomy transfer pins visible assignments and undo restores everything',
    () async {
      await service.store.write('ledger.json', {
        'accounts': [],
        'transactions': [payment('p')..['category'] = 'Food'],
      });
      final config = defaultTaxonomy();
      (config['categories'] as List).removeWhere((c) => c['id'] == 'Food');
      config['categoryTransfers'] = {'Food': 'Shopping'};
      expect(
        (await service.request('POST', '/api/taxonomy', config)).status,
        200,
      );
      expect(
        service.store.snapshot()['transactions'].first['category'],
        'Shopping',
      );
      expect(service.store.snapshot()['transactions'].first['reviewed'], true);
      service.journal.restore();
      expect(
        service.store.snapshot()['transactions'].first['category'],
        'Food',
      );
      expect(service.store.categoryIds, contains('Food'));
    },
  );
  test(
    'taxonomy and profiles reject casefold duplicate names and nested parents',
    () {
      final config = defaultTaxonomy();
      config['tags'] = [
        {'id': 'a', 'name': 'Straße'},
        {'id': 'b', 'name': 'STRASSE'},
      ];
      expect(() => validateTaxonomy(config, {}, {}), throwsFormatException);
      expect(
        () => validateProfiles({
          'users': [
            {'id': 'a', 'name': 'Straße'},
            {'id': 'b', 'name': 'STRASSE'},
          ],
          'accountUsers': {},
        }, {}),
        throwsFormatException,
      );
      expect(
        () => validateProfiles(
          {
            'users': [],
            'accountUsers': {'a': 'unknown'},
          },
          {'a'},
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'bank sync preserves BOOK history, repeat no-ID purchases and manual edits',
    () async {
      await service.close();
      service = MoneyTrackerService(
        temp.path,
        encryptionKey: Uint8List.fromList(List.filled(32, 7)),
        bankApi: (path, [body]) async {
          if (path.endsWith('/balances')) {
            return {
              'balances': [
                {
                  'balance_type': 'ITAV',
                  'balance_amount': {'currency': 'EUR', 'amount': '99.99'},
                },
              ],
            };
          }
          return {
            'transactions': [
              raw(reference: null),
              raw(reference: null),
              raw(reference: 'new', status: 'PDNG'),
            ],
          };
        },
      );
      final id = stableAccountId({'uid': 'u', 'identification_hash': 'same'});
      await service.store.write('bank-sessions.json', [
        {
          'accounts': [
            {'uid': 'u', 'identification_hash': 'same'},
          ],
        },
      ]);
      await service.store.write('ledger.json', {
        'accounts': [],
        'transactions': [
          payment('book', account: id),
          payment('old-pending', account: id)..['status'] = 'PDNG',
        ],
      });
      await service.store.write('categories.json', {'book': 'Rent'});
      await service.request('POST', '/api/sync');
      await service.waitForSync();
      expect(service.state['syncError'], null);
      final snapshot = service.store.snapshot(),
          rows = snapshot['transactions'] as List;
      expect(
        rows
            .where(
              (r) =>
                  r['id'].toString().endsWith('-0') ||
                  r['id'].toString().endsWith('-1'),
            )
            .length,
        2,
      );
      expect(
        rows.any((r) => r['id'] == 'book' && r['category'] == 'Rent'),
        true,
      );
      // Use the ordinary sync's actual recent window, rather than a fixed date.
      expect(
        rows.any((r) => r['id'] == 'old-pending'),
        DateTime.now().difference(DateTime(2026, 9, 25)).inDays > 90,
      );
      await service.request('POST', '/api/sync');
      await service.waitForSync();
      expect(service.store.snapshot()['transactions'].length, rows.length);
    },
  );
  test(
    'pagination failure rolls back raw files and ledger; mutations blocked while sync',
    () async {
      await service.close();
      final release = Completer<void>();
      service = MoneyTrackerService(
        temp.path,
        bankApi: (path, [body]) async {
          if (path.endsWith('/balances')) return {'balances': []};
          await release.future;
          return {
            'transactions': [raw()],
            'continuation_key': 'repeat',
          };
        },
      );
      await service.store.write('bank-sessions.json', [
        {
          'accounts': [
            {'uid': 'u', 'identification_hash': 'same'},
          ],
        },
      ]);
      await service.store.write('ledger.json', {
        'accounts': [],
        'transactions': [payment('original')],
      });
      final before = service.journal.file('ledger.json').readAsBytesSync();
      await service.request('POST', '/api/sync');
      expect((await service.request('POST', '/api/undo')).status, 409);
      expect(
        (await service.request(
          'GET',
          '/api/ledger',
        )).data['transactions'].first['id'],
        'original',
      );
      release.complete();
      await service.waitForSync();
      expect(service.state['syncError'], contains('Repeated bank'));
      expect(service.journal.file('ledger.json').readAsBytesSync(), before);
      expect(service.journal.file('raw-1.json').existsSync(), false);
    },
  );
  test('FX is exact at tolerance boundary and excludes stale/future rates', () {
    final table = RateTable({
      'rates': {
        '2026-09-24': {'EUR': '1', 'USD': '1.25'},
      },
    });
    expect(
      table.convert(-1250, 'USD', 'EUR', '2026-09-25')!.$1.truncate(),
      -1000,
    );
    expect(table.convert(-1250, 'USD', 'EUR', '2026-09-23'), null);
    expect(table.convert(-1250, 'USD', 'EUR', '2026-10-02'), null);
    expect(
      parseRates(
        '<Root><Cube time="2026-09-24"><Cube currency="USD" rate="1.25"/></Cube></Root>',
      )['2026-09-24']['USD'],
      '1.25',
    );
    expect(
      () => parseRates(
        '<Root><Cube time="2026-09-24"><Cube currency="USD" rate="NaN"/></Cube></Root>',
      ),
      throwsFormatException,
    );
  });
  test('PayPal ambiguity owners and one-to-one confirmation', () async {
    await service.store.write('ledger.json', {
      'accounts': [],
      'transactions': [payment('b')],
    });
    final obs = {
      'p': {
        ...payment('p', account: 'pp'),
        'institution': 'PayPal',
        'kind': 'purchase',
      },
      'q': {
        ...payment('q', account: 'pp'),
        'institution': 'PayPal',
        'kind': 'purchase',
      },
    };
    await service.store.write('paypal-observations.json', obs);
    expect(
      service.paypal.review()['rows'].every((r) => r['rule'] == 'unmatched'),
      true,
    );
    final response = await service.request('POST', '/api/paypal/confirm', {
      'pairs': [
        {'observationId': 'p', 'bankId': 'b'},
        {'observationId': 'q', 'bankId': 'b'},
      ],
    });
    expect(response.status, 400);
    expect(service.store.read('paypal-associations.json', {}), isEmpty);
    await service.store.write('profiles.json', {
      'users': [
        {'id': 'u', 'name': 'One'},
      ],
      'accountUsers': {'a': 'u'},
    });
    expect(service.paypal.review()['rows'].first['candidates'], isEmpty);
  });
  test('PayPal FX boundary is inclusive and next cent rejected', () async {
    await service.store.write('exchange-rates.json', {
      'rates': {
        '2026-09-24': {'EUR': '1', 'USD': '1.25'},
      },
    });
    await service.store.write('paypal-observations.json', {
      'p': {
        ...payment(
          'p',
          account: 'pp',
          amount: -1250,
          currency: 'USD',
          date: '2026-09-24',
        ),
        'institution': 'PayPal',
        'kind': 'purchase',
      },
    });
    await service.store.write('ledger.json', {
      'accounts': [],
      'transactions': [
        payment('b', amount: -1100),
        payment('outside', amount: -1101),
      ],
    });
    expect(
      service.paypal
          .review()['rows']
          .first['candidates']
          .map((c) => c['id'])
          .toList(),
      ['b'],
    );
  });
  test('reconciliation marks contested suggestions requiring review', () {
    final observations = [
      {...payment('p'), 'kind': 'purchase'},
      {...payment('q'), 'kind': 'purchase'},
    ];
    final rows = suggestMatches(observations, [payment('b')], {'a'});
    expect(
      rows.every((r) => r['ambiguous'] == true && r['requiresReview'] == true),
      true,
    );
  });
  test(
    'XLSX preview rechecks ledger on apply and journals valid imports',
    () async {
      await service.store.write('ledger.json', golden['spreadsheet']['ledger']);
      final preview = service.spreadsheet.preview(
        File('test/fixtures/cgd_synthetic.xlsx').absolute.path,
        'a',
      );
      expect(preview['added'], 2);
      final result = await service.spreadsheet.apply(preview['ticket']);
      expect(result['added'], 2);
      expect(service.store.read('ledger.json', {})['transactions'].length, 3);
      expect(Directory('${temp.path}/imports').existsSync(), true);
      service.journal.restore();
      expect(
        service.store.read('ledger.json', {}),
        golden['spreadsheet']['ledger'],
      );
      final next = service.spreadsheet.preview(
        File('test/fixtures/cgd_synthetic.xlsx').absolute.path,
        'a',
      );
      await service.store.write('ledger.json', {
        'accounts': [],
        'transactions': [],
      });
      await expectLater(
        service.spreadsheet.apply(next['ticket']),
        throwsFormatException,
      );
    },
  );
  test(
    'legacy migration copies original bytes/history and encrypts sessions',
    () async {
      final legacy = Directory.systemTemp.createTempSync(
        'moneytracker-legacy-',
      );
      try {
        final j = Journal(legacy.path);
        installLegacy(j);
        await j.write('ledger.json', {
          'accounts': [],
          'transactions': [payment('p')],
        });
        await j.write('session.json', {'private': 'session'});
        j.close();
        final before = File('${legacy.path}/categories.json').readAsBytesSync();
        final result = await service.request('POST', '/api/setup/import', {
          'path': legacy.path,
        });
        // A running legacy server can legitimately prevent import on a developer machine.
        if (result.status != 200 &&
            result.data['error'].toString().contains('old browser-based')) {
          markTestSkipped('Close legacy port 8765 before the migration test');
          return;
        }
        expect(result.status, 200, reason: result.data.toString());
        expect(result.data['transactions'], 1);
        expect(service.journal.status()['count'], 3);
        expect(
          File('${legacy.path}/categories.json').readAsBytesSync(),
          before,
        );
        expect(service.store.read('session.json', {}), {'private': 'session'});
        expect(
          utf8.decode(
            service.journal.file('session.json').readAsBytesSync(),
            allowMalformed: true,
          ),
          isNot(contains('session')),
        );
        expect(
          (await service.request('POST', '/api/setup/import', {
            'path': legacy.path,
          })).status,
          400,
        );
      } finally {
        legacy.deleteSync(recursive: true);
      }
    },
  );
  test(
    'generated HTTPS callback validates host/state and rejects replay',
    () async {
      await service.connections.startCallback(port: 0);
      expect(service.connections.callbackError, null);
      final port = service.connections.callbackServer!.port;
      final trust = SecurityContext(
        withTrustedRoots: false,
      )..setTrustedCertificates(service.journal.file('callback-cert.pem').path);
      final client = HttpClient(context: trust);
      try {
        final response = await (await client.getUrl(
          Uri.parse('https://localhost:$port/callback?state=wrong'),
        )).close();
        expect(response.statusCode, 400);
        expect(
          await utf8.decoder.bind(response).join(),
          contains('already completed'),
        );
      } finally {
        client.close(force: true);
      }
    },
  );
  test(
    'own bank authorization validates redirect, state, institution and replay',
    () async {
      await service.close();
      var exchanges = 0;
      service = MoneyTrackerService(
        temp.path,
        encryptionKey: Uint8List.fromList(List.filled(32, 7)),
        bankApi: (path, [body]) async {
          if (path.startsWith('/aspsps')) {
            return {
              'aspsps': [
                {
                  'name': 'Test Bank',
                  'country': 'PT',
                  'psu_types': ['personal'],
                  'maximum_consent_validity': 900,
                },
              ],
            };
          }
          if (path == '/application') {
            return {
              'redirect_urls': [callbackUrl],
            };
          }
          if (path == '/auth') {
            expect(body!['redirect_url'], callbackUrl);
            expect(body['state'], isNotEmpty);
            return {'url': 'https://example.test/authorize'};
          }
          if (path == '/sessions') {
            exchanges++;
            return {
              'aspsp': {'name': 'Test Bank', 'country': 'PT'},
              'accounts': [
                {
                  'uid': 'u',
                  'identification_hash': 'same',
                  'cash_account_type': 'CACC',
                },
              ],
            };
          }
          throw StateError(path);
        },
      );
      final started = await service.request('POST', '/api/connections/start', {
        'country': 'PT',
        'name': 'Test Bank',
      });
      expect(started.status, 200);
      final pending = service.store.read('connection-pending.json', {});
      expect(
        (await service.request('POST', '/api/connections/finish', {
          'callback': '$callbackUrl?state=wrong&code=c',
        })).status,
        400,
      );
      expect(exchanges, 0);
      final callback = '$callbackUrl?state=${pending['state']}&code=c';
      final result = await service.connections.completeCallback(callback);
      expect(result['added'], 1);
      expect(exchanges, 1);
      expect(
        service.connections.status(started.data['attempt'])['status'],
        'complete',
      );
      await expectLater(
        service.connections.completeCallback(callback),
        throwsFormatException,
      );
      expect(exchanges, 1);
      service.journal.restore();
      expect(service.store.snapshot()['accounts'], isEmpty);
      expect(service.store.bankSessions().length, 1);
    },
  );
  test(
    'unexpected authorization institution cannot persist a session',
    () async {
      await service.close();
      service = MoneyTrackerService(
        temp.path,
        bankApi: (path, [body]) async => {
          'aspsp': {'name': 'Wrong', 'country': 'PT'},
          'accounts': [
            {'uid': 'u', 'identification_hash': 'same'},
          ],
        },
      );
      await service.store.write('connection-pending.json', {
        'state': 's',
        'created': DateTime.now().millisecondsSinceEpoch / 1000,
        'attempt': 'a',
        'aspsp': {'name': 'Expected', 'country': 'PT'},
      });
      final result = await service.request('POST', '/api/connections/finish', {
        'callback': '$callbackUrl?state=s&code=c',
      });
      expect(result.status, 400);
      expect(service.store.bankSessions(), isEmpty);
      expect(service.journal.status()['count'], 0);
    },
  );
  test('expired authorization is rejected before exchanging a code', () async {
    await service.store.write('connection-pending.json', {
      'state': 's',
      'created': 0,
      'aspsp': {'name': 'Bank', 'country': 'PT'},
    });
    expect(
      (await service.request('POST', '/api/connections/finish', {
        'callback': '$callbackUrl?state=s&code=c',
      })).status,
      400,
    );
  });
  test('provider rejects invalid keys without persisting secrets', () async {
    expect(
      () => Provider.validateCredentials('own-app', 'invalid'),
      throwsFormatException,
    );
    expect(service.journal.file('credentials.json').existsSync(), false);
  });
  test('signed own key verifies application redirect before saving', () async {
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final pem = CryptoUtils.encodeRSAPrivateKeyToPem(
      pair.privateKey as RSAPrivateKey,
    );
    final provider = Provider(
      service.journal,
      client: MockClient((request) async {
        expect(request.url.path, '/application');
        expect(request.headers['Authorization'], startsWith('Bearer '));
        return http.Response(
          jsonEncode({
            'redirect_urls': [callbackUrl],
            'name': 'Own application',
          }),
          200,
        );
      }),
    );
    await provider.saveCredentials('own-app', pem);
    expect(provider.configured, true);
    expect(service.journal.status()['count'], 0);
    provider.close();
  });
}
