import Foundation

/// A complete picture of one cluster at one moment, as produced by `slurmbar-agent snapshot`.
public struct Snapshot: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let agentVersion: String?
    public let cluster: ClusterInfo
    public let summary: JobSummary
    public let jobs: [Job]
    public let warnings: [AgentWarning]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case agentVersion = "agent_version"
        case cluster, summary, jobs, warnings
    }

    public init(
        schemaVersion: Int,
        generatedAt: Date,
        agentVersion: String? = nil,
        cluster: ClusterInfo,
        summary: JobSummary,
        jobs: [Job],
        warnings: [AgentWarning] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.agentVersion = agentVersion
        self.cluster = cluster
        self.summary = summary
        self.jobs = jobs
        self.warnings = warnings
    }

    public var activeJobs: [Job] { jobs.filter { $0.state.isActive } }
    public var hasBlockingWarning: Bool { warnings.contains { $0.severity == .error } }
}

public struct ClusterInfo: Codable, Hashable, Sendable {
    public let name: String?
    public let hostname: String?
    public let slurmVersion: String?

    enum CodingKeys: String, CodingKey {
        case name, hostname
        case slurmVersion = "slurm_version"
    }

    public init(name: String?, hostname: String?, slurmVersion: String?) {
        self.name = name
        self.hostname = hostname
        self.slurmVersion = slurmVersion
    }
}

public struct JobSummary: Codable, Hashable, Sendable {
    public let running: Int
    public let pending: Int
    public let completing: Int
    public let failedRecently: Int
    /// Cancelled or preempted. Split out from ``failedRecently`` so that the two together
    /// account for the whole "Failed & cancelled" section; before the split, cancellations
    /// were counted in no cell at all and the strip silently understated the section.
    public let cancelledRecently: Int
    public let completedRecently: Int

    enum CodingKeys: String, CodingKey {
        case running, pending, completing
        case failedRecently = "failed_recently"
        case cancelledRecently = "cancelled_recently"
        case completedRecently = "completed_recently"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        running = try container.decode(Int.self, forKey: .running)
        pending = try container.decode(Int.self, forKey: .pending)
        completing = try container.decode(Int.self, forKey: .completing)
        failedRecently = try container.decode(Int.self, forKey: .failedRecently)
        // Absent from agents older than this field. Zero is the honest default: an old agent
        // did not tell us, and inventing a number would be worse than showing none.
        cancelledRecently = try container.decodeIfPresent(Int.self, forKey: .cancelledRecently) ?? 0
        completedRecently = try container.decode(Int.self, forKey: .completedRecently)
    }

    public init(
        running: Int,
        pending: Int,
        completing: Int,
        failedRecently: Int,
        cancelledRecently: Int = 0,
        completedRecently: Int
    ) {
        self.running = running
        self.pending = pending
        self.completing = completing
        self.failedRecently = failedRecently
        self.cancelledRecently = cancelledRecently
        self.completedRecently = completedRecently
    }

    /// Everything in the "Failed & cancelled" section.
    public var unsuccessfulRecently: Int { failedRecently + cancelledRecently }

    public static let empty = JobSummary(
        running: 0, pending: 0, completing: 0,
        failedRecently: 0, cancelledRecently: 0, completedRecently: 0
    )
}

public struct Job: Codable, Hashable, Identifiable, Sendable {
    public let jobID: String
    /// The id Slurm uses internally; differs from ``jobID`` for array tasks.
    public let slurmJobID: String?
    public let arrayJobID: String?
    public let arrayTaskID: String?
    public let name: String
    public let user: String?
    public let account: String?
    public let partition: String?
    public let qos: String?
    public let state: JobState
    public let stateRaw: String?
    public let reason: String?
    public let submitTime: Date?
    public let startTime: Date?
    public let endTime: Date?
    public let elapsedSeconds: Int?
    public let timeLimitSeconds: Int?
    public let nodes: [String]
    public let nodeCount: Int?
    public let cpus: Int?
    public let gpus: Int?
    public let workDir: String?
    public let stdoutPath: String?
    public let stderrPath: String?
    public let exitCode: Int?
    public let signal: Int?
    public let source: JobSource?
    public let resources: JobResources
    public let progress: JobProgress?

    public var id: String { jobID }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case slurmJobID = "slurm_job_id"
        case arrayJobID = "array_job_id"
        case arrayTaskID = "array_task_id"
        case name, user, account, partition, qos, state
        case stateRaw = "state_raw"
        case reason
        case submitTime = "submit_time"
        case startTime = "start_time"
        case endTime = "end_time"
        case elapsedSeconds = "elapsed_seconds"
        case timeLimitSeconds = "time_limit_seconds"
        case nodes
        case nodeCount = "node_count"
        case cpus, gpus
        case workDir = "work_dir"
        case stdoutPath = "stdout_path"
        case stderrPath = "stderr_path"
        case exitCode = "exit_code"
        case signal, source, resources, progress
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(String.self, forKey: .jobID)
        slurmJobID = try container.decodeIfPresent(String.self, forKey: .slurmJobID)
        arrayJobID = try container.decodeIfPresent(String.self, forKey: .arrayJobID)
        arrayTaskID = try container.decodeIfPresent(String.self, forKey: .arrayTaskID)
        // Names come from a remote machine and land in the UI, so they are sanitized on entry.
        name = SanitizedText.clean(try container.decode(String.self, forKey: .name), limit: 200)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        partition = try container.decodeIfPresent(String.self, forKey: .partition)
        qos = try container.decodeIfPresent(String.self, forKey: .qos)
        state = try container.decode(JobState.self, forKey: .state)
        stateRaw = try container.decodeIfPresent(String.self, forKey: .stateRaw)
        reason = try container.decodeIfPresent(String.self, forKey: .reason).map {
            SanitizedText.clean($0, limit: 200)
        }
        submitTime = try container.decodeIfPresent(Date.self, forKey: .submitTime)
        startTime = try container.decodeIfPresent(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        elapsedSeconds = try container.decodeIfPresent(Int.self, forKey: .elapsedSeconds)
        timeLimitSeconds = try container.decodeIfPresent(Int.self, forKey: .timeLimitSeconds)
        nodes = try container.decodeIfPresent([String].self, forKey: .nodes) ?? []
        nodeCount = try container.decodeIfPresent(Int.self, forKey: .nodeCount)
        cpus = try container.decodeIfPresent(Int.self, forKey: .cpus)
        gpus = try container.decodeIfPresent(Int.self, forKey: .gpus)
        workDir = try container.decodeIfPresent(String.self, forKey: .workDir)
        stdoutPath = try container.decodeIfPresent(String.self, forKey: .stdoutPath)
        stderrPath = try container.decodeIfPresent(String.self, forKey: .stderrPath)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        signal = try container.decodeIfPresent(Int.self, forKey: .signal)
        source = try container.decodeIfPresent(JobSource.self, forKey: .source)
        resources = try container.decodeIfPresent(JobResources.self, forKey: .resources) ?? .unavailable
        progress = try container.decodeIfPresent(JobProgress.self, forKey: .progress)
    }

    public init(
        jobID: String,
        slurmJobID: String? = nil,
        arrayJobID: String? = nil,
        arrayTaskID: String? = nil,
        name: String,
        user: String? = nil,
        account: String? = nil,
        partition: String? = nil,
        qos: String? = nil,
        state: JobState,
        stateRaw: String? = nil,
        reason: String? = nil,
        submitTime: Date? = nil,
        startTime: Date? = nil,
        endTime: Date? = nil,
        elapsedSeconds: Int? = nil,
        timeLimitSeconds: Int? = nil,
        nodes: [String] = [],
        nodeCount: Int? = nil,
        cpus: Int? = nil,
        gpus: Int? = nil,
        workDir: String? = nil,
        stdoutPath: String? = nil,
        stderrPath: String? = nil,
        exitCode: Int? = nil,
        signal: Int? = nil,
        source: JobSource? = nil,
        resources: JobResources = .unavailable,
        progress: JobProgress? = nil
    ) {
        self.jobID = jobID
        self.slurmJobID = slurmJobID
        self.arrayJobID = arrayJobID
        self.arrayTaskID = arrayTaskID
        self.name = name
        self.user = user
        self.account = account
        self.partition = partition
        self.qos = qos
        self.state = state
        self.stateRaw = stateRaw
        self.reason = reason
        self.submitTime = submitTime
        self.startTime = startTime
        self.endTime = endTime
        self.elapsedSeconds = elapsedSeconds
        self.timeLimitSeconds = timeLimitSeconds
        self.nodes = nodes
        self.nodeCount = nodeCount
        self.cpus = cpus
        self.gpus = gpus
        self.workDir = workDir
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
        self.exitCode = exitCode
        self.signal = signal
        self.source = source
        self.resources = resources
        self.progress = progress
    }

    /// True when the job is an array task rather than a standalone job.
    public var isArrayTask: Bool { arrayTaskID != nil }

    /// Fraction of the time limit consumed, or nil when there is no limit.
    public var timeLimitFraction: Double? {
        guard let limit = timeLimitSeconds, limit > 0, let elapsed = elapsedSeconds else { return nil }
        return min(1.0, Double(elapsed) / Double(limit))
    }

    /// Seconds remaining before Slurm kills the job, when a limit exists.
    public var remainingTimeSeconds: Int? {
        guard let limit = timeLimitSeconds, let elapsed = elapsedSeconds else { return nil }
        return max(0, limit - elapsed)
    }

    /// A one-line resource summary such as "32 CPU · 1 GPU · 2 nodes".
    public var resourceSummary: String {
        var parts: [String] = []
        if let cpus, cpus > 0 { parts.append("\(cpus) CPU") }
        if let gpus, gpus > 0 { parts.append("\(gpus) GPU") }
        if let nodeCount, nodeCount > 1 { parts.append("\(nodeCount) nodes") }
        return parts.joined(separator: " · ")
    }

    /// How this job ended, as far as Slurm is concerned. The one place that decides.
    public var outcome: JobOutcome {
        if state.isActive { return .active }
        if state == .completed { return .succeeded }
        if state.isFailure { return .failed }
        if state == .cancelled || state == .preempted { return .cancelled }
        return .indeterminate
    }

    /// What to do with this job's progress reading.
    ///
    /// Reconciles two witnesses that answer different questions: Slurm knows how the process
    /// exited, the workload knows whether the work finished. See ``ProgressDisposition``.
    public var progressDisposition: ProgressDisposition {
        guard let progress, progress.current != nil || progress.percent != nil else { return .none }
        guard outcome.isFinished else { return .live }

        switch progress.completion {
        case .completed:
            // The workload said so itself. This is the only signal that can tell an
            // early-stopped run from a truncated one, and it outranks the counter: a run that
            // stops at epoch 284 of 300 because validation loss plateaued *did* finish.
            return .reachedTarget
        case .failed:
            return .stoppedAt
        case .running, nil:
            // No declaration — either the workload does not use slurmbar_progress, or it died
            // before it could report. Fall back to Slurm's verdict plus the counter.
            guard outcome == .succeeded else { return .stoppedAt }
            guard let current = progress.current, let total = progress.total, total > 0 else {
                // Nothing to fall short of.
                return .reachedTarget
            }
            return current >= total - 1e-9 ? .reachedTarget : .endedShortOfTarget
        }
    }

    /// A conflict between Slurm's record and the workload's own report, when there is one.
    public var completionDisagreement: CompletionDisagreement? {
        guard let progress, progress.source.isAuthoritative, outcome.isFinished else { return nil }
        switch (progress.completion, outcome) {
        case (.failed, .succeeded):
            return .reportedFailureButExitedClean
        case (.completed, .failed):
            return .reportedSuccessButJobFailed
        case (.running, .succeeded), (.running, .failed), (.running, .cancelled):
            // Only worth mentioning if the workload was actually mid-run: a reporter that
            // reached its total and simply never wrote a final status has not lost anything.
            guard let current = progress.current, let total = progress.total, total > 0,
                  current < total - 1e-9
            else { return nil }
            return .endedWhileStillReporting
        default:
            return nil
        }
    }

    /// Whether a determinate progress bar should be drawn for this job.
    public var showsProgressBar: Bool {
        guard progress?.fraction != nil else { return false }
        return progressDisposition.showsBar
    }

    /// The fraction to draw, which is 1.0 for a run known to have reached its target even when
    /// its last counter reading was short.
    public var displayedProgressFraction: Double? {
        guard showsProgressBar, let fraction = progress?.fraction else { return nil }
        return progressDisposition.barIsComplete ? 1.0 : fraction
    }

    /// A copy carrying a different progress reading. Used by ``ProgressCarryForward``.
    public func replacingProgress(_ progress: JobProgress?) -> Job {
        Job(
            jobID: jobID, slurmJobID: slurmJobID, arrayJobID: arrayJobID, arrayTaskID: arrayTaskID,
            name: name, user: user, account: account, partition: partition, qos: qos,
            state: state, stateRaw: stateRaw, reason: reason,
            submitTime: submitTime, startTime: startTime, endTime: endTime,
            elapsedSeconds: elapsedSeconds, timeLimitSeconds: timeLimitSeconds,
            nodes: nodes, nodeCount: nodeCount, cpus: cpus, gpus: gpus,
            workDir: workDir, stdoutPath: stdoutPath, stderrPath: stderrPath,
            exitCode: exitCode, signal: signal, source: source,
            resources: resources, progress: progress
        )
    }

    /// The node list, collapsed for display when a job spans many nodes.
    public var nodeSummary: String? {
        guard !nodes.isEmpty else { return nil }
        if nodes.count <= 2 { return nodes.joined(separator: ", ") }
        return "\(nodes[0]) +\(nodes.count - 1)"
    }
}

public enum JobSource: String, Codable, Hashable, Sendable {
    case squeue, sacct

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobSource(rawValue: raw) ?? .squeue
    }
}

public struct JobResources: Codable, Hashable, Sendable {
    public let memoryUsedBytes: Int64?
    public let memoryLimitBytes: Int64?
    public let memorySemantics: MemorySemantics
    public let memoryLimitSemantics: MemorySemantics
    public let gpuMemoryUsedBytes: Int64?
    public let gpuMemoryLimitBytes: Int64?
    public let gpuUtilizationPercent: Double?
    public let cpuUtilizationPercent: Double?

    enum CodingKeys: String, CodingKey {
        case memoryUsedBytes = "memory_used_bytes"
        case memoryLimitBytes = "memory_limit_bytes"
        case memorySemantics = "memory_semantics"
        case memoryLimitSemantics = "memory_limit_semantics"
        case gpuMemoryUsedBytes = "gpu_memory_used_bytes"
        case gpuMemoryLimitBytes = "gpu_memory_limit_bytes"
        case gpuUtilizationPercent = "gpu_utilization_percent"
        case cpuUtilizationPercent = "cpu_utilization_percent"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memoryUsedBytes = try container.decodeIfPresent(Int64.self, forKey: .memoryUsedBytes)
        memoryLimitBytes = try container.decodeIfPresent(Int64.self, forKey: .memoryLimitBytes)
        memorySemantics = try container.decodeIfPresent(MemorySemantics.self, forKey: .memorySemantics) ?? .unavailable
        memoryLimitSemantics = try container.decodeIfPresent(MemorySemantics.self, forKey: .memoryLimitSemantics) ?? .unavailable
        gpuMemoryUsedBytes = try container.decodeIfPresent(Int64.self, forKey: .gpuMemoryUsedBytes)
        gpuMemoryLimitBytes = try container.decodeIfPresent(Int64.self, forKey: .gpuMemoryLimitBytes)
        gpuUtilizationPercent = try container.decodeIfPresent(Double.self, forKey: .gpuUtilizationPercent)
        cpuUtilizationPercent = try container.decodeIfPresent(Double.self, forKey: .cpuUtilizationPercent)
    }

    public init(
        memoryUsedBytes: Int64? = nil,
        memoryLimitBytes: Int64? = nil,
        memorySemantics: MemorySemantics = .unavailable,
        memoryLimitSemantics: MemorySemantics = .unavailable,
        gpuMemoryUsedBytes: Int64? = nil,
        gpuMemoryLimitBytes: Int64? = nil,
        gpuUtilizationPercent: Double? = nil,
        cpuUtilizationPercent: Double? = nil
    ) {
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.memorySemantics = memorySemantics
        self.memoryLimitSemantics = memoryLimitSemantics
        self.gpuMemoryUsedBytes = gpuMemoryUsedBytes
        self.gpuMemoryLimitBytes = gpuMemoryLimitBytes
        self.gpuUtilizationPercent = gpuUtilizationPercent
        self.cpuUtilizationPercent = cpuUtilizationPercent
    }

    public static let unavailable = JobResources()

    public var hasAnyMemoryInformation: Bool { memoryUsedBytes != nil || memoryLimitBytes != nil }

    /// Used/limit as a fraction — but only when the two numbers are actually comparable.
    ///
    /// A per-CPU or per-node request is not a job-wide ceiling, so filling a bar against it
    /// would be a lie. Those cases return nil and the UI shows the numbers without a bar.
    public var memoryFraction: Double? {
        guard let used = memoryUsedBytes, let limit = memoryLimitBytes, limit > 0 else { return nil }
        switch memoryLimitSemantics {
        case .requestedTotal, .requestedPerNode:
            return min(1.0, Double(used) / Double(limit))
        default:
            return nil
        }
    }
}

public struct JobProgress: Codable, Hashable, Sendable {
    public let source: ProgressSource
    public let confidence: ProgressConfidence?
    public let kind: String?
    public let phase: String?
    public let current: Double?
    public let total: Double?
    public let unit: String?
    public let percent: Double?
    public let message: String?
    public let updatedAt: Date?
    public let startedAt: Date?
    public let stale: Bool
    public let etaSeconds: Int?
    public let completion: ProgressCompletion?
    public let error: String?
    public let metrics: [String: MetricValue]
    /// True when this reading was kept from an earlier poll rather than measured in this one.
    ///
    /// App-local: the agent never sends it. It rides along in the snapshot cache so a relaunch
    /// does not lose the distinction, and it exists so nothing presents a remembered number as
    /// a current one.
    public let carriedForward: Bool

    enum CodingKeys: String, CodingKey {
        case source, confidence, kind, phase, current, total, unit, percent, message
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case stale
        case etaSeconds = "eta_seconds"
        case completion, error, metrics
        case carriedForward = "carried_forward"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(ProgressSource.self, forKey: .source)
        confidence = try container.decodeIfPresent(ProgressConfidence.self, forKey: .confidence)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        phase = try container.decodeIfPresent(String.self, forKey: .phase).map { SanitizedText.clean($0, limit: 60) }
        current = try container.decodeIfPresent(Double.self, forKey: .current)
        total = try container.decodeIfPresent(Double.self, forKey: .total)
        unit = try container.decodeIfPresent(String.self, forKey: .unit).map { SanitizedText.clean($0, limit: 30) }
        percent = try container.decodeIfPresent(Double.self, forKey: .percent)
        message = try container.decodeIfPresent(String.self, forKey: .message).map { SanitizedText.clean($0, limit: 300) }
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        stale = try container.decodeIfPresent(Bool.self, forKey: .stale) ?? false
        etaSeconds = try container.decodeIfPresent(Int.self, forKey: .etaSeconds)
        completion = try container.decodeIfPresent(ProgressCompletion.self, forKey: .completion)
        error = try container.decodeIfPresent(String.self, forKey: .error).map { SanitizedText.clean($0, limit: 500) }
        metrics = try container.decodeIfPresent([String: MetricValue].self, forKey: .metrics) ?? [:]
        carriedForward = try container.decodeIfPresent(Bool.self, forKey: .carriedForward) ?? false
    }

    public init(
        source: ProgressSource,
        confidence: ProgressConfidence? = nil,
        kind: String? = nil,
        phase: String? = nil,
        current: Double? = nil,
        total: Double? = nil,
        unit: String? = nil,
        percent: Double? = nil,
        message: String? = nil,
        updatedAt: Date? = nil,
        startedAt: Date? = nil,
        stale: Bool = false,
        etaSeconds: Int? = nil,
        completion: ProgressCompletion? = nil,
        error: String? = nil,
        metrics: [String: MetricValue] = [:],
        carriedForward: Bool = false
    ) {
        self.source = source
        self.confidence = confidence
        self.kind = kind
        self.phase = phase
        self.current = current
        self.total = total
        self.unit = unit
        self.percent = percent
        self.message = message
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.stale = stale
        self.etaSeconds = etaSeconds
        self.completion = completion
        self.error = error
        self.metrics = metrics
        self.carriedForward = carriedForward
    }

    /// This reading, marked as remembered rather than measured.
    ///
    /// The ETA is dropped: it was extrapolated from a throughput that has since stopped, and
    /// "3h remaining" on a job that already ended is the most confidently wrong thing the UI
    /// could say.
    public func asCarriedForward() -> JobProgress {
        JobProgress(
            source: source, confidence: confidence, kind: kind, phase: phase,
            current: current, total: total, unit: unit, percent: percent, message: message,
            updatedAt: updatedAt, startedAt: startedAt, stale: stale,
            etaSeconds: nil, completion: completion, error: error, metrics: metrics,
            carriedForward: true
        )
    }

    /// Fraction in 0…1 for a determinate progress bar, or nil when the total is unknown.
    ///
    /// The agent already computes `percent`; recomputing from current/total here is the
    /// fallback for payloads where only the counters are present.
    public var fraction: Double? {
        if let percent { return min(1.0, max(0.0, percent / 100.0)) }
        guard let current, let total, total > 0 else { return nil }
        return min(1.0, max(0.0, current / total))
    }

    /// "375 / 1000 epochs", or "4,820 files" when the total is unknown.
    public var counterDescription: String? {
        guard let current else { return nil }
        let unitLabel = unit.map { " \($0)\(pluralSuffix)" } ?? ""
        if let total {
            return "\(Formatters.count(current)) / \(Formatters.count(total))\(unitLabel)"
        }
        return "\(Formatters.count(current))\(unitLabel)"
    }

    private var pluralSuffix: String {
        guard let unit, !unit.isEmpty else { return "" }
        let value = total ?? current ?? 0
        return value == 1 ? "" : "s"
    }

    /// True when the workload reported a NaN in any metric — the "loss became NaN" signal.
    public var hasNaNMetric: Bool { metrics.values.contains { $0.isNaN } }

    public var nanMetricNames: [String] {
        metrics.filter { $0.value.isNaN }.keys.sorted()
    }

    /// Metrics worth putting on a dense job row, in a stable, meaningful order.
    public func highlightedMetrics(limit: Int = 3) -> [(key: String, value: MetricValue)] {
        let preferred = ["loss", "val_loss", "accuracy", "learning_rate", "residual"]
        var chosen: [(key: String, value: MetricValue)] = []
        for key in preferred {
            if let value = metrics[key] { chosen.append((key, value)) }
            if chosen.count == limit { return chosen }
        }
        let skipped = Set(preferred + ["batch_current", "batch_total"])
        for key in metrics.keys.sorted() where !skipped.contains(key) {
            if let value = metrics[key] { chosen.append((key, value)) }
            if chosen.count == limit { break }
        }
        return chosen
    }

    /// Batch-level sub-progress, when the workload reported it.
    public var batchDescription: String? {
        guard let current = metrics["batch_current"]?.doubleValue else { return nil }
        if let total = metrics["batch_total"]?.doubleValue {
            return "batch \(Formatters.count(current))/\(Formatters.count(total))"
        }
        return "batch \(Formatters.count(current))"
    }
}

public struct AgentWarning: Codable, Hashable, Identifiable, Sendable {
    public enum Severity: String, Codable, Hashable, Sendable {
        case info, warning, error

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Severity(rawValue: raw) ?? .warning
        }
    }

    public let code: String
    public let message: String
    public let severity: Severity
    public let detail: String?
    public let jobID: String?

    public var id: String { "\(code)|\(jobID ?? "")|\(message)" }

    enum CodingKeys: String, CodingKey {
        case code, message, severity, detail
        case jobID = "job_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = SanitizedText.clean(try container.decode(String.self, forKey: .message), limit: 400)
        severity = try container.decodeIfPresent(Severity.self, forKey: .severity) ?? .warning
        detail = try container.decodeIfPresent(String.self, forKey: .detail).map {
            SanitizedText.clean($0, limit: 800)
        }
        jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
    }

    public init(code: String, message: String, severity: Severity = .warning, detail: String? = nil, jobID: String? = nil) {
        self.code = code
        self.message = message
        self.severity = severity
        self.detail = detail
        self.jobID = jobID
    }

    /// SF Symbol for the severity. Verified to exist on macOS 14.
    public var symbolName: String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}
