import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import '../data_formats.dart';
import '../special_categories.dart';
import 'compat.dart';
import 'storage_layout.dart';

class DataFormatInspection {
  final int version, journalVersion;
  final bool recorded, hasData;
  final Map<String, dynamic> metadata;
  DataFormatInspection(
    this.version,
    this.journalVersion,
    this.recorded,
    this.hasData,
    this.metadata,
  );
  bool get needsRegistration =>
      !recorded ||
      version < currentDataFormat ||
      journalVersion < currentJournalFormat;
}

/// Read-only preflight, also used before importing or opening an undo database.
/// In particular, a newer version is rejected before chmod, lock or DB writes.
DataFormatInspection inspectDataFormat(Directory root) {
  dynamic jsonFile(String name) {
    final f = File(p.join(root.path, name));
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(f.readAsStringSync());
    } on FormatException {
      throw FormatException(
        'Cannot read $name. Keep the data folder unchanged and restore a backup or repair the file.',
      );
    }
  }

  final marker = File(p.join(root.path, dataFormatFile));
  final recorded = marker.existsSync();
  final header = recorded ? jsonFile(dataFormatFile) : null;
  if (recorded &&
      (header is! Map ||
          header['format'] != dataFormatName ||
          header['version'] is! int ||
          header['version'] < oldestDataFormat ||
          header['journalVersion'] is! int ||
          header['journalVersion'] < 1 ||
          header['migrations'] != null &&
              (header['migrations'] is! List ||
                  (header['migrations'] as List).any((m) => m is! Map)))) {
    throw const FormatException(
      'Invalid data-format marker. The data folder was not changed.',
    );
  }
  if (recorded &&
      (header['version'] > currentDataFormat ||
          header['journalVersion'] > currentJournalFormat)) {
    throw FormatException(
      'This folder requires data format v${header['version']} / undo format v${header['journalVersion']}. This app supports data v$oldestDataFormat–v$currentDataFormat and undo v$currentJournalFormat. Install a newer compatible app. The folder was not changed.',
    );
  }
  var required = 1, journalVersion = 0, history = false;
  void requireVersion(int value) {
    if (required < value) required = value;
  }

  void inspectRuleScopes(String name, dynamic value) {
    if (name == 'rules.json' &&
        value is List &&
        value.any((r) => r is Map && r['userId'] != null)) {
      requireVersion(4);
    }
    if (name == 'profiles.json' &&
        value is Map &&
        (value['users'] as List? ?? []).any(
          (u) =>
              u is Map &&
              (u.containsKey('useSharedRules') ||
                  u.containsKey('usePersonalRules')),
        )) {
      requireVersion(4);
    }
  }

  final groups = File(p.join(root.path, 'borrowing-groups.json'));
  if (groups.existsSync()) required = 3;
  bool specialCategory(dynamic id) =>
      id == borrowingCategory || id == 'Ignored';
  // Validate JSON and infer the minimum version required by pre-marker releases.
  // Never infer the producing app version: an unused newer app can leave old data.
  for (final name in trackedFiles) {
    if (!File(p.join(root.path, name)).existsSync()) continue;
    final value = jsonFile(name);
    inspectRuleScopes(name, value);
    final listFile = name == 'rules.json' || name == 'borrowing-groups.json';
    if (listFile ? value is! List : value is! Map) {
      throw FormatException(
        'Unrecognized structure in $name. The folder was not changed.',
      );
    }
    if (name == 'ledger.json' && value is Map) {
      if (value.containsKey('syncStarts') && required < 2) required = 2;
      if ((value['transactions'] as List? ?? []).any(
        (r) => specialCategory(r['category']),
      )) {
        requireVersion(3);
      }
    } else if (name == 'categories.json' &&
        value is Map &&
        value.values.any(specialCategory)) {
      requireVersion(3);
    } else if (name == 'taxonomy.json' && value is Map) {
      if ((value['categories'] as List? ?? []).any(
        (c) => specialCategory(c['id']),
      )) {
        requireVersion(3);
      }
      if ((value['tags'] as List? ?? []).any((t) => t['id'] == 'ignored') &&
          required < 2) {
        required = 2;
      }
    } else if (name == 'rules.json' && value is List) {
      if (value.any((r) => specialCategory(r['category']))) requireVersion(3);
      if (value.any((r) => (r['tags'] as List? ?? []).contains('ignored')) &&
          required < 2) {
        required = 2;
      }
    } else if (name == 'tags.json' &&
        value is Map &&
        value.values.any((v) => (v as List).contains('ignored')) &&
        required < 2) {
      required = 2;
    } else if (name == 'paypal-sync.json' &&
        value is Map &&
        value.containsKey('accountStarts') &&
        required < 2) {
      required = 2;
    }
  }
  final database = File(p.join(root.path, 'undo.sqlite3'));
  if (database.existsSync()) {
    final db = sqlite3.open(database.path, mode: OpenMode.readOnly);
    try {
      journalVersion =
          db.select('PRAGMA user_version').single.values.single as int;
      if (journalVersion > currentJournalFormat) {
        throw FormatException(
          'This undo database uses format v$journalVersion. This app supports v$currentJournalFormat. Install a newer compatible app. The folder was not changed.',
        );
      }
      const columns = {
        'blobs': ['id', 'data'],
        'actions': [
          'id',
          'label',
          'group_id',
          'created',
          'before_map',
          'after_map',
        ],
        'state': ['id', 'cursor', 'pending'],
      };
      for (final e in columns.entries) {
        final actual = db
            .select('PRAGMA table_info(${e.key})')
            .map((r) => r['name'])
            .toList();
        if (actual.length != e.value.length ||
            !actual.toSet().containsAll(e.value)) {
          throw const FormatException(
            'Unrecognized undo database structure. The folder was not changed.',
          );
        }
      }
      final inspectedBlobs = <String>{};
      void checkManifest(dynamic text) {
        if (text == null) return;
        final manifest = jsonDecode(text as String);
        if (manifest is! Map ||
            manifest.keys.any((name) => name is! String || !tracked(name))) {
          throw const FormatException(
            'Undo history references an unsupported data file. Use a newer compatible app. The folder was not changed.',
          );
        }
        if (manifest.containsKey('borrowing-groups.json')) requireVersion(3);
        for (final name in ['rules.json', 'profiles.json']) {
          final id = manifest[name];
          if (id == null || !inspectedBlobs.add('$name:$id')) continue;
          final rows = db.select('SELECT data FROM blobs WHERE id=?', [id]);
          if (rows.isEmpty) {
            throw const FormatException(
              'Undo history contains a missing blob. The folder was not changed.',
            );
          }
          final bytes = gzip.decode(rows.first['data'] as List<int>);
          if (digest(bytes) != id) {
            throw const FormatException(
              'Undo history contains a corrupt blob. The folder was not changed.',
            );
          }
          inspectRuleScopes(name, jsonDecode(utf8.decode(bytes)));
        }
      }

      for (final row in db.select('SELECT before_map,after_map FROM actions')) {
        history = true;
        checkManifest(row['before_map']);
        checkManifest(row['after_map']);
      }
      for (final row in db.select('SELECT pending FROM state')) {
        checkManifest(row['pending']);
      }
    } finally {
      db.close();
    }
  }
  if (recorded && header['version'] < required) {
    throw FormatException(
      'The v${header['version']} marker disagrees with data requiring v$required. The folder was not changed.',
    );
  }
  final hasData =
      history ||
      [
        ...trackedFiles,
        ...secretFiles,
      ].any((name) => File(p.join(root.path, name)).existsSync());
  return DataFormatInspection(
    recorded ? header['version'] as int : required,
    journalVersion,
    recorded,
    hasData,
    recorded ? Map<String, dynamic>.from(header) : {},
  );
}

void privatePath(String path, {bool directory = false}) {
  if (!Platform.isLinux) return;
  if (Process.runSync('chmod', [directory ? '700' : '600', path]).exitCode !=
      0) {
    throw FileSystemException('Could not restrict data permissions', path);
  }
}

/// Copy all original data, credentials (still encrypted), and audit files.
/// Existing backups and process locks are omitted to avoid recursive growth.
String backupBeforeFormatChange(Directory root, DataFormatInspection previous) {
  final id =
      '${DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '')}-${const Uuid().v4()}';
  final backupRoot = p.join(root.path, 'backups');
  if (FileSystemEntity.typeSync(backupRoot, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const FormatException(
      'The backup folder cannot be a symbolic link. The data was not upgraded.',
    );
  }
  final parent = Directory(backupRoot)..createSync();
  privatePath(parent.path, directory: true);
  final staging = Directory(p.join(parent.path, '.pending-$id'))..createSync();
  privatePath(staging.path, directory: true);
  final payload = Directory(p.join(staging.path, 'data'))..createSync();
  privatePath(payload.path, directory: true);
  final hashes = <String, String?>{};
  try {
    void copy(Directory source, Directory destination) {
      for (final entry in source.listSync(followLinks: false)) {
        final name = p.basename(entry.path);
        if (source.path == root.path &&
            (name == 'backups' || name == 'dart-owner.lock')) {
          continue;
        }
        if (entry is Link) {
          throw const FormatException(
            'Data backups cannot contain symbolic links. The data was not upgraded.',
          );
        }
        final target = p.join(destination.path, name);
        if (entry is Directory) {
          final dir = Directory(target)..createSync();
          privatePath(target, directory: true);
          copy(entry, dir);
        } else if (entry is File) {
          final bytes = entry.readAsBytesSync(), hash = digest(bytes);
          final output = File(target).openSync(mode: FileMode.write);
          privatePath(target);
          try {
            output.writeFromSync(bytes);
            output.flushSync();
          } finally {
            output.closeSync();
          }
          if (digest(File(target).readAsBytesSync()) != hash ||
              digest(entry.readAsBytesSync()) != hash) {
            throw const FormatException(
              'Data changed while making a backup. The data was not upgraded.',
            );
          }
          hashes[p.relative(entry.path, from: root.path)] = hash;
        }
      }
    }

    copy(root, payload);
    for (final e in hashes.entries) {
      if (digest(File(p.join(root.path, e.key)).readAsBytesSync()) != e.value) {
        throw const FormatException(
          'Data changed while making a backup. The data was not upgraded.',
        );
      }
    }
    final receipt = File(
      p.join(staging.path, 'backup-manifest.json'),
    ).openSync(mode: FileMode.write);
    privatePath(p.join(staging.path, 'backup-manifest.json'));
    try {
      receipt.writeStringSync(
        jsonEncode({
          'format': dataFormatName,
          'backupFormat': 1,
          'payloadDirectory': 'data',
          'fromVersion': previous.version,
          'toVersion': currentDataFormat,
          'files': hashes,
        }),
      );
      receipt.flushSync();
    } finally {
      receipt.closeSync();
    }
    final destination = p.join(
      parent.path,
      'before-data-v$currentDataFormat-$id',
    );
    staging.renameSync(destination);
    return p.posix.join('backups', p.basename(destination));
  } catch (_) {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    rethrow;
  }
}

Map<String, dynamic> registeredDataFormat(
  DataFormatInspection previous, {
  String? backupPath,
  String? importSource,
}) {
  final at = DateTime.now().toUtc().toIso8601String();
  return {
    ...previous.metadata,
    'format': dataFormatName,
    'version': currentDataFormat,
    'journalVersion': currentJournalFormat,
    'registeredAt': previous.metadata['registeredAt'] ?? at,
    'migrations': [
      ...previous.metadata['migrations'] as List? ?? [],
      if (previous.hasData || importSource != null)
        {
          'from': previous.version,
          'to': currentDataFormat,
          'inferred': !previous.recorded,
          'at': at,
          'kind': importSource == null ? 'registration' : 'import',
          'backupPath': importSource ?? backupPath,
          'backupKind': importSource == null
              ? 'local-copy'
              : 'original-import-folder',
          'acknowledged': false,
        },
    ],
  };
}

Map<String, dynamic> dataFormatInformation(Directory root) {
  final metadata = Map<String, dynamic>.from(
    jsonDecode(File(p.join(root.path, dataFormatFile)).readAsStringSync()),
  );
  final migrations = metadata['migrations'] as List? ?? [];
  final last = migrations.isEmpty
      ? null
      : Map<String, dynamic>.from(migrations.last);
  if (last != null && last['backupPath'] is String) {
    final location = last['backupKind'] == 'local-copy'
        ? p.joinAll([
            root.path,
            ...p.posix.split(
              (last['backupPath'] as String).replaceAll('\\', '/'),
            ),
          ])
        : last['backupPath'] as String;
    last['backupLocation'] = location;
    last['backupAvailable'] =
        Directory(location).existsSync() &&
        (last['backupKind'] != 'local-copy' ||
            Directory(p.join(location, 'data')).existsSync());
  }
  return {
    'version': metadata['version'],
    'journalVersion': metadata['journalVersion'],
    'oldestSupported': oldestDataFormat,
    'currentSupported': currentDataFormat,
    'lastMigration': last,
    'noticePending': last != null && last['acknowledged'] != true,
  };
}
