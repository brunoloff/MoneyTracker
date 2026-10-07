import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import 'classification.dart';
import 'compat.dart';
import 'ledger_store.dart';

/// Restricted read-only OOXML reader for CGD comprovativo exports.
/// Formulas, external links and oversized decompressed content are rejected.
List<List<dynamic>> readWorkbook(List<int> bytes) {
  if (bytes.length > 32 * 1024 * 1024) {
    invalid('Choose a spreadsheet smaller than 32 MB');
  }
  final archive = ZipDecoder().decodeBytes(bytes, verify: true),
      files = <String, List<int>>{};
  var total = 0;
  for (final f in archive.files) {
    if (!f.isFile) continue;
    total += f.size;
    if (total > 64 * 1024 * 1024) invalid('Spreadsheet expands beyond 64 MB');
    if (f.name.contains('externalLinks/')) {
      invalid('External spreadsheet links are not supported');
    }
    if (f.name.endsWith('.xml') || f.name.endsWith('.rels')) {
      files[f.name] = f.content;
    }
  }
  XmlDocument xml(String name) {
    final content = files[name];
    if (content == null) invalid('Incomplete spreadsheet');
    final text = utf8.decode(content);
    if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
      invalid('Unsupported spreadsheet XML');
    }
    return XmlDocument.parse(text);
  }

  List<XmlElement> elements(XmlNode node, String name) => node.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == name)
      .toList();
  final workbook = xml('xl/workbook.xml'), sheets = elements(workbook, 'sheet');
  if (sheets.length != 1 ||
      sheets.first.getAttribute('name') != 'comprovativo') {
    invalid('Expected one comprovativo sheet');
  }
  if (elements(
    workbook,
    'workbookPr',
  ).any((e) => {'true', '1'}.contains(e.getAttribute('date1904')))) {
    invalid('Unsupported spreadsheet date system');
  }
  final relationships = xml('xl/_rels/workbook.xml.rels'),
      id = sheets.first.getAttribute(
        'id',
        namespace:
            'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
      );
  final matching = elements(
    relationships,
    'Relationship',
  ).where((e) => e.getAttribute('Id') == id).toList();
  if (matching.isEmpty) invalid('Missing worksheet');
  final target = matching.first.getAttribute('Target')!;
  if (matching.first.getAttribute('TargetMode') == 'External') {
    invalid('External worksheets are not supported');
  }
  final sheetPath = target.startsWith('/')
      ? target.substring(1)
      : p.posix.normalize('xl/$target');
  if (!sheetPath.startsWith('xl/')) invalid('Invalid worksheet path');
  final strings = files.containsKey('xl/sharedStrings.xml')
      ? elements(
          xml('xl/sharedStrings.xml'),
          'si',
        ).map((e) => elements(e, 't').map((t) => t.innerText).join()).toList()
      : <String>[];
  final dateStyles = <int>{};
  if (files.containsKey('xl/styles.xml')) {
    final styles = xml('xl/styles.xml'),
        formats = {
          for (final e in elements(styles, 'numFmt'))
            int.parse(e.getAttribute('numFmtId')!): e.getAttribute(
              'formatCode',
            )!,
        };
    final cellXfs = elements(styles, 'cellXfs');
    if (cellXfs.isNotEmpty) {
      var index = 0;
      for (final xf in cellXfs.first.childElements) {
        final n = int.tryParse(xf.getAttribute('numFmtId') ?? '0') ?? 0;
        final format = formats[n] ?? '';
        if (n >= 14 && n <= 22 ||
            RegExp(
              r'[dmy]',
              caseSensitive: false,
            ).hasMatch(format.replaceAll(RegExp(r'"[^"]*"|\\.'), ''))) {
          dateStyles.add(index);
        }
        index++;
      }
    }
  }
  final rows = <List<dynamic>>[];
  for (final row in elements(xml(sheetPath), 'row')) {
    final number = int.parse(row.getAttribute('r')!);
    if (number > 100000) invalid('Too many spreadsheet rows');
    while (rows.length < number) {
      rows.add(List.filled(8, null));
    }
    for (final cell in row.childElements.where((e) => e.name.local == 'c')) {
      if (elements(cell, 'f').isNotEmpty) {
        invalid('Spreadsheet formulas are not supported');
      }
      final ref = cell.getAttribute('r')!,
          letters = RegExp(r'^[A-Z]+').stringMatch(ref)!;
      var column = 0;
      for (final c in letters.codeUnits) {
        column = column * 26 + c - 64;
      }
      column--;
      if (column > 7) {
        if (cell.innerText.trim().isNotEmpty) {
          invalid('Unrecognized CGD column layout');
        }
        continue;
      }
      final type = cell.getAttribute('t'),
          values = elements(cell, 'v'),
          text = values.isEmpty ? '' : values.first.innerText;
      dynamic value;
      if (type == 's') {
        value = strings[int.parse(text)];
      } else if (type == 'inlineStr') {
        value = elements(cell, 't').map((e) => e.innerText).join();
      } else if (type == 'str') {
        value = text;
      } else if (type == 'd') {
        value = DateTime.parse(text);
      } else if (type == 'e' || type == 'b') {
        invalid('Unsupported spreadsheet cell');
      } else if (text.isNotEmpty) {
        final style = int.tryParse(cell.getAttribute('s') ?? '0') ?? 0;
        value = dateStyles.contains(style)
            ? DateTime.utc(1899, 12, 30).add(
                Duration(milliseconds: (double.parse(text) * 86400000).round()),
              )
            : Exact.parse(text);
      }
      rows[number - 1][column] = value;
    }
  }
  return rows;
}

int spreadsheetMoney(dynamic value) {
  if (value == null || value == '' || value == 0) return 0;
  Exact amount;
  if (value is Exact) {
    amount = value;
  } else if (value is String) {
    final s = value.trim();
    if (s.isEmpty) return 0;
    if (!RegExp(r'^-?(?:\d+|\d{1,3}(?:\.\d{3})+),\d{2}$').hasMatch(s)) {
      invalid('Expected Portuguese currency with two decimal places');
    }
    amount = Exact.parse(s.replaceAll('.', '').replaceAll(',', '.'));
  } else {
    amount = Exact.parse(value);
  }
  final minor = amount * Exact(BigInt.from(100));
  if (minor.numerator.remainder(minor.denominator) != BigInt.zero) {
    invalid('Invalid currency precision');
  }
  return minor.truncate();
}

String spreadsheetDate(dynamic value) {
  if (value is DateTime) return day(value);
  final m = RegExp(
    r'^(\d{2})-(\d{2})-(\d{4})$',
  ).firstMatch(value.toString().trim());
  if (m == null) invalid('Expected a day-month-year date');
  return day(dateOnly('${m[3]}-${m[2]}-${m[1]}'));
}

List<Map<String, dynamic>> parseSpreadsheetRows(List<List<dynamic>> rows) {
  final expected = [
    'Data mov.',
    'Data valor',
    'Descrição',
    'Débito',
    'Crédito',
    'Saldo contabilístico',
    'Saldo disponível',
    'Categoria',
  ];
  if (rows.length < 8 ||
      pythonJson(rows[6].map((c) => c?.toString().trim() ?? '').toList()) !=
          pythonJson(expected)) {
    invalid('Unrecognized CGD column layout');
  }
  if (!rows[2][1].toString().contains(' - EUR - ')) {
    invalid('Expected an EUR account export');
  }
  final start = spreadsheetDate(rows[3][1]),
      end = spreadsheetDate(rows[4][1]),
      records = <Map<String, dynamic>>[];
  int? footer;
  for (var i = 7; i < rows.length; i++) {
    final row = rows[i],
        values = row.map((c) => c == null ? '' : c.toString().trim()).toList();
    if (values.every((v) => v.isEmpty)) continue;
    if (values[0].isEmpty && values[4] == 'Saldo contabilístico') {
      footer = spreadsheetMoney(values[5].replaceFirst(RegExp(r' EUR$'), ''));
      continue;
    }
    if (footer != null) invalid('Unexpected rows after closing balance');
    final debit = spreadsheetMoney(row[3]), credit = spreadsheetMoney(row[4]);
    if (debit < 0 || credit < 0 || (debit == 0) == (credit == 0)) {
      invalid('Row ${i + 1}: expected one positive debit or credit');
    }
    final record = <String, dynamic>{
      'date': spreadsheetDate(row[0]),
      'valueDate': spreadsheetDate(row[1]),
      'description': values[2],
      'amount': credit - debit,
      'balance': spreadsheetMoney(row[5]),
      'availableBalance': spreadsheetMoney(row[6]),
      'bankCategory': values[7],
      'row': i + 1,
    };
    if (values[2].isEmpty ||
        (record['date'] as String).compareTo(start) < 0 ||
        (record['date'] as String).compareTo(end) > 0) {
      invalid('Row ${i + 1}: invalid description or reporting date');
    }
    records.add(record);
  }
  if (records.isEmpty || footer != records.first['balance']) {
    invalid('Missing or inconsistent closing balance');
  }
  for (var i = 0; i < records.length - 1; i++) {
    final newer = records[i], older = records[i + 1];
    if ((newer['date'] as String).compareTo(older['date']) < 0 ||
        newer['balance'] - older['balance'] != newer['amount']) {
      invalid('Balance/date continuity failed at row ${newer['row']}');
    }
  }
  return records;
}

List<dynamic> matchKey(Map row) => [
  (row['bookingDate'] ?? row['date']).substring(0, 10),
  row['amount'],
  (row['description'] as String)
      .toUpperCase()
      .trim()
      .split(RegExp(r'\s+'))
      .join(' '),
];
(Map<String, dynamic>, Map<String, dynamic>) planSpreadsheet(
  Map ledger,
  List<Map<String, dynamic>> records,
  String accountId,
  Map<String, dynamic> source,
  Set<dynamic> allowed,
) {
  final accounts = (ledger['accounts'] as List)
      .where((a) => a['id'] == accountId)
      .toList();
  if (accounts.isEmpty ||
      accounts.first['source'] != 'CGD' ||
      accounts.first['kind'] != 'CACC') {
    invalid('Choose a CGD current account');
  }
  final existing = (ledger['transactions'] as List)
      .where((t) => t['accountId'] == accountId)
      .toList();
  if (existing.isEmpty) {
    invalid('Existing account history is required to verify overlap');
  }
  final byKey = <String, List<dynamic>>{};
  for (final row in existing) {
    if (row['status'] == 'BOOK') {
      byKey.putIfAbsent(pythonJson(matchKey(row)), () => []).add(row);
    }
  }
  final dates = existing.map((t) => matchKey(t).first as String).toList()
        ..sort(),
      earliest = dates.first,
      added = <dynamic>[],
      links = <dynamic>[],
      occurrences = <String, int>{};
  for (final record in records) {
    final key = matchKey(record), candidates = byKey[pythonJson(key)] ?? [];
    if (candidates.isNotEmpty) {
      links.add({
        'row': record['row'],
        'transactionId': candidates.removeAt(0)['id'],
      });
      continue;
    }
    if ((record['date'] as String).compareTo(earliest) >= 0) {
      invalid(
        'Unmatched overlap at spreadsheet row ${record['row']}; review before import',
      );
    }
    final identity = pythonJson([
          accountId,
          key,
          record['valueDate'],
          record['balance'],
        ], ascii: false),
        occurrence = occurrences[identity] ?? 0;
    occurrences[identity] = occurrence + 1;
    final id = hashText('cgd-xlsx:$identity:$occurrence', 32),
        observation = {
          ...record,
          ...source,
          'id': id,
          'accountId': accountId,
          'provider': 'cgd_xlsx',
          'institution': 'CGD',
          'kind': 'bank_movement',
          'externalId': null,
          'currency': 'EUR',
        };
    added.add({
      'id': id,
      'accountId': accountId,
      'date': record['date'],
      'bookingDate': record['date'],
      'amount': record['amount'],
      'currency': 'EUR',
      'description': record['description'],
      'category': suggest(record['description'], record['amount'], allowed),
      'reviewed': false,
      'status': 'BOOK',
      'source': 'CGD',
      'hasStableId': false,
      'purchaseDetails': [],
      'relatedSourceIds': [],
      'sourceRecord': observation,
    });
    links.add({'row': record['row'], 'transactionId': id});
  }
  final ids = existing.map((t) => t['id']).toSet();
  if (!links.any((l) => ids.contains(l['transactionId']))) {
    invalid('No matching overlap to verify account assignment');
  }
  final transactions = [...ledger['transactions'], ...added]
    ..sort((a, b) {
      final d = (b['date'] as String).compareTo(a['date']);
      return d != 0 ? d : (b['id'] as String).compareTo(a['id']);
    });
  if (transactions.map((t) => t['id']).toSet().length != transactions.length) {
    invalid('Transaction identity collision');
  }
  final allDates = transactions.map((t) => t['date'] as String).toList()
        ..sort(),
      recordDates = records.map((r) => r['date'] as String).toList()..sort();
  return (
    {
      ...Map<String, dynamic>.from(ledger),
      'transactions': transactions,
      'historyFrom': allDates.first,
    },
    {
      ...source,
      'accountId': accountId,
      'rows': records.length,
      'added': added.length,
      'matched': records.length - added.length,
      'from': recordDates.first,
      'through': recordDates.last,
      'links': links,
    },
  );
}

class SpreadsheetImport {
  final LedgerStore store;
  Map<String, dynamic>? _result, _report;
  List<int>? _original, _bytes;
  String? _ticket;
  SpreadsheetImport(this.store);
  Map<String, dynamic> preview(String path, String accountId) {
    final file = File(path), bytes = file.readAsBytesSync();
    final records = parseSpreadsheetRows(readWorkbook(bytes)),
        original = store.journal.file('ledger.json').readAsBytesSync();
    final plan = planSpreadsheet(
      jsonDecode(utf8.decode(original)),
      records,
      accountId,
      {
        'sourceFile': p.basename(path),
        'sha256': digest(bytes),
        'sheet': 'comprovativo',
      },
      store.categoryIds,
    );
    _result = plan.$1;
    _report = plan.$2;
    _original = original;
    _bytes = bytes;
    _ticket = hashText(
      '${DateTime.now().microsecondsSinceEpoch}:${digest(bytes)}',
    );
    return {..._report!..remove('unused'), 'ticket': _ticket}..remove('links');
  }

  Future<Map<String, dynamic>> apply(String ticket) async {
    if (ticket != _ticket || _result == null) {
      invalid('Preview the spreadsheet again before importing');
    }
    if (digest(store.journal.file('ledger.json').readAsBytesSync()) !=
        digest(_original)) {
      invalid('Ledger changed during import; preview again');
    }
    final report = {
      ..._report!,
      'completedAt': DateTime.now().toUtc().toIso8601String(),
    };
    if (report['added'] > 0) {
      final folder = p.join(
        store.journal.root.path,
        'imports',
        DateTime.now().toUtc().microsecondsSinceEpoch.toString(),
      );
      final audit = LedgerStoreAudit(folder);
      audit.write('ledger-before.json', _original!);
      audit.write('source.xlsx', _bytes!);
      audit.write('report.json', utf8.encode(pythonJson(report)));
      final summary = {...report}..remove('links');
      _result!['fileImports'] = [..._result!['fileImports'] ?? [], summary];
      await store.journal.action(
        'Import bank spreadsheet',
        () => store.write('ledger.json', _result),
      );
    }
    _ticket = null;
    _result = null;
    return {...report}..remove('links');
  }
}

class LedgerStoreAudit {
  final String path;
  LedgerStoreAudit(this.path) {
    Directory(path).createSync(recursive: true);
    if (Platform.isLinux) {
      Process.runSync('chmod', ['700', p.dirname(path), path]);
    }
  }
  void write(String name, List<int> bytes) {
    final f = File(p.join(path, name));
    f.writeAsBytesSync(bytes, flush: true);
    if (Platform.isLinux) Process.runSync('chmod', ['600', f.path]);
  }
}
