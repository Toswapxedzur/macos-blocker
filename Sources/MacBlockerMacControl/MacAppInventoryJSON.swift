import Foundation

#if os(macOS)
import AppKit
#endif

/// Produces the installed-application inventory as a JSON string for the web
/// editor's app picker. Each entry is `{ id, name, icon }` where `icon` is a
/// small base64 PNG data URL (or "" when unavailable).
public enum MacAppInventoryJSON {
    /// Builds the inventory JSON. `iconPixelSize` keeps the payload light by
    /// rendering each icon at a small size (default 36pt @1x).
    public static func make(iconPixelSize: CGFloat = 36) -> String {
        #if os(macOS)
        let apps = MacApplicationInventory.installedApplications()
        var entries: [[String: String]] = []
        entries.reserveCapacity(apps.count)

        for app in apps {
            var icon = ""
            if let image = MacApplicationInventory.icon(for: app),
               let dataURL = pngDataURL(from: image, pixelSize: iconPixelSize) {
                icon = dataURL
            }
            entries.append([
                "id": app.bundleIdentifier,
                "name": app.name,
                "icon": icon
            ])
        }

        guard let data = try? JSONSerialization.data(withJSONObject: entries),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
        #else
        return "[]"
        #endif
    }

    #if os(macOS)
    private static func pngDataURL(from image: NSImage, pixelSize: CGFloat) -> String? {
        let target = NSSize(width: pixelSize, height: pixelSize)
        let resized = NSImage(size: target)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return "data:image/png;base64," + png.base64EncodedString()
    }
    #endif
}
