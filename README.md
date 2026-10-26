# MoneyTracker

A Flutter personal finance dashboard backed by your local bank connection.

Implemented: aggregated payments, category bar chart, month/salary periods, search and account/category/direction filters, editable categories, salary marking, sync, and reversible merging with source provenance.

Public source: [brunoloff/MoneyTracker](https://github.com/brunoloff/MoneyTracker).
The [Desktop packages workflow](https://github.com/brunoloff/MoneyTracker/actions/workflows/desktop.yml)
builds and tests Windows and Linux archives. See [publication notes](docs/PUBLICATION.md)
for the source exclusions and packaged startup check.

Download the [Windows x64 ZIP](https://github.com/brunoloff/MoneyTracker/releases/download/v1.0.5/MoneyTracker-windows-x64.zip)
or [Linux x64 archive](https://github.com/brunoloff/MoneyTracker/releases/download/v1.0.5/MoneyTracker-linux-x64.tar.gz)
from the [1.0.5 desktop preview](https://github.com/brunoloff/MoneyTracker/releases/tag/v1.0.5).
Extract the entire archive; on Windows, run `money_tracker.exe`. No GitHub account
is needed to download these public release files.

For a first test, follow [the friend-testing checklist](packaging/TESTING.txt).
Testing help in setup, Preferences, and startup errors includes a copyable
version/build/platform summary. It does not collect bank data or credentials.
Arrange each person's own Enable Banking application and key before meeting.

## Run the desktop app

**Data compatibility:** current accounting format **v3**, with automatic import
of **v1/v2/v3**; SQLite undo schema **v1**, tables and banking-key encryption
unchanged. Version 1.0.6 adds explicit registration and verified backups without
rewriting financial files. Every archive includes `COMPATIBILITY.txt` and
`COMPATIBILITY.json`; see [formats, upgrade and recovery](docs/DATA_FORMATS.md).
Releases before 1.0.6 do not enforce version checks, so use a compatible complete
backup if downgrading. Preferences → Data and updates shows your actual format
and the last upgrade/import receipt.

MoneyTracker now runs as a standalone Flutter/Dart application on Linux and
Windows. Python is not required for the desktop application.

For this checkout, launch `launcher/run-native.sh`, or use the existing
MoneyTracker application-menu shortcut. The Linux executable is
`app/build/linux/x64/release/bundle/money_tracker`. Keep the complete bundle
beside it, including `lib/` and `data/`.

To build from source, use the pinned Flutter 3.44.1 SDK:

```sh
cd app
flutter pub get
flutter build linux --release  # on Linux
# flutter build windows --release  # on Windows with Visual Studio C++ tools
```

Linux needs GTK 3, libsecret and an unlocked desktop Secret Service keyring.
Windows uses the platform credential store. SQLite is bundled through Dart's
native-assets build. Windows and Linux release builds passed the core and Flutter
analysis/tests in [GitHub Actions](https://github.com/brunoloff/MoneyTracker/actions/runs/40315218627).
The extracted Windows ZIP also opened its window, initialized native storage,
and closed cleanly on the Windows runner. Linux operation was checked locally.
Real bank authorization and interactive use on recipients' Windows computers
still need separate testing. Archives contain only the built application and
instructions, with no bank keys or personal data.

### Personal setup and sharing

First launch opens a setup screen. Each friend/family member registers their
own Enable Banking application, exports their own RSA private key, and activates
restricted production access by linking their own accounts in Enable Banking's
control panel. Every account they intend to access must be linked. Register
`https://localhost:8443/callback` as a redirect URL. Setup verifies the key and
application using `GET /application` before saving. See the provider's
[registration instructions](https://enablebanking.com/docs/api/reference/#certificate-upload-and-application-registration)
and [own-account linking instructions](https://enablebanking.com/docs/api/linked-accounts/).

The app encrypts imported private keys and bank-session files with AES-GCM; the
master key is kept in the operating system credential store. They are excluded
from undo history. Keep the original PEM file separately as a backup. Share only
the application archive; everyone supplies their own credentials. Setup remains
available under Preferences → Users & accounts → Enable Banking setup.

Bank authorization opens the user's browser. A loopback-only HTTPS callback on
port 8443 completes it automatically. A locally generated certificate can cause
a browser certificate prompt. The dialog also accepts the final callback URL
manually. Bank downloads are explicit; startup and migration do not sync.

### Moving existing data

Close the old browser service before importing. The setup screen's **Import
existing MoneyTracker data** action copies the old `.private` folder into the
current user's application-support directory. The checkout launcher automatically
uses its `.private` folder on the first native launch. Existing JSON data,
transaction IDs, compressed SQLite undo history, and spreadsheet audit files are
preserved; sessions and private keys are encrypted in the new copy. The original
installation is kept unchanged. Import refuses to overwrite a populated app.

For this Linux installation, data is at
`~/.local/share/app.moneytracker.money_tracker/data`. A development-only
`MONEYTRACKER_DATA_DIR` override can isolate test installations. Keep using the
native application after migrating so future edits accumulate in one place.
The legacy browser backend remains available separately under `server/` and
`launcher/launch-legacy.py`; it uses the original `.private` folder.

### Using it

- In the desktop app, hold Ctrl and scroll the mouse wheel up/down to zoom the whole interface (50–200%). Ctrl+0 resets it to 100%. Zoom lasts until the app closes; ordinary wheel scrolling is unchanged.
- Click a colored category bubble to choose a category/subcategory, assign tags, or make a rule seeded from that transaction's description. A rule's description condition can match any linked source description (bank, PayPal, etc.); an AND group still matches within one source record.
- Preferences has section navigation on the left (a horizontal strip on mobile), preserving unsaved edits between sections. Preferences → Categories & tags configures names, colors, subcategories (one level), and tags. Subcategories appear under their parent, with an Add subcategory button for each parent. Names can change without breaking assignments. Used labels and built-in categories cannot be deleted. Chart totals roll up subcategories to their main category; category filters include descendants. Tags are independent, searchable labels; combine the tag dropdown with the category filter or search tag names (also `#tag`) in the search field.

- Preferences → Transaction history → choose 1–20 years → Download history. This requests older data for all connected accounts in the background and reports the earliest date/count returned per account. Bank/consent limits still apply. Failed downloads preserve the ledger, and repeat imports reuse record IDs. Routine bank and PayPal sync start on each account’s latest saved booked day, inclusive; older pending entries extend the overlap so their final status can be collected. Accounts with no history start with 90 days. Booked history stays saved.
- Sync → Sync everything runs exchange rates, bank statements, then PayPal. Unconnected sources are skipped. Completed stages stay saved if a later stage fails, and completed stages from one run share an Undo step. Exchange rates use the full ECB archive once, then request an inclusive `startPeriod` from the newest cached rate date through the ECB Data API and merge the result with the cache. Individual source buttons and explicit older-history downloads remain available.
- In PayPal review, use the eye-with-a-line icon to Ignore an unmatched payment. It is kept with the special `ignored` tag, hidden from matching/review, and excluded from totals. Use Ignore all unmatched / ambiguous to clear the remaining unselected rows at once; exact, FX and manually selected matches are left alone. Expand Ignored to Restore items, or use one Undo to reverse the bulk action. Ignoring preserves the other pending review choices and stays remembered after sync and restart. The tag can also be applied to bank payments; ignored entries do not anchor salary periods or count toward income averages.

- Click a payment to correct its category or choose Salary / Transfer.
- Special categories appear first in category selectors: Uncategorized, Salary, Ignored, Borrowing and Deposits, Transfer, and Other income. Their stable IDs preserve their accounting behavior when renamed. Special categories cannot be deleted or moved under another category; Uncategorized also keeps its fixed name and color. Ignored works as a category as well as the existing exclusion tag.
- Mark advances, deposits, loans to others, and expected reimbursements as Borrowing and Deposits. Both outgoing and incoming amounts in this category (or its subcategories) stay outside spending, income, Net and historical income averages. Uncategorized remains part of ordinary accounting; confirmed Salary anchors salary periods; Other income and Salary require positive amounts.
- Overview → Borrowing and Deposits opens grouping across all dates for the selected person/account. Select two or more booked payments, name the group, and choose an account for the leftover. The members disappear from the main list and their signed sum becomes a virtual payment, dated on the latest member’s date. For example, −€100 and −€20 plus a €90 repayment produce a −€30 leftover. It starts excluded in Borrowing and Deposits; change its category to count it as ordinary spending/income, or group it with a later repayment. Cross-account groups require the same account owner; the leftover belongs to one chosen account.
- Open a leftover and choose View borrowing group to inspect its members. Leftovers cannot be deleted directly or merged as duplicate bank records. Delete the group to restore its individual members. If a later group uses the leftover, delete that later group first. Group creation, deletion, categories and tags support Undo/Redo and persist through restart and data import. Original bank records remain intact; corrected bank amounts recalculate the balance, including nested groups.
- The top bar contains Overview, Rules, and Preferences, plus a saved user selector.
- Preferences lets you add/rename/remove users and assign each account to one user. Save assignments to apply them. All users includes unassigned accounts; individual users filter payments, totals, and salary periods. These are local views sharing classification rules, not separate login accounts.
- Overview supports By month / By salary with a 1–24 period count. The range ends at the displayed month or salary segment; arrows slide it one period. Choose Total or Monthly average for multiple periods. Calendar-month averages divide by selected months (including the current partial month); salary averages divide by calendar-month equivalents of days covered. Only summary/chart amounts are averaged, never individual payments. Ranges before imported history show a warning.
- Overview contains the chart and payments. Preferences selects Calendar month or Since last salary; arrows navigate previous/next months or salary periods.
- With one calendar month selected, the Income display offers This month, Last month, or Average over last X months (1–24). Last month and the average are relative to the month being viewed; the average uses the preceding complete calendar months and includes zero-income months. Both choices are saved. Spending and the payment list still use the selected month; Net is the displayed income minus the displayed spending. Income-history gaps are flagged.
- Rules lets you create OR groups of AND conditions, preview matches, and choose a category. The first enabled rule wins; manual categories take precedence. Rules can be edited, reordered, disabled, or deleted.
- Click a chart bar to filter the list; click again to clear that category.
- Merge matching payment links two equal-amount records after confirmation. Both descriptions remain in Source records. Undo merge restores separate payments.
- PayPal observations can be downloaded and explicitly matched from Sync. Amazon purchase-level enrichment remains future work.

### Other targets and checks

Android/iOS remain scaffolds, rather than supported releases. Browser builds
still compile and use the retained legacy HTTP backend; desktop requests go
directly to the Dart service in a background isolate without opening an HTTP
API server. Borrowing groups and the reserved special-category behavior are
implemented in the native Dart service; the retained legacy Python backend
does not support these new operations.

```sh
cd core
dart pub get
dart analyze
dart test
cd ../app
flutter analyze
flutter test --concurrency=1
```

The Dart suite uses synthetic Python golden fixtures for transaction identity,
Unicode matching, payment projection, spreadsheet imports, and old undo blobs.
Python is needed only to regenerate those fixtures or test the retired backend.

See [architecture](docs/ARCHITECTURE.md) for accounting and reconciliation semantics and [design QA](docs/DESIGN_QA.md) for the visual review.
### Importing a CGD spreadsheet backfill

Use Preferences → Transaction history → Import CGD spreadsheet. Select an
existing CGD current account, choose its EUR comprovativo XLSX export, review the
preview, and import. The Dart parser checks dates, exact cents, running balances,
closing balance, and overlap with existing booked rows. Only older movements
are added; repeated purchases are preserved and repeated imports add nothing.
A ledger backup, source workbook and audit report are saved under `data/imports/`.
The import is undoable. Formulas and external workbook links are rejected.

### Undo and redo

Use the history icon in the top bar to undo the last saved action or redo it. Syncs, imports, settings, rules, categories, tags and payment associations are covered; a PayPal confirmation spanning several batches is one step. History is persistent; existing Python history is retained during migration. Bank authorizations and changes made outside MoneyTracker are not reversed. Undo becomes available after an active sync finishes. New edits after undo replace the redo branch.

Preferences → Undo history controls retained actions (default 100; 0 means unlimited). Reducing the limit permanently discards older steps.
