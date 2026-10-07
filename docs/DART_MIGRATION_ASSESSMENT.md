# MoneyTracker migration from Python to Dart

Assessment date: 7 October 2026.

Implementation update: the native Dart service, personal-key setup, legacy data import, and Linux desktop package have now been implemented. The original assessment below is retained as the design record; see the root README for current build and migration instructions. Windows execution and live bank authorization still require validation.

MoneyTracker can move its local backend into Dart and run as a Flutter desktop application on Windows and Linux. No fundamental language or library obstacle was identified for personal desktop use. The migration is a substantial backend rewrite, with most of the risk in preserving saved data and behaviour rather than building the interface. Bank authentication, local HTTPS, and access to the existing undo database passed isolated feasibility checks on Linux. Windows integration and live bank authorisation remain acceptance requirements.

## Current implementation and migration scope

The interface is already Dart and Flutter: nine files under `app/lib`, approximately 5,000 lines. Its screens, category picker, charts, filtering, and most view calculations can be retained.

The backend has 13 Python files under `server`, totalling 1,539 lines. Authentication additionally comes from the 104-line `scripts/bank_test.py`; the CGD spreadsheet importer adds 184 lines. Two Linux launcher files and a separate matching-evaluation script bring all Python application and utility code to 2,067 lines. These counts describe the current implementation, not the size of its eventual Dart replacement.

| Current files | Responsibility | Migration work |
| --- | --- | --- |
| `scripts/bank_test.py` | Enable Banking HTTP requests, PEM loading, RS256 JWT signing | Implement a provider client using runtime credentials and an injectable HTTP transport. |
| `server/connections.py`, `server/bank_callback.py` | Bank selection, consent, session renewal, callback validation, TLS certificate generation | Preserve institution and state checks, expiration, replay protection, stable account identity, and credential separation. |
| `server/store.py` | Normalisation, pagination, retained history, IDs, payment projection, manual merges, category transfers | Port the domain rules with fixtures covering repeat imports, pending records, provenance, and manual edits. |
| `server/rules.py`, `server/taxonomy.py`, `server/profiles.py` | Classification, category and tag validation, account ownership and nicknames | Mostly direct translation; preserve rule priority, Unicode matching, and transfer semantics. |
| `server/paypal.py`, `server/reconciliation.py`, `server/exchange_rates.py` | Staged PayPal observations, matching, confirmation, historical ECB conversion | Preserve exact amounts, date windows, ownership restrictions, ambiguity checks, and explicit confirmation. |
| `server/undo.py` | Staged writes, compressed SQLite journal, grouped actions, undo and redo, crash recovery | Highest persistence risk. Existing history should survive migration rather than being reset. |
| `scripts/import_cgd_xlsx.py` | CGD XLSX parsing, balance checks, overlap matching, import backups | Replace `openpyxl` and port the importer, including its audits and rejection of ambiguous overlaps. |
| `server/main.py`, `server/lifecycle.py`, `server/version.py`, `launcher` | Local HTTP API, background jobs, authentication, process launch, server lifecycle | Replace desktop API calls with a local Dart service. Retain a separate HTTP adapter only if browser operation is wanted. |

`Ledger` currently mixes presentation state and HTTP access. Some widgets also call `ledger.post` directly: bank connection, preferences, rules preview, and PayPal review. Consequently, integration needs a service boundary across those screens, not just a replacement for `Ledger.load`.

## Proposed application structure

Keep Flutter widgets focused on presentation. Put normalisation, rules, matching, and validation in a Dart core that can be tested without Flutter. Add storage and bank-provider adapters around that core. A service interface should expose operations such as loading a snapshot, saving a rule, previewing matches, syncing, connecting a bank, and undoing an action.

Initially provide both the existing Python HTTP implementation and the new local Dart implementation behind that interface. This permits comparison against the current behaviour while the port is incomplete. Backend selection must never allow the two implementations to write to the same live dataset concurrently.

On desktop, a worker isolate should own storage and mutation ordering, perform substantial parsing and classification work, and report progress to the interface. Preserve the current behaviour of presenting committed data during a download and preventing conflicting changes. Cancellation, closing the window during sync, and reopening after interruption need explicit handling. [Dart isolates](https://dart.dev/language/isolates)

Start with the current JSON datasets and SQLite undo format. Preserve original bytes when copying data and importing journal blobs. Changing the language, file format, and undo design together would make differences harder to diagnose. A later move to one SQLite database could simplify atomic updates, but is a separate decision.

Use platform application-data directories for installation-independent storage and runtime credential provisioning. Desktop startup should not depend on the repository, a Python installation, or compilation. The old HTTP server's cookie, heartbeat, restart, and idle-timeout machinery can be retired from the native desktop path. Bank login still needs a small callback listener.

## Feasibility checks

The existing Python baseline passes all 97 tests. They cover classification, merged source records, bank sessions, pagination and retained history, PayPal and currency matching, imports, undo and redo, failed actions, and interrupted commits. They provide a useful behavioural specification, though passing them does not validate an unimplemented Dart port.

Temporary Dart experiments used synthetic data and generated RSA keys, without reading bank credentials or contacting the bank API. They ran with the project's Dart 3.12 SDK on Linux, using `dart_jsonwebtoken` 3.4.1, `basic_utils` 5.8.2, `sqlite3` 3.7.0, and `crypto` 3.0.7. Application dependencies were not changed.

| Experiment | Result and scope |
| --- | --- |
| Sign RS256 JWTs from PKCS1 and PKCS8 PEM keys | Passed. Python independently verified both Dart signatures and the expected Enable Banking header and claims. Provider acceptance of a live request is still to be checked. |
| Generate a local X509 certificate in Dart | Passed with an explicit `localhost` subject alternative name. Python independently verified its signature and hostname extension. |
| Serve and request a local HTTPS callback | Passed using both a Python-generated certificate and a Dart-generated certificate, with certificate validation enabled. Browser trust and actual bank redirects need platform testing. |
| Open a Python-created undo database | Passed. Dart read the existing tables and decoded gzip blobs, matching their SHA256 hashes and current-file manifest. Full undo, redo, and crash recovery were not ported. |
| Compare default JSON encoding | Defaults differ. The example included accented text and different object key order. Compatibility encoding is necessary for identities derived from Python JSON bytes. |
| Compare case-insensitive string handling | Defaults differ: Python casefold turns `Straße` into `strasse`; Dart lowercasing retains `straße`. Port full Unicode case folding or explicitly resolve this behaviour before changing existing rules. |
| Compare Python and Dart file locks | On this Linux system, Dart obtained its exclusive file lock while Python held `fcntl.flock` on the same file. The two locks must not be assumed to coordinate old and new writers. |

RS256 authentication is supported by Dart packages, and Dart provides a secure loopback HTTP server API. The SQLite package supports Windows and Linux and bundles its native library through build hooks. These are available components, not proof of a finished desktop release. [JWT package](https://pub.dev/packages/dart_jsonwebtoken), [Dart secure HTTP server](https://api.dart.dev/dart-io/HttpServer/bindSecure.html), [SQLite package](https://pub.dev/packages/sqlite3)

## Obstacles requiring deliberate implementation

### Transaction identity and arithmetic

Existing IDs connect imports to manual categories, tags, users, merges, and PayPal associations. Some IDs hash sorted Python JSON; others depend on its whitespace, escaping, or string representation. Preserve every existing ID and make new imports generate compatible IDs. Tests must include Unicode descriptions, accounts without identification hashes, transactions without stable provider references, repeated identical purchases, and reauthorised sessions.

Continue representing amounts as integer minor units. The Python code uses `Decimal` for parsing and currency comparison, including different rounding or truncation paths. A generic conversion through floating-point numbers is not equivalent. Preserve rounding, precision validation, and tolerance boundaries with exact decimal or rational arithmetic. Keep date-only accounting separate from time zones and timestamps.

### Undo history and crash recovery

The journal stores hashes of actual file bytes, before and after manifests, compressed content, a cursor, and an interrupted-operation manifest. Simply decoding and re-encoding all JSON on import can invalidate its expected current state even when the values look identical.

Port grouping, retention, redo branching, exclusion of credentials, external-change detection, and recovery after partial file replacement. Windows requires its own durability and replacement checks; a literal copy of POSIX directory flushing and permissions will not suffice. SQLite transactions do not automatically make the surrounding JSON-file updates atomic.

Dart's file locks also differ across operating systems. The migration should copy a stopped dataset into its new location and use one storage owner, with an in-process mutation queue as well as protection against a second app instance. [Dart file locking](https://api.dart.dev/dart-io/RandomAccessFile/lock.html)

### Bank authorisation and credentials

The current code requires `https://localhost:8443/callback` to be registered with the provider. Preserve it initially, including certificate reuse and renewal, state verification, attempt expiry, institution checks, and prevention of a second code exchange. The completion page should bring the user back to the desktop application instead of redirecting to the old browser interface on port 8765.

Generating a valid local certificate does not make browsers trust it automatically. Retest the flow with Windows and Linux browsers; changing to HTTP or a custom application scheme requires provider and registration verification. The cryptographic port has been demonstrated locally; an actual authorisation and harmless API request remain deployment gates.

Provision the user's private key at runtime and keep credentials outside undo history and installation files. If MoneyTracker is distributed to other people, never include a shared provider application key in the executable: Enable Banking explicitly advises against embedding it in installed applications. Distribution would require an acceptable credential model, such as a hosted component retaining the shared key, or separately verified user-managed registrations. That issue applies regardless of programming language. [Enable Banking authentication](https://enablebanking.com/docs/api/reference/)

Secure storage is available for Windows and Linux, but the Linux implementation's runtime dependencies and secret-service availability need packaging checks. Secure storage protects local credentials; it does not make a shared application key safe to distribute. [Flutter secure storage](https://pub.dev/packages/flutter_secure_storage)

### Existing browser operation

A native Dart backend can access local files and host a callback listener. Flutter running inside a browser cannot use the same filesystem and server facilities directly. If the existing browser version is retained, provide a local Dart HTTP adapter over the same core, or keep Python temporarily while that adapter is built. Native desktop migration can remove Python without committing to a browser-only banking design.

### Spreadsheet imports and release packaging

Dart XLSX readers exist, but the CGD importer's safeguards must be ported independently of workbook decoding: locale-aware money, date cells, sheet structure, running balances, repeated purchases, overlap verification, provenance, and backups. Readability of representative CGD workbooks is a remaining spike. [Dart Excel package](https://pub.dev/packages/excel)

Add Windows and Linux desktop targets, packaging, application-data discovery, secure-storage setup, icons, and builds on both operating systems. SQLite is a native library even when bundled automatically, so a Dart backend removes the Python runtime without making packaging entirely dependency-free. Linux experiments do not establish Windows behaviour.

## Migration sequence and completion criteria

1. **Define the service boundary and comparison fixtures.** Replace direct screen HTTP calls with typed operations while retaining existing behaviour. Extract synthetic cases from the Python tests, with deterministic clocks and IDs. Compare the same inputs and actions across implementations.
2. **Port the domain core.** Implement rules, validation, normalisation, payment projection, category transfers, merges, PayPal matching, and currency calculations. Require equal IDs, amounts, visible classifications, and provenance on comparison fixtures.
3. **Port storage and undo.** Use copied synthetic and representative datasets. Require preserved historical undo and redo, grouped confirmations, rollback after failures, external-change checks, and forced-interruption recovery on both platforms.
4. **Port provider and import adapters.** Integrate the demonstrated signing and callback components, then implement pagination, session renewal, progress, retained history, ECB XML, and XLSX import. Validate provider responses with fixtures before live authorisation checks.
5. **Integrate native desktop operation.** Make the local Dart backend the default, keep heavy work away from the interface, and test single-instance operation, cancellation, window closure, and restarting after a failed sync.
6. **Package and retire Python.** Import the stopped legacy dataset without changing identities or resetting history. Verify installation, updates, credentials, callback handling, imports, and data retention on clean Windows and Linux systems before removing Python as a runtime requirement.

The hardest work is behavioural and persistence compatibility. There is no identified need to rewrite the existing Flutter interface or retain Python permanently. A staged migration is justified for the long-term desktop application, with storage recovery and real bank login treated as release gates rather than assumed consequences of a successful build.
