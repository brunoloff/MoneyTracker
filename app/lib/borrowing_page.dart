import 'package:flutter/material.dart';
import 'category_picker.dart';
import 'ledger.dart';

/// All dates are available here so repayments can settle older advances.
class BorrowingPage extends StatefulWidget {
  final Ledger ledger;
  final String? initialPaymentId;
  const BorrowingPage({super.key, required this.ledger, this.initialPaymentId});
  @override
  State<BorrowingPage> createState() => _BorrowingPageState();
}

class _BorrowingPageState extends State<BorrowingPage> {
  final selected = <String>{};
  final name = TextEditingController();
  String query = '';
  String? account, error;
  bool busy = false;
  Ledger get l => widget.ledger;
  @override
  void initState() {
    super.initState();
    if (widget.initialPaymentId != null) selected.add(widget.initialPaymentId!);
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: l,
    builder: (context, _) {
      final candidates =
          l.payments
              .where((p) => l.includesPayment(p) && l.canGroupBorrowing(p))
              .toList()
            ..sort((a, b) => b.date.compareTo(a.date));
      selected.retainAll(candidates.map((p) => p.id));
      final chosen = candidates.where((p) => selected.contains(p.id)).toList();
      final accountIds = chosen.map((p) => p.accountId).toSet();
      if (!accountIds.contains(account)) account = accountIds.firstOrNull;
      final balance = chosen.fold<int>(0, (sum, p) => sum + p.amount);
      final groups = l.borrowingGroups
          .where(
            (g) =>
                l.includesPayment(g.leftover) ||
                g.members.any(l.includesPayment),
          )
          .toList()
          .reversed;
      return Scaffold(
        appBar: AppBar(title: const Text(borrowingCategory)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  'Group advances, deposits and repayments. Their signed sum becomes a new leftover payment. You can classify it as spending or income, or keep it here for a later repayment.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Payments below cover all dates for the selected person and account. Only booked payments in Borrowing and Deposits can be grouped.',
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: name,
                  enabled: !busy,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: 'Group name',
                    hintText: 'For example: business trip to Paris',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Find payments',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) =>
                      setState(() => query = value.toLowerCase()),
                ),
                const SizedBox(height: 12),
                if (candidates.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'No available payments. Choose Borrowing and Deposits in a payment’s category selector first.',
                    ),
                  ),
                for (final p in candidates.where(
                  (p) => '${p.description} ${p.date} ${money(p.amount)}'
                      .toLowerCase()
                      .contains(query),
                ))
                  CheckboxListTile(
                    key: ValueKey('borrow-select-${p.id}'),
                    value: selected.contains(p.id),
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            if (value == true) {
                              selected.add(p.id);
                            } else {
                              selected.remove(p.id);
                            }
                          }),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '${p.description} · ${money(p.amount, signed: true)}',
                    ),
                    subtitle: Text(
                      '${shortDate(p.date)} · ${l.accountLabel(p.accountId)}${p.settlementGroupId != null ? ' · Leftover' : ''}',
                    ),
                  ),
                const Divider(height: 28),
                Text(
                  '${chosen.length} selected · Leftover ${money(balance, signed: true)}',
                  key: const ValueKey('borrowing-balance'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (chosen.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Dated ${shortDate(chosen.first.date)} (the latest selected payment). Starts in Borrowing and Deposits and stays outside spending and income totals.',
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('leftover-account-$account'),
                    initialValue: account,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Account for the leftover',
                    ),
                    items: [
                      for (final id in accountIds)
                        DropdownMenuItem(
                          value: id,
                          child: Text(l.accountLabel(id)),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (id) => setState(() => account = id),
                  ),
                  if (accountIds.length > 1)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'The leftover belongs to this one account in account and person views. All selected accounts must belong to the same person.',
                      ),
                    ),
                ],
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('create-borrowing-group'),
                  icon: const Icon(Icons.join_inner),
                  label: Text(busy ? 'Saving…' : 'Create group and leftover'),
                  onPressed:
                      busy || chosen.length < 2 || name.text.trim().isEmpty
                      ? null
                      : () async {
                          setState(() {
                            busy = true;
                            error = null;
                          });
                          final success = await l
                              .reconcile('/api/borrowing/create', {
                                'memberIds': chosen.map((p) => p.id).toList(),
                                'description': name.text.trim(),
                                'accountId': account,
                              });
                          if (!mounted) return;
                          setState(() {
                            busy = false;
                            if (success) {
                              selected.clear();
                              name.clear();
                            } else {
                              error = l.error;
                            }
                          });
                          if (success && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Group created. Its leftover is available as a payment.',
                                ),
                              ),
                            );
                          }
                        },
                ),
                const SizedBox(height: 32),
                Text(
                  'Existing groups',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (groups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('No groups yet.'),
                  ),
                for (final g in groups)
                  ListTile(
                    key: ValueKey('borrowing-group-${g.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.account_tree_outlined),
                    title: Text(g.description),
                    subtitle: Text(
                      '${g.members.length} payments · Leftover ${money(g.leftover.amount, signed: true)}${g.usedBy == null ? '' : ' · Used in another group'}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showBorrowingGroup(context, l, g.id),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<void> showBorrowingGroup(
  BuildContext context,
  Ledger ledger,
  String id,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => _GroupDetails(ledger: ledger, id: id),
  ),
);

class _GroupDetails extends StatefulWidget {
  final Ledger ledger;
  final String id;
  const _GroupDetails({required this.ledger, required this.id});
  @override
  State<_GroupDetails> createState() => _GroupDetailsState();
}

class _GroupDetailsState extends State<_GroupDetails> {
  bool busy = false;
  String? error;
  Ledger get l => widget.ledger;
  Future<void> classify(Payment p) async {
    var selected = p.category;
    final category = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Leftover category'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 600,
              child: CategoryPicker(
                ledger: l,
                selected: selected,
                allowIncome: p.amount > 0,
                onSelected: (id) => update(() => selected = id),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, selected),
              child: const Text('Save category'),
            ),
          ],
        ),
      ),
    );
    if (category == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    final ok = await l.categorize(p, category);
    if (mounted) {
      setState(() {
        busy = false;
        error = ok ? null : l.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: l,
    builder: (context, _) {
      final group = l.borrowingGroups
          .where((g) => g.id == widget.id)
          .firstOrNull;
      return Scaffold(
        appBar: AppBar(title: const Text('Borrowing group')),
        body: group == null
            ? const Center(child: Text('This group no longer exists.'))
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text(
                        group.description,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'These payments are represented by their leftover in the main payment list. Deleting the group restores them individually.',
                      ),
                      const SizedBox(height: 20),
                      for (final p in group.members)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            p.settlementGroupId == null
                                ? Icons.receipt_long_outlined
                                : Icons.account_tree_outlined,
                          ),
                          title: Text(
                            '${p.description} · ${money(p.amount, signed: true)}',
                          ),
                          subtitle: Text(
                            '${shortDate(p.date)} · ${l.accountLabel(p.accountId)} · ${l.categoryLabel(p.category)}',
                          ),
                          trailing: p.settlementGroupId == null
                              ? null
                              : const Icon(Icons.chevron_right),
                          onTap: p.settlementGroupId == null
                              ? null
                              : () => showBorrowingGroup(
                                  context,
                                  l,
                                  p.settlementGroupId!,
                                ),
                        ),
                      const Divider(height: 32),
                      Text(
                        'Leftover ${money(group.leftover.amount, signed: true)}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${shortDate(group.leftover.date)} · ${l.accountLabel(group.leftover.accountId)} · ${l.categoryLabel(group.leftover.category)}',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'The balance is recalculated from the original amounts, including bank corrections. A leftover cannot be deleted directly; delete its group instead.',
                      ),
                      if (group.usedBy == null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const ValueKey('classify-leftover'),
                            onPressed: busy
                                ? null
                                : () => classify(group.leftover),
                            icon: const Icon(Icons.category_outlined),
                            label: const Text('Change leftover category'),
                          ),
                        )
                      else ...[
                        const SizedBox(height: 16),
                        const Text(
                          'This leftover is used in another group. Delete that later group before changing this leftover or deleting this group.',
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () =>
                                showBorrowingGroup(context, l, group.usedBy!),
                            icon: const Icon(Icons.account_tree_outlined),
                            label: const Text('View later group'),
                          ),
                        ),
                      ],
                      if (error != null)
                        Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      const SizedBox(height: 24),
                      OutlinedButton.icon(
                        key: const ValueKey('delete-borrowing-group'),
                        icon: const Icon(Icons.delete_outline),
                        label: Text(
                          busy
                              ? 'Saving…'
                              : 'Delete group and restore payments',
                        ),
                        onPressed: busy || group.usedBy != null
                            ? null
                            : () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Delete this group?'),
                                    content: Text(
                                      'Restore ${group.members.length} individual payments and remove the leftover. This can be undone.',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text('Cancel'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text('Delete group'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed != true || !mounted) return;
                                setState(() {
                                  busy = true;
                                  error = null;
                                });
                                final ok = await l.reconcile(
                                  '/api/borrowing/delete',
                                  {'id': group.id},
                                );
                                if (!context.mounted) return;
                                if (ok) {
                                  Navigator.pop(context);
                                } else {
                                  setState(() {
                                    busy = false;
                                    error = l.error;
                                  });
                                }
                              },
                      ),
                    ],
                  ),
                ),
              ),
      );
    },
  );
}
