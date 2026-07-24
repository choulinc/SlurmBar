import SlurmBarKit
import SwiftUI

/// One job in the popover list.
///
/// Density is the design goal: a user with a dozen jobs should be able to read the state of all
/// of them without scrolling. Each row therefore shows only what is *available* — nothing is
/// padded out with placeholder text, and any value Slurm did not report is simply absent rather
/// than rendered as a zero.
struct JobRowView: View {
    let job: Job
    let group: JobGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleLine

            switch group {
            case .running:
                runningDetails
            case .pending:
                pendingDetails
            case .completed, .unsuccessful:
                finishedDetails
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Opens job details")
    }

    // MARK: - Shared

    private var titleLine: some View {
        HStack(spacing: 6) {
            Image(systemName: job.state.symbolName)
                .imageScale(.small)
                .foregroundStyle(stateTint)
                .accessibilityHidden(true)

            Text(job.name)
                .font(.system(.callout, design: .default).weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text(job.jobID)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var stateTint: Color {
        switch job.state {
        // Blue matches the progress bar, so a running row reads as one object.
        case .running, .completing: return .blue
        case .pending: return .orange
        case .completed: return .green
        case .cancelled, .preempted: return .secondary
        default: return job.state.isFailure ? .red : .secondary
        }
    }

    // MARK: - Running

    @ViewBuilder
    private var runningDetails: some View {
        if let progress = job.progress {
            ProgressBlock(progress: progress, job: job)
        }

        MetadataLine(items: runningMetadata)

        if let resourceLine = resourceMetadata, !resourceLine.isEmpty {
            MetadataLine(items: resourceLine)
        }
    }

    private var runningMetadata: [MetadataItem] {
        var items: [MetadataItem] = []
        items.append(MetadataItem(symbol: "timer", text: Formatters.elapsedWithLimit(
            elapsed: job.elapsedSeconds,
            limit: job.timeLimitSeconds
        )))
        if let eta = job.progress?.etaSeconds, !(job.progress?.stale ?? false) {
            items.append(MetadataItem(symbol: "hourglass", text: Formatters.eta(seconds: eta)))
        }
        if let location = job.nodeSummary {
            items.append(MetadataItem(symbol: "cpu", text: location))
        } else if let partition = job.partition {
            items.append(MetadataItem(symbol: "square.stack.3d.up", text: partition))
        }
        return items
    }

    private var resourceMetadata: [MetadataItem]? {
        var items: [MetadataItem] = []

        if job.resources.hasAnyMemoryInformation {
            items.append(MetadataItem(symbol: "memorychip", text: Formatters.memory(job.resources)))
        }
        if let gpuMemory = job.resources.gpuMemoryUsedBytes {
            items.append(MetadataItem(symbol: "gauge.medium", text: "GPU \(Formatters.bytes(gpuMemory))"))
        }
        if let utilization = job.resources.gpuUtilizationPercent {
            items.append(MetadataItem(symbol: "bolt", text: "GPU \(Formatters.utilization(utilization))"))
        }
        return items.isEmpty ? nil : items
    }

    // MARK: - Pending

    @ViewBuilder
    private var pendingDetails: some View {
        MetadataLine(items: pendingMetadata)
    }

    private var pendingMetadata: [MetadataItem] {
        var items: [MetadataItem] = [
            MetadataItem(symbol: "clock", text: "waiting \(Formatters.pendingDuration(submitTime: job.submitTime))")
        ]
        if let reason = job.reason {
            items.append(MetadataItem(symbol: "questionmark.circle", text: reason))
        }
        if let partition = job.partition {
            items.append(MetadataItem(symbol: "square.stack.3d.up", text: partition))
        }
        let resources = job.resourceSummary
        if !resources.isEmpty {
            items.append(MetadataItem(symbol: "cpu", text: resources))
        }
        if let limit = job.timeLimitSeconds {
            items.append(MetadataItem(symbol: "timer", text: "limit \(Formatters.duration(seconds: limit))"))
        }
        return items
    }

    // MARK: - Finished

    @ViewBuilder
    private var finishedDetails: some View {
        MetadataLine(items: finishedMetadata)

        if let counter = job.progress?.counterDescription, let prefix = counterPrefix {
            Text("\(prefix) \(counter)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let error = job.progress?.error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// How to introduce the counter on a finished job, or nil when it adds nothing.
    ///
    /// A run that reached its target needs no gloss — the state already says it completed. The
    /// two cases worth a word are the one that ended early and the one that died partway.
    private var counterPrefix: String? {
        switch job.progressDisposition {
        case .stoppedAt: return "stopped at"
        case .endedShortOfTarget: return "ended at"
        case .live, .reachedTarget, .none: return nil
        }
    }

    private var finishedMetadata: [MetadataItem] {
        var items: [MetadataItem] = [
            MetadataItem(symbol: job.state.symbolName, text: job.state.displayName)
        ]
        items.append(MetadataItem(symbol: "timer", text: "ran \(Formatters.duration(seconds: job.elapsedSeconds))"))
        if job.exitCode != nil || job.signal != nil {
            items.append(MetadataItem(
                symbol: "number",
                text: "exit \(Formatters.exitStatus(exitCode: job.exitCode, signal: job.signal))"
            ))
        }
        if let endTime = job.endTime {
            items.append(MetadataItem(symbol: "calendar", text: Formatters.relativeTime(from: endTime)))
        }
        return items
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        var parts = [job.name, "job \(job.jobID)", job.state.displayName]
        if let progress = job.progress {
            if let counter = progress.counterDescription { parts.append(counter) }
            if let fraction = progress.fraction {
                parts.append(Formatters.percent(fraction * 100))
            }
            if progress.stale { parts.append("progress is stale") }
        }
        if let elapsed = job.elapsedSeconds {
            parts.append("elapsed \(Formatters.duration(seconds: elapsed))")
        }
        if let reason = job.reason { parts.append("reason \(reason)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Progress colours

/// One place deciding what colour a progress bar is, so the bar and the state icon beside it
/// can never tell different stories.
enum ProgressPalette {
    static func tint(for disposition: ProgressDisposition) -> Color {
        switch disposition {
        // Blue matches the running state icon: the row reads as one object.
        case .live: return .blue
        // Green matches the completed state icon, and is only ever used on a full bar.
        case .reachedTarget: return .green
        // Neither running nor finished. Orange says "this is where it got to", without
        // claiming the job itself failed — a cancelled job gets this too.
        case .stoppedAt: return .orange
        case .endedShortOfTarget, .none: return .secondary
        }
    }
}

// MARK: - Progress block

private struct ProgressBlock: View {
    let progress: JobProgress
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let counter = progress.counterDescription {
                    Text(counter)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let phase = progress.phase {
                    Text(phase)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }

                Spacer(minLength: 0)

                if progress.source == .logParser {
                    // Never let a guessed number look like a measured one.
                    Label("guessed", systemImage: "text.magnifyingglass")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Inferred from the job's log output, not reported by the workload.")
                }
                if progress.stale {
                    Label("stale", systemImage: "exclamationmark.triangle")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("The workload has not updated its progress recently.")
                }
                if let fraction = job.displayedProgressFraction {
                    Text(Formatters.percent(fraction * 100))
                        .font(.caption.monospacedDigit().weight(.medium))
                }
            }

            if let fraction = job.displayedProgressFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(ProgressPalette.tint(for: job.progressDisposition))
                    .opacity(progress.stale ? 0.5 : 1)
            }

            if !metricsLine.isEmpty {
                Text(metricsLine)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let message = progress.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var metricsLine: String {
        var parts = progress.highlightedMetrics().map { "\($0.key) \($0.value.displayString)" }
        if let batch = progress.batchDescription {
            parts.append(batch)
        }
        return parts.joined(separator: "  ")
    }
}

// MARK: - Metadata line

struct MetadataItem: Identifiable {
    let id = UUID()
    let symbol: String
    let text: String
}

private struct MetadataLine: View {
    let items: [MetadataItem]

    var body: some View {
        // A wrapping flow would be nicer, but a single truncating line keeps every row the same
        // height, which is what makes a dense list scannable.
        HStack(spacing: 8) {
            ForEach(items) { item in
                HStack(spacing: 3) {
                    Image(systemName: item.symbol)
                        .imageScale(.small)
                    Text(item.text)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Running with structured progress") {
    JobRowView(job: PreviewData.runningTrainingJob, group: .running)
        .frame(width: PopoverRootView.width)
        .padding(.vertical)
}

#Preview("Running with unknown total") {
    JobRowView(job: PreviewData.runningCounterJob, group: .running)
        .frame(width: PopoverRootView.width)
        .padding(.vertical)
}

#Preview("Running with parsed progress") {
    JobRowView(job: PreviewData.runningParsedJob, group: .running)
        .frame(width: PopoverRootView.width)
        .padding(.vertical)
}

#Preview("Stale progress") {
    JobRowView(job: PreviewData.staleProgressJob, group: .running)
        .frame(width: PopoverRootView.width)
        .padding(.vertical)
}

#Preview("Pending") {
    VStack(spacing: 0) {
        JobRowView(job: PreviewData.pendingJob, group: .pending)
        JobRowView(job: PreviewData.pendingQOSJob, group: .pending)
    }
    .frame(width: PopoverRootView.width)
    .padding(.vertical)
}

#Preview("Completed") {
    JobRowView(job: PreviewData.completedJob, group: .completed)
        .frame(width: PopoverRootView.width)
        .padding(.vertical)
}

#Preview("Failed & cancelled") {
    VStack(spacing: 0) {
        JobRowView(job: PreviewData.outOfMemoryJob, group: .unsuccessful)
        JobRowView(job: PreviewData.failedJob, group: .unsuccessful)
    }
    .frame(width: PopoverRootView.width)
    .padding(.vertical)
}
#endif
