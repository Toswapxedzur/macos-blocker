import CommonCrypto
import Foundation
import JavaScriptCore
import Security

/// Runs the editor's own lock rules for the Mac app's AI tools: customBlocker's
/// `group-actions.js` and `parental-pin.js` (bundled copies kept in sync by
/// `sync-webui.sh`) in JavaScriptCore. One implementation of every gate — the
/// wait, the PIN with its retry wait, the confirmation — for the editor, the
/// browser's tools and these tools (owner 2026-09-26: a tool may do exactly
/// what the user can, no more, no less).
public final class GroupActionsRuntime: @unchecked Sendable {
    public static let shared = GroupActionsRuntime()

    private let lock = NSLock()
    private let context: JSContext

    init() {
        context = JSContext()
        context.exceptionHandler = { _, exception in
            NSLog("[GroupActionsRuntime] %@", exception?.toString() ?? "unknown error")
        }
        // The two browser APIs the files use: UTF-8 encoding and random salt bytes.
        let randomBytes: @convention(block) (Int) -> [NSNumber] = { count in
            var bytes = [UInt8](repeating: 0, count: max(0, min(count, 1024)))
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return bytes.map { NSNumber(value: $0) }
        }
        context.setObject(randomBytes, forKeyedSubscript: "__randomBytes" as NSString)
        // Standard PBKDF2-HMAC-SHA256 (32 bytes, hex), native: parental-pin.js
        // uses it when present; tests pin it to the plain-JS result.
        let pbkdf2: @convention(block) (String, String, Int) -> String = { pin, salt, rounds in
            let password = Array(pin.utf8)
            let saltBytes = Array(salt.utf8)
            var out = [UInt8](repeating: 0, count: 32)
            let status = password.withUnsafeBufferPointer { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }, password.count,
                                     saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     UInt32(max(1, rounds)), &out, out.count)
            }
            return status == kCCSuccess ? out.map { String(format: "%02x", $0) }.joined() : ""
        }
        context.setObject(pbkdf2, forKeyedSubscript: "__nativePbkdf2Hex" as NSString)
        context.evaluateScript("""
        function TextEncoder() {}
        TextEncoder.prototype.encode = function (text) {
          var utf8 = unescape(encodeURIComponent(String(text)));
          var out = new Uint8Array(utf8.length);
          for (var i = 0; i < utf8.length; i++) out[i] = utf8.charCodeAt(i);
          return out;
        };
        var crypto = { getRandomValues: function (array) {
          var bytes = __randomBytes(array.length);
          for (var i = 0; i < array.length; i++) array[i] = bytes[i];
          return array;
        } };
        """)
        for name in ["parental-pin", "group-actions"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "Resources")
                    ?? Bundle.module.url(forResource: name, withExtension: "js"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                NSLog("[GroupActionsRuntime] missing bundled %@.js", name)
                continue
            }
            context.evaluateScript(source, withSourceURL: url)
        }
    }

    /// Calls `CBGroupActions.<name>(…)` (or `CBParentalPin.<name>` with
    /// `module: "CBParentalPin"`) with JSON-compatible arguments and returns
    /// its result as Foundation objects (nil for undefined/null).
    public func call(_ name: String, _ arguments: [Any], module: String = "CBGroupActions") -> Any? {
        lock.lock(); defer { lock.unlock() }
        guard let api = context.objectForKeyedSubscript(module), !api.isUndefined,
              let result = api.invokeMethod(name, withArguments: arguments.map(Self.jsSafe)) else { return nil }
        if result.isUndefined || result.isNull { return nil }
        return result.toObject()
    }

    public func constant(_ name: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return context.objectForKeyedSubscript("CBGroupActions")?.objectForKeyedSubscript(name)?.toObject()
    }

    /// NSNull becomes JS null; everything else passes as is.
    private static func jsSafe(_ value: Any) -> Any {
        switch value {
        case is NSNull: return NSNull()
        case let dict as [String: Any]: return dict.mapValues(jsSafe)
        case let list as [Any]: return list.map(jsSafe)
        default: return value
        }
    }
}
