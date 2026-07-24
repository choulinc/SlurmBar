import Foundation

/// A notification-worthy transition.
public struct JobEvent: Hashable, Identifiable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case completed
        case failed
        case timedOut
        case outOfMemory
        case progressStale
        case lossBecameNaN
        /// Not job-scoped: emitted once when a working connection starts failing.
        case connectionLost
    }

    public let kind: Kind
    public let jobID: String
    public let jobName: String
    public let clusterName: String
    public let detail: String?

    public var id: String { "\(clusterName)|\(jobID)|\(kind.rawValue)" }

    public init(kind: Kind, jobID: String, jobName: String, clusterName: String, detail: String? = nil) {
        self.kind = kind
        self.jobID = jobID
        self.jobName = jobName
        self.clusterName = clusterName
        self.detail = detail
    }

    public var title: String {
        switch kind {
        case .completed: return "Job completed"
        case .failed: return "Job failed"
        case .timedOut: return "Job timed out"
        case .outOfMemory: return "Job ran out of memory"
        case .progressStale: return "Progress stalled"
        case .lossBecameNaN: return "Loss became NaN"
        case .connectionLost: return "Cluster unreachable"
        }
    }

    public var body: String {
        if kind == .connectionLost {
            let base = "SlurmBar lost its connection to \(clusterName)."
            guard let detail, !detail.isEmpty else { return base }
            return "\(base) \(detail)"
        }
        let base = "\(jobName) (\(jobID)) on \(clusterName)"
        guard let detail, !detail.isEmpty else { return base }
        return "\(base) — \(detail)"
    }

    /// A connection event for `clusterName`, carrying the categorized SSH failure as detail.
    public static func connectionLost(clusterName: String, failure: SSHFailure) -> JobEvent {
        JobEvent(
            kind: .connectionLost,
            jobID: "-",
            jobName: clusterName,
            clusterName: clusterName,
            detail: failure.title
        )
    }
}

/// Turns a stream of snapshots into a stream of *transitions*.
///
/// Two rules keep this from becoming a notification firehose:
///
/// 1. **Baseline on first sight.** The first snapshot after launch records every job's state
///    without emitting anything. Otherwise every restart would replay the last day of
///    accounting history as fresh notifications.
/// 2. **Edge-triggered, once per job.** A job that is FAILED stays FAILED for hours of polling.
///    An event fires on the transition into that state and never again.
public final class JobEventDetector {
    private struct JobMemory {
        var state: JobState
        var progressStale: Bool
        var sawNaN: Bool
        var lastSeen: Date
    }

    private var memory: [String: JobMemory] = [:]
    private var hasBaseline = false
    private let clusterName: String
    /// How long a vanished job is remembered, so it is not re-notified if it reappears.
    private let forgetAfter: TimeInterval

    public init(clusterName: String, forgetAfter: TimeInterval = 24 * 3600) {
        self.clusterName = clusterName
        self.forgetAfter = forgetAfter
    }

    /// True until the first snapshot has been absorbed.
    public var needsBaseline: Bool { !hasBaseline }

    /// Absorb a snapshot and return the events worth notifying about.
    public func process(snapshot: Snapshot, now: Date = Date()) -> [JobEvent] {
        var events: [JobEvent] = []
        let establishingBaseline = !hasBaseline

        for job in snapshot.jobs {
            let previous = memory[job.jobID]
            let isStale = job.progress?.stale ?? false
            let hasNaN = job.progress?.hasNaNMetric ?? false

            if !establishingBaseline {
                events.append(contentsOf: transitions(for: job, previous: previous, isStale: isStale, hasNaN: hasNaN))
            }

            memory[job.jobID] = JobMemory(
                state: job.state,
                progressStale: isStale,
                // Latch NaN so a metric that flickers does not notify repeatedly.
                sawNaN: (previous?.sawNaN ?? false) || hasNaN,
                lastSeen: now
            )
        }

        memory = memory.filter { now.timeIntervalSince($0.value.lastSeen) < forgetAfter }
        hasBaseline = true
        return events
    }

    private func transitions(
        for job: Job,
        previous: JobMemory?,
        isStale: Bool,
        hasNaN: Bool
    ) -> [JobEvent] {
        var events: [JobEvent] = []

        // A job seen for the first time after the baseline is genuinely new to us. Only report
        // it if it is already finished — a newly submitted RUNNING job is not an event.
        let previousState = previous?.state
        if previousState != job.state, job.state.isFinished, previousState?.isFinished != true {
            if let kind = Self.kind(for: job) {
                events.append(JobEvent(
                    kind: kind,
                    jobID: job.jobID,
                    jobName: job.name,
                    clusterName: clusterName,
                    detail: Self.finishDetail(for: job)
                ))
            }
        }

        if isStale, previous?.progressStale == false, job.state == .running {
            events.append(JobEvent(
                kind: .progressStale,
                jobID: job.jobID,
                jobName: job.name,
                clusterName: clusterName,
                detail: job.progress?.updatedAt.map { "no update since \(Formatters.relativeTime(from: $0))" }
            ))
        }

        if hasNaN, previous?.sawNaN == false {
            let names = job.progress?.nanMetricNames ?? []
            events.append(JobEvent(
                kind: .lossBecameNaN,
                jobID: job.jobID,
                jobName: job.name,
                clusterName: clusterName,
                detail: names.isEmpty ? nil : names.joined(separator: ", ")
            ))
        }

        return events
    }

    private static func kind(for job: Job) -> JobEvent.Kind? {
        // A workload that reported its own failure is not a success, whatever exit status the
        // launcher handed back. Announcing "Job completed" for a run that logged a crash is
        // the most misleading thing this detector could do.
        if job.completionDisagreement == .reportedFailureButExitedClean { return .failed }

        switch job.state {
        case .completed: return .completed
        case .timeout, .deadline: return .timedOut
        case .outOfMemory: return .outOfMemory
        case .failed, .nodeFail, .bootFail: return .failed
        // A cancellation is almost always the user's own doing; notifying about it is noise.
        case .cancelled, .preempted: return nil
        default: return nil
        }
    }

    private static func finishDetail(for job: Job) -> String? {
        var parts: [String] = []
        if let elapsed = job.elapsedSeconds {
            parts.append("ran \(Formatters.duration(seconds: elapsed))")
        }
        if let exitCode = job.exitCode, exitCode != 0 {
            parts.append("exit \(exitCode)")
        }
        if let counter = job.progress?.counterDescription {
            switch job.progressDisposition {
            case .stoppedAt: parts.append("stopped at \(counter)")
            case .endedShortOfTarget: parts.append("ended at \(counter)")
            case .live, .reachedTarget, .none: break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Drop all memory, e.g. after the cluster profile changed.
    public func reset() {
        memory.removeAll()
        hasBaseline = false
    }
}
