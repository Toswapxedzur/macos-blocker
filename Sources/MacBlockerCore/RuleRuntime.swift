import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if canImport(JavaScriptCore)
@preconcurrency import JavaScriptCore
#endif

/// Mac Vault's custom-rule engine: `rule-core.js` (the rule contract the
/// browser runs too) with `custom-rule-runtime.js` (Mac Vault's own actions:
/// apps only) in JavaScriptCore. A rule's handler that runs past its time is
/// cut off by JSC's execution limit (`RuleRuntimeError.terminated`).
public final class RuleRuntime {
    public enum RuleRuntimeError: Error, Equatable {
        case javaScriptCoreUnavailable
        case executionDeadlineUnavailable
        case resourcesMissing(String)
        /// The rule ran past its time and was cut off.
        case terminated
        case failed(String)
    }

    /// What loading a rule answered.
    public struct LoadResult: Decodable, Equatable, Sendable {
        public var ok: Bool
        public var handlers: Int
        public var types: [String]
        public var error: String?
        public var logs: [Log]
        /// The panels the rule showed while registering (replacing the old ones).
        public var panels: [PanelSnapshot]?
        public var quarantine: Quarantine?
    }

    /// One `v.log` line, or a separate developer diagnostic.
    public struct Log: Decodable, Equatable, Sendable {
        public var groupId: String
        public var level: String
        public var message: String
    }

    public struct Quarantine: Decodable, Equatable, Sendable {
        public var groupId: String
        public var reason: String
    }

    /// One action a rule asked for: `block` (appId, on), `quit` / `open`
    /// (appId), or `file` (op, path, payload, requestId).
    public struct Action: Decodable, Equatable, Sendable {
        public var groupId: String
        public var kind: String
        public var appId: String?
        public var on: Bool?
        public var op: String?
        public var path: String?
        public var payload: String?
        public var requestId: String?
    }

    /// What one event made the rules do: actions, logs, the groups whose
    /// panels changed, the states that changed (JSON text) and a quarantine.
    public struct DispatchResult: Decodable, Equatable, Sendable {
        public var actions: [Action]
        public var diagnostics: [Log] = []
        public var logs: [Log]
        public var panels: [String: [PanelSnapshot]]
        public var states: [String: String]
        public var quarantine: Quarantine?
    }

    #if canImport(JavaScriptCore)
    private let context: JSContext
    /// The contract's handler time (rule-core.js LIMITS.handlerMs) plus a margin.
    private static let executionTimeLimitSeconds: Double = 1.2

    private typealias ExecutionTimeLimitCallback = @convention(c) (
        OpaquePointer?, UnsafeMutableRawPointer?
    ) -> Bool
    private typealias SetExecutionTimeLimit = @convention(c) (
        OpaquePointer?, Double, ExecutionTimeLimitCallback?, UnsafeMutableRawPointer?
    ) -> Void
    private typealias ClearExecutionTimeLimit = @convention(c) (OpaquePointer?) -> Void

    private static let setExecutionTimeLimit: SetExecutionTimeLimit? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetExecutionTimeLimit.self)
    }()
    private static let clearExecutionTimeLimit: ClearExecutionTimeLimit? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "JSContextGroupClearExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: ClearExecutionTimeLimit.self)
    }()
    #endif

    public init() throws {
        #if canImport(JavaScriptCore)
        guard let context = JSContext() else { throw RuleRuntimeError.javaScriptCoreUnavailable }
        // Fail closed: user code without a preemptive deadline could hang the app.
        guard Self.setExecutionTimeLimit != nil, Self.clearExecutionTimeLimit != nil else {
            throw RuleRuntimeError.executionDeadlineUnavailable
        }
        self.context = context
        for name in ["rule-core", "custom-rule-runtime"] {
            guard let url = RuntimeResources.url(name: name, ext: "js"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw RuleRuntimeError.resourcesMissing("\(name).js")
            }
            context.evaluateScript(source)
            if let exception = context.exception {
                context.exception = nil
                throw RuleRuntimeError.failed("\(name).js: \(exception.toString() ?? "")")
            }
        }
        #else
        throw RuleRuntimeError.javaScriptCoreUnavailable
        #endif
    }

    /// Registers a group's rule; one that fails to load leaves the group's old
    /// rule running (`ok` false with its error).
    public func load(groupID: String, source: String, stateJSON: String) throws -> LoadResult {
        try call("MacBlockerRuntime.load(\(literal(groupID)), \(literal(source)), \(literal(stateJSON)))")
    }

    /// A disabled group's rule stays loaded but hears nothing until resumed.
    public func suppress(groupID: String, _ on: Bool) {
        #if canImport(JavaScriptCore)
        context.evaluateScript("MacBlockerRuntime.suppress(\(literal(groupID)), \(on));")
        context.exception = nil
        #endif
    }

    public func unload(groupID: String) {
        #if canImport(JavaScriptCore)
        context.evaluateScript("MacBlockerRuntime.unload(\(literal(groupID)));")
        context.exception = nil
        #endif
    }

    /// One event (`type`, `data`) to one group's rule.
    public func dispatch(type: String, data: Any, groupID: String, now: Date = Date()) throws -> DispatchResult {
        let descriptor: [String: Any] = [
            "type": type, "now": (now.timeIntervalSince1970 * 1000).rounded(), "data": data, "targetGroupId": groupID
        ]
        guard JSONSerialization.isValidJSONObject(descriptor),
              let json = String(data: try JSONSerialization.data(withJSONObject: descriptor), encoding: .utf8) else {
            throw RuleRuntimeError.failed("the event is not JSON")
        }
        return try call("MacBlockerRuntime.dispatch(\(literal(json)))")
    }

    private func call<T: Decodable>(_ script: String) throws -> T {
        #if canImport(JavaScriptCore)
        guard let setLimit = Self.setExecutionTimeLimit, let clearLimit = Self.clearExecutionTimeLimit else {
            throw RuleRuntimeError.executionDeadlineUnavailable
        }
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        let shouldTerminate: ExecutionTimeLimitCallback = { _, _ in true }
        setLimit(group, Self.executionTimeLimitSeconds, shouldTerminate, nil)
        let value = context.evaluateScript(script)
        clearLimit(group)
        if let exception = context.exception {
            context.exception = nil
            let text = exception.toString() ?? ""
            if text.localizedCaseInsensitiveContains("execution terminated") { throw RuleRuntimeError.terminated }
            throw RuleRuntimeError.failed(text)
        }
        guard let json = value?.toString(), let data = json.data(using: .utf8) else {
            throw RuleRuntimeError.failed("no answer")
        }
        return try JSONDecoder().decode(T.self, from: data)
        #else
        throw RuleRuntimeError.javaScriptCoreUnavailable
        #endif
    }

    private func literal(_ value: String) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

/// Where the core's bundled JavaScript lives (the app bundle, or the
/// SwiftPM resource bundle next to the executable).
enum RuntimeResources {
    static func url(name: String, ext: String) -> URL? {
        let bundleName = "macosBlocker_MacBlockerCore.bundle"
        var bases: [URL] = []
        if let resourceURL = Bundle.main.resourceURL { bases.append(resourceURL) }
        bases.append(Bundle.main.bundleURL)
        if let executableURL = Bundle.main.executableURL { bases.append(executableURL.deletingLastPathComponent()) }
        for base in bases {
            let bundleURL = base.appendingPathComponent(bundleName, isDirectory: true)
            for candidate in [bundleURL.appendingPathComponent("Resources/\(name).\(ext)"), bundleURL.appendingPathComponent("\(name).\(ext)")]
            where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: ext)
    }
}

// MARK: - Panels (v.panel), as rule-core.js sanitizes them

/// A panel control option (select/radio).
public struct PanelControlOption: Codable, Equatable, Sendable {
    public var value: String
    public var label: String
}

/// A single control in a panel.
public struct PanelControlSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var label: String?
    public var text: String?
    public var html: String?
    public var value: AnyCodableValue?
    public var disabled: Bool?
    public var placeholder: String?
    public var options: [PanelControlOption]?
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var action: String?
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

/// A panel as a rule shows it.
public struct PanelSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var groupId: String?
    /// A rule owns its panel IDs. The native renderer combines the owner and
    /// local ID so another group's same-named panel retains independent input.
    public var presentationIdentity: [String] { [groupId ?? "", id] }
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
