import 'compat.dart';

/// Repeat the last booked day, extending the overlap for unresolved pending rows.
String incrementalStart(
  Iterable<dynamic> rows,
  String accountId, {
  DateTime? now,
}) {
  final today = day(now ?? DateTime.now());
  String? latest, pending;
  for (final row in rows) {
    if (row['accountId'] != accountId) continue;
    final date = row['date'] as String;
    dateOnly(date);
    if (date.compareTo(today) > 0) continue;
    if ((row['status'] ?? 'BOOK') == 'BOOK') {
      if (latest == null || date.compareTo(latest) > 0) latest = date;
    } else if ((row['status'] ?? '') == 'PDNG') {
      if (pending == null || date.compareTo(pending) < 0) pending = date;
    }
  }
  final start =
      latest ?? day(dateOnly(today).subtract(const Duration(days: 90)));
  return pending != null && pending.compareTo(start) < 0 ? pending : start;
}
