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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Launching a menu bar app otherwise looks like nothing happened: the icon is already
        // in the menu bar, so double-clicking in Finder gives no feedback at all. Show the
        // jobs straight away instead.
        MainActor.assumeIsolated { MenuBarPopoverOpener.openWhenReady() }
    }

    /// Double-clicking the app while it is already running.
    ///
    /// macOS routes a second launch here rather than starting another instance, so this is the
    /// hook that makes double-clicking behave the way the user expects.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { MenuBarPopoverOpener.open() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
