import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'classification.dart';
import 'compat.dart';
import 'connections.dart';
import 'journal.dart';
import 'ledger_store.dart';
import 'migration.dart';
import 'paypal.dart';
import 'provider.dart';
import 'sync.dart';
import 'xlsx_import.dart';

class ServiceResponse {
  final int status;
  final Map<String, dynamic> data;
  ServiceResponse(this.status, this.data);
}

class MoneyTrackerService {
  final String dataPath;
  final Uint8List? encryptionKey;
  final BankApi? bankApi;
  final http.Client? httpClient;
  late Journal journal;
  late LedgerStore store;
  late Provider provider;
  late Connections connections;
  late BankSync banks;
  late Paypal paypal;
  late SpreadsheetImport spreadsheet;
  bool _writing = false;
  final state = <String, dynamic>{
    'syncing': false,
    'syncError': null,
    'syncProgress': null,
  };
  Future<void>? _job;
  MoneyTrackerService(
    this.dataPath, {
    this.encryptionKey,
    this.bankApi,
    this.httpClient,
  }) {
    _initialize();
  }
  void _initialize() {
    journal = Journal(dataPath, encryptionKey: encryptionKey);
    store = LedgerStore(journal);
    provider = Provider(journal, client: httpClient);
    final api = bankApi ?? provider.call;
    connections = Connections(store, api)
      ..busy = () => _writing || state['syncing'] == true;
    banks = BankSync(store, api);
    paypal = Paypal(store, api, provider.client);
    spreadsheet = SpreadsheetImport(store);
  }

  Future<void> start() async {
    await connections.startCallback();
  }

  Future<ServiceResponse> request(
    String method,
    String path, [
    Map<String, dynamic> body = const {},
  ]) async {
    try {
      if (method == 'GET') {
        if (path == '/api/ledger') {
          return ServiceResponse(200, {
            ...store.snapshot(client: true),
            ...state,
            'undoHistory': journal.status(),
          });
        }
        if (path == '/api/status') return ServiceResponse(200, {...state});
        if (path == '/api/setup') {
          return ServiceResponse(200, {
            'configured': provider.configured,
            'hasData': journal.file('ledger.json').existsSync(),
            'dataPath': dataPath,
            'callbackError': connections.callbackError,
          });
        }
        return ServiceResponse(404, {'error': 'Not found'});
      }
      if (method != 'POST') {
        return ServiceResponse(405, {'error': 'Unsupported method'});
      }
      final readOnly = {
        '/api/keepalive',
        '/api/paypal/review',
        '/api/rules/preview',
        '/api/connections/status',
        '/api/connections/banks',
      };
      if ((_writing ||
              state['syncing'] == true ||
              connections.callbackActive) &&
          !readOnly.contains(path)) {
        return ServiceResponse(409, {
          'error':
              'Wait for the current operation to finish before changing data or undoing',
        });
      }
      if (readOnly.contains(path)) {
        return ServiceResponse(200, await _read(path, body));
      }
      _writing = true;
      try {
        return await _mutate(path, body);
      } finally {
        _writing = false;
      }
    } on FormatException catch (e) {
      return ServiceResponse(400, {'error': e.message});
    } on TypeError {
      return ServiceResponse(400, {'error': 'Invalid request'});
    } on RangeError {
      return ServiceResponse(400, {'error': 'Invalid request'});
    } catch (e) {
      return ServiceResponse(502, {
        'error': e is StateError ? e.message : e.toString(),
      });
    }
  }

  Future<Map<String, dynamic>> _read(String path, Map body) async {
    switch (path) {
      case '/api/keepalive':
        return {'ok': true};
      case '/api/connections/banks':
        return {'banks': await connections.institutions(body['country'])};
      case '/api/connections/status':
        return connections.status(body['attempt']);
      case '/api/paypal/review':
        return paypal.review(
          query: body['query']?.toString() ?? '',
          observationId: body['observationId'],
        );
      case '/api/rules/preview':
        final config = store.taxonomy(),
            rule = validateRule(
              body['rule'],
              store.categoryIds,
              (config['tags'] as List).map((t) => t['id']).toSet(),
            )..['enabled'] = true;
        final current = store.snapshot(), ordered = maps(current['rules']);
        final index = ordered.indexWhere((r) => r['id'] == rule['id']),
            earlier = ordered.take(index < 0 ? ordered.length : index);
        return {
          'matches': [
            for (final row in current['transactions'])
              if (ruleMatches(rule, row, store.roots))
                {
                  'id': row['id'],
                  'description': row['description'],
                  'date': row['date'],
                  'amount': row['amount'],
                  'category': row['category'],
                  'blockedBy': rule['category'] == null
                      ? null
                      : row['reviewed'] == true
                      ? 'Manual category'
                      : earlier.any(
                          (r) =>
                              present(r['category']) &&
                              ruleMatches(r, row, store.roots),
                        )
                      ? 'Earlier rule'
                      : null,
                },
          ],
          'category': rule['category'],
        };
      default:
        invalid('Unknown request');
    }
  }

  Future<ServiceResponse> _mutate(
    String path,
    Map<String, dynamic> body,
  ) async {
    if (path == '/api/setup/credentials') {
      if (encryptionKey == null) {
        invalid(
          'An unlocked system credential store is required to save banking keys.',
        );
      }
      return ServiceResponse(
        200,
        await provider.saveCredentials(
          body['appId'] as String,
          body['pem'] as String,
        ),
      );
    }
    if (path == '/api/setup/import') {
      if (encryptionKey == null) {
        invalid(
          'Unlock the system credential store before importing banking connections.',
        );
      }
      if (journal.status()['count'] != 0 ||
          journal.file('ledger.json').existsSync()) {
        invalid('Import into a fresh installation before making changes.');
      }
      await connections.close();
      journal.close();
      Map<String, dynamic> result;
      try {
        result = await migrateLegacy(
          body['path'] as String,
          dataPath,
          encryptionKey!,
        );
      } finally {
        _initialize();
        await start();
      }
      return ServiceResponse(200, {'ok': true, ...result});
    }
    if (path == '/api/import/preview') {
      return ServiceResponse(
        200,
        spreadsheet.preview(
          body['path'] as String,
          body['accountId'] as String,
        ),
      );
    }
    if (path == '/api/import/apply') {
      return ServiceResponse(200, {
        'ok': true,
        ...await spreadsheet.apply(body['ticket'] as String),
        'undoHistory': journal.status(),
      });
    }
    if (path == '/api/connections/start') {
      return ServiceResponse(200, await connections.start(body));
    }
    if (path == '/api/undo' || path == '/api/redo') {
      journal.restore(redo: path == '/api/redo');
      return ServiceResponse(200, {
        'ok': true,
        'undoHistory': journal.status(),
      });
    }
    if ({'/api/sync', '/api/history', '/api/paypal/sync'}.contains(path)) {
      final years = path == '/api/history' ? body['years'] : null;
      if (path == '/api/history') historyStart(years);
      final target = path == '/api/paypal/sync'
          ? 'paypal'
          : body['target'] ?? 'banks';
      if (!{'banks', 'paypal', 'rates', 'accounts'}.contains(target)) {
        invalid('Unknown sync source');
      }
      final dateFrom = target == 'paypal'
          ? paypalStart(body['dateFrom'])
          : null;
      state.addAll({
        'syncing': true,
        'syncError': null,
        'syncProgress': 'Starting bank download…',
        if (target == 'accounts') 'accountRefresh': null,
      });
      // A fresh zone prevents request staging from leaking into the worker job.
      _job = _sync(years, target as String, body['accountId'], dateFrom);
      return ServiceResponse(202, {...state});
    }
    const labels = {
      '/api/connections/finish': 'Connect bank account',
      '/api/rules/save': 'Save classification rule',
      '/api/rules/delete': 'Delete classification rule',
      '/api/rules/move': 'Reorder classification rules',
      '/api/taxonomy': 'Edit categories and tags',
      '/api/tags': 'Edit payment tags',
      '/api/category': 'Change payment category',
      '/api/paypal/confirm': 'Confirm PayPal associations',
      '/api/merge': 'Merge payments',
      '/api/unmerge': 'Unmerge payments',
      '/api/profiles': 'Edit users and accounts',
      '/api/preferences': 'Change preferences',
    };
    if (!labels.containsKey(path)) {
      return ServiceResponse(404, {'error': 'Not found'});
    }
    final group = path == '/api/paypal/confirm' ? body['actionId'] : null;
    if (group != null &&
        (group is! String || group.isEmpty || group.length > 80)) {
      invalid('Invalid action ID');
    }
    final result = await journal.action(labels[path]!, () async {
      switch (path) {
        case '/api/connections/finish':
          return await connections.finish(body['callback']);
        case '/api/rules/save':
          final rule = validateRule(
            body['rule'],
            store.categoryIds,
            (store.taxonomy()['tags'] as List).map((t) => t['id']).toSet(),
          );
          var ordered = maps(store.read('rules.json', []));
          final index = ordered.indexWhere((r) => r['id'] == rule['id']);
          if (rule['kind'] == 'category') {
            ordered = saveCategory(ordered, rule);
          } else if (index < 0) {
            if (ordered.length >= 300) invalid('Too many rules');
            ordered.add(rule);
          } else {
            ordered[index] = rule;
          }
          await store.write('rules.json', ordered);
        case '/api/rules/delete':
          await store.write('rules.json', [
            for (final r in store.read('rules.json', []))
              if (r['id'] != body['id'] || r['kind'] == 'category')
                r['id'] == body['id'] && r['kind'] == 'category'
                    ? {...Map<String, dynamic>.from(r), 'groups': []}
                    : r,
          ]);
        case '/api/rules/move':
          final ordered = maps(store.read('rules.json', [])),
              index = ordered.indexWhere((r) => r['id'] == body['id']),
              delta = body['delta'];
          if (index < 0 ||
              delta is! int ||
              !{-1, 1}.contains(delta) ||
              index + delta < 0 ||
              index + delta >= ordered.length) {
            invalid('Invalid move');
          }
          final other = index + (delta), old = ordered[index];
          ordered[index] = ordered[other];
          ordered[other] = old;
          await store.write('rules.json', ordered);
        case '/api/taxonomy':
          await store.saveTaxonomy(body);
        case '/api/tags':
          final payments = (store.snapshot()['transactions'] as List)
                  .where((r) => r['id'] == body['id'])
                  .toList(),
              values = body['tags'],
              allowed = (store.taxonomy()['tags'] as List)
                  .map((t) => t['id'])
                  .toSet();
          if (payments.isEmpty ||
              values is! List ||
              values.any((t) => t is! String || !allowed.contains(t))) {
            invalid('Invalid tags');
          }
          final saved = store.read('tags.json', {});
          for (final id in [
            body['id'],
            ...store.read('merges.json', {})[body['id']] ?? [],
          ]) {
            saved[id] = [];
          }
          saved[body['id']] = (values).toSet().toList()..sort();
          await store.write('tags.json', saved);
        case '/api/category':
          final rows = (store.snapshot()['transactions'] as List)
                  .where((t) => t['id'] == body['id'])
                  .toList(),
              category = body['category'];
          if (rows.isEmpty || !store.categoryIds.contains(category)) {
            invalid('Invalid payment or category');
          }
          if ({'Salary', 'Other income'}.contains(store.roots[category]) &&
              rows.first['amount'] <= 0) {
            invalid('Income category requires an incoming payment');
          }
          final data = store.read('categories.json', {});
          data[body['id']] = category;
          await store.write('categories.json', data);
        case '/api/paypal/confirm':
          await paypal.confirm(body['pairs']);
        case '/api/merge':
          await store.merge(body['primaryId'], body['secondaryId']);
        case '/api/unmerge':
          await store.unmerge(body['id']);
        case '/api/profiles':
          final accounts = (store.snapshot()['accounts'] as List)
                  .map((a) => a['id'])
                  .toSet(),
              existing = store.read('profiles.json', {});
          final config = validateProfiles({
            ...body,
            'accountNicknames':
                body['accountNicknames'] ?? existing['accountNicknames'] ?? {},
          }, accounts);
          await store.write('profiles.json', config);
          final prefs = store.read('preferences.json', {'period': 'month'});
          if (!{
            'all',
            'unassigned',
            for (final u in config['users']) u['id'],
          }.contains(prefs['selectedUser'] ?? 'all')) {
            prefs['selectedUser'] = 'all';
            await store.write('preferences.json', prefs);
          }
        case '/api/preferences':
          final prefs = store.read('preferences.json', {'period': 'month'});
          if (body.containsKey('period') &&
              !{'month', 'salary'}.contains(body['period'])) {
            invalid('Invalid period');
          }
          if (body.containsKey('selectedUser') &&
              !{
                'all',
                'unassigned',
                for (final u in store.read('profiles.json', {
                  'users': [],
                })['users'])
                  u['id'],
              }.contains(body['selectedUser'])) {
            invalid('Invalid user');
          }
          for (final spec in [
            ('periodCount', 1, 24),
            ('undoLimit', 0, 10000),
          ]) {
            if (body.containsKey(spec.$1) &&
                (body[spec.$1] is! int ||
                    body[spec.$1] < spec.$2 ||
                    body[spec.$1] > spec.$3)) {
              invalid('Choose ${spec.$2} to ${spec.$3} for ${spec.$1}');
            }
          }
          if (body.containsKey('fxTolerancePercent') &&
              (body['fxTolerancePercent'] is! num ||
                  !body['fxTolerancePercent'].isFinite ||
                  body['fxTolerancePercent'] < 0 ||
                  body['fxTolerancePercent'] > 100)) {
            invalid('Choose a tolerance from 0 to 100 percent');
          }
          if (body.containsKey('monthlyAverage') &&
              body['monthlyAverage'] is! bool) {
            invalid('Invalid average setting');
          }
          for (final key in [
            'period',
            'selectedUser',
            'periodCount',
            'undoLimit',
            'fxTolerancePercent',
            'monthlyAverage',
          ]) {
            if (body.containsKey(key)) prefs[key] = body[key];
          }
          await store.write('preferences.json', prefs);
      }
      return <String, dynamic>{};
    }, group: group as String?);
    return ServiceResponse(200, {
      'ok': true,
      ...result,
      'undoHistory': journal.status(),
    });
  }

  Future<void> _sync(
    dynamic years,
    String target,
    dynamic accountId,
    String? dateFrom,
  ) async {
    void progress(String value) => state['syncProgress'] = value;
    try {
      final label = target == 'accounts'
          ? 'Refresh Enable Banking accounts'
          : target == 'rates'
          ? 'Download exchange rates'
          : target == 'paypal'
          ? 'Sync PayPal'
          : years != null
          ? 'Download bank history'
          : 'Sync bank accounts';
      await journal.action(label, () async {
        switch (target) {
          case 'accounts':
            state['accountRefresh'] = await connections.refresh(
              progress: progress,
            );
          case 'rates':
            await paypal.downloadRates(progress: progress);
          case 'paypal':
            await paypal.sync(dateFrom: dateFrom, progress: progress);
          default:
            await banks.sync(
              years: years,
              accountFilter: accountId,
              progress: progress,
            );
        }
      });
      state['syncError'] = null;
    } catch (e) {
      state['syncError'] = e is FormatException ? e.message : e.toString();
    } finally {
      state['syncing'] = false;
      state['syncProgress'] = null;
    }
  }

  Future<void> waitForSync() async => await _job;
  Future<void> close() async {
    await _job;
    await connections.close();
    provider.close();
    journal.close();
  }
}
