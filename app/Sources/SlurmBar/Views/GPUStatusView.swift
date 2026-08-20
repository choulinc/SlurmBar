import AppKit
import SlurmBarKit
import SwiftUI

/// Live GPU telemetry, loaded only while this page is open.
struct GPUStatusView: View {
    @EnvironmentObject private var controller: AppController

    let onBack: () -> Void

    @State private var response: GPUStatusResponse?
    @State private var failure: SSHFailure?
    @State private var isLoading = false

    private var eligibleJobs: [Job] {
        (controller.monitor?.snapshot?.jobs ?? [])
            .filter { job in
                (job.state == .running || job.state == .completing)
                    && ((job.gpus ?? 0) > 0 || job.resources.gpuMemoryLimitBytes != nil)
            }
            .sorted { $0.jobID.localizedStandardCompare($1.jobID) == .orderedAscending }
    }

    private var jobsByID: [String: Job] {
        Dictionary(uniqueKeysWithValues: eligibleJobs.map { ($0.jobID, $0) })
    }

    private var scrollHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? PopoverLayout.fallbackScreenHeight
        let available = max(
            PopoverLayout.metrics.detailMinimum,
            screen * PopoverLayout.metrics.maximumScreenFraction - PopoverLayout.metrics.chrome
        )
        let deviceRows = response?.jobs.reduce(0) { $0 + max(1, ($1.gpus.count + 1) / 2) } ?? 2
        let jobCount = response?.jobs.count ?? 1
        return min(max(300, 92 + CGFloat(deviceRows) * 162 + CGFloat(jobCount) * 54), available)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    content
                }
                .padding(10)
            }
            .frame(height: scrollHeight)

            Divider()
            footer
        }
        .frame(width: PopoverRootView.width)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Button(action: onBack) {
                    Label("Jobs", systemImage: "chevron.left")
                        .font(.callout)
                }
                .buttonStyle(.borderless)

                Spacer(minLength: 4)

                Button {
                    Task { await load() }
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isLoading || eligibleJobs.isEmpty)
                .help("Refresh GPU status")
                .accessibilityLabel("Refresh GPU status")
            }

            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .foregroundStyle(.blue)
                Text("Live GPUs")
                    .font(.headline)
                Spacer(minLength: 0)
                if let response {
                    Text(Formatters.relativeTime(from: response.generatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(controller.settings.selectedCluster?.effectiveName ?? "Cluster")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if eligibleJobs.isEmpty {
            GPUEmptyState(
                title: "No running GPU jobs",
                message: "A job appears here while it is running and Slurm reports a GPU allocation."
            )
        } else if let failure, response == nil {
            GPUFailureView(failure: failure) {
                Task { await load() }
            }
        } else if isLoading, response == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("Checking \(eligibleJobs.count) GPU job\(eligibleJobs.count == 1 ? "" : "s")…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        } else if let response {
            if let failure {
                GPUStaleFailureBanner(failure: failure) {
                    Task { await load() }
                }
            }

            GPUSummaryStrip(response: response)

            ForEach(response.warnings) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: warning.symbolName).foregroundStyle(.orange)
                    Text(warning.message).font(.caption)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }

            ForEach(response.jobs) { status in
                GPUJobCard(status: status, job: jobsByID[status.jobID])
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal")
            Text("On demand via srun --overlap")
            Spacer(minLength: 0)
            if isLoading, response != nil {
                Text("Updating…")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @MainActor
    private func load() async {
        guard !isLoading, let monitor = controller.monitor else { return }
        let jobIDs = eligibleJobs.map(\.jobID)
        guard !jobIDs.isEmpty else {
            response = nil
            failure = nil
            return
        }
        isLoading = true
        failure = nil
        let result = await monitor.loadGPUStatus(jobIDs: jobIDs)
        isLoading = false
        switch result {
        case .success(let fetched): response = fetched
        case .failure(let error): failure = error
        }
    }
}

private struct GPUSummaryStrip: View {
    let response: GPUStatusResponse

    private var devices: [GPUDevice] { response.jobs.flatMap(\.gpus) }
    private var averageUtilization: Double? {
        let values = devices.compactMap(\.utilizationPercent)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var body: some View {
        HStack(spacing: 0) {
            summary(value: "\(devices.count)", label: "GPUs")
            summary(value: "\(response.jobs.filter(\.ok).count)", label: "Jobs")
            summary(value: Formatters.utilization(averageUtilization), label: "Avg util")
        }
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func summary(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct GPUJobCard: View {
    let status: GPUJobStatus
    let job: Job?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: status.ok ? "memorychip.fill" : "exclamationmark.triangle")
                    .foregroundStyle(status.ok ? AnyShapeStyle(.blue) : AnyShapeStyle(.orange))
                VStack(alignment: .leading, spacing: 1) {
                    Text(job?.name ?? "Job \(status.jobID)")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(jobSubtitle)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let allocationLabel {
                    Text(allocationLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if status.ok {
                if let message = status.message {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8, alignment: .top),
                        GridItem(.flexible(), spacing: 8, alignment: .top),
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(status.gpus) { gpu in
                        GPUDeviceTile(gpu: gpu)
                    }
                }
            } else {
                Text(status.message ?? "GPU status is unavailable for this job.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
    }

    private var jobSubtitle: String {
        guard let nodes = job?.nodes, !nodes.isEmpty else { return status.jobID }
        return "\(status.jobID) · \(nodes.joined(separator: ", "))"
    }

    private var allocationLabel: String? {
        guard let count = job?.gpus, count > 0 else { return nil }
        if let nodes = job?.nodeCount, nodes > 1 {
            return "\(count) GPU/node · \(nodes) nodes"
        }
        return "\(count) allocated"
    }
}

private struct GPUDeviceTile: View {
    let gpu: GPUDevice

    var body: some View {
        VStack(spacing: 6) {
            Text(gpu.node)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            GPUUsageRings(gpu: gpu)

            RingMetricLegend(
                color: utilizationTint,
                label: "Util",
                value: Formatters.utilization(gpu.utilizationPercent)
            )
            RingMetricLegend(
                color: .purple,
                label: "Mem",
                value: memoryPercentText
            )

            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.orange)
                Text(powerText)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(memoryText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(7)
        .background(.quinary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).stroke(.separator.opacity(0.3), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(gpu.node), GPU \(gpu.index), \(gpu.name), utilization "
                + "\(Formatters.utilization(gpu.utilizationPercent)), memory \(memoryText), "
                + "power \(powerText)"
        )
    }

    private var utilizationTint: Color {
        guard let value = gpu.utilizationPercent else { return .secondary }
        if value < 10 { return .orange }
        return .blue
    }

    private var memoryText: String {
        guard let used = gpu.memoryUsedMiB, let total = gpu.memoryTotalMiB else {
            return Formatters.notAvailable
        }
        return "\(mib(used)) / \(mib(total))"
    }

    private var memoryPercentText: String {
        Formatters.percent(gpu.memoryFraction.map { $0 * 100 })
    }

    private var powerText: String {
        guard let watts = gpu.powerDrawWatts else { return Formatters.notAvailable }
        return String(format: "%.1f W", watts)
    }

    private func mib(_ value: Double) -> String {
        value >= 1024 ? String(format: "%.1f GiB", value / 1024) : String(format: "%.0f MiB", value)
    }
}

private struct GPUUsageRings: View {
    let gpu: GPUDevice

    private var utilizationFraction: Double {
        min(1, max(0, (gpu.utilizationPercent ?? 0) / 100))
    }

    private var memoryFraction: Double {
        min(1, max(0, gpu.memoryFraction ?? 0))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 7)
            Circle()
                .trim(from: 0, to: utilizationFraction)
                .stroke(.blue, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle()
                .stroke(.quaternary, lineWidth: 6)
                .frame(width: 56, height: 56)
            Circle()
                .trim(from: 0, to: memoryFraction)
                .stroke(.purple, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 56, height: 56)

            VStack(spacing: 0) {
                Text("GPU \(gpu.index)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                Text(shortModelName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 45)
        }
        .frame(width: 76, height: 76)
        .accessibilityHidden(true)
    }

    private var shortModelName: String {
        let words = gpu.name
            .replacingOccurrences(of: "NVIDIA", with: "")
            .split(separator: " ")
            .map(String.init)
        guard let index = words.firstIndex(where: { $0.contains(where: \.isNumber) }) else {
            return String((words.first ?? "GPU").prefix(8))
        }
        let token = words[index].split(separator: "-", maxSplits: 1).first.map(String.init) ?? words[index]
        if index > 0, words[index - 1].uppercased() == "RTX" {
            return "RTX \(token)"
        }
        return String(token.prefix(8))
    }
}

private struct RingMetricLegend: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }
}

private struct GPUEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "memorychip")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(.horizontal, 24)
    }
}

private struct GPUFailureView: View {
    let failure: SSHFailure
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: failure.symbolName)
                .font(.title2)
                .foregroundStyle(.orange)
            Text(failure.title).font(.callout.weight(.medium))
            Text(failure.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry", action: retry).controlSize(.small)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(.horizontal, 20)
    }
}

private struct GPUStaleFailureBanner: View {
    let failure: SSHFailure
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: failure.symbolName)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Refresh failed — showing the previous reading")
                    .font(.caption.weight(.medium))
                Text(failure.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Button("Retry", action: retry)
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}
