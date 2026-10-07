import 'dart:io';
import 'package:basic_utils/basic_utils.dart';
import 'classification.dart';
import 'compat.dart';
import 'ledger_store.dart';
import 'provider.dart';

class Connections {
  final LedgerStore store;
  final BankApi api;
  HttpServer? callbackServer;
  String? callbackError;
  bool callbackActive = false;
  bool Function() busy = () => false;
  Connections(this.store, this.api);
  Future<List<Map<String, dynamic>>> institutions(dynamic country) async {
    if (country is! String || !RegExp(r'^[a-zA-Z]{2}$').hasMatch(country)) {
      invalid('Choose a two-letter country code');
    }
    final data = await api('/aspsps?country=${(country).toUpperCase()}');
    return [
      for (final b in data['aspsps'])
        if ((b['psu_types'] ?? ['personal']).contains('personal'))
          {'name': b['name'], 'country': b['country']},
    ];
  }

  Future<Map<String, dynamic>> start(Map body) async {
    if (callbackError != null) invalid(callbackError!);
    final country = body['country'], name = body['name'];
    if (country is! String ||
        !RegExp(r'^[a-zA-Z]{2}$').hasMatch(country) ||
        name is! String) {
      invalid('Choose a bank and country');
    }
    final response = await api('/aspsps?country=${(country).toUpperCase()}');
    final banks = (response['aspsps'] as List)
        .where(
          (b) =>
              b['name'] == name &&
              (b['psu_types'] ?? ['personal']).contains('personal'),
        )
        .toList();
    if (banks.isEmpty) invalid('Bank is not available for personal accounts');
    if (!((await api('/application'))['redirect_urls'] as List).contains(
      callbackUrl,
    )) {
      invalid(
        'Register $callbackUrl as a redirect URL in Enable Banking first',
      );
    }
    final state = randomToken(32),
        attempt = randomToken(24),
        validity = (banks.first['maximum_consent_validity'] as num)
            .toInt()
            .clamp(0, 90 * 86400);
    final request = <String, dynamic>{
      'aspsp': {'name': name, 'country': country.toUpperCase()},
      'state': state,
      'redirect_url': callbackUrl,
      'psu_type': 'personal',
      'access': {
        'valid_until': DateTime.now()
            .toUtc()
            .add(Duration(seconds: validity))
            .toIso8601String(),
      },
    };
    final auth = await api('/auth', request);
    final url = Uri.tryParse(auth['url'] as String? ?? '');
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      invalid('Enable Banking returned an invalid authorization link');
    }
    await store.write('connection-pending.json', {
      'state': state,
      'created': DateTime.now().millisecondsSinceEpoch / 1000,
      'aspsp': request['aspsp'],
      'redirect': callbackUrl,
      'attempt': attempt,
    });
    return {'url': url.toString(), 'attempt': attempt};
  }

  Future<Map<String, dynamic>> finish(
    dynamic callback, {
    bool automatic = false,
  }) async {
    final pending = store.read('connection-pending.json', {});
    if ((pending as Map).isEmpty ||
        DateTime.now().millisecondsSinceEpoch / 1000 - pending['created'] >
            3600 ||
        pending['completing'] == true) {
      invalid('Authorization expired. Start again.');
    }
    if (callback is! String) invalid('Paste the callback URL');
    final uri = Uri.tryParse((callback).trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.authority != 'localhost:8443' ||
        uri.path != '/callback') {
      invalid('Paste the final $callbackUrl URL');
    }
    if (!_constantEqual(
      uri.queryParameters['state'] ?? '',
      pending['state'] ?? '',
    )) {
      invalid(
        'Authorization state mismatch. Use the most recent authorization link.',
      );
    }
    if (uri.queryParameters.containsKey('error') ||
        !present(uri.queryParameters['code'])) {
      invalid('Bank authorization was not completed');
    }
    // Mark the attempt before exchanging a one-time code to exclude callback replays.
    await store.write('connection-pending.json', {
      ...pending,
      'completing': true,
    });
    final session = await api('/sessions', {
      'code': uri.queryParameters['code'],
    });
    if ([
      'name',
      'country',
    ].any((k) => session['aspsp']?[k] != pending['aspsp'][k])) {
      invalid('Bank authorization returned an unexpected institution');
    }
    if (!present(session['accounts'])) {
      invalid(
        'No accessible accounts returned. Link this account in the Enable Banking control panel first, then authorize again.',
      );
    }
    final ledger = store.read('ledger.json', {
          'accounts': [],
          'transactions': [],
        }),
        known = {for (final a in ledger['accounts']) a['id']: a};
    final source = sourceName(session);
    var added = 0, index = 0;
    for (final account in session['accounts']) {
      index++;
      final id = source == 'PayPal'
          ? paypalAccountId(account)
          : stableAccountId(account, source);
      if (!known.containsKey(id)) added++;
      final kind = source == 'PayPal'
              ? 'PAYPAL'
              : account['cash_account_type'] ?? '',
          iban = account['account_id']?['iban'] ?? '';
      final label =
          (source == 'PayPal'
              ? 'PayPal'
              : kind == 'CARD'
              ? 'Card'
              : 'Current account') +
          (iban.isNotEmpty
              ? ' ··${iban.substring(iban.length - 4)}'
              : ' $index');
      known[id] = {
        ...known[id] ?? {},
        'id': id,
        'source': source,
        'kind': kind,
        'label': label,
        'balance': known[id]?['balance'],
      };
    }
    // Validate all account identities before saving credentials.
    if (source == 'PayPal') {
      await store.write('session-paypal.json', session);
    } else {
      final saved = store.read('bank-sessions.json', []);
      saved.add(session);
      await store.write('bank-sessions.json', saved);
    }
    ledger['accounts'] = known.values.toList();
    await store.write('ledger.json', ledger);
    await store.write(
      'connection-pending.json',
      automatic
          ? {
              'attempt': pending['attempt'],
              'created': pending['created'],
              'completing': true,
            }
          : {},
    );
    return {
      'added': added,
      'message':
          '$source connected. $added new account(s) added. Use Sync to download transactions.',
    };
  }

  Map<String, dynamic> status(dynamic attempt) {
    if (attempt is! String || attempt.isEmpty) {
      invalid('Missing authorization attempt');
    }
    final result = Map<String, dynamic>.from(
      store.read('connection-result.json', {}),
    );
    if (result['attempt'] == attempt) {
      result.remove('attempt');
      return result;
    }
    final pending = store.read('connection-pending.json', {});
    if (pending['attempt'] != attempt) {
      return {
        'status': 'error',
        'message': 'This authorization was replaced. Start again.',
      };
    }
    if (DateTime.now().millisecondsSinceEpoch / 1000 - pending['created'] >
        3600) {
      return {
        'status': 'error',
        'message': 'Authorization expired. Start again.',
      };
    }
    return {'status': 'pending'};
  }

  Future<Map<String, dynamic>> completeCallback(String callback) async {
    if (busy()) {
      invalid(
        'Wait for the current operation to finish, then paste the callback URL in MoneyTracker.',
      );
    }
    final pending = store.read('connection-pending.json', {}),
        state = Uri.parse(callback).queryParameters['state'] ?? '';
    if (!present(pending['state']) ||
        pending['completing'] == true ||
        !_constantEqual(state, pending['state'])) {
      invalid(
        'Invalid or already completed authorization. Return to MoneyTracker.',
      );
    }
    callbackActive = true;
    try {
      final result = await store.journal.action(
        'Connect bank account',
        () => finish(callback, automatic: true),
      );
      await store.write('connection-result.json', {
        'attempt': pending['attempt'],
        'status': 'complete',
        ...result,
      });
      return result;
    } catch (e) {
      final message = e is FormatException
          ? e.message
          : 'Bank authorization could not be completed. Please start again.';
      await store.write('connection-result.json', {
        'attempt': pending['attempt'],
        'status': 'error',
        'message': message,
      });
      throw FormatException(message);
    } finally {
      callbackActive = false;
    }
  }

  Future<Map<String, dynamic>> refresh({
    void Function(String)? progress,
  }) async {
    final ledger = store.read('ledger.json', {
          'accounts': [],
          'transactions': [],
        }),
        known = {for (final a in ledger['accounts']) a['id']: a};
    final extra = store.read('bank-sessions.json', []),
        entries = <MapEntry<dynamic, dynamic>>[
          for (final name in ['session.json', 'session-paypal.json'])
            MapEntry(name, store.read(name, {})),
          for (var i = 0; i < extra.length; i++) MapEntry(i, extra[i]),
        ];
    final seen = <dynamic>{}, active = <MapEntry<dynamic, dynamic>>[];
    for (final e in entries.reversed) {
      final source = sourceName(e.value),
          identities = {
            for (final a in e.value['accounts'] ?? [])
              source == 'PayPal'
                  ? paypalAccountId(a)
                  : stableAccountId(a, source),
          };
      if (identities.isNotEmpty && seen.containsAll(identities)) continue;
      seen.addAll(identities);
      active.add(e);
    }
    var added = 0, checked = 0;
    final warnings = <String>[];
    for (final e in active.reversed) {
      final session = e.value, source = sourceName(session);
      if (!present(session['session_id'])) continue;
      progress?.call('Checking $source accounts…');
      try {
        final remote = await api(
          '/sessions/${Uri.encodeComponent(session['session_id'])}',
        );
        if (remote['status'] != 'AUTHORIZED') {
          invalid(
            'Authorization has expired or is inactive. Authorize this connection again.',
          );
        }
        final old = {for (final a in session['accounts'] ?? []) a['uid']: a},
            accounts = <dynamic>[];
        for (final item in remote['accounts_data']) {
          final account = <String, dynamic>{
            ...old[item['uid']] ?? {},
            ...Map<String, dynamic>.from(item),
          };
          if (!old.containsKey(item['uid'])) {
            account.addAll({
              ...await api(
                '/accounts/${Uri.encodeComponent(item['uid'])}/details',
              ),
              ...Map<String, dynamic>.from(item),
            });
          }
          accounts.add(account);
        }
        final updated = {
              ...Map<String, dynamic>.from(session),
              'accounts': accounts,
              'access': remote['access'] ?? session['access'],
            },
            fresh = <dynamic>[];
        var index = 0;
        for (final a in accounts) {
          index++;
          final id = source == 'PayPal'
                  ? paypalAccountId(a)
                  : stableAccountId(a, source),
              kind = source == 'PayPal'
                  ? 'PAYPAL'
                  : a['cash_account_type'] ?? '',
              iban = a['account_id']?['iban'] ?? '';
          final label =
              (source == 'PayPal'
                  ? 'PayPal'
                  : kind == 'CARD'
                  ? 'Card'
                  : 'Current account') +
              (iban.isNotEmpty
                  ? ' ··${iban.substring(iban.length - 4)}'
                  : source == 'PayPal'
                  ? ''
                  : ' $index');
          fresh.add({
            'id': id,
            'label': label,
            'source': source,
            'kind': kind,
            'balance': known[id]?['balance'],
          });
        }
        if (e.key is int) {
          extra[e.key] = updated;
          await store.write('bank-sessions.json', extra);
        } else {
          await store.write(e.key as String, updated);
        }
        for (final entry in fresh) {
          if (!known.containsKey(entry['id'])) added++;
          known[entry['id']] = {
            ...known[entry['id']] ?? {},
            ...Map<String, dynamic>.from(entry),
          };
        }
        checked++;
      } catch (e) {
        warnings.add('$source: $e');
      }
    }
    ledger['accounts'] = known.values.toList();
    await store.write('ledger.json', ledger);
    return {
      'added': added,
      'checked': checked,
      'warnings': warnings,
      'message':
          '$added new account(s) found. Accounts linked only in the Enable Banking control panel need a separate bank authorization in MoneyTracker.',
    };
  }

  Future<void> startCallback({int port = 8443}) async {
    try {
      final certFile = store.journal.file('callback-cert.pem'),
          keyData = store.read('callback-key.json', {});
      String? key = keyData['pem'],
          cert = certFile.existsSync() ? certFile.readAsStringSync() : null;
      var regenerate = key == null || cert == null;
      if (!regenerate) {
        try {
          regenerate = X509Utils.x509CertificateFromPem(cert)
              .tbsCertificate!
              .validity
              .notAfter
              .isBefore(DateTime.now().add(const Duration(days: 7)));
        } catch (_) {
          regenerate = true;
        }
      }
      if (regenerate) {
        final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048),
            privateKey = pair.privateKey as RSAPrivateKey,
            publicKey = pair.publicKey as RSAPublicKey;
        key = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);
        final csr = X509Utils.generateRsaCsrPem(
          {'CN': 'localhost'},
          privateKey,
          publicKey,
          san: ['localhost'],
        );
        cert = X509Utils.generateSelfSignedCertificate(
          privateKey,
          csr,
          365,
          sans: ['localhost'],
          notBefore: DateTime.now().subtract(const Duration(minutes: 5)),
        );
        await store.write('callback-key.json', {'pem': key});
        store.journal.atomic('callback-cert.pem', cert.codeUnits);
      }
      final context = SecurityContext()
        ..useCertificateChainBytes(cert!.codeUnits)
        ..usePrivateKeyBytes(key!.codeUnits)
        ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2;
      callbackServer = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        port,
        context,
        shared: false,
      );
      final boundPort = callbackServer!.port;
      callbackServer!.listen((request) async {
        final response = request.response;
        response.headers.set('Cache-Control', 'no-store');
        response.headers.set('Referrer-Policy', 'no-referrer');
        response.headers.set(
          'Content-Security-Policy',
          "default-src 'none'; frame-ancestors 'none'",
        );
        response.headers.contentType = ContentType.html;
        var message = 'Return to MoneyTracker to continue.';
        if (request.method != 'GET' ||
            request.headers.value('host') != 'localhost:$boundPort' ||
            request.uri.path != '/callback') {
          response.statusCode = 400;
          message = 'Invalid callback.';
        } else {
          try {
            final result = await completeCallback(
              'https://localhost:$boundPort${request.uri}',
            );
            message = '${result['message']} Return to MoneyTracker.';
          } catch (e) {
            response.statusCode = 400;
            message = e is FormatException
                ? e.message
                : 'Authorization could not be completed. Return to MoneyTracker.';
          }
        }
        response.write(
          '<!doctype html><html><head><title>MoneyTracker</title></head><body><h1>MoneyTracker</h1><p>${message.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')}</p></body></html>',
        );
        await response.close();
      });
    } catch (_) {
      callbackError =
          'The local HTTPS callback could not start on port $port. Close any other MoneyTracker copy or service using that port and reopen the app. You can still view your saved payments.';
    }
  }

  Future<void> close() async => callbackServer?.close(force: true);
}

bool _constantEqual(String a, String b) {
  var difference = a.length ^ b.length;
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    difference |=
        (i < a.length ? a.codeUnitAt(i) : 0) ^
        (i < b.length ? b.codeUnitAt(i) : 0);
  }
  return difference == 0;
}
