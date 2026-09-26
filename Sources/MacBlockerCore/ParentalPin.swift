import CommonCrypto
import Foundation

/// The parental PIN, for the Mac's AI tools: the same hashing, verification and
/// retry wait as the editor (customBlocker `parental-pin.js`, which the Mac
/// editor runs), over the same stored fields, so a tool passes exactly the
/// user's gate (owner 2026-09-26). Tests pin the two to identical output.
public enum ParentalPin {
    public static let hashPrefix = "pbkdf2-sha256$"
    public static let rounds = 100_000
    /// The store key the editor keeps its per-group wrong-PIN counts under.
    public static let attemptsKey = "parentalPinAttempts"
    static let retryCapMs = 64_000.0

    public static func isValid(_ pin: String) -> Bool {
        pin.count == 6 && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 1 s, 2 s, 4 s … doubling up to 64 s after the nth wrong PIN.
    public static func retryDelayMs(failures: Int) -> Double {
        min(1000 * pow(2, Double(max(0, failures - 1))), retryCapMs)
    }

    public static func hash(pin: String, salt: String, rounds: Int = rounds) -> String {
        "\(hashPrefix)\(rounds)$\(pbkdf2Hex(pin: pin, salt: salt, rounds: rounds))"
    }

    /// A new PIN, salted: the fields a group stores.
    public static func newPinFields(pin: String) -> [String: Any] {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let salt = hex(bytes)
        return ["parentalPasswordSalt": salt, "parentalPasswordHash": hash(pin: pin, salt: salt)]
    }

    /// (ok, upgradedHash): a PIN stored in an old format opens once and should
    /// then be stored as `upgradedHash`.
    public static func verify(group: [String: Any], pin: String) -> (ok: Bool, upgradedHash: String?) {
        guard let stored = group["parentalPasswordHash"] as? String, !stored.isEmpty,
              let salt = group["parentalPasswordSalt"] as? String, !salt.isEmpty,
              isValid(pin) else { return (false, nil) }
        if stored.hasPrefix(hashPrefix) {
            let parts = stored.split(separator: "$", omittingEmptySubsequences: false)
            guard parts.count == 3, let rounds = Int(parts[1]), rounds >= 1 else { return (false, nil) }
            return (constantTimeEqual(pbkdf2Hex(pin: pin, salt: salt, rounds: rounds), String(parts[2])), nil)
        }
        let legacy = stored.hasPrefix("fb") ? legacyFallbackHash(pin: pin, salt: salt) : legacySHA256(pin: pin, salt: salt)
        guard constantTimeEqual(legacy, stored) else { return (false, nil) }
        return (true, hash(pin: pin, salt: salt))
    }

    public enum CheckResult: Equatable {
        case ok(upgradedHash: String?)
        /// Still inside the wait: the PIN was not checked.
        case waiting(seconds: Int)
        /// Wrong: the next try waits this long.
        case wrong(waitSeconds: Int)
    }

    /// The gate, over the stored attempts map (read and written back in `attempts`).
    public static func check(attempts: inout [String: Any], group: [String: Any], pin: String, nowMs: Double) -> CheckResult {
        let id = group["id"] as? String ?? ""
        let entry = attempts[id] as? [String: Any] ?? [:]
        let retryAt = (entry["retryAtMs"] as? NSNumber)?.doubleValue ?? 0
        if retryAt > nowMs { return .waiting(seconds: Int(((retryAt - nowMs) / 1000).rounded(.up))) }
        let result = verify(group: group, pin: pin)
        if result.ok {
            attempts.removeValue(forKey: id)
            return .ok(upgradedHash: result.upgradedHash)
        }
        let failures = ((entry["failures"] as? NSNumber)?.intValue ?? 0) + 1
        let wait = retryDelayMs(failures: failures)
        attempts[id] = ["failures": failures, "retryAtMs": nowMs + wait]
        return .wrong(waitSeconds: Int((wait / 1000).rounded(.up)))
    }

    // MARK: Primitives

    static func pbkdf2Hex(pin: String, salt: String, rounds: Int) -> String {
        let password = Array(pin.utf8)
        let saltBytes = Array(salt.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }, password.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                &out, out.count
            )
        }
        return status == kCCSuccess ? hex(out) : ""
    }

    static func legacySHA256(pin: String, salt: String) -> String {
        let data = Array("\(salt):\(pin)".utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = CC_SHA256(data, CC_LONG(data.count), &digest)
        return hex(digest)
    }

    /// The old non-crypto fallback the Mac editor once stored (JS `Math.imul`
    /// over UTF-16 units), checked only so such a PIN can be upgraded.
    static func legacyFallbackHash(pin: String, salt: String) -> String {
        var h1: UInt32 = 0xdeadbeef
        var h2: UInt32 = 0x41c6ce57
        for unit in "\(salt):\(pin)".utf16 {
            h1 = (h1 ^ UInt32(unit)) &* 2_654_435_761
            h2 = (h2 ^ UInt32(unit)) &* 1_597_334_677
        }
        h1 = ((h1 ^ (h1 >> 16)) &* 2_246_822_507) ^ ((h2 ^ (h2 >> 13)) &* 3_266_489_909)
        h2 = ((h2 ^ (h2 >> 16)) &* 2_246_822_507) ^ ((h1 ^ (h1 >> 13)) &* 3_266_489_909)
        let out = UInt64(h2 & 2_097_151) << 32 | UInt64(h1)
        let text = String(out, radix: 16)
        return "fb" + String(repeating: "0", count: max(0, 14 - text.count)) + text
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
