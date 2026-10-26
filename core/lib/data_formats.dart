/// Version the persisted accounting contract separately from the app release.
const currentDataFormat = 4;
const oldestDataFormat = 1;
const currentJournalFormat = 1;
const dataFormatFile = 'data-format.json';
const dataFormatName = 'moneytracker';
const dataFormatDescriptions = {
  1: 'Original ledger, classification, connections and undo history',
  2: 'Incremental sync metadata and the special Ignored tag (1.0.4)',
  3: 'Special categories, borrowing groups and virtual leftovers (1.0.5)',
  4: 'Shared and per-user rule pools and per-user rule settings (1.0.8)',
};
const downgradeGuidance =
    'Use this version or a newer compatible version. Apps supporting only '
    'older formats cannot safely read this data; some older releases lack '
    'version checks. To downgrade, close the app and restore a complete '
    'compatible pre-upgrade backup first.';
