import XCTest
@testable import SlurmBarKit

final class PollingPolicyTests: XCTestCase {
    private let policy = PollingPolicy(
        foregroundInterval: 12,
        backgroundInterval: 30,
        idleInterval: 75,
        backoffMultiplier: 2,
        maximumInterval: 600,
        jitterFraction: 0
    )

    func testPopoverOpenUsesTheFastInterval() {
        let context = PollingPolicy.Context(isPopoverOpen: true, hasActiveJobs: true)
        XCTAssertEqual(policy.nextInterval(for: context, randomFraction: 0), 12)
    }

    func testPopoverClosedWithActiveJobs() {
        let context = PollingPolicy.Context(isPopoverOpen: false, hasActiveJobs: true)
        XCTAssertEqual(policy.nextInterval(for: context, randomFraction: 0), 30)
    }

    func testNoActiveJobsPollsSlowly() {
        // Nothing is running, so there is very little to learn — be a good citizen.
        let context = PollingPolicy.Context(isPopoverOpen: false, hasActiveJobs: false)
        XCTAssertEqual(policy.nextInterval(for: context, randomFraction: 0), 75)
    }

    func testOpenPopoverStillPollsWhenIdle() {
        let context = PollingPolicy.Context(isPopoverOpen: true, hasActiveJobs: false)
        XCTAssertEqual(policy.nextInterval(for: context, randomFraction: 0), 12)
    }

    func testBackoffGrowsWithConsecutiveFailures() {
        func interval(failures: Int) -> TimeInterval? {
            policy.nextInterval(
                for: PollingPolicy.Context(hasActiveJobs: true, consecutiveFailures: failures),
                randomFraction: 0
            )
        }
        XCTAssertEqual(interval(failures: 0), 30)
        XCTAssertEqual(interval(failures: 1), 60)
        XCTAssertEqual(interval(failures: 2), 120)
        XCTAssertEqual(interval(failures: 3), 240)
    }

    func testBackoffIsCapped() {
        let context = PollingPolicy.Context(hasActiveJobs: true, consecutiveFailures: 50)
        XCTAssertEqual(policy.nextInterval(for: context, randomFraction: 0), 600)
    }

    func testPauseWhenIdleStopsPollingEntirely() {
        let context = PollingPolicy.Context(isPopoverOpen: false, hasActiveJobs: false, pauseWhenIdle: true)
        XCTAssertNil(policy.nextInterval(for: context, randomFraction: 0))
        XCTAssertFalse(policy.shouldPollAutomatically(for: context))
    }

    func testPauseWhenIdleIsOverriddenByAnOpenPopover() {
        let context = PollingPolicy.Context(isPopoverOpen: true, hasActiveJobs: false, pauseWhenIdle: true)
        XCTAssertEqual(policy.nextInterval(for: context, randomFraction: 0), 12)
    }

    func testRefreshWhilePopoverOpenCanBeDisabled() {
        let context = PollingPolicy.Context(
            isPopoverOpen: true,
            hasActiveJobs: true,
            refreshWhilePopoverOpen: false
        )
        XCTAssertEqual(policy.nextInterval(for: context, randomFraction: 0), 30)
    }

    func testJitterStaysWithinBounds() {
        let jittered = PollingPolicy(
            foregroundInterval: 12, backgroundInterval: 30, idleInterval: 75,
            backoffMultiplier: 2, maximumInterval: 600, jitterFraction: 0.1
        )
        let context = PollingPolicy.Context(hasActiveJobs: true)
        XCTAssertEqual(jittered.nextInterval(for: context, randomFraction: 1) ?? 0, 33, accuracy: 0.001)
        XCTAssertEqual(jittered.nextInterval(for: context, randomFraction: -1) ?? 0, 27, accuracy: 0.001)
    }

    func testJitterNeverProducesAZeroDelay() {
        let aggressive = PollingPolicy(
            foregroundInterval: 1, backgroundInterval: 1, idleInterval: 1,
            backoffMultiplier: 1, maximumInterval: 10, jitterFraction: 5
        )
        let interval = aggressive.nextInterval(
            for: PollingPolicy.Context(hasActiveJobs: true),
            randomFraction: -1
        )
        XCTAssertGreaterThanOrEqual(interval ?? 0, 1)
    }

    func testDerivedPolicyScalesFromTheUsersBaseInterval() {
        let derived = PollingPolicy.fromBaseInterval(60)
        XCTAssertEqual(derived.backgroundInterval, 60)
        XCTAssertEqual(derived.foregroundInterval, 24)
        XCTAssertEqual(derived.idleInterval, 150)
    }

    func testDerivedPolicyEnforcesAFloor() {
        let derived = PollingPolicy.fromBaseInterval(1)
        XCTAssertGreaterThanOrEqual(derived.backgroundInterval, 5)
        XCTAssertGreaterThanOrEqual(derived.foregroundInterval, 8)
    }
}

final class StalenessPolicyTests: XCTestCase {
    private let policy = StalenessPolicy(freshLimit: 90, staleLimit: 300)
    private let now = isoDate("2026-07-22T02:30:00Z")

    func testFresh() {
        XCTAssertEqual(policy.freshness(of: now.addingTimeInterval(-30), now: now), .fresh)
    }

    func testAging() {
        XCTAssertEqual(policy.freshness(of: now.addingTimeInterval(-120), now: now), .aging)
    }

    func testStale() {
        XCTAssertEqual(policy.freshness(of: now.addingTimeInterval(-600), now: now), .stale)
    }

    func testBoundariesAreInclusive() {
        XCTAssertEqual(policy.freshness(of: now.addingTimeInterval(-90), now: now), .fresh)
        XCTAssertEqual(policy.freshness(of: now.addingTimeInterval(-300), now: now), .aging)
    }
}

final class JobGroupingTests: XCTestCase {
    private let now = isoDate("2026-07-22T02:30:00Z")

    private func job(
        _ id: String,
        state: JobState,
        elapsed: Int? = nil,
        submit: String? = nil,
        end: String? = nil
    ) -> Job {
        Job(
            jobID: id,
            name: "job-\(id)",
            state: state,
            submitTime: submit.map(isoDate),
            endTime: end.map(isoDate),
            elapsedSeconds: elapsed
        )
    }

    func testSplitsIntoThreeGroups() {
        let groups = JobGrouper.group(
            jobs: [
                job("1", state: .running),
                job("2", state: .pending),
                job("3", state: .completed, end: "2026-07-22T02:00:00Z"),
            ],
            now: now
        )
        XCTAssertEqual(groups.running.map(\.jobID), ["1"])
        XCTAssertEqual(groups.pending.map(\.jobID), ["2"])
        XCTAssertEqual(groups.recentlyFinished.map(\.jobID), ["3"])
        XCTAssertEqual(groups.totalCount, 3)
    }

    func testCompletingAndSuspendedCountAsRunning() {
        let groups = JobGrouper.group(
            jobs: [job("1", state: .completing), job("2", state: .suspended)],
            now: now
        )
        XCTAssertEqual(groups.running.count, 2)
    }

    func testRequeuedCountsAsPending() {
        let groups = JobGrouper.group(jobs: [job("1", state: .requeued)], now: now)
        XCTAssertEqual(groups.pending.map(\.jobID), ["1"])
    }

    func testRunningSortsLongestFirst() {
        let groups = JobGrouper.group(
            jobs: [
                job("a", state: .running, elapsed: 100),
                job("b", state: .running, elapsed: 9000),
                job("c", state: .running, elapsed: 3000),
            ],
            now: now
        )
        XCTAssertEqual(groups.running.map(\.jobID), ["b", "c", "a"])
    }

    func testPendingSortsLongestWaitingFirst() {
        let groups = JobGrouper.group(
            jobs: [
                job("a", state: .pending, submit: "2026-07-22T02:00:00Z"),
                job("b", state: .pending, submit: "2026-07-22T00:00:00Z"),
            ],
            now: now
        )
        XCTAssertEqual(groups.pending.map(\.jobID), ["b", "a"])
    }

    func testFinishedSortsMostRecentFirst() {
        let groups = JobGrouper.group(
            jobs: [
                job("a", state: .completed, end: "2026-07-22T00:00:00Z"),
                job("b", state: .completed, end: "2026-07-22T02:00:00Z"),
            ],
            now: now
        )
        XCTAssertEqual(groups.recentlyFinished.map(\.jobID), ["b", "a"])
    }

    func testFailuresGetTheirOwnSectionSoTheyAreNeverBuried() {
        // Previously failures merely sorted above successes in one combined list, which still
        // let a batch of clean completions push them down. They now have a section of their own.
        let groups = JobGrouper.group(
            jobs: [
                job("ok", state: .completed, end: "2026-07-22T02:00:00Z"),
                job("bad", state: .failed, end: "2026-07-22T02:00:00Z"),
                job("cancelled", state: .cancelled, end: "2026-07-22T02:00:00Z"),
            ],
            now: now
        )
        XCTAssertEqual(groups.completed.map(\.jobID), ["ok"])
        XCTAssertEqual(groups.unsuccessful.map(\.jobID), ["bad", "cancelled"])
    }

    func testCancellationsShareTheUnsuccessfulSectionButRankBelowRealFailures() {
        let groups = JobGrouper.group(
            jobs: [
                job("cancelled", state: .cancelled, end: "2026-07-22T02:00:00Z"),
                job("oom", state: .outOfMemory, end: "2026-07-22T02:00:00Z"),
            ],
            now: now
        )
        XCTAssertEqual(groups.unsuccessful.map(\.jobID), ["oom", "cancelled"])
    }

    func testEachFinishedSectionIsNewestFirst() {
        let groups = JobGrouper.group(
            jobs: [
                job("old", state: .completed, end: "2026-07-22T00:00:00Z"),
                job("new", state: .completed, end: "2026-07-22T02:00:00Z"),
            ],
            now: now
        )
        XCTAssertEqual(groups.completed.map(\.jobID), ["new", "old"])
    }

    func testDropsFinishedJobsOlderThanTheWindow() {
        let groups = JobGrouper.group(
            jobs: [
                job("old", state: .completed, end: "2026-07-19T02:00:00Z"),
                job("new", state: .completed, end: "2026-07-22T01:00:00Z"),
            ],
            recentHours: 24,
            now: now
        )
        XCTAssertEqual(groups.recentlyFinished.map(\.jobID), ["new"])
    }

    func testKeepsFinishedJobsWithNoEndTime() {
        // Better to show a job with an unknown end time than to silently drop it.
        let groups = JobGrouper.group(jobs: [job("x", state: .cancelled)], recentHours: 1, now: now)
        XCTAssertEqual(groups.recentlyFinished.map(\.jobID), ["x"])
    }

    func testEmptyInput() {
        XCTAssertTrue(JobGrouper.group(jobs: [], now: now).isEmpty)
    }

    func testSortIsStableForEqualKeys() {
        let groups = JobGrouper.group(
            jobs: [
                job("20", state: .running, elapsed: 100),
                job("3", state: .running, elapsed: 100),
            ],
            now: now
        )
        XCTAssertEqual(groups.running.map(\.jobID), ["3", "20"])
    }
}

final class MenuBarLabelTests: XCTestCase {
    private func snapshot(running: Int, pending: Int, failed: Int = 0, jobs: [Job] = []) -> Snapshot {
        Snapshot(
            schemaVersion: 1,
            generatedAt: isoDate("2026-07-22T02:30:00Z"),
            cluster: ClusterInfo(name: "c", hostname: "h", slurmVersion: nil),
            summary: JobSummary(
                running: running, pending: pending, completing: 0,
                failedRecently: failed, completedRecently: 0
            ),
            jobs: jobs
        )
    }

    func testIconOnlyHasNoText() {
        let label = MenuBarLabelBuilder.make(
            mode: .iconOnly, snapshot: snapshot(running: 3, pending: 2),
            connection: .connected(at: Date()), pinnedJobID: nil,
            hasUnacknowledgedFailure: false, showFailureIndicator: true
        )
        XCTAssertNil(label.text)
        XCTAssertFalse(label.symbolName.isEmpty)
    }

    func testCountsFormat() {
        let label = MenuBarLabelBuilder.make(
            mode: .counts, snapshot: snapshot(running: 3, pending: 2),
            connection: .connected(at: Date()), pinnedJobID: nil,
            hasUnacknowledgedFailure: false, showFailureIndicator: true
        )
        XCTAssertEqual(label.text, "3R 2P")
    }

    func testCountsOmitZeroes() {
        XCTAssertEqual(MenuBarLabelBuilder.countsText(summary: snapshot(running: 3, pending: 0).summary), "3R")
        XCTAssertEqual(MenuBarLabelBuilder.countsText(summary: snapshot(running: 0, pending: 2).summary), "2P")
        XCTAssertNil(MenuBarLabelBuilder.countsText(summary: snapshot(running: 0, pending: 0).summary))
    }

    func testPinnedJobPercent() {
        let job = Job(
            jobID: "201551", name: "train", state: .running, elapsedSeconds: 100,
            progress: JobProgress(source: .structuredFile, current: 375, total: 1000, percent: 37.5)
        )
        let label = MenuBarLabelBuilder.make(
            mode: .pinnedJobPercent, snapshot: snapshot(running: 1, pending: 0, jobs: [job]),
            connection: .connected(at: Date()), pinnedJobID: "201551",
            hasUnacknowledgedFailure: false, showFailureIndicator: true
        )
        XCTAssertEqual(label.text, "38%")
    }

    func testPinnedModeFollowsTheLongestRunningJobWhenNothingIsPinned() {
        let short = Job(
            jobID: "1", name: "a", state: .running, elapsedSeconds: 10,
            progress: JobProgress(source: .structuredFile, current: 1, total: 10, percent: 10)
        )
        let long = Job(
            jobID: "2", name: "b", state: .running, elapsedSeconds: 9000,
            progress: JobProgress(source: .structuredFile, current: 9, total: 10, percent: 90)
        )
        let text = MenuBarLabelBuilder.pinnedPercentText(
            snapshot: snapshot(running: 2, pending: 0, jobs: [short, long]),
            pinnedJobID: nil
        )
        XCTAssertEqual(text, "90%")
    }

    func testPinnedModeFallsBackToCountsWithoutProgress() {
        let job = Job(jobID: "201551", name: "train", state: .running)
        let label = MenuBarLabelBuilder.make(
            mode: .pinnedJobPercent, snapshot: snapshot(running: 1, pending: 1, jobs: [job]),
            connection: .connected(at: Date()), pinnedJobID: "201551",
            hasUnacknowledgedFailure: false, showFailureIndicator: true
        )
        XCTAssertEqual(label.text, "1R 1P")
    }

    func testFailureIndicatorRespectsTheSetting() {
        func label(showIndicator: Bool) -> MenuBarLabel {
            MenuBarLabelBuilder.make(
                mode: .counts, snapshot: snapshot(running: 1, pending: 0, failed: 1),
                connection: .connected(at: Date()), pinnedJobID: nil,
                hasUnacknowledgedFailure: true, showFailureIndicator: showIndicator
            )
        }
        XCTAssertTrue(label(showIndicator: true).showsFailureIndicator)
        XCTAssertFalse(label(showIndicator: false).showsFailureIndicator)
    }

    func testNoSnapshotStillProducesAUsableLabel() {
        let label = MenuBarLabelBuilder.make(
            mode: .counts, snapshot: nil, connection: .unconfigured,
            pinnedJobID: nil, hasUnacknowledgedFailure: false, showFailureIndicator: true
        )
        XCTAssertNil(label.text)
        XCTAssertTrue(label.accessibilityLabel.contains("no cluster configured"))
    }

    func testAccessibilityLabelDescribesTheState() {
        let label = MenuBarLabelBuilder.make(
            mode: .counts, snapshot: snapshot(running: 3, pending: 2, failed: 1),
            connection: .connected(at: Date()), pinnedJobID: nil,
            hasUnacknowledgedFailure: true, showFailureIndicator: true
        )
        XCTAssertTrue(label.accessibilityLabel.contains("3 running"))
        XCTAssertTrue(label.accessibilityLabel.contains("2 pending"))
        XCTAssertTrue(label.accessibilityLabel.contains("1 recently failed"))
    }
}

final class EmptyStateResolverTests: XCTestCase {
    private func snapshot(jobs: [Job] = [], warnings: [AgentWarning] = []) -> Snapshot {
        Snapshot(
            schemaVersion: 1,
            generatedAt: Date(),
            cluster: ClusterInfo(name: nil, hostname: nil, slurmVersion: nil),
            summary: .empty,
            jobs: jobs,
            warnings: warnings
        )
    }

    func testNoClustersWins() {
        let reason = EmptyStateResolver.resolve(snapshot: snapshot(), connection: .idle, hasClusters: false)
        XCTAssertEqual(reason, .noClusterConfigured)
    }

    func testDisconnectedWithoutCacheShowsTheFailure() {
        let failure = SSHFailure.hostUnreachable(detail: "timed out")
        let reason = EmptyStateResolver.resolve(
            snapshot: nil, connection: .failed(failure, hasCachedData: false), hasClusters: true
        )
        XCTAssertEqual(reason, .disconnected(failure))
    }

    func testDisconnectedWithCacheShowsJobsNotAnEmptyState() {
        let job = Job(jobID: "1", name: "x", state: .running)
        let reason = EmptyStateResolver.resolve(
            snapshot: snapshot(jobs: [job]),
            connection: .failed(.hostUnreachable(detail: ""), hasCachedData: true),
            hasClusters: true
        )
        XCTAssertNil(reason)
    }

    func testSlurmMissingIsDistinctFromNoJobs() {
        let warning = AgentWarning(
            code: "SLURM_MISSING",
            message: "squeue was not found on the login node.",
            severity: .error,
            detail: "Check PATH for non-interactive SSH sessions."
        )
        let reason = EmptyStateResolver.resolve(
            snapshot: snapshot(warnings: [warning]), connection: .connected(at: Date()), hasClusters: true
        )
        XCTAssertEqual(reason, .slurmUnavailable("Check PATH for non-interactive SSH sessions."))
    }

    func testGenuinelyNoJobs() {
        let reason = EmptyStateResolver.resolve(
            snapshot: snapshot(), connection: .connected(at: Date()), hasClusters: true
        )
        XCTAssertEqual(reason, .noJobs)
    }

    func testNothingFetchedYet() {
        let reason = EmptyStateResolver.resolve(snapshot: nil, connection: .idle, hasClusters: true)
        XCTAssertEqual(reason, .neverRefreshed)
    }

    func testConnectingShowsNoEmptyState() {
        let reason = EmptyStateResolver.resolve(snapshot: nil, connection: .connecting, hasClusters: true)
        XCTAssertNil(reason)
    }

    func testEveryReasonHasCopy() {
        let reasons: [EmptyStateReason] = [
            .noClusterConfigured, .neverRefreshed, .noJobs,
            .slurmUnavailable("d"), .agentUnavailable("d"),
            .disconnected(.hostUnreachable(detail: "")),
        ]
        for reason in reasons {
            XCTAssertFalse(reason.title.isEmpty)
            XCTAssertFalse(reason.message.isEmpty)
            XCTAssertFalse(reason.symbolName.isEmpty)
        }
    }
}
