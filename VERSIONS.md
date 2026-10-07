# Mac Vault version history

The owner approved this capability split on 2026-10-04. Existing tags and packaged downloads remain unchanged. All new records are **alpha, source-only**. A source record does not certify store submission, signing or native release acceptance.

Current source version: **2.2.6**. See the group-level `CHANGELOG.md` for the cross-product chapters.

## 2.2.6 — 2026-10-07 — Custom-origin log exports and JSON file picker

Save selected-rule text through the bounded native bridge because WebKit cancels Blob downloads from the app’s cbasset origin. Preserve existing Downloads files. Supply the native file picker required by macOS WebKit for Knowledge’s JSON file input. Show transfer failures beside the Settings controls, replacing stale success notices while preserving personal definitions.

## 2.2.5 — 2026-10-07 — Native rule log downloads

The native editor saves its Blob-based rule log downloads in Downloads, preserving existing files and concurrent exports. WebKit download failures are visible through the native error dialog.

## 2.2.4 — 2026-10-07 — Activity page position

Recording switches and incoming snapshots retain the outer Activity viewport, including the controls at the bottom of the page.

## 2.2.3 — 2026-10-07 — Activity scroll preservation

Background snapshots retain the hidden Activity page, preserving its newest-day and manually chosen timeline positions when returning from another page.

## 2.2.2 — 2026-10-06 — Classifier drafts and Activity range boundaries

Pending Classifier tag drafts survive model downloads; Activity includes sessions that overlap the selected range, including across midnight.

## 2.2.1 — 2026-10-06 — Installed resource lookup

Resolve the packaged icon, rule engines and editor assets from the installed app, without depending on the build machine’s folders.

## 2.2.0 — 2026-10-04 — Official dictionaries and portable desktop services

Source: `release/v2.2.0`.

- Official creator/term dictionaries, personal overlays, bounded caching and explicit contribution choices.
- Portable Classifier and Activity services support the Windows worker and separate authenticated Safari pairing.
- One app-wide Settings dialog and language choice, reviewed native guides, and consistent bounded overlays.

## 2.1.0 — 2026-10-01 — Activity detail and independent Classifier groups

Source: `7f2799d20e76744ebbfd5fa913f7541e3407a3dd`.

Retroactive milestone: the annotated tag names this exact historical snapshot. Its embedded version field retains the earlier number; no historical commit is rewritten and no package was distributed under this number.

- One WebView hosts Vault, Classifier and Activity. Activity adds usage/content views, permanent colors, view/merge groups, time blocks and recording controls.
- Each Classifier group owns its model settings and runtime status; group edits autosave.
- Budget snooze and bounded editor collections accompany the redesigned shared interface.

## 2.0.0 — 2026-09-27 — Shared blocking policies and the new rule contract

Source: `118f364f898a1cb717160a5ab43d1aa2676570fd`.

Retroactive milestone: the annotated tag names this exact historical snapshot. Its embedded version field retains the earlier number; no historical commit is rewritten and no package was distributed under this number.

- Shared scope-based groups, linked budgets, Freeze/PIN gates and user-controlled linking.
- The native apps-only engine adopts the bare (on, v) rule contract; the former helper API and count-up Timer mode are retired. This is a breaking behavior/API boundary.
- Tools use the same editor gates; disabled rules suppress effects, rule state survives Run, and in-app model downloads finish correctly.

## 1.2.0 — 2026-09-24 — Classifier and tool integration

Source: `e4aa80f690d6c80ddb6692e0a85e9311b0cc4516`.

Retroactive milestone: the annotated tag names this exact historical snapshot. Its embedded version field retains the earlier number; no historical commit is rewritten and no package was distributed under this number.

- Batched on-device classification, simpler tag-name output and a single research pass; thumbnail OCR and correction-text retrieval are retired.
- Simplified Classifier controls and community research, plus MCP access to Classifier actions and browser settings.
- Automatic local hub connection and self-registering browser helper.

## 1.1.0 — 2026-09-20 — Activity and one integrated application

Source: `e0a7d7301b0b273c02b7d6bc451de4118f341c47`.

Retroactive milestone: the annotated tag names this exact historical snapshot. Its embedded version field retains the earlier number; no historical commit is rewritten and no package was distributed under this number.

- Records native app and browser website usage in the Activity dashboard.
- Vault, Classifier and Activity share the application navigation and theme; the embedded hub runs without a standalone Classifier shell.

## Earlier versions

All existing `v*` tags, `release/v*` branches and published artifacts are retained. Their original details remain in the group changelog and website History.
