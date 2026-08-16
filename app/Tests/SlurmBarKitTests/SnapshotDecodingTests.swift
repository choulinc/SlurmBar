import XCTest
@testable import SlurmBarKit

final class SnapshotDecodingTests: XCTestCase {
    private let decoder = ProtocolDecoder()

    // MARK: - The shared example payloads

    func testDecodesTheFullExampleSnapshot() throws {
        let snapshot = try decoder.decodeSnapshot(from: try Fixtures.data(named: "snapshot-full.json"))

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.generatedAt, isoDate("2026-07-22T02:30:00Z"))
        XCTAssertEqual(snapshot.cluster.name, "examplecluster")
        XCTAssertEqual(snapshot.cluster.slurmVersion, "slurm 23.11.7")
        XCTAssertEqual(snapshot.jobs.count, 8)
        XCTAssertEqual(snapshot.summary.running, 3)
        XCTAssertEqual(snapshot.summary.pending, 2)
    }

    func testDecodesRunningJobFields() throws {
        let snapshot = try decoder.decodeSnapshot(from: try Fixtures.data(named: "snapshot-full.json"))
        let job = try XCTUnwrap(snapshot.jobs.first { $0.jobID == "201551" })

        XCTAssertEqual(job.name, "example-training")
        XCTAssertEqual(job.state, .running)
        XCTAssertEqual(job.stateRaw, "RUNNING")
        XCTAssertEqual(job.elapsedSeconds, 8400)
        XCTAssertEqual(job.timeLimitSeconds, 86400)
        XCTAssertEqual(job.nodes, ["example-gpu-017"])
        XCTAssertEqual(job.cpus, 32)
        XCTAssertEqual(job.gpus, 1)
        XCTAssertNil(job.endTime)
        XCTAssertEqual(job.source, .squeue)
    }

    func testDecodesMemorySemantics() throws {
        let snapshot = try decoder.decodeSnapshot(from: try Fixtures.data(named: "snapshot-full.json"))
        let running = try XCTUnwrap(snapshot.jobs.first { $0.jobID == "201551" })
        XCTAssertEqual(running.resources.memorySemantics, .peakRSS)
        XCTAssertEqual(running.resources.memoryLimitSemantics, .requestedPerNode)

        let finished = try XCTUnwrap(snapshot.jobs.first { $0.jobID == "201540" })
        XCTAssertEqual(finished.resources.memorySemantics, .peakRSSPerStep)
        XCTAssertEqual(finished.resources.memoryLimitSemantics, .requestedTotal)
    }

    func testDecodesStructuredProgressWithMetrics() throws {
        let snapshot = try decoder.decodeSnapshot(from: try Fixtures.data(named: "snapshot-full.json"))
        let progress = try XCTUnwrap(snapshot.jobs.first { $0.jobID == "201551" }?.progress)

        XCTAssertEqual(progress.source, .structuredFile)
        XCTAssertEqual(progress.confidence, .high)
        XCTAssertEqual(progress.current, 375)
        XCTAssertEqual(progress.total, 1000)
        XCTAssertEqual(progress.percent, 37.5)
        XCTAssertEqual(progress.unit, "epoch")
        XCTAssertEqual(progress.etaSeconds, 13993)
        XCTAssertEqual(progress.metrics["loss"]?.doubleValue, 0.059045)
        XCTAssertEqual(progress.metrics["batch_current"]?.doubleValue, 36)
        XCTAssertFalse(progress.stale)
    }

    func testDecodesLogParsedProgressAsLowerConfidence() throws {
        let snapshot = try decoder.decodeSnapshot(from: try Fixtures.data(named: "snapshot-full.json"))
        let progress = try XCTUnwrap(snapshot.jobs.first { $0.jobID == "201580" }?.progress)

        XCTAssertEqual(progress.source, .logParser)
        XCTAssertEqual(progress.confidence, .medium)
        XCTAssertFalse(progress.source.isAuthoritative)
        XCTAssertNil(progress.etaSeconds)
    }

    func testDecodesNaNMetricAsAString() throws {
        let snapshot = try decoder.decodeSnapshot(from: try Fixtures.data(named: "snapshot-full.json"))
        let progress = try XCTUnwrap(snapshot.jobs.first { $0.jobID == "201580" }?.progress)
        XCTAssertTrue(progress.hasNaNMetric)
        XCTAssertEqual(progress.nanMetricNames, ["loss"])
    }

    func testDecodesUnknownTotalAsNil() throws {
        let snapshot = try decoder.decodeSnapshot(from: try Fixtures.data(named: "snapshot-full.json"))
        let progress = try XCTUnwrap(snapshot.jobs.first { $0.jobID == "201570" }?.progress)
        XCTAssertNil(progress.total)
        XCTAssertNil(progress.percent)
        XCTAssertNil(progress.fraction)
        XCTAssertEqual(progress.current, 4820)
    }

    func testDecodesArrayTaskIdentity() throws {
        let snapshot = try decoder.decodeSnapshot(from: try Fixtures.data(named: "snapshot-full.json"))
        let job = try XCTUnwrap(snapshot.jobs.first { $0.jobID == "201560_7" })
        XCTAssertTrue(job.isArrayTask)
        XCTAssertEqual(job.arrayJobID, "201560")
        XCTAssertEqual(job.arrayTaskID, "7")
        XCTAssertEqual(job.reason, "Resources")
    }

    func testDecodesEmptySnapshot() throws {
        let snapshot = try decoder.decodeSnapshot(from: try Fixtures.data(named: "snapshot-empty.json"))
        XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertEqual(snapshot.summary, .empty)
    }

    func testDecodesDegradedSnapshotWithWarnings() throws {
        let snapshot = try decoder.decodeSnapshot(from: try Fixtures.data(named: "snapshot-degraded.json"))
        XCTAssertEqual(snapshot.jobs.count, 1)
        XCTAssertEqual(snapshot.warnings.count, 4)
        XCTAssertTrue(snapshot.warnings.contains { $0.code == "SACCT_UNAVAILABLE" })
        XCTAssertNil(snapshot.cluster.slurmVersion)
        XCTAssertNil(snapshot.jobs[0].timeLimitSeconds)
    }

    // MARK: - Version handling

    func testRejectsUnsupportedSchemaVersion() throws {
        let data = try Fixtures.data(named: "snapshot-unsupported-version.json")
        XCTAssertThrowsError(try decoder.decodeSnapshot(from: data)) { error in
            guard case ProtocolError.unsupportedSchemaVersion(let found, let supported) = error else {
                return XCTFail("expected unsupportedSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, 1)
            // The message must tell the user which side to update.
            XCTAssertTrue(ProtocolError.unsupportedSchemaVersion(found: found, supported: supported)
                .recoverySuggestion?.contains("Update SlurmBar") ?? false)
        }
    }

    func testOlderAgentVersionSuggestsReinstallingTheAgent() {
        let error = ProtocolError.unsupportedSchemaVersion(found: 0, supported: 1)
        XCTAssertTrue(error.recoverySuggestion?.contains("install-agent") ?? false)
    }

    func testMissingSchemaVersionIsItsOwnError() {
        let data = Data(#"{"jobs": []}"#.utf8)
        XCTAssertThrowsError(try decoder.decodeSnapshot(from: data)) { error in
            guard case ProtocolError.missingSchemaVersion = error else {
                return XCTFail("expected missingSchemaVersion, got \(error)")
            }
        }
    }

    // MARK: - Untrusted input

    func testRejectsEmptyResponse() {
        XCTAssertThrowsError(try decoder.decodeSnapshot(from: Data())) { error in
            guard case ProtocolError.emptyResponse = error else {
                return XCTFail("expected emptyResponse, got \(error)")
            }
        }
    }

    func testRejectsMalformedJSONWithAPreview() {
        let data = Data("this is not json at all".utf8)
        XCTAssertThrowsError(try decoder.decodeSnapshot(from: data)) { error in
            guard case ProtocolError.malformedJSON(let preview) = error else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
            XCTAssertTrue(preview.contains("not json"))
        }
    }

    func testMalformedJSONSuggestsCheckingShellStartupOutput() {
        // The classic cause: a login script echoing a banner ahead of the agent's JSON.
        let error = ProtocolError.malformedJSON(preview: "Welcome to the cluster!")
        XCTAssertTrue(error.recoverySuggestion?.contains("shell startup") ?? false)
    }

    func testRejectsOversizedPayload() {
        let data = Data(count: ProtocolDecoder.maxPayloadBytes + 1)
        XCTAssertThrowsError(try decoder.decodeSnapshot(from: data)) { error in
            guard case ProtocolError.payloadTooLarge = error else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
        }
    }

    func testSurfacesStructuredAgentErrors() {
        let data = Data(#"{"schema_version":1,"error":{"code":"NOT_FOUND","message":"Job 42 was not found."}}"#.utf8)
        XCTAssertThrowsError(try decoder.decodeSnapshot(from: data)) { error in
            guard case ProtocolError.agentError(let code, let message) = error else {
                return XCTFail("expected agentError, got \(error)")
            }
            XCTAssertEqual(code, "NOT_FOUND")
            XCTAssertEqual(message, "Job 42 was not found.")
        }
    }

    func testUnknownStateDecodesAsUnknownRatherThanFailing() throws {
        let json = """
        {"schema_version":1,"generated_at":"2026-07-22T02:30:00Z",
         "cluster":{"name":null,"hostname":null,"slurm_version":null},
         "summary":{"running":0,"pending":0,"completing":0,"failed_recently":0,"completed_recently":0},
         "jobs":[{"job_id":"1","name":"x","state":"SOME_FUTURE_STATE","state_raw":"SOME_FUTURE_STATE",
                  "resources":{"memory_used_bytes":null,"memory_limit_bytes":null,"memory_semantics":"unavailable"},
                  "progress":null}],
         "warnings":[]}
        """
        let snapshot = try decoder.decodeSnapshot(from: Data(json.utf8))
        XCTAssertEqual(snapshot.jobs[0].state, .unknown)
        XCTAssertEqual(snapshot.jobs[0].stateRaw, "SOME_FUTURE_STATE")
    }

    func testUnknownWarningCodeIsPassedThrough() throws {
        let json = """
        {"schema_version":1,"generated_at":"2026-07-22T02:30:00Z",
         "cluster":{"name":null,"hostname":null,"slurm_version":null},
         "summary":{"running":0,"pending":0,"completing":0,"failed_recently":0,"completed_recently":0},
         "jobs":[],
         "warnings":[{"code":"BRAND_NEW_CODE","message":"something new","severity":"warning"}]}
        """
        let snapshot = try decoder.decodeSnapshot(from: Data(json.utf8))
        XCTAssertEqual(snapshot.warnings.first?.code, "BRAND_NEW_CODE")
        XCTAssertEqual(snapshot.warnings.first?.severity, .warning)
    }

    func testStripsControlCharactersFromRemoteText() throws {
        let json = """
        {"schema_version":1,"generated_at":"2026-07-22T02:30:00Z",
         "cluster":{"name":null,"hostname":null,"slurm_version":null},
         "summary":{"running":0,"pending":0,"completing":0,"failed_recently":0,"completed_recently":0},
         "jobs":[{"job_id":"1","name":"evil\\u001b[31mred\\u0007\\u0000job","state":"RUNNING","state_raw":"R",
                  "resources":{"memory_used_bytes":null,"memory_limit_bytes":null,"memory_semantics":"unavailable"},
                  "progress":null}],
         "warnings":[]}
        """
        let snapshot = try decoder.decodeSnapshot(from: Data(json.utf8))
        let name = snapshot.jobs[0].name
        XCTAssertFalse(name.contains("\u{1B}"))
        XCTAssertFalse(name.contains("\u{07}"))
        XCTAssertFalse(name.contains("\u{00}"))
        XCTAssertTrue(name.contains("evil"))
        XCTAssertTrue(name.contains("job"))
    }

    /// Every display-only string on a job, with one attack per field.
    func testSanitizesEveryRemoteStringThatReachesTheUI() throws {
        let json = """
        {"schema_version":1,"generated_at":"2026-07-22T02:30:00Z",
         "cluster":{"name":null,"hostname":null,"slurm_version":null},
         "summary":{"running":1,"pending":0,"completing":0,"failed_recently":0,"completed_recently":0},
         "jobs":[{"job_id":"1","name":"job","state":"RUNNING",
                  "state_raw":"RUNNING\\u001b[2K\\u000aCOMPLETED",
                  "user":"root\\u202Enimda","account":"acct\\u0007","partition":"gpu\\u001b]0;title\\u0007",
                  "qos":"normal\\u2066","nodes":["node-1\\u000a\\u000afake-2","node\\u009b31m"],
                  "work_dir":"/home/u/\\u202Egnp.txt","stdout_path":"/home/u/\\u202Egnp.log",
                  "stderr_path":"/home/u/err\\u0000.log",
                  "resources":{"memory_used_bytes":null,"memory_limit_bytes":null,"memory_semantics":"unavailable"},
                  "progress":{"source":"structured_file","kind":"training\\u001b[31m","percent":50,
                              "metrics":{"lo\\u001b[31mss":1.5}}}],
         "warnings":[]}
        """
        let job = try XCTUnwrap(decoder.decodeSnapshot(from: Data(json.utf8)).jobs.first)

        let displayed: [String] = [
            job.stateRaw, job.user, job.account, job.partition, job.qos,
            job.workDirDisplay, job.stdoutPathDisplay, job.stderrPathDisplay,
            job.progress?.kind,
        ].compactMap { $0 } + job.nodes + (job.progress.map { Array($0.metrics.keys) } ?? [])

        XCTAssertEqual(displayed.count, 12)
        for value in displayed {
            XCTAssertFalse(value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F },
                           "C0/DEL survived in \(value.debugDescription)")
            XCTAssertFalse(value.unicodeScalars.contains { (0x80...0x9F).contains($0.value) },
                           "C1 survived in \(value.debugDescription)")
            XCTAssertFalse(value.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) },
                           "bidi override survived in \(value.debugDescription)")
            XCTAssertFalse(value.unicodeScalars.contains { (0x2066...0x2069).contains($0.value) },
                           "bidi isolate survived in \(value.debugDescription)")
            XCTAssertFalse(value.contains("\u{1B}"), "escape survived in \(value.debugDescription)")
        }
        XCTAssertEqual(job.nodes.count, 2)  // an embedded newline does not become an extra node
        XCTAssertEqual(job.progress?.metrics.keys.first, "loss")
    }

    /// A path is handed back to the agent to find a file, so the stored value must stay exact.
    func testKeepsLogPathsExactWhileSanitizingTheirDisplayForm() throws {
        let json = """
        {"schema_version":1,"generated_at":"2026-07-22T02:30:00Z",
         "cluster":{"name":null,"hostname":null,"slurm_version":null},
         "summary":{"running":1,"pending":0,"completing":0,"failed_recently":0,"completed_recently":0},
         "jobs":[{"job_id":"1","name":"job","state":"RUNNING",
                  "stdout_path":"/home/u/weird\\u0009name.log",
                  "resources":{"memory_used_bytes":null,"memory_limit_bytes":null,"memory_semantics":"unavailable"},
                  "progress":null}],
         "warnings":[]}
        """
        let job = try XCTUnwrap(decoder.decodeSnapshot(from: Data(json.utf8)).jobs.first)
        XCTAssertEqual(job.stdoutPath, "/home/u/weird\tname.log")
    }

    func testBoundsOversizedRemoteStrings() throws {
        let long = String(repeating: "A", count: 5_000)
        let json = """
        {"schema_version":1,"generated_at":"2026-07-22T02:30:00Z",
         "cluster":{"name":null,"hostname":null,"slurm_version":null},
         "summary":{"running":1,"pending":0,"completing":0,"failed_recently":0,"completed_recently":0},
         "jobs":[{"job_id":"1","name":"job","state":"RUNNING","user":"\(long)","state_raw":"\(long)",
                  "partition":"\(long)","nodes":["\(long)"],"stdout_path":"/tmp/\(long)",
                  "resources":{"memory_used_bytes":null,"memory_limit_bytes":null,"memory_semantics":"unavailable"},
                  "progress":{"source":"log_parser","kind":"\(long)","percent":1,"metrics":{"\(long)":1}}}],
         "warnings":[]}
        """
        let job = try XCTUnwrap(decoder.decodeSnapshot(from: Data(json.utf8)).jobs.first)
        XCTAssertLessThanOrEqual(job.user?.count ?? 0, 81)
        XCTAssertLessThanOrEqual(job.stateRaw?.count ?? 0, 61)
        XCTAssertLessThanOrEqual(job.partition?.count ?? 0, 81)
        XCTAssertLessThanOrEqual(job.nodes[0].count, 81)
        XCTAssertLessThanOrEqual(job.stdoutPathDisplay?.count ?? 0, 301)
        XCTAssertLessThanOrEqual(job.progress?.kind?.count ?? 0, 61)
        XCTAssertLessThanOrEqual(job.progress?.metrics.keys.first?.count ?? 0, 61)
        // …and the path itself is still whole, because the agent has to be able to find it.
        XCTAssertEqual(job.stdoutPath?.count, 5_005)
    }

    /// Two raw metric names can clean to the same name; the result must not depend on the
    /// dictionary's iteration order.
    func testCollidingMetricNamesResolveTheSameWayEveryTime() throws {
        let raw: [String: MetricValue] = [
            "loss\u{1B}[31m": .number(1),
            "loss": .number(2),
            "\u{202E}loss": .number(3),
            "\u{1B}[0m": .number(4),  // cleans away to nothing
        ]
        let cleaned = JobProgress.sanitizedMetricNames(raw)
        XCTAssertEqual(cleaned, ["loss": .number(2)])
        for _ in 0..<20 {
            XCTAssertEqual(JobProgress.sanitizedMetricNames(raw), cleaned)
        }
    }

    // MARK: - Other payloads

    func testDecodesDoctorReports() throws {
        let ok = try decoder.decodeDoctorReport(from: try Fixtures.data(named: "doctor-ok.json"))
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.checks.count, 10)
        XCTAssertTrue(ok.failures.isEmpty)

        let degraded = try decoder.decodeDoctorReport(from: try Fixtures.data(named: "doctor-degraded.json"))
        XCTAssertTrue(degraded.ok)
        XCTAssertEqual(degraded.warnings.count, 5)
    }

    func testDecodesLogTail() throws {
        let tail = try decoder.decodeLogTail(from: try Fixtures.data(named: "logs-tail.json"))
        XCTAssertEqual(tail.jobID, "201551")
        XCTAssertEqual(tail.stream, .stdout)
        XCTAssertEqual(tail.lines.count, 3)
        XCTAssertTrue(tail.truncated)
        XCTAssertEqual(tail.fileSizeBytes, 48_213_904)
    }

    func testDecodesCancelResult() throws {
        let result = try decoder.decodeCancelResult(from: try Fixtures.data(named: "cancel-ok.json"))
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.jobID, "201551")
        XCTAssertEqual(result.exitCode, 0)
    }

    // MARK: - Round trip

    func testSnapshotSurvivesEncodeDecodeForCaching() throws {
        let original = try decoder.decodeSnapshot(from: try Fixtures.data(named: "snapshot-full.json"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reDecoded = try ProtocolDecoder.makeJSONDecoder()
            .decode(Snapshot.self, from: try encoder.encode(original))
        XCTAssertEqual(reDecoded, original)
    }
}
