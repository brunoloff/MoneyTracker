import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:money_tracker_core/money_tracker_core.dart';
import 'package:money_tracker_core/special_categories.dart';
import 'package:money_tracker_core/src/classification.dart';
import 'package:money_tracker_core/src/migration.dart';
import 'migration_test.dart' show payment;

void main() {
  late Directory temp;
  late MoneyTrackerService service;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('moneytracker-borrowing-');
    service = MoneyTrackerService(
      temp.path,
      bankApi: (path, [body]) async =>
          throw StateError('Unexpected network request'),
    );
    await service.store.write('ledger.json', {
      'accounts': [
        for (final id in ['a', 'b']) {'id': id, 'label': id},
      ],
      'transactions': [
        {
          ...payment('hotel', amount: -10000, date: '2026-09-01'),
          'category': borrowingCategory,
        },
        {
          ...payment('train', amount: -2000, date: '2026-09-02'),
          'category': borrowingCategory,
        },
        {
          ...payment('refund', amount: 9000, date: '2026-10-01'),
          'category': borrowingCategory,
        },
        {
          ...payment('later', amount: 3000, date: '2026-10-02'),
          'category': borrowingCategory,
        },
      ],
    });
  });
  tearDown(() async {
    await service.close();
    temp.deleteSync(recursive: true);
  });
  Future<ServiceResponse> create(List<String> ids, {String account = 'a'}) =>
      service.request('POST', '/api/borrowing/create', {
        'memberIds': ids,
        'description': 'Business trip',
        'accountId': account,
      });
  Map snapshot() => service.store.snapshot();
  Map group() => (snapshot()['borrowingGroups'] as List).last;

  test(
    'special category identities are added without rewriting legacy data',
    () async {
      final legacy = defaultTaxonomy();
      (legacy['categories'] as List).removeWhere(
        (c) => ['Ignored', borrowingCategory].contains(c['id']),
      );
      await service.store.write('taxonomy.json', legacy);
      final config = service.store.taxonomy();
      expect(
        (config['categories'] as List)
            .take(specialCategoryOrder.length)
            .map((c) => c['id']),
        specialCategoryOrder,
      );
      expect(service.store.read('taxonomy.json', {}), legacy);
      for (final id in specialCategoryOrder) {
        final without = service.store.taxonomy();
        (without['categories'] as List).removeWhere((c) => c['id'] == id);
        without['categoryTransfers'] = {id: 'Other'};
        expect(
          (await service.request('POST', '/api/taxonomy', without)).status,
          400,
        );
        final nested = service.store.taxonomy();
        (nested['categories'] as List).firstWhere(
          (c) => c['id'] == id,
        )['parent'] = 'Other';
        expect(
          (await service.request('POST', '/api/taxonomy', nested)).status,
          400,
        );
      }
    },
  );
  test(
    'many signed payments produce one excluded leftover with provenance',
    () async {
      final raw = service.store.read('ledger.json', {});
      expect((await create(['hotel', 'train', 'refund'])).status, 200);
      final g = group(), leftover = group()['leftover'];
      expect(leftover['amount'], -3000);
      expect(leftover['date'], '2026-10-01');
      expect(leftover['category'], borrowingCategory);
      expect(leftover['settlementGroupId'], g['id']);
      expect(g['transactions'].map((p) => p['id']), [
        'hotel',
        'train',
        'refund',
      ]);
      expect((snapshot()['transactions'] as List).map((p) => p['id']).toSet(), {
        'later',
        leftover['id'],
      });
      expect(service.store.read('ledger.json', {}), raw);
      expect(service.journal.status()['undo'], 'Group borrowing payments');
      expect(
        (await service.request('POST', '/api/category', {
          'id': leftover['id'],
          'category': 'Travel',
        })).status,
        200,
      );
      expect(group()['leftover']['category'], 'Travel');
      expect(
        (await service.request('POST', '/api/category', {
          'id': 'hotel',
          'category': 'Travel',
        })).status,
        400,
      );
    },
  );
  for (final amount in [12000, 15000]) {
    test(
      'a settled or overpaid group preserves exact balance $amount',
      () async {
        final raw = service.store.read('ledger.json', {});
        raw['transactions'][2]['amount'] = amount;
        await service.store.write('ledger.json', raw);
        expect((await create(['hotel', 'train', 'refund'])).status, 200);
        expect(group()['leftover']['amount'], amount - 12000);
        expect(
          (snapshot()['transactions'] as List).any(
            (p) => p['id'] == group()['leftoverId'],
          ),
          true,
        );
      },
    );
  }
  test(
    'nested leftovers prevent parent deletion and restore in reverse order',
    () async {
      await create(['hotel', 'train', 'refund']);
      final parent = group(), leftoverId = group()['leftoverId'];
      expect((await create([leftoverId, 'later'])).status, 200);
      final child = group();
      expect(child['leftover']['amount'], 0);
      expect((snapshot()['transactions'] as List).length, 1);
      final groups = snapshot()['borrowingGroups'];
      final undo = service.journal.status();
      expect(
        (await service.request('POST', '/api/borrowing/delete', {
          'id': parent['id'],
        })).status,
        400,
      );
      expect(
        (await service.request('POST', '/api/category', {
          'id': leftoverId,
          'category': 'Travel',
        })).status,
        400,
      );
      expect(snapshot()['borrowingGroups'], groups);
      expect(service.journal.status(), undo);
      expect(groups.first['usedBy'], child['id']);
      expect(groups.first['canDelete'], false);
      expect(
        (await service.request('POST', '/api/borrowing/delete', {
          'id': child['id'],
        })).status,
        200,
      );
      expect((snapshot()['transactions'] as List).map((p) => p['id']).toSet(), {
        leftoverId,
        'later',
      });
      expect(
        (await service.request('POST', '/api/borrowing/delete', {
          'id': parent['id'],
        })).status,
        200,
      );
      expect((snapshot()['transactions'] as List).map((p) => p['id']).toSet(), {
        'hotel',
        'train',
        'refund',
        'later',
      });
    },
  );
  test(
    'group creation, reclassification and deletion survive restart and undo/redo',
    () async {
      await create(['hotel', 'refund']);
      final g = group(), leftoverId = group()['leftoverId'];
      await service.request('POST', '/api/category', {
        'id': leftoverId,
        'category': 'Travel',
      });
      await service.close();
      service = MoneyTrackerService(temp.path);
      expect(group()['leftover']['category'], 'Travel');
      expect(
        (await service.request('POST', '/api/borrowing/delete', {
          'id': g['id'],
        })).status,
        200,
      );
      expect(
        service.store.read('categories.json', {}).containsKey(leftoverId),
        false,
      );
      await service.request('POST', '/api/undo');
      expect(group()['leftover']['category'], 'Travel');
      await service.request('POST', '/api/undo');
      expect(group()['leftover']['category'], borrowingCategory);
      await service.request('POST', '/api/undo');
      expect(snapshot().containsKey('borrowingGroups'), false);
      await service.request('POST', '/api/redo');
      expect(group()['leftoverId'], leftoverId);
    },
  );
  test(
    'bank corrections recalculate every level without duplicating raw records',
    () async {
      await create(['hotel', 'refund']);
      await create([group()['leftoverId'], 'later']);
      expect(group()['leftover']['amount'], 2000);
      final raw = service.store.read('ledger.json', {});
      raw['transactions'][0]['amount'] = -11000;
      await service.store.write('ledger.json', raw);
      expect(group()['leftover']['amount'], 1000);
      expect(
        (service.store.read('ledger.json', {})['transactions'] as List).length,
        4,
      );
      expect(
        service.store
            .snapshot(client: true)['borrowingGroups']
            .first['leftover']['sourceRecords']
            .single['kind'],
        'borrowing_balance',
      );
    },
  );
  test(
    'duplicate merge and unmerge cannot consume or split a virtual/grouped payment',
    () async {
      await create(['hotel', 'train']);
      expect(
        (await service.request('POST', '/api/merge', {
          'primaryId': group()['leftoverId'],
          'secondaryId': 'later',
        })).status,
        400,
      );
      expect(
        (await service.request('POST', '/api/unmerge', {'id': 'hotel'})).status,
        400,
      );
      expect(
        (await service.request('POST', '/api/unmerge', {
          'id': group()['leftoverId'],
        })).status,
        400,
      );
      expect(
        (await service.request('POST', '/api/transactions/delete', {
          'id': group()['leftoverId'],
        })).status,
        404,
      );
    },
  );
  test(
    'invalid, repeated, pending, ignored or re-used members leave no partial writes',
    () async {
      for (final ids in [
        ['hotel'],
        ['hotel', 'hotel'],
        ['hotel', 'missing'],
      ]) {
        expect((await create(ids)).status, 400);
        expect(
          service.journal.file('borrowing-groups.json').existsSync(),
          false,
        );
      }
      await service.request('POST', '/api/category', {
        'id': 'hotel',
        'category': 'Ignored',
      });
      expect((await create(['hotel', 'refund'])).status, 400);
      await service.request('POST', '/api/category', {
        'id': 'hotel',
        'category': borrowingCategory,
      });
      final raw = service.store.read('ledger.json', {});
      raw['transactions'][0]['status'] = 'PDNG';
      await service.store.write('ledger.json', raw);
      expect((await create(['hotel', 'refund'])).status, 400);
      raw['transactions'][0]['status'] = 'BOOK';
      await service.store.write('ledger.json', raw);
      await service.store.ensureIgnoredTag();
      await service.request('POST', '/api/tags', {
        'id': 'hotel',
        'tags': ['ignored'],
      });
      expect((await create(['hotel', 'refund'])).status, 400);
      expect((await create(['train', 'refund'])).status, 200);
      expect((await create(['train', 'later'])).status, 400);
    },
  );
  test(
    'cross-account groups have one explicit account and cannot mix owners or currencies',
    () async {
      final raw = service.store.read('ledger.json', {});
      raw['transactions'][2]['accountId'] = 'b';
      await service.store.write('ledger.json', raw);
      await service.store.write('profiles.json', {
        'users': [],
        'accountUsers': {'a': 'alice', 'b': 'bob'},
      });
      expect((await create(['hotel', 'refund'])).status, 400);
      await service.store.write('profiles.json', {
        'users': [],
        'accountUsers': {'a': 'alice', 'b': 'alice'},
      });
      expect(
        (await create(['hotel', 'refund'], account: 'missing')).status,
        400,
      );
      raw['transactions'][2]['currency'] = 'USD';
      await service.store.write('ledger.json', raw);
      expect((await create(['hotel', 'refund'])).status, 400);
      raw['transactions'][2]['currency'] = 'EUR';
      await service.store.write('ledger.json', raw);
      expect((await create(['hotel', 'refund'], account: 'b')).status, 200);
      expect(group()['leftover']['accountIds'], ['b']);
    },
  );
  test(
    'a duplicate payment remains one group member and restores its merged sources',
    () async {
      final raw = service.store.read('ledger.json', {});
      raw['transactions'].add({
        ...payment('duplicate', amount: -10000),
        'category': borrowingCategory,
      });
      await service.store.write('ledger.json', raw);
      await service.request('POST', '/api/merge', {
        'primaryId': 'hotel',
        'secondaryId': 'duplicate',
      });
      await create(['hotel', 'refund']);
      expect(group()['leftover']['amount'], -1000);
      expect(group()['transactions'].first['sourceRecords'].length, 2);
      expect(
        (await service.request('POST', '/api/unmerge', {'id': 'hotel'})).status,
        400,
      );
      await service.request('POST', '/api/borrowing/delete', {
        'id': group()['id'],
      });
      final hotel = (snapshot()['transactions'] as List).firstWhere(
        (p) => p['id'] == 'hotel',
      );
      expect(hotel['merged'], true);
      expect(hotel['sourceRecords'].length, 2);
      expect(
        (await service.request('POST', '/api/unmerge', {'id': 'hotel'})).status,
        200,
      );
      expect((snapshot()['transactions'] as List).length, 5);
    },
  );
  test(
    'virtual leftovers accept normal tags and income categories with the normal sign guard',
    () async {
      await create(['hotel', 'train', 'refund']);
      final leftoverId = group()['leftoverId'];
      expect(
        (await service.request('POST', '/api/category', {
          'id': leftoverId,
          'category': 'Salary',
        })).status,
        400,
      );
      await service.store.ensureIgnoredTag();
      expect(
        (await service.request('POST', '/api/tags', {
          'id': leftoverId,
          'tags': ['ignored'],
        })).status,
        200,
      );
      expect(group()['leftover']['tags'], ['ignored']);
      expect((await create([leftoverId, 'later'])).status, 400);
      await service.request('POST', '/api/tags', {
        'id': leftoverId,
        'tags': [],
      });
      expect((await create([leftoverId, 'later'])).status, 200);
    },
  );
  test(
    'import preserves borrowing groups, virtual classifications and reversible history',
    () async {
      await create(['hotel', 'refund']);
      final id = group()['leftoverId'];
      await service.request('POST', '/api/category', {
        'id': id,
        'category': 'Travel',
      });
      final expected = snapshot();
      final target = Directory('${temp.path}-import')..createSync();
      await service.close();
      try {
        await migrateLegacy(
          temp.path,
          target.path,
          Uint8List.fromList(List.filled(32, 7)),
        );
        final imported = MoneyTrackerService(target.path);
        try {
          expect(imported.store.snapshot(), expected);
          expect((await imported.request('POST', '/api/undo')).status, 200);
          expect(
            imported.store
                .snapshot()['borrowingGroups']
                .single['leftover']['category'],
            borrowingCategory,
          );
        } finally {
          await imported.close();
        }
      } finally {
        service = MoneyTrackerService(temp.path);
        target.deleteSync(recursive: true);
      }
      expect(snapshot(), expected);
    },
  );
}
