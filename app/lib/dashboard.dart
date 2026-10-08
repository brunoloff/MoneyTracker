import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ledger.dart';
import 'category_picker.dart';
import 'rules_page.dart';
import 'preferences_page.dart';
import 'sync_page.dart';

const teal = Color(0xff008f84),
    muted = Color(0xff67758c),
    border = Color(0xffe3e9f0);
IconData categoryIcon(String c) => switch (c) {
  'Food' => Icons.restaurant_outlined,
  'Shopping' => Icons.shopping_bag_outlined,
  'Travel' => Icons.flight_outlined,
  'Bills' => Icons.receipt_long_outlined,
  'Transport' => Icons.directions_transit_outlined,
  'Rent' => Icons.home_outlined,
  'Health' => Icons.favorite_border,
  'Salary' || 'Other income' => Icons.work_outline,
  'Transfer' => Icons.swap_horiz,
  _ => Icons.more_horiz,
};

class Dashboard extends StatefulWidget {
  final Ledger ledger;
  const Dashboard({super.key, required this.ledger});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard>
    with SingleTickerProviderStateMixin {
  Ledger get l => widget.ledger;
  int limit = 40;
  String minimumPriceText = '', maximumPriceText = '';
  String? priceError;
  int priceFieldRevision = 0;
  void applyPriceRange() {
    try {
      final minimum = parsePrice(minimumPriceText);
      final maximum = parsePrice(maximumPriceText);
      if (minimum != null && maximum != null && minimum > maximum) {
        throw const FormatException('Minimum must not exceed maximum.');
      }
      setState(() {
        priceError = null;
        limit = 40;
      });
      l.minimumAmount = minimum;
      l.maximumAmount = maximum;
      l.changed();
    } on FormatException catch (e) {
      setState(() => priceError = e.message);
    }
  }

  int tab = 0;
  final List<Widget?> _panes = List.filled(4, null);
  Widget _pages() {
    _panes[tab] = _pane(switch (tab) {
      0 => _content(),
      1 => RulesPage(ledger: l),
      2 => PreferencesPage(ledger: l),
      _ => SyncPage(ledger: l),
    });
    return IndexedStack(
      index: tab,
      children: [
        for (var i = 0; i < _panes.length; i++)
          TickerMode(
            enabled: tab == i,
            child: KeyedSubtree(
              key: ValueKey('history-${l.undoRevision}-$i'),
              child: RepaintBoundary(
                child: _panes[i] ?? const SizedBox.shrink(),
              ),
            ),
          ),
      ],
    );
  }

  late final TabController tabs = TabController(length: 2, vsync: this);
  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: l,
    builder: (context, _) => Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _header(),
            Expanded(
              child: l.loading
                  ? const Center(child: CircularProgressIndicator())
                  : _pages(),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _pane(Widget child) => SingleChildScrollView(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120),
        child: Padding(
          padding: EdgeInsets.all(
            MediaQuery.sizeOf(context).width < 600 ? 18 : 32,
          ),
          child: child,
        ),
      ),
    ),
  );
  Color _color(String id) {
    final hex = l.categorySettings.firstWhere(
      (c) => c['id'] == id,
      orElse: () => {},
    )['color'];
    return hex == null
        ? categoryColor(l.mainCategory(id))
        : Color(0xff000000 | int.parse(hex, radix: 16));
  }

  Widget _header() {
    final compact = MediaQuery.sizeOf(context).width < 800;
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: border)),
      ),
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 24),
      child: Row(
        children: [
          const Tooltip(
            message: 'MoneyTracker',
            child: Icon(Icons.account_balance_wallet, color: teal, size: 26),
          ),
          const SizedBox(width: 8),
          if (!compact) ...[
            const Text(
              'MoneyTracker',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 20),
          ],
          SizedBox(
            width: compact ? 92 : 145,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: l.selectedUser,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(
                    value: 'all',
                    child: Text('All users', overflow: TextOverflow.ellipsis),
                  ),
                  const DropdownMenuItem(
                    value: 'unassigned',
                    child: Text('Unassigned', overflow: TextOverflow.ellipsis),
                  ),
                  ...l.users.map(
                    (u) => DropdownMenuItem<String>(
                      value: u['id'],
                      child: Text(u['name'], overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: l.saving
                    ? null
                    : (value) {
                        if (value != null) l.selectUser(value);
                      },
              ),
            ),
          ),
          SizedBox(width: compact ? 4 : 24),
          Expanded(
            child: TabBar(
              controller: tabs,
              isScrollable: !compact,
              tabAlignment: compact ? TabAlignment.fill : TabAlignment.start,
              labelStyle: TextStyle(fontSize: compact ? 12 : 14),
              labelPadding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
              dividerColor: Colors.transparent,
              indicatorColor: tab >= 2 ? Colors.transparent : teal,
              labelColor: tab >= 2 ? muted : teal,
              onTap: (index) => setState(() => tab = index),
              tabs: const [
                Tab(text: 'Overview'),
                Tab(text: 'Rules'),
              ],
            ),
          ),
          SizedBox(
            width: 36,
            child: PopupMenuButton<String>(
              tooltip: 'Undo / redo',
              icon: const Icon(Icons.history),
              enabled: !l.syncing && !l.saving,
              onSelected: (value) async {
                await l.restoreHistory(value == 'redo');
                if (mounted && l.error != null) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(l.error!)));
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'undo',
                  enabled: l.undoLabel != null,
                  child: Text(
                    l.undoLabel == null
                        ? 'Nothing to undo'
                        : 'Undo: ${l.undoLabel}',
                  ),
                ),
                PopupMenuItem(
                  value: 'redo',
                  enabled: l.redoLabel != null,
                  child: Text(
                    l.redoLabel == null
                        ? 'Nothing to redo'
                        : 'Redo: ${l.redoLabel}',
                  ),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  enabled: false,
                  child: Text(
                    l.undoSupported
                        ? 'History is saved across restarts. New changes only.'
                        : 'Restart the server to enable undo history.',
                  ),
                ),
              ],
            ),
          ),
          if (compact)
            IconButton(
              tooltip: 'Preferences',
              onPressed: () => setState(() => tab = 2),
              color: tab == 2 ? teal : muted,
              icon: const Icon(Icons.settings_outlined),
            )
          else
            TextButton.icon(
              onPressed: () => setState(() => tab = 2),
              style: TextButton.styleFrom(
                foregroundColor: tab == 2 ? teal : muted,
              ),
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('Preferences'),
            ),
          const SizedBox(width: 8),
          if (compact)
            IconButton(
              tooltip: l.syncing ? 'Syncing' : 'Sync',
              onPressed: () => setState(() => tab = 3),
              icon: const Icon(Icons.sync),
            )
          else
            FilledButton.icon(
              onPressed: () => setState(() => tab = 3),
              icon: const Icon(Icons.sync),
              label: Text(l.syncing ? 'Syncing' : 'Sync'),
            ),
        ],
      ),
    );
  }

  Widget _content() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (l.error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: MaterialBanner(
            content: Text(l.error!),
            actions: [
              TextButton(onPressed: l.load, child: const Text('Retry')),
            ],
          ),
        ),
      Wrap(
        spacing: 20,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton.outlined(
                tooltip: l.period == 'month'
                    ? 'Previous month'
                    : 'Previous salary period',
                onPressed: l.period == 'month'
                    ? () => l.moveMonth(-1)
                    : l.canPreviousSalary
                    ? () => l.moveSalary(1)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 180,
                child: Center(
                  child: Text(
                    l.period == 'month'
                        ? l.periodCount == 1
                              ? '${months[l.month.month - 1]} ${l.month.year}'
                              : '${months[l.start!.month - 1].substring(0, 3)} ${l.start!.year} – ${months[l.month.month - 1].substring(0, 3)} ${l.month.year}'
                        : l.lastSalary == null
                        ? 'No salary marked'
                        : '${shortDate(l.start!)} – ${l.canNextSalary ? shortDate(l.end.subtract(const Duration(days: 1))) : 'today'}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.outlined(
                tooltip: l.period == 'month'
                    ? 'Next month'
                    : 'Next salary period',
                onPressed:
                    l.period == 'month' &&
                        l.month.isBefore(
                          DateTime(l.clock().year, l.clock().month),
                        )
                    ? () => l.moveMonth(1)
                    : l.period == 'salary' && l.canNextSalary
                    ? () => l.moveSalary(-1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'month', label: Text('By month')),
              ButtonSegment(value: 'salary', label: Text('By salary')),
            ],
            selected: {l.period},
            onSelectionChanged: l.saving ? null : (v) => l.setPeriod(v.first),
            showSelectedIcon: false,
          ),
          SizedBox(
            width: 160,
            child: DropdownButtonFormField<int>(
              key: ValueKey('count-${l.periodCount}-${l.period}'),
              initialValue: l.periodCount,
              decoration: InputDecoration(
                labelText: l.period == 'month' ? 'Months' : 'Salary periods',
              ),
              items: List.generate(
                24,
                (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}')),
              ),
              onChanged: l.saving
                  ? null
                  : (value) {
                      if (value != null) l.setRange(count: value);
                    },
            ),
          ),
          if (l.effectiveCount > 1)
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Total')),
                ButtonSegment(value: true, label: Text('Monthly average')),
              ],
              selected: {l.monthlyAverage},
              showSelectedIcon: false,
              onSelectionChanged: l.saving
                  ? null
                  : (value) => l.setRange(average: value.first),
            ),
        ],
      ),
      if (l.periodCount > 1)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            l.showAverage
                ? 'Summary and chart: per-month average (total ÷ ${l.monthDivisor.toStringAsFixed(2)} months). Payments below show original amounts. ${l.period == 'month' ? 'Each selected calendar month counts once, including the current month so far.' : 'Partial calendar months are weighted by days covered, through today for the current salary period.'}'
                : 'Totals across ${l.effectiveCount} ${l.period == 'month' ? 'months' : 'salary periods'}.',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
        ),
      if (l.period == 'salary' && l.effectiveCount < l.periodCount)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Only ${l.effectiveCount} salary periods are available in this range.',
          ),
        ),
      if (l.incompleteHistory)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'This range starts before the imported history. Totals and averages may be incomplete.',
          ),
        ),
      const SizedBox(height: 16),
      if (l.period == 'salary' && l.lastSalary == null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xfffff8e8),
            child: const Text(
              'Mark your salary to start this period. Incoming payments are shown below: open the right one and choose Salary.',
            ),
          ),
        ),
      _panel(
        Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _metric('Spent', l.displayAmount(l.spent)),
                _metric(
                  'Income',
                  l.displayedIncome,
                  controls: l.canChooseIncome ? _incomeControls() : null,
                ),
                _metric('Net', l.displayAmount(l.income - l.spent), net: true),
              ],
            ),
            if (l.canChooseIncome && l.incomeMode != 'this_month') ...[
              const SizedBox(height: 12),
              Text(
                '${l.incomeMode == 'average' ? 'Average of ${l.incomeAverageMonths} calendar months before the selected month, including zero-income months.' : 'Income from the calendar month before the selected month.'} Spending and Net use the selected month.',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              if (l.incompleteIncomeHistory)
                const Text(
                  'Income history may be incomplete. Download older history in Preferences.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      _chart(),
      const SizedBox(height: 16),
      _payments(),
      const SizedBox(height: 16),
      Text(
        l.syncedAt == null
            ? 'No bank data imported yet. Tap Sync to begin.'
            : 'CGD · ${l.userAccounts.length} accounts · Last synced ${shortDate(DateTime.parse(l.syncedAt!).toLocal())}',
        style: const TextStyle(color: muted, fontSize: 12),
      ),
      const SizedBox(height: 6),
      const Text(
        'Totals use booked payments. Transfers are excluded; refunds count as income. Categories are suggestions until you review them.',
        style: TextStyle(color: muted, fontSize: 12),
      ),
      const SizedBox(height: 24),
    ],
  );
  Widget _panel(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: border),
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );
  Widget _incomeControls() => SizedBox(
    width: 140,
    child: Column(
      children: [
        PopupMenuButton<String>(
          key: const ValueKey('income-mode'),
          tooltip: 'Income display',
          enabled: !l.saving,
          initialValue: l.incomeMode,
          onSelected: (value) => l.setIncomeDisplay(mode: value),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'this_month', child: Text('This month')),
            PopupMenuItem(value: 'last_month', child: Text('Last month')),
            PopupMenuItem(
              value: 'average',
              child: Text('Average over last X months'),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    switch (l.incomeMode) {
                      'last_month' => 'Last month',
                      'average' => 'Average',
                      _ => 'This month',
                    },
                    style: const TextStyle(fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
                const Icon(Icons.expand_more, size: 16),
              ],
            ),
          ),
        ),
        if (l.incomeMode == 'average')
          DropdownButton<int>(
            key: const ValueKey('income-average-months'),
            isExpanded: true,
            value: l.incomeAverageMonths,
            items: [
              for (var i = 1; i <= 24; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    '$i ${i == 1 ? 'month' : 'months'}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            onChanged: l.saving
                ? null
                : (value) => l.setIncomeDisplay(months: value!),
          ),
      ],
    ),
  );
  Widget _metric(
    String name,
    int value, {
    bool net = false,
    Widget? controls,
  }) => Expanded(
    child: Column(
      children: [
        Text(name, style: const TextStyle(color: muted, fontSize: 13)),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            money(value, signed: net),
            style: TextStyle(
              fontSize: MediaQuery.sizeOf(context).width < 600 ? 18 : 28,
              fontWeight: FontWeight.w700,
              color: net && value >= 0 ? teal : null,
            ),
          ),
        ),
        ?controls,
      ],
    ),
  );
  final Set<String> _expandedCategories = {};

  Widget _chart() {
    final totals = l.totals;
    final max = totals.isEmpty ? 1 : totals.values.reduce(math.max);
    final children = <String, List<String>>{};
    for (final c in l.categorySettings) {
      if (c['parent'] != null) {
        children
            .putIfAbsent(c['parent'] as String, () => [])
            .add(c['id'] as String);
      }
    }
    final rows = <MapEntry<String, int>>[];
    for (final entry in totals.entries) {
      rows.add(entry);
      if (_expandedCategories.contains(entry.key)) {
        final ids = [...?children[entry.key]];
        ids.sort(
          (a, b) => (l.directCategoryTotals[b] ?? 0).compareTo(
            l.directCategoryTotals[a] ?? 0,
          ),
        );
        rows.addAll(
          ids.map((id) => MapEntry(id, l.directCategoryTotals[id] ?? 0)),
        );
      }
    }
    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Expenses by category',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'Select a name to expand subcategories; select a bar to filter payments.',
            style: TextStyle(fontSize: 12, color: muted),
          ),
          const SizedBox(height: 16),
          if (totals.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 25),
              child: Text(
                'No expenses in this period.',
                style: TextStyle(color: muted),
              ),
            )
          else
            ...rows.map(
              (e) => Semantics(
                button: true,
                label:
                    '${l.categoryName(e.key)}, ${money(l.displayAmount(e.value))}',
                child: InkWell(
                  onTap: () => l.filter(
                    categoryName: l.category == e.key ? 'all' : e.key,
                  ),
                  borderRadius: BorderRadius.circular(5),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: MediaQuery.sizeOf(context).width < 600
                              ? 108
                              : 142,
                          child: InkWell(
                            key: ValueKey('chart-category-${e.key}'),
                            onTap: children.containsKey(e.key)
                                ? () => setState(() {
                                    if (!_expandedCategories.add(e.key)) {
                                      _expandedCategories.remove(e.key);
                                    }
                                  })
                                : () => l.filter(
                                    categoryName: l.category == e.key
                                        ? 'all'
                                        : e.key,
                                  ),
                            child: Padding(
                              padding: EdgeInsets.only(
                                left: l.mainCategory(e.key) != e.key ? 14 : 0,
                                top: 6,
                                bottom: 6,
                                right: 8,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    children.containsKey(e.key)
                                        ? (_expandedCategories.contains(e.key)
                                              ? Icons.expand_more
                                              : Icons.chevron_right)
                                        : categoryIcon(e.key),
                                    color: _color(e.key),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      l.categoryName(e.key),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: l.category == e.key
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          key: ValueKey('chart-bar-${e.key}'),
                          child: LayoutBuilder(
                            builder: (context, c) => Stack(
                              children: [
                                Container(
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: const Color(0xffedf0f4),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                ),
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 250),
                                  width: c.maxWidth * e.value / max,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: _color(e.key),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: MediaQuery.sizeOf(context).width < 600
                              ? 82
                              : 135,
                          child: Text(
                            '${money(l.displayAmount(e.value))}${MediaQuery.sizeOf(context).width > 650 ? '  (${(e.value / l.spent * 100).round()}%)' : ''}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _dropdown(
    String value,
    List<DropdownMenuItem<String>> items,
    void Function(String?) change, {
    double width = 165,
  }) => SizedBox(
    width: MediaQuery.sizeOf(context).width < 600
        ? math.min(width, 145)
        : width,
    child: DropdownButtonFormField<String>(
      key: ValueKey('$value-${items.length}'),
      initialValue: value,
      isExpanded: true,
      items: items,
      onChanged: change,
      style: const TextStyle(
        fontFamily: 'MoneySans',
        fontSize: 13,
        color: Color(0xff12213e),
      ),
      decoration: const InputDecoration(
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    ),
  );
  Widget _payments() {
    final rows = l.visible;
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final search = TextField(
      onChanged: (v) {
        limit = 40;
        l.filter(search: v);
      },
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.search, size: 20),
        hintText: 'Search descriptions or tags…',
      ),
    );
    final accountFilter = _dropdown(
      l.account,
      [
        const DropdownMenuItem(value: 'all', child: Text('All accounts')),
        ...l.userAccounts.map(
          (a) => DropdownMenuItem(
            value: a['id'] as String,
            child: Text(l.accountLabel(a['id'])),
          ),
        ),
      ],
      (v) => l.filter(accountId: v),
      width: 155,
    );
    final categoryFilter = _dropdown(
      l.category,
      [
        const DropdownMenuItem(value: 'all', child: Text('All categories')),
        ...l.categoryIds.map(
          (c) => DropdownMenuItem(value: c, child: Text(l.categoryLabel(c))),
        ),
      ],
      (v) => l.filter(categoryName: v),
      width: 155,
    );
    final flowFilter = _dropdown(
      l.direction,
      const [
        DropdownMenuItem(value: 'all', child: Text('In & out')),
        DropdownMenuItem(value: 'expenses', child: Text('Expenses')),
        DropdownMenuItem(value: 'income', child: Text('Income')),
      ],
      (v) => l.filter(flow: v),
      width: 125,
    );
    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (l.tagSettings.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _dropdown(
                l.tag,
                [
                  const DropdownMenuItem(value: 'all', child: Text('All tags')),
                  ...l.tagSettings.map(
                    (t) => DropdownMenuItem<String>(
                      value: t['id'],
                      child: Text(t['name']),
                    ),
                  ),
                ],
                (value) {
                  l.tag = value ?? 'all';
                  l.changed();
                },
                width: 180,
              ),
            ),

          if (wide)
            Row(
              children: [
                const Text(
                  'All payments',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 20),
                Expanded(child: search),
                const SizedBox(width: 10),
                accountFilter,
                const SizedBox(width: 10),
                categoryFilter,
                const SizedBox(width: 10),
                flowFilter,
              ],
            )
          else ...[
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'All payments',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
                  ),
                ),
                Text('${rows.length}', style: const TextStyle(color: muted)),
              ],
            ),
            const SizedBox(height: 16),
            search,
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [accountFilter, categoryFilter, flowFilter],
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Tooltip(
              message:
                  'Sorts all matching payments. Amount uses size, ignoring the income/expense sign.',
              child: SizedBox(
                width: 240,
                child: DropdownButtonFormField<String>(
                  key: const ValueKey('payment-sort'),
                  initialValue: l.paymentSort,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Sort payments'),
                  items: const [
                    DropdownMenuItem(
                      value: 'name_asc',
                      child: Text('Name: A–Z'),
                    ),
                    DropdownMenuItem(
                      value: 'name_desc',
                      child: Text('Name: Z–A'),
                    ),
                    DropdownMenuItem(
                      value: 'date_desc',
                      child: Text('Date: newest first'),
                    ),
                    DropdownMenuItem(
                      value: 'date_asc',
                      child: Text('Date: oldest first'),
                    ),
                    DropdownMenuItem(
                      value: 'amount_desc',
                      child: Text('Amount: largest first'),
                    ),
                    DropdownMenuItem(
                      value: 'amount_asc',
                      child: Text('Amount: smallest first'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    limit = 40;
                    l.paymentSort = value;
                    l.changed();
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 140,
                child: TextFormField(
                  key: ValueKey('minimum-price-$priceFieldRevision'),
                  initialValue: minimumPriceText,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Min (€)'),
                  onChanged: (value) {
                    minimumPriceText = value;
                    applyPriceRange();
                  },
                ),
              ),
              SizedBox(
                width: 140,
                child: TextFormField(
                  key: ValueKey('maximum-price-$priceFieldRevision'),
                  initialValue: maximumPriceText,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Max (€)'),
                  onChanged: (value) {
                    maximumPriceText = value;
                    applyPriceRange();
                  },
                ),
              ),
              if (minimumPriceText.isNotEmpty || maximumPriceText.isNotEmpty)
                TextButton(
                  onPressed: () {
                    minimumPriceText = '';
                    maximumPriceText = '';
                    priceFieldRevision++;
                    applyPriceRange();
                  },
                  child: const Text('Clear amount range'),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              priceError ??
                  'Matches payment size, ignoring the income/expense sign. Leave either limit blank for no limit.',
              style: TextStyle(
                fontSize: 12,
                color: priceError == null ? muted : Colors.red,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (MediaQuery.sizeOf(context).width >= 750)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: Text(
                      'MERCHANT',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      'CATEGORY',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      'DATE',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ),
                  SizedBox(
                    width: 100,
                    child: Text(
                      'AMOUNT',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ),
                ],
              ),
            ),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  'No payments match this view.',
                  style: TextStyle(color: muted),
                ),
              ),
            ),
          ...rows.take(limit).map(_row),
          if (rows.length > limit)
            Center(
              child: TextButton(
                onPressed: () => setState(() => limit += 40),
                child: Text('Show more (${rows.length - limit} remaining)'),
              ),
            ),
          const SizedBox(height: 12),
          const Row(
            children: [
              Icon(Icons.info_outline, size: 15, color: muted),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Open a payment to review its category or mark salary / transfers.',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(Payment p) => InkWell(
    key: ValueKey('category-${p.id}'),
    onTap: () => _classification(p),
    borderRadius: BorderRadius.circular(20),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _color(p.category).withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '${l.categoryLabel(p.category)}${p.reviewed
            ? ''
            : p.ruleName != null
            ? ' · rule'
            : ' · ?'}',
        style: TextStyle(fontSize: 11, color: _color(p.category)),
      ),
    ),
  );
  Widget _row(Payment p) {
    final wide = MediaQuery.sizeOf(context).width >= 750;
    final merchant = Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: _color(p.category).withValues(alpha: .09),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            categoryIcon(p.category),
            size: 20,
            color: _color(p.category),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p.description,
                maxLines: wide ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '${p.source} · ${l.accountLabel(p.accountId)}${p.booked ? '' : ' · Pending'}',
                style: const TextStyle(fontSize: 11, color: muted),
              ),
              if (p.tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    p.tags.map((t) => '#${l.tagName(t)}').join('  '),
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                ),
              if (!wide) ...[const SizedBox(height: 7), _chip(p)],
            ],
          ),
        ),
      ],
    );
    return InkWell(
      onTap: () => _details(p),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: border)),
        ),
        child: wide
            ? Row(
                children: [
                  Expanded(flex: 5, child: merchant),
                  Expanded(
                    flex: 2,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _chip(p),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      shortDate(p.date),
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                  SizedBox(
                    width: 100,
                    child: Text(
                      money(p.amount, signed: true),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: p.amount > 0 ? teal : null,
                      ),
                    ),
                  ),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: merchant),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        money(p.amount, signed: true),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: p.amount > 0 ? teal : null,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        shortDate(p.date),
                        style: const TextStyle(color: muted, fontSize: 10),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  Widget _copyText(String text) => IconButton(
    tooltip: 'Copy description',
    icon: const Icon(Icons.copy_outlined, size: 18),
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Description copied')));
      }
    },
  );

  Future<void> _addToRule(Payment p) async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final categoryRules = {
      for (final id in l.categoryIds) id: categoryRuleDraft(l, id),
    };
    final fullCategories = categoryRules.entries
        .where((entry) => (entry.value['groups'] as List).length >= 2000)
        .map((entry) => l.categoryLabel(entry.key))
        .toList();
    final otherRules = l.rules
        .where(
          (r) =>
              r['kind'] == 'extra' ||
              ((r['tags'] as List?)?.isNotEmpty ?? false) ||
              (r['enabled'] == false && r['kind'] != 'category'),
        )
        .toList();
    final rule = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Add term to existing rule'),
        content: SizedBox(
          width: 500,
          height: 360,
          child: ListView(
            children: [
              const Text(
                'Adds a new OR group: Description includes this transaction’s description. Review before saving.',
              ),
              const SizedBox(height: 16),
              const Text(
                'Labels',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              CategoryPicker(
                ledger: l,
                selected: '',
                isSelectable: (id) =>
                    (categoryRules[id]!['groups'] as List).length < 2000,
                onSelected: (id) => Navigator.pop(dialog, categoryRules[id]),
              ),
              if (fullCategories.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Maximum of 2000 OR groups reached: ${fullCategories.join(', ')}',
                ),
              ],
              if (otherRules.isNotEmpty) ...[
                const SizedBox(height: 20),
                const Text(
                  'Other rules',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
              ],
              for (final rule in otherRules)
                ListTile(
                  title: Text(rule['name']),
                  subtitle: Text(
                    (rule['groups'] as List).length >= 2000
                        ? 'Maximum of 2000 OR groups reached'
                        : '${rule['category'] == null ? 'Tags only' : l.categoryLabel(rule['category'])}${rule['enabled'] == false ? ' · Disabled' : ''}',
                  ),
                  enabled: (rule['groups'] as List).length < 2000,
                  onTap: (rule['groups'] as List).length >= 2000
                      ? null
                      : () => Navigator.pop(dialog, rule),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (rule == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RuleEditor(
          ledger: l,
          rule: ruleWithTransactionTerm(rule, p.description),
        ),
      ),
    );
  }

  Widget _addRuleButton(Payment p, BuildContext sheet, bool busy) =>
      OutlinedButton.icon(
        onPressed: busy
            ? null
            : () {
                Navigator.pop(sheet);
                _addToRule(p);
              },
        icon: const Icon(Icons.playlist_add),
        label: const Text('Add term to existing rule'),
      );

  void _classification(Payment p) {
    final selectedTags = p.tags.toSet();
    bool busy = false;
    String? error;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              height: MediaQuery.sizeOf(sheet).height * .75,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      p.description,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Choose a category'),
                    const SizedBox(height: 12),
                    CategoryPicker(
                      ledger: l,
                      selected: p.category,
                      enabled: !busy,
                      allowIncome: p.amount > 0,
                      onSelected: (c) async {
                        update(() => busy = true);
                        final ok = await l.categorize(p, c);
                        if (!sheet.mounted) return;
                        if (ok) {
                          Navigator.pop(sheet);
                        } else {
                          update(() {
                            busy = false;
                            error = l.error;
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () {
                              Navigator.pop(sheet);
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => RuleEditor(
                                    ledger: l,
                                    rule: ruleWithTransactionTerm(
                                      categoryRuleDraft(l, p.category),
                                      p.description,
                                    ),
                                  ),
                                ),
                              );
                            },
                      icon: const Icon(Icons.rule),
                      label: const Text('Make rule based on this transaction'),
                    ),
                    const SizedBox(height: 8),
                    _addRuleButton(p, sheet, busy),
                    const SizedBox(height: 24),
                    const Text(
                      'Tags',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (l.tagSettings.isEmpty)
                      const Text(
                        'Create tags in Preferences to label and search payments.',
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final t in l.tagSettings)
                          FilterChip(
                            label: Text(t['name']),
                            selected: selectedTags.contains(t['id']),
                            onSelected: busy
                                ? null
                                : (value) => update(() {
                                    if (value) {
                                      selectedTags.add(t['id']);
                                    } else {
                                      selectedTags.remove(t['id']);
                                    }
                                  }),
                          ),
                      ],
                    ),
                    if (l.tagSettings.isNotEmpty)
                      FilledButton(
                        onPressed: busy
                            ? null
                            : () async {
                                update(() => busy = true);
                                try {
                                  await l.saveTags(p, selectedTags.toList());
                                  if (sheet.mounted) Navigator.pop(sheet);
                                } catch (e) {
                                  if (sheet.mounted) {
                                    update(() {
                                      busy = false;
                                      error = '$e';
                                    });
                                  }
                                }
                              },
                        child: const Text('Save tags'),
                      ),
                    if (error != null)
                      Text(error!, style: const TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _details(Payment p) {
    String selected = p.category;
    bool busy = false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            MediaQuery.viewInsetsOf(ctx).bottom + 28,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  p.description,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _copyText(p.description),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  money(p.amount, signed: true),
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: p.amount > 0 ? teal : null,
                  ),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  '${shortDate(p.date)} · ${p.source} · ${l.accountLabel(p.accountId)}',
                  style: const TextStyle(color: muted),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  p.reviewed
                      ? 'Category chosen manually'
                      : p.ruleName != null
                      ? 'Classified by rule: ${p.ruleName}'
                      : 'Suggested category · not yet reviewed',
                  style: const TextStyle(color: muted),
                ),
                const SizedBox(height: 12),
                _addRuleButton(p, ctx, busy),
                const SizedBox(height: 24),
                const Text('Choose a category'),
                const SizedBox(height: 12),
                CategoryPicker(
                  ledger: l,
                  selected: selected,
                  enabled: !busy,
                  allowIncome: p.amount > 0,
                  onSelected: (id) => set(() => selected = id),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Salary sets the start of your pay period. Transfers stay in the list but do not count as spending or income.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 24),
                Text(
                  'Source records (${p.sourceRecords.length})',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                ...p.sourceRecords.map(
                  (r) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: SelectableText(r['description'] ?? ''),
                    subtitle: SelectableText(
                      '${r['institution']} · ${r['date']}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SelectableText(
                          (r['currency'] ?? 'EUR') == 'EUR'
                              ? money(r['amount'] ?? 0, signed: true)
                              : '${r['currency']} ${((r['amount'] ?? 0) / 100).toStringAsFixed(2)}',
                        ),
                        _copyText(r['description'] ?? ''),
                      ],
                    ),
                  ),
                ),
                TextButton.icon(
                  icon: Icon(p.merged ? Icons.link_off : Icons.link),
                  label: Text(
                    p.merged ? 'Undo merge' : 'Merge matching payment',
                  ),
                  onPressed: busy
                      ? null
                      : () async {
                          Navigator.pop(ctx);
                          if (p.merged) {
                            await l.reconcile('/api/unmerge', {'id': p.id});
                          } else {
                            await _merge(p);
                          }
                        },
                ),
                const SizedBox(height: 16),
                const Text(
                  'Purchase details',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  p.purchaseDetails.isEmpty
                      ? 'Only the bank description is available. Amazon and PayPal item details are not connected yet.'
                      : p.purchaseDetails.join('\n'),
                  style: const TextStyle(color: muted, fontSize: 13),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: busy
                        ? null
                        : () async {
                            set(() => busy = true);
                            final ok = await l.categorize(p, selected);
                            if (ctx.mounted) {
                              if (ok) {
                                Navigator.pop(ctx);
                              } else {
                                set(() => busy = false);
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Could not save. Please retry.',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                    child: Text(busy ? 'Saving…' : 'Save category'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _merge(Payment primary) async {
    final candidates =
        l.payments
            .where(
              (p) =>
                  l.includesPayment(p) &&
                  p.id != primary.id &&
                  p.amount == primary.amount &&
                  p.status == primary.status,
            )
            .toList()
          ..sort(
            (a, b) => (a.date.difference(primary.date).inDays.abs()).compareTo(
              b.date.difference(primary.date).inDays.abs(),
            ),
          );
    final selected = await showDialog<Payment>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Merge matching payment'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose another record of this same ${money(primary.amount.abs())} payment. Equal amounts alone do not prove a match.',
              ),
              const SizedBox(height: 16),
              if (candidates.isEmpty)
                const Text(
                  'No other payments with the same amount and status.',
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: candidates
                      .map(
                        (p) => ListTile(
                          title: Text(p.description),
                          subtitle: Text(
                            '${shortDate(p.date)} · ${l.accountLabel(p.accountId)}',
                          ),
                          onTap: () => Navigator.pop(ctx, p),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Count these as one payment?'),
        content: Text(
          '${primary.description}\n${selected.description}\n\nKeep both source records, but count ${money(primary.amount.abs())} once. The first payment’s date and category will be used. You can undo this merge.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Merge records'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await l.reconcile('/api/merge', {
        'primaryId': primary.id,
        'secondaryId': selected.id,
      });
    }
  }
}
