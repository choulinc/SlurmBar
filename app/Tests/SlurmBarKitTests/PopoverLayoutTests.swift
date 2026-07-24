import XCTest
@testable import SlurmBarKit

final class PopoverLayoutTests: XCTestCase {
    private let screen: CGFloat = 900

    private func job(_ id: String, state: JobState, end: String? = nil) -> Job {
        Job(jobID: id, name: "job-\(id)", state: state, endTime: end.map(isoDate), elapsedSeconds: 10)
    }

    private func groups(running: Int = 0, pending: Int = 0, finished: Int = 0) -> GroupedJobs {
        GroupedJobs(
            running: (0..<running).map { job("r\($0)", state: .running) },
            pending: (0..<pending).map { job("p\($0)", state: .pending) },
            recentlyFinished: (0..<finished).map { job("f\($0)", state: .completed) }
        )
    }

    func testHeightGrowsWithJobCount() {
        let small = PopoverLayout.scrollHeight(groups: groups(running: 1), screenHeight: screen)
        let medium = PopoverLayout.scrollHeight(groups: groups(running: 3), screenHeight: screen)
        let large = PopoverLayout.scrollHeight(groups: groups(running: 5), screenHeight: screen)
        XCTAssertLessThan(small, medium)
        XCTAssertLessThan(medium, large)
    }

    func testNeverExceedsTheScreenFraction() {
        let huge = PopoverLayout.scrollHeight(groups: groups(running: 500), screenHeight: screen)
        let budget = screen * PopoverLayout.metrics.maximumScreenFraction
        XCTAssertLessThanOrEqual(huge + PopoverLayout.metrics.chrome, budget + 0.5)
    }

    func testTheCapIsEightyPercentOfTheScreen() {
        XCTAssertEqual(PopoverLayout.metrics.maximumScreenFraction, 0.80, accuracy: 0.001)
    }

    func testCapScalesWithTheScreen() {
        let onLaptop = PopoverLayout.scrollHeight(groups: groups(running: 500), screenHeight: 800)
        let onDesktop = PopoverLayout.scrollHeight(groups: groups(running: 500), screenHeight: 1600)
        XCTAssertLessThan(onLaptop, onDesktop, "a bigger display should allow a taller popover")
    }

    func testNeverShorterThanTheMinimum() {
        let empty = PopoverLayout.scrollHeight(
            groups: .empty, showsSummary: false, screenHeight: screen
        )
        XCTAssertGreaterThanOrEqual(empty, PopoverLayout.metrics.minimum)
    }

    func testTinyScreenStillProducesAUsableHeight() {
        // A cap below the minimum must not produce a zero or negative frame.
        let cramped = PopoverLayout.scrollHeight(groups: groups(running: 4), screenHeight: 200)
        XCTAssertGreaterThanOrEqual(cramped, PopoverLayout.metrics.minimum)
    }

    func testRunningRowsAreTallerThanPendingRows() {
        // Running rows carry a progress bar and two metadata lines.
        let running = PopoverLayout.scrollHeight(groups: groups(running: 4), screenHeight: screen)
        let pending = PopoverLayout.scrollHeight(groups: groups(pending: 4), screenHeight: screen)
        XCTAssertGreaterThan(running, pending)
    }

    func testBannerAndWarningsAddHeight() {
        let plain = PopoverLayout.scrollHeight(groups: groups(running: 2), screenHeight: screen)
        let withBanner = PopoverLayout.scrollHeight(
            groups: groups(running: 2), showsStaleBanner: true, screenHeight: screen
        )
        let withWarnings = PopoverLayout.scrollHeight(
            groups: groups(running: 2), warningCount: 3, screenHeight: screen
        )
        XCTAssertGreaterThan(withBanner, plain)
        XCTAssertGreaterThan(withWarnings, plain)
    }

    func testEmptyStateUsesItsOwnHeight() {
        let empty = PopoverLayout.scrollHeight(
            groups: .empty, showsSummary: false, showsEmptyState: true, screenHeight: screen
        )
        XCTAssertGreaterThanOrEqual(empty, PopoverLayout.metrics.emptyState)
    }

    func testAbsurdFractionIsClamped() {
        XCTAssertEqual(PopoverLayout.clampedFraction(5), 0.95)
        XCTAssertEqual(PopoverLayout.clampedFraction(0), 0.2)
        XCTAssertEqual(PopoverLayout.clampedFraction(0.6), 0.6)
    }
}

final class JobDisplayFilterTests: XCTestCase {
    private let now = isoDate("2026-07-22T12:00:00Z")

    private func job(_ id: String, state: JobState, endedHoursAgo: Double? = 1) -> Job {
        Job(
            jobID: id,
            name: "job-\(id)",
            state: state,
            endTime: endedHoursAgo.map { now.addingTimeInterval(-$0 * 3600) },
            elapsedSeconds: 60
        )
    }

    private var mixed: [Job] {
        [
            job("run", state: .running, endedHoursAgo: nil),
            job("pend", state: .pending, endedHoursAgo: nil),
            job("done", state: .completed),
            job("fail", state: .failed),
            job("oom", state: .outOfMemory),
            job("cancel", state: .cancelled),
        ]
    }

    func testNothingHiddenByDefault() {
        let groups = JobGrouper.group(jobs: mixed, filter: .default, now: now)
        XCTAssertEqual(groups.recentlyFinished.count, 4)
    }

    func testHideFailedRemovesEveryFailureKind() {
        let groups = JobGrouper.group(
            jobs: mixed, filter: JobDisplayFilter(hideFailed: true), now: now
        )
        let ids = groups.recentlyFinished.map(\.jobID)
        XCTAssertFalse(ids.contains("fail"))
        XCTAssertFalse(ids.contains("oom"), "OUT_OF_MEMORY is a failure too")
        XCTAssertTrue(ids.contains("done"))
        XCTAssertTrue(ids.contains("cancel"))
    }

    func testHideCancelledIsSeparateFromHideFailed() {
        let groups = JobGrouper.group(
            jobs: mixed, filter: JobDisplayFilter(hideCancelled: true), now: now
        )
        let ids = groups.recentlyFinished.map(\.jobID)
        XCTAssertFalse(ids.contains("cancel"))
        XCTAssertTrue(ids.contains("fail"))
    }

    func testActiveJobsAreNeverHidden() {
        let groups = JobGrouper.group(
            jobs: mixed,
            filter: JobDisplayFilter(hideFailed: true, hideCancelled: true, recentHours: 0),
            now: now
        )
        XCTAssertEqual(groups.running.count, 1)
        XCTAssertEqual(groups.pending.count, 1)
    }

    func testAgeWindowDropsOldFinishedJobs() {
        let jobs = [job("recent", state: .completed, endedHoursAgo: 1),
                    job("old", state: .completed, endedHoursAgo: 50)]
        let groups = JobGrouper.group(jobs: jobs, filter: JobDisplayFilter(recentHours: 24), now: now)
        XCTAssertEqual(groups.recentlyFinished.map(\.jobID), ["recent"])
    }
}

final class DerivedSummaryTests: XCTestCase {
    private let now = isoDate("2026-07-22T12:00:00Z")

    private func job(_ id: String, state: JobState, endedHoursAgo: Double? = 1) -> Job {
        Job(
            jobID: id,
            name: id,
            state: state,
            endTime: endedHoursAgo.map { now.addingTimeInterval(-$0 * 3600) },
            elapsedSeconds: 60
        )
    }

    func testSummaryCountsOnlyWhatIsDisplayed() {
        let jobs = [
            job("r1", state: .running, endedHoursAgo: nil),
            job("r2", state: .running, endedHoursAgo: nil),
            job("p1", state: .pending, endedHoursAgo: nil),
            job("d1", state: .completed),
            job("f1", state: .failed),
            job("f2", state: .timeout),
        ]
        let all = JobGrouper.group(jobs: jobs, filter: .default, now: now).summary
        XCTAssertEqual(all.running, 2)
        XCTAssertEqual(all.pending, 1)
        XCTAssertEqual(all.completedRecently, 1)
        XCTAssertEqual(all.failedRecently, 2)

        // Hiding failures must remove them from the count as well as the list; a summary
        // reading "2 failed" above an empty section would be worse than no number at all.
        let hidden = JobGrouper.group(
            jobs: jobs, filter: JobDisplayFilter(hideFailed: true), now: now
        ).summary
        XCTAssertEqual(hidden.failedRecently, 0)
        XCTAssertEqual(hidden.running, 2, "hiding failures must not disturb active counts")
    }

    func testAgeWindowAlsoShrinksTheCounts() {
        let jobs = [job("d1", state: .completed, endedHoursAgo: 1),
                    job("d2", state: .completed, endedHoursAgo: 100)]
        let summary = JobGrouper.group(jobs: jobs, filter: JobDisplayFilter(recentHours: 24), now: now).summary
        XCTAssertEqual(summary.completedRecently, 1)
    }

    func testCompletingIsCountedSeparatelyFromRunning() {
        let jobs = [job("r", state: .running, endedHoursAgo: nil),
                    job("c", state: .completing, endedHoursAgo: nil)]
        let summary = JobGrouper.group(jobs: jobs, filter: .default, now: now).summary
        XCTAssertEqual(summary.running, 1)
        XCTAssertEqual(summary.completing, 1)
    }

    func testCancelledIsNeitherFailedNorCompleted() {
        let summary = JobGrouper.group(jobs: [job("c", state: .cancelled)], filter: .default, now: now).summary
        XCTAssertEqual(summary.failedRecently, 0)
        XCTAssertEqual(summary.completedRecently, 0)
    }

    func testMenuBarCountsUseTheFilteredSummary() {
        let jobs = [job("r", state: .running, endedHoursAgo: nil), job("f", state: .failed)]
        let groups = JobGrouper.group(jobs: jobs, filter: JobDisplayFilter(hideFailed: true), now: now)
        let snapshot = Snapshot(
            schemaVersion: 1,
            generatedAt: now,
            cluster: ClusterInfo(name: "c", hostname: "h", slurmVersion: nil),
            // The agent's own summary still reports the failure it fetched.
            summary: JobSummary(running: 1, pending: 0, completing: 0, failedRecently: 1, completedRecently: 0),
            jobs: jobs
        )
        let label = MenuBarLabelBuilder.make(
            mode: .counts,
            snapshot: snapshot,
            summary: groups.summary,
            connection: .connected(at: now),
            pinnedJobID: nil,
            hasUnacknowledgedFailure: false,
            showFailureIndicator: true
        )
        XCTAssertEqual(label.text, "1R")
        XCTAssertFalse(
            label.accessibilityLabel.contains("recently failed"),
            "a hidden failure must not be announced in the menu bar either"
        )
    }
}

/// Dismissing is a display-only action: it hides a finished job on this Mac and never touches
/// the cluster. A finished job cannot be removed from Slurm's accounting at all.
final class DismissedJobTests: XCTestCase {
    private let now = isoDate("2026-07-22T12:00:00Z")
    private let clusterA = UUID()
    private let clusterB = UUID()

    private func job(_ id: String, state: JobState = .completed) -> Job {
        Job(jobID: id, name: id, state: state,
            endTime: now.addingTimeInterval(-3600), elapsedSeconds: 60)
    }

    func testDismissedJobLeavesBothListAndCounts() {
        let jobs = [job("a"), job("b"), job("c")]
        let filter = JobDisplayFilter(dismissedJobIDs: ["b"])
        let groups = JobGrouper.group(jobs: jobs, filter: filter, now: now)
        XCTAssertEqual(groups.recentlyFinished.map(\.jobID), ["a", "c"])
        XCTAssertEqual(groups.summary.completedRecently, 2)
    }

    func testDismissingDoesNotHideActiveJobs() {
        // Guard against a stale dismissal silencing a job that got requeued and is running.
        let jobs = [Job(jobID: "x", name: "x", state: .running)]
        let groups = JobGrouper.group(
            jobs: jobs, filter: JobDisplayFilter(dismissedJobIDs: ["x"]), now: now
        )
        XCTAssertEqual(groups.running.count, 1, "an active job must never be hidden")
    }

    func testDismissalsAreScopedPerCluster() {
        var settings = AppSettings()
        settings.dismiss(jobID: "1", clusterID: clusterA)
        XCTAssertEqual(settings.dismissed(for: clusterA), ["1"])
        XCTAssertTrue(settings.dismissed(for: clusterB).isEmpty)
    }

    func testDismissIsIdempotent() {
        var settings = AppSettings()
        settings.dismiss(jobID: "1", clusterID: clusterA)
        settings.dismiss(jobID: "1", clusterID: clusterA)
        XCTAssertEqual(settings.dismissedJobIDs[clusterA.uuidString]?.count, 1)
    }

    func testStoredDismissalsAreBounded() {
        var settings = AppSettings()
        for i in 0..<(AppSettings.maxDismissedPerCluster + 250) {
            settings.dismiss(jobID: "job\(i)", clusterID: clusterA)
        }
        XCTAssertEqual(
            settings.dismissedJobIDs[clusterA.uuidString]?.count,
            AppSettings.maxDismissedPerCluster
        )
        // The cap drops the oldest, so recent dismissals survive.
        XCTAssertTrue(settings.dismissed(for: clusterA).contains("job749"))
    }

    func testPruningForgetsJobsTheClusterNoLongerReports() {
        var settings = AppSettings()
        settings.dismiss(jobIDs: ["old", "current"], clusterID: clusterA)
        settings.pruneDismissed(clusterID: clusterA, knownJobIDs: ["current"])
        XCTAssertEqual(settings.dismissed(for: clusterA), ["current"])
    }

    func testPruningEverythingClearsTheEntry() {
        var settings = AppSettings()
        settings.dismiss(jobID: "gone", clusterID: clusterA)
        settings.pruneDismissed(clusterID: clusterA, knownJobIDs: [])
        XCTAssertNil(settings.dismissedJobIDs[clusterA.uuidString])
    }

    func testRestoreBringsEverythingBack() {
        var settings = AppSettings()
        settings.dismiss(jobIDs: ["a", "b"], clusterID: clusterA)
        settings.restoreDismissed(clusterID: clusterA)
        XCTAssertTrue(settings.dismissed(for: clusterA).isEmpty)
    }

    func testDismissalsSurviveASettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.dismiss(jobID: "42", clusterID: clusterA)
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded.dismissed(for: clusterA), ["42"])
    }

    func testOlderSettingsFileWithoutDismissalsStillDecodes() throws {
        let json = #"{"clusters": [], "hideFailedJobs": true}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.hideFailedJobs)
        XCTAssertTrue(settings.dismissedJobIDs.isEmpty)
    }
}

final class DetailLayoutTests: XCTestCase {
    func testDetailHasItsOwnFloor() {
        let height = PopoverLayout.detailScrollHeight(
            hasProgress: false, metricCount: 0, logsExpanded: false, screenHeight: 400
        )
        XCTAssertGreaterThanOrEqual(height, PopoverLayout.metrics.detailMinimum)
    }

    func testExpandingLogsAsksForMoreRoom() {
        let collapsed = PopoverLayout.detailScrollHeight(
            hasProgress: true, metricCount: 4, logsExpanded: false, screenHeight: 1200
        )
        let expanded = PopoverLayout.detailScrollHeight(
            hasProgress: true, metricCount: 4, logsExpanded: true, screenHeight: 1200
        )
        XCTAssertGreaterThan(expanded, collapsed)
    }

    func testDetailObeysTheSameScreenCap() {
        let height = PopoverLayout.detailScrollHeight(
            hasProgress: true, metricCount: 50, logsExpanded: true, screenHeight: 900
        )
        let budget = 900 * PopoverLayout.metrics.maximumScreenFraction
        XCTAssertLessThanOrEqual(height + PopoverLayout.metrics.chrome, budget + 0.5)
    }
}

final class LaunchAtLoginSettingTests: XCTestCase {
    func testTheAskFlagDefaultsToUnasked() {
        XCTAssertFalse(AppSettings().didAskAboutLaunchAtLogin)
        XCTAssertFalse(AppSettings().launchAtLogin)
    }

    func testTheAskFlagSurvivesARoundTrip() throws {
        var settings = AppSettings()
        settings.didAskAboutLaunchAtLogin = true
        let decoded = try JSONDecoder().decode(
            AppSettings.self, from: try JSONEncoder().encode(settings)
        )
        // If this were lost, the prompt would reappear on every launch.
        XCTAssertTrue(decoded.didAskAboutLaunchAtLogin)
    }

    func testASettingsFileFromBeforeThePromptExistedStillDecodes() throws {
        let json = #"{"clusters": [], "launchAtLogin": true}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.launchAtLogin)
        // Not yet asked, so an existing user is offered the choice once.
        XCTAssertFalse(settings.didAskAboutLaunchAtLogin)
    }
}

/// Every surface has to agree about whether a job is finished and how it ended. These pin the
/// reconciliation between Slurm's record and the workload's own report.
final class ProgressBarVisibilityTests: XCTestCase {
    private func job(
        state: JobState,
        current: Double?,
        total: Double?,
        completion: ProgressCompletion? = nil,
        source: ProgressSource = .structuredFile
    ) -> Job {
        Job(
            jobID: "1", name: "j", state: state,
            progress: current == nil ? nil : JobProgress(
                source: source, current: current, total: total,
                percent: (current != nil && total != nil && total! > 0)
                    ? current! / total! * 100 : nil,
                completion: completion
            )
        )
    }

    // MARK: - Outcome, the one classification

    func testOutcomePartitionsEveryStateExactlyOnce() {
        // No state may fall through into "succeeded" by accident, and none may land nowhere.
        for state in JobState.allCases {
            let outcome = Job(jobID: "1", name: "j", state: state).outcome
            if state.isActive {
                XCTAssertEqual(outcome, .active, "\(state)")
            } else {
                XCTAssertNotEqual(outcome, .active, "\(state)")
                XCTAssertNotNil(outcome.finishedGroup, "\(state) must have a section")
            }
        }
    }

    func testUnrecognizedFinishedStateIsNotTreatedAsSuccess() {
        let job = Job(jobID: "1", name: "j", state: .unknown)
        XCTAssertEqual(job.outcome, .indeterminate)
        XCTAssertEqual(job.outcome.finishedGroup, .unsuccessful)
    }

    func testCancellationIsNeitherSuccessNorFailure() {
        for state in [JobState.cancelled, .preempted] {
            XCTAssertEqual(Job(jobID: "1", name: "j", state: state).outcome, .cancelled, "\(state)")
        }
    }

    // MARK: - The bar

    func testCompletedJobThatReachedItsTargetShowsAFullBar() {
        let done = job(state: .completed, current: 1000, total: 1000)
        XCTAssertEqual(done.progressDisposition, .reachedTarget)
        XCTAssertEqual(done.displayedProgressFraction, 1.0)
    }

    func testCompletedJobWhoseCounterFellShortShowsNoBar() {
        // Exited cleanly at epoch 652 of 1000. Filling the bar would claim it reached 1000;
        // leaving it at 65% reads as unfinished. The counter text carries the fact instead.
        let short = job(state: .completed, current: 652, total: 1000)
        XCTAssertEqual(short.progressDisposition, .endedShortOfTarget)
        XCTAssertFalse(short.showsProgressBar)
        XCTAssertNil(short.displayedProgressFraction)
    }

    func testWorkloadDeclaringSuccessFillsTheBarEvenBelowTheTotal() {
        // Early stopping: 284 of 300 epochs *is* a finished run, and only the workload can say
        // so. That declaration outranks the counter.
        let earlyStopped = job(state: .completed, current: 284, total: 300, completion: .completed)
        XCTAssertEqual(earlyStopped.progressDisposition, .reachedTarget)
        XCTAssertEqual(earlyStopped.displayedProgressFraction, 1.0)
    }

    func testRunningJobKeepsItsLiveBar() {
        let running = job(state: .running, current: 652, total: 1000)
        XCTAssertEqual(running.progressDisposition, .live)
        XCTAssertEqual(running.displayedProgressFraction ?? 0, 0.652, accuracy: 1e-9)
    }

    func testFailuresKeepTheirBarAtWhereTheyStopped() {
        // "How far did it get before it died" is exactly the useful question here.
        for state in [JobState.failed, .outOfMemory, .timeout, .nodeFail] {
            let died = job(state: state, current: 41, total: 400)
            XCTAssertEqual(died.progressDisposition, .stoppedAt, "\(state)")
            XCTAssertEqual(died.displayedProgressFraction ?? 0, 0.1025, accuracy: 1e-9, "\(state)")
        }
    }

    func testCancelledKeepsItsBar() {
        XCTAssertEqual(job(state: .cancelled, current: 120, total: 500).progressDisposition, .stoppedAt)
    }

    func testWorkloadReportedFailureOverridesACleanExit() {
        let lying = job(state: .completed, current: 40, total: 100, completion: .failed)
        XCTAssertEqual(lying.progressDisposition, .stoppedAt)
        XCTAssertEqual(lying.completionDisagreement, .reportedFailureButExitedClean)
    }

    func testWorkloadSucceededButSlurmFailedIsSurfaced() {
        let teardown = job(state: .failed, current: 300, total: 300, completion: .completed)
        XCTAssertEqual(teardown.completionDisagreement, .reportedSuccessButJobFailed)
    }

    func testJobKilledMidRunIsSurfaced() {
        let killed = job(state: .cancelled, current: 120, total: 500, completion: .running)
        XCTAssertEqual(killed.completionDisagreement, .endedWhileStillReporting)
    }

    func testLogParsedProgressNeverRaisesADisagreement() {
        // A log parser infers numbers from text; it cannot declare an outcome, so contradicting
        // it would mean contradicting a guess.
        let parsed = job(state: .completed, current: 40, total: 100, completion: nil, source: .logParser)
        XCTAssertNil(parsed.completionDisagreement)
        XCTAssertEqual(parsed.progressDisposition, .endedShortOfTarget)
    }

    func testNoBarWithoutAKnownTotal() {
        XCTAssertFalse(job(state: .running, current: 4820, total: nil).showsProgressBar)
    }

    func testNoBarWithoutProgressAtAll() {
        let bare = job(state: .running, current: nil, total: nil)
        XCTAssertEqual(bare.progressDisposition, .none)
        XCTAssertFalse(bare.showsProgressBar)
    }

    func testTheCounterItselfSurvivesWhenTheBarIsDropped() {
        // Dropping the bar must not drop the factual "652 / 1,000 epochs" text.
        let finished = Job(
            jobID: "1", name: "j", state: .completed,
            progress: JobProgress(source: .structuredFile, current: 652, total: 1000, unit: "epoch")
        )
        XCTAssertFalse(finished.showsProgressBar)
        XCTAssertEqual(finished.progress?.counterDescription, "652 / 1,000 epochs")
    }

    // MARK: - Cross-surface agreement

    func testSummaryAccountsForEveryJobInTheUnsuccessfulSection() {
        // The bug this replaces: the section header counted cancellations, the strip did not,
        // so the same list of jobs was reported as two different numbers.
        let jobs = [
            Job(jobID: "1", name: "a", state: .failed, endTime: Date()),
            Job(jobID: "2", name: "b", state: .cancelled, endTime: Date()),
            Job(jobID: "3", name: "c", state: .preempted, endTime: Date()),
            Job(jobID: "4", name: "d", state: .unknown, endTime: Date()),
            Job(jobID: "5", name: "e", state: .completed, endTime: Date()),
        ]
        let groups = JobGrouper.group(jobs: jobs, recentHours: 24)
        XCTAssertEqual(groups.unsuccessful.count, 4)
        XCTAssertEqual(groups.summary.unsuccessfulRecently, groups.unsuccessful.count)
        XCTAssertEqual(groups.summary.completedRecently, groups.completed.count)
        XCTAssertEqual(groups.summary.cancelledRecently, 2)
        // The unclassifiable one counts as failed, not cancelled: nobody chose to stop it.
        XCTAssertEqual(groups.summary.failedRecently, 2)
    }

    // MARK: - A row's layout and its section are the same decision

    func testEveryJobLandsInTheSectionItsRowIsDrawnFor() {
        // The observed failure: rows drawn as live jobs — blue bar, elapsed-versus-limit, live
        // memory — under a "Completed 115" header. The section came from JobGrouper, the
        // layout came from whatever section value the row had been handed, and the two drifted.
        for state in JobState.allCases {
            let job = Job(jobID: "1", name: "j", state: state, endTime: Date())
            let groups = JobGrouper.group(jobs: [job], recentHours: 24)
            let section = JobGroup.allCases.first { !groups.jobs(in: $0).isEmpty }
            XCTAssertEqual(section, job.displayGroup, "\(state) is filed and drawn differently")
        }
    }

    func testAFinishedJobIsNeverDrawnAsALiveOne() {
        for state in JobState.allCases where !state.isActive {
            let group = Job(jobID: "1", name: "j", state: state).displayGroup
            XCTAssertTrue(group.isFinished, "\(state) would render with the live layout")
        }
    }

    // MARK: - Carrying the last reading past the finish line

    private func snapshot(_ jobs: [Job]) -> Snapshot {
        Snapshot(
            schemaVersion: 1, generatedAt: Date(),
            cluster: ClusterInfo(name: nil, hostname: nil, slurmVersion: nil),
            summary: .empty, jobs: jobs
        )
    }

    func testLastReadingSurvivesTheJobLeavingTheQueue() {
        // sacct has no StdOut field, so the agent loses the log path — and with it any chance
        // of a reading — the moment squeue stops listing the job.
        let running = job(state: .running, current: 5640, total: 9400, source: .logParser)
        let finishedWithNothing = Job(jobID: "1", name: "j", state: .failed)

        let merged = ProgressCarryForward.apply(
            previous: snapshot([running]), to: snapshot([finishedWithNothing])
        )
        let result = merged.jobs[0]
        XCTAssertEqual(result.progress?.current, 5640)
        XCTAssertTrue(result.progress?.carriedForward == true)
        XCTAssertEqual(result.progressDisposition, .stoppedAt)
    }

    func testCarriedReadingDropsItsETA() {
        // Extrapolated from a throughput that has since stopped.
        let running = Job(
            jobID: "1", name: "j", state: .running,
            progress: JobProgress(source: .logParser, current: 50, total: 100, etaSeconds: 3600)
        )
        let merged = ProgressCarryForward.apply(
            previous: snapshot([running]), to: snapshot([Job(jobID: "1", name: "j", state: .completed)])
        )
        XCTAssertNil(merged.jobs[0].progress?.etaSeconds)
    }

    func testACarriedReadingSurvivesMoreThanOnePoll() {
        // Harvesting only from active jobs meant a carried reading lasted exactly one poll:
        // by the next one its source job was finished and no longer a source at all.
        let running = job(state: .running, current: 5640, total: 9400, source: .logParser)
        let finished = Job(jobID: "1", name: "j", state: .completed)

        var current = snapshot([running])
        for poll in 1...5 {
            current = ProgressCarryForward.apply(previous: current, to: snapshot([finished]))
            XCTAssertEqual(current.jobs[0].progress?.current, 5640, "lost at poll \(poll)")
            XCTAssertTrue(current.jobs[0].progress?.carriedForward == true, "poll \(poll)")
        }
    }

    func testAFreshReadingIsNeverOverwrittenByAnOlderOne() {
        let running = job(state: .running, current: 10, total: 100)
        let finishedWithItsOwn = job(state: .completed, current: 100, total: 100)
        let merged = ProgressCarryForward.apply(
            previous: snapshot([running]), to: snapshot([finishedWithItsOwn])
        )
        XCTAssertEqual(merged.jobs[0].progress?.current, 100)
        XCTAssertFalse(merged.jobs[0].progress?.carriedForward == true)
    }

    func testNothingIsCarriedOntoAJobThatIsStillRunning() {
        // A running job with no reading this poll means the log stopped being parseable, not
        // that the old number is still true.
        let previous = job(state: .running, current: 10, total: 100)
        let stillRunning = Job(jobID: "1", name: "j", state: .running)
        let merged = ProgressCarryForward.apply(
            previous: snapshot([previous]), to: snapshot([stillRunning])
        )
        XCTAssertNil(merged.jobs[0].progress)
    }

    func testCarryForwardSurvivesTheSnapshotCacheRoundTrip() throws {
        let carried = job(state: .completed, current: 284, total: 300).replacingProgress(
            JobProgress(source: .logParser, current: 284, total: 300).asCarriedForward()
        )
        let data = try JSONEncoder().encode(snapshot([carried]))
        let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        XCTAssertTrue(decoded.jobs[0].progress?.carriedForward == true)
    }

    func testAgentPayloadsHaveNoCarriedFlag() {
        // The field is app-local. An agent that never heard of it must decode as "measured".
        let json = #"{"source":"log_parser","current":5,"total":10,"stale":false,"metrics":{}}"#
        let progress = try? JSONDecoder().decode(JobProgress.self, from: Data(json.utf8))
        XCTAssertFalse(progress?.carriedForward == true)
    }

    func testMenuBarStopsReportingAPinnedJobOnceItFinishes() {
        // A pinned job that ended at 63% used to keep showing "63%" forever, contradicting a
        // popover that had already filed it under a finished section.
        let finished = job(state: .completed, current: 63, total: 100)
        let snapshot = Snapshot(
            schemaVersion: 1, generatedAt: Date(),
            cluster: ClusterInfo(name: nil, hostname: nil, slurmVersion: nil),
            summary: .empty, jobs: [finished]
        )
        XCTAssertNil(MenuBarLabelBuilder.pinnedPercentText(snapshot: snapshot, pinnedJobID: "1"))
    }
}
