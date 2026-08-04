#if os(macOS)
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Resolves the real macOS app icon for an MCP client connector, as a PNG
/// `data:` URL for the settings list. GUI apps (Cursor, VS Code, Claude Desktop,
/// …) have an icon; CLI/extension tools (Codex, Claude Code, Cline) don't, so
/// they return nil and the web layer draws a lettered fallback badge.
enum MCPConnectorIcons {
    /// Connector id → candidate `.app` locations (also checked under
    /// `~/Applications`). Only GUI apps appear here.
    private static let appNames: [String: [String]] = [
        "claude-desktop": ["Claude.app"],
        "cursor": ["Cursor.app"],
        "vscode": ["Visual Studio Code.app"],
        "vscode-insiders": ["Visual Studio Code - Insiders.app"],
        "windsurf": ["Windsurf.app"],
        "zed": ["Zed.app"],
    ]

    static func iconDataURL(connectorID: String, sizePx: Int = 36) -> String? {
        #if canImport(AppKit)
        guard let names = appNames[connectorID] else { return nil }
        let fileManager = FileManager.default
        let roots = [
            "/Applications",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
        ]
        for name in names {
            for root in roots {
                let path = root + "/" + name
                guard fileManager.fileExists(atPath: path) else { continue }
                if let url = pngDataURL(NSWorkspace.shared.icon(forFile: path), sizePx: sizePx) {
                    return url
                }
            }
        }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
    private static func pngDataURL(_ image: NSImage, sizePx: Int) -> String? {
        let size = NSSize(width: sizePx, height: sizePx)
        let scaled = NSImage(size: size)
        scaled.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        scaled.unlockFocus()
        guard let tiff = scaled.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }
    #endif
}
#endif
