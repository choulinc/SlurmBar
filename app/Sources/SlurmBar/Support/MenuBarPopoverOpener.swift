import AppKit

/// Opens the menu bar popover programmatically.
///
/// `MenuBarExtra` exposes no API for this — its only binding is `isInserted`, which controls
/// whether the item is in the menu bar, not whether its window is showing. Without this,
/// launching the app or double-clicking it in Finder produces no visible response at all: the
/// icon is already there, so nothing appears to happen.
///
/// The status item is therefore located through AppKit and clicked. That relies on the private
/// window class `MenuBarExtra` uses, so it is written to fail quietly: if the structure changes
/// in a future macOS, the app behaves exactly as it does today rather than crashing.
enum MenuBarPopoverOpener {
    /// Show the popover, leaving it alone if it is already showing.
    ///
    /// Clicking the status item toggles, so this checks first: double-clicking the app while
    /// the popover is open must not close it.
    ///
    /// - Returns: whether the popover is showing afterwards.
    @MainActor
    @discardableResult
    static func open() -> Bool {
        if PopoverVisibility.shared.isVisible { return true }
        guard let button = statusItemButton() else { return false }
        button.performClick(nil)
        return true
    }

    /// Try repeatedly for a short while.
    ///
    /// At `applicationDidFinishLaunching` the SwiftUI scene has usually not created its status
    /// item yet, so a single attempt loses the race. This retries on the main queue until the
    /// button exists or the budget runs out.
    @MainActor
    static func openWhenReady(attemptsRemaining: Int = 20, delay: TimeInterval = 0.1) {
        if open() { return }
        guard attemptsRemaining > 0 else {
            NSLog("SlurmBar: could not find the menu bar item to open; click it manually.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                openWhenReady(attemptsRemaining: attemptsRemaining - 1, delay: delay)
            }
        }
    }

    /// Find the button backing our menu bar item.
    ///
    /// `MenuBarExtra` puts its item in a window whose class name contains "StatusBar"; the
    /// button is that window's content view or a descendant of it.
    private static func statusItemButton() -> NSStatusBarButton? {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            if let button = window.contentView as? NSStatusBarButton {
                return button
            }
            if let button = firstStatusBarButton(in: window.contentView) {
                return button
            }
        }
        return nil
    }

    private static func firstStatusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = firstStatusBarButton(in: subview) { return button }
        }
        return nil
    }
}
