import Foundation

#if canImport(JavaScriptCore)
@preconcurrency import JavaScriptCore
#endif

/// Native host for the Safari extension's custom-rule engine.
///
/// On Chromium/Firefox the custom-rule engine (`rule-core.js` +
/// `event-sandbox.js`) runs in a browser sandbox iframe. Safari has no
/// `chrome.offscreen`, and its support for the eval-relaxing manifest `sandbox`
/// key is unreliable, so the Safari extension is a *thin client*: it forwards
/// each `event-sandbox-request` to the macosBlocker app over native messaging,
/// and this bridge runs the **same** engine files in JavaScriptCore (no CSP, so
/// `new Function` just works) and returns the same `{ ok, … }` shape.
///
/// It is still the browser's engine (its actions are the browser's: items,
/// cover, go, close, css, dom — carried out by the Safari extension); Mac Vault
/// only hosts it. This is the counterpart of `offscreen.js`: a tiny `window` /
/// `postMessage` shim answering the same payload kinds (`load-source`,
/// `unload-group`, `dispatch-event`).
///
/// The registered rules live in this JSContext, which the
/// SafariWebExtensionHandler keeps alive for the lifetime of its process.
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
    #endif

    public init() throws {
        #if canImport(JavaScriptCore)
        guard let context = JSContext() else {
            throw BridgeError.javaScriptCoreUnavailable
        }
        self.context = context
        installEnvironment()
        try loadEngine()
        guard ready else { throw BridgeError.engineNotReady }
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

    /// Convenience wrapper mirroring the extension's message kind.
    public func loadSource(groupID: String, source: String, state: [String: Any] = [:]) throws -> String {
        try handle(payloadJSON: Self.encodeJSONObject([
            "kind": "load-source", "groupId": groupID, "source": source, "state": state
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
        context.setObject(onReply, forKeyedSubscript: "__cbHostReply" as NSString)
        context.setObject(onReady, forKeyedSubscript: "__cbHostReady" as NSString)

        // window / self shim. event-sandbox.js only uses
        // window.addEventListener("message", …) and window.parent.postMessage
        // (replies, "ready", and handler-start beacons, ignored here) — no
        // timers, DOM, fetch, or location.
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
        // The same files, in the same order, as event-sandbox.html.
        // event-sandbox.js posts {type:"ready"} during evaluation, which flips
        // `ready` via __cbHostReady.
        for name in ["rule-core", "event-sandbox"] {
            context.evaluateScript(try Self.loadResource(name, ext: "js"))
            if let exception = context.exception {
                context.exception = nil
                throw BridgeError.dispatchFailed("\(name).js: \(exception.toString() ?? "unknown")")
            }
        }
    }

    // MARK: - Helpers

    private static func loadResource(_ name: String, ext: String) throws -> String {
        guard let url = RuntimeResources.url(name: name, ext: ext) else { throw BridgeError.resourcesMissing("\(name).\(ext)") }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw BridgeError.resourcesMissing("\(name).\(ext) (unreadable)")
        }
        return text
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
