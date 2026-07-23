import XCTest
@testable import SlurmBarKit

final class DurationFormattingTests: XCTestCase {
    func testCompactDurations() {
        XCTAssertEqual(Formatters.duration(seconds: 0), "0s")
        XCTAssertEqual(Formatters.duration(seconds: 45), "45s")
        XCTAssertEqual(Formatters.duration(seconds: 60), "1m")
        XCTAssertEqual(Formatters.duration(seconds: 500), "8m 20s")
        XCTAssertEqual(Formatters.duration(seconds: 3600), "1h")
        XCTAssertEqual(Formatters.duration(seconds: 8400), "2h 20m")
        XCTAssertEqual(Formatters.duration(seconds: 86400), "1d")
        XCTAssertEqual(Formatters.duration(seconds: 187_200), "2d 4h")
    }

    func testDurationNeverShowsMoreThanTwoUnits() {
        // A dense row cannot fit "2d 4h 17m 33s", and the extra precision is meaningless.
        XCTAssertEqual(Formatters.duration(seconds: 187_053), "2d 3h")
    }

    func testUnavailableDurationIsNotZero() {
        XCTAssertEqual(Formatters.duration(seconds: nil), "N/A")
        XCTAssertEqual(Formatters.duration(seconds: -5), "N/A")
    }

    func testClockDuration() {
        XCTAssertEqual(Formatters.clockDuration(seconds: 8400), "02:20:00")
        XCTAssertEqual(Formatters.clockDuration(seconds: 45), "00:00:45")
        XCTAssertEqual(Formatters.clockDuration(seconds: 90061), "1d 01:01:01")
        XCTAssertEqual(Formatters.clockDuration(seconds: nil), "N/A")
    }

    func testETAIsAlwaysMarkedApproximate() {
        XCTAssertEqual(Formatters.eta(seconds: 30), "~30s left")
        XCTAssertEqual(Formatters.eta(seconds: 13993), "~3h 53m left")
        XCTAssertEqual(Formatters.eta(seconds: nil), "N/A")
    }

    func testElapsedWithLimit() {
        XCTAssertEqual(Formatters.elapsedWithLimit(elapsed: 8400, limit: 86400), "2h 20m / 1d")
        // No time limit is a real state, not a missing value.
        XCTAssertEqual(Formatters.elapsedWithLimit(elapsed: 8400, limit: nil), "2h 20m")
        XCTAssertEqual(Formatters.elapsedWithLimit(elapsed: nil, limit: 3600), "N/A / 1h")
    }
}

final class ByteFormattingTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(Formatters.bytes(nil), "N/A")
        for value: Int64 in [0, 1024 * 1024, 120_946_278_400] {
            let rendered = Formatters.bytes(value)
            XCTAssertFalse(rendered.isEmpty)
            XCTAssertNotEqual(rendered, "N/A")
        }
    }

    func testNegativeBytesAreUnavailableNotZero() {
        XCTAssertEqual(Formatters.bytes(-1), "N/A")
    }

    func testMemoryCarriesItsSemantics() {
        let resources = JobResources(
            memoryUsedBytes: 120_946_278_400,
            memoryLimitBytes: 274_877_906_944,
            memorySemantics: .peakRSS,
            memoryLimitSemantics: .requestedPerNode
        )
        let text = Formatters.memory(resources)
        XCTAssertTrue(text.contains("peak"), text)
        XCTAssertTrue(text.contains("per node"), text)
    }

    func testMemoryUnavailableIsNotFabricated() {
        XCTAssertEqual(Formatters.memory(.unavailable), "N/A")
    }

    func testLimitOnlyMemoryShowsADashForUsage() {
        let resources = JobResources(
            memoryLimitBytes: 34_359_738_368,
            memoryLimitSemantics: .requestedTotal
        )
        XCTAssertTrue(Formatters.memory(resources).hasPrefix("—"))
    }

    func testMemoryFractionOnlyWhenComparable() {
        // A per-CPU request is not a job-wide ceiling; filling a bar against it would lie.
        let perCPU = JobResources(
            memoryUsedBytes: 1_000_000,
            memoryLimitBytes: 4_294_967_296,
            memorySemantics: .peakRSS,
            memoryLimitSemantics: .requestedPerCPU
        )
        XCTAssertNil(perCPU.memoryFraction)

        let total = JobResources(
            memoryUsedBytes: 17_179_869_184,
            memoryLimitBytes: 34_359_738_368,
            memorySemantics: .peakRSS,
            memoryLimitSemantics: .requestedTotal
        )
        XCTAssertEqual(total.memoryFraction ?? 0, 0.5, accuracy: 0.001)
    }
}

final class NumberFormattingTests: XCTestCase {
    func testCounts() {
        XCTAssertEqual(Formatters.count(375), "375")
        XCTAssertEqual(Formatters.count(4820), "4,820")
        XCTAssertEqual(Formatters.count(1.5), "1.50")
    }

    func testPercent() {
        XCTAssertEqual(Formatters.percent(37.5), "38%")
        XCTAssertEqual(Formatters.percent(37.5, decimals: 1), "37.5%")
        XCTAssertEqual(Formatters.percent(nil), "N/A")
        XCTAssertEqual(Formatters.percent(Double.nan), "N/A")
        XCTAssertEqual(Formatters.percent(150), "100%")
        XCTAssertEqual(Formatters.percent(-10), "0%")
    }

    func testExitStatus() {
        XCTAssertEqual(Formatters.exitStatus(exitCode: 0, signal: 0), "0 (success)")
        XCTAssertEqual(Formatters.exitStatus(exitCode: 1, signal: 0), "1")
        XCTAssertEqual(Formatters.exitStatus(exitCode: 0, signal: 9), "killed by signal 9")
        XCTAssertEqual(Formatters.exitStatus(exitCode: nil, signal: nil), "N/A")
    }
}

final class MetricValueTests: XCTestCase {
    func testNumericFormatting() {
        XCTAssertEqual(MetricValue.number(375).displayString, "375")
        XCTAssertEqual(MetricValue.number(0.059045).displayString, "0.05905")
        XCTAssertEqual(MetricValue.number(0.000034).displayString, "3.4e-05")
    }

    func testNaNIsDetectedFromBothRepresentations() {
        XCTAssertTrue(MetricValue.string("nan").isNaN)
        XCTAssertTrue(MetricValue.string("NaN").isNaN)
        XCTAssertTrue(MetricValue.number(Double.nan).isNaN)
        XCTAssertFalse(MetricValue.number(0.5).isNaN)
    }

    func testInfinityIsDetected() {
        XCTAssertTrue(MetricValue.string("inf").isInfinite)
        XCTAssertTrue(MetricValue.string("-inf").isInfinite)
    }

    func testNaNStringIsNotCoercedToANumber() {
        XCTAssertNil(MetricValue.string("nan").doubleValue)
    }

    func testDecodesEveryProtocolType() throws {
        let json = #"{"a": 1.5, "b": "text", "c": true, "d": null}"#
        let decoded = try JSONDecoder().decode([String: MetricValue].self, from: Data(json.utf8))
        XCTAssertEqual(decoded["a"], .number(1.5))
        XCTAssertEqual(decoded["b"], .string("text"))
        XCTAssertEqual(decoded["c"], .bool(true))
        XCTAssertEqual(decoded["d"], .null)
    }
}

final class ProgressPresentationTests: XCTestCase {
    func testFractionFromPercent() {
        let progress = JobProgress(source: .structuredFile, current: 375, total: 1000, percent: 37.5)
        XCTAssertEqual(progress.fraction ?? 0, 0.375, accuracy: 0.0001)
    }

    func testFractionFallsBackToCounters() {
        let progress = JobProgress(source: .structuredFile, current: 1, total: 4)
        XCTAssertEqual(progress.fraction ?? 0, 0.25, accuracy: 0.0001)
    }

    func testNoFractionWhenTotalIsUnknown() {
        let progress = JobProgress(source: .structuredFile, current: 4820, total: nil, unit: "file")
        XCTAssertNil(progress.fraction)
        XCTAssertEqual(progress.counterDescription, "4,820 files")
    }

    func testCounterDescriptionWithTotal() {
        let progress = JobProgress(source: .structuredFile, current: 375, total: 1000, unit: "epoch")
        XCTAssertEqual(progress.counterDescription, "375 / 1,000 epochs")
    }

    func testSingularUnit() {
        let progress = JobProgress(source: .structuredFile, current: 1, total: 1, unit: "epoch")
        XCTAssertEqual(progress.counterDescription, "1 / 1 epoch")
    }

    func testFractionIsClampedToOne() {
        let progress = JobProgress(source: .structuredFile, current: 1200, total: 1000)
        XCTAssertEqual(progress.fraction, 1.0)
    }

    func testHighlightedMetricsPreferLossFirst() {
        let progress = JobProgress(
            source: .structuredFile,
            metrics: [
                "zzz": .number(1),
                "learning_rate": .number(0.001),
                "loss": .number(0.5),
                "batch_current": .number(3),
            ]
        )
        let highlighted = progress.highlightedMetrics(limit: 2).map(\.key)
        XCTAssertEqual(highlighted, ["loss", "learning_rate"])
    }

    func testBatchDescription() {
        let progress = JobProgress(
            source: .structuredFile,
            metrics: ["batch_current": .number(36), "batch_total": .number(94)]
        )
        XCTAssertEqual(progress.batchDescription, "batch 36/94")
    }
}

final class JobPresentationTests: XCTestCase {
    func testTimeLimitFraction() {
        let job = Job(jobID: "1", name: "x", state: .running, elapsedSeconds: 43200, timeLimitSeconds: 86400)
        XCTAssertEqual(job.timeLimitFraction ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(job.remainingTimeSeconds, 43200)
    }

    func testNoTimeLimitMeansNoFraction() {
        let job = Job(jobID: "1", name: "x", state: .running, elapsedSeconds: 43200, timeLimitSeconds: nil)
        XCTAssertNil(job.timeLimitFraction)
        XCTAssertNil(job.remainingTimeSeconds)
    }

    func testResourceSummaryOmitsWhatIsUnknown() {
        XCTAssertEqual(
            Job(jobID: "1", name: "x", state: .running, nodeCount: 2, cpus: 32, gpus: 1).resourceSummary,
            "32 CPU · 1 GPU · 2 nodes"
        )
        XCTAssertEqual(Job(jobID: "1", name: "x", state: .running).resourceSummary, "")
    }

    func testNodeSummaryCollapsesLongLists() {
        let job = Job(jobID: "1", name: "x", state: .running, nodes: ["a", "b", "c", "d"])
        XCTAssertEqual(job.nodeSummary, "a +3")
        XCTAssertEqual(Job(jobID: "1", name: "x", state: .running, nodes: ["a", "b"]).nodeSummary, "a, b")
        XCTAssertNil(Job(jobID: "1", name: "x", state: .running).nodeSummary)
    }
}

final class JobStateTests: XCTestCase {
    func testActiveStates() {
        XCTAssertTrue(JobState.running.isActive)
        XCTAssertTrue(JobState.pending.isActive)
        XCTAssertTrue(JobState.completing.isActive)
        XCTAssertFalse(JobState.completed.isActive)
        XCTAssertFalse(JobState.failed.isActive)
    }

    func testFailureStates() {
        XCTAssertTrue(JobState.failed.isFailure)
        XCTAssertTrue(JobState.timeout.isFailure)
        XCTAssertTrue(JobState.outOfMemory.isFailure)
        XCTAssertTrue(JobState.nodeFail.isFailure)
        // A user cancelling their own job is not a failure.
        XCTAssertFalse(JobState.cancelled.isFailure)
        XCTAssertFalse(JobState.completed.isFailure)
    }

    func testEveryStateHasDistinctPresentation() {
        let names = Set(JobState.allCases.map(\.displayName))
        XCTAssertEqual(names.count, JobState.allCases.count)
        XCTAssertFalse(JobState.allCases.contains { $0.symbolName.isEmpty })
    }
}
