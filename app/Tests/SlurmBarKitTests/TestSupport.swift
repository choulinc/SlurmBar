import Foundation
import XCTest
@testable import SlurmBarKit

/// Locates `protocol/examples/*.json` at the repository root.
///
/// The Swift and Python suites decode the *same* files rather than each keeping a private copy,
/// so a protocol change that breaks one language cannot pass the other's tests.
enum Fixtures {
    static let repositoryRoot: URL = {
        // .../app/Tests/SlurmBarKitTests/TestSupport.swift -> repository root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SlurmBarKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
    }()

    static var examplesDirectory: URL {
        repositoryRoot.appendingPathComponent("protocol/examples", isDirectory: true)
    }

    static func data(named name: String) throws -> Data {
        let url = examplesDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Fixture \(name) not found at \(url.path)")
        }
        return try Data(contentsOf: url)
    }
}

func isoDate(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string) ?? Date(timeIntervalSince1970: 0)
}

/// A ``RemoteCommandRunner`` that replays canned responses. No process is ever launched.
final class StubRemoteRunner: RemoteCommandRunner, @unchecked Sendable {
    struct Response {
        var exitCode: Int32 = 0
        var stdout: Data = Data()
        var stderr: String = ""
        var error: SSHFailure?
        var delay: TimeInterval = 0
    }

    private let lock = NSLock()
    private var responses: [Response]
    private(set) var invocations: [[String]] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    convenience init(json: String) {
        self.init(responses: [Response(stdout: Data(json.utf8))])
    }

    convenience init(failure: SSHFailure) {
        self.init(responses: [Response(error: failure)])
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations.count
    }

    func run(remoteArguments: [String], timeout: TimeInterval) async throws -> RemoteCommandResult {
        lock.lock()
        invocations.append(remoteArguments)
        let response = responses.count > 1 ? responses.removeFirst() : (responses.first ?? Response())
        lock.unlock()

        if response.delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(response.delay * 1_000_000_000))
        }
        if let error = response.error { throw error }
        return RemoteCommandResult(
            exitCode: response.exitCode,
            standardOutput: response.stdout,
            standardError: response.stderr,
            duration: 0.01
        )
    }
}
