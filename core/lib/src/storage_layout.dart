import 'package:path/path.dart' as p;

const trackedFiles = {
  'ledger.json',
  'categories.json',
  'merges.json',
  'borrowing-groups.json',
  'tags.json',
  'taxonomy.json',
  'profiles.json',
  'preferences.json',
  'rules.json',
  'paypal-observations.json',
  'paypal-associations.json',
  'paypal-sync.json',
  'exchange-rates.json',
};
bool tracked(String name) =>
    trackedFiles.contains(name) ||
    name.startsWith('raw-') &&
        name.endsWith('.json') &&
        p.basename(name) == name &&
        !name.contains('\\');
const secretFiles = {
  'credentials.json',
  'session.json',
  'bank-sessions.json',
  'session-paypal.json',
  'connection-pending.json',
  'connection-result.json',
  'callback-key.json',
};
