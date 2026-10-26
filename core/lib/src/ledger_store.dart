import 'classification.dart';
import 'compat.dart';
import 'journal.dart';
import 'package:uuid/uuid.dart';
import '../special_categories.dart';

String stableAccountId(Map account, [String source = 'CGD']) {
  final identity = present(account['identification_hash'])
      ? account['identification_hash']
      : pythonJson(account['account_id'], sorted: true);
  if (!present(identity) || identity == 'null') {
    invalid('Bank account has no stable identity');
  }
  return hashText('enablebanking:$source:$identity', 24);
}

String paypalAccountId(Map account) =>
    'paypal-${hashText(pythonString(present(account['identification_hash']) ? account['identification_hash'] : account['account_id']), 24)}';
String sourceName(Map session) {
  final name = session['aspsp']?['name'] ?? 'CGD';
  return {'CGD', 'Caixa Geral de Depósitos'}.contains(name)
      ? 'CGD'
      : name as String;
}

DateTime historyStart(dynamic years, [DateTime? today]) {
  if (years is! int || years < 1 || years > 20) invalid('Choose 1 to 20 years');
  final d = today ?? DateTime.now(), y = d.year - (years);
  final target = DateTime.utc(y, d.month, d.day);
  return target.month == d.month ? target : DateTime.utc(y, d.month, 28);
}

const suggestions = {
  'Food':
      r'PINGO DOCE|CONTINENTE|LIDL|ALDI|AUCHAN|SPAR|RESTAUR|QUIOSQUE|CERV|PASTEL|SUPERMERC|CAF[EÉ]',
  'Shopping': r'AMAZON|WWW\.AMA|FNAC|IKEA|DECATHLON|ZARA',
  'Transport':
      r'UBER(?!.*EATS)|BOLT|METRO|CP COMBO|CARRIS|VIA VERDE|GALP|REPSOL',
  'Bills': r'VODAFONE|MEO |NOS |EDP|ENDESA|EPAL|AGUA|IMPOSTO|COMISS|COM SB',
  'Health': r'FARM[AÁ]CIA|HOSPITAL|CLINIC',
  'Travel': r'RYANAIR|EASYJET|TAP |HOTEL|AIRBNB|BOOKING|BETTERROAMING',
  'Entertainment': r'NETFLIX|SPOTIFY|CINEMA',
};
String suggest(String description, int amount, Set<dynamic> allowed) {
  if (amount > 0) {
    return allowed.contains('Other income') ? 'Other income' : 'Uncategorized';
  }
  for (final e in suggestions.entries) {
    if (RegExp(e.value, caseSensitive: false).hasMatch(description)) {
      return allowed.contains(e.key) ? e.key : 'Uncategorized';
    }
  }
  return 'Uncategorized';
}

Map<String, dynamic> normalize(
  Map raw,
  String accountId,
  Set<dynamic> allowed, [
  String source = 'CGD',
]) {
  final currency = raw['transaction_amount']['currency'];
  if (currency != 'EUR') {
    invalid(
      'This first version only supports EUR; refusing to mix currencies.',
    );
  }
  final amount =
      cents(raw['transaction_amount']['amount'], round: true).abs() *
      (raw['credit_debit_indicator'] == 'DBIT' ? -1 : 1);
  final description = present(raw['remittance_information'])
      ? (raw['remittance_information'] as List).join(' · ')
      : present(raw['note'])
      ? raw['note'] as String
      : 'Bank transaction';
  final date =
      raw['transaction_date'] ?? raw['booking_date'] ?? raw['value_date'];
  if (!present(date)) invalid('Transaction has no date');
  final reference = present(raw['entry_reference'])
      ? raw['entry_reference']
      : raw['transaction_id'];
  final identity = present(reference)
      ? pythonString(reference)
      : pythonJson(raw, sorted: true, compact: true);
  final id = hashText('$accountId:$identity', 32);
  return {
    'id': id,
    'accountId': accountId,
    'date': (date as String).substring(0, 10),
    'bookingDate': raw['booking_date'],
    'amount': amount,
    'currency': currency,
    'description': description.trim(),
    'category': suggest(description, amount, allowed),
    'reviewed': false,
    'status': raw['status'] ?? 'BOOK',
    'source': source,
    'purchaseDetails': <dynamic>[],
    'relatedSourceIds': <dynamic>[],
    'hasStableId': present(reference),
    'sourceRecord': {
      'id': id,
      'provider': 'enablebanking',
      'institution': source,
      'kind': 'bank_movement',
      'externalId': reference,
      'accountId': accountId,
      'date': date.substring(0, 10),
      'description': description.trim(),
      'amount': amount,
      'currency': currency,
    },
  };
}

class LedgerStore {
  final Journal journal;
  LedgerStore(this.journal);
  dynamic read(String name, dynamic fallback) => journal.read(name, fallback);
  Future<void> write(String name, dynamic value) => journal.write(name, value);
  Map<String, dynamic> taxonomy() {
    final config = Map<String, dynamic>.from(
      read('taxonomy.json', defaultTaxonomy()),
    );
    for (final id in specialCategoryOrder) {
      if ((config['categories'] as List).any((c) => c['id'] == id)) continue;
      final names = (config['categories'] as List)
          .map((c) => c['name'].toString().toLowerCase())
          .toSet();
      var name = id, suffix = 1;
      while (names.contains(name.toLowerCase())) {
        name = '$id (special ${suffix++})';
      }
      config['categories'].add({
        'id': id,
        'name': name,
        'parent': null,
        'color': categoryColors[id],
      });
    }
    config['categories'] = orderedCategories(maps(config['categories']));
    return config;
  }

  Set<dynamic> get categoryIds =>
      (taxonomy()['categories'] as List).map((c) => c['id']).toSet();
  Future<void> ensureIgnoredTag() async {
    final config = taxonomy();
    if ((config['tags'] as List).any((t) => t['id'] == 'ignored')) return;
    if ((config['tags'] as List).length >= 200) {
      invalid(
        'Remove an unused tag before adding the special Ignored tag (200-tag limit)',
      );
    }
    final names = (config['tags'] as List)
        .map((t) => t['name'].toString().toLowerCase())
        .toSet();
    var name = 'Ignored', suffix = 1;
    while (names.contains(name.toLowerCase())) {
      name = 'Ignored (excluded ${suffix++})';
    }
    config['tags'].add({'id': 'ignored', 'name': name});
    await write('taxonomy.json', config);
  }

  Map<dynamic, dynamic> get roots => {
    for (final c in taxonomy()['categories']) c['id']: c['parent'] ?? c['id'],
  };
  List<Map<String, dynamic>> bankSessions() {
    final legacy = read('session.json', null);
    return [
      if (legacy != null) Map<String, dynamic>.from(legacy),
      ...maps(read('bank-sessions.json', [])),
    ];
  }

  Map<String, dynamic> snapshot({
    bool client = false,
    bool includeGroups = true,
  }) {
    final config = taxonomy(), rootCategories = roots;
    final result = Map<String, dynamic>.from(
      read('ledger.json', {
        'accounts': [],
        'transactions': [],
        'syncedAt': null,
      }),
    );
    final overrides = read('categories.json', {}),
        groups = read('merges.json', {}),
        tags = read('tags.json', {});
    final rules = maps(read('rules.json', [])),
        categoryRules = rules.where(
          (r) => present(r['category']) && enabled(r),
        ),
        tagRules = rules.where((r) => present(r['tags']) && enabled(r));
    final records = {for (final row in result['transactions']) row['id']: row};
    final children = <dynamic>{
      for (final e in (groups as Map).entries)
        if (records.containsKey(e.key))
          for (final child in e.value)
            if (child != e.key) child,
    };
    final paypalRows = read('paypal-observations.json', {}),
        links = read('paypal-associations.json', {});
    final paypalByBank = {
      for (final e in (links as Map).entries)
        if (paypalRows.containsKey(e.key)) e.value: paypalRows[e.key],
    };
    final payments = <dynamic>[];
    for (final row in result['transactions']) {
      if (children.contains(row['id'])) continue;
      final ids = <dynamic>{row['id'], ...groups[row['id']] ?? []};
      final observations = [
        for (final id in ids)
          if (records.containsKey(id)) records[id],
      ];
      row['sourceRecords'] = [
        for (final o in observations)
          o['sourceRecord'] ??
              {
                'id': o['id'],
                'institution': o['source'],
                'kind': 'bank_movement',
                'description': o['description'],
                'date': o['date'],
                'amount': o['amount'],
                'currency': o['currency'],
                'accountId': o['accountId'],
              },
      ];
      row['accountIds'] = observations
          .map((o) => o['accountId'])
          .toSet()
          .toList();
      for (final o in observations) {
        if (paypalByBank.containsKey(o['id'])) {
          final paypal = Map<String, dynamic>.from(paypalByBank[o['id']])
            ..remove('raw');
          row['sourceRecords'].add(paypal);
          row['description'] = paypal['description'];
          row['accountIds'].add(paypal['accountId']);
        }
      }
      row['merged'] = observations.length > 1;
      row['tags'] = <dynamic>{
        for (final o in observations) ...tags[o['id']] ?? [],
      }.toList()..sort();
      row['classificationRule'] = null;
      row['reviewed'] = false;
      for (final rule in categoryRules) {
        if (ruleMatches(rule, row, rootCategories)) {
          row['category'] = rule['category'];
          row['classificationRule'] = {'id': rule['id'], 'name': rule['name']};
          break;
        }
      }
      for (final rule in tagRules) {
        if (ruleMatches(rule, row, rootCategories)) {
          row['tags'] = <dynamic>{...row['tags'], ...rule['tags']}.toList()
            ..sort();
        }
      }
      if (overrides.containsKey(row['id'])) {
        row['classificationRule'] = null;
        row['category'] = overrides[row['id']];
        row['reviewed'] = true;
      }
      payments.add(row);
    }
    final paypalAccounts =
        (paypalRows as Map).values.map((o) => o['accountId']).toSet().toList()
          ..sort();
    result['accounts'] ??= [];
    final known = (result['accounts'] as List).map((a) => a['id']).toSet();
    result['accounts'].addAll([
      for (final id in paypalAccounts)
        if (!known.contains(id))
          {
            'id': id,
            'label': 'PayPal',
            'source': 'PayPal',
            'kind': 'PAYPAL',
            'balance': null,
          },
    ]);
    final borrowingGroups = <Map<String, dynamic>>[];
    if (includeGroups) {
      final stored = maps(read('borrowing-groups.json', []));
      final byId = {for (final row in payments) row['id']: row};
      final consumed = <String, String>{};
      final waiting = <String>{};
      final projected = <String, Map<String, dynamic>>{};
      final definitions = {for (final g in stored) g['id']: g};
      Map<String, dynamic> project(Map<String, dynamic> g) {
        final id = g['id'] as String;
        if (projected.containsKey(id)) return projected[id]!;
        if (!waiting.add(id)) invalid('Borrowing groups contain a cycle');
        final members = <dynamic>[];
        for (final memberId in g['memberIds']) {
          if (consumed.containsKey(memberId) && consumed[memberId] != id) {
            invalid('A payment belongs to more than one borrowing group');
          }
          consumed[memberId] = id;
          if (!byId.containsKey(memberId)) {
            final parent = stored
                .where((p) => p['leftoverId'] == memberId)
                .firstOrNull;
            if (parent == null) {
              invalid('Borrowing group has a missing payment');
            }
            project(parent);
          }
          members.add(byId[memberId]);
        }
        final amount = members.fold<int>(
          0,
          (sum, p) => sum + (p['amount'] as int),
        );
        final row = <String, dynamic>{
          'id': g['leftoverId'],
          'accountId': g['accountId'],
          'accountIds': [g['accountId']],
          'date': g['date'],
          'amount': amount,
          'currency': g['currency'],
          'description': g['description'],
          'category': borrowingCategory,
          'source': 'Borrowing group',
          'status': 'BOOK',
          'reviewed': true,
          'settlementGroupId': id,
          'merged': false,
          'purchaseDetails': <dynamic>[],
          'sourceRecords': <dynamic>[],
          'tags': tags[g['leftoverId']] ?? <dynamic>[],
          'classificationRule': null,
        };
        row['sourceRecords'] = [
          {
            'id': row['id'],
            'kind': 'borrowing_balance',
            'institution': 'Borrowing group',
            'description': row['description'],
            'accountId': row['accountId'],
            'date': row['date'],
            'amount': amount,
            'currency': row['currency'],
          },
        ];
        for (final rule in categoryRules) {
          if (ruleMatches(rule, row, rootCategories)) {
            row['category'] = rule['category'];
            row['classificationRule'] = {
              'id': rule['id'],
              'name': rule['name'],
            };
            row['reviewed'] = false;
            break;
          }
        }
        for (final rule in tagRules) {
          if (ruleMatches(rule, row, rootCategories)) {
            row['tags'] = <dynamic>{...row['tags'], ...rule['tags']}.toList()
              ..sort();
          }
        }
        if (overrides.containsKey(row['id'])) {
          row['category'] = overrides[row['id']];
          row['classificationRule'] = null;
          row['reviewed'] = true;
        }
        byId[row['id']] = row;
        projected[id] = {...g, 'transactions': members, 'leftover': row};
        waiting.remove(id);
        return projected[id]!;
      }

      for (final g in definitions.values) {
        project(g);
      }
      for (final g in stored) {
        borrowingGroups.add({
          ...projected[g['id']]!,
          'usedBy': consumed[g['leftoverId']],
          'canDelete': !consumed.containsKey(g['leftoverId']),
        });
      }
      payments.clear();
      payments.addAll(byId.values.where((p) => !consumed.containsKey(p['id'])));
    }
    result.addAll({
      'taxonomy': config,
      'rules': rules,
      'transactions': payments,
      'profiles': read('profiles.json', {'users': [], 'accountUsers': {}}),
      'preferences': read('preferences.json', {'period': 'month'}),
      if (borrowingGroups.isNotEmpty) 'borrowingGroups': borrowingGroups,
    });
    if (client) {
      result.remove('fileImports');
      final allRows = <dynamic>[
        ...payments,
        for (final g in borrowingGroups) ...g['transactions'],
        for (final g in borrowingGroups) g['leftover'],
      ];
      for (final row in allRows) {
        row.remove('sourceRecord');
        for (final source in row['sourceRecords']) {
          for (final key in [
            'sha256',
            'sourceFile',
            'sheet',
            'row',
            'availableBalance',
            'bankCategory',
            'balance',
          ]) {
            source.remove(key);
          }
        }
      }
    }
    return result;
  }

  Future<void> createBorrowingGroup(Map body) async {
    final ids = body['memberIds'], description = body['description'];
    if (ids is! List ||
        ids.length < 2 ||
        ids.any((id) => id is! String) ||
        ids.toSet().length != ids.length) {
      invalid('Choose at least two different payments');
    }
    if (description is! String ||
        description.trim().isEmpty ||
        description.trim().length > 200) {
      invalid('Give the group a name (up to 200 characters)');
    }
    final available = {for (final p in snapshot()['transactions']) p['id']: p},
        rootCategories = roots;
    final members = <dynamic>[];
    for (final id in ids) {
      final p = available[id];
      if (p == null ||
          rootCategories[p['category']] != borrowingCategory ||
          p['status'] != 'BOOK' ||
          (p['tags'] as List).contains('ignored')) {
        invalid(
          'Choose available, booked Borrowing and Deposits payments without the Ignored tag',
        );
      }
      members.add(p);
    }
    final currencies = members.map((p) => p['currency']).toSet();
    if (currencies.length != 1) invalid('Group payments in the same currency');
    final owners = read('profiles.json', {})['accountUsers'] ?? {};
    if (members.map((p) => owners[p['accountId']]).toSet().length != 1) {
      invalid('Group payments belonging to the same person');
    }
    final account = body['accountId'];
    if (!members.any((p) => p['accountId'] == account)) {
      invalid('Choose one of the group’s accounts for the leftover');
    }
    final id = const Uuid().v4();
    final dates = members.map((p) => p['date'] as String).toList()..sort();
    await journal.action('Group borrowing payments', () async {
      final overrides = read('categories.json', {}) as Map;
      overrides['borrowing-leftover-$id'] = borrowingCategory;
      await write('categories.json', overrides);
      await write('borrowing-groups.json', [
        ...read('borrowing-groups.json', []),
        {
          'id': id,
          'leftoverId': 'borrowing-leftover-$id',
          'description': description.trim(),
          'memberIds': ids,
          'accountId': account,
          'currency': currencies.single,
          'date': dates.last,
        },
      ]);
    });
  }

  Future<void> deleteBorrowingGroup(dynamic id) async {
    final groups = maps(read('borrowing-groups.json', []));
    final group = groups.where((g) => g['id'] == id).firstOrNull;
    if (group == null) invalid('Group no longer available; reload first');
    if (groups.any(
      (g) => (g['memberIds'] as List).contains(group['leftoverId']),
    )) {
      invalid('Delete the later group using this leftover first');
    }
    await journal.action('Delete borrowing group', () async {
      await write(
        'borrowing-groups.json',
        groups.where((g) => g['id'] != id).toList(),
      );
      for (final file in ['categories.json', 'tags.json']) {
        final saved = read(file, {}) as Map;
        saved.remove(group['leftoverId']);
        await write(file, saved);
      }
    });
  }

  Future<void> merge(dynamic primary, dynamic secondary) async {
    if (primary == secondary) invalid('Choose two different payments');
    final payments = {
      for (final row in snapshot()['transactions']) row['id']: row,
    };
    if (!payments.containsKey(primary) || !payments.containsKey(secondary)) {
      invalid('Payment no longer available; reload first');
    }
    final a = payments[primary], b = payments[secondary];
    if (a['settlementGroupId'] != null || b['settlementGroupId'] != null) {
      invalid('A virtual leftover cannot be merged as a duplicate payment');
    }
    if (['amount', 'currency', 'status'].any((k) => a[k] != b[k])) {
      invalid(
        'This version merges only equal amounts, currency and status; splits and fees need separate reconciliation',
      );
    }
    final groups = read('merges.json', {});
    final old = groups.remove(secondary) ?? [];
    groups[primary] = <dynamic>{
      ...groups[primary] ?? [],
      secondary,
      ...old,
    }.toList();
    await write('merges.json', groups);
  }

  Future<void> unmerge(dynamic id) async {
    if (!(snapshot()['transactions'] as List).any(
      (p) => p['id'] == id && p['settlementGroupId'] == null,
    )) {
      invalid('Payment is grouped or no longer available');
    }
    final groups = read('merges.json', {});
    groups.remove(id);
    await write('merges.json', groups);
  }

  Future<void> saveTaxonomy(Map config) async {
    final ignored = (taxonomy()['tags'] as List)
        .where((t) => t['id'] == 'ignored')
        .firstOrNull;
    if (ignored != null &&
        !(config['tags'] as List).any(
          (t) => t['id'] == 'ignored' && t['name'] == ignored['name'],
        )) {
      invalid('Ignored is a special tag and cannot be renamed or deleted');
    }
    final old = {for (final c in taxonomy()['categories']) c['id']: c};
    final remaining = (config['categories'] as List)
            .map((c) => c['id'])
            .toSet(),
        removed = old.keys.toSet().difference(remaining);
    final transfers = config['categoryTransfers'] ?? {};
    if (transfers is! Map ||
        transfers.keys.toSet().difference(removed).isNotEmpty ||
        removed.difference(transfers.keys.toSet()).isNotEmpty) {
      invalid('Choose a destination for every deleted category');
    }
    for (final e in (transfers).entries) {
      if (isSpecialCategory(e.key) || !remaining.contains(e.value)) {
        invalid(
          'Choose an existing destination; special categories cannot be deleted',
        );
      }
      if ((config['categories'] as List).any((c) => c['parent'] == e.key)) {
        invalid('Delete or move subcategories before deleting their parent');
      }
    }
    final ledger = read('ledger.json', {}),
        overrides = read('categories.json', {});
    if (removed.isNotEmpty) {
      for (final row in snapshot()['transactions']) {
        if (transfers.containsKey(row['category'])) {
          overrides[row['id']] = transfers[row['category']];
        }
      }
    }
    for (final row in ledger['transactions'] ?? []) {
      row['category'] = transfers[row['category']] ?? row['category'];
    }
    for (final k in (overrides as Map).keys.toList()) {
      overrides[k] = transfers[overrides[k]] ?? overrides[k];
    }
    final rules = transferCategories(maps(read('rules.json', [])), transfers, {
      for (final c in config['categories']) c['id']: c['name'],
    });
    final usedCategories = <dynamic>{
      for (final r in ledger['transactions'] ?? []) r['category'],
      ...overrides.values,
      for (final r in rules)
        if (present(r['category'])) r['category'],
    };
    final usedTags = <dynamic>{
      for (final values in (read('tags.json', {}) as Map).values) ...values,
      for (final r in rules) ...r['tags'] ?? [],
    };
    final valid = validateTaxonomy(config, usedCategories, usedTags),
        newRoots = {
          for (final c in valid['categories']) c['id']: c['parent'] ?? c['id'],
        },
        names = {for (final c in valid['categories']) c['id']: c['name']};
    for (final r in rules) {
      if (r['kind'] == 'category') r['name'] = names[r['category']];
    }
    for (final e in transfers.entries) {
      if (incomeCategories.contains(newRoots[e.value]) &&
          !incomeCategories.contains(old[e.key]['parent'] ?? e.key)) {
        invalid('Choose a non-income destination for this category');
      }
    }
    await journal.action('Edit categories and tags', () async {
      if (removed.isNotEmpty) {
        await write('ledger.json', ledger);
        await write('categories.json', overrides);
      }
      if (pythonJson(rules) != pythonJson(read('rules.json', []))) {
        await write('rules.json', rules);
      }
      await write('taxonomy.json', valid);
    });
  }
}
