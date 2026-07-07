import Foundation

#if canImport(JavaScriptCore)
@preconcurrency import JavaScriptCore
#endif

/// Native host for the Safari extension's custom-rule engine.
///
/// On Chromium/Firefox the custom-rule engine (`event-sandbox.js`) runs in a
/// browser sandbox iframe. Safari has no `chrome.offscreen`, and its support
/// for the eval-relaxing manifest `sandbox` key is unreliable, so the Safari
/// extension is built as a *thin client*: it forwards each
/// `event-sandbox-request` to the macosBlocker app over native messaging, and
/// this bridge runs the **verbatim, intent-emitting** `event-sandbox.js` in
/// JavaScriptCore (which has no CSP, so `new Function` just works) and returns
/// the same `{ ok, result }` shape the in-browser sandbox produces.
///
/// This is the macOS counterpart of `offscreen.js`: it installs a tiny
/// `window` / `postMessage` shim, performs the same ready/init handshake, and
/// answers the same payload kinds (`load-source`, `check-source`,
/// `unload-group`, `list-handlers`, `evaluate-platform-items`,
/// `dispatch-event`/`post-event`). DOM/redirect intents are returned inside
/// the result and applied by the extension's content script, exactly as on
/// Chromium.
///
/// State (registered handlers, timers, persistence) lives in this JSContext,
/// which the SafariWebExtensionHandler keeps alive for the lifetime of its
/// process — and which can be rehydrated from the App Group on cold start.
public final class SafariCustomRuleBridge {

    public enum BridgeError: Error, Equatable {
        case javaScriptCoreUnavailable
        case resourcesMissing(String)
        case engineNotReady
        case dispatchFailed(String)
        case timeout
    }

    #if canImport(JavaScriptCore)
    private let context: JSContext
    private var ready = false
    private var nextRequestId = 1
    private var pendingReplyJSON: String?
    private var pendingReplyId: Int = -1
    /// Async intent / log pushes the engine emits outside a request/reply.
    /// Surfaced so the host can forward them if desired.
    public private(set) var lastNotifications: [(type: String, json: String)] = []
    #endif

    public init(extensionURLPrefix: String = "", debugMode: Bool = false) throws {
        #if canImport(JavaScriptCore)
        guard let context = JSContext() else {
            throw BridgeError.javaScriptCoreUnavailable
        }
        self.context = context
        installEnvironment()
        try loadEngine()
        guard ready else { throw BridgeError.engineNotReady }
        try sendInit(extensionURLPrefix: extensionURLPrefix, debugMode: debugMode)
        #else
        throw BridgeError.javaScriptCoreUnavailable
        #endif
    }

    /// Handle one `event-sandbox-request`. `payloadJSON` is the request's
    /// `payload` object (`{ "kind": "...", ... }`). Returns the result object
    /// serialized as JSON (the same value `offscreen.js` resolves with).
    public func handle(payloadJSON: String) throws -> String {
        #if canImport(JavaScriptCore)
        guard ready else { throw BridgeError.engineNotReady }
        let id = nextRequestId
        nextRequestId += 1
        pendingReplyJSON = nil
        pendingReplyId = id
        lastNotifications.removeAll(keepingCapacity: true)

        let payloadLiteral = try Self.jsLiteral(payloadJSON)
        let script = "globalThis.__cbDeliver(\(id), \(payloadLiteral));"
        context.evaluateScript(script)
        if let exception = context.exception {
            context.exception = nil
            throw BridgeError.dispatchFailed(exception.toString() ?? "unknown")
        }
        guard let reply = pendingReplyJSON, pendingReplyId == id else {
            throw BridgeError.dispatchFailed("engine produced no reply for request \(id)")
        }
        return reply
        #else
        throw BridgeError.javaScriptCoreUnavailable
        #endif
    }

    /// Convenience wrappers mirroring the extension's message kinds.
    public func loadSource(groupID: String, source: String) throws -> String {
        try handle(payloadJSON: Self.encodeJSONObject([
            "kind": "load-source", "groupId": groupID, "source": source
        ]))
    }

    public func unloadGroup(groupID: String, clearState: Bool = true) throws -> String {
        try handle(payloadJSON: Self.encodeJSONObject([
            "kind": "unload-group", "groupId": groupID, "clearState": clearState
        ]))
    }

    public func checkSource(_ source: String) throws -> String {
        try handle(payloadJSON: Self.encodeJSONObject([
            "kind": "check-source", "source": source
        ]))
    }

    // MARK: - Engine boot

    #if canImport(JavaScriptCore)
    private func installEnvironment() {
        context.exceptionHandler = { _, exception in
            print("[SafariCustomRuleBridge] JS exception: \(exception?.toString() ?? "unknown")")
        }

        // Capture replies posted by the engine via window.parent.postMessage.
        let onReply: @convention(block) (Int, String) -> Void = { [weak self] id, json in
            guard let self else { return }
            self.pendingReplyId = id
            self.pendingReplyJSON = json
        }
        let onReady: @convention(block) () -> Void = { [weak self] in
            self?.ready = true
        }
        let onNotify: @convention(block) (String, String) -> Void = { [weak self] type, json in
            self?.lastNotifications.append((type: type, json: json))
        }
        context.setObject(onReply, forKeyedSubscript: "__cbHostReply" as NSString)
        context.setObject(onReady, forKeyedSubscript: "__cbHostReady" as NSString)
        context.setObject(onNotify, forKeyedSubscript: "__cbHostNotify" as NSString)

        // window / self / console shim. event-sandbox.js + helpers.js only use
        // window.addEventListener("message", …), window.parent.postMessage,
        // self.__customBlockerHelpers, and (try/caught) console.* — no timers,
        // DOM, fetch, or location.
        let bootstrap = """
        (function () {
          var listeners = [];
          var parentBridge = {
            postMessage: function (message) {
              try {
                if (!message || typeof message !== "object") return;
                if (message.type === "reply") {
                  __cbHostReply(message.id === undefined ? -1 : message.id,
                                JSON.stringify(message.result === undefined ? null : message.result));
                } else if (message.type === "ready") {
                  __cbHostReady();
                } else {
                  __cbHostNotify(String(message.type || ""), JSON.stringify(message));
                }
              } catch (e) {}
            }
          };
          var win = {
            addEventListener: function (type, fn) {
              if (type === "message" && typeof fn === "function") listeners.push(fn);
            },
            removeEventListener: function (type, fn) {
              listeners = listeners.filter(function (f) { return f !== fn; });
            }
          };
          win.parent = parentBridge;          // window.parent !== window (ready check)
          win.postMessage = function () {};
          globalThis.window = win;
          globalThis.self = globalThis;
          if (typeof globalThis.console === "undefined") {
            var noop = function () {};
            globalThis.console = { log: noop, warn: noop, error: noop, info: noop, debug: noop };
          }
          // event-sandbox.js calls performance.now() unconditionally (handler
          // deadlines, registeredAt). JavaScriptCore has no performance object,
          // so back it with Date.now() — millisecond resolution is plenty for
          // the time-budget bookkeeping.
          if (typeof globalThis.performance === "undefined" || !globalThis.performance.now) {
            globalThis.performance = { now: function () { return Date.now(); } };
          }
          globalThis.__cbDeliver = function (id, payload) {
            var evt = {
              data: { source: "custom-blocker-offscreen", id: id, payload: payload },
              source: parentBridge,
              origin: ""
            };
            for (var i = 0; i < listeners.length; i++) {
              try { listeners[i](evt); } catch (e) {}
            }
          };
        })();
        """
        context.evaluateScript(bootstrap)
    }

    private func loadEngine() throws {
        let helpers = try Self.loadResource("helpers", ext: "js")
        let sandbox = try Self.loadResource("event-sandbox", ext: "js")
        context.evaluateScript(helpers)
        if let exception = context.exception {
            context.exception = nil
            throw BridgeError.dispatchFailed("helpers.js: \(exception.toString() ?? "unknown")")
        }
        // event-sandbox.js posts {type:"ready"} during evaluation, which flips
        // `ready` via __cbHostReady.
        context.evaluateScript(sandbox)
        if let exception = context.exception {
            context.exception = nil
            throw BridgeError.dispatchFailed("event-sandbox.js: \(exception.toString() ?? "unknown")")
        }
    }

    private func sendInit(extensionURLPrefix: String, debugMode: Bool) throws {
        _ = try handle(payloadJSON: Self.encodeJSONObject([
            "kind": "init",
            "extensionUrlPrefix": extensionURLPrefix,
            "debugMode": debugMode
        ]))
    }

    // MARK: - Helpers

    private static func loadResource(_ name: String, ext: String) throws -> String {
        let url = bundledResourceURL(name: name, ext: ext)
        guard let url else { throw BridgeError.resourcesMissing("\(name).\(ext)") }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw BridgeError.resourcesMissing("\(name).\(ext) (unreadable)")
        }
        return text
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

    private static func jsLiteral(_ value: String) throws -> String {
        // Encode the raw JSON string as a JS string literal we can JSON.parse.
        let data = try JSONEncoder().encode(value)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw BridgeError.dispatchFailed("could not encode literal")
        }
        return "JSON.parse(\(literal))"
    }

    private static func encodeJSONObject(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
    #endif
}
