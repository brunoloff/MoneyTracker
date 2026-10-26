import 'dart:convert';
import 'dart:io';

String masterKeyName(String dataPath) =>
    'moneytracker.master.${base64Url.encode(utf8.encode(dataPath))}';

Future<String?> findSourceImportKey(
  String source,
  Future<String?> Function(String) readVault,
) async {
  for (final path in {source, Directory(source).resolveSymbolicLinksSync()}) {
    final value = await readVault(masterKeyName(path));
    if (value != null) return value;
  }
  return null;
}
