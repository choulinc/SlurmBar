import Foundation

/// What the menu bar item shows next to the icon.
public enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case counts
    case pinnedJobPercent

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .counts: return "Running and pending counts"
        case .pinnedJobPercent: return "Pinned job progress"
        }
    }

    public var explanation: String {
        switch self {
        case .iconOnly: return "Just the SlurmBar icon."
        case .counts: return "For example, 3R 2P."
        case .pinnedJobPercent: return "For example, 37%. Falls back to counts when no job is pinned."
        }
    }
}

/// Which transitions are worth interrupting the user for.
public struct NotificationPreferences: Codable, Hashable, Sendable {
    public var jobCompleted: Bool
    public var jobFailed: Bool
    public var jobTimedOut: Bool
    public var jobOutOfMemory: Bool
    public var progressStale: Bool
    public var connectionLost: Bool
    public var lossBecameNaN: Bool

    public init(
        jobCompleted: Bool = true,
        jobFailed: Bool = true,
        jobTimedOut: Bool = true,
        jobOutOfMemory: Bool = true,
        progressStale: Bool = false,
        connectionLost: Bool = false,
        lossBecameNaN: Bool = true
    ) {
        self.jobCompleted = jobCompleted
        self.jobFailed = jobFailed
        self.jobTimedOut = jobTimedOut
        self.jobOutOfMemory = jobOutOfMemory
        self.progressStale = progressStale
        self.connectionLost = connectionLost
        self.lossBecameNaN = lossBecameNaN
    }

    public static let `default` = NotificationPreferences()

    public func isEnabled(for event: JobEvent.Kind) -> Bool {
        switch event {
        case .completed: return jobCompleted
        case .failed: return jobFailed
        case .timedOut: return jobTimedOut
        case .outOfMemory: return jobOutOfMemory
        case .progressStale: return progressStale
        case .lossBecameNaN: return lossBecameNaN
        case .connectionLost: return connectionLost
        }
    }
}

/// Everything persisted outside of the cluster list.
public struct AppSettings: Codable, Hashable, Sendable {
    public var clusters: [ClusterProfile]
    public var selectedClusterID: UUID?
    public var menuBarDisplayMode: MenuBarDisplayMode
    public var pinnedJobID: String?
    public var launchAtLogin: Bool
    /// Whether the one-time "start at login?" prompt has been shown.
    public var didAskAboutLaunchAtLogin: Bool
    public var notifications: NotificationPreferences
    public var recentlyFinishedHours: Int
    /// Leave failed jobs out of the list and the counts.
    public var hideFailedJobs: Bool
    /// Leave cancelled and preempted jobs out of the list and the counts.
    public var hideCancelledJobs: Bool
    /// Jobs the user dismissed from the list, keyed by cluster id.
    ///
    /// Display-only, and bounded: a cluster keeps at most ``maxDismissedPerCluster`` ids so
    /// the settings file cannot grow without limit.
    public var dismissedJobIDs: [String: [String]]
    public var refreshWhenPopoverOpen: Bool
    public var pauseWhenNoActiveJobs: Bool
    public var showFailureIndicatorInMenuBar: Bool

    public init(
        clusters: [ClusterProfile] = [],
        selectedClusterID: UUID? = nil,
        menuBarDisplayMode: MenuBarDisplayMode = .counts,
        pinnedJobID: String? = nil,
        launchAtLogin: Bool = false,
        didAskAboutLaunchAtLogin: Bool = false,
        notifications: NotificationPreferences = .default,
        recentlyFinishedHours: Int = 24,
        hideFailedJobs: Bool = false,
        hideCancelledJobs: Bool = false,
        dismissedJobIDs: [String: [String]] = [:],
        refreshWhenPopoverOpen: Bool = true,
        pauseWhenNoActiveJobs: Bool = false,
        showFailureIndicatorInMenuBar: Bool = true
    ) {
        self.clusters = clusters
        self.selectedClusterID = selectedClusterID
        self.menuBarDisplayMode = menuBarDisplayMode
        self.pinnedJobID = pinnedJobID
        self.launchAtLogin = launchAtLogin
        self.didAskAboutLaunchAtLogin = didAskAboutLaunchAtLogin
        self.notifications = notifications
        self.recentlyFinishedHours = recentlyFinishedHours
        self.hideFailedJobs = hideFailedJobs
        self.hideCancelledJobs = hideCancelledJobs
        self.dismissedJobIDs = dismissedJobIDs
        self.refreshWhenPopoverOpen = refreshWhenPopoverOpen
        self.pauseWhenNoActiveJobs = pauseWhenNoActiveJobs
        self.showFailureIndicatorInMenuBar = showFailureIndicatorInMenuBar
    }

    public static let `default` = AppSettings()

    /// Cap on remembered dismissals per cluster.
    public static let maxDismissedPerCluster = 500

    public func dismissed(for clusterID: UUID) -> Set<String> {
        Set(dismissedJobIDs[clusterID.uuidString] ?? [])
    }

    /// Dismiss a job for one cluster, keeping the stored list bounded.
    public mutating func dismiss(jobID: String, clusterID: UUID) {
        var ids = dismissedJobIDs[clusterID.uuidString] ?? []
        guard !ids.contains(jobID) else { return }
        ids.append(jobID)
        if ids.count > AppSettings.maxDismissedPerCluster {
            ids.removeFirst(ids.count - AppSettings.maxDismissedPerCluster)
        }
        dismissedJobIDs[clusterID.uuidString] = ids
    }

    public mutating func dismiss(jobIDs: [String], clusterID: UUID) {
        for id in jobIDs { dismiss(jobID: id, clusterID: clusterID) }
    }

    public mutating func restoreDismissed(clusterID: UUID) {
        dismissedJobIDs[clusterID.uuidString] = nil
    }

    /// Forget dismissals for jobs the cluster no longer reports, so the list does not grow
    /// forever as old job ids age out of accounting.
    public mutating func pruneDismissed(clusterID: UUID, knownJobIDs: Set<String>) {
        guard let ids = dismissedJobIDs[clusterID.uuidString] else { return }
        let kept = ids.filter { knownJobIDs.contains($0) }
        if kept.isEmpty {
            dismissedJobIDs[clusterID.uuidString] = nil
        } else if kept.count != ids.count {
            dismissedJobIDs[clusterID.uuidString] = kept
        }
    }

    public var selectedCluster: ClusterProfile? {
        guard let selectedClusterID else { return clusters.first(where: \.isEnabled) ?? clusters.first }
        return clusters.first { $0.id == selectedClusterID } ?? clusters.first
    }

    public var hasConfiguredCluster: Bool { !clusters.isEmpty }

    /// Decoding tolerates a settings file written by an older build: every field has a default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clusters = try container.decodeIfPresent([ClusterProfile].self, forKey: .clusters) ?? []
        selectedClusterID = try container.decodeIfPresent(UUID.self, forKey: .selectedClusterID)
        menuBarDisplayMode = try container.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode) ?? .counts
        pinnedJobID = try container.decodeIfPresent(String.self, forKey: .pinnedJobID)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        didAskAboutLaunchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .didAskAboutLaunchAtLogin) ?? false
        notifications = try container.decodeIfPresent(NotificationPreferences.self, forKey: .notifications) ?? .default
        recentlyFinishedHours = try container.decodeIfPresent(Int.self, forKey: .recentlyFinishedHours) ?? 24
        hideFailedJobs = try container.decodeIfPresent(Bool.self, forKey: .hideFailedJobs) ?? false
        hideCancelledJobs = try container.decodeIfPresent(Bool.self, forKey: .hideCancelledJobs) ?? false
        dismissedJobIDs = try container.decodeIfPresent([String: [String]].self, forKey: .dismissedJobIDs) ?? [:]
        refreshWhenPopoverOpen = try container.decodeIfPresent(Bool.self, forKey: .refreshWhenPopoverOpen) ?? true
        pauseWhenNoActiveJobs = try container.decodeIfPresent(Bool.self, forKey: .pauseWhenNoActiveJobs) ?? false
        showFailureIndicatorInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showFailureIndicatorInMenuBar) ?? true
    }
}
