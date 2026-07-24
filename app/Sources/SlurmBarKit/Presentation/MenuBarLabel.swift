import Foundation

/// What to draw in the menu bar.
///
/// The menu bar is the most constrained surface in macOS and the most visible; it gets a
/// symbol, at most a short label, and one optional failure dot. Everything else belongs in the
/// popover.
public struct MenuBarLabel: Hashable, Sendable {
    /// SF Symbol for the icon. Rendered as a template so it matches Apple's own items in both
    /// appearances and in menu bar tinting.
    public let symbolName: String
    /// Short text beside the icon, or nil for icon-only.
    public let text: String?
    /// Draws the small failure indicator.
    public let showsFailureIndicator: Bool
    /// VoiceOver description of the whole item.
    public let accessibilityLabel: String

    public init(symbolName: String, text: String?, showsFailureIndicator: Bool, accessibilityLabel: String) {
        self.symbolName = symbolName
        self.text = text
        self.showsFailureIndicator = showsFailureIndicator
        self.accessibilityLabel = accessibilityLabel
    }
}

public enum MenuBarLabelBuilder {
    /// `server.rack` reads as "cluster" at menu bar size and exists on macOS 14.
    public static let defaultSymbol = "server.rack"

    /// - Parameter summary: counts to display. Pass the *filtered* summary so the menu bar
    ///   agrees with the popover; defaults to the snapshot's own counts.
    public static func make(
        mode: MenuBarDisplayMode,
        snapshot: Snapshot?,
        summary summaryOverride: JobSummary? = nil,
        connection: ConnectionState,
        pinnedJobID: String?,
        hasUnacknowledgedFailure: Bool,
        showFailureIndicator: Bool
    ) -> MenuBarLabel {
        let failureIndicator = showFailureIndicator && hasUnacknowledgedFailure

        guard let snapshot else {
            let label: String
            switch connection {
            case .unconfigured: label = "SlurmBar, no cluster configured"
            case .connecting: label = "SlurmBar, refreshing"
            case .failed(let failure, _): label = "SlurmBar, \(failure.title)"
            default: label = "SlurmBar, not connected"
            }
            return MenuBarLabel(
                symbolName: defaultSymbol,
                text: nil,
                showsFailureIndicator: failureIndicator,
                accessibilityLabel: label
            )
        }

        let summary = summaryOverride ?? snapshot.summary
        let accessibility = accessibilityDescription(summary: summary, connection: connection)

        switch mode {
        case .iconOnly:
            return MenuBarLabel(
                symbolName: defaultSymbol,
                text: nil,
                showsFailureIndicator: failureIndicator,
                accessibilityLabel: accessibility
            )

        case .counts:
            return MenuBarLabel(
                symbolName: defaultSymbol,
                text: countsText(summary: summary),
                showsFailureIndicator: failureIndicator,
                accessibilityLabel: accessibility
            )

        case .pinnedJobPercent:
            if let text = pinnedPercentText(snapshot: snapshot, pinnedJobID: pinnedJobID) {
                return MenuBarLabel(
                    symbolName: defaultSymbol,
                    text: text,
                    showsFailureIndicator: failureIndicator,
                    accessibilityLabel: accessibility
                )
            }
            // No pinned job, or it has no progress: counts are more useful than a blank space.
            return MenuBarLabel(
                symbolName: defaultSymbol,
                text: countsText(summary: summary),
                showsFailureIndicator: failureIndicator,
                accessibilityLabel: accessibility
            )
        }
    }

    /// `3R 2P`, `3R`, or nil when nothing is active.
    public static func countsText(summary: JobSummary) -> String? {
        var parts: [String] = []
        let active = summary.running + summary.completing
        if active > 0 { parts.append("\(active)R") }
        if summary.pending > 0 { parts.append("\(summary.pending)P") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// `37%` for the pinned job, while it is still making progress.
    ///
    /// A finished job reports nothing here even though its last reading is still in the
    /// snapshot. The menu bar is a live indicator: a pinned job that ended at 63% used to keep
    /// showing "63%" indefinitely, contradicting the popover, which had already moved it into a
    /// finished section and stopped drawing its bar. Returning nil falls back to the counts.
    public static func pinnedPercentText(snapshot: Snapshot, pinnedJobID: String?) -> String? {
        let candidate: Job?
        if let pinnedJobID {
            candidate = snapshot.jobs.first { $0.jobID == pinnedJobID }
        } else {
            // Without an explicit pin, follow the longest-running job that reports progress.
            candidate = snapshot.jobs
                .filter { $0.state == .running && $0.progress?.fraction != nil }
                .max { ($0.elapsedSeconds ?? 0) < ($1.elapsedSeconds ?? 0) }
        }
        guard let job = candidate,
              job.progressDisposition == .live,
              let fraction = job.progress?.fraction
        else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func accessibilityDescription(summary: JobSummary, connection: ConnectionState) -> String {
        var parts: [String] = ["SlurmBar"]
        parts.append("\(summary.running) running")
        parts.append("\(summary.pending) pending")
        if summary.failedRecently > 0 {
            parts.append("\(summary.failedRecently) recently failed")
        }
        if summary.cancelledRecently > 0 {
            parts.append("\(summary.cancelledRecently) recently cancelled")
        }
        if case .failed(let failure, _) = connection {
            parts.append(failure.title)
        }
        return parts.joined(separator: ", ")
    }
}
