import SlurmBarKit
import SwiftUI

@main
struct SlurmBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppController()

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
                .environmentObject(controller)
        } label: {
            MenuBarLabelView(label: controller.menuBarLabel)
        }
        // .window gives a real SwiftUI surface rather than a system menu, which is what lets
        // the popover show progress bars, grouped sections and a scrollable job list.
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRootView()
                .environmentObject(controller)
        }
    }
}

/// Keeps the process out of the Dock and the app switcher.
///
/// `LSUIElement` in Info.plist does this for a bundled app; setting the policy here as well
/// means `swift run` behaves the same way during development.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarContextMenu: MenuBarContextMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let contextMenu = MenuBarContextMenuController()
            contextMenu.install()
            menuBarContextMenu = contextMenu
        }

        // Launching a menu bar app otherwise looks like nothing happened: the icon is already
        // in the menu bar, so double-clicking in Finder gives no feedback at all. Show the
        // jobs straight away instead.
        MainActor.assumeIsolated { MenuBarPopoverOpener.openWhenReady() }

        if let path = ProcessInfo.processInfo.environment["SLURMBAR_DEMO_SCREENSHOT_PATH"] {
            Task { @MainActor in
                // Allow the popover, demo snapshot, logs, and GPU telemetry to settle first.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                exportDemoScreenshot(to: path)
            }
        }
    }

    /// Double-clicking the app while it is already running.
    ///
    /// macOS routes a second launch here rather than starting another instance, so this is the
    /// hook that makes double-clicking behave the way the user expects.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        _ = MainActor.assumeIsolated { MenuBarPopoverOpener.open() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @MainActor
    private func exportDemoScreenshot(to path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/") else {
            NSLog("SlurmBar: refusing to export a demo screenshot outside the temporary directory")
            return
        }
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && ($0.contentView?.bounds.width ?? 0) >= PopoverRootView.width
        }), let view = window.contentView else {
            NSLog("SlurmBar: no visible popover available for the demo screenshot")
            return
        }

        let bounds = view.bounds
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(bounds.width * scale)),
            pixelsHigh: Int(ceil(bounds.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)

        do {
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            try data.write(to: url, options: .atomic)
            NSLog("SlurmBar: exported 2x demo screenshot to %@", url.path)
        } catch {
            NSLog("SlurmBar: could not export demo screenshot: %@", String(describing: error))
        }
    }
}
