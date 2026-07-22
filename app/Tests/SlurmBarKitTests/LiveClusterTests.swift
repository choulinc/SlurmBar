import XCTest
@testable import SlurmBarKit

/// Opt-in tests that talk to a real cluster.
///
/// Skipped unless `SLURMBAR_LIVE_ALIAS` is set, so the normal suite stays hermetic:
///
///     SLURMBAR_LIVE_ALIAS=my-cluster swift test --filter LiveClusterTests
///
/// These exercise the exact path the app uses — `/usr/bin/ssh` via `Process`, real agent,
/// real decoding — which fixture tests by construction cannot cover.
final class LiveClusterTests: XCTestCase {
    private var alias: String {
        get throws {
            guard let value = ProcessInfo.processInfo.environment["SLURMBAR_LIVE_ALIAS"],
                  !value.isEmpty
            else {
                throw XCTSkip("set SLURMBAR_LIVE_ALIAS to run live cluster tests")
            }
            return value
        }
    }

    private func profile() throws -> ClusterProfile {
        var profile = ClusterProfile(displayName: "Live", sshAlias: try alias)
        profile.timeoutSeconds = 30
        profile.connectTimeoutSeconds = 10
        return profile
    }

    func testSSHRunnerReachesTheCluster() async throws {
        let runner = SSHCommandRunner(alias: try alias, connectTimeout: 10)
        let result = try await runner.run(remoteArguments: ["echo", "slurmbar-live-ok"], timeout: 30)
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.standardError)")
        XCTAssertEqual(
            String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            "slurmbar-live-ok"
        )
    }

    func testDoctorAgainstTheRealAgent() async throws {
        let report = try await AgentClient.live(profile: try profile()).doctor()
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertFalse(report.checks.isEmpty)
        print("live doctor: ok=\(report.ok) python=\(report.pythonVersion ?? "?")")
        for check in report.checks {
            print("  [\(check.status.rawValue)] \(check.title): \(check.value ?? check.detail ?? "")")
        }
    }

    func testSnapshotAgainstTheRealAgent() async throws {
        let snapshot = try await AgentClient.live(profile: try profile()).snapshot()
        XCTAssertEqual(snapshot.schemaVersion, 1)
        print("live snapshot: \(snapshot.jobs.count) jobs, summary \(snapshot.summary)")

        // Every job must be honestly representable by the UI.
        for job in snapshot.jobs {
            XCTAssertFalse(job.jobID.isEmpty)
            if let path = job.stdoutPath {
                XCTAssertFalse(path.contains("%"), "unexpanded log pattern: \(path)")
            }
            if job.state.isActive {
                XCTAssertNil(job.exitCode, "active job \(job.jobID) must not claim an exit code")
            }
        }

        for job in snapshot.jobs.prefix(5) {
            print("  \(job.jobID) \(job.state.rawValue) \(job.name) "
                  + "elapsed=\(Formatters.duration(seconds: job.elapsedSeconds)) "
                  + "mem=\(Formatters.memory(job.resources)) "
                  + "progress=\(job.progress?.source.rawValue ?? "none")")
        }
    }

    func testMonitorEndToEnd() async throws {
        // Resolve the profile *outside* the MainActor closure: `try?` in there would swallow
        // the XCTSkip and the test would run against an empty profile.
        let liveProfile = try profile()
        let notifier = RecordingNotifier()
        let monitor = await MainActor.run {
            ClusterMonitor(
                profile: liveProfile,
                cache: SnapshotCache(directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("slurmbar-live-\(UUID().uuidString)")),
                notifier: notifier
            )
        }
        await MainActor.run { monitor.refresh() }

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let done = await MainActor.run { monitor.connection.isConnected || monitor.connection.failure != nil }
            if done { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let (connected, failure, count) = await MainActor.run {
            (monitor.connection.isConnected, monitor.connection.failure, monitor.snapshot?.jobs.count ?? 0)
        }
        if let failure {
            XCTFail("live refresh failed: \(failure.title) — \(failure.message)")
        }
        XCTAssertTrue(connected)
        print("live monitor: connected with \(count) jobs")
    }
}
