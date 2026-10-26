import 'package:flutter/material.dart';
import 'ledger.dart';

class RulePoolPicker extends StatelessWidget {
  final Ledger ledger;
  final String? userId;
  final ValueChanged<String?>? onChanged;
  const RulePoolPicker({
    super.key,
    required this.ledger,
    required this.userId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    key: ValueKey('rule-pool-${userId ?? 'shared'}'),
    initialValue: userId == null ? 'shared' : 'user:$userId',
    isExpanded: true,
    decoration: const InputDecoration(labelText: 'Rule pool'),
    items: [
      DropdownMenuItem(value: 'shared', child: Text(ledger.rulePoolName(null))),
      for (final u in ledger.users)
        DropdownMenuItem(
          value: 'user:${u['id']}',
          child: Text(
            ledger.rulePoolName(u['id']),
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
    onChanged: onChanged == null
        ? null
        : (value) {
            if (value != null) {
              onChanged!(value == 'shared' ? null : value.substring(5));
            }
          },
  );
}
