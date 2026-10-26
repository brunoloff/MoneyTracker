import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:money_tracker_core/data_formats.dart';
import 'package:money_tracker_core/money_tracker_core.dart';
import 'package:money_tracker_core/special_categories.dart';
import 'package:money_tracker_core/src/classification.dart';
import 'package:money_tracker_core/src/compat.dart';
import 'package:money_tracker_core/src/journal.dart';
import 'package:money_tracker_core/src/ledger_store.dart';
import 'package:money_tracker_core/src/migration.dart';
import 'migration_test.dart' show payment;

final oldKey = Uint8List.fromList(List.filled(32, 7));
final newKey = Uint8List.fromList(List.filled(32, 9));

/// Synthetic historical payloads, including extension fields and native keys.
Future<void> historical(
  Directory root,
  int version, {
  bool marker = false,
}) async {
  final j = Journal(root.path, encryptionKey: oldKey);
  try {
    final taxonomy = defaultTaxonomy();
    (taxonomy['categories'] as List).removeWhere(
      (c) => ['Ignored', borrowingCategory].contains(c['id']),
    );
    taxonomy['tags'] = [
      {'id': 'work', 'name': 'Work'},
      if (version >= 2) {'id': 'ignored', 'name': 'Ignored'},
    ];
    await j.action('Original data', () async {
      await j.write('ledger.json', {
        'accounts': [
          {'id': 'a', 'label': 'Synthetic account'},
        ],
        'transactions': [
          payment('loan', amount: -10000),
          payment('duplicate', amount: -10000),
          payment('refund', amount: 9000),
          payment('ordinary'),
        ],
        'extensionField': {
          'retain': [1, 'yes'],
        },
        if (version >= 2) 'syncStarts': {'a': '2026-09-25'},
      });
      await j.write('categories.json', {
        if (version == 3) ...{
          'loan': borrowingCategory,
          'refund': borrowingCategory,
        },
      });
      await j.write('merges.json', {
        'loan': ['duplicate'],
      });
      await j.write('tags.json', {
        'ordinary': ['work', if (version >= 2) 'ignored'],
      });
      await j.write('taxonomy.json', taxonomy);
      await j.write('profiles.json', {
        'users': [
          {'id': 'owner', 'name': 'Example'},
        ],
        'accountUsers': {'a': 'owner'},
      });
      await j.write('preferences.json', {
        'period': 'month',
        'extensionPreference': 'retain',
      });
      await j.write('rules.json', []);
      await j.write('paypal-observations.json', {});
      await j.write('paypal-associations.json', {});
      await j.write('paypal-sync.json', {
        'at': '2026-09-25',
        if (version >= 2) 'accountStarts': {'p': '2026-09-25'},
      });
      await j.write('exchange-rates.json', {
        'source': 'ECB',
        'rates': {
          '2026-09-25': {'EUR': '1', 'USD': '1.1'},
        },
      });
      await j.write('raw-synthetic.json', {'unchanged': true});
      if (version == 3) {
        await j.write('borrowing-groups.json', [
          {
            'id': 'trip',
            'leftoverId': 'borrowing-leftover-trip',
            'description': 'Synthetic trip',
            'memberIds': ['loan', 'refund'],
            'accountId': 'a',
            'currency': 'EUR',
            'date': '2026-09-25',
          },
        ]);
      }
    });
    await j.action('Classify ordinary', () async {
      final categories = j.read('categories.json', {});
      categories['ordinary'] = 'Travel';
      await j.write('categories.json', categories);
    });
    await j.write('credentials.json', {
      'appId': 'synthetic',
      'pem': 'synthetic-only',
    });
    await j.write('session.json', {'synthetic': true, 'accounts': []});
  } finally {
    j.close();
  }
  final db = sqlite3.open(p.join(root.path, 'undo.sqlite3'));
  db.execute('PRAGMA user_version=${marker && version == 3 ? 1 : 0}');
  db.close();
  final f = File(p.join(root.path, dataFormatFile));
  if (marker) {
    f.writeAsStringSync(
      jsonEncode({
        'format': dataFormatName,
        'version': version,
        'journalVersion': 1,
      }),
    );
  } else {
    f.deleteSync();
  }
  Directory(p.join(root.path, 'imports')).createSync();
  File(
    p.join(root.path, 'imports', 'synthetic-audit.txt'),
  ).writeAsStringSync('Synthetic audit retained.');
  File(
    p.join(root.path, 'backup-manifest.json'),
  ).writeAsStringSync('{"originalReceipt":"retain"}');
}

Map<String, String?> hashes(Directory root) => {
  for (final f in root.listSync(recursive: true).whereType<File>())
    if (!p
            .relative(f.path, from: root.path)
            .startsWith('backups${p.separator}') &&
        p.basename(f.path) != 'dart-owner.lock')
      p.relative(f.path, from: root.path): digest(f.readAsBytesSync()),
};
List<Map<String, Object?>> historyRows(Directory root) {
  final db = sqlite3.open(
    p.join(root.path, 'undo.sqlite3'),
    mode: OpenMode.readOnly,
  );
  try {
    return [
      for (final table in ['actions', 'blobs', 'state'])
        for (final row in db.select('SELECT * FROM $table ORDER BY id'))
          Map<String, Object?>.from(row),
    ];
  } finally {
    db.close();
  }
}

void main() {
  late Directory root;
  setUp(
    () => root = Directory.systemTemp.createTempSync('moneytracker-formats-'),
  );
  tearDown(() => root.deleteSync(recursive: true));
  test(
    'a complete backup payload can be restored, reopened and undone without receipt collisions',
    () async {
      await historical(root, 2);
      var j = Journal(root.path, encryptionKey: oldKey);
      final expected = LedgerStore(j).snapshot(), history = historyRows(root);
      final payload = Directory(
        p.join(j.dataFormat['lastMigration']['backupLocation'], 'data'),
      );
      j.close();
      final target = Directory.systemTemp.createTempSync(
        'moneytracker-format-restored-',
      );
      try {
        for (final entry in payload.listSync(recursive: true)) {
          final path = p.join(
            target.path,
            p.relative(entry.path, from: payload.path),
          );
          if (entry is Directory) {
            Directory(path).createSync(recursive: true);
          } else if (entry is File) {
            entry.copySync(path);
          }
        }
        j = Journal(target.path, encryptionKey: oldKey);
        try {
          expect(LedgerStore(j).snapshot(), expected);
          expect(historyRows(target), history);
          expect(
            j.read('backup-manifest.json', {})['originalReceipt'],
            'retain',
          );
          j.restore();
          j.restore(redo: true);
          expect(LedgerStore(j).snapshot(), expected);
        } finally {
          j.close();
        }
      } finally {
        target.deleteSync(recursive: true);
      }
    },
  );
  test('corrupt version marker is rejected without changing data', () async {
    await historical(root, 1);
    File(p.join(root.path, dataFormatFile)).writeAsStringSync('{broken');
    final before = hashes(root);
    expect(() => Journal(root.path), throwsFormatException);
    expect(hashes(root), before);
  });
  test(
    'registration recovers a copied pending journal and preserves a recoverable original backup',
    () async {
      await historical(root, 1);
      final db = sqlite3.open(p.join(root.path, 'undo.sqlite3'));
      final pending = db
          .select('SELECT after_map FROM actions WHERE id=2')
          .single['after_map'];
      db.execute('UPDATE state SET pending=? WHERE id=1', [pending]);
      db.close();
      File(p.join(root.path, 'categories.json')).writeAsStringSync('{}');
      final j = Journal(root.path, encryptionKey: oldKey);
      try {
        expect(j.read('categories.json', {})['ordinary'], 'Travel');
        final backup = Directory(
          j.dataFormat['lastMigration']['backupLocation'],
        );
        expect(
          jsonDecode(
            File(
              p.join(backup.path, 'data', 'categories.json'),
            ).readAsStringSync(),
          ),
          {},
        );
        final db = sqlite3.open(
          p.join(backup.path, 'data', 'undo.sqlite3'),
          mode: OpenMode.readOnly,
        );
        try {
          expect(
            db.select('SELECT pending FROM state').single['pending'],
            pending,
          );
        } finally {
          db.close();
        }
      } finally {
        j.close();
      }
    },
  );
  test(
    'fresh installation records data v3 and undo v1 without creating history or a backup',
    () {
      final j = Journal(root.path);
      try {
        expect(j.dataFormat['version'], 3);
        expect(j.dataFormat['journalVersion'], 1);
        expect(j.dataFormat['noticePending'], false);
        expect(j.status()['count'], 0);
        expect(Directory(p.join(root.path, 'backups')).existsSync(), false);
      } finally {
        j.close();
      }
    },
  );
  for (final version in [1, 2, 3]) {
    for (final marker in [false, true]) {
      test(
        'v$version ${marker ? 'declared' : 'unversioned'} upgrades without changing financial files, secrets or history',
        () async {
          await historical(root, version, marker: marker);
          final before = hashes(root), rows = historyRows(root);
          expect(inspectDataFormat(root).version, version);
          var j = Journal(root.path, encryptionKey: oldKey);
          try {
            expect(j.dataFormat['version'], 3);
            expect(historyRows(root), rows);
            for (final name in before.keys.where(
              (name) => !['undo.sqlite3', dataFormatFile].contains(name),
            )) {
              expect(
                digest(File(p.join(root.path, name)).readAsBytesSync()),
                before[name],
                reason: name,
              );
            }
            final upgrade = !marker || version < 3;
            expect(j.dataFormat['noticePending'], upgrade);
            if (upgrade) {
              final backup = Directory(
                j.dataFormat['lastMigration']['backupLocation'],
              );
              expect(backup.existsSync(), true);
              final receipt = jsonDecode(
                File(
                  p.join(backup.path, 'backup-manifest.json'),
                ).readAsStringSync(),
              );
              expect(receipt['fromVersion'], version);
              expect(receipt['files'], before);
              for (final name in before.keys) {
                expect(
                  digest(
                    File(p.join(backup.path, 'data', name)).readAsBytesSync(),
                  ),
                  before[name],
                  reason: 'backup $name',
                );
              }
            }
            final snapshot = LedgerStore(j).snapshot();
            expect(snapshot['transactions'].length, version == 3 ? 2 : 3);
            if (version == 3) {
              expect(
                snapshot['borrowingGroups'].single['leftover']['amount'],
                -1000,
              );
            }
            j.restore();
            expect(
              j.read('categories.json', {}).containsKey('ordinary'),
              false,
            );
            expect(j.dataFormat['version'], 3);
            j.restore(redo: true);
            expect(j.read('categories.json', {})['ordinary'], 'Travel');
            j.acknowledgeDataFormat();
            expect(j.dataFormat['noticePending'], false);
            expect(j.status()['count'], 2);
          } finally {
            j.close();
          }
          final backups = Directory(p.join(root.path, 'backups'));
          final count = backups.existsSync() ? backups.listSync().length : 0;
          j = Journal(root.path, encryptionKey: oldKey);
          try {
            expect(j.dataFormat['noticePending'], false);
            expect(backups.existsSync() ? backups.listSync().length : 0, count);
            expect(j.read('credentials.json', {})['appId'], 'synthetic');
          } finally {
            j.close();
          }
        },
      );
    }
  }
  for (final version in [1, 2, 3]) {
    test(
      'imports unversioned v$version with a different native key and preserves the source',
      () async {
        await historical(root, version);
        final before = hashes(root), rows = historyRows(root);
        final target = Directory.systemTemp.createTempSync(
          'moneytracker-format-import-',
        );
        try {
          final result = await migrateLegacy(
            root.path,
            target.path,
            newKey,
            sourceEncryptionKey: oldKey,
          );
          expect(result['sourceDataFormat'], version);
          expect(result['dataFormat'], 3);
          expect(hashes(root), before);
          expect(historyRows(root), rows);
          final j = Journal(target.path, encryptionKey: newKey);
          try {
            for (final name in before.keys.where((name) => tracked(name))) {
              expect(
                digest(j.file(name).readAsBytesSync()),
                before[name],
                reason: name,
              );
            }
            expect(j.read('credentials.json', {}), {
              'appId': 'synthetic',
              'pem': 'synthetic-only',
            });
            expect(j.read('session.json', {})['synthetic'], true);
            expect(
              digest(j.file('credentials.json').readAsBytesSync()),
              isNot(before['credentials.json']),
            );
            expect(historyRows(target), rows);
            expect(
              j.dataFormat['lastMigration']['backupKind'],
              'original-import-folder',
            );
            j.restore();
            j.restore(redo: true);
            expect(j.read('categories.json', {})['ordinary'], 'Travel');
            if (version == 3) {
              expect(
                LedgerStore(
                  j,
                ).snapshot()['borrowingGroups'].single['leftover']['amount'],
                -1000,
              );
            }
          } finally {
            j.close();
          }
        } finally {
          target.deleteSync(recursive: true);
        }
      },
    );
  }
  test(
    'missing native source key aborts import without installing unreadable credentials',
    () async {
      await historical(root, 3);
      final before = hashes(root);
      final target = Directory.systemTemp.createTempSync(
        'moneytracker-format-no-key-',
      );
      try {
        await expectLater(
          migrateLegacy(root.path, target.path, newKey),
          throwsFormatException,
        );
        expect(hashes(root), before);
        expect(target.listSync(), isEmpty);
      } finally {
        target.deleteSync();
      }
    },
  );
  for (final newer in ['data', 'journal', 'history']) {
    test(
      'rejects newer $newer format before changing any original file',
      () async {
        await historical(root, 3, marker: true);
        if (newer == 'data') {
          File(p.join(root.path, dataFormatFile)).writeAsStringSync(
            jsonEncode({
              'format': dataFormatName,
              'version': 99,
              'journalVersion': 1,
            }),
          );
        } else {
          final db = sqlite3.open(p.join(root.path, 'undo.sqlite3'));
          if (newer == 'journal') {
            db.execute('PRAGMA user_version=99');
          } else {
            db.execute('UPDATE actions SET after_map=? WHERE id=2', [
              jsonEncode({'future-unknown.json': 'missing'}),
            ]);
          }
          db.close();
        }
        final before = hashes(root);
        expect(() => Journal(root.path), throwsFormatException);
        expect(hashes(root), before);
        expect(Directory(p.join(root.path, 'backups')).existsSync(), false);
        final target = Directory.systemTemp.createTempSync(
          'moneytracker-future-import-',
        );
        try {
          await expectLater(
            migrateLegacy(root.path, target.path, newKey),
            throwsFormatException,
          );
          expect(target.listSync(), isEmpty);
          expect(hashes(root), before);
        } finally {
          target.deleteSync();
        }
      },
    );
  }
  test(
    'failed backup prevents registration and leaves the database and data unchanged',
    () async {
      await historical(root, 1);
      File(
        p.join(root.path, 'backups'),
      ).writeAsStringSync('Blocked backup destination');
      final before = hashes(root);
      expect(() => Journal(root.path), throwsA(isA<FileSystemException>()));
      expect(hashes(root), before);
      expect(File(p.join(root.path, dataFormatFile)).existsSync(), false);
    },
  );
  test(
    'v3 is inferred from undone borrowing groups still present in redo history',
    () async {
      await historical(root, 3);
      var j = Journal(root.path, encryptionKey: oldKey);
      j.restore();
      j.restore();
      j.close();
      File(p.join(root.path, dataFormatFile)).deleteSync();
      expect(
        File(p.join(root.path, 'borrowing-groups.json')).existsSync(),
        false,
      );
      expect(inspectDataFormat(root).version, 3);
      j = Journal(root.path, encryptionKey: oldKey);
      try {
        j.restore(redo: true);
        j.restore(redo: true);
        expect(
          LedgerStore(
            j,
          ).snapshot()['borrowingGroups'].single['leftover']['amount'],
          -1000,
        );
      } finally {
        j.close();
      }
    },
  );
  test(
    'format acknowledgement is metadata, not an undoable financial edit',
    () async {
      await historical(root, 2);
      final service = MoneyTrackerService(root.path, encryptionKey: oldKey);
      try {
        final info = (await service.request(
          'GET',
          '/api/ledger',
        )).data['dataFormat'];
        expect(info['version'], 3);
        expect(info['noticePending'], true);
        final history = service.journal.status();
        expect(
          (await service.request(
            'POST',
            '/api/data-format/acknowledge',
          )).status,
          200,
        );
        expect(service.journal.status(), history);
        expect(service.journal.dataFormat['noticePending'], false);
      } finally {
        await service.close();
      }
    },
  );
}
