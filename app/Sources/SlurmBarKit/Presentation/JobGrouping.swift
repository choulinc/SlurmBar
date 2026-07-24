import Foundation

/// The three sections of the popover.
public enum JobGroup: String, CaseIterable, Identifiable, Sendable {
    case running
    case pending
    /// Finished cleanly.
    case completed
    /// Failed, timed out, ran out of memory, or was cancelled.
    ///
    /// Kept apart from `completed` because the two demand different attention: a completed run
    /// is a result to collect, an unsuccessful one is something to look into. Mixing them in
    /// one list buries the failures among the successes.
    case unsuccessful

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .running: return "Running"
        case .pending: return "Pending"
        case .completed: return "Completed"
        case .unsuccessful: return "Failed & cancelled"
        }
    }

    public var symbolName: String {
        switch self {
        case .running: return "play.circle"
        case .pending: return "clock"
        case .completed: return "checkmark.circle"
        case .unsuccessful: return "exclamationmark.triangle"
        }
    }

    /// True for the two finished groups, which share row rendering and removal actions.
    public var isFinished: Bool { self == .completed || self == .unsuccessful }
}

/// Which finished jobs to leave out of the list entirely.
///
/// Hidden jobs are excluded from the counts as well as the list. A summary that says
/// "3 failed" above a list showing none is worse than not showing the number at all.
public struct JobDisplayFilter: Hashable, Sendable {
    public var hideFailed: Bool
    public var hideCancelled: Bool
    /// Finished jobs older than this are neither shown nor counted.
    public var recentHours: Int
    /// Individually dismissed jobs, by job id.
    ///
    /// Dismissing only affects this Mac's display — it never touches the job on the cluster.
    /// A finished job cannot be "deleted" from Slurm's accounting, and pretending otherwise
    /// would be a lie about what the button did.
    public var dismissedJobIDs: Set<String>

    public init(
        hideFailed: Bool = false,
        hideCancelled: Bool = false,
        recentHours: Int = 24,
        dismissedJobIDs: Set<String> = []
    ) {
        self.hideFailed = hideFailed
        self.hideCancelled = hideCancelled
        self.recentHours = recentHours
        self.dismissedJobIDs = dismissedJobIDs
    }

    public static let `default` = JobDisplayFilter()

    /// True when this job should be left out of both the list and the counts.
    public func hides(_ job: Job) -> Bool {
        if dismissedJobIDs.contains(job.jobID) { return true }
        if hideFailed, job.state.isFailure { return true }
        if hideCancelled, job.state == .cancelled || job.state == .preempted { return true }
        return false
    }
}

public struct GroupedJobs: Hashable, Sendable {
    public let running: [Job]
    public let pending: [Job]
    public let completed: [Job]
    public let unsuccessful: [Job]

    public init(running: [Job], pending: [Job], completed: [Job], unsuccessful: [Job]) {
        self.running = running
        self.pending = pending
        self.completed = completed
        self.unsuccessful = unsuccessful
    }

    /// Convenience for callers that do not care how a finished job ended.
    public init(running: [Job], pending: [Job], recentlyFinished: [Job]) {
        self.init(
            running: running,
            pending: pending,
            completed: recentlyFinished.filter { $0.state == .completed },
            unsuccessful: recentlyFinished.filter { $0.state != .completed }
        )
    }

    public static let empty = GroupedJobs(running: [], pending: [], completed: [], unsuccessful: [])

    /// Every finished job, whichever way it ended.
    public var recentlyFinished: [Job] { completed + unsuccessful }

    public var isEmpty: Bool {
        running.isEmpty && pending.isEmpty && completed.isEmpty && unsuccessful.isEmpty
    }
    public var totalCount: Int {
        running.count + pending.count + completed.count + unsuccessful.count
    }

    public func jobs(in group: JobGroup) -> [Job] {
        switch group {
        case .running: return running
        case .pending: return pending
        case .completed: return completed
        case .unsuccessful: return unsuccessful
        }
    }

    /// Counts derived from exactly these jobs.
    ///
    /// The agent's own summary covers everything it fetched, which is a wider window than the
    /// popover displays and ignores the user's hide settings. Recomputing here is what keeps
    /// the summary strip, the menu bar counts and the visible list telling the same story.
    public var summary: JobSummary {
        var running = 0
        var completing = 0
        for job in self.running {
            if job.state == .completing { completing += 1 } else { running += 1 }
        }
        // Every unsuccessful job lands in exactly one of the two counts, so the section header
        // and the summary strip can never disagree about how many jobs are in that section.
        var failed = 0
        var cancelled = 0
        for job in unsuccessful {
            // `indeterminate` is counted as failed rather than cancelled: an unclassifiable
            // finished state is not evidence that somebody stopped it on purpose.
            if job.outcome == .cancelled { cancelled += 1 } else { failed += 1 }
        }
        return JobSummary(
            running: running,
            pending: pending.count,
            completing: completing,
            failedRecently: failed,
            cancelledRecently: cancelled,
            completedRecently: self.completed.count
        )
    }
}

/// Splits and orders jobs for display.
public enum JobGrouper {
    /// Group jobs, dropping finished jobs older than `recentHours`.
    ///
    /// Sort orders are chosen for what a user scans for in each section:
    /// * running — longest-running first, because those are closest to a time limit;
    /// * pending — longest-waiting first;
    /// * finished — most recently finished first, and failures ahead of successes at the same
    ///   time so a failure is never pushed below the fold by a batch of clean completions.
    public static func group(
        jobs: [Job],
        recentHours: Int = 24,
        now: Date = Date()
    ) -> GroupedJobs {
        group(jobs: jobs, filter: JobDisplayFilter(recentHours: recentHours), now: now)
    }

    public static func group(
        jobs: [Job],
        filter: JobDisplayFilter,
        now: Date = Date()
    ) -> GroupedJobs {
        var running: [Job] = []
        var pending: [Job] = []
        var completed: [Job] = []
        var unsuccessful: [Job] = []

        let cutoff = now.addingTimeInterval(-TimeInterval(max(0, filter.recentHours) * 3600))

        for job in jobs {
            switch job.state {
            case .running, .completing, .suspended:
                running.append(job)
            case .pending, .requeued:
                pending.append(job)
            default:
                // Age and hide rules apply only to finished jobs: an active job is never
                // hidden, because that is the thing the user most needs to see.
                if let endTime = job.endTime, endTime < cutoff { continue }
                if filter.hides(job) { continue }
                if job.outcome.finishedGroup == .completed {
                    completed.append(job)
                } else {
                    unsuccessful.append(job)
                }
            }
        }

        running.sort { lhs, rhs in
            let left = lhs.elapsedSeconds ?? -1
            let right = rhs.elapsedSeconds ?? -1
            if left != right { return left > right }
            return lhs.jobID.localizedStandardCompare(rhs.jobID) == .orderedAscending
        }

        pending.sort { lhs, rhs in
            let left = lhs.submitTime ?? .distantFuture
            let right = rhs.submitTime ?? .distantFuture
            if left != right { return left < right }
            return lhs.jobID.localizedStandardCompare(rhs.jobID) == .orderedAscending
        }

        // Both finished groups read newest-first; within the unsuccessful group a genuine
        // failure outranks a user cancellation at the same instant.
        let byRecency: (Job, Job) -> Bool = { lhs, rhs in
            let left = lhs.endTime ?? .distantPast
            let right = rhs.endTime ?? .distantPast
            if left != right { return left > right }
            if lhs.state.isFailure != rhs.state.isFailure { return lhs.state.isFailure }
            return lhs.jobID.localizedStandardCompare(rhs.jobID) == .orderedAscending
        }
        completed.sort(by: byRecency)
        unsuccessful.sort(by: byRecency)

        return GroupedJobs(
            running: running, pending: pending, completed: completed, unsuccessful: unsuccessful
        )
    }
}
