import SlurmBarKit
import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        TabView {
            ClusterSettingsView()
                .tabItem { Label("Clusters", systemImage: "server.rack") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 640, height: 500)
    }
}

// MARK: - Clusters

struct ClusterSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @State private var selection: UUID?
    @State private var draft: ClusterProfile?
    @State private var doctorReport: DoctorReport?
    @State private var doctorFailure: SSHFailure?
    @State private var isTesting = false

    var body: some View {
        HSplitView {
            clusterList
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
            editor
                .frame(minWidth: 380)
        }
        .onAppear {
            if selection == nil { selection = controller.settings.selectedCluster?.id }
            loadDraft()
        }
        .onChange(of: selection) { _, _ in loadDraft() }
    }

    private var clusterList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(controller.settings.clusters) { cluster in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cluster.effectiveName).font(.body)
                        Text(cluster.sshAlias).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(cluster.id)
                }
            }

            Divider()

            HStack(spacing: 4) {
                Button {
                    addCluster()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add cluster")

                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .accessibilityLabel("Remove cluster")

                Spacer()
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let binding = draftBinding {
            Form {
                Section("Connection") {
                    TextField("Display name", text: binding.displayName, prompt: Text("My Cluster"))
                    TextField("SSH alias or host", text: binding.sshAlias, prompt: Text("my-cluster"))
                    Text("A Host entry from ~/.ssh/config. SlurmBar uses your existing OpenSSH setup — keys, ProxyJump and ControlMaster all apply. It never stores keys or asks for passwords.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Username override", text: binding.username, prompt: Text("optional"))
                    TextField("Slurm user to query", text: binding.slurmUser, prompt: Text("defaults to the SSH user"))
                }

                Section("Remote agent") {
                    TextField("Agent command", text: Binding(
                        get: { binding.wrappedValue.agentCommandString },
                        set: { binding.wrappedValue.agentCommand = ClusterProfile.parseAgentCommand($0) }
                    ))
                    .font(.system(.body, design: .monospaced))

                    Text("Run ./scripts/install-agent.sh \(binding.wrappedValue.sshAlias.isEmpty ? "<alias>" : binding.wrappedValue.sshAlias) to install the agent into your home directory on the cluster.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField("Progress directory", text: binding.progressDirectory,
                              prompt: Text("~/.local/state/slurmbar/jobs"))
                        .font(.system(.body, design: .monospaced))
                }

                Section("Refresh") {
                    LabeledContent("Polling interval") {
                        Stepper(
                            "\(binding.wrappedValue.pollIntervalSeconds) s",
                            value: binding.pollIntervalSeconds,
                            in: 10...600,
                            step: 5
                        )
                    }
                    LabeledContent("Command timeout") {
                        Stepper(
                            "\(binding.wrappedValue.timeoutSeconds) s",
                            value: binding.timeoutSeconds,
                            in: 3...60
                        )
                    }
                    LabeledContent("SSH connect timeout") {
                        Stepper(
                            "\(binding.wrappedValue.connectTimeoutSeconds) s",
                            value: binding.connectTimeoutSeconds,
                            in: 2...60
                        )
                    }
                    LabeledContent("Job history") {
                        Stepper(
                            "\(binding.wrappedValue.historyHours) h",
                            value: binding.historyHours,
                            in: 0...168,
                            step: 1
                        )
                    }
                    Text("The popover refreshes more often while it is open and backs off when the cluster is unreachable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    if !binding.wrappedValue.validationErrors.isEmpty {
                        ForEach(binding.wrappedValue.validationErrors, id: \.self) { error in
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    HStack {
                        Button("Save") { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!binding.wrappedValue.isValid)
                        Button("Test Connection") { runDoctor() }
                            .disabled(isTesting || !binding.wrappedValue.isValid)
                        if isTesting { ProgressView().controlSize(.small) }
                    }
                }

                if doctorReport != nil || doctorFailure != nil {
                    Section("Test results") {
                        DoctorResultView(report: doctorReport, failure: doctorFailure)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView {
                Label("No cluster selected", systemImage: "server.rack")
            } description: {
                Text("Add a cluster to start monitoring Slurm jobs.")
            } actions: {
                Button("Add Cluster") { addCluster() }
            }
        }
    }

    private var draftBinding: Binding<ClusterProfile>? {
        guard draft != nil else { return nil }
        return Binding(
            get: { draft ?? ClusterProfile() },
            set: { draft = $0 }
        )
    }

    private func loadDraft() {
        doctorReport = nil
        doctorFailure = nil
        guard let selection else {
            draft = nil
            return
        }
        draft = controller.settings.clusters.first { $0.id == selection }
    }

    private func addCluster() {
        let profile = ClusterProfile(displayName: "New Cluster", sshAlias: "")
        controller.settingsStore.addCluster(profile)
        selection = profile.id
        draft = profile
    }

    private func removeSelected() {
        guard let selection else { return }
        controller.settingsStore.removeCluster(id: selection)
        self.selection = controller.settings.clusters.first?.id
        loadDraft()
    }

    private func save() {
        guard let draft else { return }
        controller.settingsStore.updateCluster(draft)
    }

    private func runDoctor() {
        guard let draft else { return }
        controller.settingsStore.updateCluster(draft)
        isTesting = true
        doctorReport = nil
        doctorFailure = nil
        Task {
            // Use the same transport as the monitor. In demo mode this stays file-backed and
            // must never try to resolve or contact the synthetic SSH alias.
            let client = AppController.clientFactory()(draft)
            do {
                doctorReport = try await client.doctor()
            } catch let failure as SSHFailure {
                doctorFailure = failure
            } catch {
                doctorFailure = .launchFailed(detail: error.localizedDescription)
            }
            isTesting = false
        }
    }
}

struct DoctorResultView: View {
    let report: DoctorReport?
    let failure: SSHFailure?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure {
                Label(failure.title, systemImage: failure.symbolName)
                    .font(.callout.weight(.medium))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let suggestion = failure.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let report {
                ForEach(report.checks) { check in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: check.status.symbolName)
                            .foregroundStyle(tint(for: check.status))
                            .imageScale(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(check.title).font(.caption.weight(.medium))
                                if let value = check.value {
                                    Text(value)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let detail = check.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func tint(for status: DoctorCheck.Status) -> Color {
        switch status {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        case .skip: return .secondary
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Display", selection: binding(\.menuBarDisplayMode)) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text(controller.settings.menuBarDisplayMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if controller.settings.menuBarDisplayMode == .pinnedJobPercent {
                    Picker("Pinned job", selection: Binding<String>(
                        get: { controller.settings.pinnedJobID ?? "" },
                        set: { newValue in
                            controller.settingsStore.update { settings in
                                settings.pinnedJobID = newValue.isEmpty ? nil : newValue
                            }
                        }
                    )) {
                        Text("Longest-running job with progress").tag("")
                        ForEach(controller.monitor?.groupedJobs.running ?? []) { job in
                            Text("\(job.name) (\(job.jobID))").tag(job.jobID)
                        }
                    }
                }

                Toggle("Show an indicator when a job fails", isOn: binding(\.showFailureIndicatorInMenuBar))
            }

            Section("Startup") {
                Toggle("Launch SlurmBar at login", isOn: binding(\.launchAtLogin))

                switch controller.launchAtLoginStatus {
                case .enabled:
                    Label("Registered with macOS.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .requiresApproval:
                    // Registration succeeded but macOS is holding it for the user to allow.
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Waiting for your approval in System Settings.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open Login Items…") { controller.openLoginItemsSettings() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                case .unavailable:
                    Text("Unavailable: this build is running as a bare executable rather than an app bundle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .notEnabled:
                    Text("SlurmBar has no window, so it is easy to forget to start it. Turning this on keeps your jobs a click away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = controller.launchAtLoginError {
                    Label(error, systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Requires SlurmBar.app to be in /Applications.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Jobs") {
                Picker("Default cluster", selection: Binding(
                    get: { controller.settings.selectedClusterID ?? controller.settings.clusters.first?.id },
                    set: { newValue in
                        guard let newValue else { return }
                        controller.settingsStore.selectCluster(id: newValue)
                    }
                )) {
                    ForEach(controller.settings.clusters) { cluster in
                        Text(cluster.effectiveName).tag(Optional(cluster.id))
                    }
                }
                .disabled(controller.settings.clusters.isEmpty)

                LabeledContent("Show finished jobs from the last") {
                    Stepper("\(controller.settings.recentlyFinishedHours) h",
                            value: binding(\.recentlyFinishedHours), in: 1...168)
                }

                Toggle("Always hide failed jobs", isOn: binding(\.hideFailedJobs))
                Toggle("Always hide cancelled jobs", isOn: binding(\.hideCancelledJobs))
                Text("These apply automatically to every refresh. To clear jobs one at a time, use the trash menu in the popover instead. Either way the jobs are only removed from this list — they stay in Slurm's accounting — and the counts drop to match, so the summary always agrees with what you see. Running and pending jobs are never hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Refresh behaviour") {
                Toggle("Refresh more often while the popover is open", isOn: binding(\.refreshWhenPopoverOpen))
                Toggle("Pause polling when no jobs are active", isOn: binding(\.pauseWhenNoActiveJobs))
                Text("SlurmBar polls on a schedule rather than continuously, to keep load on the shared Slurm controller low.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { newValue in
                controller.settingsStore.update { $0[keyPath: keyPath] = newValue }
            }
        )
    }
}

// MARK: - Notifications

struct NotificationSettingsView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Form {
            Section("Notify me when") {
                Toggle("A job completes", isOn: binding(\.jobCompleted))
                Toggle("A job fails", isOn: binding(\.jobFailed))
                Toggle("A job times out", isOn: binding(\.jobTimedOut))
                Toggle("A job runs out of memory", isOn: binding(\.jobOutOfMemory))
                Toggle("A workload's loss becomes NaN", isOn: binding(\.lossBecameNaN))
                Toggle("A workload stops reporting progress", isOn: binding(\.progressStale))
                Toggle("The SSH connection is lost", isOn: binding(\.connectionLost))
            }

            Section {
                Text("SlurmBar notifies on state *transitions* only. The first refresh after launch establishes a baseline silently, so restarting the app never replays yesterday's finished jobs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Loss-becomes-NaN requires the structured progress integration; Slurm itself has no idea what your loss is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ keyPath: WritableKeyPath<NotificationPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.settings.notifications[keyPath: keyPath] },
            set: { newValue in
                controller.settingsStore.update { $0.notifications[keyPath: keyPath] = newValue }
            }
        )
    }
}

#if DEBUG
#Preview("Doctor results") {
    Form {
        DoctorResultView(report: PreviewData.doctorReport, failure: nil)
    }
    .formStyle(.grouped)
    .frame(width: 460, height: 420)
}
#endif
