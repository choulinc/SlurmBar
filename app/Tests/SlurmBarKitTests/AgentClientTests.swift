import XCTest
@testable import SlurmBarKit

final class AgentClientTests: XCTestCase {
    private func profile(
        agentCommand: [String] = ["python3", "~/.local/share/slurmbar/slurmbar-agent.pyz"],
        historyHours: Int = 24,
        slurmUser: String = "",
        progressDirectory: String = ""
    ) -> ClusterProfile {
        ClusterProfile(
            displayName: "Example",
            sshAlias: "example-cluster",
            agentCommand: agentCommand,
            progressDirectory: progressDirectory,
            slurmUser: slurmUser,
            historyHours: historyHours
        )
    }

    // MARK: - Command construction

    func testSnapshotCommandShape() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let client = AgentClient(runner: runner, profile: profile())
        _ = try await client.snapshot()

        let argv = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(argv.prefix(4), [
            "python3", "~/.local/share/slurmbar/slurmbar-agent.pyz", "snapshot", "--json",
        ])
        XCTAssertTrue(argv.contains("--history-hours"))
        XCTAssertFalse(argv.contains("--user"), "no user flag when the profile does not set one")
        XCTAssertFalse(argv.contains("--progress-dir"))
    }

    func testOptionalFlagsAreOnlySentWhenConfigured() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let client = AgentClient(
            runner: runner,
            profile: profile(slurmUser: "exampleuser", progressDirectory: "/scratch/progress")
        )
        _ = try await client.snapshot()

        let argv = try XCTUnwrap(runner.invocations.first)
        let userIndex = try XCTUnwrap(argv.firstIndex(of: "--user"))
        XCTAssertEqual(argv[userIndex + 1], "exampleuser")
        let dirIndex = try XCTUnwrap(argv.firstIndex(of: "--progress-dir"))
        XCTAssertEqual(argv[dirIndex + 1], "/scratch/progress")
    }

    func testLogsCommandBoundsTheLineCount() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "logs-tail.json"))
        ])
        let client = AgentClient(runner: runner, profile: profile())
        _ = try await client.logs(jobID: "201551", stream: .stdout, lines: 10_000_000)

        let argv = try XCTUnwrap(runner.invocations.first)
        let linesIndex = try XCTUnwrap(argv.firstIndex(of: "--lines"))
        XCTAssertEqual(argv[linesIndex + 1], "2000", "an unbounded tail read must not be possible")
    }

    func testCancelAlwaysPassesConfirm() async throws {
        // The agent refuses to run scancel without it, which is a second guard behind the UI's
        // confirmation dialog.
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "cancel-ok.json"))
        ])
        let client = AgentClient(runner: runner, profile: profile())
        _ = try await client.cancel(jobID: "201551")

        let argv = try XCTUnwrap(runner.invocations.first)
        XCTAssertTrue(argv.contains("--confirm"))
        XCTAssertTrue(argv.contains("cancel"))
        XCTAssertTrue(argv.contains("201551"))
    }

    func testJobIDIsValidatedBeforeAnyCommandRuns() async {
        let runner = StubRemoteRunner(responses: [.init()])
        let client = AgentClient(runner: runner, profile: profile())

        for bad in [
            "201551; rm -rf ~", "$(id)", "../../etc/passwd", "abc",
            "１２３", "1234567890123456789",
        ] {
            do {
                _ = try await client.cancel(jobID: bad)
                XCTFail("\(bad) should have been rejected")
            } catch {
                // expected
            }
        }
        XCTAssertEqual(runner.invocationCount, 0, "no command may run for an invalid job id")
    }

    func testJobIDIsValidatedForLogsToo() async {
        let runner = StubRemoteRunner(responses: [.init()])
        let client = AgentClient(runner: runner, profile: profile())
        do {
            _ = try await client.logs(jobID: "1; cat /etc/passwd", stream: .stdout)
            XCTFail("should have been rejected")
        } catch {
            XCTAssertEqual(runner.invocationCount, 0)
        }
    }

    // MARK: - Response handling

    func testDecodesASuccessfulSnapshot() async throws {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: try Fixtures.data(named: "snapshot-full.json"))
        ])
        let snapshot = try await AgentClient(runner: runner, profile: profile()).snapshot()
        XCTAssertEqual(snapshot.jobs.count, 8)
    }

    func testNonZeroExitWithStructuredErrorSurfacesTheAgentMessage() async {
        let payload = #"{"schema_version":1,"error":{"code":"NOT_FOUND","message":"Job 999999 was not found."}}"#
        let runner = StubRemoteRunner(responses: [
            .init(exitCode: 4, stdout: Data(payload.utf8))
        ])
        do {
            _ = try await AgentClient(runner: runner, profile: profile()).snapshot()
            XCTFail("expected a failure")
        } catch let failure as SSHFailure {
            guard case .protocolFailure(.agentError(let code, let message)) = failure else {
                return XCTFail("got \(failure)")
            }
            XCTAssertEqual(code, "NOT_FOUND")
            XCTAssertTrue(message.contains("999999"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNonZeroExitWithStructuredErrorSanitizesAndBoundsRemoteText() async {
        let code = "BAD\u{202E}CODE"
        let message = "\u{1B}[31m" + String(repeating: "x", count: 5_000)
        let payload = try! JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "error": ["code": code, "message": message],
        ])
        let runner = StubRemoteRunner(responses: [
            .init(exitCode: 4, stdout: payload)
        ])

        do {
            _ = try await AgentClient(runner: runner, profile: profile()).snapshot()
            XCTFail("expected a failure")
        } catch let failure as SSHFailure {
            guard case .protocolFailure(.agentError(let receivedCode, let receivedMessage)) = failure else {
                return XCTFail("got \(failure)")
            }
            XCTAssertFalse(receivedCode.contains("\u{202E}"))
            XCTAssertFalse(receivedMessage.contains("\u{1B}"))
            XCTAssertLessThanOrEqual(receivedCode.count, 81)
            XCTAssertLessThanOrEqual(receivedMessage.count, 801)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNonZeroExitWithSSHStderrIsCategorized() async {
        let runner = StubRemoteRunner(responses: [
            .init(exitCode: 255, stderr: "ssh: Could not resolve hostname example-cluster: nodename nor servname provided")
        ])
        do {
            _ = try await AgentClient(runner: runner, profile: profile()).snapshot()
            XCTFail("expected a failure")
        } catch let failure as SSHFailure {
            guard case .aliasNotFound(let alias) = failure else { return XCTFail("got \(failure)") }
            XCTAssertEqual(alias, "example-cluster")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testMalformedJSONBecomesAProtocolFailure() async {
        let runner = StubRemoteRunner(responses: [
            .init(stdout: Data("Welcome to the cluster!\n{\"schema".utf8))
        ])
        do {
            _ = try await AgentClient(runner: runner, profile: profile()).snapshot()
            XCTFail("expected a failure")
        } catch let failure as SSHFailure {
            guard case .protocolFailure(.malformedJSON) = failure else { return XCTFail("got \(failure)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTransportFailuresPropagateUnchanged() async {
        let runner = StubRemoteRunner(failure: .timedOut(seconds: 12))
        do {
            _ = try await AgentClient(runner: runner, profile: profile()).snapshot()
            XCTFail("expected a failure")
        } catch let failure as SSHFailure {
            XCTAssertEqual(failure, .timedOut(seconds: 12))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testDebugCommandLineIsShowable() {
        let client = AgentClient(runner: StubRemoteRunner(responses: [.init()]), profile: profile())
        let command = client.debugCommandLine()
        XCTAssertTrue(command.contains("/usr/bin/ssh"))
        XCTAssertTrue(command.contains("BatchMode=yes"))
        XCTAssertTrue(command.contains("snapshot"))
    }
}

final class ClusterProfileTests: XCTestCase {
    func testDefaultAgentCommandPointsAtTheDocumentedInstallPath() {
        XCTAssertEqual(
            ClusterProfile.defaultAgentCommand,
            ["python3", "~/.local/share/slurmbar/slurmbar-agent.pyz"]
        )
    }

    func testValidationRequiresAnAlias() {
        XCTAssertFalse(ClusterProfile().isValid)
        XCTAssertTrue(ClusterProfile(sshAlias: "example").isValid)
    }

    func testValidationRejectsAnAliasWithSpaces() {
        let profile = ClusterProfile(sshAlias: "my cluster")
        XCTAssertFalse(profile.isValid)
        XCTAssertTrue(profile.validationErrors.contains { $0.contains("spaces") })
    }

    func testValidationRejectsAnAliasThatLooksLikeAnSSHOption() {
        let profile = ClusterProfile(sshAlias: "-oProxyCommand=/tmp/evil")
        XCTAssertFalse(profile.isValid)
        XCTAssertTrue(profile.validationErrors.contains { $0.contains("dash") })
    }

    func testValidationRejectsAnAbsurdPollingInterval() {
        var profile = ClusterProfile(sshAlias: "example")
        profile.pollIntervalSeconds = 1
        XCTAssertFalse(profile.isValid)
    }

    func testEffectiveNameFallsBackToTheAlias() {
        XCTAssertEqual(ClusterProfile(displayName: "  ", sshAlias: "example").effectiveName, "example")
        XCTAssertEqual(ClusterProfile(displayName: "Prod", sshAlias: "example").effectiveName, "Prod")
    }

    func testProfileStoresNoSecrets() throws {
        // The profile is written to disk in plain JSON; it must reference the user's SSH
        // configuration, never duplicate any part of it.
        let profile = ClusterProfile(displayName: "Example", sshAlias: "example-cluster")
        let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self).lowercased()
        for forbidden in ["password", "privatekey", "private_key", "identityfile", "passphrase", "secret", "token"] {
            XCTAssertFalse(json.contains(forbidden), "profile must not contain \(forbidden)")
        }
    }
}

final class AppSettingsTests: XCTestCase {
    func testDecodingToleratesAFileFromAnOlderBuild() throws {
        // Every field has a default, so a settings file missing new keys still loads.
        let json = #"{"clusters": [], "menuBarDisplayMode": "counts"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.recentlyFinishedHours, 24)
        XCTAssertTrue(settings.notifications.jobFailed)
        XCTAssertFalse(settings.launchAtLogin)
    }

    func testUnknownDisplayModeDoesNotBreakDecoding() throws {
        let json = #"{"clusters": []}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.menuBarDisplayMode, .counts)
    }

    func testSelectedClusterFallsBackWhenTheSelectionIsStale() {
        let a = ClusterProfile(displayName: "A", sshAlias: "a")
        let settings = AppSettings(clusters: [a], selectedClusterID: UUID())
        XCTAssertEqual(settings.selectedCluster?.id, a.id)
    }

    func testRoundTrip() throws {
        let original = AppSettings(
            clusters: [ClusterProfile(displayName: "A", sshAlias: "a")],
            menuBarDisplayMode: .pinnedJobPercent,
            pinnedJobID: "201551",
            recentlyFinishedHours: 48
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

final class SettingsStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("slurmbar-tests-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
    }

    @MainActor
    func testAddUpdateAndRemoveClustersPersist() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SettingsStore(fileURL: url)
        XCTAssertTrue(store.settings.clusters.isEmpty)

        var profile = ClusterProfile(displayName: "Example", sshAlias: "example")
        store.addCluster(profile)
        XCTAssertEqual(store.settings.clusters.count, 1)
        XCTAssertEqual(store.settings.selectedClusterID, profile.id)

        profile.displayName = "Renamed"
        store.updateCluster(profile)
        XCTAssertEqual(store.settings.clusters.first?.displayName, "Renamed")

        // A fresh store reads what the first one wrote.
        let reloaded = SettingsStore(fileURL: url)
        XCTAssertEqual(reloaded.settings.clusters.first?.displayName, "Renamed")

        store.removeCluster(id: profile.id)
        XCTAssertTrue(store.settings.clusters.isEmpty)
        XCTAssertNil(store.settings.selectedClusterID)
    }

    @MainActor
    func testCorruptSettingsFileIsPreservedNotDestroyed() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(to: url)

        let store = SettingsStore(fileURL: url)
        XCTAssertTrue(store.settings.clusters.isEmpty)

        let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backup.path),
            "hand-edited settings must be recoverable, not silently discarded"
        )
    }
}
