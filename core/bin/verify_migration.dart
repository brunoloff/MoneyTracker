import 'dart:convert';
import 'dart:io';
import 'package:money_tracker_core/src/compat.dart';
import 'package:money_tracker_core/src/journal.dart';
import 'package:money_tracker_core/src/ledger_store.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'Usage: dart run bin/verify_migration.dart OLD_PRIVATE NEW_DATA PYTHON_SNAPSHOT',
    );
    exitCode = 64;
    return;
  }
  final from = Directory(args[0]), to = Directory(args[1]);
  var verified = 0;
  for (final f
      in from.listSync(recursive: true, followLinks: false).whereType<File>()) {
    final relative = f.path.substring(from.path.length + 1);
    if (!tracked(relative) &&
        !relative.startsWith('imports${Platform.pathSeparator}')) {
      continue;
    }
    final copied = File('${to.path}${Platform.pathSeparator}$relative');
    if (!copied.existsSync() ||
        digest(copied.readAsBytesSync()) != digest(f.readAsBytesSync())) {
      throw StateError('Copied file differs: $relative');
    }
    verified++;
  }
  final scratch = Directory.systemTemp.createTempSync('moneytracker-audit-');
  try {
    for (final f in to.listSync(followLinks: false).whereType<File>()) {
      if (tracked(f.uri.pathSegments.last)) {
        f.copySync('${scratch.path}/${f.uri.pathSegments.last}');
      }
    }
    final j = Journal(scratch.path);
    try {
      final actual = LedgerStore(j).snapshot(client: true),
          expected = jsonDecode(File(args[2]).readAsStringSync());
      if (pythonJson(actual, sorted: true) !=
          pythonJson(expected, sorted: true)) {
        throw StateError(
          'The migrated payment projection differs from Python.',
        );
      }
      stdout.writeln(
        'Verified $verified data/audit files byte-for-byte and ${actual['transactions'].length} displayed payments against the Python projection.',
      );
    } finally {
      j.close();
    }
  } finally {
    scratch.deleteSync(recursive: true);
  }
}
