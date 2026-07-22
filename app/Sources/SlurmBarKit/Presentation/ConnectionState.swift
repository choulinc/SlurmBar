import Foundation

/// What the app currently knows about its ability to reach the cluster.
///
/// Deliberately distinct cases rather than one `error` bucket: the popover shows a different
/// banner, a different icon and different actions for "VPN is down" versus "the agent isn't
/// installed" versus "this cluster has no accounting".
public enum ConnectionState: Hashable, Sendable {
    /// No cluster configured yet.
    case unconfigured
    /// A refresh has never completed and none is running.
    case idle
    /// A refresh is in flight.
    case connecting
    /// The last refresh succeeded.
    case connected(at: Date)
    /// The last refresh failed. `hasCachedData` decides whether the popover shows stale jobs.
    case failed(SSHFailure, hasCachedData: Bool)

    public var isRefreshing: Bool {
        if case .connecting = self { return true }
        return false
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var failure: SSHFailure? {
        if case .failed(let failure, _) = self { return failure }
        return nil
    }

    public var lastSuccess: Date? {
        if case .connected(let date) = self { return date }
        return nil
    }

    public var shortLabel: String {
        switch self {
        case .unconfigured: return "Not configured"
        case .idle: return "Not connected"
        case .connecting: return "Refreshing…"
        case .connected: return "Connected"
        case .failed(let failure, let hasCache): return hasCache ? "Stale — \(failure.title)" : failure.title
        }
    }

    /// SF Symbols verified to exist on macOS 14.
    public var symbolName: String {
        switch self {
        case .unconfigured: return "gearshape"
        case .idle: return "circle.dashed"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle.fill"
        case .failed(let failure, _): return failure.symbolName
        }
    }
}

/// Why the popover is showing nothing, so the empty state can be specific.
public enum EmptyStateReason: Hashable, Sendable {
    case noClusterConfigured
    case neverRefreshed
    case noJobs
    case slurmUnavailable(String)
    case agentUnavailable(String)
    case disconnected(SSHFailure)

    public var title: String {
        switch self {
        case .noClusterConfigured: return "No cluster configured"
        case .neverRefreshed: return "Not connected yet"
        case .noJobs: return "No jobs"
        case .slurmUnavailable: return "Slurm unavailable"
        case .agentUnavailable: return "Agent unavailable"
        case .disconnected(let failure): return failure.title
        }
    }

    public var message: String {
        switch self {
        case .noClusterConfigured:
            return "Add a cluster in Settings using an SSH alias you already use in Terminal."
        case .neverRefreshed:
            return "Refresh to load your jobs from the cluster."
        case .noJobs:
            return "Nothing is queued, running, or recently finished for this user."
        case .slurmUnavailable(let detail):
            return detail
        case .agentUnavailable(let detail):
            return detail
        case .disconnected(let failure):
            return failure.message
        }
    }

    public var symbolName: String {
        switch self {
        case .noClusterConfigured: return "server.rack"
        case .neverRefreshed: return "arrow.clockwise"
        case .noJobs: return "tray"
        case .slurmUnavailable: return "exclamationmark.triangle"
        case .agentUnavailable: return "shippingbox"
        case .disconnected(let failure): return failure.symbolName
        }
    }
}

/// Reads the agent's structured warnings to decide which specific empty state applies.
public enum EmptyStateResolver {
    public static func resolve(
        snapshot: Snapshot?,
        connection: ConnectionState,
        hasClusters: Bool
    ) -> EmptyStateReason? {
        guard hasClusters else { return .noClusterConfigured }

        if case .failed(let failure, let hasCache) = connection, !hasCache {
            return .disconnected(failure)
        }

        guard let snapshot else {
            if case .connecting = connection { return nil }
            return .neverRefreshed
        }

        guard snapshot.jobs.isEmpty else { return nil }

        if let slurmMissing = snapshot.warnings.first(where: { $0.code == "SLURM_MISSING" }) {
            return .slurmUnavailable(slurmMissing.detail ?? slurmMissing.message)
        }
        if let squeueFailed = snapshot.warnings.first(where: { $0.code == "SQUEUE_FAILED" }) {
            return .slurmUnavailable(squeueFailed.detail ?? squeueFailed.message)
        }
        return .noJobs
    }
}
