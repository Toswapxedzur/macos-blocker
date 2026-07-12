import Foundation

#if canImport(JavaScriptCore)
@preconcurrency import JavaScriptCore
#endif

public struct CustomRuleEvent: Codable, Equatable, Sendable {
    public var type: String
    public var groupID: String
    public var target: BlockTarget?
    public var now: Date
    public var url: String
    public var hostname: String
    public var data: [String: String]

    public init(
        type: String,
        groupID: String,
        target: BlockTarget? = nil,
        now: Date = Date(),
        url: String = "",
        hostname: String = "",
        data: [String: String] = [:]
    ) {
        self.type = type
        self.groupID = groupID
        self.target = target
        self.now = now
        self.url = url
        self.hostname = hostname
        self.data = data
    }
}

public enum CustomJavaScriptPolicyRuntimeError: Error, Equatable {
    case javaScriptCoreUnavailable
    case compileFailed(String)
    case dispatchFailed(String)
    case invalidResult
}

/// An intent emitted by a custom rule's helper (e.g. getWindowHelper().close()).
public struct WindowIntent: Codable, Equatable, Sendable {
    public var kind: String
    public var action: String
    public var target: String?
    public var pattern: String?
    public var browserBundleID: String?
    public var windowIndex: Int?
    public var tabIndex: Int?
    public var path: String?
    public var text: String?
    public var groupId: String?
    public var requestId: String?
}

/// A timer snapshot emitted by dispatch, filtered by scope vs. the focused app.
public struct CustomTimerSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var groupId: String
    public var displayName: String
    public var direction: String
    public var currentMs: Double
    public var isPaused: Bool
}

/// A panel control option (select/radio).
public struct PanelControlOption: Codable, Equatable, Sendable {
    public var value: String
    public var label: String
}

/// A single control in a panel snapshot.
public struct PanelControlSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var label: String?
    public var text: String?
    public var value: AnyCodableValue?
    public var disabled: Bool?
    public var placeholder: String?
    public var options: [PanelControlOption]?
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var action: String?
    public var timerId: String?
    public var timer: CustomTimerSnapshot?
    public var format: String?
    public var showExpired: Bool?
    public var controls: [PanelControlSnapshot]?
    public var layout: String?
    public var align: String?
    public var priority: Int?
    public var role: String?
    public var autoFocus: Bool?
    public var rows: Int?
    public var width: String?
    public var height: String?
    public var length: Int?
    public var masked: Bool?
    public var autoSubmit: Bool?
}

/// Theme customization for a panel.
public struct PanelTheme: Codable, Equatable, Sendable {
    public var background: String?
    public var foreground: String?
    public var accent: String?
    public var border: String?
    public var muted: String?
    public var fontSize: String?
    public var titleSize: String?
}

/// A complete panel snapshot emitted by dispatch for rendering.
public struct PanelSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var groupId: String?
    public var title: String?
    public var description: String?
    public var position: String?
    public var align: String?
    public var layout: String?
    public var priority: Int?
    public var width: String?
    public var textSize: String?
    public var role: String?
    public var autoFocus: Bool?
    public var theme: PanelTheme?
    public var controls: [PanelControlSnapshot]?
    public var visible: Bool?
    public var values: [String: AnyCodableValue]?
}

/// Type-erased JSON value for panel control values (Bool, String, Double, etc).
public enum AnyCodableValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .null: return ""
        }
    }

    public var boolValue: Bool {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return s == "true"
        case .null: return false
        }
    }

    public var doubleValue: Double {
        switch self {
        case .bool(let b): return b ? 1 : 0
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s) ?? 0
        case .null: return 0
        }
    }
}

/// The result of dispatching a custom rule event: decisions for enforcement
/// plus intents for side-effects (close tab, block site, etc).
public struct DispatchResult: Sendable {
    public var decisions: [PolicyDecision]
    public var intents: [WindowIntent]
    public var timers: [CustomTimerSnapshot]
    public var panels: [PanelSnapshot]

    public init(decisions: [PolicyDecision] = [], intents: [WindowIntent] = [], timers: [CustomTimerSnapshot] = [], panels: [PanelSnapshot] = []) {
        self.decisions = decisions
        self.intents = intents
        self.timers = timers
        self.panels = panels
    }
}

/// Result of loading a custom rule: handler count + any log decisions
/// emitted during registration.
public struct LoadResult: Sendable {
    public var handlers: Int
    public var decisions: [PolicyDecision]

    public init(handlers: Int = 0, decisions: [PolicyDecision] = []) {
        self.handlers = handlers
        self.decisions = decisions
    }
}

public protocol CustomPolicyRuntime {
    @discardableResult
    func load(groupID: String, source: String) throws -> LoadResult
    func unload(groupID: String)
    func dispatch(_ event: CustomRuleEvent) throws -> DispatchResult
}

public final class CustomJavaScriptPolicyRuntime: CustomPolicyRuntime {
    #if canImport(JavaScriptCore)
    private let context: JSContext
    #endif

    public init() throws {
        #if canImport(JavaScriptCore)
        guard let context = JSContext() else {
            throw CustomJavaScriptPolicyRuntimeError.javaScriptCoreUnavailable
        }
        self.context = context
        installBootstrap()
        #else
        throw CustomJavaScriptPolicyRuntimeError.javaScriptCoreUnavailable
        #endif
    }

    @discardableResult
    public func load(groupID: String, source: String) throws -> LoadResult {
        #if canImport(JavaScriptCore)
        let groupLiteral = try Self.javaScriptStringLiteral(groupID)
        let sourceLiteral = try Self.javaScriptStringLiteral(source)
        let script = """
        MacBlockerRuntime.load(\(groupLiteral), \(sourceLiteral));
        """
        guard let value = context.evaluateScript(script) else {
            throw CustomJavaScriptPolicyRuntimeError.compileFailed("Script evaluation returned no value.")
        }
        if let exception = context.exception {
            context.exception = nil
            throw CustomJavaScriptPolicyRuntimeError.compileFailed(exception.toString())
        }
        guard let json = value.toString(), let data = json.data(using: .utf8) else {
            return LoadResult()
        }
        let envelope = try JSONDecoder().decode(LoadEnvelope.self, from: data)
        return LoadResult(handlers: envelope.handlers, decisions: envelope.decisions ?? [])
        #else
        throw CustomJavaScriptPolicyRuntimeError.javaScriptCoreUnavailable
        #endif
    }

    private struct LoadEnvelope: Codable {
        var handlers: Int
        var decisions: [PolicyDecision]?
    }

    public func unload(groupID: String) {
        #if canImport(JavaScriptCore)
        guard let literal = try? Self.javaScriptStringLiteral(groupID) else {
            return
        }
        context.evaluateScript("MacBlockerRuntime.unload(\(literal));")
        context.exception = nil
        #endif
    }

    public func dispatch(_ event: CustomRuleEvent) throws -> DispatchResult {
        #if canImport(JavaScriptCore)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let eventData = try encoder.encode(event)
        guard let eventJSON = String(data: eventData, encoding: .utf8) else {
            throw CustomJavaScriptPolicyRuntimeError.dispatchFailed("Could not encode event.")
        }
        let eventLiteral = try Self.javaScriptStringLiteral(eventJSON)
        let script = "MacBlockerRuntime.dispatch(JSON.parse(\(eventLiteral)));"
        guard let value = context.evaluateScript(script) else {
            throw CustomJavaScriptPolicyRuntimeError.invalidResult
        }
        if let exception = context.exception {
            context.exception = nil
            throw CustomJavaScriptPolicyRuntimeError.dispatchFailed(exception.toString())
        }
        guard let resultJSON = value.toString(),
              let data = resultJSON.data(using: .utf8)
        else {
            throw CustomJavaScriptPolicyRuntimeError.invalidResult
        }
        let envelope = try JSONDecoder().decode(DispatchEnvelope.self, from: data)
        return DispatchResult(decisions: envelope.decisions, intents: envelope.intents ?? [], timers: envelope.timers ?? [], panels: envelope.panels ?? [])
        #else
        throw CustomJavaScriptPolicyRuntimeError.javaScriptCoreUnavailable
        #endif
    }

    private struct DispatchEnvelope: Codable {
        var decisions: [PolicyDecision]
        var intents: [WindowIntent]?
        var timers: [CustomTimerSnapshot]?
        var panels: [PanelSnapshot]?
    }

    #if canImport(JavaScriptCore)
    private func installBootstrap() {
        context.exceptionHandler = { _, exception in
            print("MacBlocker JS exception: \(exception?.toString() ?? "unknown")")
        }

        if let bundled = Self.bundledRuntimeSource() {
            context.evaluateScript(bundled)
            if context.objectForKeyedSubscript("MacBlockerRuntime") != nil,
               context.exception == nil {
                return
            }
            context.exception = nil
        }

        // Fallback minimal engine (used only if the bundled JS can't be found).
        context.evaluateScript(
            """
            const MacBlockerRuntime = (() => {
              const handlersByGroup = new Map();

              function ensureGroup(groupId) {
                if (!handlersByGroup.has(groupId)) handlersByGroup.set(groupId, []);
                return handlersByGroup.get(groupId);
              }

              function register(groupId, type, id, handler, options) {
                if (typeof type !== "string" || !type) return false;
                if (typeof id !== "string" || !id) return false;
                if (typeof handler !== "function") return false;
                const list = ensureGroup(groupId);
                const entry = {
                  groupId,
                  type,
                  id,
                  handler,
                  priority: Number(options && options.priority) || 0,
                  registeredAt: Date.now()
                };
                const existing = list.findIndex((item) => item.type === type && item.id === id);
                if (existing >= 0) list[existing] = entry;
                else list.push(entry);
                list.sort((a, b) => b.priority - a.priority || a.registeredAt - b.registeredAt);
                return true;
              }

              function eventRegistry(groupId) {
                return {
                  register(type, id, handler, options) {
                    return register(groupId, type, id, handler, options || {});
                  },
                  registerUsageThresholdReached(id, handler, options) {
                    return register(groupId, "usageThresholdReached", id, handler, options || {});
                  },
                  registerScheduleChanged(id, handler, options) {
                    return register(groupId, "scheduleChanged", id, handler, options || {});
                  },
                  registerShieldAction(id, handler, options) {
                    return register(groupId, "shieldAction", id, handler, options || {});
                  },
                  registerSnoozePress(id, handler, options) {
                    return register(groupId, "snoozePress", id, handler, options || {});
                  },
                  registerTimerEnded(id, handler, options) {
                    return register(groupId, "timerEnded", id, handler, options || {});
                  }
                };
              }

              function helpersFor(ev) {
                return {
                  now: ev.now,
                  groupId: ev.groupID,
                  target: {
                    hasTag(target, tag) {
                      const tags = target && target.tags;
                      return Array.isArray(tags) && tags.includes(tag);
                    }
                  },
                  time: {
                    hour() {
                      return new Date(ev.now).getHours();
                    },
                    isWeekday() {
                      const day = new Date(ev.now).getDay();
                      return day >= 1 && day <= 5;
                    }
                  },
                  log(message) {
                    ev.__decisions.push({
                      action: "log",
                      groupID: ev.groupID,
                      targetIDs: [],
                      reason: String(message || ""),
                      shieldMessage: "",
                      overlayStatus: null,
                      metadata: {}
                    });
                  },
                  overlay: {
                    show(status) {
                      const safe = status || {};
                      ev.__decisions.push({
                        action: "showStatus",
                        groupID: ev.groupID,
                        targetIDs: ev.target && ev.target.id ? [ev.target.id] : [],
                        reason: String(safe.message || ""),
                        shieldMessage: "",
                        overlayStatus: {
                          title: String(safe.title || "Blocker Status"),
                          message: String(safe.message || ""),
                          timerGroupID: String(safe.timerId || ev.groupID),
                          expiresAt: null
                        },
                        metadata: {}
                      });
                    }
                  }
                };
              }

              function hostEvent(rawEvent) {
                const ev = Object.assign({}, rawEvent);
                ev.__decisions = [];
                ev.__intents = [];
                const focusedAppId = rawEvent.data && rawEvent.data.isBrowser === "true"
                  ? ""
                  : (rawEvent.data && rawEvent.data.appId) || "";
                ev.close = function(id) {
                  if (typeof id === "string" && id) {
                    ev.__intents.push({ kind: "window", action: "close", target: id });
                  } else if (focusedAppId) {
                    ev.__intents.push({ kind: "window", action: "close", target: focusedAppId });
                  }
                };
                ev.block = function(id) {
                  const appId = typeof id === "string" && id ? id : focusedAppId;
                  if (!appId) return;
                  ev.__intents.push({ kind: "window", action: "blockApp", target: appId });
                };
                ev.unblock = function(id) {
                  const appId = typeof id === "string" && id ? id : focusedAppId;
                  if (!appId) return;
                  ev.__intents.push({ kind: "window", action: "unblockApp", target: appId });
                };
                ev.open = function(id) {
                  if (typeof id !== "string" || !id) return;
                  ev.__intents.push({ kind: "window", action: "openApp", target: id });
                };
                ev.allow = function(reason) {
                  ev.__decisions.push({
                    action: "allow",
                    groupID: ev.groupID,
                    targetIDs: ev.target && ev.target.id ? [ev.target.id] : [],
                    reason: String(reason || ""),
                    shieldMessage: "",
                    overlayStatus: null,
                    metadata: {}
                  });
                };
                ev.setShieldMessage = function(message) {
                  const last = ev.__decisions[ev.__decisions.length - 1];
                  if (last) last.shieldMessage = String(message || "");
                };
                return ev;
              }

              return {
                load(groupId, source) {
                  handlersByGroup.set(groupId, []);
                  const factory = Function('"use strict"; return (' + source + ');');
                  const rule = factory();
                  if (typeof rule !== "function") throw new Error("Custom rule must evaluate to a function.");
                  const loadEvent = hostEvent({ type: "_register", groupID: groupId, now: new Date().toISOString(), data: {} });
                  rule(eventRegistry(groupId), helpersFor(loadEvent));
                  const list = handlersByGroup.get(groupId) || [];
                  return JSON.stringify({ handlers: list.length, decisions: loadEvent.__decisions });
                },
                unload(groupId) {
                  handlersByGroup.delete(groupId);
                },
                dispatch(rawEvent) {
                  const list = handlersByGroup.get(rawEvent.groupID) || [];
                  const event = hostEvent(rawEvent);
                  const helpers = helpersFor(event);
                  for (const entry of list) {
                    if (entry.type !== rawEvent.type) continue;
                    entry.handler(event, helpers);
                  }
                  return JSON.stringify({ decisions: event.__decisions, intents: event.__intents });
                }
              };
            })();
            """
        )
    }

    private static func javaScriptStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw CustomJavaScriptPolicyRuntimeError.invalidResult
        }
        return literal
    }

    private static func bundledRuntimeSource() -> String? {
        guard let url = bundledResourceURL(name: "custom-rule-runtime", ext: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func bundledResourceURL(name: String, ext: String) -> URL? {
        let bundleName = "macosBlocker_MacBlockerCore.bundle"
        for baseURL in runtimeResourceBaseURLs() {
            let bundleURL = baseURL.appendingPathComponent(bundleName, isDirectory: true)
            let nested = bundleURL
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("\(name).\(ext)", isDirectory: false)
            if FileManager.default.fileExists(atPath: nested.path) {
                return nested
            }
            let flat = bundleURL.appendingPathComponent("\(name).\(ext)", isDirectory: false)
            if FileManager.default.fileExists(atPath: flat.path) {
                return flat
            }
        }
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: ext)
    }

    private static func runtimeResourceBaseURLs() -> [URL] {
        var urls: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL)
        }
        urls.append(Bundle.main.bundleURL)
        if let executableURL = Bundle.main.executableURL {
            urls.append(executableURL.deletingLastPathComponent())
        }
        return urls
    }
    #endif
}
