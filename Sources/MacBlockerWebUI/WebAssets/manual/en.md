# Vault desktop-app functional reference

## Purpose and boundary

This is the authoritative reference for the Vault desktop application interface. It is intentionally separate from the Vault browser-extension manual.

The desktop app manages **native applications and application windows**. The browser extension manages websites, browser tabs, and supported web-platform feeds. They share the same ideas—groups, schedules, timers, freezes, snoozes, Custom rules, and the optional bridge—but they do not have the same enforcement surface.

Use this document to configure, audit, reproduce, or maintain the desktop-app behaviour. The code is canonical if an implementation and this manual differ.

## 1. What the desktop app can and cannot control

Vault evaluates focus policy for selected native applications. When its native enforcement capability is available, it can apply the current plan to matching application targets and report a shield/status result to the host UI.

It can:

- create, enable, disable, reorder, import, export, freeze, snooze, and remove groups;
- target native applications selected through the application picker;
- apply an immediate block, a timed allowance, or a count-up-only timer;
- restrict normal groups to weekdays and local time windows;
- run Custom JavaScript policy rules for application lifecycle events;
- show rule-created native status/panel information through the host;
- manage an optional local folder for supported Custom-rule file requests;
- join compatible explicitly linked groups through the local Vault bridge.

It cannot:

- act as a browser extension, inspect a website DOM, or manipulate browser feed cards;
- guarantee that an operating system will allow every application, process, window, or system service to be controlled;
- turn application selection into remote administration, device surveillance, or a firewall;
- make browser-only Custom helpers such as DOM, navigation, redirection, or tab control work in the native runtime;
- synchronize every group automatically merely because the local bridge is running.

## 2. Vocabulary

| Term | Meaning |
| --- | --- |
| Group | A named focus-policy object. Group names must be unique within the current Vault endpoint. |
| Target | A native application identity selected for a group. |
| Default application group | A normal group whose targets are native applications from the app picker. |
| Custom group | A group whose JavaScript rule reacts to application-policy events. |
| Match | The current foreground/running application matches an enabled and active group target or Custom-rule condition. |
| Active | Enabled, within the normal schedule, and not actively snoozed. |
| Enforcement plan | The native host's resulting allow/shield/status decision after it evaluates applicable groups. |
| Freeze | Protection against ordinary modification of a group. |
| Snooze | A temporary exception from a normal group policy. |

## 3. Target identity and application picker

Select applications through the **+** picker in a Default application group. Vault stores a normalized identity as well as a display name.

| Host | Target identity used for matching |
| --- | --- |
| macOS | Application bundle identifier where available. |
| Windows | Normalized executable path or process name supplied by the application picker. |

The display name is for the editor. The normalized value is the identity used by the native enforcement layer. Renaming an application in the UI does not change the identity. A target can also carry tags for Custom-rule policy use.

Do not enter a website URL in an application-target field and expect native application enforcement. Use the extension's Site group for website blocking.

## 4. Group lifecycle and precedence

A new group is enabled by default. The group list supports selection, enable/disable, drag ordering, Add, Clear, import, export, and deletion. The selected group opens in the editor.

Normal field edits save through the editor's autosave policy. A frozen group disables ordinary editing controls. A Custom source is different: saving text does not make it active; **Run** is the operation that loads the current source into the policy runtime.

Several groups can match the same application. Vault evaluates group policy in stored order and builds a native enforcement plan. Keep overlaps intentional, especially when groups use different timed policies or Custom rules issue allow/shield decisions. Reorder the groups to make the intended precedence clear; do not rely on a conflicting configuration being resolved in a particular user-friendly way.

## 5. Normal application groups

### 5.1 Group state

| Field | Functional contract |
| --- | --- |
| Name | Non-empty, trimmed, unique case-insensitively within this endpoint. |
| Enabled | Disabled groups are retained but do not take part in normal enforcement. |
| Targets | One or more application identities selected from the picker. |
| Behaviour | Immediate block, block after an allowance, or timer/count-up. |
| Schedule | Selected weekdays and optional local time windows. |
| Freeze | None, Frozen, Strict frozen, or Parental frozen. |
| Snooze | Per-group temporary-exception policy. |
| Fallback/status message | Message the native host can show when it applies a shield/status response. |

An empty Default group has no selected application target and therefore does not match an application merely by existing.

### 5.2 Blocking behaviours

| Behaviour | Result |
| --- | --- |
| Block immediately | A matching active target produces an immediate native block/shield decision. |
| Block after a number of minutes | Matching use accrues against the group allowance. When the allowance is exhausted, the group produces a native block/shield decision until its usage period resets or another state makes the group inactive. |
| Timer (count up, no block) | Matching use is measured and may be displayed, but that timer alone never produces a block. |

New groups use a 15-minute allowance and a 24-hour reset interval unless changed. Timed usage belongs to the group, so all matching targets share that group policy. The exact response to a block is implemented by the native host and is constrained by the operating-system permissions and supported enforcement mechanism.

### 5.3 Schedules

Schedules apply to normal groups. A Custom group makes its own time decisions in JavaScript.

Select any combination of Monday through Sunday. Each time window is one line in local time:

```text
0900-1200
1330-1730
```

The exact accepted format is HHMM-HHMM. Hours must be 00 through 23, minutes 00 through 59, and the start must be earlier than the end on the same day. A window includes its start and excludes its end. Cross-midnight windows are not accepted. Empty windows mean the entire selected day.

The normal group is active only when:

1. it is enabled;
2. the current weekday is selected;
3. the local time is inside a configured window, or the group has no windows;
4. it is not in an active snooze.

### 5.4 Snooze

Snooze temporarily removes a normal group from active enforcement. Its phases are:

| Phase | Result |
| --- | --- |
| Pending | The request exists but the activation delay has not elapsed; the group remains active. |
| Active | The group is temporarily inactive for its snooze duration. |
| Cooldown | The snooze has ended and the group is active again, but a new snooze is not yet available. |

| Setting | Rule |
| --- | --- |
| Allow snooze | When off, the group cannot be normally snoozed. |
| Snooze duration | Positive number of minutes. The default for a new group is 30 minutes. |
| Activation delay | Zero or more minutes before the snooze becomes active. |
| Cooldown | Zero through five minutes after the active snooze ends. |
| Confirmations | Non-negative whole number of required confirmation interactions. |

An active snooze is a temporary policy exception, not deletion or unfreezing. The group configuration stays intact.

### 5.5 Freeze

Freeze is a deliberate modification barrier.

| Mode | Contract |
| --- | --- |
| Frozen | Ordinary edits and ordinary state changes remain locked until the product's unfreeze confirmation flow succeeds. |
| Strict frozen | The group cannot be unfrozen before its strict-freeze duration ends. The duration is positive and limited to 72 hours. |
| Parental frozen | Guardian-password management is required for freeze/unfreeze actions. |

Choosing a mode in the editor does not freeze the group by itself; use the freeze action to apply it. A bridge-linked group may also lock coordinated freeze controls while a required member is offline.

## 6. Native enforcement and device control

The editor can accurately save a group even when the operating system has not granted the ability to enforce it. Always check **Settings → Device Control** and the live native status after changing permissions.

The native host decides which actions are possible for the current operating system, application, window, and permission state. A rule can be correctly configured yet have no visible effect when:

- Device Control is not granted or has been revoked;
- the group is disabled, scheduled out, or actively snoozed;
- the focused process does not match a selected normalized target;
- the operating system rejects an action for that target;
- a bridge dependency is offline for an action that requires coordinated state.

Do not treat a successful save toast as proof that active enforcement is available. Test the selected target while the group is active and inspect the host status.

## 7. Custom groups and native policy rules

Custom groups run in the native JavaScript policy runtime. They are not browser Custom rules. Browser DOM, tab, navigation, URL redirection, and feed-control behaviour are intentionally unavailable.

### 7.1 Source lifecycle

Use a function expression:

```js
(events, helpers) => {
  events.on("focusEvent", "shield-focus", (event, h) => {
    if (event.target?.id) event.setResult(-1);
  });
}
```

Run loads the source and its event registrations. Running again unloads the old source and resets its rule-owned handlers, timers, panels, persistence, and dynamic app blocklist. A source that does not evaluate to a function cannot be loaded.

### 7.2 Native built-in events

| Event | Meaning |
| --- | --- |
| tickEvent | Periodic host tick. An intervalMs registration option can rate-limit a handler. |
| timerEnded | A rule-owned countdown reaches zero. |
| snoozePress | The user presses Start Snooze for a Custom group. |
| panelEvent | A Custom panel control is used. |
| localFileEvent | A requested local-folder action completes. |
| openAppEvent | A tracked application opens. |
| closeAppEvent | A tracked application closes. |
| focusEvent | The foreground application changes to an application. |
| unfocusEvent | The foreground application changes away from an application. |
| minimizeEvent / unminimizeEvent | The host reports a supported window-minimize transition. |
| switchAppEvent | The foreground application changes from one app to another. |
| appChangedEvent | General application lifecycle/change event. |

The event object contains type, groupId/groupID, groupName, URL/hostname equivalents, time, data, and target. For a native application, target exposes an id, kind, displayName, normalized value, and tags when the focus target matches a configured target.

Application lifecycle event data includes the current app id/name, group name, a serialized running-app snapshot, and event-specific values such as bundleId, previousAppId, currentAppId, or change reason.

### 7.3 Event API and decisions

The registry provides on/register, off/unregister, unregisterAll, countRegistered, getEvent, and getEvents. Higher priority runs first; equal priority preserves registration order. The registry has a per-group handler cap.

The event object supports:

| Method | Result |
| --- | --- |
| setResult(-1) | Produce a native shield/block decision. A string result also becomes a native block because desktop rules have no browser redirect target. |
| allow(reason) or setResult(1) | Produce an allow decision for the event. |
| setShieldMessage(message) | Set the human-facing shield/status message for a native block. |
| stopPropagation() | Stop later handlers for the current event. |
| block(appId), unblock(appId) | Add/remove a dynamic native application block. |
| close(appId), open(appId) | Request a supported native close/open action. |
| post(type, data) | Dispatch a nested Custom event within the native runtime. |

The app runtime allows timers, persistence, panels, logs, local-folder operations, application-window helpers, and URL-classifier utilities. It deliberately treats DOM, navigation, redirection, and browser-tab helpers as unavailable/inert.

### 7.4 Native helpers

| Helper | Native behaviour |
| --- | --- |
| getLogHelper | Emits app/popup/screen log decisions. |
| getTimerHelper | Creates forward/backward timers with bounds, steps, scope/domain predicates, pause/resume, state inspection, and timerEnded transitions. Timers do not shield by themselves. |
| getPersistenceHelper | Per-group JSON state: get, set, delete, has, keys, entries, clear, size. |
| getStorageHelper | Persistence plus host async-request placeholders; do not assume a synchronous external response. |
| getWindowHelper | Reads current/running applications and requests close/open/block/unblock application actions. |
| getPanelHelper | Creates validated native panel snapshots, controls, inline handlers, and panelEvent reactions. |
| getLocalFolderHelper | Queues allowed relative .txt, .csv, and .json operations under the user-granted root. Completion is localFileEvent. |
| getDomainHelper / getDomainUtility | URL and platform classifiers for rules that also reason about URL-like values. |
| getPlatformHelper / platform | URL classifiers remain available; native feed/DOM control calls are inert because the desktop host has no website DOM. |

Custom panels use the same declarative control vocabulary as the browser runtime: text, checkbox, select, textInput, textarea, button, section, timer, numberInput, range, toggle, radio, date, time, color, pin, and sanitized html. The native host decides how much of a panel can be displayed on the current platform.

## 8. Local File Folder

The Local File Folder is an optional, user-granted boundary for Custom rules. Rules can request text/CSV/JSON reads, writes, appends, lists, existence tests, and JSON operations. Paths are always relative to the selected root. Absolute paths, traversal segments, hidden path components, unsupported extensions, and operations outside the root are rejected.

Revoke the folder when a rule no longer needs it. A rule must handle unavailable permission and failed localFileEvent results; it must not assume a selected folder remains authorized after a restart.

## 9. Web-app bridge

The bridge is optional local synchronization between compatible Vault programs. A native desktop app can host the local hub; clients connect on the supported local address.

Connection states are Off, Connecting, Disconnected, Connected/Running, and Error. Connecting a program does not merge all groups. The user must explicitly link eligible matching groups.

For a group link:

1. Start the native hub in Settings.
2. Connect the other compatible Vault endpoint.
3. Create matching, unfrozen groups with the same name and type.
4. In the group bridge section, choose the program and connect the group.

A linked group forms a cluster. Supported common policy values, usage, and snooze state can synchronize while members are connected. Disconnecting pauses synchronization and preserves local groups. Browser-only targets, unsupported Custom actions, and platform-specific fields are not guaranteed to transfer.

## 10. Import, export, reset, and audit

Export saves one compatible group representation. Import validates/normalizes compatible group data and still enforces local name uniqueness. Delete Group removes the selected group and its associated state. Clear removes all groups after confirmation. Reset to defaults affects global editor settings; export anything that must be retained first.

Before relying on a desktop rule:

1. Verify Device Control is granted.
2. Verify the selected target's normalized identity.
3. Verify enabled state, schedule, freeze state, and snooze phase.
4. Test immediate, timed, and count-up behaviour separately.
5. For a Custom group, Run the exact source and test each registered app event.
6. Verify local-folder failures as well as successful operations.
7. Verify bridge offline/connected behaviour if the group is linked.

## 11. Platform-specific notes

The core policy concepts are shared, but native enforcement is host-specific:

| macOS | Windows |
| --- | --- |
| Targets normally resolve to application bundle identifiers. Device Control and the current macOS permission state gate enforcement. | Targets normally resolve to a normalized executable path or process name. The Windows enforcement layer decides which current windows/processes can be managed. |

This desktop reference deliberately does not describe website blocklists, feed selectors, YouTube creator classification, browser redirects, or browser-tab actions. Those belong to the Vault extension manual.
