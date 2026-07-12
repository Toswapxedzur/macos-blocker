import Foundation
import MacBlockerCore
import MacBlockerWebUI
#if os(macOS)
import AppKit
import MacBlockerMacControl
#endif

/// Connects the web editor's saved groups to live macOS enforcement and the
/// floating timer HUD.
///
/// Scope boundary — the native app enforces **whole apps only** and never
/// touches in-browser affairs at any level: it does not read browser tabs
/// (no `__nativeGetAllTabs` provider is installed, so `getAllTabs()` returns
/// `[]`), and it ignores every web-level intent (`closeTab`,
/// `closeTabsByPattern`, `blockSite`, `unblockSite`). Site/tab/DOM enforcement
/// belongs entirely to the customBlocker browser extension, matching the
/// Windows port. `isBrowser` is always reported `false`.
///
/// Lifecycle events (notification-driven, real-time):
///   - `openAppEvent`      — process launched (strong)
///   - `closeAppEvent`     — process terminated (strong)
///   - `focusEvent`        — app became frontmost
///   - `unfocusEvent`      — app lost frontmost
///   - `minimizeEvent`     — app hidden (Cmd+H)
///   - `unminimizeEvent`   — app unhidden
///
/// Context events:
///   - `switchAppEvent`    — frontmost changed non-null → non-null
///   - `appChangedEvent`   — superset of all above + URL changes
///   - `tickEvent`         — every ~1s
///
/// User-triggered:
///   - `snoozePress` / `panelEvent` / `localFileEvent`
@MainActor
public final class MacEnforcementBridge: ObservableObject {
    /// Shared store the editor persists into and we read groups back out of.
    public let webStore: BlockerWebStore

    /// Rolling log of event + rule output (capped). Published so the web UI
    /// can display it.
    @Published public var ruleLog: [RuleLogEntry] = []

    #if os(macOS)
    private let adapter: EndpointSecurityPolicyAdapter
    private let evaluator = PolicyEvaluator()
    private let overlay = TimerOverlayPanelController()
    private let toastOverlay = ToastOverlayPanelController()
    private let panelOverlay = PanelOverlayPanelController()
    private var timer: Timer?
    private let tickInterval: TimeInterval
    private var lastSampleAt: Date?
    /// Group ids whose current local usage total has already been seeded to the
    /// web-app bridge cluster. The first report after a group joins a cluster
    /// carries a delta-free seed (its existing local total) so prior Mac usage
    /// isn't lost when it links; subsequent reports carry only fresh increments.
    /// Cleared when a group leaves its cluster so a re-link re-seeds.
    private var clusterSeededGroups: Set<String> = []

    // Custom-rule runtime state
    private var ruleRuntime: CustomJavaScriptPolicyRuntime?
    private var loadedRuleSources: [String: String] = [:]
    private var lastFrontmost: String?

    // Notification-driven lifecycle event queue. NSWorkspace notifications
    // push events here; the tick loop drains them.
    private struct AppLifecycleEvent {
        enum Kind: String { case launched, terminated, activated, deactivated, hidden, unhidden }
        let kind: Kind
        let bundleID: String
    }
    private var pendingLifecycleEvents: [AppLifecycleEvent] = []
    private var workspaceObservers: [Any] = []

    // Persistent (rule-driven) app blocklist — whole-app enforcement only.
    // The native app deliberately does NOT read or control browser tabs/sites:
    // site/tab/DOM enforcement belongs entirely to the customBlocker browser
    // extension. There is no browser tab reader, focus observer, or dynamic
    // site blocklist here on purpose (see the boundary note above the class).
    private var blockedAppBundleIDs: Set<String> = []

    // Panel event throttle (leading-edge, trailing flush at tick)
    private static let panelThrottleInterval: TimeInterval = 0.10
    private var lastPanelFireAt: [String: Date] = [:]
    private var pendingPanelEvents: [String: (groupID: String, data: [String: String])] = [:]

    // System overlay panel events (e.g. parental PIN entry) buffered for the
    // web editor to poll via drainSystemPanelEventsJSON().
    private var systemPanelEvents: [[String: String]] = []
    #endif

    public init(webStore: BlockerWebStore = BlockerWebStore(), sweepInterval: TimeInterval = 1.0) {
        self.webStore = webStore
        #if os(macOS)
        self.adapter = EndpointSecurityPolicyAdapter(runTerminationSweep: true)
        self.tickInterval = sweepInterval
        #endif
    }

    /// Re-evaluates immediately (e.g. right after an editor save).
    public func refresh() {
        #if os(macOS)
        tick()
        #endif
    }

    /// Returns new log entries as a JSON array string and clears the buffer.
    /// Called by the web view's push timer to forward logs to the popup's Log
    /// panel.
    public func drainLogJSON() -> String? {
        guard !ruleLog.isEmpty else { return nil }
        let entries = ruleLog
        ruleLog.removeAll()
        let dicts: [[String: String]] = entries.map {
            ["timestamp": ISO8601DateFormatter().string(from: $0.timestamp),
             "level": $0.level, "group": $0.group, "message": $0.message]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dicts),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    // MARK: - Public event triggers

    /// Fire a `snoozePress` event for the given group. Called when the user
    /// taps snooze in the shield/UI.
    public func fireSnoozePress(groupID: String) {
        #if os(macOS)
        let groups = webStore.importedGroups()?.groups ?? []
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let event = makeEvent(type: "snoozePress", group: group, frontmost: frontmost,
                              data: ["triggeredAt": String(Int(Date().timeIntervalSince1970 * 1000))])
        dispatchSingleEvent(event, group: group, frontmost: frontmost)
        #endif
    }

    /// Fire a `panelEvent` for the given group. Called when the web UI panel
    /// sends an interaction (button click, input change, etc).
    public func firePanelEvent(groupID: String, data: [String: String]) {
        #if os(macOS)
        let groups = webStore.importedGroups()?.groups ?? []
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let event = makeEvent(type: "panelEvent", group: group, frontmost: frontmost, data: data)
        dispatchSingleEvent(event, group: group, frontmost: frontmost)
        #endif
    }

    /// Show a system overlay panel (e.g. parental PIN entry) requested by the
    /// web editor. `json` is a serialized `PanelSnapshot`.
    public func showSystemPanel(json: String) {
        #if os(macOS)
        guard let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(PanelSnapshot.self, from: data) else { return }
        panelOverlay.showSystemPanel(snapshot)
        #endif
    }

    /// Dismiss a system overlay panel by id (empty id dismisses all).
    public func dismissSystemPanel(id: String) {
        #if os(macOS)
        panelOverlay.dismissSystemPanel(id: id)
        #endif
    }

    /// Drains buffered system-panel interaction events as a JSON array string
    /// (or nil when empty). Polled by the web editor each second.
    public func drainSystemPanelEventsJSON() -> String? {
        #if os(macOS)
        guard !systemPanelEvents.isEmpty else { return nil }
        let events = systemPanelEvents
        systemPanelEvents.removeAll()
        guard let data = try? JSONSerialization.data(withJSONObject: events),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
        #else
        return nil
        #endif
    }

    /// Fire a `localFileEvent` for the given group. Called after a file
    /// operation initiated by a custom rule completes.
    public func fireLocalFileEvent(groupID: String, data: [String: String]) {
        #if os(macOS)
        let groups = webStore.importedGroups()?.groups ?? []
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let event = makeEvent(type: "localFileEvent", group: group, frontmost: frontmost, data: data)
        dispatchSingleEvent(event, group: group, frontmost: frontmost)
        #endif
    }

    /// Begins enforcement: an initial evaluation plus a repeating tick that
    /// accrues usage, re-evaluates, enforces, and refreshes the timer HUD.
    public func start() {
        #if os(macOS)
        guard timer == nil else { return }
        print("[MacEnforcementBridge] start() called")
        print("[MacEnforcementBridge] AppGroup.containerURL = \(AppGroup.containerURL()?.path ?? "nil")")
        print("[MacEnforcementBridge] AppGroup.baseDirectory = \(AppGroup.baseDirectory().path)")
        webStore.seedIfNeeded()
        lastSampleAt = Date()
        lastFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        registerWorkspaceObservers()
        panelOverlay.setEventHandler { [weak self] groupID, panelId, controlId, eventName, value, extra in
            guard let self else { return }
            var data: [String: String] = [
                "panelId": panelId,
                "controlId": controlId,
                "eventName": eventName,
                "value": value
            ]
            if !extra.isEmpty { data["valuesJSON"] = extra }
            // System panels are driven by the web editor (parental PIN entry),
            // not a custom rule: buffer their events for the editor to poll.
            if groupID == PanelOverlayPanelController.systemGroupID {
                self.systemPanelEvents.append(data)
                return
            }
            if eventName == "click" {
                self.firePanelEvent(groupID: groupID, data: data)
                return
            }
            let key = "\(groupID)|\(panelId)|\(controlId)"
            let now = Date()
            if let last = self.lastPanelFireAt[key],
               now.timeIntervalSince(last) < Self.panelThrottleInterval {
                self.pendingPanelEvents[key] = (groupID: groupID, data: data)
                return
            }
            self.lastPanelFireAt[key] = now
            self.pendingPanelEvents.removeValue(forKey: key)
            self.firePanelEvent(groupID: groupID, data: data)
        }
        tick()
        let timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        self.timer = timer
        #endif
    }

    public func stop() {
        #if os(macOS)
        timer?.invalidate()
        timer = nil
        lastSampleAt = nil
        overlay.hide()
        toastOverlay.teardown()
        panelOverlay.teardown()
        unregisterWorkspaceObservers()
        #endif
    }

    #if os(macOS)
    // MARK: - Workspace Notification Observers

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let mapping: [(NSNotification.Name, AppLifecycleEvent.Kind)] = [
            (.init("NSWorkspaceDidLaunchApplicationNotification"), .launched),
            (.init("NSWorkspaceDidTerminateApplicationNotification"), .terminated),
            (.init("NSWorkspaceDidActivateApplicationNotification"), .activated),
            (.init("NSWorkspaceDidDeactivateApplicationNotification"), .deactivated),
            (.init("NSWorkspaceDidHideApplicationNotification"), .hidden),
            (.init("NSWorkspaceDidUnhideApplicationNotification"), .unhidden),
        ]
        for (name, kind) in mapping {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier,
                      !MacProcessTerminator.isBrowserBundleIdentifier(bundleID) else { return }
                // Only track GUI apps (regular activation policy).
                if kind == .launched || kind == .terminated {
                    guard app.activationPolicy == .regular else { return }
                }
                Task { @MainActor in
                    self?.pendingLifecycleEvents.append(AppLifecycleEvent(kind: kind, bundleID: bundleID))
                }
            }
            workspaceObservers.append(observer)
        }
    }

    private func unregisterWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        pendingLifecycleEvents.removeAll()
    }

    // MARK: - Tick

    private func tick() {
        // Flush any throttled panel events (trailing edge).
        for (_, pending) in pendingPanelEvents {
            firePanelEvent(groupID: pending.groupID, data: pending.data)
        }
        pendingPanelEvents.removeAll()
        lastPanelFireAt.removeAll()

        let now = Date()
        let importResult = webStore.importedGroups()
        let groups = importResult?.groups ?? []
        let observedFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let frontmost = MacProcessTerminator.isBrowserBundleIdentifier(observedFrontmost) ? nil : observedFrontmost

        // 1. Reconcile reset windows + accrue time spent in the frontmost app.
        let elapsed = elapsedSinceLastSample(now: now)
        lastSampleAt = now
        let timersMs = reconcileUsage(groups: groups, frontmost: frontmost, elapsed: elapsed, now: now)
        let usage = UsageSnapshot(
            usageByGroupSeconds: timersMs.mapValues { $0 / 1000 },
            snoozesByGroup: webStore.loadSnoozes()
        )

        // Enforce persistent app blocklist: kill any blocked app that's running.
        if !blockedAppBundleIDs.isEmpty, let fm = frontmost, blockedAppBundleIDs.contains(fm) {
            MacProcessTerminator.terminate(bundleIdentifier: fm)
            appendLog(level: "log", group: "system",
                      message: "Killed blocked app: \(fm)")
        }

        // 2. Drain notification-driven lifecycle events.
        let lifecycleEvents = pendingLifecycleEvents
        pendingLifecycleEvents.removeAll()

        let switched = frontmost != lastFrontmost

        // 3. Build and dispatch events for ALL enabled groups, log each event.
        let dispatchOutput = dispatchEvents(
            groups: groups, frontmost: frontmost, usage: usage, now: now,
            lifecycleEvents: lifecycleEvents, switched: switched
        )

        // 4. Enforce: block apps whose group says "blocked now" PLUS
        //    any apps shield-ed by custom-rule decisions.
        Task { [adapter, ruleBlocked = dispatchOutput.shieldedBundleIDs] in
            try? await adapter.applyGroups(
                groups, usage: usage, now: now,
                customBlockedBundleIDs: ruleBlocked
            )
        }

        // 5. Render the HUD for any timer whose app is currently frontmost.
        let activeTargetIDs = matchingTargetIDs(groups: groups, frontmost: frontmost)
        let context = ActivityContext(
            now: now,
            target: nil,
            activeTargetIDs: activeTargetIDs,
            platform: .macOS
        )
        let result = evaluator.evaluate(groups: groups, usage: usage, context: context)
        var rows = result.visibleTimerItems.map {
            TimerOverlayRow(id: $0.groupID, name: $0.name, remainingSeconds: $0.remainingSeconds)
        }
        for timer in dispatchOutput.customTimers where !timer.isPaused {
            let remainingSec = max(0, timer.currentMs / 1000)
            rows.append(TimerOverlayRow(
                id: "\(timer.groupId).\(timer.id)",
                name: timer.displayName,
                remainingSeconds: remainingSec
            ))
        }
        overlay.update(rows: rows)

        // 6. Show popup/screen log messages as toasts (separate from the timer HUD).
        for log in dispatchOutput.hudLogs {
            toastOverlay.show(message: log.message, level: log.level)
        }

        // 7. Render interactive panels from getPanelHelper(). The overlay is
        //    an authoritative mirror of every enabled group's current panels,
        //    so panels from a disabled or no-longer-active group disappear.
        //    In-progress user input is preserved on the native side (the
        //    overlay dedupes identical snapshots and controls hold edits in
        //    local view state).
        var panelsByGroupID: [String: [PanelSnapshot]] = [:]
        for panel in dispatchOutput.panels {
            panelsByGroupID[panel.groupId ?? "", default: []].append(panel)
        }
        panelOverlay.replaceAll(panelsByGroupID)

        // Track state for next tick.
        lastFrontmost = frontmost
    }

    // MARK: - Event Dispatch

    /// Builds events and dispatches them for all enabled groups. Groups with
    /// `customRuleSource` get dispatched to the JS runtime; all groups get
    /// their events logged regardless.
    private struct DispatchOutput {
        var shieldedBundleIDs: Set<String>
        var customTimers: [CustomTimerSnapshot]
        var hudLogs: [(message: String, level: String)]
        var panels: [PanelSnapshot]
    }

    private func dispatchEvents(
        groups: [BlockGroup],
        frontmost: String?,
        usage: UsageSnapshot,
        now: Date,
        lifecycleEvents: [AppLifecycleEvent],
        switched: Bool
    ) -> DispatchOutput {
        let enabledGroups = groups.filter { $0.enabled }
        let ruleGroups = enabledGroups.filter { !$0.customRuleSource.isEmpty }

        // Reconcile the JS runtime for groups that have custom rules.
        if ruleGroups.isEmpty {
            if !loadedRuleSources.isEmpty { unloadAllRules() }
        } else if let runtime = ensureRuntime() {
            reconcileRuleRuntime(runtime: runtime, groups: ruleGroups)
        }

        var shieldedBundleIDs: Set<String> = []
        var allowedBundleIDs: Set<String> = []
        var collectedTimers: [CustomTimerSnapshot] = []
        var hudLogs: [(message: String, level: String)] = []
        var collectedPanels: [PanelSnapshot] = []

        for group in enabledGroups {
            guard group.isActive(at: now) else { continue }
            if usage.snoozesByGroup[group.id]?.phase(at: now) == .active { continue }

            let events = buildEventsForGroup(
                group: group, frontmost: frontmost, now: now,
                lifecycleEvents: lifecycleEvents, switched: switched
            )

            for event in events {
                if event.type != "tickEvent" {
                    appendLog(level: "log", group: group.name,
                              message: "event fired: \(event.type) | target: \(event.target?.displayName ?? "none") | app: \(event.data["appId"] ?? event.data["bundleId"] ?? "—") | url: \(event.url.isEmpty ? "—" : event.url)")
                }

                // Only dispatch to runtime if this group has a custom rule loaded.
                guard !group.customRuleSource.isEmpty, let runtime = ruleRuntime else { continue }

                let result: DispatchResult
                do {
                    result = try runtime.dispatch(event)
                } catch {
                    appendLog(level: "error", group: group.name,
                              message: "dispatch failed: \(error.localizedDescription)")
                    continue
                }

                for decision in result.decisions {
                    switch decision.action {
                    case .shield:
                        if decision.targetIDs.isEmpty, let fm = frontmost {
                            shieldedBundleIDs.insert(fm)
                        } else {
                            for id in decision.targetIDs {
                                shieldedBundleIDs.insert(id)
                            }
                        }
                    case .allow:
                        if decision.targetIDs.isEmpty, let fm = frontmost {
                            allowedBundleIDs.insert(fm)
                        } else {
                            for id in decision.targetIDs {
                                allowedBundleIDs.insert(id)
                            }
                        }
                    case .log:
                        let level = decision.metadata["level"] ?? "log"
                        let surface = decision.metadata["surface"] ?? "all"
                        appendLog(level: level, group: group.name, message: decision.reason)
                        if surface == "popup" || surface == "screen" || surface == "all" {
                            hudLogs.append((message: "[\(group.name)] \(decision.reason)", level: level))
                        }
                    case .showStatus, .quarantine, .requestSnooze, .unshield:
                        break
                    }
                }

                // Collect visible timers and panels from the last event
                // (tickEvent) to avoid duplicates from multiple events per group.
                if event.type == "tickEvent" {
                    collectedTimers.append(contentsOf: result.timers)
                    collectedPanels.append(contentsOf: result.panels)
                }

                processWindowIntents(result.intents, frontmost: frontmost)
            }
        }

        shieldedBundleIDs.subtract(allowedBundleIDs)
        return DispatchOutput(shieldedBundleIDs: shieldedBundleIDs, customTimers: collectedTimers, hudLogs: hudLogs, panels: collectedPanels)
    }

    private func buildEventsForGroup(
        group: BlockGroup,
        frontmost: String?,
        now: Date,
        lifecycleEvents: [AppLifecycleEvent],
        switched: Bool
    ) -> [CustomRuleEvent] {
        var events: [CustomRuleEvent] = []

        func make(type: String, data: [String: String] = [:]) -> CustomRuleEvent {
            makeEvent(type: type, group: group, frontmost: frontmost, data: data)
        }

        // Always fire tickEvent.
        events.append(make(type: "tickEvent", data: ["intervalMs": "1000"]))

        // Process notification-driven lifecycle events (no target filtering —
        // rules decide what to act on).
        for le in lifecycleEvents {
            let bundleData = ["bundleId": le.bundleID]
            switch le.kind {
            case .launched:
                events.append(make(type: "openAppEvent", data: bundleData))
                events.append(make(type: "appChangedEvent", data: ["reason": "open", "bundleId": le.bundleID]))
            case .terminated:
                events.append(make(type: "closeAppEvent", data: bundleData))
                events.append(make(type: "appChangedEvent", data: ["reason": "close", "bundleId": le.bundleID]))
            case .activated:
                events.append(make(type: "focusEvent", data: bundleData))
                events.append(make(type: "appChangedEvent", data: ["reason": "focus", "bundleId": le.bundleID]))
            case .deactivated:
                events.append(make(type: "unfocusEvent", data: bundleData))
                events.append(make(type: "appChangedEvent", data: ["reason": "unfocus", "bundleId": le.bundleID]))
            case .hidden:
                events.append(make(type: "minimizeEvent", data: bundleData))
                events.append(make(type: "appChangedEvent", data: ["reason": "minimize", "bundleId": le.bundleID]))
            case .unhidden:
                events.append(make(type: "unminimizeEvent", data: bundleData))
                events.append(make(type: "appChangedEvent", data: ["reason": "unminimize", "bundleId": le.bundleID]))
            }
        }

        // switchAppEvent: only fires on non-null → non-null frontmost change.
        if switched, let prev = lastFrontmost, let curr = frontmost {
            events.append(make(type: "switchAppEvent", data: [
                "previousAppId": prev,
                "currentAppId": curr
            ]))
            events.append(make(type: "appChangedEvent", data: [
                "reason": "switch",
                "previousAppId": prev,
                "currentAppId": curr
            ]))
        }

        return events
    }

    /// Helper to build a single event with standard enriched data.
    private func makeEvent(
        type: String,
        group: BlockGroup,
        frontmost: String?,
        data: [String: String] = [:]
    ) -> CustomRuleEvent {
        // App-level only: never derived from browser tab state. URL is a synthetic
        // app:// scheme and isBrowser is always false (site/tab/DOM is the
        // extension's domain).
        let url = frontmost.map { "app://\($0)" } ?? ""
        let hostname = frontmost ?? ""

        let matchingTarget = frontmost.flatMap { fm in
            group.targets.first(where: { $0.kind == .application && $0.id == fm })
        }

        var enrichedData = data
        enrichedData["appId"] = frontmost ?? ""
        enrichedData["appName"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        enrichedData["isBrowser"] = "false"
        enrichedData["groupName"] = group.name
        enrichedData["allApps"] = Self.runningAppsJSON()
        return CustomRuleEvent(
            type: type, groupID: group.id,
            target: matchingTarget, now: Date(),
            url: url, hostname: hostname, data: enrichedData
        )
    }

    /// Dispatches a single event (snoozePress, panelEvent, localFileEvent)
    /// outside the regular tick loop.
    private func dispatchSingleEvent(_ event: CustomRuleEvent, group: BlockGroup, frontmost: String?) {
        appendLog(level: "log", group: group.name,
                  message: "event fired: \(event.type) | target: \(event.target?.displayName ?? "none") | url: \(event.url.isEmpty ? "—" : event.url)")

        guard !group.customRuleSource.isEmpty, let runtime = ensureRuntime() else { return }

        // Ensure the rule is loaded.
        if loadedRuleSources[group.id] != group.customRuleSource {
            reconcileRuleRuntime(runtime: runtime, groups: [group])
        }

        let result: DispatchResult
        do {
            result = try runtime.dispatch(event)
        } catch {
            appendLog(level: "error", group: group.name,
                      message: "dispatch failed: \(error.localizedDescription)")
            return
        }

        for decision in result.decisions {
            switch decision.action {
            case .log:
                let level = decision.metadata["level"] ?? "log"
                let surface = decision.metadata["surface"] ?? "all"
                appendLog(level: level, group: group.name, message: decision.reason)
                if surface == "popup" || surface == "screen" || surface == "all" {
                    toastOverlay.show(message: "[\(group.name)] \(decision.reason)", level: level)
                }
            case .shield:
                if let fm = frontmost {
                    MacProcessTerminator.terminate(bundleIdentifier: fm)
                }
            default:
                break
            }
        }

        processWindowIntents(result.intents, frontmost: frontmost)

        panelOverlay.update(panels: result.panels, forGroup: group.id)
    }

    private func ensureRuntime() -> CustomJavaScriptPolicyRuntime? {
        if let rt = ruleRuntime { return rt }
        do {
            let rt = try CustomJavaScriptPolicyRuntime()
            // No tab provider is installed on purpose: __nativeGetAllTabs stays
            // undefined so the runtime's getAllTabs() returns []. The native app
            // never reads browser tabs; that's the extension's job.
            ruleRuntime = rt
            return rt
        } catch {
            appendLog(level: "error", group: "system", message: "Failed to create rule runtime: \(error)")
            return nil
        }
    }

    private func reconcileRuleRuntime(runtime: CustomJavaScriptPolicyRuntime, groups: [BlockGroup]) {
        let currentGroupIDs = Set(groups.map(\.id))
        let currentGroupNames = Set(groups.map(\.name))

        // Clean groups that are no longer enabled or have been removed.
        for (groupID, _) in loadedRuleSources where !currentGroupIDs.contains(groupID) {
            cleanRule(groupID: groupID)
        }

        // Purge log entries from groups that no longer exist.
        ruleLog.removeAll { entry in
            let g = entry.group
            if g == "system" || g.isEmpty { return false }
            return !currentGroupIDs.contains(g) && !currentGroupNames.contains(g)
        }

        // Build groups that are enabled but not yet loaded.
        for group in groups {
            if loadedRuleSources[group.id] != nil { continue }
            buildRule(groupID: group.id)
        }
    }

    /// Tear down a group's rule: unload JS, clear all per-group state
    /// (handlers, timers, persistence, blocklist, log dedup).
    /// Called on: disable group, or as the first half of Run.
    public func cleanRule(groupID: String) {
        #if os(macOS)
        guard let runtime = ruleRuntime else { return }
        if loadedRuleSources[groupID] != nil {
            runtime.unload(groupID: groupID)
            loadedRuleSources.removeValue(forKey: groupID)
        }
        // Immediately drop any panels this group rendered so they don't
        // linger on screen until the next tick (or forever if no other
        // group triggers a panel refresh).
        panelOverlay.removePanels(forGroup: groupID)
        #endif
    }

    /// Remove all log entries and overlay state associated with a group.
    public func purgeGroup(groupID: String) {
        #if os(macOS)
        let groupName = (webStore.importedGroups()?.groups ?? []).first(where: { $0.id == groupID })?.name
        cleanRule(groupID: groupID)
        let names = Set([groupID] + (groupName.map { [$0] } ?? []))
        ruleLog.removeAll { names.contains($0.group) }
        #endif
    }

    /// Compile and load a group's current source. Assumes clean state
    /// (call cleanRule first if reloading).
    /// Called on: enable group, or as the second half of Run.
    public func buildRule(groupID: String) {
        #if os(macOS)
        guard let runtime = ensureRuntime() else { return }
        let groups = webStore.importedGroups()?.groups ?? []
        guard let group = groups.first(where: { $0.id == groupID && !$0.customRuleSource.isEmpty }) else {
            return
        }
        guard loadedRuleSources[groupID] == nil else { return }
        do {
            let loadResult = try runtime.load(groupID: groupID, source: group.customRuleSource)
            loadedRuleSources[groupID] = group.customRuleSource
            appendLog(level: "log", group: group.name,
                      message: "Rule built: \(loadResult.handlers) handler(s)")
            for decision in loadResult.decisions where decision.action == .log {
                let level = decision.metadata["level"] ?? "log"
                appendLog(level: level, group: group.name, message: decision.reason)
            }
        } catch {
            loadedRuleSources.removeValue(forKey: groupID)
            appendLog(level: "error", group: group.name,
                      message: "Rule build failed: \(error.localizedDescription)")
        }
        #endif
    }

    /// Run = clean + build. Called when the user clicks Run in the editor.
    public func runRule(groupID: String) {
        cleanRule(groupID: groupID)
        buildRule(groupID: groupID)
    }

    private func processWindowIntents(_ intents: [WindowIntent], frontmost: String?) {
        for intent in intents {
            if intent.kind == "localFile" {
                processLocalFileIntent(intent)
                continue
            }
            switch intent.action {
            case "close":
                if let target = intent.target, !target.isEmpty,
                   !MacProcessTerminator.isBrowserBundleIdentifier(target) {
                    MacProcessTerminator.terminate(bundleIdentifier: target)
                } else if let fm = frontmost,
                          !MacProcessTerminator.isBrowserBundleIdentifier(fm) {
                    MacProcessTerminator.terminate(bundleIdentifier: fm)
                }
            // Web-level intents (closeTab / closeTabsByPattern / blockSite /
            // unblockSite) are deliberately ignored — neither acted on nor
            // logged. Site/tab/DOM enforcement belongs entirely to the
            // customBlocker browser extension, which runs the same rule against
            // its own web events. The native app must not touch in-browser
            // affairs at any level; it only enforces whole-app intents.
            case "blockApp":
                if let target = intent.target, !target.isEmpty,
                   !MacProcessTerminator.isBrowserBundleIdentifier(target) {
                    blockedAppBundleIDs.insert(target)
                    MacProcessTerminator.terminate(bundleIdentifier: target)
                    appendLog(level: "log", group: "system",
                              message: "App blocked: \(target)")
                }
            case "unblockApp":
                if let target = intent.target, !target.isEmpty {
                    blockedAppBundleIDs.remove(target)
                    appendLog(level: "log", group: "system",
                              message: "App unblocked: \(target)")
                }
            case "openApp":
                if let target = intent.target, !target.isEmpty,
                   !MacProcessTerminator.isBrowserBundleIdentifier(target) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
                        NSWorkspace.shared.openApplication(at: url,
                                                           configuration: NSWorkspace.OpenConfiguration())
                        appendLog(level: "log", group: "system",
                                  message: "App opened: \(target)")
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: - Local File I/O

    private lazy var localFileBroker: LocalFileBroker = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("MacBlocker/LocalFiles", isDirectory: true)
        return LocalFileBroker(baseURL: folder)
    }()

    private func processLocalFileIntent(_ intent: WindowIntent) {
        guard let groupId = intent.groupId, !groupId.isEmpty,
              let requestId = intent.requestId, !requestId.isEmpty else { return }
        let action = intent.action
        let path = intent.path ?? ""

        Task { @MainActor in
            let resultData = localFileBroker.handle(
                action: action,
                path: path,
                text: intent.text,
                requestID: requestId
            )
            fireLocalFileEvent(groupID: groupId, data: resultData)
        }
    }

    private func unloadAllRules() {
        guard let runtime = ruleRuntime else { return }
        for groupID in loadedRuleSources.keys {
            runtime.unload(groupID: groupID)
        }
        loadedRuleSources.removeAll()
    }

    private func appendLog(level: String, group: String, message: String) {
        print("[MacEnforcementBridge] [\(group)] \(level): \(message)")
        let entry = RuleLogEntry(timestamp: Date(), level: level, group: group, message: message)
        ruleLog.append(entry)
        if ruleLog.count > 200 {
            ruleLog.removeFirst(ruleLog.count - 200)
        }
    }

    // MARK: - Helpers

    private func elapsedSinceLastSample(now: Date) -> TimeInterval {
        guard let lastSampleAt else { return 0 }
        return min(max(0, now.timeIntervalSince(lastSampleAt)), tickInterval * 4)
    }

    private func reconcileUsage(
        groups: [BlockGroup],
        frontmost: String?,
        elapsed: TimeInterval,
        now: Date
    ) -> [String: Double] {
        let current = webStore.loadUsageTimers()
        var timers = current.timersMs
        var resetAt = current.resetAtMs
        let nowMs = now.timeIntervalSince1970 * 1000

        var timerWrites: [String: Double] = [:]
        var resetWrites: [String: Double] = [:]

        for group in groups where group.enabled {
            guard group.mode == .timer || group.mode == .afterMinutes else { continue }
            let gid = group.id

            var anchor = resetAt[gid]
            if anchor == nil {
                anchor = nowMs
                resetAt[gid] = nowMs
                resetWrites[gid] = nowMs
            }

            let intervalMs = Double(max(0, group.resetIntervalHours)) * 3_600_000
            if intervalMs > 0, let start = anchor {
                let sinceReset = nowMs - start
                if sinceReset >= intervalMs {
                    let elapsedIntervals = floor(sinceReset / intervalMs)
                    let newStart = start + elapsedIntervals * intervalMs
                    timers[gid] = 0
                    resetAt[gid] = newStart
                    timerWrites[gid] = 0
                    resetWrites[gid] = newStart
                }
            }

            var addedMs: Double = 0
            if let frontmost, elapsed > 0, group.isActive(at: now),
               group.targets.contains(where: { $0.kind == .application && $0.id == frontmost }) {
                addedMs = elapsed * 1000
                timers[gid, default: 0] += addedMs
                timerWrites[gid] = timers[gid]
            }

            // Web-app bridge: a clustered Default group shares ONE live budget.
            // We are the accrual owner for app-time, so report this tick's
            // increment to the hub (the single accumulator) and fold the
            // authoritative shared total back into the local timer so the Mac
            // display + enforcement reflect time spent on every linked member
            // (browser website time included). reportLocalUsage is a no-op when
            // the group isn't clustered, so the gate keeps non-bridge groups
            // entirely local.
            if ConnectionHub.shared.sharedUsage(groupName: group.name) != nil {
                // We report resetAtMs:0 (no rollover signal) because the Mac's
                // local window anchor (nowMs-based) is NOT comparable to the
                // browser's; letting it drive the hub's rollover would wipe the
                // shared budget on first report. The browser is the reset
                // authority; we just adopt the hub's anchor on fold so our local
                // enforcement window stays aligned.
                if clusterSeededGroups.contains(gid) {
                    ConnectionHub.shared.reportLocalUsage(
                        groupName: group.name,
                        deltaMs: addedMs,
                        resetAtMs: 0
                    )
                } else {
                    // First report since joining: seed our current local total
                    // (which already includes this tick's accrual) with no delta,
                    // so prior Mac usage is preserved on the shared budget.
                    ConnectionHub.shared.reportLocalUsage(
                        groupName: group.name,
                        deltaMs: 0,
                        resetAtMs: 0,
                        seedMs: timers[gid] ?? 0
                    )
                    clusterSeededGroups.insert(gid)
                }
                if let shared = ConnectionHub.shared.sharedUsage(groupName: group.name) {
                    let total = max(0, shared.ms)
                    if timers[gid] != total {
                        timers[gid] = total
                        timerWrites[gid] = total
                    }
                    if shared.resetAtMs > 0, resetAt[gid] != shared.resetAtMs {
                        resetAt[gid] = shared.resetAtMs
                        resetWrites[gid] = shared.resetAtMs
                    }
                }
            } else {
                // Group isn't clustered: forget any seed flag so a future re-link
                // re-seeds its then-current local total.
                clusterSeededGroups.remove(gid)
            }
        }

        webStore.writeUsage(timersMs: timerWrites, resetAtMs: resetWrites)
        return timers
    }

    private static func runningAppsJSON() -> String {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> [String: Any]? in
                guard let bid = app.bundleIdentifier else { return nil }
                guard !MacProcessTerminator.isBrowserBundleIdentifier(bid) else { return nil }
                // The native app does not distinguish browsers — it never reads
                // tabs, so every app is reported as a plain app (isBrowser:false).
                return [
                    "id": bid,
                    "name": app.localizedName ?? bid,
                    "isBrowser": false
                ]
            }
        guard let data = try? JSONSerialization.data(withJSONObject: apps),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private func matchingTargetIDs(groups: [BlockGroup], frontmost: String?) -> Set<String> {
        guard let frontmost else { return [] }
        var ids: Set<String> = []
        for group in groups {
            for target in group.targets where target.kind == .application && target.id == frontmost {
                ids.insert(target.id)
            }
        }
        return ids
    }
    #endif
}

/// A single entry in the custom-rule log.
public struct RuleLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let level: String
    public let group: String
    public let message: String
}
