# MoneyTracker maintenance

Preserve users' saved data and support friends/family who update independently.

- Every update report and release description must explicitly state the data
  format before/after, whether financial files or the SQLite schema change,
  automatic migration/backup behavior, and downgrade compatibility. Say
  **Data format unchanged** when it is unchanged; do not omit this information.
- The data-format contract includes accounting semantics, not only JSON shape.
  See `docs/DATA_FORMATS.md` and `core/lib/data_formats.dart`. Bump the format
  when older readers cannot safely interpret the new stored data. Document
  additive fields even when they are backward compatible.
- Keep readers and tested migrations for every released format. Refuse unknown
  newer versions before writing. Keep format metadata outside Undo/Redo.
- Back up existing data before upgrading it. Imports must preserve the source,
  verify copied files, retain history/unknown compatible fields, and handle
  native credentials with the original operating-system keyring key.
- Test upgrade, import, restart, Undo/Redo, newer-format refusal and failure
  paths using synthetic historical fixtures. Audit a stable, read-only copy of
  local data when authorized; never print bank details or credentials.
- Update compatibility notes, package documentation and the in-app Data and
  updates information alongside any format change. Test Windows and Linux.
- The original development folder also holds private data. When `.public-repo/`
  exists, publish deliberately selected source/test files through that checkout;
  never copy the whole original directory. Work normally in a clean Git clone.
