import CoreGraphics
import Foundation

/// Sizing for the popover's scrollable job list.
///
/// The popover grows with the number of jobs instead of always reserving a fixed slab of
/// screen: three jobs get a short window, thirty get a tall one. It never exceeds a fraction of
/// the display, because a menu bar popover taller than the screen is unusable and macOS will
/// clip it anyway.
///
/// Pure arithmetic with no SwiftUI types so the rules are directly testable.
public enum PopoverLayout {
    /// Estimated heights, in points, of the pieces the scroll area contains. These only need to
    /// be close: an underestimate means a little empty space, an overestimate a little scroll.
    public struct Metrics: Sendable {
        public var runningRow: CGFloat = 96
        public var pendingRow: CGFloat = 54
        public var finishedRow: CGFloat = 58
        public var sectionHeader: CGFloat = 30
        public var summaryStrip: CGFloat = 56
        public var warningRow: CGFloat = 44
        public var staleBanner: CGFloat = 130
        public var emptyState: CGFloat = 190
        /// Never shorter than this, so the window does not look broken when nearly empty.
        public var minimum: CGFloat = 120
        /// Floor for the detail page, which always has several sections to show.
        public var detailMinimum: CGFloat = 260
        /// Fraction of the usable screen height the whole popover may occupy.
        public var maximumScreenFraction: CGFloat = 0.80
        /// Header plus footer, which sit outside the scroll area but inside the popover.
        public var chrome: CGFloat = 104

        public init() {}
    }

    public static let metrics = Metrics()

    /// Height for the scrolling job list.
    ///
    /// - Parameters:
    ///   - groups: the jobs actually being displayed, after any filtering.
    ///   - warningCount: prominent warnings rendered above the list.
    ///   - showsStaleBanner: whether the disconnected/stale banner is present.
    ///   - showsSummary: whether the running/pending/completed/failed strip is present.
    ///   - showsEmptyState: whether the empty-state block replaces the list.
    ///   - screenHeight: usable screen height (`NSScreen.visibleFrame.height`).
    public static func scrollHeight(
        groups: GroupedJobs,
        warningCount: Int = 0,
        showsStaleBanner: Bool = false,
        showsSummary: Bool = true,
        showsEmptyState: Bool = false,
        screenHeight: CGFloat,
        metrics: Metrics = PopoverLayout.metrics
    ) -> CGFloat {
        var content: CGFloat = 0

        if showsStaleBanner { content += metrics.staleBanner }
        content += CGFloat(max(0, warningCount)) * metrics.warningRow

        if showsEmptyState {
            content += metrics.emptyState
        } else {
            if showsSummary { content += metrics.summaryStrip }
            for group in JobGroup.allCases {
                let count = groups.jobs(in: group).count
                guard count > 0 else { continue }
                content += metrics.sectionHeader
                content += CGFloat(count) * rowHeight(for: group, metrics: metrics)
            }
        }

        // The cap applies to the whole popover, so the chrome comes out of the same budget.
        let available = max(
            metrics.minimum,
            screenHeight * clampedFraction(metrics.maximumScreenFraction) - metrics.chrome
        )
        return min(max(content, metrics.minimum), available)
    }

    public static func rowHeight(for group: JobGroup, metrics: Metrics = PopoverLayout.metrics) -> CGFloat {
        switch group {
        case .running: return metrics.runningRow
        case .pending: return metrics.pendingRow
        case .completed, .unsuccessful: return metrics.finishedRow
        }
    }

    /// Guards against a nonsensical configured fraction.
    static func clampedFraction(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.2), 0.95)
    }

    /// Height for the job-detail page's scroll area.
    ///
    /// Detail is a second page inside the same popover, so it obeys the same screen cap. It
    /// gets a floor of its own because a detail page squeezed to the list's minimum would be
    /// unreadable.
    public static func detailScrollHeight(
        hasProgress: Bool,
        metricCount: Int,
        logsExpanded: Bool,
        screenHeight: CGFloat,
        metrics: Metrics = PopoverLayout.metrics
    ) -> CGFloat {
        var content: CGFloat = 300          // resources + job metadata sections
        if hasProgress { content += 150 }
        content += CGFloat(max(0, min(metricCount, 12))) * 16
        if logsExpanded { content += 210 }

        let available = max(
            metrics.detailMinimum,
            screenHeight * clampedFraction(metrics.maximumScreenFraction) - metrics.chrome
        )
        return min(max(content, metrics.detailMinimum), available)
    }

    /// Fallback when no screen can be queried (headless test runs, detached processes).
    public static let fallbackScreenHeight: CGFloat = 900
}
