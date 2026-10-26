/// Stable identities shared by persistence, accounting, rules and selectors.
const borrowingCategory = 'Borrowing and Deposits';
const specialCategoryOrder = [
  'Uncategorized',
  'Salary',
  'Ignored',
  borrowingCategory,
  'Transfer',
  'Other income',
];
const incomeCategories = {'Salary', 'Other income'};
const excludedCategories = {'Ignored', borrowingCategory, 'Transfer'};

bool isSpecialCategory(String id) => specialCategoryOrder.contains(id);

/// Keep ordinary categories in their saved order, with children by their parent.
List<Map<String, dynamic>> orderedCategories(List<Map<String, dynamic>> rows) {
  final roots = [
    for (final id in specialCategoryOrder) ...rows.where((c) => c['id'] == id),
    ...rows.where((c) => c['parent'] == null && !isSpecialCategory(c['id'])),
  ];
  return [
    for (final root in roots) ...[
      root,
      ...rows.where((c) => c['parent'] == root['id']),
    ],
  ];
}
