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
}

/// The result of dispatching a custom rule event: decisions for enforcement
/// plus intents for side-effects (close tab, block site, etc).
public struct DispatchResult: Sendable {
    public var decisions: [PolicyDecision]
    public var intents: [WindowIntent]

    public init(decisions: [PolicyDecision] = [], intents: [WindowIntent] = []) {
        self.decisions = decisions
        self.intents = intents
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
        return DispatchResult(decisions: envelope.decisions, intents: envelope.intents ?? [])
        #else
        throw CustomJavaScriptPolicyRuntimeError.javaScriptCoreUnavailable
        #endif
    }

    private struct DispatchEnvelope: Codable {
        var decisions: [PolicyDecision]
        var intents: [WindowIntent]?
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
                ev.block = function(reason) {
                  ev.__decisions.push({
                    action: "shield",
                    groupID: ev.groupID,
                    targetIDs: ev.target && ev.target.id ? [ev.target.id] : [],
                    reason: String(reason || "Blocked by custom rule."),
                    shieldMessage: String(reason || "Blocked by custom rule."),
                    overlayStatus: {
                      title: "Blocked",
                      message: String(reason || "Blocked by custom rule."),
                      timerGroupID: ev.groupID,
                      expiresAt: null
                    },
                    metadata: {}
                  });
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
                  rule(eventRegistry(groupId), {});
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
                  return JSON.stringify(event.__decisions);
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
        guard let url = Bundle.module.url(
            forResource: "custom-rule-runtime",
            withExtension: "js",
            subdirectory: "Resources"
        ) ?? Bundle.module.url(forResource: "custom-rule-runtime", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
    #endif
}
