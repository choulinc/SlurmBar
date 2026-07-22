import Foundation

/// Whether the menu bar popover is currently on screen.
///
/// `MenuBarExtra` reports nothing about its own presentation, and the only way to open it is to
/// click the status item — which *toggles*. Without tracking this, double-clicking the app
/// while the popover was already open would close it, the exact opposite of what the user
/// asked for. The popover view updates this as it appears and disappears.
@MainActor
final class PopoverVisibility {
    static let shared = PopoverVisibility()

    private(set) var isVisible = false

    private init() {}

    func markVisible() { isVisible = true }
    func markHidden() { isVisible = false }
}
