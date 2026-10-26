# Data formats and update compatibility

**Current accounting data format: v4. Supported older formats: v1, v2 and v3.**
**SQLite undo schema: v1; its tables and compressed history format are unchanged.**
**Banking credential encryption: MTK1 / AES-GCM, unchanged.**

App releases and data formats are separate versions. A format describes both
stored structure and the meaning needed to calculate correct totals. Reading
JSON successfully does not prove that an older app understands the accounts.

| Data format | Introduced | Contract |
| --- | --- | --- |
| v1 | Original Python and native releases through 1.0.3 | Ledger JSON, stable transaction/account IDs, classification overrides, duplicate merges, tags, rules, profiles, preferences, PayPal observations/associations, rates and SQLite undo history. |
| v2 | 1.0.4 | Adds optional `ledger.syncStarts` and `paypal-sync.accountStarts`; retains the existing rate-cache shape. Gives tag ID `ignored` its exclusion and review behavior. Old apps can read the files but may incorrectly count ignored entries. |
| v3 | 1.0.5 | Adds `borrowing-groups.json`, virtual leftover identities and group dependencies. Reserves Ignored and Borrowing and Deposits category IDs and excludes them from ordinary accounting. Old readers do not project these groups correctly. |
| v4 | 1.0.8 | Adds optional `rules[].userId` and per-user `useSharedRules`/`usePersonalRules` settings. Shared and personal rules combine with OR; personal category rules take priority. v3 readers cannot safely interpret scopes. |

Version 1.0.6 adds explicit version registration and checks; it **does not
introduce another accounting-payload format**. Existing data is registered as
v3, and the SQLite header's `user_version` is set to 1. No transaction JSON,
classification file, rate cache, bank-key ciphertext, history row or history
blob is rewritten as part of this registration. Completing an already pending
journal recovery remains necessary and behaves as before.

Version 1.0.7 computes Overview account and Borrowing and Deposits balances
from existing data. **Data format unchanged: v3 → v3; SQLite schema v1 → v1.**
It adds no stored fields, financial-file rewrites, migrations or new backups
for registered v3 data. Older-data registration and verified backups continue
as described below. Data from 1.0.7 remains compatible with 1.0.6 without conversion.

Version 1.0.8 upgrades older data to **v4**, with a verified complete backup
before the marker changes. Existing rule and financial files stay byte-for-byte
unchanged: rules without `userId` are shared. No SQLite table/history conversion
or credential re-encryption is needed for this in-place upgrade. Versions
1.0.6/1.0.7 refuse v4; earlier versions can misapply personal rules to all users.

## Shared and personal rule contract

`rules.json` remains an ordered list. Missing/null `userId` means shared;
a stable user ID means personal. Each category and tag condition keeps its
existing OR-of-AND-groups semantics, including matching one linked source per
AND group and income-only Salary rules. Shared and personal conditions form
an **OR union** for each label. Personal category rules run first, then shared
rules, preserving the saved order within each pool. Manual categories override
both. Matching tag actions from either enabled pool accumulate independently
of category conflicts. Paused rules do not apply.

`profiles.users[].useSharedRules` and `usePersonalRules` are optional booleans,
both defaulting to true. Disabling a pool for one user preserves its rules and
does not affect other users. Ownership follows `profiles.accountUsers`, not
the selected dashboard view. Unassigned accounts use shared rules. A merged
payment follows its canonical account; if unassigned, a unique linked owner
is used, otherwise only shared rules apply. Virtual leftovers follow their
chosen account. Deleting a user keeps personal rules dormant; Undo can restore
that user and their assignments. A different user never inherits those rules.

Saving/consolidating category conditions and reordering priorities affect only
the chosen pool. Category transfers consolidate each pool separately. Rule
previews use the same ownership, enablement and priority logic as classification.
The format marker remains v4 even when all personal rules have been undone;
preflight also detects scoped rules/settings retained only in history.

## Explicit marker and preflight

The data folder contains `data-format.json`:

```json
{"format":"moneytracker","version":4,"journalVersion":1,"migrations":[]}
```

The marker also records registration dates and migration/backup receipts. It is
outside financial Undo/Redo: undoing a payment edit cannot downgrade the format.
An unversioned installation is inspected for the minimum format required by
its data and rule-scope/borrowing-group references in retained undo/redo history. This
inference identifies a compatible format, not the exact producing app release.

The app rejects unknown newer marker versions, newer SQLite `user_version`
values, unknown undo-table layouts and unsupported files in history **before
writing to that data folder**. A missing or corrupt marker is never treated as
permission to reset a populated database. Compatible unknown JSON fields remain
unchanged. Every released supported format must retain a tested reader/import.

## Automatic registration, backups and recovery

Before upgrading/registering an existing installation, the app holds its owner
lock and copies the original files into
`backups/before-data-v4-<timestamp>-<id>/`. This includes the original SQLite
file, financial JSON, encrypted credentials, raw downloads and import audits,
all under the backup's `data/` subfolder.
Existing backup folders and the process lock are omitted. Each file is flushed
and checked by SHA-256; a separate `backup-manifest.json` receipt (backup format
v1) records the originals. Keeping the receipt beside the payload avoids filename
collisions when restoring a previous backup.
If backup creation or verification fails, registration stops. Subsequent opens
of an already current installation do not create another backup.

The dashboard shows a dismissible registration/import receipt with the format
transition and backup location. Preferences → Data and updates keeps this
information available. Testing help includes supported format versions in its
copyable build information, without paths, bank details or credentials.

To recover an in-place installation, close every MoneyTracker copy, preserve
the current folder separately, and restore the **complete contents of the
backup's `data/` subfolder** to the original data-folder path. Keep the original OS user/keyring: encrypted banking
keys depend on its master key. Do not restore individual JSON files while
leaving an unrelated undo database, and do not include a stale SQLite WAL or
journal file from the newer folder. A backup with a pending transaction is
recovered from its copied journal on opening.

## Imports

Imports preflight the source version, copy known data and the format marker to
a staging folder, verify every copied file and the projected ledger, and only
then install the copy. The original folder remains unchanged and is shown as
the import's recovery source. v1, v2, v3 and v4 imports preserve IDs, extension fields,
duplicate links, manual categories/tags, rules, profiles, preferences, PayPal
state, rates, borrowing groups and undo/redo history.

Native imports resolve the source folder's key from the original OS keyring on
the UI isolate, use it only for local decryption, and re-encrypt credentials
with the destination key. Keys do not enter history, format markers, reports or
network requests. Legacy plaintext credentials are encrypted in the copy. If
the original native key is unavailable (for example on another OS/user), import
fails clearly before installing unreadable credentials; the source is retained.
Keep the original PEM key and the original OS keyring for credential recovery.

## Downgrading and future releases

**Versions 1.0.6 and 1.0.7 refuse v4 data before writing.** To return to either,
restore a complete compatible pre-v4 backup to its original location and retain
the original OS user/keyring. Do not remove/edit the version marker to bypass
the guard: older code would apply personal rules globally and could rewrite
scoped rules incorrectly. Keep the upgraded folder separately before restoring.

**Releases before 1.0.6 cannot enforce format-version checks.** In particular,
1.0.3 does not implement the Ignored tag, and 1.0.4 does not understand borrowing
groups or the new special-category semantics. Do not use those versions on
newer data: they can display incorrect totals or damage later undo operations.
Use an appropriate complete pre-upgrade backup if a downgrade is required.

Every release description and development handoff must state the old/new data
format, SQLite schema impact, migration/backup behavior, downgrade limitations
and validation. Say **Data format unchanged** explicitly when appropriate.
Increment the data format for incompatible structure or accounting semantics;
document compatible optional fields as well. See `AGENTS.md` for maintenance
requirements and `docs/PUBLICATION.md` for verified release evidence.
