import 'dart:convert';
import 'package:flutter/material.dart';
import 'ledger.dart';

class TaxonomySettings extends StatefulWidget {
  final Ledger ledger;
  const TaxonomySettings({super.key, required this.ledger});
  @override
  State<TaxonomySettings> createState() => _TaxonomySettingsState();
}

class _TaxonomySettingsState extends State<TaxonomySettings> {
  late List<Map<String, dynamic>> cats, tags;
  bool dirty = false, busy = false;
  String? message;
  int revision = 0;
  final Map<String, String> transfers = {};
  @override
  void initState() {
    super.initState();
    cats = (jsonDecode(jsonEncode(widget.ledger.categorySettings)) as List)
        .cast<Map<String, dynamic>>();
    for (final c in cats) {
      c['color'] ??= '93A0B4';
    }
    tags = (jsonDecode(jsonEncode(widget.ledger.tagSettings)) as List)
        .cast<Map<String, dynamic>>();
  }

  void edit(VoidCallback action) => setState(() {
    action();
    dirty = true;
    message = null;
  });
  Future<void> save() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await widget.ledger.saveTaxonomy({
        'categories': cats,
        'tags': tags,
        'categoryTransfers': transfers,
      });
      if (mounted) {
        setState(() {
          dirty = false;
          transfers.clear();
          message = 'Categories and tags saved.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Color color(Map<String, dynamic> c) =>
      Color(0xff000000 | int.parse(c['color'], radix: 16));

  void addChild(Map<String, dynamic> parent) => edit(
    () => cats.add({
      'id': 'category-${DateTime.now().microsecondsSinceEpoch}',
      'name': '',
      'parent': parent['id'],
      'color': parent['color'],
    }),
  );

  Future<void> deleteCategory(Map<String, dynamic> c) async {
    String? destination;
    final income = {'Salary', 'Other income'};
    final sourceIncome = income.contains(c['parent'] ?? c['id']);
    final targets = cats
        .where(
          (p) =>
              p['id'] != c['id'] &&
              (sourceIncome || !income.contains(p['parent'] ?? p['id'])),
        )
        .toList();
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            'Delete ${c['name'].toString().isEmpty ? 'category' : c['name']}?',
          ),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Move its transactions and rule assignments to another category. This takes effect when you save and can be undone.',
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Move to category',
                  ),
                  items: targets
                      .map(
                        (p) => DropdownMenuItem<String>(
                          value: p['id'],
                          child: Row(
                            children: [
                              Icon(Icons.circle, color: color(p), size: 12),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  p['parent'] == null
                                      ? '${p['name']}'
                                      : '${cats.firstWhere((v) => v['id'] == p['parent'])['name']} / ${p['name']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => update(() => destination = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: destination == null
                  ? null
                  : () => Navigator.pop(context, destination),
              child: const Text('Move and delete'),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    edit(() {
      // Collapse chains when a previously selected destination is deleted too.
      transfers.updateAll((key, value) => value == c['id'] ? chosen : value);
      if (widget.ledger.categorySettings.any((p) => p['id'] == c['id'])) {
        transfers[c['id']] = chosen;
      }
      cats.remove(c);
      revision++;
    });
  }

  Widget _categoryEditor(Map<String, dynamic> c) {
    final locked = c['id'] == 'Uncategorized';
    final hasChildren = cats.any((p) => p['parent'] == c['id']);
    return Padding(
      key: ValueKey(c['id']),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            if (locked)
              const SizedBox(
                width: 40,
                child: Icon(Icons.lock_outline, size: 18),
              )
            else
              PopupMenuButton<String>(
                tooltip: 'Change category color',
                enabled: !busy,
                icon: Icon(Icons.circle, color: color(c), size: 20),
                onSelected: (hex) => edit(() => c['color'] = hex),
                itemBuilder: (_) => [
                  for (final hex in [
                    '00A5AA',
                    '388DF0',
                    'FF8B37',
                    '9870ED',
                    '6380BB',
                    'CF769B',
                    'D8666C',
                    '008F84',
                    '93A0B4',
                  ])
                    PopupMenuItem(
                      value: hex,
                      height: 36,
                      child: Row(
                        children: [
                          Icon(
                            Icons.circle,
                            color: Color(
                              0xff000000 | int.parse(hex, radix: 16),
                            ),
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            {
                              '00A5AA': 'Turquoise',
                              '388DF0': 'Blue',
                              'FF8B37': 'Orange',
                              '9870ED': 'Purple',
                              '6380BB': 'Slate blue',
                              'CF769B': 'Pink',
                              'D8666C': 'Red',
                              '008F84': 'Teal',
                              '93A0B4': 'Gray',
                            }[hex]!,
                          ),
                          if (hex == c['color'])
                            const Padding(
                              padding: EdgeInsets.only(left: 12),
                              child: Icon(Icons.check, size: 16),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            Expanded(
              child: locked
                  ? const Text('Uncategorized')
                  : TextFormField(
                      initialValue: c['name'],
                      enabled: !busy,
                      maxLength: 60,
                      decoration: InputDecoration(
                        labelText: c['parent'] == null
                            ? 'Category name'
                            : 'Subcategory name',
                        counterText: '',
                        floatingLabelBehavior: FloatingLabelBehavior.never,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 12,
                        ),
                      ),
                      onChanged: (value) => edit(() => c['name'] = value),
                    ),
            ),
            if (!locked && c['parent'] == null)
              IconButton(
                key: ValueKey('add-subcategory-${c['id']}'),
                tooltip: 'Add subcategory',
                onPressed: busy ? null : () => addChild(c),
                icon: const Icon(Icons.add, size: 20),
              ),
            if (!locked && !categories.contains(c['id']))
              PopupMenuButton<String>(
                tooltip: 'Change parent category',
                enabled: !busy && !hasChildren,
                icon: const Icon(Icons.drive_file_move_outline, size: 20),
                onSelected: (value) => edit(() {
                  c['parent'] = value == 'main' ? null : value;
                  revision++;
                }),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'main',
                    child: Text('Main category'),
                  ),
                  for (final p in cats.where(
                    (p) =>
                        p['parent'] == null &&
                        p['id'] != c['id'] &&
                        p['id'] != 'Uncategorized',
                  ))
                    PopupMenuItem<String>(
                      value: p['id'],
                      child: Text(p['name']),
                    ),
                ],
              ),
            if (!locked)
              IconButton(
                tooltip: hasChildren
                    ? 'Remove subcategories before deleting'
                    : 'Delete category',
                onPressed: busy || hasChildren ? null : () => deleteCategory(c),
                icon: const Icon(Icons.delete_outline, size: 20),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Categories and tags',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text(
        'Edit names directly; click a color to change it. Use + to add a subcategory. Delete categories without subcategories and choose where their transactions go. Uncategorized stays fixed.',
      ),
      ExpansionTile(
        title: const Text('Manage categories and subcategories'),
        children: [
          for (final parent in cats.where((c) => c['parent'] == null))
            Card(
              key: ValueKey('group-${parent['id']}'),
              margin: const EdgeInsets.symmetric(vertical: 2),
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _categoryEditor(parent),
                    for (final child in cats.where(
                      (c) => c['parent'] == parent['id'],
                    ))
                      Padding(
                        padding: const EdgeInsets.only(left: 20),
                        child: _categoryEditor(child),
                      ),
                  ],
                ),
              ),
            ),
          TextButton.icon(
            onPressed: busy
                ? null
                : () => edit(
                    () => cats.add({
                      'id': 'category-${DateTime.now().microsecondsSinceEpoch}',
                      'name': '',
                      'parent': null,
                      'color': '00A5AA',
                    }),
                  ),
            icon: const Icon(Icons.add),
            label: const Text('Add main category'),
          ),
        ],
      ),
      ExpansionTile(
        title: const Text('Manage tags'),
        children: [
          for (final t in tags)
            Padding(
              key: ValueKey(t['id']),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: t['name'],
                      enabled: !busy,
                      maxLength: 60,
                      decoration: const InputDecoration(
                        labelText: 'Tag name',
                        counterText: '',
                      ),
                      onChanged: (value) => edit(() => t['name'] = value),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Delete tag',
                    onPressed: busy ? null : () => edit(() => tags.remove(t)),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
          TextButton.icon(
            onPressed: busy
                ? null
                : () => edit(
                    () => tags.add({
                      'id': 'tag-${DateTime.now().microsecondsSinceEpoch}',
                      'name': '',
                    }),
                  ),
            icon: const Icon(Icons.add),
            label: const Text('Add tag'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: busy || !dirty ? null : save,
        child: Text(busy ? 'Saving…' : 'Save categories and tags'),
      ),
      if (message != null)
        Padding(padding: const EdgeInsets.only(top: 12), child: Text(message!)),
    ],
  );
}
