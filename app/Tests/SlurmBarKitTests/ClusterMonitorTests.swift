import XCTest
@testable import SlurmBarKit

@MainActor
final class ClusterMonitorTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slurmbar-monitor-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    /// The example snapshots carry a fixed `generated_at`, so the monitor is given a clock
    /// pinned just after it. Otherwise every freshness assertion would depend on the wall clock
    /// at the moment the suite runs, and the fixtures would "go stale" on their own.
    private static let fixtureNow = isoDate("2026-07-22T02:30:30Z")

    private func makeMonitor(
        runner: StubRemoteRunner,
        profile: ClusterProfile = ClusterProfile(displayName: "Example", sshAlias: "example-cluster"),
        notifier: RecordingNotifier = RecordingNotifier(),
        now: @escaping () -> Date = { ClusterMonitorTests.fixtureNow }
    ) -> (ClusterMonitor, RecordingNotifier) {
        let monitor = ClusterMonitor(
            profile: profile,
            cache: SnapshotCache(directory: cacheDirectory),
            notifier: notifier,
            now: now,
            clientFactory: { AgentClient(runner: runner, profile: $0) }
        )
        return (monitor, notifier)
    }

    /// Polls the monitor until `condition` holds, so tests never depend on fixed sleeps.
    private func wait(
        timeout: TimeInterval = 3,
        for condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    // MARK: - Happy path

    func testSuccessfulRefreshPopulatesState() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let (monitor, _) = makeMonitor(runner: runner)

        monitor.refresh()
        try await wait { monitor.connection.isConnected }

        XCTAssertEqual(monitor.snapshot?.jobs.count, 8)
        XCTAssertNotNil(monitor.lastSuccessfulFetch)
        XCTAssertFalse(monitor.isShowingStaleData)
        XCTAssertEqual(monitor.consecutiveFailures, 0)
        XCTAssertTrue(monitor.hasActiveJobs)
    }

    func testGroupedJobsAreDerivedFromTheSnapshot() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let (monitor, _) = makeMonitor(runner: runner)
        monitor.refresh()
        try await wait { monitor.connection.isConnected }

        let groups = monitor.groupedJobs
        XCTAssertEqual(groups.running.count, 3)
        XCTAssertEqual(groups.pending.count, 2)
        XCTAssertFalse(groups.recentlyFinished.isEmpty)
    }

    // MARK: - One refresh at a time

    func testOverlappingRefreshesAreDropped() async throws {
        // A second SSH connection to the same login node for the same data is pure waste, and
        // an impatient user clicking refresh must not multiply Slurm controller load.
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"), delay: 0.4)
        ])
        let (monitor, _) = makeMonitor(runner: runner)

        monitor.refresh()
        monitor.refresh()
        monitor.refresh()
        monitor.refresh()

        try await wait { monitor.connection.isConnected }
        XCTAssertEqual(runner.invocationCount, 1)
    }

    func testARefreshCanRunAgainAfterTheFirstCompletes() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let (monitor, _) = makeMonitor(runner: runner)

        monitor.refresh()
        try await wait { monitor.connection.isConnected }
        monitor.refresh()
        try await wait { runner.invocationCount == 2 }
    }

    // MARK: - Failure handling

    func testFailureKeepsTheLastSnapshotAndMarksItStale() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json")),
            .init(exitCode: 255, stderr: "ssh: connect to host login.example.org port 22: Operation timed out"),
        ])
        let (monitor, _) = makeMonitor(runner: runner)

        monitor.refresh()
        try await wait { monitor.connection.isConnected }
        let jobCount = monitor.snapshot?.jobs.count

        monitor.refresh()
        try await wait { monitor.connection.failure != nil }

        // Losing the VPN must not blank the popover.
        XCTAssertEqual(monitor.snapshot?.jobs.count, jobCount)
        XCTAssertTrue(monitor.isShowingStaleData)
        XCTAssertEqual(monitor.consecutiveFailures, 1)
        guard case .hostUnreachable = try XCTUnwrap(monitor.connection.failure) else {
            return XCTFail("expected hostUnreachable")
        }
    }

    func testFailureWithoutAnyDataReportsHasCachedDataFalse() async throws {
        let runner = StubRemoteRunner(failure: .authenticationFailed(detail: "Permission denied (publickey)."))
        let (monitor, _) = makeMonitor(runner: runner)

        monitor.refresh()
        try await wait { monitor.connection.failure != nil }

        guard case .failed(_, let hasCache) = monitor.connection else { return XCTFail("expected failed") }
        XCTAssertFalse(hasCache)
        XCTAssertEqual(monitor.emptyStateReason?.title, "Authentication failed")
    }

    func testConsecutiveFailuresAccumulateForBackoff() async throws {
        let runner = StubRemoteRunner(failure: .timedOut(seconds: 12))
        let (monitor, _) = makeMonitor(runner: runner)

        monitor.refresh()
        try await wait { monitor.consecutiveFailures == 1 }
        monitor.refresh()
        try await wait { monitor.consecutiveFailures == 2 }
    }

    func testASuccessAfterFailuresResetsTheCounter() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(exitCode: 255, stderr: "ssh: connect to host x port 22: Operation timed out"),
            .init(stdout: try Fixtures.data(named: "snapshot-full.json")),
        ])
        let (monitor, _) = makeMonitor(runner: runner)

        monitor.refresh()
        try await wait { monitor.consecutiveFailures == 1 }
        monitor.refresh()
        try await wait { monitor.connection.isConnected }
        XCTAssertEqual(monitor.consecutiveFailures, 0)
        XCTAssertFalse(monitor.isShowingStaleData)
    }

    func testInvalidProfileNeverAttemptsAConnection() async throws {
        let runner = StubRemoteRunner(responses: [.init()])
        let (monitor, _) = makeMonitor(runner: runner, profile: ClusterProfile(displayName: "Broken", sshAlias: ""))

        monitor.refresh()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runner.invocationCount, 0)
        XCTAssertEqual(monitor.connection, .unconfigured)
    }

    // MARK: - Caching

    func testSnapshotIsCachedAndRestoredOnLaunch() async throws {
        let profile = ClusterProfile(displayName: "Example", sshAlias: "example-cluster")
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let (monitor, _) = makeMonitor(runner: runner, profile: profile)
        monitor.refresh()
        try await wait { monitor.connection.isConnected }

        // A fresh monitor — as after an app restart — shows the cached data immediately.
        let (restored, _) = makeMonitor(runner: StubRemoteRunner(responses: [.init(delay: 5)]), profile: profile)
        XCTAssertEqual(restored.snapshot?.jobs.count, 8)
        XCTAssertTrue(restored.isShowingStaleData, "restored data must be labelled stale")
        XCTAssertNotNil(restored.lastSuccessfulFetch)
    }

    func testRestoredCacheDoesNotReplayNotifications() async throws {
        // The single most important anti-flood rule: restarting the app must not re-announce
        // every job that finished while it was closed.
        let profile = ClusterProfile(displayName: "Example", sshAlias: "example-cluster")
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let (monitor, _) = makeMonitor(runner: runner, profile: profile)
        monitor.refresh()
        try await wait { monitor.connection.isConnected }

        let notifier = RecordingNotifier()
        let (restored, _) = makeMonitor(
            runner: StubRemoteRunner(responses: [
                .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
            ]),
            profile: profile,
            notifier: notifier
        )
        restored.refresh()
        try await wait { restored.connection.isConnected }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(notifier.delivered.isEmpty, "cached jobs must not notify again")
    }

    func testFirstEverRefreshDoesNotNotify() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let (monitor, notifier) = makeMonitor(runner: runner)
        monitor.refresh()
        try await wait { monitor.connection.isConnected }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(notifier.delivered.isEmpty)
    }

    // MARK: - On-demand actions

    func testDoctorRunsOnDemand() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "doctor-ok.json"))
        ])
        let (monitor, _) = makeMonitor(runner: runner)

        let result = await monitor.runDoctor()
        guard case .success(let report) = result else { return XCTFail("expected success") }
        XCTAssertTrue(report.ok)
        XCTAssertEqual(monitor.lastDoctorReport?.checks.count, 10)
    }

    func testDoctorFailureIsCategorized() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(exitCode: 255, stderr: "Host key verification failed.")
        ])
        let (monitor, _) = makeMonitor(runner: runner)

        let result = await monitor.runDoctor()
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        guard case .hostKeyUnknown = failure else { return XCTFail("got \(failure)") }
    }

    func testLogsAreOnlyFetchedWhenAsked() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json")),
            .init(stdout: try Fixtures.data(named: "logs-tail.json")),
        ])
        let (monitor, _) = makeMonitor(runner: runner)

        monitor.refresh()
        try await wait { monitor.connection.isConnected }
        XCTAssertEqual(runner.invocationCount, 1, "polling must never read logs")

        let job = try XCTUnwrap(monitor.snapshot?.jobs.first { $0.jobID == "201551" })
        let result = await monitor.loadLogs(job: job, stream: .stdout)
        guard case .success(let tail) = result else { return XCTFail("expected success") }
        XCTAssertEqual(tail.lines.count, 3)
        XCTAssertEqual(runner.invocationCount, 2)
    }

    func testLogRequestPassesTheKnownPathToAvoidAnExtraLookup() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json")),
            .init(stdout: try Fixtures.data(named: "logs-tail.json")),
        ])
        let (monitor, _) = makeMonitor(runner: runner)
        monitor.refresh()
        try await wait { monitor.connection.isConnected }

        let job = try XCTUnwrap(monitor.snapshot?.jobs.first { $0.jobID == "201551" })
        _ = await monitor.loadLogs(job: job, stream: .stdout)

        let argv = runner.invocations[1]
        let pathIndex = try XCTUnwrap(argv.firstIndex(of: "--path"))
        XCTAssertEqual(argv[pathIndex + 1], "/home/exampleuser/slurmbar-demo/logs/slurm-201551.out")
    }

    func testCancelIsNeverInvokedByPollingOrRefresh() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let (monitor, _) = makeMonitor(runner: runner)

        monitor.refresh()
        try await wait { monitor.connection.isConnected }
        monitor.popoverDidOpen()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(
            runner.invocations.contains { $0.contains("cancel") },
            "no automatic code path may ever reach scancel"
        )
    }

    // MARK: - Profile changes

    func testChangingClusterClearsStateAndCancelsInFlightWork() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let (monitor, _) = makeMonitor(runner: runner)
        monitor.refresh()
        try await wait { monitor.connection.isConnected }

        let different = ClusterProfile(displayName: "Other", sshAlias: "other-cluster")
        monitor.apply(profile: different, notificationPreferences: .default)

        XCTAssertEqual(monitor.profile.sshAlias, "other-cluster")
        // Jobs from the previous cluster must not linger under the new cluster's name.
        XCTAssertNil(monitor.snapshot)
    }

    func testChangingOnlyThePollingIntervalKeepsTheSnapshot() async throws {
        var profile = ClusterProfile(displayName: "Example", sshAlias: "example-cluster")
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let (monitor, _) = makeMonitor(runner: runner, profile: profile)
        monitor.refresh()
        try await wait { monitor.connection.isConnected }

        profile.pollIntervalSeconds = 90
        monitor.apply(profile: profile, notificationPreferences: .default)
        XCTAssertNotNil(monitor.snapshot)
    }

    func testStopHaltsScheduling() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let (monitor, _) = makeMonitor(runner: runner)
        monitor.refresh()
        try await wait { monitor.connection.isConnected }

        monitor.stop()
        let countAfterStop = runner.invocationCount
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(runner.invocationCount, countAfterStop)
    }

    func testAcknowledgingFailuresClearsTheMenuBarIndicator() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let (monitor, _) = makeMonitor(runner: runner)
        monitor.refresh()
        try await wait { monitor.connection.isConnected }

        monitor.acknowledgeFailures()
        XCTAssertFalse(monitor.hasUnacknowledgedFailure)
    }
}

final class SnapshotCacheTests: XCTestCase {
    func testStoreAndLoadRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slurmbar-cache-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = SnapshotCache(directory: directory)
        let snapshot = try ProtocolDecoder().decodeSnapshot(from: try Fixtures.data(named: "snapshot-full.json"))
        let clusterID = UUID()
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

        cache.store(snapshot, clusterID: clusterID, fetchedAt: fetchedAt)
        let loaded = try XCTUnwrap(cache.load(clusterID: clusterID))

        XCTAssertEqual(loaded.snapshot, snapshot)
        XCTAssertEqual(loaded.fetchedAt.timeIntervalSince1970, fetchedAt.timeIntervalSince1970, accuracy: 1)
    }

    func testMissingCacheReturnsNil() {
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("slurmbar-cache-missing-\(UUID().uuidString)"))
        XCTAssertNil(cache.load(clusterID: UUID()))
    }

    func testCachesAreIsolatedPerCluster() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slurmbar-cache-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = SnapshotCache(directory: directory)
        let snapshot = try ProtocolDecoder().decodeSnapshot(from: try Fixtures.data(named: "snapshot-full.json"))
        let clusterA = UUID()
        cache.store(snapshot, clusterID: clusterA)
        XCTAssertNotNil(cache.load(clusterID: clusterA))
        XCTAssertNil(cache.load(clusterID: UUID()))
    }

    func testRemove() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slurmbar-cache-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = SnapshotCache(directory: directory)
        let snapshot = try ProtocolDecoder().decodeSnapshot(from: try Fixtures.data(named: "snapshot-empty.json"))
        let clusterID = UUID()
        cache.store(snapshot, clusterID: clusterID)
        cache.remove(clusterID: clusterID)
        XCTAssertNil(cache.load(clusterID: clusterID))
    }
}
