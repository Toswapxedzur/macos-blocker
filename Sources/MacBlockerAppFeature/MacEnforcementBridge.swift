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
/// Scope line (owner 2026-09-27): Mac Vault controls apps only and never a
/// website — it reads no browser tab and acts on nothing inside a browser;
/// sites, pages and tabs belong to the browser extension.
///
/// Custom rules (rule-core.js, run by `RuleRuntime`) get Mac Vault's events —
/// "tick" every second ({ frontmost, running }) and "app" as apps launch,
/// quit, come to the front or leave it, hide or unhide — plus "snooze",
/// "panel" and "file"; they act with v.block / v.quit / v.open (apps), panels,
/// the folder and their state.
@MainActor
public final class MacEnforcementBridge: ObservableObject {
    /// The one engine of the process (owner 2026-09-26: Mac Vault blocks the
    /// whole time it runs, window open or not; it stops when the user quits).
    /// It reads linked groups through the hub's live shared state.
    public static let shared: MacEnforcementBridge = {
        let bridge = MacEnforcementBridge()
        GroupStore.sharedOverlay = { ConnectionHub.shared.overlayShared(onto: $0) }
        // A tool's snooze of a custom group is the rule's snooze press, as the editor's.
        VaultMCPTools.snoozePress = { id in Task { @MainActor in MacEnforcementBridge.shared.fireSnoozePress(groupID: id) } }
        // A tool's Run is the editor's Run.
        VaultMCPTools.runRule = { id, source in
            let run = { MainActor.assumeIsolated { MacEnforcementBridge.shared.runRule(groupID: id, source: source) } }
            return Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
        }
        return bridge
    }()

    /// Shared store the editor persists into and we read groups back out of.
    public let webStore: BlockerWebStore

    /// Pending v.log output (capped independently per group). Published so the web UI
    /// can display it.
    @Published public var ruleLog: [RuleLogEntry] = []

    #if os(macOS)
    private let adapter: AppBlockPolicy
    private let overlay = TimerOverlayPanelController()
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

    // Custom rules: the loaded source and the event types each handles.
    private var ruleRuntime: RuleRuntime?
    private var loadedRuleSources: [String: String] = [:]
    private var ruleTypes: [String: Set<String>] = [:]
    /// Disabled groups: the rule stays loaded but hears nothing, and its panels
    /// and app blocks are lifted until the group is enabled (owner 2026-09-27).
    private var suppressedRules: Set<String> = []
    /// Each rule's current panels (shown only while its group is enabled).
    private var rulePanels: [String: [PanelSnapshot]] = [:]
    private var quarantinedRuleSources: [String: String] = [:]
    private var lastFrontmost: String?

    // Notification-driven lifecycle event queue. NSWorkspace notifications
    // push events here; the tick loop drains them.
    private struct AppLifecycleEvent {
        enum Kind: String { case launch, quit, focus, blur, hide, unhide }
        let kind: Kind
        let bundleID: String
        let name: String
    }
    private var pendingLifecycleEvents: [AppLifecycleEvent] = []
    private var workspaceObservers: [Any] = []

    // The apps each group's rule blocked (v.block), until it unblocks them or
    // its rule is Run again, disabled or deleted.
    private var blockedAppBundleIDsByGroup: [String: Set<String>] = [:]
    /// The apps the enabled groups' rules blocked (a rule runs whenever its
    /// group is enabled, as in the browser).
    private func ruleBlockedApps(groups: [BlockGroup]) -> Set<String> {
        groups.reduce(into: Set<String>()) { union, group in
            guard group.enabled, let apps = blockedAppBundleIDsByGroup[group.id] else { return }
            union.formUnion(apps)
        }
    }

    // Panel event throttle (leading-edge, trailing flush at tick)
    private static let panelThrottleInterval: TimeInterval = 0.10
    private var lastPanelFireAt: [String: Date] = [:]
    private var pendingPanelEvents: [String: (groupID: String, data: [String: Any])] = [:]

    /// The Activity log's app-usage recorder, fed by this tick.
    public var activityRecorder: ActivityRecorderService?
    #endif

    public init(webStore: BlockerWebStore = BlockerWebStore(), sweepInterval: TimeInterval = 1.0) {
        self.webStore = webStore
        #if os(macOS)
        self.adapter = AppBlockPolicy()
        self.tickInterval = sweepInterval
        #endif
    }

    /// Re-evaluates immediately (e.g. right after an editor save).
    public func refresh() {
        #if os(macOS)
        tick(everySecond: false)
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
             "source": "v.log", "groupId": $0.groupId,
             "level": $0.level, "group": $0.group, "message": $0.message]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dicts),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    // MARK: - Public event triggers

    /// The group's Snooze: its rule's "snooze" event (the rule decides).
    public func fireSnoozePress(groupID: String) {
        #if os(macOS)
        dispatchRule(type: "snooze", data: [String: Any](), groupID: groupID)
        #endif
    }

    /// A rule's panel interaction: its "panel" event.
    public func firePanelEvent(groupID: String, data: [String: Any]) {
        #if os(macOS)
        dispatchRule(type: "panel", data: data, groupID: groupID)
        #endif
    }

    #if os(macOS)
    /// An event from outside the tick (the editor, a panel, the folder): the
    /// group is read once.
    private func dispatchRule(type: String, data: Any, groupID: String) {
        guard ruleTypes[groupID]?.contains(type) == true,
              let group = webStore.importedGroups().first(where: { $0.id == groupID }) else { return }
        dispatchRule(type: type, data: data, group: group)
    }
    #endif

    /// Begins enforcement: an initial evaluation plus a repeating tick that
    /// accrues usage, re-evaluates, enforces, and refreshes the timer HUD.
    public func start() {
        #if os(macOS)
        guard timer == nil else { return }
        webStore.seedIfNeeded()
        lastSampleAt = Date()
        lastFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        registerWorkspaceObservers()
        panelOverlay.setEventHandler { [weak self] groupID, panelId, controlId, eventName, value, extra in
            guard let self else { return }
            let values = (try? JSONSerialization.jsonObject(with: Data(extra.utf8))) as? [String: Any] ?? [:]
            let data: [String: Any] = [
                "panelId": panelId,
                "controlId": controlId,
                "eventName": eventName,
                "value": value,
                "values": values
            ]
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
            Task { @MainActor [weak self] in
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
        panelOverlay.teardown()
        unregisterWorkspaceObservers()
        #endif
    }

    #if os(macOS)
    // MARK: - Workspace Notification Observers

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let mapping: [(NSNotification.Name, AppLifecycleEvent.Kind)] = [
            (.init("NSWorkspaceDidLaunchApplicationNotification"), .launch),
            (.init("NSWorkspaceDidTerminateApplicationNotification"), .quit),
            (.init("NSWorkspaceDidActivateApplicationNotification"), .focus),
            (.init("NSWorkspaceDidDeactivateApplicationNotification"), .blur),
            (.init("NSWorkspaceDidHideApplicationNotification"), .hide),
            (.init("NSWorkspaceDidUnhideApplicationNotification"), .unhide),
        ]
        for (name, kind) in mapping {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Every app counts, menu-bar and background ones included.
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                let event = AppLifecycleEvent(kind: kind, bundleID: bundleID, name: app.localizedName ?? bundleID)
                Task { @MainActor [weak self] in
                    self?.pendingLifecycleEvents.append(event)
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

    /// `everySecond`: the timer's tick (the rules' "tick" event goes out only
    /// then, not on an editor save's re-evaluation).
    private func tick(everySecond: Bool = true) {
        // Flush any throttled panel events (trailing edge).
        for (_, pending) in pendingPanelEvents {
            firePanelEvent(groupID: pending.groupID, data: pending.data)
        }
        pendingPanelEvents.removeAll()
        lastPanelFireAt.removeAll()

        let now = Date()
        let nowMs = (now.timeIntervalSince1970 * 1000).rounded() // whole ms, as every stored time
        // The tick's one read of the store.
        // A Mac group that left a link keeps only its own lines.
        webStore.keepOwnLines(groupIds: ConnectionHub.shared.takeUnlinkedLocalGroups())
        let document = webStore.loadForTick(nowMs: nowMs, linkedGroupIds: ConnectionHub.shared.linkedLocalGroupIds())
        // Mac Vault takes part in its links itself, editor window or not.
        ConnectionHub.shared.contributeLocalDefinitions(document: document, nowMs: nowMs)
        // …and adopts what the link shares into its own file.
        webStore.adoptShared()
        var view = BlockerWebStore.enforcementView(of: document)
        restartChangedBudgets(document: document, usage: &view.usage, nowMs: nowMs)
        let groups = view.groups
        let snoozes = view.snoozes
        let frontApp = NSWorkspace.shared.frontmostApplication
        activityRecorder?.sample(frontmost: frontApp, now: now)
        let observedFrontmost = frontApp?.bundleIdentifier
        let frontmost = BlockedProcesses.isBrowserBundleIdentifier(observedFrontmost) ? nil : observedFrontmost

        // 1. Reconcile reset windows + accrue time spent in the frontmost app.
        let elapsed = elapsedSinceLastSample(now: now)
        lastSampleAt = now
        // A blocked app still in front (shielded or suspended) is not time in
        // that app: no group counts it, as a covered browser page counts none.
        let ruleBlocked = ruleBlockedApps(groups: groups)
        let frontBlocked = frontmost.map { app in
            ruleBlocked.contains(app) || AppBlockPolicy.blocksApplication(
                app,
                groups: groups,
                usage: UsageSnapshot(
                    usageByGroupSeconds: view.usage.timersMs.mapValues { $0 / 1000 },
                    snoozesByGroup: snoozes
                ),
                now: now
            )
        } ?? false
        let timersMs = reconcileUsage(current: view.usage, groups: groups, frontmost: frontBlocked ? nil : frontmost, elapsed: elapsed, now: now, snoozes: snoozes)
        let usage = UsageSnapshot(
            usageByGroupSeconds: timersMs.mapValues { $0 / 1000 },
            snoozesByGroup: snoozes
        )

        // 2. The rules: what happened to apps since the last tick, then "tick".
        dispatchRuleEvents(groups: groups, frontApp: frontApp, everySecond: everySecond)

        // 3. Enforce: block apps whose group says "blocked now" plus the apps
        //    a rule blocked (one quit sweep).
        let quitRetry = view.quitRetryMinutes * 60
        Task { [adapter, ruleBlocked = ruleBlockedApps(groups: groups)] in
            try? await adapter.applyGroups(
                groups, usage: usage, now: now,
                customBlockedBundleIDs: ruleBlocked,
                quitRetry: quitRetry
            )
        }

        // 4. Render the HUD for any timer whose app is currently frontmost.
        //    A timed group shows while its time counts for the front app (a
        //    custom-rule group always, while it runs).
        let frontExempt = !GuardPolicy.canBlock(frontmost)
        let rows: [TimerOverlayRow] = groups.reversed().compactMap { group in
            guard group.isEnforcing(snoozes: usage.snoozesByGroup, at: now),
                  let remaining = group.remainingSeconds(usedSeconds: usage.usageByGroupSeconds[group.id] ?? 0,
                                                         extraSeconds: usage.snoozesByGroup[group.id]?.extraSeconds(at: now) ?? 0),
                  group.groupType == .custom || frontmost.map({ group.countsApplication($0, exempt: frontExempt) }) == true
            else { return nil }
            return TimerOverlayRow(id: group.id, name: group.name, remainingSeconds: remaining)
        }
        overlay.update(rows: rows)

    }

    // MARK: - Custom rules

    /// This tick's rule events: each app change since the last tick ("app"),
    /// then "tick". Rules load, reload and unload here as the groups change.
    private func dispatchRuleEvents(groups: [BlockGroup], frontApp: NSRunningApplication?, everySecond: Bool) {
        let lifecycleEvents = pendingLifecycleEvents
        pendingLifecycleEvents.removeAll()
        let frontmost = frontApp?.bundleIdentifier
        defer { lastFrontmost = frontmost }
        reconcileRules(groups: groups)
        guard !loadedRuleSources.isEmpty else { return }

        let listening = groups.filter { loadedRuleSources[$0.id] != nil }
        for event in lifecycleEvents {
            var data: [String: Any] = ["kind": event.kind.rawValue, "appId": event.bundleID, "name": event.name]
            if event.kind == .focus { data["previousAppId"] = lastFrontmost ?? NSNull() }
            for group in listening { dispatchRule(type: "app", data: data, group: group) }
        }
        let wantsTick = listening.filter { ruleTypes[$0.id]?.contains("tick") == true }
        guard everySecond, !wantsTick.isEmpty else { return }
        let tick: [String: Any] = [
            "frontmost": frontApp.map { ["appId": $0.bundleIdentifier ?? "", "name": $0.localizedName ?? ""] as [String: Any] } ?? NSNull(),
            "running": Self.runningApps()
        ]
        for group in wantsTick { dispatchRule(type: "tick", data: tick, group: group) }
    }

    /// Every running app (menu-bar and background ones included): an `.app`
    /// with a bundle id.
    private static func runningApps() -> [[String: Any]] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, app.bundleURL?.pathExtension == "app" else { return nil }
            return ["appId": id, "name": app.localizedName ?? id]
        }
    }

    /// One event to one group's rule (only if it handles that type), then what
    /// it asked for.
    private func dispatchRule(type: String, data: Any, group: BlockGroup) {
        guard group.enabled, ruleTypes[group.id]?.contains(type) == true, let runtime = ruleRuntime else { return }
        do {
            apply(try runtime.dispatch(type: type, data: data, groupID: group.id), group: group)
        } catch RuleRuntime.RuleRuntimeError.terminated {
            quarantineRule(group: group)
        } catch {
            NSLog("[Vault rule %@] %@: %@", group.id, type, String(describing: error))
        }
    }

    private func apply(_ result: RuleRuntime.DispatchResult, group: BlockGroup) {
        for diagnostic in result.diagnostics {
            NSLog("[Vault rule %@] %@", diagnostic.groupId, diagnostic.message)
        }
        for log in result.logs { appendLog(groupId: log.groupId, group: group.name, message: log.message) }
        for (groupID, panels) in result.panels { setPanels(panels, groupID: groupID) }
        if !result.states.isEmpty { webStore.writeRuleStates(result.states.mapValues { Optional($0) }) }
        for action in result.actions { perform(action) }
        if result.quarantine != nil { quarantineRule(group: group) }
    }

    /// A rule's action — apps only (the scope line).
    private func perform(_ action: RuleRuntime.Action) {
        switch action.kind {
        case "block":
            guard let app = action.appId, GuardPolicy.canBlock(app) else { return }
            if action.on == false {
                blockedAppBundleIDsByGroup[action.groupId]?.remove(app)
            } else {
                blockedAppBundleIDsByGroup[action.groupId, default: []].insert(app)
            }
        case "quit":
            // Asked to quit normally, like a block (QuitRequests: an app no
            // block can act on is left alone).
            if let app = action.appId { Task { [adapter] in await adapter.close(bundleIdentifier: app, now: Date()) } }
        case "open":
            if let app = action.appId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case "file":
            runRuleFile(action)
        default:
            break
        }
    }

    /// A rule's file request, in the folder the user chose (`LocalFolderGrant`,
    /// as the browser's "Choose folder"); its answer is the rule's "file" event.
    private func runRuleFile(_ action: RuleRuntime.Action) {
        let op = action.op ?? "", path = action.path ?? "", requestId = action.requestId ?? ""
        var answer: [String: String] = ["ok": "false", "error": "local-folder-not-available"]
        if let folder = LocalFolderGrant.resolvedFolderURL() {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            answer = LocalFileBroker(baseURL: folder).handle(action: op, path: path, text: action.payload, requestID: requestId)
        }
        let entries = answer["entriesJSON"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        let data: [String: Any] = [
            "requestId": requestId, "op": op, "path": path, "ok": answer["ok"] == "true",
            "text": answer["text"] ?? NSNull(), "entries": entries ?? NSNull(),
            "exists": answer["exists"].map { $0 == "true" } ?? NSNull(), "error": answer["error"] ?? ""
        ]
        dispatchRule(type: "file", data: data, groupID: action.groupId)
    }

    private func ensureRuntime() -> RuleRuntime? {
        if let runtime = ruleRuntime { return runtime }
        do {
            ruleRuntime = try RuleRuntime()
        } catch {
            NSLog("[Vault rule engine] %@", String(describing: error))
        }
        return ruleRuntime
    }

    /// Loads what each enabled custom group last Ran (its active source) and
    /// unloads the rules of groups that are gone, disabled or emptied.
    /// Loads what each custom group last Ran (its active source), unloads the
    /// rules of groups that are gone or emptied, and suppresses the rules of
    /// disabled groups (loaded, silent) — enabling one resumes it as it was.
    private func reconcileRules(groups: [BlockGroup]) {
        let wanted = Dictionary(uniqueKeysWithValues: groups
            .filter { $0.groupType == .custom && !$0.customRuleSource.isEmpty }
            .map { ($0.id, $0) })
        for groupID in Set(loadedRuleSources.keys).union(quarantinedRuleSources.keys) where wanted[groupID] == nil {
            unloadRule(groupID: groupID)
        }
        for (groupID, group) in wanted {
            if loadedRuleSources[groupID] != group.customRuleSource, quarantinedRuleSources[groupID] != group.customRuleSource {
                _ = loadRule(group: group, source: group.customRuleSource, stateJSON: webStore.ruleState(groupID: groupID))
            }
            if loadedRuleSources[groupID] != nil { setSuppressed(!group.enabled, groupID: groupID) }
        }
    }

    private func setSuppressed(_ on: Bool, groupID: String, force: Bool = false) {
        guard force || on != suppressedRules.contains(groupID) else { return }
        ruleRuntime?.suppress(groupID: groupID, on)
        if on { suppressedRules.insert(groupID) } else { suppressedRules.remove(groupID) }
        panelOverlay.update(panels: on ? [] : rulePanels[groupID] ?? [], forGroup: groupID)
    }

    private func setPanels(_ panels: [PanelSnapshot], groupID: String) {
        rulePanels[groupID] = panels
        if !suppressedRules.contains(groupID) { panelOverlay.update(panels: panels, forGroup: groupID) }
    }

    /// Registers a group's rule; one that doesn't load leaves the old one.
    private func loadRule(group: BlockGroup, source: String, stateJSON: String) -> RuleRuntime.LoadResult? {
        guard let runtime = ensureRuntime() else { return nil }
        do {
            let result = try runtime.load(groupID: group.id, source: source, stateJSON: stateJSON)
            for log in result.logs { appendLog(groupId: log.groupId, group: group.name, message: log.message) }
            guard result.ok else {
                NSLog("[Vault rule %@] %@", group.id, result.error ?? "The rule didn't load.")
                if result.quarantine != nil { quarantineRule(group: group) }
                return result
            }
            loadedRuleSources[group.id] = source
            quarantinedRuleSources.removeValue(forKey: group.id)
            ruleTypes[group.id] = Set(result.types)
            blockedAppBundleIDsByGroup.removeValue(forKey: group.id)
            setPanels(result.panels ?? [], groupID: group.id)
            // A fresh load isn't suppressed in the engine: say where it stands.
            setSuppressed(!group.enabled, groupID: group.id, force: true)
            return result
        } catch RuleRuntime.RuleRuntimeError.terminated {
            quarantineRule(group: group)
        } catch {
            NSLog("[Vault rule %@] load failed: %@", group.id, String(describing: error))
        }
        return nil
    }

    private func unloadRule(groupID: String) {
        ruleRuntime?.unload(groupID: groupID)
        loadedRuleSources.removeValue(forKey: groupID)
        quarantinedRuleSources.removeValue(forKey: groupID)
        ruleTypes.removeValue(forKey: groupID)
        suppressedRules.remove(groupID)
        rulePanels.removeValue(forKey: groupID)
        blockedAppBundleIDsByGroup.removeValue(forKey: groupID)
        panelOverlay.removePanels(forGroup: groupID)
    }

    /// Run (the editor's button and the AI tool): the text becomes the group's
    /// rule, keeping its memory (v.state, owner 2026-09-27). A rule that doesn't load
    /// changes nothing — the one before keeps running. A frozen group is refused.
    public func runRule(groupID: String, source: String) -> [String: Any] {
        let store = GroupStore()
        let document = store.load()
        guard document.group(id: groupID)?["groupType"] as? String == "custom",
              let group = webStore.importedGroups().first(where: { $0.id == groupID }) else {
            return ["ok": false, "error": "group-not-found"]
        }
        if document.isLocked(id: groupID) { return ["ok": false, "error": "group-locked"] }
        // Run enables the group (as the editor does).
        var running = group
        running.enabled = true
        guard let result = loadRule(group: running, source: source, stateJSON: webStore.ruleState(groupID: groupID)) else {
            return ["ok": false, "error": quarantinedRuleSources[groupID] != nil ? "sandbox-timeout" : "rules-not-running"]
        }
        if result.ok { _ = try? store.mutate { try $0.recordRun(id: groupID, source: source) } }
        return ["ok": result.ok, "handlers": result.handlers, "error": result.error ?? NSNull()]
    }

    /// A rule that ran past its time is stopped until it is Run again.
    private func quarantineRule(group: BlockGroup) {
        let source = loadedRuleSources[group.id] ?? group.customRuleSource
        unloadRule(groupID: group.id)
        quarantinedRuleSources[group.id] = source
        NSLog("[Vault rule %@] stopped: execution deadline exceeded", group.id)
    }

    public func clearRuleLog(groupID: String) {
        ruleLog.removeAll { $0.groupId == groupID }
    }

    private func appendLog(groupId: String, group: String, message: String) {
        guard !groupId.isEmpty else { return }
        let entry = RuleLogEntry(timestamp: Date(), level: "log", groupId: groupId, group: group, message: message)
        ruleLog.append(entry)
        if ruleLog.filter({ $0.groupId == groupId }).count > 200,
           let oldest = ruleLog.firstIndex(where: { $0.groupId == groupId }) {
            ruleLog.remove(at: oldest)
        }
    }

    // MARK: - Helpers

    /// Each group's budget fields as last seen, to spot an edit that changes
    /// how its budget runs.
    private var budgetFieldsSeen: [String: [String: Any]] = [:]

    /// An edit that changes how a group's budget runs restarts it, whoever
    /// made it — the editor's own rule (group-actions.js budgetRestarts), as
    /// the browser's worker applies it.
    private func restartChangedBudgets(document: [String: Any], usage: inout BlockerWebStore.UsageTimers, nowMs: Double) {
        let fields = ["groupType", "mode", "resetIntervalHours", "resetAtMidnight", "rollingLimit"]
        var restarted: [String] = []
        var seen: [String: [String: Any]] = [:]
        for group in document["blockedGroups"] as? [[String: Any]] ?? [] {
            guard let id = group["id"] as? String else { continue }
            let shape = fields.reduce(into: [String: Any]()) { $0[$1] = group[$1] ?? NSNull() }
            seen[id] = shape
            if let previous = budgetFieldsSeen[id],
               WebStoreDocument.canonicalJSON(previous) != WebStoreDocument.canonicalJSON(shape),
               GroupActionsRuntime.shared.call("budgetRestarts", [previous, shape]) as? Bool == true {
                restarted.append(id)
            }
        }
        budgetFieldsSeen = seen
        guard !restarted.isEmpty else { return }
        var timers: [String: Double] = [:], resets: [String: Double] = [:], buckets: [String: [Double: Double]] = [:]
        for id in restarted {
            timers[id] = 0; resets[id] = nowMs; buckets[id] = [:]
            usage.timersMs[id] = 0; usage.resetAtMs[id] = nowMs; usage.bucketsMs[id] = [:]
        }
        webStore.writeUsage(timersMs: timers, resetAtMs: resets, bucketsMs: buckets)
    }

    private func elapsedSinceLastSample(now: Date) -> TimeInterval {
        guard let lastSampleAt else { return 0 }
        return min(max(0, now.timeIntervalSince(lastSampleAt)), tickInterval * 4)
    }

    private func reconcileUsage(
        current: BlockerWebStore.UsageTimers,
        groups: [BlockGroup],
        frontmost: String?,
        elapsed: TimeInterval,
        now: Date,
        snoozes: [String: SnoozeState] = [:]
    ) -> [String: Double] {
        var timers = current.timersMs
        var resetAt = current.resetAtMs
        let nowMs = now.timeIntervalSince1970 * 1000

        var timerWrites: [String: Double] = [:]
        var resetWrites: [String: Double] = [:]
        var bucketWrites: [String: [Double: Double]] = [:]
        // What running budget snoozes gave this tick, counted as it is used
        // (group-actions.js snoozeGivenMs): the part above the plain allowance.
        var snoozeGiven: [String: Double] = [:]

        for group in groups where group.enabled {
            guard group.mode.isTimed else { continue }
            let gid = group.id

            var addedMs: Double = 0
            // A snoozed group spends nothing, as in the extension.
            if let frontmost, elapsed > 0, group.isEnforcing(snoozes: snoozes, at: now),
               group.countsApplication(frontmost, exempt: !GuardPolicy.canBlock(frontmost)) {
                // Time counts up to the allowance (a running budget snooze's
                // extra included), as in the extension.
                let allowedMs = max(0, group.allowedMinutes) * 60_000
                    + (snoozes[gid]?.extraSeconds(at: now) ?? 0) * 1000
                addedMs = min(elapsed * 1000, max(0, allowedMs - (timers[gid] ?? 0)))
                if (snoozes[gid]?.extraSeconds(at: now) ?? 0) > 0 {
                    let before = timers[gid] ?? 0
                    let given = before + addedMs - max(before, max(0, group.allowedMinutes) * 60_000)
                    if given > 0 { snoozeGiven[gid] = given }
                }
            }

            if group.rollingLimit {
                // Rolling limit: time is kept per minute and counts until it is
                // resetIntervalHours old (or cleared at midnight); the timer holds
                // the in-window total so the block decision + display stay as-is.
                let stored = current.bucketsMs[gid] ?? [:]
                var buckets = stored
                if addedMs > 0 {
                    buckets[UsageBudget.bucketStartMs(nowMs), default: 0] += addedMs
                }
                if let shared = ConnectionHub.shared.sharedUsage(groupID: gid) {
                    // Linked group: report this tick's minute (or seed our history
                    // once), then adopt the hub's shared per-minute usage.
                    if clusterSeededGroups.contains(gid) {
                        if addedMs > 0 {
                            ConnectionHub.shared.reportLocalUsage(
                                groupID: gid, deltaMs: 0, resetAtMs: 0,
                                bucketDeltas: [UsageBudget.bucketStartMs(nowMs): addedMs]
                            )
                        }
                    } else {
                        ConnectionHub.shared.reportLocalUsage(
                            groupID: gid, deltaMs: 0, resetAtMs: 0, seedBuckets: buckets
                        )
                        clusterSeededGroups.insert(gid)
                    }
                    buckets = ConnectionHub.shared.sharedUsage(groupID: gid)?.buckets ?? shared.buckets
                } else {
                    clusterSeededGroups.remove(gid)
                }
                buckets = UsageBudget.pruneBuckets(buckets, group: group, nowMs: nowMs)
                if buckets != stored { bucketWrites[gid] = buckets }
                let used = UsageBudget.usedMs(buckets)
                if timers[gid] != used {
                    timers[gid] = used
                    timerWrites[gid] = used
                }
                continue
            }

            // Fixed budget: resets every resetIntervalHours from the anchor, or
            // on the midnight-aligned grid when resetAtMidnight is on. A linked
            // group's period belongs to the hub: it resets there, and we adopt
            // its total and anchor below instead of resetting on our own clock.
            let linked = ConnectionHub.shared.sharedUsage(groupID: gid) != nil
            var anchor = resetAt[gid] ?? nowMs
            if resetAt[gid] == nil {
                resetAt[gid] = nowMs
                resetWrites[gid] = nowMs
            }
            let periodStart = UsageBudget.periodStartMs(anchorMs: anchor, group: group, nowMs: nowMs)
            if !linked, periodStart != anchor {
                timers[gid] = 0
                resetAt[gid] = periodStart
                timerWrites[gid] = 0
                resetWrites[gid] = periodStart
                anchor = periodStart
            }
            if addedMs > 0 {
                timers[gid, default: 0] += addedMs
                timerWrites[gid] = timers[gid]
            }

            // Linked group: ONE live budget, kept by the hub. Report this tick's
            // increment (our anchor only seeds the hub's period when it has
            // none) and fold the hub's total + anchor back into the local timer,
            // so enforcement reflects time spent on every member.
            if linked {
                if clusterSeededGroups.contains(gid) {
                    ConnectionHub.shared.reportLocalUsage(
                        groupID: gid,
                        deltaMs: addedMs,
                        resetAtMs: anchor
                    )
                } else {
                    // First report since joining: seed our current local total
                    // (which already includes this tick's accrual) with no delta,
                    // so prior Mac usage is preserved on the shared budget.
                    ConnectionHub.shared.reportLocalUsage(
                        groupID: gid,
                        deltaMs: 0,
                        resetAtMs: anchor,
                        seedMs: timers[gid] ?? 0
                    )
                    clusterSeededGroups.insert(gid)
                }
                if let shared = ConnectionHub.shared.sharedUsage(groupID: gid) {
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

        webStore.writeUsage(timersMs: timerWrites, resetAtMs: resetWrites, bucketsMs: bucketWrites, snoozeGivenMs: snoozeGiven)
        return timers
    }

    #endif
}

/// A single entry in the custom-rule log.
public struct RuleLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let level: String
    public let groupId: String
    public let group: String
    public let message: String
}
