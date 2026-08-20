import Foundation
import XCTest
@testable import SlurmBarKit

final class RemoteAgentInstallerTests: XCTestCase {
    func testStreamsAgentAndRunsDoctorWithDefaultInstalledPath() async throws {
        let agent = Data("example-agent".utf8)
        let runner = StubInstallRunner(
            uploadResult: RemoteCommandResult(
                exitCode: 0,
                standardOutput: Data("\(agent.count)\n".utf8),
                standardError: "",
                duration: 0.01
            ),
            doctorResult: RemoteCommandResult(
                exitCode: 0,
                standardOutput: Data(Self.doctorJSON.utf8),
                standardError: "",
                duration: 0.01
            )
        )
        var profile = ClusterProfile(displayName: "Test", sshAlias: "test-cluster")
        profile.agentCommand = ["/custom/python", "/custom/agent.pyz"]

        let report = try await RemoteAgentInstaller(profile: profile, runner: runner)
            .install(agentData: agent)

        XCTAssertTrue(report.ok)
        XCTAssertEqual(runner.uploadedData, agent)
        XCTAssertEqual(Array(runner.uploadArguments?.prefix(2) ?? []), ["sh", "-c"])
        XCTAssertEqual(
            Array(runner.doctorArguments?.prefix(2) ?? []),
            ClusterProfile.defaultAgentCommand
        )
        XCTAssertTrue(runner.doctorArguments?.contains("doctor") ?? false)
    }

    func testRejectsUploadSizeMismatchBeforeDoctor() async {
        let runner = StubInstallRunner(
            uploadResult: RemoteCommandResult(
                exitCode: 0,
                standardOutput: Data("1\n".utf8),
                standardError: "",
                duration: 0.01
            ),
            doctorResult: RemoteCommandResult(
                exitCode: 0,
                standardOutput: Data(Self.doctorJSON.utf8),
                standardError: "",
                duration: 0.01
            )
        )
        let profile = ClusterProfile(displayName: "Test", sshAlias: "test-cluster")

        do {
            _ = try await RemoteAgentInstaller(profile: profile, runner: runner)
                .install(agentData: Data("agent".utf8))
            XCTFail("Expected a size mismatch")
        } catch let failure as SSHFailure {
            guard case .remoteCommandFailed = failure else {
                return XCTFail("Unexpected failure: \(failure)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertNil(runner.doctorArguments)
    }

    func testInstallScriptIsHomeScopedAndDoesNotUsePrivilegeEscalation() {
        let script = RemoteAgentInstaller.installScript
        XCTAssertTrue(script.contains("$HOME/.local/share/slurmbar"))
        XCTAssertTrue(script.contains("python3 \"$incoming\" --version"))
        XCTAssertTrue(script.contains("mktemp"))
        XCTAssertTrue(script.contains("symbolic-link"))
        XCTAssertFalse(script.contains("sudo"))
        XCTAssertFalse(script.contains("StrictHostKeyChecking"))
    }

    func testProcessRunnerCanStreamStandardInput() async throws {
        let payload = Data("streamed payload\n".utf8)
        let result = try await ProcessRunner.run(
            executable: "/bin/cat",
            arguments: [],
            timeout: 2,
            maxOutputBytes: 1024,
            standardInput: payload
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, payload)
    }

    private static let doctorJSON = #"{"schema_version":1,"generated_at":"2026-08-20T00:00:00Z","agent_version":"0.2.4","ok":true,"hostname":"test","python_version":"3.9.0","warnings":[],"checks":[]}"#
}

private final class StubInstallRunner: RemoteInputCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let uploadResult: RemoteCommandResult
    private let doctorResult: RemoteCommandResult
    private(set) var uploadArguments: [String]?
    private(set) var uploadedData: Data?
    private(set) var doctorArguments: [String]?

    init(uploadResult: RemoteCommandResult, doctorResult: RemoteCommandResult) {
        self.uploadResult = uploadResult
        self.doctorResult = doctorResult
    }

    func run(remoteArguments: [String], timeout: TimeInterval) async throws -> RemoteCommandResult {
        lock.withLock { doctorArguments = remoteArguments }
        return doctorResult
    }

    func run(
        remoteArguments: [String],
        standardInput: Data,
        timeout: TimeInterval
    ) async throws -> RemoteCommandResult {
        lock.withLock {
            uploadArguments = remoteArguments
            uploadedData = standardInput
        }
        return uploadResult
    }
}
