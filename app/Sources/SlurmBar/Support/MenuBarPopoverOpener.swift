import AppKit
import SwiftUI

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
    static func statusItemButton() -> NSStatusBarButton? {
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

/// Adds a SlurmBar-styled right-click action panel that SwiftUI's window-style `MenuBarExtra`
/// does not provide on its own.
///
/// A local event monitor is used instead of replacing the status item's target/action, so the
/// system-owned left-click behaviour remains untouched.
@MainActor
final class MenuBarContextMenuController: NSObject, NSPopoverDelegate {
    private var eventMonitor: Any?
    private var contextPopover: NSPopover?

    func install() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self,
                  let button = MenuBarPopoverOpener.statusItemButton(),
                  event.window === button.window,
                  button.bounds.contains(button.convert(event.locationInWindow, from: nil))
            else { return event }

            self.showContextPopover(relativeTo: button)
            return nil
        }
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    private func showContextPopover(relativeTo button: NSStatusBarButton) {
        if contextPopover?.isShown == true {
            closeContextPopover()
            return
        }

        let popover = NSPopover()
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 210, height: 83)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContextActionsView(
                openAction: { [weak self] in
                    self?.closeContextPopover()
                    DispatchQueue.main.async {
                        _ = MenuBarPopoverOpener.open()
                    }
                },
                quitAction: { [weak self] in
                    self?.closeContextPopover()
                    NSApp.terminate(nil)
                }
            )
        )
        contextPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closeContextPopover() {
        contextPopover?.performClose(nil)
        contextPopover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              closedPopover === contextPopover
        else { return }
        contextPopover = nil
    }
}

/// A compact companion to the main dashboard: system typography, SF Symbols and familiar
/// full-width hover states, presented inside the same popover material as SlurmBar.
private struct MenuBarContextActionsView: View {
    let openAction: () -> Void
    let quitAction: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            ContextActionRow(
                title: "Open SlurmBar",
                symbol: "server.rack",
                action: openAction
            )

            Divider()
                .padding(.horizontal, 5)

            ContextActionRow(
                title: "Quit SlurmBar",
                symbol: "power",
                shortcut: "⌘Q",
                action: quitAction
            )
        }
        .padding(5)
        .frame(width: 210)
    }
}

private struct ContextActionRow: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 31)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.09 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }
}
