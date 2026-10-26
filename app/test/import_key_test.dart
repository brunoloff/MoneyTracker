import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_tracker/platform/import_key.dart';

void main() {
  late Directory root;
  setUp(
    () =>
        root = Directory.systemTemp.createTempSync('moneytracker-import-key-'),
  );
  tearDown(() => root.deleteSync(recursive: true));
  test(
    'native import selects the source key instead of a different destination key',
    () async {
      final source = Directory('${root.path}/source')..createSync();
      final destination = Directory('${root.path}/destination')..createSync();
      final vault = {
        'moneytracker.master.${base64Url.encode(utf8.encode(source.path))}':
            'source-key',
        'moneytracker.master.${base64Url.encode(utf8.encode(destination.path))}':
            'destination-key',
      };
      expect(
        await findSourceImportKey(source.path, (key) async => vault[key]),
        'source-key',
      );
    },
  );
  test(
    'folder-picker path aliases resolve to the original native key',
    () async {
      final source = Directory('${root.path}/source')..createSync();
      final vault = {
        masterKeyName(source.resolveSymbolicLinksSync()): 'original-key',
      };
      expect(
        await findSourceImportKey(
          '${source.path}${Platform.pathSeparator}.',
          (key) async => vault[key],
        ),
        'original-key',
      );
    },
  );
  test(
    'missing source key remains missing without substituting another key',
    () async {
      expect(await findSourceImportKey(root.path, (_) async => null), isNull);
    },
  );
}
