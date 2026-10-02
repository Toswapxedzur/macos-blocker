import Foundation

/// Data-only browser presentation shared by WKWebView and WebView2. No script
/// source is interpolated from collected titles or user input.
enum VaultClassifierPresentation {
    static let maximumWebActionDataFields = 24

    static func stateUpdateJavaScript(payload: [String: Any], presentationRevision: UInt64? = nil) -> String? {
        var deliveredPayload = payload
        if let presentationRevision { deliveredPayload["presentationRevision"] = presentationRevision }
        guard JSONSerialization.isValidJSONObject(deliveredPayload),
              let data = try? JSONSerialization.data(withJSONObject: deliveredPayload, options: [.sortedKeys]) else { return nil }
        let encoded = data.base64EncodedString()
        return "window.VaultClassifier && window.VaultClassifier.receive(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'), value => value.charCodeAt(0)))));"
    }
}
