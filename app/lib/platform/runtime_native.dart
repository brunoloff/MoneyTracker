import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:money_tracker_core/money_tracker_core.dart';
import 'runtime_types.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import '../testing_help.dart';

Future<AppRuntime> createRuntime() async {
  final override = Platform.environment['MONEYTRACKER_DATA_DIR'];
  final path =
      override ??
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}data';
  const vault = FlutterSecureStorage();
  final vaultName =
      'moneytracker.master.${base64Url.encode(utf8.encode(path))}';
  Uint8List key;
  try {
    var value = await vault.read(key: vaultName);
    if (value == null) {
      value = base64Encode(
        List.generate(32, (_) => Random.secure().nextInt(256)),
      );
      await vault.write(key: vaultName, value: value);
      if (await vault.read(key: vaultName) != value) {
        throw StateError('Credential store did not retain the key');
      }
    }
    key = base64Decode(value);
  } catch (_) {
    throw StateError(credentialStoreGuidance(defaultTargetPlatform));
  }
  final ready = ReceivePort(), errors = ReceivePort();
  final isolate = await Isolate.spawn(
    _worker,
    [ready.sendPort, path, key],
    onError: errors.sendPort,
    onExit: errors.sendPort,
  );
  final client = _LocalClient(isolate, ready, errors);
  await client.ready.timeout(
    const Duration(seconds: 45),
    onTimeout: () {
      client.close();
      throw StateError(
        'The local service did not start. Close another copy of MoneyTracker and retry.',
      );
    },
  );
  final legacy = Platform.environment['MONEYTRACKER_LEGACY_DIR'];
  if (legacy != null &&
      !File('$path${Platform.pathSeparator}ledger.json').existsSync()) {
    try {
      final response = await client.post(
        Uri.parse('http://localhost/api/setup/import'),
        body: jsonEncode({'path': legacy}),
      );
      if (response.statusCode != 200) {
        throw StateError(jsonDecode(response.body)['error'] as String);
      }
    } catch (_) {
      client.close();
      rethrow;
    }
  }
  return AppRuntime(client, desktop: true, dataPath: path);
}

void _worker(List<dynamic> args) async {
  final reply = args[0] as SendPort, port = ReceivePort();
  MoneyTrackerService? service;
  try {
    service = MoneyTrackerService(
      args[1] as String,
      encryptionKey: args[2] as Uint8List,
    );
    await service.start();
    reply.send({'ready': port.sendPort});
  } catch (e) {
    reply.send({'startupError': e.toString()});
    port.close();
    return;
  }
  var closing = false;
  port.listen((dynamic message) async {
    if (message == 'close') {
      closing = true;
      await service!.close();
      port.close();
      reply.send({'closed': true});
      return;
    }
    if (closing) return;
    final request = message as Map;
    try {
      final response = await service!.request(
        request['method'] as String,
        request['path'] as String,
        Map<String, dynamic>.from(request['body'] as Map),
      );
      reply.send({
        'id': request['id'],
        'status': response.status,
        'data': response.data,
      });
    } catch (_) {
      reply.send({
        'id': request['id'],
        'status': 500,
        'data': {'error': 'The local request could not be completed.'},
      });
    }
  });
}

class _LocalClient extends http.BaseClient {
  final Isolate isolate;
  final ReceivePort replies, errors;
  final _ready = Completer<void>();
  final _pending = <int, Completer<http.StreamedResponse>>{};
  SendPort? _send;
  int _id = 0;
  bool _closing = false;
  Future<void> get ready => _ready.future;
  _LocalClient(this.isolate, this.replies, this.errors) {
    replies.listen((dynamic response) {
      final map = response as Map;
      if (map['startupError'] != null) {
        _fail(StateError(map['startupError'] as String));
        return;
      }
      if (map['ready'] != null) {
        _send = map['ready'] as SendPort;
        _ready.complete();
        return;
      }
      if (map['closed'] == true) {
        replies.close();
        errors.close();
        return;
      }
      final pending = _pending.remove(map['id']);
      pending?.complete(
        http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(map['data']))),
          map['status'] as int,
          headers: {'content-type': 'application/json'},
        ),
      );
    });
    errors.listen((dynamic _) {
      if (!_closing) {
        _fail(
          StateError(
            'The local service stopped unexpectedly. Reopen MoneyTracker.',
          ),
        );
      }
    });
  }
  void _fail(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final c in _pending.values) {
      c.completeError(error);
    }
    _pending.clear();
    isolate.kill();
    replies.close();
    errors.close();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await ready;
    if (_closing) throw http.ClientException('MoneyTracker is closing');
    final bytes = await request.finalize().toBytes(),
        body = bytes.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final id = ++_id, c = Completer<http.StreamedResponse>();
    _pending[id] = c;
    _send!.send({
      'id': id,
      'method': request.method,
      'path': request.url.path,
      'body': body,
    });
    return c.future;
  }

  @override
  void close() {
    if (_closing) return;
    _closing = true;
    _send?.send('close');
    for (final c in _pending.values) {
      c.completeError(http.ClientException('MoneyTracker is closing'));
    }
    _pending.clear();
  }
}
