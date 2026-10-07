import 'dart:convert';
import 'package:flutter/material.dart';
import 'ledger.dart';
import 'taxonomy_settings.dart';
import 'bank_connection.dart';
import 'setup_page.dart';
import 'spreadsheet_import.dart';
import 'testing_help.dart';

class PreferencesPage extends StatefulWidget {
  final Ledger ledger;
  const PreferencesPage({super.key, required this.ledger});
  @override
  State<PreferencesPage> createState() => _PreferencesPageState();
}

class _PreferencesPageState extends State<PreferencesPage> {
  late List<Map<String, dynamic>> users;
  late Map<String, dynamic> owners, nicknames;
  bool dirty = false, busy = false;
  int historyYears = 1;
  int section = 0;
  String? message;
  Ledger get l => widget.ledger;
  @override
  void initState() {
    super.initState();
    users = (jsonDecode(jsonEncode(l.users)) as List)
        .cast<Map<String, dynamic>>();
    owners = Map.from(l.accountUsers);
    nicknames = Map.from(l.accountNicknames);
  }

  void edit(VoidCallback action) => setState(() {
    action();
    dirty = true;
    message = null;
  });
  Future<void> save() async {
    final names = users
        .map((u) => (u['name'] as String).trim().toLowerCase())
        .toList();
    if (names.any((n) => n.isEmpty) || names.toSet().length != names.length) {
      setState(() => message = 'Give each user a unique, non-empty name.');
      return;
    }
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await l.saveProfiles({
        'users': users,
        'accountUsers': owners,
        'accountNicknames': nicknames,
      });
      if (mounted) {
        setState(() {
          dirty = false;
          message = 'Users and accounts saved.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  static const sections = [
    'Budget period',
    'Transaction history',
    'Users & accounts',
    'Categories & tags',
    'Payment matching',
    'Undo history',
    'Testing help',
  ];
  Widget _navigation(bool wide) {
    final buttons = [
      for (var i = 0; i < sections.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 6, right: 6),
          child: TextButton(
            key: ValueKey('preferences-section-$i'),
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              backgroundColor: section == i ? const Color(0xffe0f2ef) : null,
              foregroundColor: section == i
                  ? const Color(0xff008f84)
                  : const Color(0xff67758c),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            ),
            onPressed: () => setState(() => section = i),
            child: Text(sections[i]),
          ),
        ),
    ];
    return wide
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: buttons,
          )
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: buttons),
          );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 700;
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < sections.length; i++)
            Visibility(
              visible: section == i,
              maintainState: true,
              child: switch (i) {
                0 => _section0(),
                1 => _section1(),
                2 => _section2(),
                3 => _section3(),
                4 => _matching(),
                5 => _undoSettings(),
                _ => TextButton.icon(
                  onPressed: () => showTestingHelp(context),
                  icon: const Icon(Icons.help_outline),
                  label: const Text('Open testing help'),
                ),
              },
            ),
        ],
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Preferences',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 205, child: _navigation(true)),
                const SizedBox(width: 28),
                Expanded(child: content),
              ],
            )
          else ...[
            _navigation(false),
            const SizedBox(height: 18),
            content,
          ],
        ],
      );
    },
  );
  int? undoLimitDraft;
  Widget _undoSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Undo history',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
      const Text(
        'Choose how many saved actions to keep. A sync or a complete PayPal confirmation counts as one action.',
      ),
      TextFormField(
        key: ValueKey('undo-limit-${l.undoLimit}'),
        initialValue: l.undoLimit.toString(),
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Undo steps to keep',
          helperText: 'Default: 100. Use 0 for unlimited; maximum 10,000.',
        ),
        onChanged: (value) => undoLimitDraft = int.tryParse(value) ?? -1,
      ),
      const SizedBox(height: 12),
      const Text(
        'Reducing this limit permanently discards older undo steps. Increasing it later will not restore discarded history.',
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: busy
            ? null
            : () async {
                final value = undoLimitDraft ?? l.undoLimit;
                if (value < 0 || value > 10000) {
                  setState(() => message = 'Choose 0 to 10,000 steps.');
                  return;
                }
                setState(() => busy = true);
                try {
                  await l.post('/api/preferences', {'undoLimit': value});
                  await l.load();
                  if (mounted) {
                    setState(() => message = 'Undo history limit saved.');
                  }
                } catch (e) {
                  if (mounted) setState(() => message = '$e');
                }
                if (mounted) setState(() => busy = false);
              },
        child: const Text('Save undo history settings'),
      ),
      if (message != null) Text(message!),
    ],
  );

  Widget _matching() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Payment matching',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
      ),
      const Text(
        'Allow bank amounts within this percentage of the historical ECB conversion. Download exchange rates on the Sync page.',
      ),
      TextFormField(
        key: ValueKey('fx-tolerance-${l.fxTolerancePercent}'),
        initialValue: l.fxTolerancePercent.toString(),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          labelText: 'Currency conversion tolerance (%)',
          helperText: 'Default: ±10%. Range: 0–100%.',
        ),
        onChanged: (value) =>
            toleranceDraft = double.tryParse(value) ?? double.nan,
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: busy
            ? null
            : () async {
                final value = toleranceDraft ?? l.fxTolerancePercent;
                if (!value.isFinite || value < 0 || value > 100) {
                  setState(() => message = 'Choose 0 to 100 percent.');
                  return;
                }
                setState(() => busy = true);
                try {
                  await l.post('/api/preferences', {
                    'fxTolerancePercent': value,
                  });
                  await l.load();
                  if (mounted) {
                    setState(() => message = 'Matching tolerance saved.');
                  }
                } catch (e) {
                  if (mounted) setState(() => message = '$e');
                }
                if (mounted) setState(() => busy = false);
              },
        child: const Text('Save matching settings'),
      ),
      if (message != null) Text(message!),
    ],
  );
  double? toleranceDraft;

  Widget _section0() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Budget period',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      RadioGroup<String>(
        groupValue: l.period,
        onChanged: (v) {
          if (v != null && !l.saving) l.setPeriod(v);
        },
        child: const Column(
          children: [
            RadioListTile(
              value: 'month',
              title: Text('Calendar month'),
              subtitle: Text('From the first day of the month'),
            ),
            RadioListTile(
              value: 'salary',
              title: Text('Since last salary'),
              subtitle: Text(
                'Salary periods follow the selected user’s accounts',
              ),
            ),
          ],
        ),
      ),
      if (l.error != null)
        Text(l.error!, style: const TextStyle(color: Colors.red)),
    ],
  );
  Widget _section1() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (l.desktop) ...[
        OutlinedButton.icon(
          onPressed: busy || l.syncing
              ? null
              : () async {
                  final result = await showDialog<String>(
                    context: context,
                    builder: (_) => SpreadsheetImportDialog(ledger: l),
                  );
                  if (mounted && result != null) {
                    setState(() => message = result);
                  }
                },
          icon: const Icon(Icons.upload_file),
          label: const Text('Import CGD spreadsheet'),
        ),
        const SizedBox(height: 20),
      ],
      const Text(
        'Transaction history',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text(
        'Download older transactions for all connected accounts. The bank controls how much history is available. Existing payments and category corrections are kept.',
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 160,
            child: DropdownButtonFormField<int>(
              initialValue: historyYears,
              decoration: const InputDecoration(labelText: 'Years back'),
              items: List.generate(
                20,
                (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}')),
              ),
              onChanged: l.syncing
                  ? null
                  : (value) {
                      if (value != null) setState(() => historyYears = value);
                    },
            ),
          ),
          FilledButton.icon(
            onPressed: l.syncing ? null : () => l.sync(years: historyYears),
            icon: const Icon(Icons.download),
            label: Text(l.syncing ? 'Downloading…' : 'Download history'),
          ),
        ],
      ),
      if (l.syncing) ...[
        const SizedBox(height: 12),
        const LinearProgressIndicator(),
        Text(l.syncProgress ?? 'Downloading bank transactions…'),
      ],
      if (l.historyImport != null) ...[
        const SizedBox(height: 16),
        Text(
          'Last history download: ${shortDate(DateTime.parse(l.historyImport!['completedAt']).toLocal())} · ${l.historyImport!['added']} new records',
        ),
        Text(
          'Requested from ${l.historyImport!['requestedFrom']}. Returned history by account:',
        ),
        for (final account in l.historyImport!['accounts'] as List)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${l.accountNicknames[account['accountId']] ?? account['label']}: ${account['count']} records${account['earliest'] == null ? '' : ', earliest ${account['earliest']}'}',
            ),
          ),
        const SizedBox(height: 8),
        const Text(
          'An empty or shorter result does not prove there were no older transactions; the bank or consent may restrict history.',
        ),
      ],
    ],
  );
  Widget _section2() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (l.desktop) ...[
        OutlinedButton.icon(
          onPressed: busy || l.syncing
              ? null
              : () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (pageContext) => SetupPage(
                        ledger: l,
                        onFinished: () => Navigator.pop(pageContext),
                      ),
                    ),
                  );
                  await l.load();
                },
          icon: const Icon(Icons.key),
          label: const Text('Enable Banking setup'),
        ),
        const SizedBox(height: 20),
      ],
      const Text(
        'Users',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text(
        'Create user views, then assign each account below. These share the same local data and classification rules.',
      ),
      const SizedBox(height: 16),
      for (final user in users)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey(user['id']),
                  initialValue: user['name'],
                  enabled: !busy,
                  maxLength: 60,
                  decoration: const InputDecoration(
                    labelText: 'User name',
                    counterText: '',
                  ),
                  onChanged: (value) => edit(() => user['name'] = value),
                ),
              ),
              IconButton(
                tooltip: 'Remove user',
                onPressed: busy
                    ? null
                    : () async {
                        final remove = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Remove user?'),
                            content: const Text(
                              'Their accounts will become unassigned. No payments or bank connections will be deleted.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Remove'),
                              ),
                            ],
                          ),
                        );
                        if (remove == true && mounted) {
                          edit(() {
                            users.remove(user);
                            owners.removeWhere(
                              (_, value) => value == user['id'],
                            );
                          });
                        }
                      },
                icon: const Icon(Icons.person_remove_outlined),
              ),
            ],
          ),
        ),
      OutlinedButton.icon(
        onPressed: busy || users.length >= 50
            ? null
            : () => edit(
                () => users.add({
                  'id': 'user-${DateTime.now().microsecondsSinceEpoch}',
                  'name': '',
                }),
              ),
        icon: const Icon(Icons.person_add_outlined),
        label: const Text('Add user'),
      ),
      const SizedBox(height: 28),
      const Text(
        'Account assignments',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text(
        'Each account belongs to one user. All users includes every account, including unassigned accounts. A merged payment is counted once in a user’s view if any of its accounts belongs to them.',
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: busy || l.syncing
            ? null
            : () async {
                final result = await showDialog<String>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => BankConnection(ledger: l),
                );
                if (mounted && result != null) setState(() => message = result);
              },
        icon: const Icon(Icons.account_balance_outlined),
        label: const Text('Connect or renew a bank'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: busy || l.syncing ? null : () => l.sync(target: 'accounts'),
        icon: const Icon(Icons.refresh),
        label: Text(
          l.syncing ? 'Refreshing…' : 'Refresh Enable Banking accounts',
        ),
      ),
      if (l.syncing)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(l.syncProgress ?? 'Checking accounts…'),
        ),
      if (l.accountRefresh != null && !l.syncing)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            [
              l.accountRefresh!['message'],
              ...?l.accountRefresh!['warnings'] as List?,
            ].join('\n'),
          ),
        ),
      const SizedBox(height: 12),
      if (l.accounts.isEmpty) const Text('No accounts connected yet.'),
      for (final account in l.accounts)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${account['source'] ?? 'Bank'} · ${account['label']}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: ValueKey('account-nickname-${account['id']}'),
                initialValue: nicknames[account['id']] ?? '',
                enabled: !busy,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'Nickname',
                  helperText: 'Leave blank to use the bank’s account name',
                  counterText: '',
                  isDense: true,
                ),
                onChanged: (value) =>
                    edit(() => nicknames[account['id']] = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('${account['id']}-${owners[account['id']]}'),
                initialValue: owners[account['id']] ?? 'unassigned',
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Assigned user'),
                items: [
                  const DropdownMenuItem(
                    value: 'unassigned',
                    child: Text('Unassigned'),
                  ),
                  ...users.map(
                    (u) => DropdownMenuItem<String>(
                      value: u['id'],
                      child: Text(
                        (u['name'] as String).trim().isEmpty
                            ? 'New user'
                            : u['name'],
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: busy
                    ? null
                    : (value) => edit(() {
                        if (value == 'unassigned') {
                          owners.remove(account['id']);
                        } else {
                          owners[account['id']] = value;
                        }
                      }),
              ),
            ],
          ),
        ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: busy || !dirty ? null : save,
        child: Text(busy ? 'Saving…' : 'Save users and accounts'),
      ),
      if (message != null)
        Padding(padding: const EdgeInsets.only(top: 12), child: Text(message!)),
      if (dirty)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Unsaved changes — save to apply nicknames and assignments.',
          ),
        ),
    ],
  );
  Widget _section3() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TaxonomySettings(ledger: l),
      const SizedBox(height: 24),
    ],
  );
}
