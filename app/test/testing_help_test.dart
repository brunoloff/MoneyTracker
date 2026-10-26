import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_tracker/testing_help.dart';
import 'package:money_tracker_core/data_formats.dart';

void main() {
  test('reported version matches the packaged version', () {
    expect(
      File('pubspec.yaml').readAsLinesSync().map((line) => line.trim()),
      contains('version: $appVersion'),
    );
  });
  test(
    'release compatibility manifest matches this app and its data contract',
    () {
      final manifest = jsonDecode(
        File('../packaging/COMPATIBILITY.json').readAsStringSync(),
      );
      expect(manifest['appVersion'], appVersion);
      expect(manifest['dataFormat'], currentDataFormat);
      expect(manifest['supportedDataFormats'], [
        for (var i = oldestDataFormat; i <= currentDataFormat; i++) i,
      ]);
      expect(manifest['journalSchema'], currentJournalFormat);
      for (final field in [
        'previousReleaseDataFormat',
        'sqliteTablesChanged',
        'financialFilesRewritten',
        'credentialEncryption',
        'change',
        'backup',
        'downgrade',
      ]) {
        expect(
          manifest[field],
          isNotNull,
          reason: 'Each release must explicitly declare $field',
        );
      }
      expect(
        File('../packaging/COMPATIBILITY.txt').readAsStringSync(),
        contains(appVersion),
      );
    },
  );

  test('credential-store recovery guidance matches the operating system', () {
    expect(
      credentialStoreGuidance(TargetPlatform.windows),
      contains('Windows user account'),
    );
    expect(
      credentialStoreGuidance(TargetPlatform.windows),
      isNot(contains('GNOME')),
    );
    expect(credentialStoreGuidance(TargetPlatform.linux), contains('keyring'));
  });

  for (final width in [390.0, 1100.0]) {
    testWidgets('testing help copies only build information at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTestingHelp(context),
                child: const Text('Help'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Help'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Close and reopen'), findsOneWidget);
      await tester.tap(find.text('Copy build info'));
      await tester.pumpAndSettle();
      expect(
        copied,
        'MoneyTracker $appVersion\nBuild: $buildRevision\nPlatform: ${defaultTargetPlatform.name}\nSupported data: v$oldestDataFormat–v$currentDataFormat\nUndo database: v$currentJournalFormat\n',
      );
      expect(find.text('Build info copied.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  }
}
