import 'package:uuid/uuid.dart';
import 'casefold.dart';
import 'compat.dart';
import '../special_categories.dart';

const categoryColors = {
  'Food': '00A5AA',
  'Shopping': '388DF0',
  'Travel': 'FF8B37',
  'Transport': '6380BB',
  'Rent': 'CF769B',
  'Bills': '9870ED',
  'Health': 'D8666C',
  'Entertainment': '93A0B4',
  'Other': '93A0B4',
  'Salary': '008F84',
  'Other income': '008F84',
  'Transfer': '93A0B4',
  'Uncategorized': '93A0B4',
  'Ignored': '93A0B4',
  borrowingCategory: '9870ED',
};
Map<String, dynamic> defaultTaxonomy() => {
  'categories': orderedCategories([
    for (final e in categoryColors.entries)
      {'id': e.key, 'name': e.key, 'parent': null, 'color': e.value},
  ]),
  'tags': <dynamic>[],
};
Never invalid(String message) => throw FormatException(message);
Map<String, dynamic> validateRule(
  dynamic input,
  Set<dynamic> categories,
  Set<dynamic> tags, {
  Set<dynamic>? users,
}) {
  if (input is! Map) invalid('Rule must be an object');
  final rule = Map<String, dynamic>.from(input);
  final userId = rule['userId'];
  if (userId != null &&
      (userId is! String ||
          userId.isEmpty ||
          userId.length > 80 ||
          {'all', 'unassigned'}.contains(userId) ||
          users != null && !users.contains(userId))) {
    invalid('Choose an existing user for a personal rule');
  }
  final name = rule['name'],
      groups = rule['groups'],
      tagIds = rule['tags'] ?? [],
      special = rule['kind'] == 'category';
  if (name is! String || name.trim().isEmpty || name.length > 100) {
    invalid('Give the rule a name (up to 100 characters)');
  }
  if (tagIds is! List || tagIds.any((t) => t is! String || !tags.contains(t))) {
    invalid('Choose existing tags');
  }
  if (!categories.contains(rule['category']) &&
          !(rule['category'] == null && (tagIds).isNotEmpty) ||
      rule.containsKey('enabled') && rule['enabled'] is! bool) {
    invalid('Invalid category or enabled flag');
  }
  if (groups is! List ||
      groups.length < (special ? 0 : 1) ||
      groups.length > 2000) {
    invalid(
      'Use up to 2000 OR groups (an empty category rule matches nothing)',
    );
  }
  final clean = <dynamic>[];
  for (final group in groups) {
    if (group is! List || group.isEmpty || group.length > 12) {
      invalid('Each group needs 1 to 12 AND conditions');
    }
    final conditions = <dynamic>[];
    for (final condition in group) {
      if (condition is! Map) invalid('Invalid condition');
      final c = condition,
          field = c['field'],
          op = c['operator'],
          value = c['value'];
      if (!{'description', 'source', 'direction'}.contains(field) ||
          !{
            'contains',
            'starts_with',
            'ends_with',
            'equals',
            'not_contains',
          }.contains(op)) {
        invalid('Unknown field or operator');
      }
      if (value is! String || value.trim().isEmpty || value.length > 2000) {
        invalid('Each condition needs a value (up to 2000 characters)');
      }
      if (field == 'direction' &&
          (op != 'equals' || !{'income', 'expense'}.contains(value))) {
        invalid('Direction must equal income or expense');
      }
      conditions.add({'field': field, 'operator': op, 'value': (value).trim()});
    }
    clean.add(conditions);
  }
  final id = present(rule['id']) ? rule['id'] : const Uuid().v4();
  if (id is! String || id.length > 100) invalid('Invalid rule ID');
  final result = <String, dynamic>{
    'id': id,
    'name': (name).trim(),
    'category': rule['category'],
    'enabled': rule['enabled'] ?? true,
    'groups': clean,
    'userId': ?userId,
  };
  if ((tagIds).isNotEmpty) result['tags'] = tagIds.toSet().toList()..sort();
  if (rule['kind'] == 'extra') result['kind'] = 'extra';
  if (special) {
    if (tagIds.isNotEmpty) invalid('Use an additional rule for tags');
    result['kind'] = 'category';
  }
  return result;
}

bool ruleMatches(Map rule, Map payment, [Map<dynamic, dynamic>? roots]) {
  if (!enabled(rule)) return false;
  final category = roots?[rule['category']] ?? rule['category'];
  if (incomeCategories.contains(category) && payment['amount'] <= 0) {
    return false;
  }
  final sources = present(payment['sourceRecords'])
      ? payment['sourceRecords'] as List
      : [payment];
  for (final record in sources) {
    for (final group in rule['groups'] as List) {
      if ((group as List).every((c) {
        final field = c['field'];
        final actual = casefold(
          pythonString(
            field == 'direction'
                ? payment['amount'] > 0
                      ? 'income'
                      : 'expense'
                : field == 'source'
                ? record['institution'] ?? record['source'] ?? ''
                : record[field] ?? '',
          ),
        );
        final value = casefold(c['value'] as String);
        return switch (c['operator']) {
          'contains' => actual.contains(value),
          'not_contains' => !actual.contains(value),
          'starts_with' => actual.startsWith(value),
          'ends_with' => actual.endsWith(value),
          'equals' => actual == value,
          _ => false,
        };
      })) {
        return true;
      }
    }
  }
  return false;
}

/// Shared and personal conditions form a union. Personal category rules take
/// priority; matching tags from either enabled pool accumulate as before.
/// Ownership is independent of the dashboard's selected user. For a merged
/// payment its canonical account owns it; an unassigned canonical account uses
/// a unique linked owner, if there is one. Conflicting linked owners stay shared.
class RuleBook {
  final List<Map<String, dynamic>> ordered;
  final Map<dynamic, dynamic> roots;
  final Map owners;
  late final Map<dynamic, Map<String, dynamic>> users;
  late final List<Map<String, dynamic>> shared;
  late final Map<dynamic, List<Map<String, dynamic>>> personal;
  final Map<String?, List<Map<String, dynamic>>> _pools = {};

  RuleBook(this.ordered, Map profiles, this.roots)
    : owners = profiles['accountUsers'] as Map? ?? {} {
    users = {for (final u in maps(profiles['users'] ?? [])) u['id']: u};
    shared = ordered.where((r) => r['userId'] == null && enabled(r)).toList();
    personal = {};
    for (final r in ordered) {
      if (r['userId'] != null && enabled(r)) {
        personal.putIfAbsent(r['userId'], () => []).add(r);
      }
    }
  }

  String? owner(Map payment) {
    final primary = owners[payment['accountId']];
    if (users.containsKey(primary)) return primary as String;
    final linked = (payment['accountIds'] as List? ?? [])
        .map((id) => owners[id])
        .where(users.containsKey)
        .toSet();
    return linked.length == 1 ? linked.single as String : null;
  }

  List<Map<String, dynamic>> forPayment(Map payment) {
    final id = owner(payment);
    return _pools.putIfAbsent(
      id,
      () => [
        if (id != null && users[id]?['usePersonalRules'] != false)
          ...personal[id] ?? [],
        if (id == null || users[id]?['useSharedRules'] != false) ...shared,
      ],
    );
  }

  bool matches(Map rule, Map payment) =>
      forPayment(payment).any((r) => r['id'] == rule['id']) &&
      ruleMatches(rule, payment, roots);

  Map<String, dynamic>? categoryRule(Map payment) => forPayment(payment)
      .where((r) => present(r['category']) && ruleMatches(r, payment, roots))
      .firstOrNull;
}

Map<String, dynamic> categoryDraft(
  String category,
  String name,
  List<Map<String, dynamic>> ordered, {
  String? userId,
}) {
  final candidates = ordered
      .where(
        (r) =>
            r['userId'] == userId &&
            r['category'] == category &&
            r['kind'] != 'extra' &&
            !present(r['tags']) &&
            (enabled(r) || r['kind'] == 'category'),
      )
      .toList();
  final active = candidates.any(enabled), groups = <dynamic>[];
  final keys = <String>{};
  for (final r in candidates) {
    if (!enabled(r) && active) continue;
    for (final g in r['groups']) {
      if (keys.add(pythonJson(g, sorted: true))) groups.add(clone(g));
    }
  }
  return {
    'id': candidates.isEmpty
        ? userId == null
              ? 'category-${const Uuid().v5(Namespace.url.value, category)}'
              : 'category-user-${const Uuid().v5(Namespace.url.value, pythonJson([userId, category]))}'
        : candidates.first['id'],
    'name': name,
    'category': category,
    'kind': 'category',
    'enabled': candidates.isEmpty || active,
    'groups': groups,
    'userId': ?userId,
  };
}

List<Map<String, dynamic>> saveCategory(
  List<Map<String, dynamic>> ordered,
  Map<String, dynamic> rule,
) {
  final result = <Map<String, dynamic>>[];
  var inserted = false;
  for (final old in ordered) {
    final same =
        old['userId'] == rule['userId'] &&
        old['category'] == rule['category'] &&
        old['kind'] != 'extra' &&
        !present(old['tags']);
    if (same && (enabled(old) || old['kind'] == 'category')) {
      if (!enabled(old) && old['id'] != rule['id'] && enabled(rule)) {
        result.add({...old, 'kind': 'extra'});
        continue;
      }
      if (!inserted) {
        result.add(rule);
        inserted = true;
      }
    } else {
      result.add(old);
    }
  }
  if (!inserted) result.add(rule);
  return result;
}

List<Map<String, dynamic>> transferCategories(
  List<Map<String, dynamic>> ordered,
  Map transfers,
  Map names,
) {
  var result = maps(clone(ordered));
  for (final e in transfers.entries) {
    for (final rule in result) {
      if (rule['category'] == e.key) {
        rule['category'] = e.value;
        if (!enabled(rule)) rule['kind'] = 'extra';
      }
    }
    final pools = result
        .where((r) => r['category'] == e.value)
        .map((r) => r['userId'] as String?)
        .toSet();
    for (final userId in pools) {
      final active = result
          .where(
            (r) =>
                r['userId'] == userId &&
                r['category'] == e.value &&
                r['kind'] != 'extra' &&
                !present(r['tags']) &&
                enabled(r),
          )
          .toList();
      if (active.isNotEmpty) {
        result = saveCategory(
          result,
          categoryDraft(
            e.value as String,
            names[e.value] as String,
            active,
            userId: userId,
          ),
        );
      }
    }
  }
  return result;
}

Map<String, dynamic> validateTaxonomy(
  dynamic config,
  Set<dynamic> usedCategories,
  Set<dynamic> usedTags,
) {
  if (config is! Map ||
      config['categories'] is! List ||
      config['tags'] is! List ||
      config['categories'].length > 200 ||
      config['tags'].length > 200) {
    invalid('Use at most 200 categories and tags');
  }
  List<Map<String, dynamic>> entries(dynamic rows) {
    final ids = <dynamic>{},
        names = <String>{},
        result = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r is! Map) invalid('Invalid settings');
      final id = r['id'], name = r['name'];
      if (id is! String ||
          id.isEmpty ||
          id.length > 100 ||
          id == 'all' ||
          !ids.add(id)) {
        invalid('Invalid or duplicate ID');
      }
      if (name is! String ||
          name.trim().isEmpty ||
          name.trim().length > 60 ||
          !names.add(casefold(name.trim()))) {
        invalid('Names must be unique and non-empty (up to 60 characters)');
      }
      result.add({...Map<String, dynamic>.from(r), 'name': name.trim()});
    }
    return result;
  }

  final categories = entries(config['categories']),
      tags = entries(config['tags']);
  final ids = categories.map((c) => c['id']).toSet(),
      tagIds = tags.map((t) => t['id']).toSet();
  if (!ids.containsAll(specialCategoryOrder) ||
      !ids.containsAll(usedCategories) ||
      !tagIds.containsAll(usedTags)) {
    invalid(
      'Keep special categories; transfer categories in use before deleting; used tags cannot be deleted',
    );
  }
  final byId = {for (final c in categories) c['id']: c};
  for (final c in categories) {
    final parent = c['parent'];
    if (c['id'] == 'Uncategorized' &&
        (c['name'] != 'Uncategorized' ||
            parent != null ||
            c['color'] != '93A0B4')) {
      invalid('Uncategorized cannot be changed');
    }
    if (parent == 'Uncategorized') {
      invalid('Uncategorized cannot have subcategories');
    }
    if (c['color'] is! String ||
        !RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(c['color'])) {
      invalid('Invalid category color');
    }
    if (categoryColors.containsKey(c['id']) && present(parent)) {
      invalid('Built-in categories remain main categories');
    }
    if (present(parent) &&
        (!ids.contains(parent) ||
            parent == c['id'] ||
            present(byId[parent]!['parent']))) {
      invalid('Choose a main category as parent');
    }
  }
  return {
    'categories': [
      for (final c in categories)
        {
          'id': c['id'],
          'name': c['name'],
          'parent': c['parent'],
          'color': (c['color'] as String).toUpperCase(),
        },
    ],
    'tags': [
      for (final t in tags) {'id': t['id'], 'name': t['name']},
    ],
  };
}

Map<String, dynamic> validateProfiles(Map body, Set<dynamic> accounts) {
  final users = body['users'], owners = body['accountUsers'];
  if (users is! List || users.length > 50 || owners is! Map) {
    invalid('Invalid users');
  }
  final clean = <dynamic>[], ids = <dynamic>{}, names = <String>{};
  for (final u in users) {
    final id = u['id'], name = u['name'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 80 ||
        {'all', 'unassigned'}.contains(id) ||
        !ids.add(id)) {
      invalid('Invalid user ID');
    }
    if (name is! String ||
        name.trim().isEmpty ||
        name.trim().length > 60 ||
        !names.add(casefold(name.trim()))) {
      invalid('Use unique, non-empty user names (up to 60 characters)');
    }
    for (final field in ['useSharedRules', 'usePersonalRules']) {
      if (u.containsKey(field) && u[field] is! bool) {
        invalid('Invalid rule-pool setting');
      }
    }
    clean.add({
      'id': id,
      'name': name.trim(),
      for (final field in ['useSharedRules', 'usePersonalRules'])
        if (u.containsKey(field)) field: u[field],
    });
  }
  if ((owners).entries.any(
    (e) => !accounts.contains(e.key) || !ids.contains(e.value),
  )) {
    invalid('Invalid account assignment');
  }
  final result = <String, dynamic>{'users': clean, 'accountUsers': owners};
  if (body.containsKey('accountNicknames')) {
    final nicknames = body['accountNicknames'];
    if (nicknames is! Map) invalid('Invalid account nicknames');
    final trimmed = <String, dynamic>{};
    for (final e in (nicknames).entries) {
      if (!accounts.contains(e.key) ||
          e.value is! String ||
          e.value.trim().length > 60) {
        invalid(
          'Use account nicknames up to 60 characters for existing accounts',
        );
      }
      if (e.value.trim().isNotEmpty) trimmed[e.key] = e.value.trim();
    }
    result['accountNicknames'] = trimmed;
  }
  return result;
}
