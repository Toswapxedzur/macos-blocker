# Growing list containment

Owner decision (2026-10-01): every collection that can accumulate entries,
including slowly growing collections, must have a bounded visible box. This
pass covers Mac Vault and the shared browser editor; Windows and the website
replica are outside the confirmed scope.

The shared `vui-list-box` fits short collections naturally and scrolls long
ones inside a borderless, rounded viewport. It caps visible height, not item
count. Headings and creation/search controls live outside collection viewports.
Boxes are keyboard focusable; existing collapsible sections retain their
collapse behavior. Classifier list positions survive incoming snapshots.

## Audited surfaces

| Surface | Growing collection | Containment |
| --- | --- | --- |
| Vault editor | Group navigation | Remaining navigation-panel height; Add stays outside |
| Vault editor | Applies-to entries, websites, blocked apps | Shared chip box, at most 28vh / 240px |
| Vault editor | Creator/account filters, Discord targets | Shared chip box, at most 28vh / 240px |
| Vault editor | Available Classifier tags | Searchable floating chooser; menu at most 320px, internal list at most 250px |
| Vault editor | Installed-app search results | Existing bounded picker; explicit shrinkable results area |
| Vault editor | Custom-rule output | Existing 220px internal scroll area |
| Shared controls | Group/link choices and other dropdown choices | Existing bounded `vui-menu` |
| Classifier | Types navigation | Bounded box, at most 32vh / 300px |
| Classifier Knowledge | Terms and creators for each platform | Separate boxes, at most 52vh / 480px; headings/counts outside |
| Classifier Settings research | Fetched provider models | Searchable floating picker; list at most 32vh / 280px; menu fits viewport; Fetch/Refresh/Retry outside |
| Classifier Settings API keys | Provider profiles | Shared box, at most 52vh / 480px; creation controls outside |
| Classifier tag tree | Growing tag graph | Existing 520px canvas with internal pan/scroll |
| Activity | User groups | Existing 206px area, cards scroll horizontally |
| Activity group editor | Selected members | Dedicated internal scroll box; heading outside |
| Activity group editor | Member search results | Existing internal scroll box |
| Activity Usage/Content | Apps, sites, tags/colours | Existing 300px panels with internal scroll lists |
| Activity Content | Authors and watched entries | Existing 360px panels with internal scroll lists |
| Activity charts | Growing day ranges | Existing horizontal chart scrolling; no vertical list expansion |
| Native custom rules | Multiple floating panels at each position | Scroll document capped at 65% of visible screen height / 640px |
| Native custom rules | Select options | Separate white popover; internal scrolling at most 280px; parent panel size unchanged |
| Editor dialogs | Snapshot controls | Bounded dialog body |

Fixed menus (days, recording switches, platforms, model tiers, strictness and
languages) and capped creator suggestions (six, in an anchored floating menu) cannot
accumulate arbitrary entries. Manual text and input fields are not growing
collections. The floating timer HUD is a separate noninteractive surface;
it remains fully click-through (owner confirmed 2026-10-02).

## Verification

Mini1 checks use production renderers with synthetic data: 763 creators,
100 terms, 80 API keys, 100 block groups, 400 sites/creator
filters/tags, 300 blocked apps, 200 Activity groups/authors/watched entries,
and 120 selected Activity members. Wide and narrow viewport checks cover
scrolling to the last entry, short-list sizing, search, snapshot scroll/focus
preservation and existing autosave behavior. Native tests verify short/long
scroll documents and the production SwiftUI panel stack.

- Browser: `tests/popup-bounded-lists.js` through the existing extension driver.
- Classifier: `classifier/Tests/WebUI/bounded-lists.js` through `autosave.mjs`.
- Activity: `Tests/WebUI/activity-lists.js` through the same fixture runner.
- Native overlays: `Tests/MacBlockerMacControlTests/BoundedOverlayTests.swift`.

## List search (owner 2026-10-02)

Lists and option menus with six or more entries show a compact local search.
One to five entries need no extra search; an active query stays visible when
a collection shrinks. Knowledge has a separate search directly above Terms
and each platform’s Content sources list, matching names, identifiers and
descriptions. Model/app/tag/member pickers retain their established searches.
Fixed model tiers, strictness, platforms, weekdays
and short mode choices stay simple; Classifier group navigation is capped at
four groups.

Search covers Vault group navigation, targets/sites/apps/creator/Discord lists
and group logs; Classifier provider profiles and shared selectors; Activity
groups, selected members, usage items, tags, pie legends, sources and viewed
content; languages and long shared/custom-rule dropdowns in browser and Mac.
Tag-tree Find highlights and pans to matching names/descriptions, preserving
all branches. Tag-rule Find locates lines in the backing text without rewriting
their syntax. Clear and no-match states are explicit.

Matching ignores case and allows partial text. Filters change only display,
never stored data, selections, order, recording, totals or chart filters.
Queries are transient per-list state and survive snapshots with focus/caret;
open dropdowns rebind to replacement controls before a choice is made. Clear
group search before reordering the full navigation list.

Mini1 regressions: browser `tests/popup-search.js` and
`tests/browser-panel-search.py`; Mac `classifier/Tests/WebUI/list-search.js`
and `Tests/WebUI/activity-search.js`, through the existing fixture runner at
wide/narrow widths. Native selects remain in their bounded floating popover.


## Growing-list performance (2026-10-02)

Containment now bounds mounted work as well as visible size. Variable-height
editor cards/chips and Activity rows use pages of 40; Knowledge and provider
profiles use 12; app/member pickers use 60. Searches cover the full backing
collection, yield between chunks, and retain query/page/draft/focus state.
Deletion clamps and refetches the last native page; query failures offer Retry.
No stored entries are truncated. Controls and headings stay outside list boxes.

Long shared selects retain the complete model but mount only the chosen native
option and 40 menu results. Knowledge pages/search execute off MainActor, and
UI snapshots omit complete Knowledge collections and provider request records;
MCP retains its complete data contract. Activity range/history aggregation runs
off MainActor, while native icon resolution yields in bounded chunks.

Large tag graphs mount viewport nodes/edges. Dense day timelines and strips
use canvas with indexed viewport queries and original per-record hover data.
Native panel stacks use ScrollView/LazyVStack; browser panels defer offscreen
paint and construct in chunks. Timers avoid rebuilding unchanged rows; native
large timer formatting runs off MainActor. Both timer surfaces stay click-through.

Feed parsing/filtering scans changed card roots, handles all matching cards,
and yields after 32 cards. Full scans remain necessary on navigation or policy
changes. Taxonomy transport pages through all tags; the 16-tag limit applies
only to tags attached to one content item.

These changes bound DOM and synchronous rendering work; initial data transfer,
filtering, sorting and aggregate calculations still grow with stored data.
They do not promise constant total time or zero memory growth.

Mini1 regressions: `classifier/Tests/WebUI/list-performance.js`,
`Tests/WebUI/activity-performance.js`, existing containment/search/autosave
fixtures, native suites, and the sibling Chromium performance/feed suites.
Synthetic 10,000-entry fixtures check final-entry access, bounded DOM,
draft/caret/page preservation and exact chart hover identities.
