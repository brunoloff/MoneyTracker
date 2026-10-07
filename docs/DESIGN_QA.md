# Design and verification

The user accepted `design-concept.png`. Generated with the built-in ImageGen tool: a white Flutter dashboard and mobile counterpart, navy type, teal actions, summary strip, horizontal category bars, payments table/list, Preferences and Sync. Fictional data only was supplied to the image generator. Full prompt was recorded in the task tool call.

Implemented screen: `app/lib/dashboard.dart`; bundled Roboto fonts; native Material controls/icons. No raster mockup is used as the application interface.

## Visual review

Offline Flutter widget renderer, synthetic fixture, 1100×1100 desktop and 390×1100 mobile. Golden images are reproducible in `app/test/goldens/`. These are test-rendered images, not browser screenshots. Reviewed with view_image against the accepted design.

1. Copy: MoneyTracker, Your money clearly, subtitle, Expenses by category, All payments, Preferences and Sync preserved. Headline punctuation preserved in implementation.
2. Palette: white surfaces, navy typography, teal controls; category hues match. Deliberately flat bars rather than generated gloss.
3. Layout: summary → category bars → table/list, centered desktop, stacked mobile; responsive toolbar.
4. Typography: bundled Roboto regular/bold; fixed missing font loading in offline renders and dropdown text, reduced mobile metric size.
5. Controls: native Material settings/wallet/category icons. Mobile uses icon-only Sync/Preferences. Slightly rounder Material buttons than concept.
6. Data: real imports in the running app; synthetic amounts only in golden fixtures. Added income filter, count, source provenance, explicit category-review state and merge details for required functionality.
7. Spacing: fixed mobile header crowding. Mobile list has category chips and account labels. Table may extend below the first viewport; full page scrolls.

Above-fold intentional copy additions: chart-filter hint and conditional no-salary/error messages. Running values are data-driven, not hard-coded mockup amounts. Category list length is data-driven.

Browser/IAB opening of http://localhost:8765 was denied by browser security review (reported permission declined). No alternative browser was used to bypass it. Consequently browser-rendered fidelity and browser interactions are NOT verified, and exact native-size reproduction of the composite design board is not claimed. Offline render verification and widget interactions pass. Physical Android/iOS device testing remains outstanding.

## Checks

- Python: exact cents, account-scoped IDs, currency rejection, category overrides, stable identities across reauthorization, merge count/provenance, undo and invalid merge rejection.
- Flutter: month boundaries, salary confirmation, transfer/pending exclusion, filter scope; preferences and details at mobile/desktop sizes; reproducible goldens.
- Flutter static analysis and release web compilation.
