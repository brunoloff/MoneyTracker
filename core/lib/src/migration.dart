import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'classification.dart';
import 'compat.dart';
import 'journal.dart';
import 'ledger_store.dart';

/// Copies a stopped legacy installation. The source is never modified.
Future<Map<String, dynamic>> migrateLegacy(
  String source,
  String destination,
  Uint8List key,
) async {
  final from = Directory(source).resolveSymbolicLinksSync(),
      to = Directory(destination).absolute.path;
  if (from == to || p.isWithin(from, to) || p.isWithin(to, from)) {
    invalid('Choose a separate folder containing the old .private data.');
  }
  if (!File(p.join(from, 'ledger.json')).existsSync()) {
    invalid('Select the old .private folder containing ledger.json.');
  }
  Socket? probe;
  try {
    probe = await Socket.connect(
      InternetAddress.loopbackIPv4,
      8765,
      timeout: const Duration(milliseconds: 300),
    );
  } catch (_) {}
  if (probe != null) {
    probe.destroy();
    invalid(
      'Close the old browser-based MoneyTracker service before importing its data.',
    );
  }
  final destinationFiles = Directory(to)
      .listSync()
      .whereType<File>()
      .where((f) => tracked(p.basename(f.path)))
      .toList();
  if (destinationFiles.isNotEmpty) {
    invalid(
      'This MoneyTracker already contains data. Import into a fresh installation.',
    );
  }
  final staging = Directory(
    '$to.migration-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  try {
    final selected = Directory(from)
        .listSync(followLinks: false)
        .whereType<File>()
        .where(
          (f) =>
              tracked(p.basename(f.path)) ||
              secretFiles.contains(p.basename(f.path)),
        )
        .toList();
    final audits = Directory(p.join(from, 'imports'));
    if (audits.existsSync()) {
      final entities = audits.listSync(recursive: true, followLinks: false);
      if (entities.any((e) => e is Link)) {
        invalid('Import audit folders must not contain symbolic links.');
      }
      selected.addAll(entities.whereType<File>());
    }
    final hashes = {
      for (final f in selected) f.path: digest(f.readAsBytesSync()),
    };
    for (final f in selected) {
      final target = File(p.join(staging.path, p.relative(f.path, from: from)));
      target.parent.createSync(recursive: true);
      f.copySync(target.path);
      if (digest(target.readAsBytesSync()) != hashes[f.path]) {
        invalid('An imported file did not match its source.');
      }
    }
    final sourceDb = File(p.join(from, 'undo.sqlite3'));
    if (sourceDb.existsSync()) {
      final db = sqlite3.open(sourceDb.path, mode: OpenMode.readOnly);
      try {
        db.execute('VACUUM INTO ?', [p.join(staging.path, 'undo.sqlite3')]);
      } finally {
        db.close();
      }
    }
    for (final f in selected) {
      if (digest(f.readAsBytesSync()) != hashes[f.path]) {
        invalid(
          'The old data changed during import. Close the old service and try again.',
        );
      }
    }
    final candidate = Journal(staging.path, encryptionKey: key);
    Map<String, dynamic> summary;
    try {
      // Replay only the copied journal's pending manifest, then verify projection.
      final snapshot = LedgerStore(candidate).snapshot();
      summary = {
        'transactions': snapshot['transactions'].length,
        'storedTransactions': candidate
            .read('ledger.json', {})['transactions']
            .length,
        'accounts': snapshot['accounts'].length,
        'undoSteps': candidate.status()['count'],
      };
      for (final name in secretFiles) {
        if (candidate.file(name).existsSync()) {
          await candidate.write(name, candidate.read(name, {}));
        }
      }
      final keys = Directory(p.dirname(from))
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => p.extension(f.path) == '.pem')
          .toList();
      if (keys.length == 1 &&
          !candidate.file('credentials.json').existsSync()) {
        await candidate.write('credentials.json', {
          'appId': p.basenameWithoutExtension(keys.single.path),
          'pem': keys.single.readAsStringSync(),
        });
      }
      candidate.atomic(
        'migration.json',
        utf8.encode(
          pythonJson({
            'source': from,
            'completedAt': DateTime.now().toUtc().toIso8601String(),
            ...summary,
          }),
        ),
      );
    } finally {
      candidate.close();
    }
    // Install the complete verified directory in one rename. Retain the empty
    // pre-migration directory too, so interruption has an obvious recovery path.
    final before =
        '$to.before-migration-${DateTime.now().microsecondsSinceEpoch}';
    // Restrict every copied audit file, not just the journal's own files.
    if (Platform.isLinux) {
      for (final entity in staging.listSync(
        recursive: true,
        followLinks: false,
      )) {
        Process.runSync('chmod', [
          entity is Directory ? '700' : '600',
          entity.path,
        ]);
      }
    }
    Directory(to).renameSync(before);
    try {
      staging.renameSync(to);
    } catch (_) {
      Directory(before).renameSync(to);
      rethrow;
    }
    return {
      ...summary,
      'message':
          'Data copied and verified. The original installation has been kept unchanged.',
    };
  } catch (_) {
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    rethrow;
  }
}
