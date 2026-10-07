import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:ffi/ffi.dart';
import 'package:pointycastle/export.dart';
import 'package:sqlite3/sqlite3.dart';
import 'compat.dart';

const trackedFiles = {
  'ledger.json',
  'categories.json',
  'merges.json',
  'tags.json',
  'taxonomy.json',
  'profiles.json',
  'preferences.json',
  'rules.json',
  'paypal-observations.json',
  'paypal-associations.json',
  'paypal-sync.json',
  'exchange-rates.json',
};
bool tracked(String name) =>
    trackedFiles.contains(name) ||
    name.startsWith('raw-') &&
        name.endsWith('.json') &&
        p.basename(name) == name &&
        !name.contains('\\');
const secretFiles = {
  'credentials.json',
  'session.json',
  'bank-sessions.json',
  'session-paypal.json',
  'connection-pending.json',
  'connection-result.json',
  'callback-key.json',
};
final _stageKey = Object();

/// One owner per data directory. The native service also serializes mutations.
class Journal {
  final Directory root;
  final Uint8List? encryptionKey;
  late final Database db;
  RandomAccessFile? _owner;
  Journal(String path, {this.encryptionKey}) : root = Directory(path) {
    root.createSync(recursive: true);
    _private(root.path, directory: true);
    final file = File(p.join(path, 'dart-owner.lock'));
    _owner = file.openSync(mode: FileMode.append);
    try {
      _owner!.lockSync(FileLock.exclusive);
    } catch (_) {
      _owner!.closeSync();
      throw StateError(
        'MoneyTracker is already using this data folder. Close the other copy.',
      );
    }
    db = sqlite3.open(p.join(path, 'undo.sqlite3'));
    _private(p.join(path, 'undo.sqlite3'));
    db.execute('PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL;');
    db.execute(
      'CREATE TABLE IF NOT EXISTS blobs(id TEXT PRIMARY KEY,data BLOB NOT NULL); CREATE TABLE IF NOT EXISTS actions(id INTEGER PRIMARY KEY AUTOINCREMENT,label TEXT NOT NULL,group_id TEXT,created TEXT NOT NULL,before_map TEXT NOT NULL,after_map TEXT NOT NULL); CREATE TABLE IF NOT EXISTS state(id INTEGER PRIMARY KEY CHECK(id=1),cursor INTEGER NOT NULL,pending TEXT); INSERT OR IGNORE INTO state VALUES(1,0,NULL);',
    );
    recover();
  }
  Map<String, List<int>>? get _stage =>
      Zone.current[_stageKey] as Map<String, List<int>>?;
  File file(String name) {
    if (p.basename(name) != name ||
        name.contains('\\') ||
        name.startsWith('.')) {
      throw const FormatException('Invalid data file');
    }
    return File(p.join(root.path, name));
  }

  dynamic read(String name, dynamic fallback) {
    final staged = _stage?[name];
    if (staged != null) return jsonDecode(utf8.decode(staged));
    final f = file(name);
    if (!f.existsSync()) return clone(fallback);
    var bytes = f.readAsBytesSync();
    if (secretFiles.contains(name) &&
        bytes.length > 4 &&
        utf8.decode(bytes.take(4).toList(), allowMalformed: true) == 'MTK1') {
      if (encryptionKey == null) {
        throw StateError(
          'Unlock the system keyring to open banking credentials.',
        );
      }
      final nonce = bytes.sublist(4, 16), encrypted = bytes.sublist(16);
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(encryptionKey!),
            128,
            nonce,
            Uint8List.fromList(utf8.encode(name)),
          ),
        );
      bytes = cipher.process(encrypted);
    }
    return jsonDecode(utf8.decode(bytes));
  }

  Future<void> write(String name, dynamic value) async {
    var data = Uint8List.fromList(utf8.encode(pythonJson(value)));
    if (tracked(name)) {
      if (_stage != null) {
        _stage![name] = data;
        return;
      }
      await action(
        'Update ${name.replaceAll('.json', '').replaceAll('-', ' ')}',
        () async {
          _stage![name] = data;
        },
      );
    } else {
      if (secretFiles.contains(name) && encryptionKey != null) {
        final nonce = Uint8List.fromList(
          List.generate(12, (_) => Random.secure().nextInt(256)),
        );
        final cipher = GCMBlockCipher(AESEngine())
          ..init(
            true,
            AEADParameters(
              KeyParameter(encryptionKey!),
              128,
              nonce,
              Uint8List.fromList(utf8.encode(name)),
            ),
          );
        data = Uint8List.fromList([
          ...utf8.encode('MTK1'),
          ...nonce,
          ...cipher.process(data),
        ]);
      }
      atomic(name, data);
    }
  }

  String? _blob(List<int>? data) {
    final id = digest(data);
    if (data != null) {
      db.execute('INSERT OR IGNORE INTO blobs VALUES(?,?)', [
        id,
        Uint8List.fromList(gzip.encode(data)),
      ]);
    }
    return id;
  }

  void atomic(String name, List<int>? bytes) {
    final f = file(name);
    if (bytes == null) {
      if (f.existsSync()) f.deleteSync();
      _syncDirectory();
      return;
    }
    final temp = File('${f.path}.undo-tmp');
    final out = temp.openSync(mode: FileMode.write);
    _private(temp.path);
    try {
      out.writeFromSync(bytes);
      out.flushSync();
    } finally {
      out.closeSync();
    }
    // Dart's rename replaces an existing file on Windows and POSIX.
    if (Platform.isWindows) {
      final move = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<
            Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
            int Function(Pointer<Utf16>, Pointer<Utf16>, int)
          >('MoveFileExW');
      final source = temp.path.toNativeUtf16(), target = f.path.toNativeUtf16();
      try {
        // Replace and flush the rename before clearing SQLite's pending manifest.
        if (move(source, target, 0x9) == 0) {
          throw FileSystemException('Could not replace data file', f.path);
        }
      } finally {
        calloc.free(source);
        calloc.free(target);
      }
    } else {
      temp.renameSync(f.path);
    }
    _syncDirectory();
  }

  void _syncDirectory() {
    if (!Platform.isLinux) return;
    final lib = DynamicLibrary.open('libc.so.6');
    final open = lib
        .lookupFunction<
          Int32 Function(Pointer<Uint8>, Int32),
          int Function(Pointer<Uint8>, int)
        >('open');
    final malloc = lib
        .lookupFunction<
          Pointer<Uint8> Function(IntPtr),
          Pointer<Uint8> Function(int)
        >('malloc');
    final free = lib
        .lookupFunction<
          Void Function(Pointer<Uint8>),
          void Function(Pointer<Uint8>)
        >('free');
    final bytes = utf8.encode(root.path), ptr = malloc(bytes.length + 1);
    ptr.asTypedList(bytes.length + 1).setAll(0, [...bytes, 0]);
    final fd = open(ptr, 0x10000);
    free(ptr);
    if (fd < 0) {
      throw const FileSystemException(
        'Could not open data directory for durability',
      );
    }
    final fsync = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'fsync',
    );
    final close = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'close',
    );
    try {
      if (fsync(fd) != 0) {
        throw const FileSystemException('Could not flush data directory');
      }
    } finally {
      close(fd);
    }
  }

  void recover() {
    final pending = db
        .select('SELECT pending FROM state WHERE id=1')
        .first['pending'];
    if (pending == null) return;
    final manifest = jsonDecode(pending as String) as Map;
    for (final entry in manifest.entries) {
      if (!tracked(entry.key as String)) {
        throw const FormatException('Invalid undo journal file');
      }
      List<int>? data;
      if (entry.value != null) {
        final rows = db.select('SELECT data FROM blobs WHERE id=?', [
          entry.value,
        ]);
        if (rows.isEmpty) {
          throw const FormatException('Undo history contains a missing blob');
        }
        data = gzip.decode(rows.first['data'] as List<int>);
        if (digest(data) != entry.value) {
          throw const FormatException('Undo history contains a corrupt blob');
        }
      }
      atomic(entry.key as String, data);
    }
    db.execute('UPDATE state SET pending=NULL WHERE id=1');
  }

  Future<T> action<T>(
    String label,
    Future<T> Function() body, {
    String? group,
  }) async {
    if (_stage != null) return body();
    recover();
    final writes = <String, List<int>>{};
    final value = await runZoned(body, zoneValues: {_stageKey: writes});
    final before = <String, String?>{}, after = <String, String?>{};
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final entry in writes.entries) {
        final f = file(entry.key),
            old = f.existsSync() ? f.readAsBytesSync() : null;
        if (digest(old) == digest(entry.value)) continue;
        before[entry.key] = _blob(old);
        after[entry.key] = _blob(entry.value);
      }
      if (after.isEmpty) {
        db.execute('ROLLBACK');
        return value;
      }
      var cursor =
          db.select('SELECT cursor FROM state WHERE id=1').first['cursor']
              as int;
      final latest = db.select(
        'SELECT * FROM actions ORDER BY id DESC LIMIT 1',
      );
      if (group != null &&
          latest.isNotEmpty &&
          latest.first['id'] == cursor &&
          latest.first['group_id'] == group) {
        final first = Map<String, dynamic>.from(
          jsonDecode(latest.first['before_map'] as String),
        );
        final last = Map<String, dynamic>.from(
          jsonDecode(latest.first['after_map'] as String),
        );
        before.forEach((k, v) {
          first.putIfAbsent(k, () => v);
        });
        last.addAll(after);
        db.execute('UPDATE actions SET before_map=?,after_map=? WHERE id=?', [
          jsonEncode(first),
          jsonEncode(last),
          cursor,
        ]);
      } else {
        db.execute('DELETE FROM actions WHERE id>?', [cursor]);
        db.execute(
          'INSERT INTO actions(label,group_id,created,before_map,after_map) VALUES(?,?,?,?,?)',
          [
            label,
            group,
            DateTime.now().toUtc().toIso8601String(),
            jsonEncode(before),
            jsonEncode(after),
          ],
        );
        cursor = db.lastInsertRowId;
      }
      db.execute('UPDATE state SET cursor=?,pending=? WHERE id=1', [
        cursor,
        jsonEncode(after),
      ]);
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    recover();
    prune();
    return value;
  }

  int get retention {
    final value = read('preferences.json', {})['undoLimit'];
    return value is int && value >= 0 && value <= 10000 ? value : 100;
  }

  void prune() {
    final limit = retention;
    if (limit == 0) return;
    final excess = db.select(
      'SELECT id FROM actions ORDER BY id DESC LIMIT -1 OFFSET ?',
      [limit],
    );
    if (excess.isEmpty) return;
    db.execute('BEGIN');
    try {
      for (final row in excess) {
        db.execute('DELETE FROM actions WHERE id=?', [row['id']]);
      }
      final referenced = <dynamic>{};
      for (final row in db.select('SELECT before_map,after_map FROM actions')) {
        referenced.addAll(
          (jsonDecode(row['before_map'] as String) as Map).values,
        );
        referenced.addAll(
          (jsonDecode(row['after_map'] as String) as Map).values,
        );
      }
      for (final row in db.select('SELECT id FROM blobs')) {
        if (!referenced.contains(row['id'])) {
          db.execute('DELETE FROM blobs WHERE id=?', [row['id']]);
        }
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Map<String, dynamic> status() {
    final cursor = db
        .select('SELECT cursor FROM state WHERE id=1')
        .first['cursor'];
    final prev = db.select('SELECT label FROM actions WHERE id=?', [cursor]);
    final next = db.select(
      'SELECT label FROM actions WHERE id>? ORDER BY id LIMIT 1',
      [cursor],
    );
    return {
      'undo': prev.isEmpty ? null : prev.first['label'],
      'redo': next.isEmpty ? null : next.first['label'],
      'limit': retention,
      'count': db.select('SELECT COUNT(*) AS n FROM actions').first['n'],
    };
  }

  void restore({bool redo = false}) {
    recover();
    final cursor = db
        .select('SELECT cursor FROM state WHERE id=1')
        .first['cursor'];
    final rows = db.select(
      redo
          ? 'SELECT * FROM actions WHERE id>? ORDER BY id LIMIT 1'
          : 'SELECT * FROM actions WHERE id=?',
      [cursor],
    );
    if (rows.isEmpty) {
      throw FormatException(redo ? 'Nothing to redo' : 'Nothing to undo');
    }
    final row = rows.first,
        expected =
            jsonDecode(row[redo ? 'before_map' : 'after_map'] as String) as Map;
    for (final entry in expected.entries) {
      final f = file(entry.key as String);
      if (digest(f.existsSync() ? f.readAsBytesSync() : null) != entry.value) {
        throw const FormatException(
          'Data changed outside undo history; refusing to overwrite it',
        );
      }
    }
    final next = redo
        ? row['id']
        : db.select('SELECT COALESCE(MAX(id),0) AS n FROM actions WHERE id<?', [
            row['id'],
          ]).first['n'];
    db.execute('UPDATE state SET cursor=?,pending=? WHERE id=1', [
      next,
      row[redo ? 'after_map' : 'before_map'],
    ]);
    recover();
  }

  void close() {
    db.close();
    _owner?.closeSync();
    _owner = null;
  }
}

void _private(String path, {bool directory = false}) {
  if (Platform.isLinux) {
    final result = Process.runSync('chmod', [directory ? '700' : '600', path]);
    if (result.exitCode != 0) {
      throw FileSystemException('Could not restrict data permissions', path);
    }
  }
}
