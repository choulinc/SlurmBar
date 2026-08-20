import Combine
import SlurmBarKit
import SwiftUI
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// Top-level app state: owns the settings store and the monitor for the selected cluster.
///
/// One monitor at a time, rebuilt when the selection changes. Monitoring every configured
/// cluster simultaneously would multiply SSH connections and Slurm controller load for data the
/// user is not looking at.
@MainActor
final class AppController: ObservableObject {
    @Published private(set) var monitor: ClusterMonitor?
    @Published var settingsStore: SettingsStore

    private var cancellables: Set<AnyCancellable> = []
    private var monitorObservation: AnyCancellable?
    private let notifier: NotificationDelivering
    /// Surfaced in Settings when macOS refuses to register the login item.
    @Published private(set) var launchAtLoginError: String?
    /// Surfaced beside the interactive-login button if Terminal could not be opened.
    @Published private(set) var interactiveAuthLaunchError: String?
    private var interactiveAuthRetryTask: Task<Void, Never>?

    init(settingsStore: SettingsStore? = nil, notifier: NotificationDelivering? = nil) {
        // In demo mode everything is redirected to a throwaway directory. Overriding HOME is
        // not enough: FileManager.urls(for:) resolves the real user directories regardless,
        // so a demo run would otherwise read the real cluster profile and overwrite its
        // cached snapshot with fabricated jobs.
        let store = settingsStore ?? SettingsStore(fileURL: AppController.demoSettingsURL())
        self.settingsStore = store
        #if canImport(UserNotifications)
        self.notifier = notifier ?? UserNotificationService()
        #else
        self.notifier = notifier ?? RecordingNotifier()
        #endif

        store.$settings
            .removeDuplicates()
            .sink { [weak self] settings in
                self?.applySettings(settings)
            }
            .store(in: &cancellables)

        applySettings(store.settings)
    }

    var settings: AppSettings { settingsStore.settings }

    // MARK: - Derived UI state

    var menuBarLabel: MenuBarLabel {
        MenuBarLabelBuilder.make(
            mode: settings.menuBarDisplayMode,
            snapshot: monitor?.snapshot,
            summary: monitor?.summary,
            connection: monitor?.connection ?? (settings.hasConfiguredCluster ? .idle : .unconfigured),
            pinnedJobID: settings.pinnedJobID,
            hasUnacknowledgedFailure: monitor?.hasUnacknowledgedFailure ?? false,
            showFailureIndicator: settings.showFailureIndicatorInMenuBar
        )
    }

    var connection: ConnectionState {
        monitor?.connection ?? (settings.hasConfiguredCluster ? .idle : .unconfigured)
    }

    var emptyStateReason: EmptyStateReason? {
        guard settings.hasConfiguredCluster else { return .noClusterConfigured }
        return monitor?.emptyStateReason
    }

    // MARK: - Actions

    func refresh() {
        monitor?.refresh(reason: .manual)
    }

    func popoverDidOpen() {
        monitor?.popoverDidOpen()
    }

    func popoverDidClose() {
        monitor?.popoverDidClose()
    }

    func selectCluster(id: UUID) {
        settingsStore.selectCluster(id: id)
    }

    /// Opens the selected profile's real OpenSSH login in Terminal. Password and OTP entry stay
    /// entirely inside Terminal; the menu bar app only schedules a few bounded retries so it can
    /// recover as soon as the new ControlMaster is available.
    func authenticateInteractively(profile: ClusterProfile? = nil) {
        guard let profile = profile ?? settings.selectedCluster else { return }
        do {
            try InteractiveSSHLoginLauncher.open(profile: profile)
            interactiveAuthLaunchError = nil
            interactiveAuthRetryTask?.cancel()
            interactiveAuthRetryTask = Task { [weak self] in
                for delay in [8, 15, 30] {
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.refresh()
                }
            }
        } catch {
            interactiveAuthLaunchError = error.localizedDescription
        }
    }

    // MARK: - Hiding finished jobs

    /// Remove one finished job from the list on this Mac. Never touches the cluster.
    func dismissJob(_ job: Job) {
        guard let clusterID = settings.selectedCluster?.id else { return }
        let known = monitor?.knownJobIDs ?? []
        settingsStore.update { settings in
            settings.dismiss(jobID: job.jobID, clusterID: clusterID)
            settings.pruneDismissed(clusterID: clusterID, knownJobIDs: known)
        }
    }

    func removeAllCancelled() {
        removeJobs(monitor?.cancelledJobIDs ?? [])
    }

    func dismissAllFinished() {
        guard let clusterID = settings.selectedCluster?.id, let monitor else { return }
        let ids = monitor.dismissableJobIDs
        guard !ids.isEmpty else { return }
        let known = monitor.knownJobIDs
        settingsStore.update { settings in
            settings.dismiss(jobIDs: ids, clusterID: clusterID)
            settings.pruneDismissed(clusterID: clusterID, knownJobIDs: known)
        }
    }

    private func removeJobs(_ ids: [String]) {
        guard let clusterID = settings.selectedCluster?.id, !ids.isEmpty else { return }
        let known = monitor?.knownJobIDs ?? []
        settingsStore.update { settings in
            settings.dismiss(jobIDs: ids, clusterID: clusterID)
            settings.pruneDismissed(clusterID: clusterID, knownJobIDs: known)
        }
    }

    var cancelledCount: Int { monitor?.cancelledJobIDs.count ?? 0 }

    func restoreDismissedJobs() {
        guard let clusterID = settings.selectedCluster?.id else { return }
        settingsStore.update { $0.restoreDismissed(clusterID: clusterID) }
    }

    var dismissedCount: Int {
        guard let clusterID = settings.selectedCluster?.id else { return 0 }
        return settings.dismissed(for: clusterID).count
    }

    func setHideFailed(_ value: Bool) { settingsStore.update { $0.hideFailedJobs = value } }
    func setHideCancelled(_ value: Bool) { settingsStore.update { $0.hideCancelledJobs = value } }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings application

    private func applySettings(_ settings: AppSettings) {
        applyLaunchAtLogin(settings.launchAtLogin)

        guard let profile = settings.selectedCluster, profile.isValid else {
            monitor?.stop()
            monitor = nil
            monitorObservation = nil
            return
        }

        if let monitor, monitor.profile.id == profile.id {
            monitor.apply(
                profile: profile,
                notificationPreferences: settings.notifications,
                behaviour: ClusterMonitor.RefreshBehaviour(settings: settings, clusterID: profile.id)
            )
            return
        }

        monitor?.stop()
        let newMonitor = ClusterMonitor(
            profile: profile,
            cache: AppController.snapshotCache(),
            notifier: notifier,
            notificationPreferences: settings.notifications,
            behaviour: ClusterMonitor.RefreshBehaviour(settings: settings, clusterID: profile.id),
            clientFactory: AppController.clientFactory()
        )
        // MenuBarExtra's label does not observe a nested ObservableObject, so republish its
        // changes as our own to keep the menu bar text live.
        monitorObservation = newMonitor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        monitor = newMonitor
        newMonitor.start()
    }

    /// Where snapshots come from.
    ///
    /// Normally SSH. When `SLURMBAR_DEMO_SNAPSHOT` points at a readable JSON file, that file is
    /// served instead — used for documentation screenshots so no real cluster, account name or
    /// project path ever ends up in a published image.
    ///
    /// This is opt-in via an environment variable that must name a file the user created. The
    /// shipping app contains no fabricated jobs of its own.
    /// Root of the throwaway directory used in demo mode, or nil when running normally.
    static var demoRoot: URL? {
        guard let path = ProcessInfo.processInfo.environment["SLURMBAR_DEMO_SNAPSHOT"],
              !path.isEmpty
        else { return nil }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlurmBarDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Settings location: a scratch file in demo mode, the real one otherwise.
    static func demoSettingsURL() -> URL? {
        guard let root = demoRoot else { return nil }
        let url = root.appendingPathComponent("settings.json")
        // A demo is a deterministic disposable environment. Recreate it on each launch so old
        // screenshot sessions cannot leave stale profiles or preferences behind.
        let profile = ClusterProfile(displayName: "demo-cluster", sshAlias: "demo-cluster")
        var settings = AppSettings(clusters: [profile], selectedClusterID: profile.id)
        settings.menuBarDisplayMode = .counts
        settings.didAskAboutLaunchAtLogin = true
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(settings).write(to: url, options: .atomic)
        return url
    }

    static func snapshotCache() -> SnapshotCache {
        guard let root = demoRoot else { return SnapshotCache() }
        return SnapshotCache(directory: root.appendingPathComponent("snapshots", isDirectory: true))
    }

    static func clientFactory() -> @Sendable (ClusterProfile) -> AgentClient {
        guard let path = ProcessInfo.processInfo.environment["SLURMBAR_DEMO_SNAPSHOT"],
              !path.isEmpty
        else {
            return { AgentClient.live(profile: $0) }
        }
        NSLog("SlurmBar: DEMO MODE — serving %@ instead of contacting a cluster", path)
        let runner = FileBackedRunner(path: (path as NSString).expandingTildeInPath)
        return { AgentClient(runner: runner, profile: $0) }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        #if canImport(ServiceManagement)
        guard Bundle.main.bundleIdentifier != nil else { return }
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("SlurmBar: could not change launch-at-login: %@", String(describing: error))
            launchAtLoginError = Self.describeLaunchAtLoginFailure(error)
        }
        #endif
    }

    /// What macOS currently thinks about starting SlurmBar at login.
    enum LaunchAtLoginStatus {
        case enabled
        /// Registered, but the user has to approve it in System Settings > General > Login Items.
        case requiresApproval
        case notEnabled
        /// Only a bundled app can register; a bare executable cannot.
        case unavailable
    }

    var launchAtLoginStatus: LaunchAtLoginStatus {
        #if canImport(ServiceManagement)
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .notEnabled
        }
        #else
        return .unavailable
        #endif
    }

    /// Opens the pane where the user approves or revokes login items.
    func openLoginItemsSettings() {
        #if canImport(ServiceManagement)
        SMAppService.openSystemSettingsLoginItems()
        #endif
    }

    /// Ask once, on first run, rather than silently doing nothing.
    ///
    /// `SMAppService` has no permission dialog of its own — registering just succeeds, and the
    /// user can revoke it later in System Settings. So the choice has to be offered explicitly,
    /// or the feature is one nobody ever discovers.
    func promptForLaunchAtLoginIfNeeded() {
        guard !settings.didAskAboutLaunchAtLogin else { return }
        guard Bundle.main.bundleIdentifier != nil else { return }
        // Only worth asking once there is a cluster to monitor.
        guard settings.hasConfiguredCluster else { return }
        guard launchAtLoginStatus != .enabled else {
            settingsStore.update { $0.didAskAboutLaunchAtLogin = true }
            return
        }

        settingsStore.update { $0.didAskAboutLaunchAtLogin = true }

        let alert = NSAlert()
        alert.messageText = "Start SlurmBar when you log in?"
        alert.informativeText = """
        SlurmBar lives in the menu bar and has no window, so it is easy to forget to start it.         Starting it automatically means your jobs are always a click away.

        You can change this any time in Settings, or in System Settings > General > Login Items.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start at Login")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            settingsStore.update { $0.launchAtLogin = true }
            if launchAtLoginStatus == .requiresApproval {
                let followUp = NSAlert()
                followUp.messageText = "One more step"
                followUp.informativeText =
                    "macOS needs you to allow SlurmBar in System Settings > General > Login Items."
                followUp.addButton(withTitle: "Open Login Items")
                followUp.addButton(withTitle: "Later")
                if followUp.runModal() == .alertFirstButtonReturn {
                    openLoginItemsSettings()
                }
            }
        }
    }

    static func describeLaunchAtLoginFailure(_ error: Error) -> String {
        let nsError = error as NSError
        // Registration fails for an app that is not in /Applications, which is the usual cause.
        if nsError.domain == "SMAppServiceErrorDomain" || nsError.code == 1 {
            return "macOS refused to register SlurmBar. Move SlurmBar.app to /Applications and try again."
        }
        return nsError.localizedDescription
    }
}
