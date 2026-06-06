import SwiftUI
import MacBlockerAppFeature

#if os(macOS)
import AppKit

/// A SwiftPM executable is launched as a background "agent" process, so AppKit
/// never shows the window or a Dock icon. Promoting the activation policy to
/// `.regular` and activating makes the panel window appear.
final class PanelAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

@main
struct MacBlockerPanelApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(PanelAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup("macosBlocker Panel") {
            BlockerMainView()
                .frame(minWidth: 720, minHeight: 560)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif

        #if os(macOS)
        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("macosBlocker")
                    .font(.title2.bold())
                Text("The macOS panel runs the shared editor and status-window replacement. iOS shielding still requires an Xcode app target with Screen Time entitlements.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            .padding()
        }
        #endif
    }
}
