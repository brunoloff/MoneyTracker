import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:money_tracker_core/money_tracker_core.dart';
import 'package:money_tracker_core/src/classification.dart';
import 'package:money_tracker_core/src/compat.dart';
import 'package:money_tracker_core/src/journal.dart';

Map<String, dynamic> rule(
  String id,
  String? category,
  String text, {
  String? user,
  List<String>? tags,
  bool enabled = true,
}) => {
  'id': id,
  'name': id,
  'category': category,
  'enabled': enabled,
  'kind': tags == null ? 'category' : 'extra',
  'userId': ?user,
  'tags': ?tags,
  'groups': [
    [
      {'field': 'description', 'operator': 'contains', 'value': text},
    ],
  ],
};
Map<String, dynamic> row(String id, String account, String text) => {
  'id': id,
  'accountId': account,
  'description': text,
  'date': '2026-10-01',
  'amount': -100,
  'currency': 'EUR',
  'category': 'Uncategorized',
  'status': 'BOOK',
  'reviewed': false,
  'source': 'Synthetic bank',
};
Map<String, dynamic> profiles() => {
  'users': [
    <String, dynamic>{'id': 'alice', 'name': 'Alice'},
    <String, dynamic>{'id': 'bob', 'name': 'Bob'},
  ],
  'accountUsers': {'a': 'alice', 'b': 'bob', 'd': 'alice'},
};

void main() {
  late Directory temp;
  late MoneyTrackerService service;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('moneytracker-user-rules-');
    service = MoneyTrackerService(
      temp.path,
      bankApi: (path, [body]) async => throw StateError('Unexpected network'),
    );
    await service.store.write('ledger.json', {
      'accounts': [
        for (final id in ['a', 'b', 'c', 'd']) {'id': id, 'label': id},
      ],
      'transactions': [
        for (final a in ['a', 'b', 'c', 'd'])
          for (final text in ['shared shop', 'alice shop', 'bob shop'])
            row('$a-$text', a, text),
      ],
    });
    await service.store.write('profiles.json', profiles());
    await service.store.write('rules.json', [
      rule('shared', 'Food', 'shared shop'),
      rule('alice', 'Food', 'alice shop', user: 'alice'),
      rule('bob', 'Food', 'bob shop', user: 'bob'),
    ]);
  });
  tearDown(() async {
    await service.close();
    temp.deleteSync(recursive: true);
  });
  Map<String, String> categories() => {
    for (final r in service.store.snapshot()['transactions'])
      r['id']: r['category'],
  };
  Future<ServiceResponse> save(Map r) =>
      service.request('POST', '/api/rules/save', {'rule': r});

  test(
    'shared and personal label terms form OR without leaking to other users',
    () async {
      final result = categories();
      for (final a in ['a', 'b', 'c', 'd']) {
        expect(result['$a-shared shop'], 'Food');
      }
      for (final a in ['a', 'd']) {
        expect(result['$a-alice shop'], 'Food');
      }
      expect(result['b-bob shop'], 'Food');
      expect(result['a-bob shop'], 'Uncategorized');
      expect(result['b-alice shop'], 'Uncategorized');
      expect(result['c-alice shop'], 'Uncategorized');
      await service.store.write('preferences.json', {'selectedUser': 'alice'});
      expect(categories(), result);
      await service.store.write('preferences.json', {'selectedUser': 'bob'});
      expect(categories(), result);
    },
  );

  test(
    'personal priority precedes shared; manual overrides still win',
    () async {
      expect(
        (await save(
          rule('personal travel', 'Travel', 'shared shop', user: 'alice'),
        )).status,
        200,
      );
      expect(categories()['a-shared shop'], 'Travel');
      expect(categories()['b-shared shop'], 'Food');
      await service.store.write('categories.json', {
        'a-shared shop': 'Shopping',
      });
      expect(categories()['a-shared shop'], 'Shopping');
      final book = RuleBook(
        [rule('salary', 'Salary', 'salary', user: 'alice')],
        profiles(),
        {},
      );
      expect(book.categoryRule(row('out', 'a', 'salary')), isNull);
      expect(
        book.categoryRule({...row('in', 'a', 'salary'), 'amount': 100}),
        isNotNull,
      );
    },
  );

  test(
    'per-user settings independently disable either or both pools',
    () async {
      final p = profiles();
      p['users'][0]['useSharedRules'] = false;
      await service.store.write('profiles.json', p);
      expect(categories()['a-shared shop'], 'Uncategorized');
      expect(categories()['a-alice shop'], 'Food');
      expect(categories()['b-shared shop'], 'Food');
      p['users'][0]['useSharedRules'] = true;
      p['users'][0]['usePersonalRules'] = false;
      await service.store.write('profiles.json', p);
      expect(categories()['a-shared shop'], 'Food');
      expect(categories()['a-alice shop'], 'Uncategorized');
      p['users'][0]['useSharedRules'] = false;
      await service.store.write('profiles.json', p);
      expect(categories()['a-shared shop'], 'Uncategorized');
      expect(categories()['a-alice shop'], 'Uncategorized');
    },
  );

  test(
    'tag rules from both pools accumulate and paused personal rules stay inactive',
    () async {
      final taxonomy = defaultTaxonomy();
      taxonomy['tags'] = [
        for (final id in ['shared-tag', 'personal-tag']) {'id': id, 'name': id},
      ];
      await service.store.write('taxonomy.json', taxonomy);
      expect(
        (await save(
          rule('shared tag', null, 'shop', tags: ['shared-tag']),
        )).status,
        200,
      );
      expect(
        (await save(
          rule(
            'personal tag',
            null,
            'shop',
            user: 'alice',
            tags: ['personal-tag'],
          ),
        )).status,
        200,
      );
      expect(
        (await save(
          rule('paused', 'Travel', 'bob shop', user: 'alice', enabled: false),
        )).status,
        200,
      );
      final rows = {
        for (final r in service.store.snapshot()['transactions']) r['id']: r,
      };
      expect(rows['a-bob shop']['tags'], ['personal-tag', 'shared-tag']);
      expect(rows['b-bob shop']['tags'], ['shared-tag']);
      expect(rows['a-bob shop']['category'], 'Uncategorized');
    },
  );

  test(
    'consolidating, clearing and reordering one pool preserve all other pools',
    () async {
      final before = maps(service.store.read('rules.json', []));
      expect(
        (await save(
          rule('alice', 'Food', 'new alice shop', user: 'alice'),
        )).status,
        200,
      );
      var current = maps(service.store.read('rules.json', []));
      expect(
        current.where((r) => r['userId'] != 'alice'),
        before.where((r) => r['userId'] != 'alice'),
      );
      expect(
        (await save(rule('second', 'Travel', 'other', user: 'alice'))).status,
        200,
      );
      expect(
        (await service.request('POST', '/api/rules/move', {
          'id': 'second',
          'delta': -1,
        })).status,
        200,
      );
      current = maps(service.store.read('rules.json', []));
      expect(current.where((r) => r['userId'] == 'alice').map((r) => r['id']), [
        'second',
        'alice',
      ]);
      expect(
        current.where((r) => r['userId'] != 'alice'),
        before.where((r) => r['userId'] != 'alice'),
      );
      expect(
        (await service.request('POST', '/api/rules/delete', {
          'id': 'alice',
        })).status,
        200,
      );
      expect(categories()['a-alice shop'], 'Uncategorized');
      expect(categories()['a-shared shop'], 'Food');
      expect(categories()['b-bob shop'], 'Food');
      expect(
        (await service.request('POST', '/api/rules/move', {
          'id': 'shared',
          'delta': 1,
        })).status,
        400,
      );
    },
  );

  test(
    'reject unknown users, reserved view IDs, scope changes and malformed settings atomically',
    () async {
      final before = service.store.read('rules.json', []);
      for (final id in ['missing', 'all', 'unassigned', '']) {
        expect((await save(rule('bad', 'Food', 'x', user: id))).status, 400);
      }
      expect(
        (await save(rule('shared', 'Food', 'x', user: 'alice'))).status,
        400,
      );
      expect((await save(rule('shared', 'Travel', 'x'))).status, 400);
      expect(service.store.read('rules.json', []), before);
      final p = profiles();
      p['users'][0]['useSharedRules'] = 'yes';
      expect((await service.request('POST', '/api/profiles', p)).status, 400);
      expect(service.store.read('profiles.json', {}), profiles());
    },
  );

  test(
    'category transfers consolidate per pool while preserving paused rules',
    () {
      final rules = [
        rule('shared-food', 'Food', 'common'),
        rule('shared-travel', 'Travel', 'common trip'),
        rule('alice-food', 'Food', 'alice', user: 'alice'),
        rule('alice-travel', 'Travel', 'alice trip', user: 'alice'),
        rule('bob-food', 'Food', 'bob', user: 'bob'),
        rule('paused', 'Travel', 'paused', user: 'alice', enabled: false),
      ];
      final transferred = transferCategories(
        rules,
        {'Travel': 'Food'},
        {'Food': 'Food'},
      );
      expect(categoryDraft('Food', 'Food', transferred)['groups'].length, 2);
      expect(
        categoryDraft(
          'Food',
          'Food',
          transferred,
          userId: 'alice',
        )['groups'].length,
        2,
      );
      expect(
        categoryDraft(
          'Food',
          'Food',
          transferred,
          userId: 'bob',
        )['groups'].length,
        1,
      );
      expect(
        transferred.singleWhere((r) => r['id'] == 'paused')['enabled'],
        false,
      );
      expect(rules[1]['category'], 'Travel');
    },
  );

  test(
    'preview uses ownership, personal precedence, pool settings and the saved result',
    () async {
      final proposed = rule(
        'personal-travel',
        'Travel',
        'shared shop',
        user: 'alice',
      );
      var preview = await service.request('POST', '/api/rules/preview', {
        'rule': proposed,
      });
      expect(preview.status, 200);
      expect((preview.data['matches'] as List).map((r) => r['id']), [
        'a-shared shop',
        'd-shared shop',
      ]);
      expect(
        (preview.data['matches'] as List).every((r) => r['blockedBy'] == null),
        true,
      );
      expect((await save(proposed)).status, 200);
      expect(categories()['a-shared shop'], 'Travel');
      preview = await service.request('POST', '/api/rules/preview', {
        'rule': rule('shared', 'Food', 'shared shop'),
      });
      expect(
        (preview.data['matches'] as List).firstWhere(
          (r) => r['id'] == 'a-shared shop',
        )['blockedBy'],
        contains('personal-travel'),
      );
      final p = profiles();
      p['users'][0]['usePersonalRules'] = false;
      await service.store.write('profiles.json', p);
      preview = await service.request('POST', '/api/rules/preview', {
        'rule': proposed,
      });
      expect(preview.data['matches'], isEmpty);
    },
  );

  test(
    'deleting a user retains dormant personal rules; undo restores ownership and application',
    () async {
      final original = service.store.read('rules.json', []);
      final p = profiles();
      p['users'].removeAt(0);
      p['accountUsers'] = {'b': 'bob'};
      expect((await service.request('POST', '/api/profiles', p)).status, 200);
      expect(service.store.read('rules.json', []), original);
      expect(categories()['a-alice shop'], 'Uncategorized');
      expect(categories()['a-shared shop'], 'Food');
      service.journal.restore();
      expect(categories()['a-alice shop'], 'Food');
      service.journal.restore(redo: true);
      expect(categories()['a-alice shop'], 'Uncategorized');
    },
  );

  test(
    'legacy profile saves preserve pool settings; restart and undo retain scoped rules',
    () async {
      final p = profiles();
      p['users'][0]['useSharedRules'] = false;
      expect((await service.request('POST', '/api/profiles', p)).status, 200);
      expect(
        (await service.request('POST', '/api/profiles', profiles())).status,
        200,
      );
      expect(
        service.store.read('profiles.json', {})['users'][0]['useSharedRules'],
        false,
      );
      expect(
        (await save(
          rule('alice', 'Food', 'replacement', user: 'alice'),
        )).status,
        200,
      );
      final expected = service.store.read('rules.json', []);
      await service.close();
      service = MoneyTrackerService(temp.path);
      expect(service.store.read('rules.json', []), expected);
      expect(service.journal.dataFormat['version'], 4);
      service.journal.restore();
      expect(categories()['a-alice shop'], 'Food');
      service.journal.restore(redo: true);
      expect(service.store.read('rules.json', []), expected);
    },
  );

  test(
    'merged ownership is canonical, with a unique linked-owner fallback',
    () {
      final book = RuleBook(
        [
          rule('a', 'Food', 'shop', user: 'alice'),
          rule('b', 'Travel', 'shop', user: 'bob'),
        ],
        profiles(),
        {},
      );
      expect(
        book.categoryRule({
          ...row('m', 'a', 'shop'),
          'accountIds': ['a', 'b'],
        })?['id'],
        'a',
      );
      expect(
        book.categoryRule({
          ...row('m', 'c', 'shop'),
          'accountIds': ['c', 'a', 'd'],
        })?['id'],
        'a',
      );
      expect(
        book.categoryRule({
          ...row('m', 'c', 'shop'),
          'accountIds': ['c', 'a', 'b'],
        }),
        isNull,
      );
    },
  );

  test(
    'v4 is inferred from scoped rules retained only in redo history',
    () async {
      await service.close();
      temp.deleteSync(recursive: true);
      temp.createSync();
      final j = Journal(temp.path);
      await j.write('profiles.json', profiles());
      await j.action(
        'Personal rules',
        () => j.write('rules.json', [rule('new', 'Food', 'x', user: 'alice')]),
      );
      j.restore();
      j.close();
      File('${temp.path}/data-format.json').deleteSync();
      expect(inspectDataFormat(temp).version, 4);
      File('${temp.path}/data-format.json').writeAsStringSync(
        jsonEncode({
          'format': 'moneytracker',
          'version': 3,
          'journalVersion': 1,
        }),
      );
      final before = digest(
        File('${temp.path}/undo.sqlite3').readAsBytesSync(),
      );
      expect(() => Journal(temp.path), throwsFormatException);
      expect(
        digest(File('${temp.path}/undo.sqlite3').readAsBytesSync()),
        before,
      );
      File('${temp.path}/data-format.json').deleteSync();
      service = MoneyTrackerService(temp.path);
      service.journal.restore(redo: true);
      expect(service.store.read('rules.json', []).single['userId'], 'alice');
    },
  );
}
