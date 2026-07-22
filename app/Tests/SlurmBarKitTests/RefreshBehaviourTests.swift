import XCTest
@testable import SlurmBarKit

/// Covers the settings that live in `AppSettings` rather than in the cluster profile, and that
/// therefore have to be threaded all the way from Settings into the monitor.
@MainActor
final class RefreshBehaviourTests: XCTestCase {
    private var cacheDirectory: URL!
    private static let fixtureNow = isoDate("2026-07-22T02:30:30Z")

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slurmbar-behaviour-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    private func makeMonitor(
        runner: StubRemoteRunner,
        behaviour: ClusterMonitor.RefreshBehaviour,
        notifier: RecordingNotifier = RecordingNotifier(),
        profile: ClusterProfile = ClusterProfile(displayName: "Example", sshAlias: "example-cluster")
    ) -> (ClusterMonitor, RecordingNotifier) {
        let monitor = ClusterMonitor(
            profile: profile,
            cache: SnapshotCache(directory: cacheDirectory),
            notifier: notifier,
            behaviour: behaviour,
            now: { RefreshBehaviourTests.fixtureNow },
            clientFactory: { AgentClient(runner: runner, profile: $0) }
        )
        return (monitor, notifier)
    }

    private func wait(timeout: TimeInterval = 3, for condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }

    // MARK: - Settings mapping

    func testBehaviourIsDerivedFromAppSettings() {
        let settings = AppSettings(
            recentlyFinishedHours: 6,
            refreshWhenPopoverOpen: false,
            pauseWhenNoActiveJobs: true
        )
        let behaviour = ClusterMonitor.RefreshBehaviour(settings: settings)
        XCTAssertEqual(behaviour.recentlyFinishedHours, 6)
        XCTAssertFalse(behaviour.refreshWhenPopoverOpen)
        XCTAssertTrue(behaviour.pauseWhenNoActiveJobs)
    }

    // MARK: - Display window

    func testRecentlyFinishedHoursNarrowsWhatThePopoverShows() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        // The fixture's finished jobs ended on 2026-07-21, 12+ hours before the fixture clock.
        let (wide, _) = makeMonitor(
            runner: runner,
            behaviour: .init(recentlyFinishedHours: 24)
        )
        wide.refresh()
        try await wait { wide.connection.isConnected }
        XCTAssertFalse(wide.groupedJobs.recentlyFinished.isEmpty)

        let (narrow, _) = makeMonitor(
            runner: StubRemoteRunner(responses: [
                .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
            ]),
            behaviour: .init(recentlyFinishedHours: 1)
        )
        narrow.refresh()
        try await wait { narrow.connection.isConnected }
        XCTAssertTrue(
            narrow.groupedJobs.recentlyFinished.isEmpty,
            "a 1-hour display window must hide jobs that finished yesterday"
        )
        // Narrowing the display window must not hide active jobs.
        XCTAssertEqual(narrow.groupedJobs.running.count, 3)
    }

    func testDisplayWindowIsClampedToWhatWasActuallyFetched() async throws {
        var profile = ClusterProfile(displayName: "Example", sshAlias: "example-cluster")
        profile.historyHours = 2
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        // Asking to display 168 h when only 2 h were fetched must not widen anything.
        let (monitor, _) = makeMonitor(
            runner: runner,
            behaviour: .init(recentlyFinishedHours: 168),
            profile: profile
        )
        monitor.refresh()
        try await wait { monitor.connection.isConnected }
        XCTAssertTrue(monitor.groupedJobs.recentlyFinished.isEmpty)
    }

    // MARK: - Connection-lost notification

    func testConnectionLossNotifiesOnceWhenEnabled() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json")),
            .init(exitCode: 255, stderr: "ssh: connect to host x port 22: Operation timed out"),
        ])
        let notifier = RecordingNotifier()
        let (monitor, _) = makeMonitor(runner: runner, behaviour: .default, notifier: notifier)
        monitor.apply(
            profile: monitor.profile,
            notificationPreferences: NotificationPreferences(connectionLost: true)
        )

        monitor.refresh()
        try await wait { monitor.connection.isConnected }

        monitor.refresh()
        try await wait { notifier.delivered.contains { $0.kind == .connectionLost } }

        // Still failing on subsequent polls must not produce a second alert.
        monitor.refresh()
        try await wait { monitor.consecutiveFailures >= 2 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(notifier.delivered.filter { $0.kind == .connectionLost }.count, 1)
    }

    func testConnectionLossIsSilentWhenDisabled() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json")),
            .init(exitCode: 255, stderr: "ssh: connect to host x port 22: Operation timed out"),
        ])
        let notifier = RecordingNotifier()
        // connectionLost defaults to false.
        let (monitor, _) = makeMonitor(runner: runner, behaviour: .default, notifier: notifier)

        monitor.refresh()
        try await wait { monitor.connection.isConnected }
        monitor.refresh()
        try await wait { monitor.connection.failure != nil }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(notifier.delivered.filter { $0.kind == .connectionLost }.isEmpty)
    }

    func testAFailureBeforeAnySuccessDoesNotNotify() async throws {
        // Launching while the VPN is already down is not "the connection was lost".
        let runner = StubRemoteRunner(failure: .timedOut(seconds: 12))
        let notifier = RecordingNotifier()
        let (monitor, _) = makeMonitor(runner: runner, behaviour: .default, notifier: notifier)
        monitor.apply(
            profile: monitor.profile,
            notificationPreferences: NotificationPreferences(connectionLost: true)
        )

        monitor.refresh()
        try await wait { monitor.connection.failure != nil }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(notifier.delivered.isEmpty)
    }

    func testReconnectingArmsTheAlertAgain() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json")),
            .init(exitCode: 255, stderr: "ssh: connect to host x port 22: Operation timed out"),
            .init(stdout: try Fixtures.data(named: "snapshot-full.json")),
            .init(exitCode: 255, stderr: "ssh: connect to host x port 22: Operation timed out"),
        ])
        let notifier = RecordingNotifier()
        let (monitor, _) = makeMonitor(runner: runner, behaviour: .default, notifier: notifier)
        monitor.apply(
            profile: monitor.profile,
            notificationPreferences: NotificationPreferences(connectionLost: true)
        )

        monitor.refresh()
        try await wait { monitor.connection.isConnected }
        monitor.refresh()
        try await wait { notifier.delivered.count == 1 }
        monitor.refresh()
        try await wait { monitor.connection.isConnected }
        monitor.refresh()
        try await wait { notifier.delivered.count == 2 }
    }

    func testConnectionLostEventReadsWell() {
        let event = JobEvent.connectionLost(
            clusterName: "Example Cluster",
            failure: .hostUnreachable(detail: "timed out")
        )
        XCTAssertEqual(event.title, "Cluster unreachable")
        XCTAssertTrue(event.body.contains("Example Cluster"))
        // The job-shaped body format must not leak into a connection event.
        XCTAssertFalse(event.body.contains("(-)"))
    }
}
