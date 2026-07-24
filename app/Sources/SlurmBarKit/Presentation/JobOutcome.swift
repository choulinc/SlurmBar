import Foundation

/// How a job ended, according to Slurm.
///
/// Every surface that answers "is this finished, and did it go well?" reads this and nothing
/// else. The question used to be answered independently in six places — grouping, the summary
/// strip, the row, the detail view, the menu bar and the notification detector — and they did
/// not agree with each other. The most visible symptom: a cancelled job landed in the
/// "Failed & cancelled" section but was counted in neither the "Completed" nor the "Failed"
/// summary cell, so on a real snapshot the section header read 74 while the cells accounted
/// for 61 of them.
public enum JobOutcome: String, Hashable, Sendable, CaseIterable {
    /// Queued, running, suspended, completing, or waiting to be requeued.
    case active
    /// Finished, and Slurm considers it clean.
    case succeeded
    /// Finished because something went wrong.
    case failed
    /// Stopped deliberately — by a person, or by the scheduler preempting it.
    case cancelled
    /// Finished in a state this build does not classify.
    ///
    /// Never folded into ``succeeded``: a state we cannot interpret is not evidence that
    /// anything went right.
    case indeterminate

    public var isFinished: Bool { self != .active }

    /// Which popover section a job with this outcome belongs to, for finished jobs.
    ///
    /// Active jobs still split into running and pending by state, which is a scheduling
    /// distinction rather than an outcome.
    public var finishedGroup: JobGroup? {
        switch self {
        case .active: return nil
        case .succeeded: return .completed
        case .failed, .cancelled, .indeterminate: return .unsuccessful
        }
    }
}

/// What to do with a job's progress reading, given how the job ended.
///
/// Slurm and the workload answer different questions. Slurm knows whether the *process* exited
/// cleanly; only the workload knows whether the *work* finished. A run that early-stops at
/// epoch 284 of 300 exits 0, and Slurm has no way to tell that apart from a crash at epoch 284
/// that was caught and swallowed. So the two are kept separate and reconciled here.
public enum ProgressDisposition: Hashable, Sendable {
    /// No usable reading.
    case none
    /// Still moving. Show a live bar.
    case live
    /// Finished having reached its target — either the counter got there, or the workload
    /// declared success through `slurmbar_progress`. A full bar here is a fact, not a rounding.
    case reachedTarget
    /// Finished cleanly with the counter short of the total.
    ///
    /// This is what an early-stopped run looks like. It is *also* what a run whose last
    /// progress update was never flushed looks like, and what a run that was `exit 0`'d by a
    /// wrapper script looks like. Nothing in Slurm's record distinguishes them, so the UI
    /// states the observation and declines to name the cause.
    case endedShortOfTarget
    /// Ended badly. The counter records how far it got, which is the useful number here.
    case stoppedAt

    /// Whether a determinate bar should be drawn.
    ///
    /// ``endedShortOfTarget`` is the one finished case that gets no bar: filling it would claim
    /// the run reached a total it did not reach, and leaving it partial next to "Completed"
    /// reads as unfinished. The counter is shown instead, which is true either way.
    public var showsBar: Bool {
        switch self {
        case .live, .reachedTarget, .stoppedAt: return true
        case .none, .endedShortOfTarget: return false
        }
    }

    /// Whether the bar should be pinned full regardless of the counter.
    public var barIsComplete: Bool { self == .reachedTarget }
}

/// A conflict between what Slurm recorded and what the workload reported.
///
/// Only ever raised for `structured_file` progress. A log parser infers numbers from text and
/// cannot declare an outcome, so disagreeing with it would be disagreeing with a guess.
public enum CompletionDisagreement: Hashable, Sendable {
    /// The workload reported failure; Slurm recorded a clean exit.
    ///
    /// Usually a caught exception that was logged and then swallowed, or a launcher that
    /// returns its own status rather than the training process's.
    case reportedFailureButExitedClean
    /// The workload had already reported success when Slurm recorded a failure.
    ///
    /// Typically something after the work itself — checkpoint upload, an epilog, a hitting of
    /// the time limit during teardown.
    case reportedSuccessButJobFailed
    /// The workload was still reporting progress, short of its target, when the job ended.
    case endedWhileStillReporting

    public var summary: String {
        switch self {
        case .reportedFailureButExitedClean:
            return "The workload reported a failure, but Slurm recorded a clean exit."
        case .reportedSuccessButJobFailed:
            return "The workload reported success before Slurm recorded a failure."
        case .endedWhileStillReporting:
            return "The job ended while the workload was still reporting progress."
        }
    }

    public var explanation: String {
        switch self {
        case .reportedFailureButExitedClean:
            return "An exception that was caught and logged, or a launcher that reports its own exit status instead of the workload's, both look like this."
        case .reportedSuccessButJobFailed:
            return "The work itself finished; something after it did not — a checkpoint upload, an epilog script, or the time limit arriving during teardown."
        case .endedWhileStillReporting:
            return "The workload never got to record an outcome. It was killed, or it exited on a path that skips the final report."
        }
    }
}
