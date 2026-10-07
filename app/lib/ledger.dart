import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

const categories = [
  'Uncategorized',
  'Food',
  'Shopping',
  'Travel',
  'Transport',
  'Rent',
  'Bills',
  'Health',
  'Entertainment',
  'Other',
  'Salary',
  'Other income',
  'Transfer',
];
const months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
String money(int cents, {bool signed = false}) {
  final value = (cents.abs() / 100).toStringAsFixed(2).split('.');
  final whole = value[0].replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'),
    (m) => '${m[1]},',
  );
  return '${cents < 0
      ? '−'
      : signed && cents > 0
      ? '+'
      : ''}€$whole.${value[1]}';
}

String shortDate(DateTime date) =>
    '${date.day} ${months[date.month - 1].substring(0, 3)} ${date.year}';

class Payment {
  final String id, accountId, description, category, source, status;
  final int amount;
  final DateTime date;
  final bool reviewed;
  final List<dynamic> purchaseDetails;
  final List<Map<String, dynamic>> sourceRecords;
  final List<String> accountIds, tags;
  final bool merged;
  final String? ruleName;
  Payment.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      accountId = j['accountId'],
      description = j['description'],
      category = j['category'],
      source = j['source'],
      status = j['status'],
      amount = j['amount'],
      date = DateTime.parse(j['date']),
      reviewed = j['reviewed'],
      purchaseDetails = j['purchaseDetails'] ?? [],
      sourceRecords = (j['sourceRecords'] as List? ?? [])
          .cast<Map<String, dynamic>>(),
      accountIds = (j['accountIds'] as List? ?? [j['accountId']])
          .cast<String>(),
      merged = j['merged'] ?? false,
      ruleName = j['classificationRule']?['name'],
      tags = (j['tags'] as List? ?? []).cast<String>();
  bool get transfer => category == 'Transfer';
  bool get booked => status == 'BOOK';
}

int? parsePrice(String text) {
  final value = text.trim().replaceAll(',', '.');
  if (value.isEmpty) return null;
  if (!RegExp(r'^\d{1,12}(\.\d{0,2})?$').hasMatch(value)) {
    throw const FormatException(
      'Enter a positive amount with up to 2 decimal places.',
    );
  }
  final parts = value.split('.');
  return int.parse(parts.first) * 100 +
      (parts.length == 1 ? 0 : int.parse(parts.last.padRight(2, '0')));
}

class Ledger extends ChangeNotifier {
  final http.Client client;
  final bool desktop;
  final DateTime Function() clock;
  Ledger({
    http.Client? client,
    DateTime Function()? clock,
    this.desktop = false,
  }) : client = client ?? http.Client(),
       clock = clock ?? DateTime.now {
    month = DateTime(this.clock().year, this.clock().month);
  }
  List<Payment> payments = [];
  List<Map<String, dynamic>> accounts = [];
  List<Map<String, dynamic>> users = [];
  Map<String, dynamic> accountUsers = {};
  Map<String, dynamic> accountNicknames = {};
  String selectedUser = 'all';
  String? undoLabel, redoLabel;
  bool undoSupported = false;
  int undoRevision = 0;
  int undoLimit = 100;
  List<Map<String, dynamic>> categorySettings = [
    for (final c in categories) {'id': c, 'name': c, 'parent': null},
  ];
  List<Map<String, dynamic>> tagSettings = [];
  String tag = 'all';
  String paymentSort = 'date_desc';
  int? minimumAmount, maximumAmount;
  late DateTime month;
  int salaryIndex = 0;
  int periodCount = 1;
  bool monthlyAverage = false;
  double fxTolerancePercent = 10;
  String? historyFrom, syncProgress;
  Map<String, dynamic>? historyImport;
  List<Map<String, dynamic>> rules = [];
  String period = 'month',
      query = '',
      account = 'all',
      category = 'all',
      direction = 'all';
  bool loading = true, syncing = false, saving = false;
  String? error, syncedAt;
  Map<String, dynamic>? accountRefresh;
  Timer? _poll;
  bool _disposed = false;
  static const base = String.fromEnvironment('API_BASE');
  static const token = String.fromEnvironment('API_TOKEN');
  Uri uri(String path) => base.isEmpty && kIsWeb
      ? Uri.base.resolve(path)
      : Uri.parse('${base.isEmpty ? 'http://localhost:8765' : base}$path');
  Map<String, String> get headers => {
    'Content-Type': 'application/json',
    if (token.isNotEmpty) 'Authorization': 'Bearer $token',
  };
  void changed() {
    if (!_disposed) notifyListeners();
  }

  void ingest(Map<String, dynamic> data) {
    accountRefresh = data['accountRefresh'] as Map<String, dynamic>?;
    undoSupported = data.containsKey('undoHistory');
    undoLimit = data['preferences']?['undoLimit'] ?? 100;
    undoLabel = data['undoHistory']?['undo'];
    redoLabel = data['undoHistory']?['redo'];
    _searchText = Expando<String>();
    payments = (data['transactions'] as List)
        .map((j) => Payment.fromJson(j))
        .toList();
    accounts = (data['accounts'] as List).cast<Map<String, dynamic>>();
    users = (data['profiles']?['users'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    accountUsers = Map<String, dynamic>.from(
      data['profiles']?['accountUsers'] ?? {},
    );
    accountNicknames = Map<String, dynamic>.from(
      data['profiles']?['accountNicknames'] ?? {},
    );
    selectedUser = data['preferences']?['selectedUser'] ?? 'all';
    if (![
      'all',
      'unassigned',
      ...users.map((u) => u['id']),
    ].contains(selectedUser)) {
      selectedUser = 'all';
    }
    if (!userAccounts.any((a) => a['id'] == account)) account = 'all';
    rules = (data['rules'] as List? ?? []).cast<Map<String, dynamic>>();
    period = data['preferences']?['period'] ?? 'month';
    syncedAt = data['syncedAt'];
    historyFrom = data['historyFrom'];
    historyImport = data['historyImport'];
    if (data['taxonomy'] != null) {
      categorySettings = (data['taxonomy']['categories'] as List)
          .cast<Map<String, dynamic>>();
      tagSettings = (data['taxonomy']['tags'] as List)
          .cast<Map<String, dynamic>>();
      if (!categoryIds.contains(category)) category = 'all';
      if (!tagSettings.any((t) => t['id'] == tag)) tag = 'all';
    }
    salaryIndex = salaryIndex.clamp(
      0,
      salaryDates.isEmpty ? 0 : salaryDates.length - 1,
    );
    syncProgress = data['syncProgress'];
    periodCount = ((data['preferences']?['periodCount'] ?? 1) as int).clamp(
      1,
      24,
    );
    monthlyAverage = data['preferences']?['monthlyAverage'] ?? false;
    fxTolerancePercent = (data['preferences']?['fxTolerancePercent'] ?? 10)
        .toDouble();
    syncing = data['syncing'] ?? false;
    error = data['syncError'];
    loading = false;
  }

  Future<void> _pollSync() async {
    if (_disposed) return;
    try {
      final response = await client
          .get(uri('/api/status'), headers: headers)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw Exception('Status unavailable');
      final status = jsonDecode(response.body) as Map<String, dynamic>;
      if (status['syncing'] != true) {
        await load();
        return;
      }
      syncProgress = status['syncProgress'];
      changed();
      if (!_disposed) _poll = Timer(const Duration(seconds: 3), _pollSync);
    } catch (_) {
      await load();
    }
  }

  Future<void> load() async {
    if (_disposed) return;
    _poll?.cancel();
    try {
      final r = await client
          .get(uri('/api/ledger'), headers: headers)
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        throw Exception(
          jsonDecode(r.body)['error'] ??
              'Cannot load payments (${r.statusCode}).',
        );
      }
      if (_disposed) return;
      ingest(jsonDecode(r.body));
      if (syncing) {
        _poll?.cancel();
        _poll = Timer(const Duration(seconds: 3), _pollSync);
      }
    } catch (e) {
      error = desktop
          ? 'Could not load local payments: $e'
          : 'Could not reach the local bank service. Your saved data has not been changed.';
      loading = false;
      syncing = false;
    }
    changed();
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final r = await client
        .post(uri(path), headers: headers, body: jsonEncode(body))
        .timeout(
          Duration(
            seconds:
                path.startsWith('/api/connections/') ||
                    path.startsWith('/api/setup/') ||
                    path.startsWith('/api/import/')
                ? 120
                : 20,
          ),
        );
    if (r.statusCode >= 300) {
      throw Exception(jsonDecode(r.body)['error'] ?? 'Save failed');
    }
    final result = jsonDecode(r.body) as Map<String, dynamic>;
    if (result.containsKey('undoHistory')) {
      undoLabel = result['undoHistory']['undo'];
      redoLabel = result['undoHistory']['redo'];
      undoSupported = true;
    }
    return result;
  }

  Future<void> restoreHistory(bool redo) async {
    if (saving || syncing) return;
    saving = true;
    changed();
    try {
      await post(redo ? '/api/redo' : '/api/undo', {});
      account = 'all';
      category = 'all';
      tag = 'all';
      query = '';
      await load();
      undoRevision++;
    } catch (e) {
      error = 'Could not ${redo ? 'redo' : 'undo'}: $e';
    }
    saving = false;
    changed();
  }

  Future<void> updateRule(String action, Map<String, dynamic> body) async {
    await post('/api/rules/$action', body);
    await load();
  }

  Future<void> setPeriod(String value) async {
    saving = true;
    changed();
    try {
      await post('/api/preferences', {'period': value});
      period = value;
      error = null;
    } catch (e) {
      error = 'Could not save preference: $e';
    }
    saving = false;
    changed();
  }

  List<String> get categoryIds =>
      categorySettings.map((c) => c['id'] as String).toList();
  String categoryName(String id) => categorySettings.firstWhere(
    (c) => c['id'] == id,
    orElse: () => {'name': id},
  )['name'];
  String mainCategory(String id) {
    if (!identical(_taxonomyKey, categorySettings)) {
      _taxonomyKey = categorySettings;
      _roots = {
        for (final c in categorySettings)
          c['id'] as String: (c['parent'] ?? c['id']) as String,
      };
    }
    return _roots[id] ?? id;
  }

  String categoryLabel(String id) => mainCategory(id) == id
      ? categoryName(id)
      : '${categoryName(mainCategory(id))} / ${categoryName(id)}';
  String tagName(String id) => tagSettings.firstWhere(
    (t) => t['id'] == id,
    orElse: () => {'name': id},
  )['name'];
  Future<void> saveTaxonomy(Map<String, dynamic> config) async {
    await post('/api/taxonomy', config);
    await load();
  }

  Future<void> saveTags(Payment p, List<String> tags) async {
    await post('/api/tags', {'id': p.id, 'tags': tags});
    await load();
  }

  Future<void> setRange({int? count, bool? average}) async {
    saving = true;
    changed();
    try {
      final preferences = <String, dynamic>{};
      if (count != null) preferences['periodCount'] = count;
      if (average != null) preferences['monthlyAverage'] = average;
      await post('/api/preferences', preferences);
      if (count != null) {
        periodCount = count;
        salaryIndex = 0;
      }
      if (average != null) monthlyAverage = average;
      error = null;
    } catch (e) {
      error = 'Could not save range: $e';
    }
    saving = false;
    changed();
  }

  Future<bool> categorize(Payment p, String value) async {
    saving = true;
    changed();
    try {
      await post('/api/category', {'id': p.id, 'category': value});
      await load();
      saving = false;
      changed();
      return true;
    } catch (e) {
      error = 'Could not save category: $e';
      saving = false;
      changed();
      return false;
    }
  }

  Future<bool> reconcile(String path, Map<String, dynamic> data) async {
    try {
      await post(path, data);
      await load();
      return true;
    } catch (e) {
      error = 'Could not update linked records: $e';
      changed();
      return false;
    }
  }

  Future<void> sync({
    int? years,
    String target = 'banks',
    String? dateFrom,
    String? accountId,
  }) async {
    if (syncing) return;
    syncing = true;
    error = null;
    changed();
    try {
      await post(
        target == 'paypal'
            ? '/api/paypal/sync'
            : years == null
            ? '/api/sync'
            : '/api/history',
        years == null
            ? {'target': target, 'accountId': ?accountId, 'dateFrom': ?dateFrom}
            : {'years': years},
      );
      await load();
    } catch (e) {
      syncing = false;
      error =
          'Sync failed: $e. Your previous import is still available. If the endpoint was not found, restart the MoneyTracker server.';
      changed();
    }
  }

  void filter({
    String? search,
    String? accountId,
    String? categoryName,
    String? flow,
  }) {
    if (search != null) query = search;
    if (accountId != null) {
      account = accountId;
      salaryIndex = 0;
    }
    if (categoryName != null) category = categoryName;
    if (flow != null) direction = flow;
    changed();
  }

  List<Map<String, dynamic>> get userAccounts => accounts
      .where(
        (a) =>
            selectedUser == 'all' ||
            (selectedUser == 'unassigned'
                ? !accountUsers.containsKey(a['id'])
                : accountUsers[a['id']] == selectedUser),
      )
      .toList();
  // Collection snapshots are replaced by ingest; scalar filters form cache keys.
  // Search, table filters and saving notifications do not invalidate aggregates.
  Object? _selectionKey, _summaryKey, _visibleKey, _taxonomyKey;
  List<Payment> _selected = [], _scoped = [], _visible = [];
  List<DateTime> _salaryDates = [];
  Map<String, String> _roots = {};
  Map<String, int> _totals = {}, _directTotals = {};
  int _spent = 0, _income = 0, _selectionVersion = 0;
  Expando<String> _searchText = Expando<String>();
  @visibleForTesting
  int selectionPasses = 0, summaryPasses = 0, visiblePasses = 0;

  void _ensureSelection() {
    final now = clock();
    final today = DateTime(now.year, now.month, now.day);
    final key = (
      payments,
      accounts,
      accountUsers,
      categorySettings,
      selectedUser,
      account,
      today,
    );
    if (_selectionKey == key) return;
    _selectionKey = key;
    _selectionVersion++;
    selectionPasses++;
    final ids = userAccounts.map((a) => a['id']).toSet();
    _selected =
        payments
            .where(
              (p) => p.accountIds.any(
                (id) => ids.contains(id) && (account == 'all' || account == id),
              ),
            )
            .toList()
          ..sort((a, b) => b.date.compareTo(a.date));
    _salaryDates =
        _selected
            .where(
              (p) =>
                  p.booked &&
                  (p.reviewed || p.ruleName != null) &&
                  p.amount > 0 &&
                  mainCategory(p.category) == 'Salary' &&
                  !p.date.isAfter(today),
            )
            .map((p) => DateTime(p.date.year, p.date.month, p.date.day))
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));
  }

  bool includesPayment(Payment p) {
    final ids = userAccounts.map((a) => a['id']).toSet();
    return p.accountIds.any(
      (id) => ids.contains(id) && (account == 'all' || account == id),
    );
  }

  void _ensureSummary() {
    _ensureSelection();
    final key = (_selectionVersion, period, month, salaryIndex, periodCount);
    if (_summaryKey == key) return;
    _summaryKey = key;
    summaryPasses++;
    final from = start, until = end;
    final rows = <Payment>[];
    final totals = <String, int>{};
    final directTotals = <String, int>{};
    _spent = 0;
    _income = 0;
    if (from != null) {
      for (final p in _selected) {
        if (p.date.isBefore(from) || !p.date.isBefore(until)) continue;
        rows.add(p);
        final main = mainCategory(p.category);
        if (!p.booked || main == 'Transfer') continue;
        if (p.amount < 0) {
          _spent -= p.amount;
          directTotals[p.category] = (directTotals[p.category] ?? 0) - p.amount;
          totals[main] = (totals[main] ?? 0) - p.amount;
        } else {
          _income += p.amount;
        }
      }
    }
    _directTotals = Map.unmodifiable(directTotals);
    _scoped = List.unmodifiable(rows);
    _totals = Map.unmodifiable(
      Map.fromEntries(
        totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value)),
      ),
    );
  }

  Future<void> selectUser(String id) async {
    saving = true;
    changed();
    try {
      await post('/api/preferences', {'selectedUser': id});
      selectedUser = id;
      account = 'all';
      salaryIndex = 0;
      error = null;
    } catch (e) {
      error = 'Could not select user: $e';
    }
    saving = false;
    changed();
  }

  Future<void> saveProfiles(Map<String, dynamic> config) async {
    await post('/api/profiles', config);
    salaryIndex = 0;
    await load();
  }

  void moveMonth(int n) {
    month = DateTime(month.year, month.month + n);
    changed();
  }

  List<DateTime> get salaryDates {
    _ensureSelection();
    return _salaryDates;
  }

  DateTime? get lastSalary => salaryDates.isEmpty ? null : salaryDates.first;
  int get selectedSalaryIndex =>
      salaryIndex.clamp(0, salaryDates.isEmpty ? 0 : salaryDates.length - 1);
  bool get canPreviousSalary =>
      selectedSalaryIndex + effectiveCount < salaryDates.length;
  bool get canNextSalary => selectedSalaryIndex > 0;
  void moveSalary(int delta) {
    salaryIndex = (selectedSalaryIndex + delta).clamp(
      0,
      salaryDates.isEmpty ? 0 : salaryDates.length - 1,
    );
    changed();
  }

  int get effectiveCount => period == 'month'
      ? periodCount
      : (salaryDates.length - selectedSalaryIndex).clamp(0, periodCount);
  DateTime? get start => period == 'salary'
      ? (salaryDates.isEmpty
            ? null
            : salaryDates[selectedSalaryIndex + effectiveCount - 1])
      : DateTime(month.year, month.month - periodCount + 1);
  DateTime get end => period == 'salary'
      ? (selectedSalaryIndex > 0
            ? salaryDates[selectedSalaryIndex - 1]
            : DateTime(clock().year, clock().month, clock().day + 1))
      : DateTime(month.year, month.month + 1);
  // Calendar-month equivalents: a partial month contributes covered days / days in that month.
  double get monthDivisor {
    if (period == 'month') return periodCount.toDouble();
    if (start == null) return 1;
    var cursor = DateTime.utc(start!.year, start!.month, start!.day);
    final stop = DateTime.utc(end.year, end.month, end.day);
    var result = 0.0;
    while (cursor.isBefore(stop)) {
      final next = DateTime.utc(cursor.year, cursor.month + 1);
      final upper = next.isBefore(stop) ? next : stop;
      result +=
          upper.difference(cursor).inDays /
          DateTime.utc(cursor.year, cursor.month + 1, 0).day;
      cursor = upper;
    }
    return result > 0 ? result : 1;
  }

  bool get showAverage => monthlyAverage && effectiveCount > 1;
  int displayAmount(int cents) =>
      showAverage ? (cents / monthDivisor).round() : cents;
  bool get incompleteHistory =>
      start != null &&
      historyFrom != null &&
      start!.isBefore(DateTime.parse(historyFrom!));

  List<Payment> get scoped {
    _ensureSummary();
    return _scoped;
  }

  List<Payment> get visible {
    _ensureSummary();
    final key = (
      _summaryKey,
      category,
      tag,
      direction,
      query,
      tagSettings,
      paymentSort,
      minimumAmount,
      maximumAmount,
    );
    if (_visibleKey == key) return _visible;
    _visibleKey = key;
    visiblePasses++;
    final search = query.toLowerCase();
    final candidates = period == 'salary' && _salaryDates.isEmpty
        ? _selected.where((p) => p.amount > 0)
        : _scoped;
    final rows = candidates
        .where(
          (p) =>
              (category == 'all' ||
                  p.category == category ||
                  mainCategory(p.category) == category) &&
              (tag == 'all' || p.tags.contains(tag)) &&
              (minimumAmount == null || p.amount.abs() >= minimumAmount!) &&
              (maximumAmount == null || p.amount.abs() <= maximumAmount!) &&
              (direction == 'all' ||
                  (direction == 'income' ? p.amount > 0 : p.amount < 0)) &&
              (search.isEmpty ||
                  (_searchText[p] ??= [
                    p.description,
                    ...p.sourceRecords.map((r) => r['description'] ?? ''),
                    ...p.tags.map((t) => '#${tagName(t)}'),
                  ].join(' ').toLowerCase()).contains(search)),
        )
        .toList();
    // Sort all matching payments before the view takes its display limit.
    rows.sort((a, b) {
      final primary = switch (paymentSort) {
        'date_asc' => a.date.compareTo(b.date),
        'amount_desc' => b.amount.abs().compareTo(a.amount.abs()),
        'amount_asc' => a.amount.abs().compareTo(b.amount.abs()),
        'name_asc' => a.description.toLowerCase().compareTo(
          b.description.toLowerCase(),
        ),
        'name_desc' => b.description.toLowerCase().compareTo(
          a.description.toLowerCase(),
        ),
        _ => b.date.compareTo(a.date),
      };
      if (primary != 0) return primary;
      final dateOrder = b.date.compareTo(a.date);
      return dateOrder != 0 ? dateOrder : a.id.compareTo(b.id);
    });
    _visible = List.unmodifiable(rows);
    return _visible;
  }

  int get spent {
    _ensureSummary();
    return _spent;
  }

  int get income {
    _ensureSummary();
    return _income;
  }

  Map<String, int> get directCategoryTotals {
    _ensureSummary();
    return _directTotals;
  }

  Map<String, int> get totals {
    _ensureSummary();
    return _totals;
  }

  String accountLabel(String id) =>
      (accountNicknames[id] as String?) ??
      accounts.firstWhere(
        (a) => a['id'] == id,
        orElse: () => {'label': 'Account'},
      )['label'];
  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    client.close();
    super.dispose();
  }
}
