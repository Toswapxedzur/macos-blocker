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
/// On a short repeating tick it:
///   1. samples the frontmost application and accrues "time spent" into timed
///      groups that target it (the macOS analogue of the extension's per-page
///      heartbeat), persisting usage to the shared store;
///   2. re-evaluates the groups against schedule + usage and enforces only what
///      should be blocked right now (so timer groups block exactly when their
///      budget runs out, never before);
///   3. dispatches native events into the custom-rule JS runtime for groups
///      that have a `customRuleSource`, collecting shield/allow/log decisions
///      that drive enforcement alongside mode/schedule blocking;
///   4. renders the remaining time of any active timer in an always-on-top
///      overlay panel that floats over every app, including full-screen ones —
///      the native equivalent of the extension's on-page timer overlay.
///
/// Off macOS it is an inert holder for the shared `BlockerWebStore`.
@MainActor
public final class MacEnforcementBridge: ObservableObject {
    /// Shared store the editor persists into and we read groups back out of.
    public let webStore: BlockerWebStore

    /// Rolling log of custom-rule output (capped). Published so the web UI
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
    private var wasActiveByGroup: [String: Bool] = [:]
    private var wasOverThresholdByGroup: [String: Bool] = [:]

    // Browser tab + dynamic site blocklist
    private let focusObserver = BrowserFocusObserver()
    private let siteBlocklist = DynamicSiteBlocklist()
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

    /// Begins enforcement: an initial evaluation plus a repeating tick that
    /// accrues usage, re-evaluates, enforces, and refreshes the timer HUD.
    public func start() {
        #if os(macOS)
        guard timer == nil else { return }
        lastSampleAt = Date()
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
        #endif
    }

    #if os(macOS)
    private func tick() {
        let now = Date()
        let importResult = webStore.importedGroups()
        let groups = importResult?.groups ?? []
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if importResult == nil {
            print("[MacEnforcementBridge] tick: importedGroups() returned nil — no stored data or decode error.")
        }

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

        // 2. Dispatch custom-rule events and collect shield decisions.
        let ruleBlocked = dispatchCustomRules(
            groups: groups, frontmost: frontmost, usage: usage, now: now
        )

        // 3. Enforce: block apps whose group says "blocked now" PLUS
        //    any apps shield-ed by custom-rule decisions.
        Task { [adapter, ruleBlocked] in
            try? await adapter.applyGroups(
                groups, usage: usage, now: now,
                customBlockedBundleIDs: ruleBlocked
            )
        }

        // 4. Render the HUD for any timer whose app is currently frontmost.
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

        // Track frontmost for change detection next tick.
        lastFrontmost = frontmost
    }

    // MARK: - Custom Rule Dispatch

    private var didLogFirstDispatch = false

    private func dispatchCustomRules(
        groups: [BlockGroup],
        frontmost: String?,
        usage: UsageSnapshot,
        now: Date
    ) -> Set<String> {
        let ruleGroups = groups.filter { $0.enabled && !$0.customRuleSource.isEmpty }
        if !didLogFirstDispatch {
            didLogFirstDispatch = true
            print("[MacEnforcementBridge] dispatchCustomRules: \(groups.count) total groups, \(ruleGroups.count) custom rule groups")
            for g in groups {
                print("  - \(g.name) (type=\(g.groupType), enabled=\(g.enabled), ruleSource=\(g.customRuleSource.prefix(60)))")
            }
        }
        guard !ruleGroups.isEmpty else {
            if !loadedRuleSources.isEmpty {
                unloadAllRules()
            }
            return []
        }

        let runtime = ensureRuntime()
        guard let runtime else { return [] }

        reconcileRuleRuntime(runtime: runtime, groups: ruleGroups)

        var shieldedBundleIDs: Set<String> = []
        var allowedBundleIDs: Set<String> = []

        for group in ruleGroups {
            guard group.isActive(at: now) else { continue }
            if usage.snoozesByGroup[group.id]?.phase(at: now) == .active { continue }

            let matchingTarget = frontmost.flatMap { fm in
                group.targets.first(where: { $0.kind == .application && $0.id == fm })
            }

            let events = buildEventsForGroup(
                group: group, frontmost: frontmost,
                matchingTarget: matchingTarget, usage: usage, now: now
            )

            for event in events {
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

            // Track threshold crossings for usageThresholdReached.
            if group.mode == .timer || group.mode == .afterMinutes {
                let used = usage.usageByGroupSeconds[group.id] ?? 0
                let allowed = TimeInterval(max(0, group.allowedMinutes) * 60)
                let isOver = allowed > 0 && used >= allowed
                wasOverThresholdByGroup[group.id] = isOver
            }
        }

        shieldedBundleIDs.subtract(allowedBundleIDs)
        return shieldedBundleIDs
    }

    private func buildEventsForGroup(
        group: BlockGroup,
        frontmost: String?,
        matchingTarget: BlockTarget?,
        usage: UsageSnapshot,
        now: Date
    ) -> [CustomRuleEvent] {
        var events: [CustomRuleEvent] = []

        // Use real browser tab URL when available; fall back to app:// scheme.
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

        func makeEvent(type: String, data: [String: String] = [:]) -> CustomRuleEvent {
            var enrichedData = data
            enrichedData["appId"] = frontmost ?? ""
            enrichedData["appName"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            enrichedData["isBrowser"] = isBrowser ? "true" : "false"
            if let tab = lastBrowserTab {
                enrichedData["tabTitle"] = tab.title
            }
            return CustomRuleEvent(
                type: type, groupID: group.id,
                target: matchingTarget, now: now,
                url: url, hostname: hostname, data: enrichedData
            )
        }

        // Always fire tickEvent.
        events.append(makeEvent(type: "tickEvent"))

        // Focus transitions.
        let prevFrontmost = lastFrontmost
        if frontmost != prevFrontmost {
            if matchingTarget != nil {
                events.append(makeEvent(type: "openWebEvent"))
                events.append(makeEvent(type: "switchWebEvent"))
                events.append(makeEvent(type: "webChangedEvent"))
            } else if prevFrontmost != nil,
                      group.targets.contains(where: { $0.kind == .application && $0.id == prevFrontmost! }) {
                events.append(makeEvent(type: "closeWebEvent"))
            }
        }

        // Schedule transitions.
        let wasActive = wasActiveByGroup[group.id] ?? true
        let isActive = group.isActive(at: now)
        if isActive != wasActive {
            events.append(makeEvent(type: "scheduleChanged", data: ["active": isActive ? "true" : "false"]))
        }
        wasActiveByGroup[group.id] = isActive

        // usageThresholdReached: fires once when timer crosses its limit.
        if group.mode == .timer || group.mode == .afterMinutes {
            let used = usage.usageByGroupSeconds[group.id] ?? 0
            let allowed = TimeInterval(max(0, group.allowedMinutes) * 60)
            let isOver = allowed > 0 && used >= allowed
            let wasOver = wasOverThresholdByGroup[group.id] ?? false
            if isOver && !wasOver {
                events.append(makeEvent(type: "usageThresholdReached"))
            }
        }

        return events
    }

    private func ensureRuntime() -> CustomJavaScriptPolicyRuntime? {
        if let rt = ruleRuntime { return rt }
        do {
            let rt = try CustomJavaScriptPolicyRuntime()
            ruleRuntime = rt
            return rt
        } catch {
            appendLog(level: "error", group: "system", message: "Failed to create rule runtime: \(error)")
            return nil
        }
    }

    private func reconcileRuleRuntime(runtime: CustomJavaScriptPolicyRuntime, groups: [BlockGroup]) {
        let currentGroupIDs = Set(groups.map(\.id))

        // Unload removed/disabled groups.
        for (groupID, _) in loadedRuleSources where !currentGroupIDs.contains(groupID) {
            runtime.unload(groupID: groupID)
            loadedRuleSources.removeValue(forKey: groupID)
        }

        // Load/reload changed sources.
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
                if let fm = frontmost, BrowserTabReader.isBrowser(fm) {
                    BrowserTabReader.closeActiveTab(browserBundleID: fm)
                }
            case "blockSite":
                if let pattern = intent.pattern, !pattern.isEmpty {
                    siteBlocklist.add(pattern)
                    appendLog(level: "log", group: "system",
                              message: "Site blocked: \(pattern)")
                }
            case "unblockSite":
                if let pattern = intent.pattern, !pattern.isEmpty {
                    siteBlocklist.remove(pattern)
                    appendLog(level: "log", group: "system",
                              message: "Site unblocked: \(pattern)")
                }
            default:
                break
            }
        }
    }

    /// Handles a chokepoint event from the browser focus observer.
    /// Fires custom-rule events immediately (instead of waiting for the next tick).
    private func handleBrowserFocusEvent(_ event: BrowserFocusObserver.FocusEvent) {
        lastBrowserTab = event.tab

        // Check dynamic blocklist immediately on focus/URL change.
        if let tab = event.tab, siteBlocklist.isBlocked(tab.url) {
            BrowserTabReader.closeActiveTab(browserBundleID: tab.browserBundleID)
            appendLog(level: "log", group: "system",
                      message: "Closed blocked site (chokepoint): \(tab.url)")
            return
        }

        // Fire custom rule events for the URL change.
        let now = Date()
        let groups = webStore.importedGroups()?.groups ?? []
        let frontmost = event.browserBundleID
        let ruleGroups = groups.filter { $0.enabled && !$0.customRuleSource.isEmpty }
        guard !ruleGroups.isEmpty, let runtime = ensureRuntime() else { return }

        for group in ruleGroups {
            guard group.isActive(at: now) else { continue }
            let eventType = event.trigger == .appActivated ? "openWebEvent" : "webChangedEvent"
            let url = event.tab?.url ?? ""
            let hostname = URL(string: url)?.host ?? frontmost

            var data: [String: String] = [
                "appId": frontmost,
                "appName": BrowserTabReader.isBrowser(frontmost) ? frontmost : "",
                "isBrowser": "true"
            ]
            if let tab = event.tab { data["tabTitle"] = tab.title }

            let ruleEvent = CustomRuleEvent(
                type: eventType, groupID: group.id,
                target: nil, now: now,
                url: url, hostname: hostname, data: data
            )
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
        let entry = RuleLogEntry(timestamp: Date(), level: level, group: group, message: message)
        ruleLog.append(entry)
        if ruleLog.count > 200 {
            ruleLog.removeFirst(ruleLog.count - 200)
        }
    }

    // MARK: - Usage

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
