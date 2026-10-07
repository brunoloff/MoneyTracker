import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'ledger.dart';

class SpreadsheetImportDialog extends StatefulWidget {
  final Ledger ledger;
  const SpreadsheetImportDialog({super.key, required this.ledger});
  @override
  State<SpreadsheetImportDialog> createState() =>
      _SpreadsheetImportDialogState();
}

class _SpreadsheetImportDialogState extends State<SpreadsheetImportDialog> {
  String? account, error;
  Map<String, dynamic>? preview;
  bool busy = false;
  Future<void> choose() async {
    setState(() {
      busy = true;
      error = null;
      preview = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'CGD spreadsheet', extensions: ['xlsx']),
        ],
      );
      if (file == null) return;
      final result = await widget.ledger.post('/api/import/preview', {
        'path': file.path,
        'accountId': account,
      });
      if (mounted) setState(() => preview = result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> apply() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.ledger.post('/api/import/apply', {
        'ticket': preview!['ticket'],
      });
      await widget.ledger.load();
      if (mounted) {
        Navigator.pop(
          context,
          'Spreadsheet imported. A backup and audit were saved; you can undo the import.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Import CGD spreadsheet'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Choose a CGD current account with existing payments. Only verified older movements are added; the spreadsheet must overlap the account’s saved history.',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'CGD current account',
              ),
              items: [
                for (final a in widget.ledger.accounts)
                  if (a['source'] == 'CGD' && a['kind'] == 'CACC')
                    DropdownMenuItem(
                      value: a['id'] as String,
                      child: Text(widget.ledger.accountLabel(a['id'])),
                    ),
              ],
              onChanged: busy
                  ? null
                  : (value) => setState(() {
                      account = value;
                      preview = null;
                    }),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: busy || account == null ? null : choose,
              child: const Text('Choose XLSX and preview'),
            ),
            if (preview != null) ...[
              const SizedBox(height: 16),
              Text(
                '${preview!['rows']} rows: ${preview!['matched']} matched, ${preview!['added']} older payments to add.\n${preview!['from']} to ${preview!['through']}',
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy || preview == null ? null : apply,
        child: const Text('Import verified payments'),
      ),
    ],
  );
}
