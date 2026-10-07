import 'dart:convert';
import 'package:flutter/material.dart';
import 'ledger.dart';
import 'category_picker.dart';

/// Copy the rule so cancelling the editor never changes the saved rule.
Map<String, dynamic> ruleWithTransactionTerm(
  Map<String, dynamic> rule,
  String description,
) {
  final draft = jsonDecode(jsonEncode(rule)) as Map<String, dynamic>;
  final groups = draft['groups'] as List;
  if (groups.length >= 2000) {
    throw StateError('This rule already has 2000 OR groups.');
  }
  groups.add([
    {'field': 'description', 'operator': 'contains', 'value': description},
  ]);
  return draft;
}

Map<String, dynamic> categoryRuleDraft(Ledger ledger, String category) {
  final candidates = ledger.rules
      .where(
        (r) =>
            r['category'] == category &&
            r['kind'] != 'extra' &&
            ((r['tags'] as List?)?.isEmpty ?? true) &&
            (r['enabled'] != false || r['kind'] == 'category'),
      )
      .toList();
  final active = candidates.where((r) => r['enabled'] != false).toList();
  final chosen = active.isNotEmpty ? active : candidates;
  final groups = <dynamic>[];
  for (final rule in chosen) {
    for (final group in rule['groups'] as List) {
      if (!groups.any((g) => jsonEncode(g) == jsonEncode(group))) {
        groups.add(group);
      }
    }
  }
  return {
    if (candidates.isNotEmpty) 'id': chosen.first['id'],
    'kind': 'category',
    'name': ledger.categoryName(category),
    'category': category,
    'enabled': chosen.isEmpty || chosen.any((r) => r['enabled'] != false),
    'groups': jsonDecode(jsonEncode(groups)),
  };
}

class RulesPage extends StatefulWidget {
  final Ledger ledger;
  const RulesPage({super.key, required this.ledger});
  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  bool busy = false;
  String? error;
  Future<void> change(String action, Map<String, dynamic> body) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.ledger.updateRule(action, body);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void edit([Map<String, dynamic>? rule]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RuleEditor(ledger: widget.ledger, rule: rule),
      ),
    );
  }

  Widget priorityMenu(Map<String, dynamic> rule, {bool removable = false}) {
    final ordered = widget.ledger.rules;
    final index = ordered.indexWhere((r) => r['id'] == rule['id']);
    return PopupMenuButton<String>(
      tooltip: 'Rule actions',
      enabled: !busy && index >= 0,
      onSelected: (action) async {
        if (action == 'up' || action == 'down') {
          await change('move', {
            'id': rule['id'],
            'delta': action == 'up' ? -1 : 1,
          });
        } else if (action == 'delete') {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Delete rule?'),
              content: const Text(
                'Transactions will be reclassified. Manual categories stay unchanged.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (confirmed == true) await change('delete', {'id': rule['id']});
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'up',
          enabled: index > 0,
          child: const Text('Move rule up'),
        ),
        PopupMenuItem(
          value: 'down',
          enabled: index < ordered.length - 1,
          child: const Text('Move rule down'),
        ),
        if (removable)
          const PopupMenuItem(value: 'delete', child: Text('Delete rule')),
      ],
    );
  }

  Widget categoryRow(Map<String, dynamic> category, {bool child = false}) {
    final l = widget.ledger;
    final draft = categoryRuleDraft(l, category['id']);
    final count = (draft['groups'] as List).length;
    final index = l.rules.indexWhere((r) => r['id'] == draft['id']);
    final hex = category['color'] as String?;
    final color = hex == null
        ? categoryColor(category['id'])
        : Color(0xff000000 | int.parse(hex, radix: 16));
    return Padding(
      padding: EdgeInsets.only(left: child ? 22 : 0),
      child: ListTile(
        key: ValueKey('category-rule-${category['id']}'),
        dense: true,
        contentPadding: const EdgeInsets.only(left: 10),
        leading: Icon(
          child ? Icons.subdirectory_arrow_right : Icons.circle,
          color: color,
          size: 18,
        ),
        title: Text(
          category['name'],
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          count == 0
              ? 'No conditions yet'
              : '$count OR groups${draft['enabled'] == false ? ' · Paused' : ''}${index >= 0 ? ' · Priority ${index + 1}' : ''}',
        ),
        onTap: busy ? null : () => edit(draft),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (index >= 0) priorityMenu(draft),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.ledger;
    final extras = l.rules
        .where(
          (r) =>
              r['kind'] == 'extra' ||
              ((r['tags'] as List?)?.isNotEmpty ?? false) ||
              (r['enabled'] == false && r['kind'] != 'category'),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Classification rules',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
            ),
            TextButton.icon(
              onPressed: busy ? null : () => edit(),
              icon: const Icon(Icons.add),
              label: const Text('New rule'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Choose a category to edit its conditions. Any OR group can match; conditions within a group are joined by AND.',
        ),
        const SizedBox(height: 8),
        const Text(
          'Lower priority numbers win category conflicts. Manual categories take precedence. Matching tag rules always add their tags.',
        ),
        const SizedBox(height: 16),
        for (final parent in l.categorySettings.where(
          (c) => c['parent'] == null,
        ))
          Card(
            margin: const EdgeInsets.only(bottom: 4),
            elevation: 0,
            child: Column(
              children: [
                categoryRow(parent),
                for (final child in l.categorySettings.where(
                  (c) => c['parent'] == parent['id'],
                ))
                  categoryRow(child, child: true),
              ],
            ),
          ),
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Other rules',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const Text(
          'Use named rules for exceptions, tags, or combined actions.',
        ),
        for (final rule in extras)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              rule['name'],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${rule['category'] == null ? 'Keep category' : l.categoryLabel(rule['category'])}${(rule['tags'] as List? ?? []).isEmpty ? '' : ' · Tags: ${(rule['tags'] as List).map((id) => l.tagName(id)).join(', ')}'} · ${(rule['groups'] as List).length} OR groups · Priority ${l.rules.indexOf(rule) + 1}',
            ),
            onTap: () => edit({...rule, 'kind': 'extra'}),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: rule['enabled'] != false,
                  onChanged: busy
                      ? null
                      : (value) => change('save', {
                          'rule': {...rule, 'kind': 'extra', 'enabled': value},
                        }),
                ),
                priorityMenu(rule, removable: true),
              ],
            ),
          ),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
      ],
    );
  }
}

const operatorLabels = {
  'contains': 'includes',
  'starts_with': 'starts with',
  'ends_with': 'ends with',
  'equals': 'equals',
  'not_contains': 'does not include',
};

class RuleEditor extends StatefulWidget {
  final Ledger ledger;
  final Map<String, dynamic>? rule;
  const RuleEditor({super.key, required this.ledger, this.rule});
  @override
  State<RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<RuleEditor> {
  late Map<String, dynamic> draft;
  bool busy = false;
  String? error;
  List<dynamic>? preview;
  bool showValidation = false;
  final _textValues = Expando<String>();
  int revision = 0;
  bool get categoryRule => draft['kind'] == 'category';
  List<dynamic> get groups => draft['groups'] as List;
  Map<String, dynamic> condition() => {
    'field': 'description',
    'operator': 'contains',
    'value': '',
  };
  @override
  void initState() {
    super.initState();
    draft = widget.rule == null
        ? {
            'name': '',
            'kind': 'extra',
            'category': widget.ledger.categoryIds.contains('Food')
                ? 'Food'
                : 'Uncategorized',
            'enabled': true,
            'groups': [
              [condition()],
            ],
          }
        : jsonDecode(jsonEncode(widget.rule));
  }

  void update(VoidCallback f) => setState(() {
    f();
    preview = null;
    error = null;
  });
  String? validate() {
    if (draft['category'] == null &&
        ((draft['tags'] as List?)?.isEmpty ?? true)) {
      return 'Choose a category or at least one tag.';
    }
    if ((draft['name'] as String).trim().isEmpty) {
      return 'Give this rule a name.';
    }
    for (var gi = 0; gi < groups.length; gi++) {
      final group = groups[gi] as List;
      for (var ci = 0; ci < group.length; ci++) {
        if ((group[ci]['value'] as String).trim().isEmpty) {
          return 'Group ${gi + 1}, condition ${ci + 1}: enter match text or remove this condition.';
        }
      }
    }
    return null;
  }

  Future<void> run(bool save) async {
    final validation = validate();
    if (validation != null) {
      setState(() {
        error = validation;
        showValidation = true;
      });
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (save) {
        await widget.ledger.updateRule('save', {'rule': draft});
        if (mounted) Navigator.pop(context);
      } else {
        final result = await widget.ledger.post('/api/rules/preview', {
          'rule': draft,
        });
        if (mounted) setState(() => preview = result['matches'] as List);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget select(
    String value,
    Map<String, String> options,
    void Function(String) change,
  ) => DropdownButtonFormField<String>(
    initialValue: value,
    isExpanded: true,
    decoration: const InputDecoration(
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    ),
    items: options.entries
        .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
        .toList(),
    onChanged: busy
        ? null
        : (v) {
            if (v != null) change(v);
          },
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        categoryRule
            ? widget.ledger.categoryLabel(draft['category'])
            : widget.rule?['id'] == null
            ? 'New rule'
            : 'Edit rule',
      ),
    ),
    body: SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!categoryRule) ...[
                  TextFormField(
                    initialValue: draft['name'],
                    enabled: !busy,
                    maxLength: 100,
                    decoration: const InputDecoration(
                      labelText: 'Rule name',
                      counterText: '',
                      isDense: true,
                    ),
                    onChanged: (v) => update(() => draft['name'] = v),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(
                        key: const ValueKey('rule-category-selector'),
                        avatar: const Icon(Icons.category_outlined, size: 18),
                        label: Text(
                          draft['category'] == null
                              ? 'Keep category'
                              : widget.ledger.categoryLabel(draft['category']),
                        ),
                        onPressed: busy
                            ? null
                            : () => showDialog<void>(
                                context: context,
                                builder: (dialog) => AlertDialog(
                                  title: const Text('Assign category'),
                                  content: SizedBox(
                                    width: 550,
                                    child: SingleChildScrollView(
                                      child: CategoryPicker(
                                        ledger: widget.ledger,
                                        selected: draft['category'] ?? '',
                                        onSelected: (id) {
                                          update(() => draft['category'] = id);
                                          Navigator.pop(dialog);
                                        },
                                      ),
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () {
                                        update(() => draft['category'] = null);
                                        Navigator.pop(dialog);
                                      },
                                      child: const Text(
                                        'Keep category unchanged',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                      for (final tag in widget.ledger.tagSettings)
                        FilterChip(
                          label: Text(tag['name']),
                          selected: (draft['tags'] as List? ?? []).contains(
                            tag['id'],
                          ),
                          onSelected: busy
                              ? null
                              : (value) => update(() {
                                  final tags = List<String>.from(
                                    draft['tags'] ?? [],
                                  );
                                  value
                                      ? tags.add(tag['id'])
                                      : tags.remove(tag['id']);
                                  draft['tags'] = tags;
                                }),
                        ),
                    ],
                  ),
                ] else
                  Text(
                    'Assigns transactions to ${widget.ledger.categoryLabel(draft['category'])}. Saving combines its active rules at their earliest priority. Use Preview to check overlaps.',
                  ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enabled'),
                  value: draft['enabled'],
                  onChanged: busy
                      ? null
                      : (v) => update(() => draft['enabled'] = v),
                ),
                const Text(
                  'Match any group. Within a group, all conditions must match one linked source. Text ignores case.',
                ),
                const SizedBox(height: 12),
                for (var gi = 0; gi < groups.length; gi++) ...[
                  if (gi > 0)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        'OR',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  Card(
                    key: ValueKey('group-$revision-$gi'),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Group ${gi + 1}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              TextButton.icon(
                                onPressed:
                                    busy || (groups[gi] as List).length >= 12
                                    ? null
                                    : () => update(
                                        () => (groups[gi] as List).add(
                                          condition(),
                                        ),
                                      ),
                                icon: const Icon(Icons.add),
                                label: const Text('AND condition'),
                              ),
                              IconButton(
                                tooltip: 'Remove group',
                                onPressed:
                                    busy ||
                                        (!categoryRule && groups.length == 1)
                                    ? null
                                    : () => update(() {
                                        groups.removeAt(gi);
                                        revision++;
                                      }),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                          for (
                            var ci = 0;
                            ci < (groups[gi] as List).length;
                            ci++
                          ) ...[
                            if (ci > 0)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text('AND'),
                              ),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final c =
                                    groups[gi][ci] as Map<String, dynamic>;
                                final fields = [
                                  select(
                                    c['field'],
                                    const {
                                      'description': 'Description',
                                      'source': 'Source',
                                      'direction': 'Direction',
                                    },
                                    (v) => update(() {
                                      if (c['field'] == v) return;
                                      if (c['field'] != 'direction') {
                                        _textValues[c] = c['value'] as String;
                                      }
                                      final wasDirection =
                                          c['field'] == 'direction';
                                      c['field'] = v;
                                      c['operator'] = v == 'direction'
                                          ? 'equals'
                                          : 'contains';
                                      c['value'] = v == 'direction'
                                          ? 'expense'
                                          : wasDirection
                                          ? (_textValues[c] ?? '')
                                          : c['value'];
                                      revision++;
                                    }),
                                  ),
                                  select(
                                    c['operator'],
                                    c['field'] == 'direction'
                                        ? const {'equals': 'equals'}
                                        : operatorLabels,
                                    (v) => update(() => c['operator'] = v),
                                  ),
                                  if (c['field'] == 'direction')
                                    select(c['value'], const {
                                      'expense': 'Expense',
                                      'income': 'Income',
                                    }, (v) => update(() => c['value'] = v))
                                  else
                                    TextFormField(
                                      initialValue: c['value'],
                                      enabled: !busy,
                                      maxLength: 2000,
                                      decoration: InputDecoration(
                                        labelText: 'Match text',
                                        isDense: true,
                                        counterText: '',
                                        errorText:
                                            showValidation &&
                                                (c['value'] as String)
                                                    .trim()
                                                    .isEmpty
                                            ? 'Enter text to match'
                                            : null,
                                      ),
                                      onChanged: (v) =>
                                          update(() => c['value'] = v),
                                    ),
                                ];
                                final remove = IconButton(
                                  tooltip: 'Remove condition',
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed:
                                      busy || (groups[gi] as List).length == 1
                                      ? null
                                      : () => update(() {
                                          (groups[gi] as List).removeAt(ci);
                                          revision++;
                                        }),
                                );
                                if (constraints.maxWidth > 600) {
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: Row(
                                      children: [
                                        SizedBox(width: 130, child: fields[0]),
                                        const SizedBox(width: 6),
                                        SizedBox(width: 155, child: fields[1]),
                                        const SizedBox(width: 6),
                                        Expanded(child: fields[2]),
                                        remove,
                                      ],
                                    ),
                                  );
                                }
                                return Column(
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(child: fields[0]),
                                        const SizedBox(width: 6),
                                        Expanded(child: fields[1]),
                                        remove,
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    fields[2],
                                  ],
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
                TextButton.icon(
                  onPressed: busy || groups.length >= 2000
                      ? null
                      : () => update(() => groups.add([condition()])),
                  icon: const Icon(Icons.add),
                  label: const Text('OR group'),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Manual categories are preserved. Salary rules apply only to income.',
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: busy ? null : () => run(false),
                      child: const Text('Preview matches'),
                    ),
                    FilledButton(
                      onPressed: busy ? null : () => run(true),
                      child: Text(busy ? 'Working…' : 'Save rule'),
                    ),
                  ],
                ),
                if (preview != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    '${preview!.length} matches · ${preview!.where((p) => p['blockedBy'] == null).length} eligible for this rule',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (draft['enabled'] == false)
                    const Text(
                      'Preview shows potential matches. This rule is disabled and will not change categories until enabled.',
                    ),
                  for (final p in preview!.take(100))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(p['description']),
                      subtitle: Text(
                        '${p['date']} · ${p['blockedBy'] ?? '${widget.ledger.categoryLabel(p['category'])} → ${(draft['category'] == null ? 'Add tags' : widget.ledger.categoryLabel(draft['category']))}'}',
                      ),
                      trailing: Text(money(p['amount'])),
                    ),
                  if (preview!.length > 100)
                    const Text('Showing the first 100 matches.'),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
