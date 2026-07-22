import XCTest
@testable import SlurmBarKit

final class JobEventDetectorTests: XCTestCase {
    private func snapshot(_ jobs: [Job]) -> Snapshot {
        Snapshot(
            schemaVersion: 1,
            generatedAt: Date(),
            cluster: ClusterInfo(name: "c", hostname: "h", slurmVersion: nil),
            summary: .empty,
            jobs: jobs
        )
    }

    private func job(
        _ id: String,
        state: JobState,
        progress: JobProgress? = nil,
        elapsed: Int? = 100,
        exitCode: Int? = nil
    ) -> Job {
        Job(
            jobID: id,
            name: "job-\(id)",
            state: state,
            elapsedSeconds: elapsed,
            exitCode: exitCode,
            progress: progress
        )
    }

    // MARK: - Baseline behaviour

    func testFirstSnapshotEstablishesBaselineSilently() {
        // Otherwise every launch replays the last day of accounting history as notifications.
        let detector = JobEventDetector(clusterName: "Test")
        XCTAssertTrue(detector.needsBaseline)

        let events = detector.process(snapshot: snapshot([
            job("1", state: .completed),
            job("2", state: .failed),
            job("3", state: .outOfMemory),
            job("4", state: .running),
        ]))

        XCTAssertTrue(events.isEmpty, "the first snapshot must not notify")
        XCTAssertFalse(detector.needsBaseline)
    }

    func testTransitionAfterBaselineNotifies() {
        let detector = JobEventDetector(clusterName: "Test")
        _ = detector.process(snapshot: snapshot([job("1", state: .running)]))

        let events = detector.process(snapshot: snapshot([job("1", state: .completed)]))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .completed)
        XCTAssertEqual(events[0].jobID, "1")
        XCTAssertEqual(events[0].clusterName, "Test")
    }

    // MARK: - Edge triggering

    func testARepeatedlyPolledFinishedJobNotifiesExactlyOnce() {
        let detector = JobEventDetector(clusterName: "Test")
        _ = detector.process(snapshot: snapshot([job("1", state: .running)]))

        var total = 0
        for _ in 0..<10 {
            total += detector.process(snapshot: snapshot([job("1", state: .failed)])).count
        }
        XCTAssertEqual(total, 1, "a FAILED job stays FAILED for hours of polling")
    }

    func testEachFailureModeMapsToItsOwnEvent() {
        func kind(for state: JobState) -> JobEvent.Kind? {
            let detector = JobEventDetector(clusterName: "Test")
            _ = detector.process(snapshot: snapshot([job("1", state: .running)]))
            return detector.process(snapshot: snapshot([job("1", state: state)])).first?.kind
        }
        XCTAssertEqual(kind(for: .completed), .completed)
        XCTAssertEqual(kind(for: .failed), .failed)
        XCTAssertEqual(kind(for: .timeout), .timedOut)
        XCTAssertEqual(kind(for: .deadline), .timedOut)
        XCTAssertEqual(kind(for: .outOfMemory), .outOfMemory)
        XCTAssertEqual(kind(for: .nodeFail), .failed)
    }

    func testCancellationDoesNotNotify() {
        // Almost always the user's own doing; notifying is noise.
        let detector = JobEventDetector(clusterName: "Test")
        _ = detector.process(snapshot: snapshot([job("1", state: .running)]))
        XCTAssertTrue(detector.process(snapshot: snapshot([job("1", state: .cancelled)])).isEmpty)
    }

    func testStateChangesAmongActiveStatesDoNotNotify() {
        let detector = JobEventDetector(clusterName: "Test")
        _ = detector.process(snapshot: snapshot([job("1", state: .pending)]))
        XCTAssertTrue(detector.process(snapshot: snapshot([job("1", state: .running)])).isEmpty)
        XCTAssertTrue(detector.process(snapshot: snapshot([job("1", state: .completing)])).isEmpty)
    }

    func testANewlySubmittedRunningJobDoesNotNotify() {
        let detector = JobEventDetector(clusterName: "Test")
        _ = detector.process(snapshot: snapshot([job("1", state: .running)]))
        let events = detector.process(snapshot: snapshot([
            job("1", state: .running),
            job("2", state: .running),
        ]))
        XCTAssertTrue(events.isEmpty)
    }

    func testAJobFirstSeenAlreadyFinishedNotifiesOnce() {
        // A short job that started and finished between two polls still deserves one event.
        let detector = JobEventDetector(clusterName: "Test")
        _ = detector.process(snapshot: snapshot([job("1", state: .running)]))
        let events = detector.process(snapshot: snapshot([
            job("1", state: .running),
            job("2", state: .completed),
        ]))
        XCTAssertEqual(events.map(\.jobID), ["2"])
    }

    func testAccountingRecordAppearingAfterTheQueueRecordDoesNotDoubleNotify() {
        let detector = JobEventDetector(clusterName: "Test")
        _ = detector.process(snapshot: snapshot([job("1", state: .running)]))
        XCTAssertEqual(detector.process(snapshot: snapshot([job("1", state: .completing)])).count, 0)
        XCTAssertEqual(detector.process(snapshot: snapshot([job("1", state: .completed)])).count, 1)
        XCTAssertEqual(detector.process(snapshot: snapshot([job("1", state: .completed)])).count, 0)
    }

    // MARK: - Progress-derived events

    func testProgressBecomingStaleNotifiesOnce() {
        let detector = JobEventDetector(clusterName: "Test")
        let fresh = JobProgress(source: .structuredFile, current: 5, total: 10, stale: false)
        let stale = JobProgress(source: .structuredFile, current: 5, total: 10, stale: true)

        _ = detector.process(snapshot: snapshot([job("1", state: .running, progress: fresh)]))
        let first = detector.process(snapshot: snapshot([job("1", state: .running, progress: stale)]))
        XCTAssertEqual(first.map(\.kind), [.progressStale])

        let second = detector.process(snapshot: snapshot([job("1", state: .running, progress: stale)]))
        XCTAssertTrue(second.isEmpty)
    }

    func testNaNLossNotifiesOnceAndIsLatched() {
        let detector = JobEventDetector(clusterName: "Test")
        let ok = JobProgress(source: .structuredFile, current: 1, total: 10, metrics: ["loss": .number(0.5)])
        let nan = JobProgress(source: .structuredFile, current: 2, total: 10, metrics: ["loss": .string("nan")])

        _ = detector.process(snapshot: snapshot([job("1", state: .running, progress: ok)]))

        let first = detector.process(snapshot: snapshot([job("1", state: .running, progress: nan)]))
        XCTAssertEqual(first.map(\.kind), [.lossBecameNaN])
        XCTAssertEqual(first.first?.detail, "loss")

        // A metric that flickers back and forth must not notify repeatedly.
        _ = detector.process(snapshot: snapshot([job("1", state: .running, progress: ok)]))
        let again = detector.process(snapshot: snapshot([job("1", state: .running, progress: nan)]))
        XCTAssertTrue(again.isEmpty)
    }

    func testEventBodyIncludesUsefulDetail() {
        let detector = JobEventDetector(clusterName: "Example Cluster")
        _ = detector.process(snapshot: snapshot([job("201542", state: .running)]))
        let events = detector.process(snapshot: snapshot([
            job("201542", state: .failed, elapsed: 2520, exitCode: 1)
        ]))
        let body = try? XCTUnwrap(events.first?.body)
        XCTAssertTrue(body?.contains("201542") ?? false)
        XCTAssertTrue(body?.contains("Example Cluster") ?? false)
        XCTAssertTrue(body?.contains("exit 1") ?? false)
    }

    func testFailedJobBodyMentionsWhereProgressStopped() {
        let detector = JobEventDetector(clusterName: "Test")
        let progress = JobProgress(source: .structuredFile, current: 812, total: 1000, unit: "epoch")
        _ = detector.process(snapshot: snapshot([job("1", state: .running, progress: progress)]))
        let events = detector.process(snapshot: snapshot([
            job("1", state: .failed, progress: progress, elapsed: 2520)
        ]))
        XCTAssertTrue(events.first?.body.contains("812 / 1,000 epochs") ?? false)
    }

    func testResetClearsMemoryAndRequiresANewBaseline() {
        let detector = JobEventDetector(clusterName: "Test")
        _ = detector.process(snapshot: snapshot([job("1", state: .running)]))
        detector.reset()
        XCTAssertTrue(detector.needsBaseline)
        XCTAssertTrue(detector.process(snapshot: snapshot([job("1", state: .failed)])).isEmpty)
    }

    func testEventsHaveStableUniqueIdentifiers() {
        let a = JobEvent(kind: .completed, jobID: "1", jobName: "x", clusterName: "c")
        let b = JobEvent(kind: .completed, jobID: "1", jobName: "x", clusterName: "c")
        let c = JobEvent(kind: .failed, jobID: "1", jobName: "x", clusterName: "c")
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a.id, c.id)
    }
}

final class NotificationPreferenceTests: XCTestCase {
    func testEachEventKindIsIndividuallyControllable() {
        var preferences = NotificationPreferences.default
        XCTAssertTrue(preferences.isEnabled(for: .completed))
        preferences.jobCompleted = false
        XCTAssertFalse(preferences.isEnabled(for: .completed))
        XCTAssertTrue(preferences.isEnabled(for: .failed))
    }

    func testNoisyEventsAreOffByDefault() {
        let preferences = NotificationPreferences.default
        XCTAssertFalse(preferences.progressStale)
        XCTAssertFalse(preferences.connectionLost)
        XCTAssertTrue(preferences.jobFailed)
    }
}
