/// Version the persisted accounting contract separately from the app release.
const currentDataFormat = 3;
const oldestDataFormat = 1;
const currentJournalFormat = 1;
const dataFormatFile = 'data-format.json';
const dataFormatName = 'moneytracker';
const dataFormatDescriptions = {
  1: 'Original ledger, classification, connections and undo history',
  2: 'Incremental sync metadata and the special Ignored tag (1.0.4)',
  3: 'Special categories, borrowing groups and virtual leftovers (1.0.5)',
};
const downgradeGuidance =
    'Use this version or a newer compatible version. Older releases do not '
    'enforce format checks and can show incorrect totals. To downgrade, close '
    'the app and restore a compatible pre-upgrade backup first.';
