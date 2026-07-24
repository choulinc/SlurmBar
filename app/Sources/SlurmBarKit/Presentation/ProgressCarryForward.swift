import Foundation

/// Keeps a job's last progress reading when the job leaves the queue.
///
/// The agent reads progress two ways, and both stop the instant a job finishes:
///
/// * a **log tail** needs the log's path, and `squeue` is the only command that reports one.
///   `sacct` has no `StdOut` field at all, so a job that has left the queue cannot have its log
///   located, let alone read;
/// * a **structured status file** does survive, but only workloads that adopted the
///   `slurmbar_progress` SDK write one.
///
/// So for everyone else, "epoch 5640/9400" is discarded at exactly the moment the question
/// "how far did it get?" starts to matter. The agent is one-shot and stateless and cannot fix
/// this; the app polls and therefore already holds the answer from the poll before last.
///
/// Only readings taken while the job was still active are carried, only onto finished jobs that
/// have no reading of their own, and the copy is flagged so nothing downstream mistakes it for
/// a live measurement.
public enum ProgressCarryForward {
    /// Merge `previous`'s progress readings into `fetched` where `fetched` has lost them.
    public static func apply(previous: Snapshot?, to fetched: Snapshot) -> Snapshot {
        guard let previous else { return fetched }

        // Only jobs that were still going have a reading worth keeping. A finished job's
        // carried reading is already carried; re-carrying it is harmless but pointless, and
        // this way the chain is always at most one hop from a live observation.
        var carriable: [String: JobProgress] = [:]
        for job in previous.jobs where !job.outcome.isFinished {
            if let progress = job.progress { carriable[job.jobID] = progress }
        }
        guard !carriable.isEmpty else { return fetched }

        var changed = false
        let jobs = fetched.jobs.map { job -> Job in
            guard job.progress == nil,
                  job.outcome.isFinished,
                  let inherited = carriable[job.jobID]
            else { return job }
            changed = true
            return job.replacingProgress(inherited.asCarriedForward())
        }
        guard changed else { return fetched }

        return Snapshot(
            schemaVersion: fetched.schemaVersion,
            generatedAt: fetched.generatedAt,
            agentVersion: fetched.agentVersion,
            cluster: fetched.cluster,
            summary: fetched.summary,
            jobs: jobs,
            warnings: fetched.warnings
        )
    }
}
