import AppKit
import SlurmBarKit
import SwiftUI

/// The popover. Fixed width, scrollable body, fixed header and footer.
struct PopoverRootView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.openWindow) private var openWindow

    static let width: CGFloat = 372

    @State private var detailJob: Job?
    @State private var showsGPUPage = false

    private var requestedDemoPage: String? {
        ProcessInfo.processInfo.environment["SLURMBAR_DEMO_PAGE"]
    }

    /// Usable height of the screen holding the menu bar, minus the menu bar itself.
    private var screenHeight: CGFloat {
        NSScreen.main?.visibleFrame.height ?? PopoverLayout.fallbackScreenHeight
    }

    /// Grows with the job count, capped at a fraction of the screen.
    private var scrollHeight: CGFloat {
        guard let monitor = controller.monitor else {
            return PopoverLayout.scrollHeight(
                groups: .empty,
                showsSummary: false,
                showsEmptyState: controller.emptyStateReason != nil,
                screenHeight: screenHeight
            )
        }
        let showsEmpty = controller.emptyStateReason != nil
        return PopoverLayout.scrollHeight(
            groups: showsEmpty ? .empty : monitor.groupedJobs,
            warningCount: monitor.prominentWarnings.count,
            showsStaleBanner: monitor.isShowingStaleData,
            showsSummary: !showsEmpty,
            showsEmptyState: showsEmpty,
            screenHeight: screenHeight
        )
    }

    var body: some View {
        Group {
            if showsGPUPage {
                GPUStatusView(
                    onBack: { withAnimation(.easeOut(duration: 0.12)) { showsGPUPage = false } }
                )
            } else if let job = detailJob {
                // Same popover, second page. A sheet or a separate window would move key
                // focus and macOS would close the popover underneath it.
                JobDetailView(job: job, onBack: { withAnimation(.easeOut(duration: 0.12)) { detailJob = nil } })
            } else {
                listPage
            }
        }
        .onAppear {
            PopoverVisibility.shared.markVisible()
            controller.popoverDidOpen()
            openRequestedDemoPage()
            // Ask after the user has seen the popover once, not while it is still empty.
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                controller.promptForLaunchAtLoginIfNeeded()
            }
        }
        .onDisappear {
            PopoverVisibility.shared.markHidden()
            controller.popoverDidClose()
        }
    }

    private func openRequestedDemoPage() {
        switch requestedDemoPage {
        case "gpu":
            Task { @MainActor in
                for _ in 0..<20 {
                    if controller.monitor?.snapshot?.jobs.contains(where: {
                        ($0.state == .running || $0.state == .completing) && ($0.gpus ?? 0) > 0
                    }) == true {
                        showsGPUPage = true
                        return
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                showsGPUPage = true
            }
        case "job", "logs":
            // The file-backed demo monitor normally has its snapshot before the popover opens.
            // Retry briefly so documentation captures remain deterministic on a slower machine.
            Task { @MainActor in
                for _ in 0..<20 {
                    if let job = controller.monitor?.snapshot?.jobs.first(where: { $0.jobID == "10001" }) {
                        detailJob = job
                        return
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        default:
            break
        }
    }

    private var listPage: some View {
        VStack(spacing: 0) {
            PopoverHeaderView(
                onShowGPU: { withAnimation(.easeOut(duration: 0.12)) { showsGPUPage = true } }
            )

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let monitor = controller.monitor {
                        if monitor.isShowingStaleData {
                            StaleBanner(connection: monitor.connection, lastFetch: monitor.lastSuccessfulFetch)
                        }

                        ForEach(monitor.prominentWarnings) { warning in
                            WarningRow(warning: warning)
                        }

                        if let reason = controller.emptyStateReason {
                            EmptyStateView(reason: reason)
                        } else {
                            // monitor.summary is derived from the filtered, visible jobs, so
                            // these numbers always match the list underneath them.
                            SummaryStrip(summary: monitor.summary)
                            JobSectionsView(
                                groups: monitor.groupedJobs,
                                onSelect: { job in
                                    withAnimation(.easeOut(duration: 0.12)) { detailJob = job }
                                }
                            )
                        }
                    } else if let reason = controller.emptyStateReason {
                        EmptyStateView(reason: reason)
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(height: scrollHeight)

            Divider()

            PopoverFooterView()
        }
        .frame(width: Self.width)
    }
}

// MARK: - Header

private struct PopoverHeaderView: View {
    @EnvironmentObject private var controller: AppController
    let onShowGPU: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if controller.settings.clusters.count > 1 {
                    ClusterPicker()
                } else {
                    Text(controller.settings.selectedCluster?.effectiveName ?? "SlurmBar")
                        .font(.headline)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button(action: onShowGPU) {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                }
                .buttonStyle(.borderless)
                .disabled(controller.monitor?.snapshot == nil)
                .help("Live GPU status")
                .accessibilityLabel("Open live GPU status")

                CleanupMenu()

                Button {
                    controller.refresh()
                } label: {
                    if controller.connection.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(controller.connection.isRefreshing || controller.monitor == nil)
                .help("Refresh now")
                .accessibilityLabel("Refresh now")
            }

            HStack(spacing: 5) {
                ConnectionIndicator(state: controller.connection)
                if let fetched = controller.monitor?.lastSuccessfulFetch {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("Updated \(Formatters.relativeTime(from: fetched))")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

/// Clearing finished jobs out of the list.
///
/// "Remove", not "Delete": this only affects the list on this Mac. A finished job cannot be
/// deleted from Slurm — `sacct` will still report it forever — and a button that implied
/// otherwise would be lying about what it did. Every label and tooltip here says "list".
private struct CleanupMenu: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Menu {
            Button("Remove cancelled from list (\(controller.cancelledCount))") {
                controller.removeAllCancelled()
            }
            .disabled(controller.cancelledCount == 0)

            Button("Remove all finished from list") { controller.dismissAllFinished() }
                .disabled(controller.monitor?.dismissableJobIDs.isEmpty ?? true)

            if controller.dismissedCount > 0 {
                Divider()
                Button("Put back \(controller.dismissedCount) removed") {
                    controller.restoreDismissedJobs()
                }
            }

            Divider()

            Toggle("Always hide failed", isOn: Binding(
                get: { controller.settings.hideFailedJobs },
                set: { controller.setHideFailed($0) }
            ))
            Toggle("Always hide cancelled", isOn: Binding(
                get: { controller.settings.hideCancelledJobs },
                set: { controller.setHideCancelled($0) }
            ))
        } label: {
            Image(systemName: hasRemovals ? "trash.fill" : "trash")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Remove finished jobs from this list. Does not affect the cluster.")
        .accessibilityLabel(hasRemovals ? "Cleanup, some jobs removed" : "Remove finished jobs")
    }

    /// Filled can whenever something is being kept out of the list, so it is never quietly
    /// incomplete without a visible cue.
    private var hasRemovals: Bool {
        controller.settings.hideFailedJobs
            || controller.settings.hideCancelledJobs
            || controller.dismissedCount > 0
    }
}

private struct ClusterPicker: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Picker("Cluster", selection: Binding(
            get: { controller.settings.selectedCluster?.id ?? controller.settings.clusters.first?.id ?? UUID() },
            set: { controller.selectCluster(id: $0) }
        )) {
            ForEach(controller.settings.clusters) { cluster in
                Text(cluster.effectiveName).tag(cluster.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

private struct ConnectionIndicator: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbolName)
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(state.shortLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(state.shortLabel)")
    }
}

// MARK: - Stale / warnings

private struct StaleBanner: View {
    let connection: ConnectionState
    let lastFetch: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: connection.failure?.symbolName ?? "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
                Text(connection.failure?.title ?? "Showing cached data")
                    .font(.callout.weight(.medium))
            }

            if let failure = connection.failure {
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let suggestion = failure.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let lastFetch {
                Text("Last successful refresh \(Formatters.relativeTime(from: lastFetch)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RetryActions()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }
}

private struct RetryActions: View {
    @EnvironmentObject private var controller: AppController
    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if controller.connection.failure?.isInteractiveAuthenticationRequired == true {
                Button("Authenticate in Terminal…") {
                    controller.authenticateInteractively()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button("Retry") { controller.refresh() }
                    .buttonStyle(.borderless)
                    .font(.caption)

                Button("Test Connection") { runDoctor() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(isTesting)

                if isTesting {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = controller.interactiveAuthLaunchError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let testResult {
                Text(testResult)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private func runDoctor() {
        guard let monitor = controller.monitor else { return }
        isTesting = true
        testResult = nil
        Task {
            let result = await monitor.runDoctor()
            isTesting = false
            switch result {
            case .success(let report):
                let failures = report.failures
                testResult = failures.isEmpty
                    ? "Agent reachable. \(report.checks.filter { $0.status == .ok }.count) checks passed."
                    : "Failed: \(failures.map(\.title).joined(separator: ", "))"
            case .failure(let failure):
                testResult = "\(failure.title): \(failure.message)"
            }
        }
    }
}

private struct WarningRow: View {
    let warning: AgentWarning

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: warning.symbolName)
                .imageScale(.small)
                .foregroundStyle(warning.severity == .error ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = warning.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Summary

private struct SummaryStrip: View {
    let summary: JobSummary

    var body: some View {
        HStack(spacing: 0) {
            SummaryCell(value: summary.running, label: "Running", symbol: "play.circle")
            SummaryCell(value: summary.pending, label: "Pending", symbol: "clock")
            SummaryCell(value: summary.completedRecently, label: "Completed", symbol: "checkmark.circle")
            // Counts the whole "Failed & cancelled" section, not just the failures in it.
            // Showing only failures left cancellations counted in no cell at all, so the
            // section header and the strip disagreed about the same list of jobs.
            SummaryCell(
                value: summary.unsuccessfulRecently,
                label: "Unsuccessful",
                symbol: "exclamationmark.triangle",
                emphasized: summary.failedRecently > 0
            )
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

private struct SummaryCell: View {
    let value: Int
    let label: String
    let symbol: String
    var emphasized: Bool = false

    var body: some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(emphasized ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            Label(label, systemImage: symbol)
                .labelStyle(.titleOnly)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

// MARK: - Sections

private struct JobSectionsView: View {
    let groups: GroupedJobs
    let onSelect: (Job) -> Void

    var body: some View {
        ForEach(JobGroup.allCases) { group in
            let jobs = groups.jobs(in: group)
            if !jobs.isEmpty {
                SectionHeader(title: group.title, count: jobs.count)
                ForEach(jobs) { job in
                    JobRowView(job: job)
                        // Identity is scoped to the section. A job that finishes moves between
                        // two ForEach bodies with its id unchanged, and inside a LazyVStack
                        // that reads as "the same row moved" — leaving the previously rendered
                        // body in place under the new header. Making it a different view forces
                        // a fresh one.
                        .id("\(group.rawValue)#\(job.jobID)")
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(job) }
                        .contextMenu { JobRowContextMenu(job: job) }
                }
            }
        }
    }
}

private struct JobRowContextMenu: View {
    @EnvironmentObject private var controller: AppController
    let job: Job

    var body: some View {
        Button("Copy Job ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.jobID, forType: .string)
        }
        if job.state.isFinished {
            Divider()
            // Scoped to "list" on purpose — see CleanupMenu.
            Button("Remove from list", systemImage: "trash") { controller.dismissJob(job) }
            Button("Remove all finished from list") { controller.dismissAllFinished() }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Footer

private struct PopoverFooterView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 10) {
            Button {
                openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Quit") { controller.quit() }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Populated") {
    PopoverPreviewHost(snapshot: PreviewData.snapshot)
}

#Preview("Empty") {
    PopoverPreviewHost(snapshot: PreviewData.emptySnapshot)
}

/// Renders the popover body against fixture data without touching SSH or the settings file.
struct PopoverPreviewHost: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(spacing: 0) {
            SummaryStrip(summary: snapshot.summary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let groups = JobGrouper.group(jobs: snapshot.jobs, now: snapshot.generatedAt)
                    if groups.isEmpty {
                        EmptyStateView(reason: .noJobs)
                    } else {
                        JobSectionsView(groups: groups, onSelect: { _ in })
                    }
                }
            }
        }
        .frame(width: PopoverRootView.width, height: 520)
    }
}
#endif
