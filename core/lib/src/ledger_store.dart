import 'classification.dart';
import 'compat.dart';
import 'journal.dart';

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
    if (!(config['categories'] as List).any(
      (c) => c['id'] == 'Uncategorized',
    )) {
      config['categories'].insert(0, {
        'id': 'Uncategorized',
        'name': 'Uncategorized',
        'parent': null,
        'color': '93A0B4',
      });
    }
    return config;
  }

  Set<dynamic> get categoryIds =>
      (taxonomy()['categories'] as List).map((c) => c['id']).toSet();
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

  Map<String, dynamic> snapshot({bool client = false}) {
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
    result.addAll({
      'taxonomy': config,
      'rules': rules,
      'transactions': payments,
      'profiles': read('profiles.json', {'users': [], 'accountUsers': {}}),
      'preferences': read('preferences.json', {'period': 'month'}),
    });
    if (client) {
      result.remove('fileImports');
      for (final row in payments) {
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

  Future<void> merge(dynamic primary, dynamic secondary) async {
    if (primary == secondary) invalid('Choose two different payments');
    final payments = {
      for (final row in snapshot()['transactions']) row['id']: row,
    };
    if (!payments.containsKey(primary) || !payments.containsKey(secondary)) {
      invalid('Payment no longer available; reload first');
    }
    final a = payments[primary], b = payments[secondary];
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
    final groups = read('merges.json', {});
    groups.remove(id);
    await write('merges.json', groups);
  }

  Future<void> saveTaxonomy(Map config) async {
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
      if (e.key == 'Uncategorized' || !remaining.contains(e.value)) {
        invalid(
          'Choose an existing destination; Uncategorized cannot be deleted',
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
      if ({'Salary', 'Other income'}.contains(newRoots[e.value]) &&
          !{'Salary', 'Other income'}.contains(old[e.key]['parent'] ?? e.key)) {
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
