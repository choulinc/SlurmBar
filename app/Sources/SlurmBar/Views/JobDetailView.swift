import AppKit
import SlurmBarKit
import SwiftUI

/// Job detail, rendered as a second page *inside* the popover.
///
/// It is deliberately not a sheet or a separate window: opening either would move key focus
/// away from the menu bar popover, and macOS closes the popover the moment that happens — so
/// returning from the detail left the user with nothing on screen. Keeping both pages in the
/// same popover means "back" really does go back.
///
/// It shares the popover's type scale, spacing and row idiom so the two pages read as one app
/// rather than a compact list bolted to a desktop-style inspector.
struct JobDetailView: View {
    @EnvironmentObject private var controller: AppController

    let job: Job
    let onBack: () -> Void

    @State private var stream: LogStream = .stdout
    @State private var logTail: LogTail?
    @State private var logError: SSHFailure?
    @State private var isLoadingLogs = false
    @State private var showCancelConfirmation = false
    @State private var cancelOutcome: String?
    @State private var isCancelling = false
    @State private var copiedLabel: String?
    @State private var showLogs = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let progress = job.progress {
                        ProgressSection(progress: progress, job: job)
                        SectionDivider()
                    }
                    ResourceSection(resources: job.resources, job: job)
                    SectionDivider()
                    MetadataSection(job: job)
                    SectionDivider()
                    LogSection(
                        stream: $stream,
                        tail: logTail,
                        error: logError,
                        isLoading: isLoadingLogs,
                        isExpanded: $showLogs,
                        onLoad: { loadLogs(force: true) }
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(height: scrollHeight)

            Divider()
            footer
        }
        .frame(width: PopoverRootView.width)
        .confirmationDialog(
            "Cancel job \(job.jobID)?",
            isPresented: $showCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel job \(job.jobID)", role: .destructive) { performCancel() }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("This runs scancel \(job.jobID) for “\(job.name)” on \(controller.settings.selectedCluster?.effectiveName ?? "the cluster"). This cannot be undone.")
        }
    }

    private var scrollHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? PopoverLayout.fallbackScreenHeight
        return PopoverLayout.detailScrollHeight(
            hasProgress: job.progress != nil,
            metricCount: job.progress?.metrics.count ?? 0,
            logsExpanded: showLogs,
            screenHeight: screen
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Label("Jobs", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to the job list")

                Spacer(minLength: 4)

                Text(job.jobID)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                Image(systemName: job.state.symbolName)
                    .imageScale(.small)
                    .foregroundStyle(stateTint)
                Text(job.name)
                    .font(.system(.callout).weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            HStack(spacing: 5) {
                Text(job.state.displayName)
                if let raw = job.stateRaw, raw != job.state.rawValue {
                    Text("(\(raw))").foregroundStyle(.tertiary)
                }
                if job.isArrayTask, let task = job.arrayTaskID {
                    Text("· array task \(task)").foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
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

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                copy(job.jobID, label: "Copied")
            } label: {
                Label("Job ID", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)

            Menu {
                Button("scancel \(job.jobID)") { copy("scancel \(job.jobID)", label: "Copied") }
                Button("sacct -j \(job.jobID) --long") { copy("sacct -j \(job.jobID) --long", label: "Copied") }
                Button("scontrol show job \(job.jobID)") { copy("scontrol show job \(job.jobID)", label: "Copied") }
                if let path = job.stdoutPath {
                    Button("tail -f \(path)") { copy("tail -f \(path)", label: "Copied") }
                }
                Divider()
                Button("SlurmBar refresh command") {
                    copy(controller.monitor?.debugCommandLine() ?? "", label: "Copied")
                }
            } label: {
                Label("Command", systemImage: "terminal")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let copiedLabel {
                Text(copiedLabel).font(.caption2).foregroundStyle(.secondary).transition(.opacity)
            }

            Spacer(minLength: 0)

            if let cancelOutcome {
                Text(cancelOutcome).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }

            if job.state.isActive {
                Button(role: .destructive) {
                    showCancelConfirmation = true
                } label: {
                    if isCancelling {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(isCancelling)
                .help("Runs scancel on the cluster. Asks for confirmation first.")
            } else {
                Button {
                    controller.dismissJob(job)
                    onBack()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .help("Removes this job from the list on this Mac only. It stays in Slurm's accounting.")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func copy(_ text: String, label: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copiedLabel = label }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { copiedLabel = nil }
        }
    }

    private func loadLogs(force: Bool) {
        guard let monitor = controller.monitor else { return }
        guard force || logTail == nil else { return }
        isLoadingLogs = true
        logError = nil
        Task {
            let result = await monitor.loadLogs(job: job, stream: stream, lines: 200)
            isLoadingLogs = false
            switch result {
            case .success(let tail): logTail = tail
            case .failure(let failure):
                logTail = nil
                logError = failure
            }
        }
    }

    /// Only ever reached from the confirmation dialog's destructive button.
    private func performCancel() {
        guard let monitor = controller.monitor else { return }
        isCancelling = true
        cancelOutcome = nil
        Task {
            let result = await monitor.cancelJob(jobID: job.jobID)
            isCancelling = false
            switch result {
            case .success(let outcome):
                cancelOutcome = outcome.ok ? "Cancellation requested" : "Cancel failed"
            case .failure(let failure):
                cancelOutcome = failure.title
            }
        }
    }
}

// MARK: - Shared building blocks (same idiom as the job list)

private struct SectionDivider: View {
    var body: some View {
        Divider().opacity(0.5)
    }
}

private struct DetailSectionHeader: View {
    let title: String
    let symbol: String
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).imageScale(.small)
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }
}

struct DetailRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var annotation: String?
}

private struct DetailRows: View {
    let rows: [DetailRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 108, alignment: .leading)
                    Text(row.value)
                        .font(.caption.monospacedDigit())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let annotation = row.annotation, !annotation.isEmpty {
                        Text(annotation).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Sections

private struct ProgressSection: View {
    let progress: JobProgress
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailSectionHeader(
                title: "Progress",
                symbol: "chart.bar",
                trailing: AnyView(SourceBadge(source: progress.source, confidence: progress.confidence))
            )

            HStack(spacing: 6) {
                if let counter = progress.counterDescription {
                    Text(counter).font(.callout.monospacedDigit().weight(.medium))
                }
                if let phase = progress.phase {
                    Text(phase)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer(minLength: 0)
                // The percentage goes with the bar. Where the bar is suppressed because the
                // counter cannot be trusted as a completion figure, the percentage would carry
                // exactly the same false claim.
                if let fraction = job.displayedProgressFraction {
                    Text(Formatters.percent(fraction * 100, decimals: 1))
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

            if let note = dispositionNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let disagreement = job.completionDisagreement {
                DisagreementNote(disagreement: disagreement)
            }

            DetailRows(rows: rows)

            if !progress.metrics.isEmpty {
                DetailRows(rows: progress.metrics.keys.sorted().map { key in
                    DetailRow(label: key, value: progress.metrics[key]?.displayString ?? Formatters.notAvailable)
                })
            }

            if let error = progress.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The one line of prose that says what the counter means now that the job has ended.
    ///
    /// Only the ambiguous case gets an explanation. Naming a cause would be a guess: Slurm
    /// records an exit status, not an intent, and an early-stopped run is indistinguishable
    /// from one whose final update never reached disk.
    private var dispositionNote: String? {
        switch job.progressDisposition {
        case .endedShortOfTarget:
            return "Exited cleanly before the counter reached its total. An early-stopped run "
                + "looks like this; so does one whose last progress update was never written. "
                + "Report completion from the workload to tell them apart."
        case .reachedTarget where progress.completion == .completed
            && (progress.current ?? 0) < (progress.total ?? 0):
            return "The workload reported that it finished, short of the counter's total."
        case .live, .reachedTarget, .stoppedAt, .none:
            return nil
        }
    }

    private var rows: [DetailRow] {
        var rows: [DetailRow] = []
        if let kind = progress.kind { rows.append(DetailRow(label: "Workload", value: kind)) }
        rows.append(DetailRow(label: "ETA", value: Formatters.eta(seconds: progress.etaSeconds)))
        rows.append(DetailRow(
            label: "Updated",
            value: progress.updatedAt.map { Formatters.relativeTime(from: $0) } ?? Formatters.notAvailable,
            // "last reading" wins over "stale": for a job that has ended, the reading not
            // having changed recently is expected rather than a warning sign.
            annotation: progress.carriedForward ? "last reading before the job ended"
                : (progress.stale ? "stale" : nil)
        ))
        if let message = progress.message { rows.append(DetailRow(label: "Message", value: message)) }
        return rows
    }
}

/// Shown when Slurm's record and the workload's own report do not agree.
///
/// Presented rather than resolved. Both witnesses are telling the truth about the question they
/// can answer, and which one matters depends on what the user was trying to do.
private struct DisagreementNote: View {
    let disagreement: CompletionDisagreement

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
                .imageScale(.small)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(disagreement.summary)
                    .font(.caption.weight(.medium))
                Text(disagreement.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SourceBadge: View {
    let source: ProgressSource
    let confidence: ProgressConfidence?

    var body: some View {
        Label(text, systemImage: source == .structuredFile ? "checkmark.seal" : "text.magnifyingglass")
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(source == .structuredFile ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
            .help(helpText)
    }

    private var text: String {
        source == .structuredFile ? "reported" : "guessed (\(confidence?.rawValue ?? "low"))"
    }

    private var helpText: String {
        switch source {
        case .structuredFile:
            return "The workload reported this directly using slurmbar_progress."
        case .logParser:
            return "Inferred from the tail of the job's log. Slurm does not know about epochs "
                + "or batches; add slurmbar_progress for exact values."
        }
    }
}

private struct ResourceSection: View {
    let resources: JobResources
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailSectionHeader(title: "Resources", symbol: "memorychip", trailing: nil)

            if let fraction = resources.memoryFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            DetailRows(rows: rows)

            if resources.memoryUsedBytes != nil || resources.memoryLimitBytes != nil {
                Text(semanticsExplanation)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rows: [DetailRow] {
        [
            DetailRow(
                label: "Memory used",
                value: Formatters.bytes(resources.memoryUsedBytes),
                annotation: resources.memoryUsedBytes == nil ? nil : resources.memorySemantics.shortLabel
            ),
            DetailRow(
                label: "Memory requested",
                value: Formatters.bytes(resources.memoryLimitBytes),
                annotation: resources.memoryLimitBytes == nil ? nil : resources.memoryLimitSemantics.shortLabel
            ),
            DetailRow(label: "GPU memory", value: Formatters.bytes(resources.gpuMemoryUsedBytes)),
            DetailRow(label: "GPU utilization", value: Formatters.utilization(resources.gpuUtilizationPercent)),
            DetailRow(label: "CPUs", value: job.cpus.map(String.init) ?? Formatters.notAvailable),
            DetailRow(label: "GPUs", value: job.gpus.map(String.init) ?? Formatters.notAvailable),
            DetailRow(label: "Nodes", value: job.nodes.isEmpty ? Formatters.notAvailable : job.nodes.joined(separator: ", ")),
        ]
    }

    private var semanticsExplanation: String {
        var parts: [String] = []
        if resources.memoryUsedBytes != nil { parts.append(resources.memorySemantics.explanation) }
        if resources.memoryLimitBytes != nil { parts.append(resources.memoryLimitSemantics.explanation) }
        return parts.joined(separator: " ")
    }
}

private struct MetadataSection: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailSectionHeader(title: "Job", symbol: "info.circle", trailing: nil)
            DetailRows(rows: rows)
        }
    }

    private var rows: [DetailRow] {
        var rows: [DetailRow] = [
            DetailRow(label: "User", value: job.user ?? Formatters.notAvailable),
            DetailRow(label: "Partition", value: job.partition ?? Formatters.notAvailable),
            DetailRow(label: "Account", value: job.account ?? Formatters.notAvailable),
            DetailRow(label: "Submitted", value: Formatters.dateTime(job.submitTime)),
            DetailRow(label: "Started", value: Formatters.dateTime(job.startTime)),
        ]
        if job.state.isFinished {
            rows.append(DetailRow(label: "Ended", value: Formatters.dateTime(job.endTime)))
            rows.append(DetailRow(label: "Exit", value: Formatters.exitStatus(exitCode: job.exitCode, signal: job.signal)))
        }
        rows.append(DetailRow(label: "Elapsed", value: Formatters.clockDuration(seconds: job.elapsedSeconds)))
        rows.append(DetailRow(label: "Time limit", value: Formatters.clockDuration(seconds: job.timeLimitSeconds)))
        if let remaining = job.remainingTimeSeconds, job.state.isActive {
            rows.append(DetailRow(label: "Remaining", value: Formatters.duration(seconds: remaining)))
        }
        if let reason = job.reason { rows.append(DetailRow(label: "Reason", value: reason)) }
        rows.append(DetailRow(label: "Work dir", value: job.workDir ?? Formatters.notAvailable))
        rows.append(DetailRow(label: "stdout", value: job.stdoutPath ?? Formatters.notAvailable))
        return rows
    }
}

private struct LogSection: View {
    @Binding var stream: LogStream
    let tail: LogTail?
    let error: SSHFailure?
    let isLoading: Bool
    @Binding var isExpanded: Bool
    let onLoad: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailSectionHeader(
                title: "Log tail",
                symbol: "doc.plaintext",
                trailing: AnyView(
                    Button(isExpanded ? "Hide" : "Load") {
                        isExpanded.toggle()
                        if isExpanded { onLoad() }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                )
            )

            if !isExpanded {
                // Logs cost an extra SSH round trip, so they load only when asked for.
                Text("Last 200 lines, fetched on demand.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 6) {
                    Picker("Stream", selection: $stream) {
                        ForEach(LogStream.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()

                    if isLoading { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                    Button {
                        onLoad()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoading)
                    .accessibilityLabel("Reload log")
                }
                .onChange(of: stream) { _, _ in onLoad() }

                if let error {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(error.title).font(.caption.weight(.medium))
                        Text(error.message).font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let tail {
                    if let warning = tail.warnings.first {
                        Text(warning.message)
                            .font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if tail.isEmpty {
                        Text("No log output.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView([.horizontal, .vertical]) {
                            Text(tail.text)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(5)
                        }
                        .frame(height: 150)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))

                        HStack(spacing: 5) {
                            Text("\(tail.lines.count) lines")
                            if tail.truncated { Text("· tail only") }
                            if let size = tail.fileSizeBytes { Text("· \(Formatters.bytes(size))") }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                } else if !isLoading {
                    Text("Not loaded.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Running job") {
    JobDetailView(job: PreviewData.runningTrainingJob, onBack: {})
        .environmentObject(AppController(
            settingsStore: SettingsStore(fileURL: URL(fileURLWithPath: "/dev/null")),
            notifier: RecordingNotifier()
        ))
}

#Preview("Failed job") {
    JobDetailView(job: PreviewData.failedJob, onBack: {})
        .environmentObject(AppController(
            settingsStore: SettingsStore(fileURL: URL(fileURLWithPath: "/dev/null")),
            notifier: RecordingNotifier()
        ))
}
#endif
