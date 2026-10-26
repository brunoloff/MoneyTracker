import 'package:flutter/material.dart';
import 'package:money_tracker_core/data_formats.dart';
import 'ledger.dart';

/// Permanent compatibility information and a dismissible upgrade receipt.
class DataFormatPanel extends StatelessWidget {
  final Ledger ledger;
  final bool notice;
  const DataFormatPanel({super.key, required this.ledger, this.notice = false});
  @override
  Widget build(BuildContext context) {
    final info = ledger.dataFormat;
    final migration = info?['lastMigration'] as Map?;
    if (notice && info?['noticePending'] != true) {
      return const SizedBox.shrink();
    }
    return Card(
      margin: EdgeInsets.only(bottom: notice ? 20 : 0),
      color: const Color(0xffedf7f4),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              notice
                  ? 'Your data is ready: format v${info?['version']}'
                  : 'Data format and updates',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(
              info == null
                  ? 'This app supports data formats v$oldestDataFormat–v$currentDataFormat and undo database v$currentJournalFormat.'
                  : 'Your data: v${info['version']} · Undo database: v${info['journalVersion']}',
            ),
            if (migration != null) ...[
              const SizedBox(height: 12),
              Text(
                '${migration['kind'] == 'import' ? 'Imported' : 'Registered'} data v${migration['from']} to v${migration['to']}. Original payment records, categories, tags and undo history were preserved.',
              ),
              const SizedBox(height: 8),
              Text(
                migration['backupKind'] == 'original-import-folder'
                    ? 'The original import folder has been kept unchanged.'
                    : 'An automatic copy was saved before registration.',
              ),
              if (migration['backupLocation'] is String)
                SelectableText('Backup: ${migration['backupLocation']}'),
              if (migration['backupAvailable'] == false)
                const Text(
                  'That backup is no longer at this location. Keep your separate backup before changing app versions.',
                ),
            ],
            const SizedBox(height: 12),
            const Text(
              'Compatibility history: 1.0.4 introduced the Ignored tag (v2); 1.0.5 introduced special categories and borrowing groups (v3). Version 1.0.6 records those versions explicitly. The SQLite tables and banking-key encryption format are unchanged.',
            ),
            const SizedBox(height: 12),
            const Text(downgradeGuidance),
            if (notice) ...[
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('acknowledge-data-format'),
                onPressed: ledger.syncing || ledger.saving
                    ? null
                    : () =>
                          ledger.reconcile('/api/data-format/acknowledge', {}),
                child: const Text('Got it'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
