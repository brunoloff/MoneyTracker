import 'package:flutter/material.dart';
import 'ledger.dart';

Color categoryColor(String c) => switch (c) {
  'Food' => const Color(0xff00a5aa),
  'Shopping' => const Color(0xff388df0),
  'Travel' => const Color(0xffff8b37),
  'Bills' => const Color(0xff9870ed),
  'Transport' => const Color(0xff6380bb),
  'Rent' => const Color(0xffcf769b),
  'Health' => const Color(0xffd8666c),
  'Salary' || 'Other income' => const Color(0xff008f84),
  _ => const Color(0xff93a0b4),
};

/// Shared category selection for payments and classification rules.
class CategoryPicker extends StatelessWidget {
  final Ledger ledger;
  final String selected;
  final bool enabled, allowIncome;
  final ValueChanged<String> onSelected;
  final bool Function(String)? isSelectable;
  const CategoryPicker({
    super.key,
    required this.ledger,
    required this.selected,
    required this.onSelected,
    this.isSelectable,
    this.enabled = true,
    this.allowIncome = true,
  });

  Widget chip(String id) {
    final config = ledger.categorySettings.firstWhere((c) => c['id'] == id);
    final hex = config['color'] as String?;
    final color = hex == null
        ? categoryColor(ledger.mainCategory(id))
        : Color(0xff000000 | int.parse(hex, radix: 16));
    return ActionChip(
      key: ValueKey('choose-category-$id'),
      avatar: id == selected ? Icon(Icons.check, size: 18, color: color) : null,
      label: Text(
        ledger.categoryLabel(id),
        style: TextStyle(fontSize: 16, color: color),
      ),
      backgroundColor: color.withValues(alpha: .12),
      onPressed: enabled && (isSelectable?.call(id) ?? true)
          ? () => onSelected(id)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 12,
    children: [
      for (final parent in ledger.categoryIds.where(
        (id) =>
            ledger.mainCategory(id) == id &&
            (allowIncome || !['Salary', 'Other income'].contains(id)),
      ))
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            chip(parent),
            for (final child in ledger.categoryIds.where(
              (id) => id != parent && ledger.mainCategory(id) == parent,
            ))
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 6),
                child: chip(child),
              ),
          ],
        ),
    ],
  );
}
