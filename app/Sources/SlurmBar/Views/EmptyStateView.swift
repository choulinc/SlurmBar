import SlurmBarKit
import SwiftUI

/// Shown instead of a blank window. Always says which specific situation applies and offers the
/// action that resolves it.
struct EmptyStateView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.openSettings) private var openSettings
    let reason: EmptyStateReason

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: reason.symbolName)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)

            Text(reason.title)
                .font(.callout.weight(.medium))

            Text(reason.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            actions
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(reason.title). \(reason.message)")
    }

    @ViewBuilder
    private var actions: some View {
        switch reason {
        case .noClusterConfigured:
            Button("Set Up SlurmBar…") { openSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 2)
        case .neverRefreshed, .noJobs:
            Button("Refresh") { controller.refresh() }
                .controlSize(.small)
                .padding(.top, 2)
        case .slurmUnavailable, .agentUnavailable, .disconnected:
            HStack(spacing: 8) {
                Button("Retry") { controller.refresh() }
                    .controlSize(.small)
                Button("Settings…") { openSettings() }
                    .controlSize(.small)
            }
            .padding(.top, 2)
        }
    }
}

#if DEBUG
#Preview("No cluster") {
    EmptyStateView(reason: .noClusterConfigured)
        .environmentObject(AppController(settingsStore: SettingsStore(fileURL: URL(fileURLWithPath: "/dev/null")),
                                         notifier: RecordingNotifier()))
        .frame(width: PopoverRootView.width)
}

#Preview("No jobs") {
    EmptyStateView(reason: .noJobs)
        .environmentObject(AppController(settingsStore: SettingsStore(fileURL: URL(fileURLWithPath: "/dev/null")),
                                         notifier: RecordingNotifier()))
        .frame(width: PopoverRootView.width)
}

#Preview("Disconnected") {
    EmptyStateView(reason: .disconnected(.hostUnreachable(detail: "ssh: connect to host example.org port 22: Operation timed out")))
        .environmentObject(AppController(settingsStore: SettingsStore(fileURL: URL(fileURLWithPath: "/dev/null")),
                                         notifier: RecordingNotifier()))
        .frame(width: PopoverRootView.width)
}
#endif
