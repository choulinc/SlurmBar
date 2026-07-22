import Combine
import Foundation

/// Owns one cluster's refresh loop and the state the UI renders.
///
/// Concurrency rules, which are the whole reason this is a class rather than scattered state:
///
/// * exactly one refresh is in flight at a time — a second request while one is running is
///   dropped rather than queued, so an impatient user cannot multiply the load on the Slurm
///   controller;
/// * every refresh is a cancellable `Task`, and changing settings cancels the in-flight one;
/// * the last successful snapshot is never discarded on failure, so the popover keeps showing
///   real data with a stale marker instead of going blank.
@MainActor
public final class ClusterMonitor: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var profile: ClusterProfile
    @Published public private(set) var snapshot: Snapshot?
    @Published public private(set) var lastSuccessfulFetch: Date?
    @Published public private(set) var connection: ConnectionState = .idle
    @Published public private(set) var isStaleFromCache: Bool = false
    @Published public private(set) var lastDoctorReport: DoctorReport?
    @Published public private(set) var consecutiveFailures: Int = 0
    @Published public private(set) var hasUnacknowledgedFailure: Bool = false

    // MARK: - Dependencies

    private let cache: SnapshotCache
    private let notifier: NotificationDelivering
    private var detector: JobEventDetector
    private var pollingPolicy: PollingPolicy
    private let stalenessPolicy: StalenessPolicy
    private let clientFactory: @Sendable (ClusterProfile) -> AgentClient
    private let now: () -> Date

    // MARK: - Private state

    private var refreshTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?
    private var isPopoverOpen = false
    private var notificationPreferences: NotificationPreferences
    private var behaviour: RefreshBehaviour
    private var knownFailedJobIDs: Set<String> = []
    /// Latched so a cluster that stays unreachable notifies once, not once per poll.
    private var didNotifyConnectionLoss = false
    /// True once a refresh has actually succeeded in this session. `connection` cannot answer
    /// this: `refresh()` moves it to `.connecting` before the attempt, so by the time a failure
    /// is handled the previous `.connected` state is already gone.
    private var hadLiveSuccess = false

    /// The user-facing refresh settings that live in ``AppSettings`` rather than the profile.
    public struct RefreshBehaviour: Hashable, Sendable {
        public var refreshWhenPopoverOpen: Bool
        public var pauseWhenNoActiveJobs: Bool
        /// Display window for finished jobs. Never wider than what was actually fetched.
        public var recentlyFinishedHours: Int?
        public var hideFailedJobs: Bool
        public var hideCancelledJobs: Bool
        public var dismissedJobIDs: Set<String>

        public init(
            refreshWhenPopoverOpen: Bool = true,
            pauseWhenNoActiveJobs: Bool = false,
            recentlyFinishedHours: Int? = nil,
            hideFailedJobs: Bool = false,
            hideCancelledJobs: Bool = false,
            dismissedJobIDs: Set<String> = []
        ) {
            self.refreshWhenPopoverOpen = refreshWhenPopoverOpen
            self.pauseWhenNoActiveJobs = pauseWhenNoActiveJobs
            self.recentlyFinishedHours = recentlyFinishedHours
            self.hideFailedJobs = hideFailedJobs
            self.hideCancelledJobs = hideCancelledJobs
            self.dismissedJobIDs = dismissedJobIDs
        }

        public static let `default` = RefreshBehaviour()

        public init(settings: AppSettings, clusterID: UUID? = nil) {
            self.init(
                refreshWhenPopoverOpen: settings.refreshWhenPopoverOpen,
                pauseWhenNoActiveJobs: settings.pauseWhenNoActiveJobs,
                recentlyFinishedHours: settings.recentlyFinishedHours,
                hideFailedJobs: settings.hideFailedJobs,
                hideCancelledJobs: settings.hideCancelledJobs,
                dismissedJobIDs: clusterID.map { settings.dismissed(for: $0) } ?? []
            )
        }
    }

    public init(
        profile: ClusterProfile,
        cache: SnapshotCache = SnapshotCache(),
        notifier: NotificationDelivering,
        notificationPreferences: NotificationPreferences = .default,
        behaviour: RefreshBehaviour = .default,
        stalenessPolicy: StalenessPolicy = .default,
        now: @escaping () -> Date = Date.init,
        clientFactory: @escaping @Sendable (ClusterProfile) -> AgentClient = { AgentClient.live(profile: $0) }
    ) {
        self.profile = profile
        self.cache = cache
        self.notifier = notifier
        self.notificationPreferences = notificationPreferences
        self.behaviour = behaviour
        self.stalenessPolicy = stalenessPolicy
        self.now = now
        self.clientFactory = clientFactory
        self.detector = JobEventDetector(clusterName: profile.effectiveName)
        self.pollingPolicy = PollingPolicy.fromBaseInterval(profile.pollIntervalSeconds)

        loadCachedSnapshot()
    }

    deinit {
        refreshTask?.cancel()
        scheduledTask?.cancel()
    }

    // MARK: - Derived state for the UI

    public var groupedJobs: GroupedJobs {
        guard let snapshot else { return .empty }
        return JobGrouper.group(jobs: snapshot.jobs, filter: displayFilter, now: now())
    }

    public var displayFilter: JobDisplayFilter {
        // The profile decides how far back the agent *fetches*; the setting decides how far
        // back the popover *shows*. Showing more than was fetched is impossible, so clamp.
        let displayHours = min(
            behaviour.recentlyFinishedHours ?? profile.historyHours,
            profile.historyHours
        )
        return JobDisplayFilter(
            hideFailed: behaviour.hideFailedJobs,
            hideCancelled: behaviour.hideCancelledJobs,
            recentHours: displayHours,
            dismissedJobIDs: behaviour.dismissedJobIDs
        )
    }

    /// Derived from the jobs actually on screen, so the counts can never contradict the list.
    public var summary: JobSummary { groupedJobs.summary }

    public var warnings: [AgentWarning] { snapshot?.warnings ?? [] }

    /// Warnings worth surfacing above the job list. Info-level noise stays in the detail view.
    public var prominentWarnings: [AgentWarning] {
        warnings.filter { $0.severity != .info }
    }

    public var freshness: StalenessPolicy.Freshness? {
        guard let snapshot else { return nil }
        return stalenessPolicy.freshness(of: snapshot.generatedAt, now: now())
    }

    /// True when the popover should mark the visible data as not current.
    public var isShowingStaleData: Bool {
        if isStaleFromCache { return true }
        if case .failed = connection { return snapshot != nil }
        guard let freshness else { return false }
        return freshness == .stale
    }

    public var emptyStateReason: EmptyStateReason? {
        EmptyStateResolver.resolve(snapshot: snapshot, connection: connection, hasClusters: true)
    }

    /// Every job id the current snapshot knows about, for pruning stale dismissals.
    public var knownJobIDs: Set<String> {
        Set(snapshot?.jobs.map(\.jobID) ?? [])
    }

    /// Finished jobs currently visible — what "remove all finished" would act on.
    public var dismissableJobIDs: [String] {
        groupedJobs.recentlyFinished.map(\.jobID)
    }

    /// Just the cancelled and preempted ones, for the common "clear the noise" case.
    public var cancelledJobIDs: [String] {
        groupedJobs.recentlyFinished
            .filter { $0.state == .cancelled || $0.state == .preempted }
            .map(\.jobID)
    }

    public var hasActiveJobs: Bool {
        guard let snapshot else { return false }
        return snapshot.jobs.contains { $0.state.isActive }
    }

    // MARK: - Lifecycle

    public func start() {
        Task { await notifier.requestAuthorizationIfNeeded() }
        refresh(reason: .automatic)
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        scheduledTask?.cancel()
        scheduledTask = nil
    }

    /// Apply a changed profile. Cancels anything in flight, because it targeted the old config.
    public func apply(
        profile: ClusterProfile,
        notificationPreferences: NotificationPreferences,
        behaviour: RefreshBehaviour = .default
    ) {
        let clusterChanged = profile.id != self.profile.id
            || profile.sshAlias != self.profile.sshAlias
            || profile.agentCommand != self.profile.agentCommand
            || profile.slurmUser != self.profile.slurmUser

        self.profile = profile
        self.notificationPreferences = notificationPreferences
        self.behaviour = behaviour
        self.pollingPolicy = PollingPolicy.fromBaseInterval(profile.pollIntervalSeconds)

        if clusterChanged {
            stop()
            detector = JobEventDetector(clusterName: profile.effectiveName)
            knownFailedJobIDs.removeAll()
            didNotifyConnectionLoss = false
            hadLiveSuccess = false
            snapshot = nil
            isStaleFromCache = false
            connection = .idle
            loadCachedSnapshot()
            refresh(reason: .automatic)
        } else {
            scheduleNextPoll()
        }
    }

    public func popoverDidOpen() {
        isPopoverOpen = true
        acknowledgeFailures()
        // Opening the popover is an explicit "show me now", but only if the data is not fresh.
        if freshness != .fresh {
            refresh(reason: .manual)
        } else {
            scheduleNextPoll()
        }
    }

    public func popoverDidClose() {
        isPopoverOpen = false
        scheduleNextPoll()
    }

    public func acknowledgeFailures() {
        hasUnacknowledgedFailure = false
    }

    // MARK: - Refresh

    public enum RefreshReason: Sendable {
        case manual
        case automatic
    }

    /// Kick off a refresh. Returns immediately; a refresh already in flight wins.
    public func refresh(reason: RefreshReason = .manual) {
        guard profile.isValid else {
            connection = .unconfigured
            return
        }
        guard refreshTask == nil else { return }

        scheduledTask?.cancel()
        scheduledTask = nil
        connection = .connecting

        let client = clientFactory(profile)
        refreshTask = Task { [weak self] in
            await self?.performRefresh(client: client)
        }
    }

    private func performRefresh(client: AgentClient) async {
        defer {
            refreshTask = nil
            scheduleNextPoll()
        }

        do {
            let fetched = try await client.snapshot()
            guard !Task.isCancelled else { return }
            await handleSuccess(fetched)
        } catch let failure as SSHFailure {
            guard !Task.isCancelled, failure != .cancelled else { return }
            await handleFailure(failure)
        } catch {
            await handleFailure(.launchFailed(detail: error.localizedDescription))
        }
    }

    private func handleSuccess(_ fetched: Snapshot) async {
        let timestamp = now()
        snapshot = fetched
        lastSuccessfulFetch = timestamp
        isStaleFromCache = false
        consecutiveFailures = 0
        didNotifyConnectionLoss = false
        hadLiveSuccess = true
        connection = .connected(at: timestamp)
        cache.store(fetched, clusterID: profile.id, fetchedAt: timestamp)

        let events = detector.process(snapshot: fetched, now: timestamp)
        for event in events where notificationPreferences.isEnabled(for: event.kind) {
            await notifier.deliver(event)
        }

        let failures = Set(fetched.jobs.filter { $0.state.isFailure }.map(\.jobID))
        if !failures.subtracting(knownFailedJobIDs).isEmpty, !detector.needsBaseline {
            hasUnacknowledgedFailure = true
        }
        knownFailedJobIDs = failures
    }

    private func handleFailure(_ failure: SSHFailure) async {
        consecutiveFailures += 1
        connection = .failed(failure, hasCachedData: snapshot != nil)
        if snapshot != nil {
            isStaleFromCache = true
        }

        // Only worth an alert when a working connection breaks, and only once per outage.
        // Launching while the VPN is already down is not "the connection was lost".
        guard hadLiveSuccess, !didNotifyConnectionLoss,
              notificationPreferences.isEnabled(for: .connectionLost)
        else { return }
        didNotifyConnectionLoss = true
        await notifier.deliver(
            JobEvent.connectionLost(clusterName: profile.effectiveName, failure: failure)
        )
    }

    // MARK: - Scheduling

    private func scheduleNextPoll() {
        scheduledTask?.cancel()
        scheduledTask = nil

        let context = PollingPolicy.Context(
            isPopoverOpen: isPopoverOpen,
            hasActiveJobs: hasActiveJobs,
            consecutiveFailures: consecutiveFailures,
            pauseWhenIdle: behaviour.pauseWhenNoActiveJobs,
            refreshWhilePopoverOpen: behaviour.refreshWhenPopoverOpen
        )
        guard let interval = pollingPolicy.nextInterval(for: context) else { return }

        scheduledTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.refresh(reason: .automatic) }
        }
    }

    private func loadCachedSnapshot() {
        guard let cached = cache.load(clusterID: profile.id) else { return }
        snapshot = cached.snapshot
        lastSuccessfulFetch = cached.fetchedAt
        isStaleFromCache = true
        // The cached snapshot seeds the notification baseline: without this, every job that
        // finished while the app was closed would notify on the first refresh after launch.
        _ = detector.process(snapshot: cached.snapshot, now: cached.fetchedAt)
        knownFailedJobIDs = Set(cached.snapshot.jobs.filter { $0.state.isFailure }.map(\.jobID))
    }

    // MARK: - On-demand actions

    public func runDoctor() async -> Result<DoctorReport, SSHFailure> {
        let client = clientFactory(profile)
        do {
            let report = try await client.doctor()
            lastDoctorReport = report
            return .success(report)
        } catch let failure as SSHFailure {
            return .failure(failure)
        } catch {
            return .failure(.launchFailed(detail: error.localizedDescription))
        }
    }

    /// Fetches a log tail. Only called from the job detail view, never from the poll loop.
    public func loadLogs(job: Job, stream: LogStream, lines: Int = 200) async -> Result<LogTail, SSHFailure> {
        let client = clientFactory(profile)
        let knownPath = stream == .stdout ? job.stdoutPath : job.stderrPath
        do {
            return .success(try await client.logs(
                jobID: job.jobID,
                stream: stream,
                lines: lines,
                knownPath: knownPath
            ))
        } catch let failure as SSHFailure {
            return .failure(failure)
        } catch {
            return .failure(.launchFailed(detail: error.localizedDescription))
        }
    }

    public func loadJobDetail(jobID: String) async -> Result<JobDetailResponse, SSHFailure> {
        let client = clientFactory(profile)
        do {
            return .success(try await client.jobDetail(jobID: jobID))
        } catch let failure as SSHFailure {
            return .failure(failure)
        } catch {
            return .failure(.launchFailed(detail: error.localizedDescription))
        }
    }

    /// Cancels a job. The caller is responsible for having obtained explicit confirmation; this
    /// is never reachable from an automatic code path.
    public func cancelJob(jobID: String) async -> Result<CancelResult, SSHFailure> {
        let client = clientFactory(profile)
        do {
            let result = try await client.cancel(jobID: jobID)
            refresh(reason: .manual)
            return .success(result)
        } catch let failure as SSHFailure {
            return .failure(failure)
        } catch {
            return .failure(.launchFailed(detail: error.localizedDescription))
        }
    }

    /// The equivalent Terminal command, for the "Copy SSH command" action.
    public func debugCommandLine() -> String {
        clientFactory(profile).debugCommandLine()
    }
}
