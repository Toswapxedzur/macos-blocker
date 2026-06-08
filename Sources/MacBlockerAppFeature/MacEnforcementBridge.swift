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
    private var timer: Timer?
    private let tickInterval: TimeInterval
    private var lastSampleAt: Date?

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

    // Browser tab + dynamic site blocklist + persistent app blocklist
    private let focusObserver = BrowserFocusObserver()
    private let siteBlocklist = DynamicSiteBlocklist()
    private var blockedAppBundleIDs: Set<String> = []
    private var lastBrowserTab: BrowserTabReader.TabInfo?
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
        tick()
        let timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        self.timer = timer

        focusObserver.onFocusEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleBrowserFocusEvent(event)
            }
        }
        focusObserver.start()
        #endif
    }

    public func stop() {
        #if os(macOS)
        timer?.invalidate()
        timer = nil
        lastSampleAt = nil
        overlay.hide()
        focusObserver.stop()
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
                      let bundleID = app.bundleIdentifier else { return }
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
        let now = Date()
        let importResult = webStore.importedGroups()
        let groups = importResult?.groups ?? []
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Read browser tab URL if frontmost is a browser.
        if let fm = frontmost, BrowserTabReader.isBrowser(fm) {
            lastBrowserTab = BrowserTabReader.currentTab(browserBundleID: fm)
        } else {
            lastBrowserTab = nil
        }

        // 1. Reconcile reset windows + accrue time spent in the frontmost app.
        let elapsed = elapsedSinceLastSample(now: now)
        lastSampleAt = now
        let timersMs = reconcileUsage(groups: groups, frontmost: frontmost, elapsed: elapsed, now: now)
        let usage = UsageSnapshot(
            usageByGroupSeconds: timersMs.mapValues { $0 / 1000 },
            snoozesByGroup: webStore.loadSnoozes()
        )

        // Check dynamic site blocklist against current tab.
        if let tab = lastBrowserTab, siteBlocklist.isBlocked(tab.url) {
            BrowserTabReader.closeActiveTab(browserBundleID: tab.browserBundleID)
            appendLog(level: "log", group: "system",
                      message: "Closed blocked site: \(tab.url)")
        }

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
        let ruleBlocked = dispatchEvents(
            groups: groups, frontmost: frontmost, usage: usage, now: now,
            lifecycleEvents: lifecycleEvents, switched: switched
        )

        // 4. Enforce: block apps whose group says "blocked now" PLUS
        //    any apps shield-ed by custom-rule decisions.
        Task { [adapter, ruleBlocked] in
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
        let rows = result.visibleTimerItems.map {
            TimerOverlayRow(id: $0.groupID, name: $0.name, remainingSeconds: $0.remainingSeconds)
        }
        overlay.update(rows: rows)

        // Track state for next tick.
        lastFrontmost = frontmost
    }

    // MARK: - Event Dispatch

    /// Builds events and dispatches them for all enabled groups. Groups with
    /// `customRuleSource` get dispatched to the JS runtime; all groups get
    /// their events logged regardless.
    private func dispatchEvents(
        groups: [BlockGroup],
        frontmost: String?,
        usage: UsageSnapshot,
        now: Date,
        lifecycleEvents: [AppLifecycleEvent],
        switched: Bool
    ) -> Set<String> {
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
                        appendLog(level: level, group: group.name, message: decision.reason)
                    case .showStatus, .quarantine, .requestSnooze, .unshield:
                        break
                    }
                }

                processWindowIntents(result.intents, frontmost: frontmost)
            }
        }

        shieldedBundleIDs.subtract(allowedBundleIDs)
        return shieldedBundleIDs
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
        let url: String
        let hostname: String
        if let tab = lastBrowserTab {
            url = tab.url
            hostname = URL(string: tab.url)?.host ?? frontmost ?? ""
        } else {
            url = frontmost.map { "app://\($0)" } ?? ""
            hostname = frontmost ?? ""
        }

        let isBrowser = frontmost.map { BrowserTabReader.isBrowser($0) } ?? false
        let matchingTarget = frontmost.flatMap { fm in
            group.targets.first(where: { $0.kind == .application && $0.id == fm })
        }

        var enrichedData = data
        enrichedData["appId"] = frontmost ?? ""
        enrichedData["appName"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        enrichedData["isBrowser"] = isBrowser ? "true" : "false"
        if let tab = lastBrowserTab {
            enrichedData["tabTitle"] = tab.title
        }
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
                appendLog(level: level, group: group.name, message: decision.reason)
            case .shield:
                if let fm = frontmost {
                    MacProcessTerminator.terminate(bundleIdentifier: fm)
                }
            default:
                break
            }
        }

        processWindowIntents(result.intents, frontmost: frontmost)
    }

    private func ensureRuntime() -> CustomJavaScriptPolicyRuntime? {
        if let rt = ruleRuntime { return rt }
        do {
            let rt = try CustomJavaScriptPolicyRuntime()
            rt.tabProvider = { BrowserTabReader.allTabsJSON() }
            rt.installTabProvider()
            ruleRuntime = rt
            return rt
        } catch {
            appendLog(level: "error", group: "system", message: "Failed to create rule runtime: \(error)")
            return nil
        }
    }

    private func reconcileRuleRuntime(runtime: CustomJavaScriptPolicyRuntime, groups: [BlockGroup]) {
        let currentGroupIDs = Set(groups.map(\.id))

        for (groupID, _) in loadedRuleSources where !currentGroupIDs.contains(groupID) {
            runtime.unload(groupID: groupID)
            loadedRuleSources.removeValue(forKey: groupID)
        }

        for group in groups {
            let source = group.customRuleSource
            if loadedRuleSources[group.id] == source { continue }
            if loadedRuleSources[group.id] != nil {
                runtime.unload(groupID: group.id)
            }
            do {
                let loadResult = try runtime.load(groupID: group.id, source: source)
                loadedRuleSources[group.id] = source
                appendLog(level: "log", group: group.name,
                          message: "Rule loaded: \(loadResult.handlers) handler(s)")
                for decision in loadResult.decisions where decision.action == .log {
                    let level = decision.metadata["level"] ?? "log"
                    appendLog(level: level, group: group.name, message: decision.reason)
                }
            } catch {
                loadedRuleSources.removeValue(forKey: group.id)
                appendLog(level: "error", group: group.name,
                          message: "Rule load failed: \(error.localizedDescription)")
            }
        }
    }

    private func processWindowIntents(_ intents: [WindowIntent], frontmost: String?) {
        for intent in intents {
            switch intent.action {
            case "close":
                if let target = intent.target, !target.isEmpty {
                    MacProcessTerminator.terminate(bundleIdentifier: target)
                } else if let fm = frontmost {
                    MacProcessTerminator.terminate(bundleIdentifier: fm)
                }
            case "closeTab":
                if let bid = intent.browserBundleID,
                   let wIdx = intent.windowIndex,
                   let tIdx = intent.tabIndex {
                    BrowserTabReader.closeTab(browserBundleID: bid, windowIndex: wIdx, tabIndex: tIdx)
                } else if let fm = frontmost, BrowserTabReader.isBrowser(fm) {
                    BrowserTabReader.closeActiveTab(browserBundleID: fm)
                }
            case "closeTabsByPattern":
                if let pattern = intent.pattern, !pattern.isEmpty {
                    let closed = BrowserTabReader.closeTabsMatching(pattern: pattern)
                    if closed > 0 {
                        appendLog(level: "log", group: "system",
                                  message: "Closed \(closed) tab(s) matching: \(pattern)")
                    }
                }
            case "blockSite":
                if let pattern = intent.pattern, !pattern.isEmpty {
                    siteBlocklist.add(pattern)
                    BrowserTabReader.closeTabsMatching(pattern: pattern)
                    appendLog(level: "log", group: "system",
                              message: "Site blocked: \(pattern)")
                }
            case "unblockSite":
                if let pattern = intent.pattern, !pattern.isEmpty {
                    siteBlocklist.remove(pattern)
                    appendLog(level: "log", group: "system",
                              message: "Site unblocked: \(pattern)")
                }
            case "blockApp":
                if let target = intent.target, !target.isEmpty {
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
                if let target = intent.target, !target.isEmpty {
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

    /// Handles a chokepoint event from the browser focus observer.
    /// Fires appChangedEvent immediately (instead of waiting for the next tick).
    private func handleBrowserFocusEvent(_ event: BrowserFocusObserver.FocusEvent) {
        lastBrowserTab = event.tab

        if let tab = event.tab, siteBlocklist.isBlocked(tab.url) {
            BrowserTabReader.closeActiveTab(browserBundleID: tab.browserBundleID)
            appendLog(level: "log", group: "system",
                      message: "Closed blocked site (chokepoint): \(tab.url)")
            return
        }

        let now = Date()
        let groups = webStore.importedGroups()?.groups ?? []
        let frontmost = event.browserBundleID
        let ruleGroups = groups.filter { $0.enabled && !$0.customRuleSource.isEmpty }
        guard !ruleGroups.isEmpty, let runtime = ensureRuntime() else { return }

        for group in ruleGroups {
            guard group.isActive(at: now) else { continue }
            // Only fire appChangedEvent from the chokepoint — switchAppEvent is
            // handled by the tick loop to avoid duplicates.
            guard event.trigger == .urlChanged else { continue }
            let url = event.tab?.url ?? ""
            let hostname = URL(string: url)?.host ?? frontmost

            var data: [String: String] = [
                "appId": frontmost,
                "appName": BrowserTabReader.isBrowser(frontmost) ? frontmost : "",
                "isBrowser": "true",
                "reason": "urlChanged"
            ]
            if let tab = event.tab { data["tabTitle"] = tab.title }

            let matchingTarget = group.targets.first(where: { $0.kind == .application && $0.id == frontmost })
            let ruleEvent = CustomRuleEvent(
                type: "appChangedEvent", groupID: group.id,
                target: matchingTarget, now: now,
                url: url, hostname: hostname, data: data
            )
            appendLog(level: "log", group: group.name,
                      message: "event fired: appChangedEvent | target: \(matchingTarget?.displayName ?? "none") | url: \(url.isEmpty ? "—" : url)")
            do {
                let result = try runtime.dispatch(ruleEvent)
                for decision in result.decisions where decision.action == .shield {
                    if BrowserTabReader.isBrowser(frontmost) {
                        BrowserTabReader.closeActiveTab(browserBundleID: frontmost)
                        appendLog(level: "log", group: group.name,
                                  message: "Blocked tab (chokepoint): \(url)")
                    }
                    break
                }
                processWindowIntents(result.intents, frontmost: frontmost)
            } catch {
                appendLog(level: "error", group: group.name,
                          message: "chokepoint dispatch failed: \(error.localizedDescription)")
            }
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

            if let frontmost, elapsed > 0, group.isActive(at: now),
               group.targets.contains(where: { $0.kind == .application && $0.id == frontmost }) {
                timers[gid, default: 0] += elapsed * 1000
                timerWrites[gid] = timers[gid]
            }
        }

        webStore.writeUsage(timersMs: timerWrites, resetAtMs: resetWrites)
        return timers
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
