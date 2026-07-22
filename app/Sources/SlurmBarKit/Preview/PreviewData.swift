#if DEBUG
import Foundation

/// Fixture data for SwiftUI previews and tests.
///
/// Wrapped in `#if DEBUG` on purpose: the shipping app must never be able to display invented
/// jobs. If a release build somehow rendered this, it would be indistinguishable from real
/// cluster state, which is precisely the failure mode this project cannot afford.
public enum PreviewData {
    public static let clusterProfile = ClusterProfile(
        displayName: "Example Cluster",
        sshAlias: "example-cluster",
        pollIntervalSeconds: 30
    )

    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso) ?? Date()
    }

    public static let runningTrainingJob = Job(
        jobID: "201551",
        name: "example-training",
        user: "exampleuser",
        account: "exampleaccount",
        partition: "gpu",
        state: .running,
        stateRaw: "RUNNING",
        submitTime: date("2026-07-22T00:00:00Z"),
        startTime: date("2026-07-22T00:10:00Z"),
        elapsedSeconds: 8400,
        timeLimitSeconds: 86400,
        nodes: ["example-gpu-017"],
        nodeCount: 1,
        cpus: 32,
        gpus: 1,
        stdoutPath: "/home/exampleuser/slurmbar-demo/logs/slurm-201551.out",
        stderrPath: "/home/exampleuser/slurmbar-demo/logs/slurm-201551.err",
        source: .squeue,
        resources: JobResources(
            memoryUsedBytes: 120_946_278_400,
            memoryLimitBytes: 274_877_906_944,
            memorySemantics: .peakRSS,
            memoryLimitSemantics: .requestedPerNode,
            gpuMemoryUsedBytes: 42_221_862_912,
            gpuUtilizationPercent: 87
        ),
        progress: JobProgress(
            source: .structuredFile,
            confidence: .high,
            kind: "training",
            phase: "train",
            current: 375,
            total: 1000,
            unit: "epoch",
            percent: 37.5,
            updatedAt: date("2026-07-22T02:29:55Z"),
            startedAt: date("2026-07-22T00:10:00Z"),
            stale: false,
            etaSeconds: 13993,
            completion: .running,
            metrics: [
                "loss": .number(0.059045),
                "learning_rate": .number(0.000034),
                "batch_current": .number(36),
                "batch_total": .number(94),
            ]
        )
    )

    public static let runningCounterJob = Job(
        jobID: "201570",
        name: "example-preprocess",
        user: "exampleuser",
        partition: "cpu",
        state: .running,
        stateRaw: "RUNNING",
        submitTime: date("2026-07-22T01:00:00Z"),
        startTime: date("2026-07-22T01:00:10Z"),
        elapsedSeconds: 5390,
        nodes: ["example-cpu-004", "example-cpu-005"],
        nodeCount: 2,
        cpus: 16,
        source: .squeue,
        resources: JobResources(
            memoryUsedBytes: 8_589_934_592,
            memoryLimitBytes: 68_719_476_736,
            memorySemantics: .peakRSS,
            memoryLimitSemantics: .requestedPerNode
        ),
        progress: JobProgress(
            source: .structuredFile,
            confidence: .high,
            kind: "preprocessing",
            phase: "shard",
            current: 4820,
            total: nil,
            unit: "file",
            message: "Converting parquet shards",
            updatedAt: date("2026-07-22T02:29:40Z"),
            stale: false,
            completion: .running
        )
    )

    public static let runningParsedJob = Job(
        jobID: "201580",
        name: "example-simulation",
        user: "exampleuser",
        partition: "compute",
        state: .running,
        stateRaw: "R",
        submitTime: date("2026-07-22T02:00:00Z"),
        startTime: date("2026-07-22T02:00:30Z"),
        elapsedSeconds: 1770,
        timeLimitSeconds: 43200,
        nodes: ["example-cpu-011"],
        nodeCount: 1,
        cpus: 8,
        source: .squeue,
        resources: JobResources(
            memoryLimitBytes: 17_179_869_184,
            memoryLimitSemantics: .requestedTotal
        ),
        progress: JobProgress(
            source: .logParser,
            confidence: .medium,
            current: 4300,
            total: 10000,
            unit: "timestep",
            percent: 43,
            updatedAt: date("2026-07-22T02:29:12Z"),
            stale: false,
            metrics: ["loss": .string("nan")]
        )
    )

    public static let staleProgressJob = Job(
        jobID: "201585",
        name: "example-stalled",
        user: "exampleuser",
        partition: "gpu",
        state: .running,
        stateRaw: "RUNNING",
        startTime: date("2026-07-21T20:00:00Z"),
        elapsedSeconds: 23400,
        timeLimitSeconds: 86400,
        nodes: ["example-gpu-019"],
        cpus: 16,
        gpus: 1,
        source: .squeue,
        resources: JobResources(memoryLimitBytes: 137_438_953_472, memoryLimitSemantics: .requestedPerNode),
        progress: JobProgress(
            source: .structuredFile,
            confidence: .high,
            kind: "training",
            phase: "train",
            current: 12,
            total: 400,
            unit: "epoch",
            percent: 3,
            updatedAt: date("2026-07-22T00:15:00Z"),
            stale: true,
            completion: .running
        )
    )

    public static let pendingJob = Job(
        jobID: "201560_7",
        arrayJobID: "201560",
        arrayTaskID: "7",
        name: "example-array",
        user: "exampleuser",
        partition: "gpu",
        state: .pending,
        stateRaw: "PENDING",
        reason: "Resources",
        submitTime: date("2026-07-22T00:10:00Z"),
        elapsedSeconds: 0,
        timeLimitSeconds: 14400,
        nodeCount: 1,
        cpus: 8,
        gpus: 1,
        source: .squeue,
        resources: JobResources(memoryLimitBytes: 4_294_967_296, memoryLimitSemantics: .requestedPerCPU)
    )

    public static let pendingQOSJob = Job(
        jobID: "201561",
        name: "example-evaluation",
        user: "exampleuser",
        partition: "gpu",
        state: .pending,
        stateRaw: "PENDING",
        reason: "QOSMaxJobsPerUserLimit",
        submitTime: date("2026-07-22T02:20:00Z"),
        elapsedSeconds: 0,
        timeLimitSeconds: 3600,
        cpus: 4,
        gpus: 1,
        source: .squeue
    )

    public static let completedJob = Job(
        jobID: "201540",
        name: "example-completed",
        user: "exampleuser",
        partition: "gpu",
        state: .completed,
        stateRaw: "COMPLETED",
        submitTime: date("2026-07-21T10:00:00Z"),
        startTime: date("2026-07-21T10:05:00Z"),
        endTime: date("2026-07-21T18:05:00Z"),
        elapsedSeconds: 28800,
        timeLimitSeconds: 86400,
        nodes: ["example-gpu-014"],
        nodeCount: 1,
        cpus: 32,
        gpus: 1,
        exitCode: 0,
        signal: 0,
        source: .sacct,
        resources: JobResources(
            memoryUsedBytes: 24_696_061_952,
            memoryLimitBytes: 274_877_906_944,
            memorySemantics: .peakRSSPerStep,
            memoryLimitSemantics: .requestedTotal
        )
    )

    public static let outOfMemoryJob = Job(
        jobID: "201546",
        name: "example-memory-test",
        user: "exampleuser",
        partition: "gpu",
        state: .outOfMemory,
        stateRaw: "OUT_OF_MEMORY",
        startTime: date("2026-07-21T13:01:00Z"),
        endTime: date("2026-07-21T13:22:00Z"),
        elapsedSeconds: 1260,
        timeLimitSeconds: 21600,
        nodes: ["example-gpu-016"],
        cpus: 8,
        gpus: 1,
        exitCode: 0,
        signal: 125,
        source: .sacct,
        resources: JobResources(
            memoryUsedBytes: 33_822_867_456,
            memoryLimitBytes: 34_359_738_368,
            memorySemantics: .peakRSSPerStep,
            memoryLimitSemantics: .requestedTotal
        )
    )

    public static let failedJob = Job(
        jobID: "201542",
        name: "example-failed",
        user: "exampleuser",
        partition: "gpu",
        state: .failed,
        stateRaw: "FAILED",
        startTime: date("2026-07-21T11:02:00Z"),
        endTime: date("2026-07-21T11:44:00Z"),
        elapsedSeconds: 2520,
        timeLimitSeconds: 43200,
        nodes: ["example-gpu-015"],
        cpus: 16,
        gpus: 1,
        exitCode: 1,
        signal: 0,
        source: .sacct,
        resources: JobResources(
            memoryUsedBytes: 4_294_967_296,
            memoryLimitBytes: 137_438_953_472,
            memorySemantics: .peakRSSPerStep,
            memoryLimitSemantics: .requestedTotal
        ),
        progress: JobProgress(
            source: .structuredFile,
            confidence: .high,
            kind: "training",
            current: 812,
            total: 1000,
            unit: "epoch",
            percent: 81.2,
            updatedAt: date("2026-07-21T11:43:58Z"),
            stale: false,
            completion: .failed,
            error: "RuntimeError: CUDA out of memory",
            metrics: ["loss": .string("nan")]
        )
    )

    public static let cluster = ClusterInfo(
        name: "examplecluster",
        hostname: "login01.example.org",
        slurmVersion: "slurm 23.11.7"
    )

    public static let snapshot = Snapshot(
        schemaVersion: 1,
        generatedAt: date("2026-07-22T02:30:00Z"),
        agentVersion: "0.1.0",
        cluster: cluster,
        summary: JobSummary(running: 4, pending: 2, completing: 0, failedRecently: 2, completedRecently: 1),
        jobs: [
            runningTrainingJob, runningCounterJob, runningParsedJob, staleProgressJob,
            pendingJob, pendingQOSJob,
            completedJob, outOfMemoryJob, failedJob,
        ],
        warnings: [
            AgentWarning(
                code: "SSTAT_FAILED",
                message: "Live memory usage is unavailable for running jobs.",
                severity: .info,
                detail: "sstat: error: no steps running for job 201580"
            )
        ]
    )

    public static let emptySnapshot = Snapshot(
        schemaVersion: 1,
        generatedAt: date("2026-07-22T02:30:00Z"),
        agentVersion: "0.1.0",
        cluster: cluster,
        summary: .empty,
        jobs: [],
        warnings: []
    )

    public static let degradedSnapshot = Snapshot(
        schemaVersion: 1,
        generatedAt: date("2026-07-22T02:30:00Z"),
        agentVersion: "0.1.0",
        cluster: ClusterInfo(name: nil, hostname: "login01.example.org", slurmVersion: nil),
        summary: JobSummary(running: 1, pending: 0, completing: 0, failedRecently: 0, completedRecently: 0),
        jobs: [runningParsedJob],
        warnings: [
            AgentWarning(
                code: "SQUEUE_JSON_UNSUPPORTED",
                message: "squeue --json is unavailable; using text output instead.",
                severity: .info
            ),
            AgentWarning(
                code: "SACCT_UNAVAILABLE",
                message: "sacct is not available; recently finished jobs cannot be shown.",
                severity: .warning,
                detail: "Slurm accounting (slurmdbd) may not be configured on this cluster."
            ),
            AgentWarning(
                code: "PROGRESS_DIR_MISSING",
                message: "No structured progress directory was found; epoch/batch details are unavailable.",
                severity: .info
            ),
        ]
    )

    public static let doctorReport = DoctorReport(
        schemaVersion: 1,
        generatedAt: date("2026-07-22T02:30:00Z"),
        agentVersion: "0.1.0",
        ok: true,
        hostname: "login01.example.org",
        pythonVersion: "3.9.18",
        checks: [
            DoctorCheck(id: "agent", title: "SlurmBar agent", status: .ok, value: "0.1.0"),
            DoctorCheck(id: "python", title: "Remote Python", status: .ok, value: "3.9.18"),
            DoctorCheck(id: "slurm_commands", title: "Slurm commands", status: .ok, value: "squeue, sacct, sstat"),
            DoctorCheck(id: "slurm_version", title: "Slurm version", status: .ok, value: "slurm 23.11.7"),
            DoctorCheck(id: "squeue", title: "squeue", status: .ok, value: "4 job(s) in queue"),
            DoctorCheck(id: "squeue_json", title: "squeue --json", status: .ok,
                        detail: "Structured queue output is available."),
            DoctorCheck(id: "sacct", title: "Accounting (sacct)", status: .ok, detail: "Job history is available."),
            DoctorCheck(id: "sstat", title: "Live usage (sstat)", status: .ok),
            DoctorCheck(id: "progress_dir", title: "Progress directory", status: .warn,
                        detail: "Not present yet. It is created the first time a job reports progress.",
                        value: "~/.local/state/slurmbar/jobs"),
        ]
    )

    public static let logTail = LogTail(
        jobID: "201551",
        stream: .stdout,
        path: "/home/exampleuser/slurmbar-demo/logs/slurm-201551.out",
        lines: (370...375).map {
            "Epoch \($0)/1000 | batch 94/94 | loss=0.0612\($0 % 10) | lr=0.000034 | 41.2s"
        },
        bytesRead: 131_072,
        fileSizeBytes: 48_213_904,
        truncated: true,
        modifiedAt: date("2026-07-22T02:29:58Z")
    )
}
#endif
