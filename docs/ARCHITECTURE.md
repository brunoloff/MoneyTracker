## Native desktop runtime

The current Linux/Windows application uses `core/lib/src/service.dart` inside a
Dart isolate. `app/lib/platform/runtime_native.dart` bridges the existing Ledger
request boundary in memory; there is no desktop HTTP API listener and no Python
process. JSON ledger files and the SQLite/gzip undo schema remain compatible with
the original backend. Mutations are serialized, sync stages tracked writes in a
separate async zone, and committed readers remain available during downloads.
Pending manifests recover multi-file commits on next startup. Linux additionally
flushes directory entries after atomic file replacements.

`setup_page.dart` handles each person's own Enable Banking credentials and legacy
import. Private keys and sessions use authenticated encryption with an OS-held
master key. They never enter the undo journal. The only native local listener is
the TLS authorization callback on localhost:8443. Current desktop packaging and
first-run steps are documented in the root README. The Python files below are
retained for compatibility fixtures and the legacy browser app.

# MoneyTracker v0.1

Flutter UI (`app/lib`) → loopback-only Python service (`server`) → Enable Banking.
The bank private key and session never enter the Flutter bundle. The local service serves only the compiled web directory and authenticates API calls with an HttpOnly SameSite cookie (native development can use a bearer token). It is not an Internet-facing deployment.

## Records versus payments

`ledger.json` stores imported source observations. Each has an account-scoped provider reference, original description, dates, signed integer EUR cents, source identity, and a `sourceRecord`. Stable account identities derive from the bank's identification hash rather than its expiring session account UUID. Current source: CGD via Enable Banking.

`merges.json` stores reversible relationships between source observations. `snapshot()` projects those into canonical payments with `sourceRecords[]`, `accountIds[]`, `purchaseDetails[]`, and a single amount. The primary record determines date, amount, and category; secondary records remain available and are not counted again. An undo removes the relationship and restores both independent payments. Category overrides remain separate and survive imports/undo. Equal amount, currency, and status are required for this first manual merge; equal amounts are never automatically matched.

Future PayPal/Amazon adapters should produce source observations and item details, then match them to an existing payment. A receipt/item enrichment is not inherently a second money movement. Order splits, several charges per order, fees, currency conversion and refunds need an allocation/reconciliation model before automatic matching. Do not infer equivalence from amount or merchant alone. No Amazon or PayPal connector is implemented yet.

## Budgets

- Date = transaction date if present, otherwise booking date, otherwise value date.
- Calendar month uses [first day, first day of next month).
- Salary periods run from one confirmed positive booked Salary date (inclusive) to the next (exclusive), with previous/next navigation. The latest period runs through today. User-authored Salary rules also confirm a boundary; same-day salary payments share a single boundary. It follows the selected account filter. Without one, the UI shows incoming records to mark, rather than inventing a start date.
- Only booked payments enter totals; transfers are excluded. Expenses are gross debits; positive refunds are currently included in income, not subtracted from expenses. UI explains this.
- Search, direction and category filters affect the list. Account and period affect both chart and list.
- Suggestions are deterministic merchant rules, explicitly unreviewed. Salary is never guessed. Correct categories from the detail sheet.
- First import fetched 90 days. Normal sync refreshes that window while retaining booked history. Preferences can backfill 1–20 years using Enable Banking’s longest-history strategy with a date_from hint and complete pagination. Backfill overlays returned IDs without removing existing records; bank or consent limits can still truncate results. Per-account earliest dates and counts are saved in historyImport, distinct from the requested date. EUR only: other currencies are rejected instead of summed incorrectly.

## Limitations

Native Android/iOS project shells exist; physical-device validation and secure remote hosting/pairing are not completed. The preview works on this computer; localhost on a phone refers to the phone. No bank authorization UI yet: existing `scripts/bank_test.py` completes consent. No recurring-payment detection or future budget forecasting yet.

## Classification rules

`rules.json` contains ordered, enabled/disabled DNF rules: `groups` is an OR list of AND lists of `{field, operator, value}` conditions. Description and source support includes, does-not-include, starts-with, ends-with and equals, ignoring case; direction supports income/expense. No regex or executable expressions. Each AND group must match one source observation, avoiding combinations of unrelated properties across merged records.

Classification is derived on each snapshot: manual category override > first enabled matching rule > original imported keyword suggestion. Saving, reordering, disabling or deleting rules reclassifies history without changing source observations. Preview shows matches and payments protected by manual overrides or earlier rules. Salary/Other income rules cannot classify debits. The UI requires a preview before saving an edited rule.

## User views

`profiles.json` stores named users and a map from stable account ID to user ID. One account has at most one owner; removing a user leaves their accounts unassigned and never deletes bank data. `preferences.json` also stores the selected user, preserving the budget period when changing views. All users includes all accounts; Unassigned includes accounts without an owner. Overview scopes account choices, payments, totals and salary dates together. A merged payment with multiple account IDs is included once if any account belongs to the selected user; per-user totals therefore are not necessarily additive across cross-user merged records. Rules remain shared across the local dataset.

## Categories, subcategories and tags

`taxonomy.json` holds stable category/tag IDs, editable names, category colors and optional category parent IDs. The tree is limited to main category + subcategory. Original category names remain their stable IDs for compatibility; new IDs are independent of labels. Salary/Other income/Transfer semantics follow the root category. Removal is rejected for built-ins or any category/tag used by observations, overrides or rules.

`tags.json` stores per-payment labels separately from immutable imported observations. Merged payments initially union their source payments' tags. Saving tags on a merged payment replaces that combined set. Tags affect list searches and the independent tag filter, never chart grouping. Chart totals aggregate leaf categories into roots. Category and tag filters intersect; tag names also participate in free-text search. The bubble picker seeds a new DNF rule with the full transaction description and still requires preview before saving.

### Overview calculation cost

Flutter caches selected/sorted transactions and salary dates by the immutable
snapshot collections, user/account selection and current day. A separate range
cache computes spent, income and parent-category totals in one pass, with period
boundaries outside the loop. Table filters use a third cache and lazy normalized
search strings; they do not invalidate the range totals. Replace collections on
refresh (as `ingest` does), rather than mutating cached input collections in place.
Only the active dashboard pane receives a new widget; visited inactive panes keep
state and pause animations. Sync progress uses authenticated `/api/status` polling
and reloads the full ledger once on completion. `/api/ledger` omits redundant
storage/audit fields and supports gzip; the on-disk ledger retains full provenance.

`app/test/performance_test.dart` exercises 30,001 records, checks aggregate-cache
reuse during search, and verifies invalidation on range, owner, taxonomy, refresh
and day changes. Timings are reported, not used as machine-dependent assertions.

### PayPal reconciliation groundwork

`server/reconciliation.py` suggests (but never applies) links between staged
purchase observations and existing booked bank payments. It accepts explicit bank
account IDs and a 0–31 day window (default 7), indexes exact signed amount and
currency, checks transaction and booking dates, and ranks PayPal bank descriptions
first. Competing candidates in either direction are flagged for review. Funding
transfers, non-booked records and already PayPal-linked payments are excluded.
FX, fees and split payments are deliberately not approximated into equal amounts.
This module is tested but not yet exposed in the UI or connected to a PayPal feed.
The feed route depends on account API permissions; a CSV activity export is the
alternative. Importing a purchase as an additional counted debit before linking
it to its bank charge would double-count spending, so staging/review is required.


## PayPal sync and association review

The Sync header action opens a source page. Bank sync supports all accounts or one stable account ID, preserving other accounts and pending records. PayPal uses its separate Enable Banking session and stores observations in `.private/paypal-observations.json`; unassociated observations do not enter EUR budget totals.

Review restricts candidates to booked, same-direction bank movements mentioning PayPal/PYPL and with the same account owner (including both unassigned). The exact group requires equal minor-unit amount/currency, 0–7 calendar days posting delay and uniqueness in both directions. Different-currency candidates in that window must also satisfy the configured tolerance around a downloaded historical ECB conversion. They remain tentative until confirmed. Search offers eligible close calls within 31 days; the conversion tolerance also applies to different-currency search results. All associations require confirmation, including exact matches.

Confirmation revalidates candidates and enforces one-to-one links atomically in `paypal-associations.json`. Snapshot projection attaches the PayPal source and preferred description to the canonical bank payment, preserving the bank date, category override, currency and amount. Classification rules see all source descriptions. Existing confirmed pairs never reappear in review. Editing/removing PayPal associations is deferred.

### Historical conversion matching

Sync can download the ECB historical XML into `exchange-rates.json`, atomically replacing the cache only after successful parsing. Rates express currency units per EUR; cross conversion is amount × target rate ÷ source rate. Matching uses the latest published day at or before the PayPal date (at most seven days earlier), never a future or arbitrarily stale rate. Missing currency/date coverage leaves the payment unmatched. Different-currency candidates, including the manual search results, must fall within `fxTolerancePercent` (default 10, configurable 0–100 in Preferences → Payment matching). The review shows the converted amount, relative difference, and rate date tooltip.

Review uses compact horizontally scrollable tables in collapsible sections. Exact and foreign-currency suggestions start selected, reserving exact matches first and preventing duplicate bank selections. Confirmation remains explicit. Collapsing a section retains its selections.

PayPal's Sync source panel includes a start-date picker (last seven years, default 90 days). The selected `dateFrom` is validated before starting the worker and sent on every provider page with the longest-history strategy. The last successful requested date and actual returned date range/count are retained in `paypal-sync.json` and displayed in Sync/review. Requesting older history never discards previously staged payments or confirmed associations; provider coverage can be shorter than requested.

Confirmation submissions are split into batches of 40 to remain compatible with already-running servers' 8 KiB request limit. Each batch is atomic; after a later failure, the app reloads pending records and reports the confirmed count. Updated servers additionally allow up to 1 MiB and 5,000 pairs on the confirmation endpoint only; unrelated endpoint limits remain unchanged.

## Persistent undo and redo

The header history menu undoes/redoes saved actions, including ordinary/history bank sync, PayPal sync, exchange-rate downloads, spreadsheet imports, classifications, rules, tags, taxonomy, profiles, preferences, merges and PayPal associations. Tracking begins with installation; there is no fabricated history for earlier actions. Authentication credentials/consents, application binaries, provider-side state, transient navigation/search and unsaved editor text are outside this data journal.

`server/undo.py` stages writes to the application datasets in memory during a logical action. Reads by that action see staged values; other readers see committed data. A compressed, content-addressed SQLite journal stores changed files' before/after versions in `.private/undo.sqlite3`. Unchanged files produce no entry; history persists with a configurable action-count limit (100 by default, 0 for unlimited). External file edits are detected on restore rather than overwritten. New edits after undo discard the redo branch. When the limit prunes old actions, unreferenced compressed blobs are deleted; SQLite reuses freed pages. Lowering the limit permanently removes those older steps, even if the preference is subsequently undone.

A filesystem writer lock serializes cooperating processes. Commit/restore holds the shared reader lock, durably records a pending manifest in SQLite, atomically replaces each file and fsyncs its directory, then clears the manifest. Startup recovers interrupted multi-file operations. Failed downloads/validation discard staged data entirely. The HTTP service rejects writes and undo/redo during background sync while allowing progress/read requests. Standalone spreadsheet import and bank-sync entrypoints also create logical journal actions. New mutable app datasets must be registered in `undo.FILES`.

One PayPal confirmation sends a shared `actionId` across its 40-pair requests. Consecutive successful batches combine into one journal entry, preserving the original before-state and latest after-state. A partially successful confirmation is also undoable as one action. Intervening unrelated edits intentionally prevent grouping across those edits. Undo refreshes the ledger and recreates page state to discard stale derived/editor state.


### Desktop updates

The running server reports a startup source fingerprint in `/api/health`. The desktop launcher compares it with current backend files and reuses matching instances. For outdated instances it waits for sync to finish, requests authenticated graceful shutdown, waits for the port to close, then starts the new server and opens the browser. For a one-time upgrade from older versions without that endpoint, the launcher only signals a process whose command resolves to this project's server script and whose file descriptors own the loopback 8765 listening socket. It refuses to kill unidentified processes. No icon reinstall is required: the desktop entry calls the same launcher script.
