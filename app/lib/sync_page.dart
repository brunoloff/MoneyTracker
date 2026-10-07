import 'package:flutter/material.dart';
import 'ledger.dart';

class SyncPage extends StatefulWidget {
  final Ledger ledger;
  const SyncPage({super.key, required this.ledger});
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  Ledger get l => widget.ledger;
  List<dynamic> rows = [];
  final Map<String, String> choices = {};
  bool busy = false, awaitingSync = false, reviewing = false;
  String? error;
  bool awaitingRates = false;
  Map<String, dynamic> rateStatus = {};
  double tolerance = 10;
  DateTime paypalFrom = DateTime.now().subtract(const Duration(days: 90));
  bool historyInitialized = false;
  Map<String, dynamic> history = {};
  String dateLabel(DateTime date) => date.toIso8601String().substring(0, 10);
  @override
  void initState() {
    super.initState();
    l.addListener(_changed);
    refresh();
  }

  @override
  void dispose() {
    l.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (awaitingRates && !l.syncing) {
      awaitingRates = false;
      refresh();
    }
    if (awaitingSync && !l.syncing) {
      awaitingSync = false;
      if (l.error == null) {
        reviewing = true;
        refresh();
      }
    }
  }

  Future<void> refresh() async {
    try {
      final data = await l.post('/api/paypal/review', {});
      if (mounted) {
        setState(() {
          rows = data['rows'];
          history = Map<String, dynamic>.from(data['history'] ?? {});
          if (!historyInitialized && history['requestedFrom'] != null) {
            paypalFrom = DateTime.parse(history['requestedFrom']);
          }
          historyInitialized = true;
          choices.clear();
          rateStatus = Map<String, dynamic>.from(data['exchangeRates'] ?? {});
          tolerance = (data['tolerancePercent'] ?? 10).toDouble();
          // Exact matches take priority; never select the same bank movement twice.
          for (final rule in ['exact', 'fx']) {
            for (final row in rows.where((r) => r['rule'] == rule)) {
              final suggestion = (row['candidates'] as List)
                  .where(
                    (c) => c['rule'] == rule && !choices.containsValue(c['id']),
                  )
                  .firstOrNull;
              if (suggestion != null) {
                choices[row['observation']['id']] = suggestion['id'];
              }
            }
          }
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> confirm() async {
    var confirmedCount = 0;
    final actionId = 'paypal-${DateTime.now().microsecondsSinceEpoch}';
    l.saving = true;
    l.changed();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final pairs = choices.entries
          .map((e) => {'observationId': e.key, 'bankId': e.value})
          .toList();
      // Keep each request below the original server's 8 KiB / 100-pair limits.
      for (var offset = 0; offset < pairs.length; offset += 40) {
        final end = offset + 40 < pairs.length ? offset + 40 : pairs.length;
        await l.post('/api/paypal/confirm', {
          'pairs': pairs.sublist(offset, end),
          'actionId': actionId,
        });
        confirmedCount += end - offset;
      }
      await l.load();
      await refresh();
    } catch (e) {
      await l.load();
      await refresh();
      if (mounted) {
        setState(
          () => error =
              '$confirmedCount associations confirmed before the error: $e. Remaining payments are shown below.',
        );
      }
    }
    l.saving = false;
    l.changed();
    if (mounted) setState(() => busy = false);
  }

  String amount(dynamic p) =>
      '${p['currency']} ${(p['amount'] / 100).toStringAsFixed(2)}';
  Future<void> choose(dynamic row) async {
    final candidates = (row['candidates'] as List).cast<Map<String, dynamic>>();
    String query = '';
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final visible = candidates
              .where(
                (c) => '${c['description']} ${c['date']} ${amount(c)}'
                    .toLowerCase()
                    .contains(query.toLowerCase()),
              )
              .toList();
          return AlertDialog(
            title: const Text('Find a PayPal bank movement'),
            content: SizedBox(
              width: 600,
              height: 420,
              child: Column(
                children: [
                  const Text(
                    'PayPal-labelled movements within 31 days, from accounts assigned to the same user. FX candidates must be within the configured conversion tolerance. Closest suggestions first.',
                  ),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Search description, date or amount',
                    ),
                    onChanged: (v) => update(() => query = v),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final c in visible)
                          ListTile(
                            enabled: !choices.entries.any(
                              (e) =>
                                  e.key != row['observation']['id'] &&
                                  e.value == c['id'],
                            ),
                            title: Text('${amount(c)} · ${c['date']}'),
                            subtitle: Text(
                              '${c['description']} · ${c['accountLabel'] ?? 'Bank account'} · ${c['delay']} day difference',
                            ),
                            onTap: () =>
                                Navigator.pop(context, c['id'] as String),
                          ),
                        if (visible.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Text(
                              'No eligible bank movements found. Try syncing your bank accounts or checking account ownership in Preferences.',
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
    if (chosen != null && mounted) {
      setState(() => choices[row['observation']['id']] = chosen);
    }
  }

  Widget groupTable(String rule, String title) {
    final group = rows.where((r) => r['rule'] == rule).toList();
    return ExpansionTile(
      key: PageStorageKey('paypal-group-$rule'),
      initiallyExpanded: true,
      tilePadding: EdgeInsets.zero,
      title: Text(
        '$title (${group.length})',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      children: [
        if (rule == 'fx')
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Historical ECB conversion ±$tolerance%. Verify before confirming.',
            ),
          ),
        if (group.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('No payments in this section.'),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: DataTable(
                  columnSpacing: 18,
                  horizontalMargin: 8,
                  headingRowHeight: 36,
                  dataRowMinHeight: 52,
                  dataRowMaxHeight: 64,
                  columns: const [
                    DataColumn(label: Text('Use')),
                    DataColumn(label: Text('PayPal payment')),
                    DataColumn(label: Text('Amount')),
                    DataColumn(label: Text('Bank movement')),
                    DataColumn(label: Text('Conversion')),
                    DataColumn(label: Text('')),
                  ],
                  rows: [for (final row in group) paymentRow(row)],
                ),
              ),
            ),
          ),
      ],
    );
  }

  DataRow paymentRow(dynamic row) {
    final o = row['observation'];
    final candidates = row['candidates'] as List;
    final selected = choices[o['id']];
    final suggested = candidates
        .where((c) => c['rule'] == row['rule'])
        .firstOrNull;
    final bank =
        candidates.where((c) => c['id'] == selected).firstOrNull ?? suggested;
    return DataRow(
      cells: [
        DataCell(
          Checkbox(
            value: selected != null,
            onChanged: busy
                ? null
                : (v) {
                    if (v == false) {
                      setState(() => choices.remove(o['id']));
                    } else if (bank != null &&
                        !choices.containsValue(bank['id'])) {
                      setState(() => choices[o['id']] = bank['id']);
                    } else {
                      choose(row);
                    }
                  },
          ),
        ),
        DataCell(
          SizedBox(
            width: 220,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  message: o['description'],
                  child: Text(
                    o['description'],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(o['date'], style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
        DataCell(Text(amount(o))),
        DataCell(
          SizedBox(
            width: 210,
            child: bank == null
                ? const Text('No suggested match')
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${amount(bank)} · ${bank['date']}'),
                      Text(
                        bank['accountLabel'] ?? 'Bank account',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
          ),
        ),
        DataCell(
          bank?['expectedAmount'] == null
              ? const Text('—')
              : Tooltip(
                  message: 'ECB rate from ${bank['rateDate']}',
                  child: Text(
                    '≈ ${bank['currency']} ${(bank['expectedAmount'] / 100).toStringAsFixed(2)}\n${bank['differencePercent'].toStringAsFixed(1)}% difference',
                  ),
                ),
        ),
        DataCell(
          IconButton(
            tooltip: 'Find / change bank movement',
            onPressed: busy ? null : () => choose(row),
            icon: const Icon(Icons.search),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        reviewing ? 'Review PayPal associations' : 'Sync',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      if (error != null || l.error != null)
        Text(error ?? l.error!, style: const TextStyle(color: Colors.red)),
      if (l.syncing) ...[
        const LinearProgressIndicator(),
        Text(l.syncProgress ?? 'Syncing…'),
      ],
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: l.syncing || busy
                ? null
                : () {
                    awaitingRates = true;
                    l.sync(target: 'rates');
                  },
            icon: const Icon(Icons.currency_exchange),
            label: const Text('Download exchange rates'),
          ),
          Text(
            rateStatus['to'] == null
                ? 'No exchange rates downloaded'
                : "ECB · ${rateStatus['from']} to ${rateStatus['to']}",
          ),
        ],
      ),
      Text(
        'Matching tolerance: ±$tolerance% · change in Preferences → Payment matching',
        style: const TextStyle(fontSize: 12),
      ),
      if (history['requestedFrom'] != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            history['earliestReturned'] == null
                ? 'Last PayPal sync: requested from ${history['requestedFrom']}; no payments returned.'
                : 'Last PayPal sync: requested from ${history['requestedFrom']}; returned ${history['returnedCount']} payments, ${history['earliestReturned']} to ${history['latestReturned']}.',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      if (!reviewing) ...[
        const SizedBox(height: 24),
        Wrap(
          spacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text(
              'Bank accounts',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            FilledButton(
              onPressed: l.syncing ? null : () => l.sync(),
              child: const Text('Sync all banks'),
            ),
          ],
        ),
        for (final a in l.accounts.where((a) => a['source'] != 'PayPal'))
          ListTile(
            title: Text('${a['source']} · ${l.accountLabel(a['id'])}'),
            trailing: OutlinedButton(
              onPressed: l.syncing ? null : () => l.sync(accountId: a['id']),
              child: const Text('Sync'),
            ),
          ),
        const Divider(),
        for (final a in l.accounts.where((a) => a['source'] == 'PayPal'))
          DropdownButtonFormField<String>(
            key: ValueKey('paypal-owner-${a['id']}-${l.accountUsers[a['id']]}'),
            initialValue: l.accountUsers[a['id']] ?? '',
            decoration: const InputDecoration(labelText: 'PayPal belongs to'),
            items: [
              const DropdownMenuItem(value: '', child: Text('Unassigned')),
              for (final user in l.users)
                DropdownMenuItem<String>(
                  value: user['id'],
                  child: Text(user['name']),
                ),
            ],
            onChanged: busy || l.syncing
                ? null
                : (value) async {
                    setState(() => busy = true);
                    try {
                      final owners = Map<String, dynamic>.from(l.accountUsers);
                      if (value == '') {
                        owners.remove(a['id']);
                      } else {
                        owners[a['id']] = value;
                      }
                      await l.saveProfiles({
                        'users': l.users,
                        'accountUsers': owners,
                      });
                      await refresh();
                    } catch (e) {
                      if (mounted) setState(() => error = '$e');
                    }
                    if (mounted) setState(() => busy = false);
                  },
          ),
        const Text(
          'PayPal',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const Text(
          'Download payments, then review matches. Unassociated payments are kept out of overview totals.',
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const ValueKey('paypal-history-start'),
          icon: const Icon(Icons.date_range),
          label: Text('Download from ${dateLabel(paypalFrom)}'),
          onPressed: l.syncing
              ? null
              : () async {
                  final today = DateTime.now();
                  final earliest = DateTime(
                    today.year - 7,
                    today.month,
                    today.day,
                  );
                  final chosen = await showDatePicker(
                    context: context,
                    initialDate: paypalFrom.isBefore(earliest)
                        ? earliest
                        : paypalFrom,
                    firstDate: earliest,
                    lastDate: today,
                    helpText: 'Download PayPal payments from',
                  );
                  if (chosen != null && mounted) {
                    setState(() => paypalFrom = chosen);
                  }
                },
        ),
        const Text(
          'Choose up to 7 years back. This PayPal connection currently appears to return about 1 year; older saved payments are kept.',
          style: TextStyle(fontSize: 12),
        ),
        Wrap(
          spacing: 12,
          children: [
            FilledButton(
              onPressed: l.syncing
                  ? null
                  : () {
                      awaitingSync = true;
                      l.sync(target: 'paypal', dateFrom: dateLabel(paypalFrom));
                    },
              child: const Text('Sync PayPal'),
            ),
            TextButton(
              onPressed: () {
                setState(() => reviewing = true);
                refresh();
              },
              child: Text('Review pending (${rows.length})'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text(
          'Amazon · Coming later',
          style: TextStyle(color: Colors.grey),
        ),
      ] else ...[
        TextButton(
          onPressed: () => setState(() => reviewing = false),
          child: const Text('Back to sync sources'),
        ),
        const Text(
          'Nothing is merged until you confirm. Previously confirmed pairs are hidden. Assign your PayPal account to its user in Preferences to match that user’s bank accounts.',
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy || choices.isEmpty ? null : confirm,
          child: Text('Confirm ${choices.length} selected'),
        ),
        groupTable('exact', 'Exact amount and currency'),
        groupTable('fx', 'Different currency'),
        groupTable('unmatched', 'Unmatched or ambiguous'),
        if (rows.isEmpty)
          const Text(
            'No pending PayPal payments. Sync PayPal to fetch new movements.',
          ),
      ],
    ],
  );
}
