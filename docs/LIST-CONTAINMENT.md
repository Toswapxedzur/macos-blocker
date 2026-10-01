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
its mouse-input policy needs an owner decision before adding interactive
scrolling.

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
