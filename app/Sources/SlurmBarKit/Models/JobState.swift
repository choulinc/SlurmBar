import Foundation

/// Normalized job state.
///
/// Decoding never fails on an unrecognized value: a newer agent may introduce a state this
/// build has not heard of, and showing it as `unknown` alongside the preserved raw string beats
/// refusing the whole snapshot.
public enum JobState: String, Codable, Hashable, CaseIterable, Sendable {
    case pending = "PENDING"
    case running = "RUNNING"
    case suspended = "SUSPENDED"
    case completing = "COMPLETING"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
    case timeout = "TIMEOUT"
    case outOfMemory = "OUT_OF_MEMORY"
    case nodeFail = "NODE_FAIL"
    case preempted = "PREEMPTED"
    case bootFail = "BOOT_FAIL"
    case deadline = "DEADLINE"
    case requeued = "REQUEUED"
    case unknown = "UNKNOWN"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobState(rawValue: raw) ?? .unknown
    }

    /// Jobs the cluster is still working on.
    public var isActive: Bool {
        switch self {
        case .pending, .running, .suspended, .completing, .requeued: return true
        default: return false
        }
    }

    /// States that mean something went wrong, as opposed to a clean finish or a user cancel.
    public var isFailure: Bool {
        switch self {
        case .failed, .timeout, .outOfMemory, .nodeFail, .bootFail, .deadline: return true
        default: return false
        }
    }

    public var isFinished: Bool { !isActive }

    /// Short label for dense rows.
    public var shortLabel: String {
        switch self {
        case .pending: return "PD"
        case .running: return "R"
        case .suspended: return "S"
        case .completing: return "CG"
        case .completed: return "CD"
        case .failed: return "F"
        case .cancelled: return "CA"
        case .timeout: return "TO"
        case .outOfMemory: return "OOM"
        case .nodeFail: return "NF"
        case .preempted: return "PR"
        case .bootFail: return "BF"
        case .deadline: return "DL"
        case .requeued: return "RQ"
        case .unknown: return "?"
        }
    }

    public var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Running"
        case .suspended: return "Suspended"
        case .completing: return "Completing"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .timeout: return "Timed out"
        case .outOfMemory: return "Out of memory"
        case .nodeFail: return "Node failure"
        case .preempted: return "Preempted"
        case .bootFail: return "Boot failure"
        case .deadline: return "Deadline"
        case .requeued: return "Requeued"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbol name. All verified to exist on macOS 14.
    public var symbolName: String {
        switch self {
        case .running: return "play.circle.fill"
        case .pending: return "clock"
        case .suspended, .requeued: return "pause.circle"
        case .completing: return "hourglass"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .outOfMemory: return "memorychip"
        case .timeout, .deadline: return "clock.badge.exclamationmark"
        case .failed, .nodeFail, .bootFail: return "exclamationmark.triangle.fill"
        case .preempted: return "arrow.uturn.backward.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// How memory numbers should be read. Never rendered as a bare number in the UI.
public enum MemorySemantics: String, Codable, Hashable, Sendable {
    case peakRSS = "peak_rss"
    case peakRSSPerStep = "peak_rss_per_step"
    case currentRSS = "current_rss"
    case requestedTotal = "requested_total"
    case requestedPerNode = "requested_per_node"
    case requestedPerCPU = "requested_per_cpu"
    case unavailable = "unavailable"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MemorySemantics(rawValue: raw) ?? .unavailable
    }

    /// Short qualifier shown next to the value, e.g. "12.4 GB peak".
    public var shortLabel: String {
        switch self {
        case .peakRSS, .peakRSSPerStep: return "peak"
        case .currentRSS: return "current"
        case .requestedTotal: return "requested"
        case .requestedPerNode: return "per node"
        case .requestedPerCPU: return "per CPU"
        case .unavailable: return ""
        }
    }

    /// The honest long-form explanation used in the job detail view.
    public var explanation: String {
        switch self {
        case .peakRSS:
            return "Highest resident set size observed for a running step so far. Not the job's current live total."
        case .peakRSSPerStep:
            return "Highest resident set size of the largest single job step, from accounting. Not summed across nodes."
        case .currentRSS:
            return "Resident set size at the time of measurement."
        case .requestedTotal:
            return "Memory requested for the whole job."
        case .requestedPerNode:
            return "Memory requested per node. Multiply by the node count for the job total."
        case .requestedPerCPU:
            return "Memory requested per CPU. Multiply by the CPU count for the job total."
        case .unavailable:
            return "Not reported by Slurm for this job."
        }
    }
}

/// Where a progress reading came from. Determines how much the UI is allowed to claim.
public enum ProgressSource: String, Codable, Hashable, Sendable {
    case structuredFile = "structured_file"
    case logParser = "log_parser"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProgressSource(rawValue: raw) ?? .logParser
    }

    public var isAuthoritative: Bool { self == .structuredFile }
}

public enum ProgressConfidence: String, Codable, Hashable, Sendable {
    case high, medium, low

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProgressConfidence(rawValue: raw) ?? .low
    }
}

public enum ProgressCompletion: String, Codable, Hashable, Sendable {
    case running, completed, failed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProgressCompletion(rawValue: raw) ?? .running
    }
}
