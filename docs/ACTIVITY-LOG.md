# Activity Log — design

> **Status: BUILDING (2026-09-19).** Owner ask: an integrated feature that
> records the user's own activity — app use time, time on websites, and the
> content they watch — shown as a dashboard (pie chart), local-only, per-category
> opt-in, with user-controlled retention. Design-doc-first, like
> `classifier/CLASSIFIER-INDEPENDENCE.md`.

## 1. What it records (three overlapping layers)

The layers are deliberately **allowed to overlap** — they are different lenses on
the same time, never deduplicated. Watching a YouTube video in Chrome produces a
record in all three at once, and that is correct.

| Category | Key (pie slice) | What it measures | Source |
|---|---|---|---|
| `appUsage` | app bundle id / exe | seconds an app is **foreground + focused**, minus idle | native (`NSWorkspace` on macOS, `GetForegroundWindow` on Windows) |
| `webVisit` | domain | seconds the **active, focused tab** is on a site, minus idle | extension (content script) |
| `contentWatched` | `platform:contentID` | each piece of content actually watched + its duration + title/creator | extension, on platforms a custom platform rule supports (YouTube/Reddit/Bilibili/…) |

- **App / site time = foreground + focused only.** Background apps and unfocused
  or background tabs do not accrue.
- **`contentWatched` is item-level** (title, creator, duration) and only on
  supported platforms; generic web stays **domain-level** (no arbitrary URLs, no
  window titles).
- **Not captured, ever:** keystrokes, screenshots, message/content bodies,
  browser window titles, full URLs off supported platforms.

## 2. Idle — dropped for now (owner decision 2026-09-19)

Inactivity detection is **not implemented for now**: time accrues while an app is
foreground + focused **whether or not the user is present** (leaving the desk
keeps counting). Accrual still stops naturally during system sleep — the sample
timer does not fire and the monotonic clock does not advance — and the per-step
cap bounds any gap. Durations are measured on a **monotonic clock** (never
wall-clock deltas, which jump on sleep / NTP / DST) and attributed to the local
day of their start.

The seams to re-enable idle later are kept: the accumulator takes an `active`
flag (currently always true), and `ActivitySettings.idleThresholdSeconds` is
stored but unused. When it returns, accrual would pause on no-input-for-N and on
screen lock.

## 3. Privacy contract (enforced in code, not just here)

- **Per-category opt-in; default OFF.** A first-run explainer offers to turn each
  on. Existing screen-time enforcement and classifier collection are separate
  pre-existing pipelines with their own settings; an Activity toggle governs the
  **Activity log only** (UI copy: "record to your Activity log").
- **Disabled ⇒ never captured.** Enforced at the capture site *and* backstopped in
  `ActivityStore.record` (a disabled category writes nothing). A toggle takes
  effect immediately, mid-session.
- **Local-only, no egress.** No network sink exists. Cross-device merge would need
  outward sync, which is precluded; timelines are per-machine (the native app plus
  the browsers on that machine, merged over the loopback HMAC hub).
- **Retention you control.** Per-category window (`retentionDays`, default 30; `0`
  = keep forever). A reaper prunes on a schedule. Plus delete-all, delete-a-range,
  delete-one now — a real delete of raw records, not a tombstone.
- Any future export or send is gated behind an explicit consent dialog; none is
  built.
- `PRIVACY.md` gains an Activity-log section (translated at release, per policy).

## 4. Storage

The **native app is the store of record** (always-on; the browser worker sleeps).
Layout under the env-scoped support dir, dir `0700`, files `0600`:

```
Activity/
  settings.json
  app-usage/<yyyy-MM-dd>.json        # [ActivityRecord] for that local day
  web-visit/<yyyy-MM-dd>.json
  content-watched/<yyyy-MM-dd>.json
```

- **One file per (category, day)** so per-category retention and delete are whole-
  file operations, and a day's raw records aggregate cheaply for the pie chart.
- Records carry a feeder-assigned **`id`** so a replay after reconnect is
  **idempotent** (dedupe within the target day file).
- Writes are coalesced onto a background queue (the `LocalStateFile` discipline);
  atomic writes; a partial day file is recoverable (last good array wins).

## 5. Cross-surface flow

- Native feeders (`appUsage`) write straight to the store.
- The extension measures `webVisit` / `contentWatched` in the **content script**
  (survives the MV3 worker sleeping), buffers to `chrome.storage`, and flushes to
  the native app over a new hub op **`activity-record`** (one enum case in
  `SharedBrowserBridgeOperation` → allowlists derive automatically). Flush is
  idempotent and the buffer is bounded (cap + drop-oldest).
- Same definitions (idle threshold, day boundary, "watched") hold identically
  across macOS, Windows, and the extension.

## 6. Phases

1. **Shared core (this doc + `Activity.swift`/`ActivityStore.swift` in
   `MacBlockerCore`)** — model, settings, per-(category,day) store, aggregate,
   reaper, delete; injectable clock; hermetic tests for the privacy invariant,
   idempotent replay, aggregation, reaper, and deletes. ← building now
2. **macOS feeder** — foreground+focused app intervals with idle/lock/sleep
   pausing → `appUsage`.
3. **Hub op + extension feeders** — `activity-record`; content-script `webVisit`
   dwell + `contentWatched`; buffer/flush; popup per-category toggles.
4. **Dashboard** — an Activity page beside Vault | Classifier: pie charts (time by
   app / by site), the watched-content list, and the toggle + retention + delete
   controls. Shared web assets render in both the Mac and Windows WebViews.
5. **Windows feeder** — the `appUsage` equivalent in Windows Vault; verify on the
   mini1 Windows VM.
6. **Downstream (later)** — screen-time limits and reports off the aggregates, and
   the opt-in classifier feed from watched history.

## 7. What v1 excludes
Window titles, full URLs off supported platforms, Vault's own events
(blocks/snoozes/corrections), cross-device sync, and the optional
Screen-Time/browser-history import. Each is an additive follow-on.
