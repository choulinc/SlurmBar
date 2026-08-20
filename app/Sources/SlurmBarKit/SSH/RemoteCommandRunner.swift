import Foundation

/// One remote invocation's result.
public struct RemoteCommandResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: String
    public let duration: TimeInterval

    public init(exitCode: Int32, standardOutput: Data, standardError: String, duration: TimeInterval) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.duration = duration
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// Abstraction over "run this argv on the cluster".
///
/// The app depends on this rather than on `Process` so the whole monitor, polling and
/// notification stack can be tested with a stub that returns fixture JSON.
public protocol RemoteCommandRunner: Sendable {
    /// - Parameters:
    ///   - remoteArguments: the remote argv. The implementation is responsible for quoting.
    ///   - timeout: wall-clock limit; exceeding it must throw ``SSHFailure/timedOut(seconds:)``.
    func run(remoteArguments: [String], timeout: TimeInterval) async throws -> RemoteCommandResult
}

/// A remote transport that can stream bytes to the command's standard input.
///
/// Kept separate from ``RemoteCommandRunner`` so ordinary polling stubs and file-backed demo
/// runners do not need an upload implementation. The live SSH runner uses it to install the
/// bundled agent without exposing the archive in argv or writing an intermediate local file.
public protocol RemoteInputCommandRunner: RemoteCommandRunner {
    func run(
        remoteArguments: [String],
        standardInput: Data,
        timeout: TimeInterval
    ) async throws -> RemoteCommandResult
}

/// Runs remote commands through the system OpenSSH client.
///
/// Deliberate constraints:
/// * `/usr/bin/ssh` only — no embedded SSH library, so the user's existing config, agent,
///   `ProxyJump` and `ControlMaster` all work exactly as they do in Terminal;
/// * `BatchMode=yes` — SlurmBar can never produce a password prompt;
/// * host key checking is left at OpenSSH's default — SlurmBar never accepts an unknown key;
/// * output is capped and the process is killed on timeout.
public struct SSHCommandRunner: RemoteInputCommandRunner {
    public static let sshPath = "/usr/bin/ssh"

    /// Hard cap on captured stdout, matching the decoder's limit.
    public static let maxOutputBytes = 16 * 1024 * 1024

    private let alias: String
    private let username: String?
    private let connectTimeout: Int
    private let extraOptions: [String]
    private let executablePath: String

    public init(
        alias: String,
        username: String? = nil,
        connectTimeout: Int = 8,
        extraOptions: [String] = [],
        executablePath: String = SSHCommandRunner.sshPath
    ) {
        self.alias = alias
        self.username = username
        self.connectTimeout = max(1, connectTimeout)
        self.extraOptions = extraOptions
        self.executablePath = executablePath
    }

    /// The exact argv handed to `Process`. Exposed so tests and the UI's "copy command" action
    /// show precisely what runs.
    public func sshArguments(remoteCommand: String) -> [String] {
        var arguments: [String] = [
            // Never prompt: no password dialog, no host-key confirmation, ever.
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(connectTimeout)",
            // Quieter stderr, but real errors still come through.
            "-o", "LogLevel=ERROR",
            // No TTY: the remote side is a one-shot command, not a shell session.
            "-T",
        ]
        arguments.append(contentsOf: extraOptions)
        if let username, !username.isEmpty {
            arguments.append(contentsOf: ["-l", username])
        }
        arguments.append(alias)
        arguments.append(remoteCommand)
        return arguments
    }

    /// A copy-pasteable equivalent of what SlurmBar runs, for the UI and for bug reports.
    public func displayCommand(remoteCommand: String) -> String {
        ([executablePath] + sshArguments(remoteCommand: remoteCommand))
            .map(ShellQuoting.quote)
            .joined(separator: " ")
    }

    public func run(remoteArguments: [String], timeout: TimeInterval) async throws -> RemoteCommandResult {
        try await run(remoteArguments: remoteArguments, standardInput: nil, timeout: timeout)
    }

    public func run(
        remoteArguments: [String],
        standardInput: Data,
        timeout: TimeInterval
    ) async throws -> RemoteCommandResult {
        try await run(remoteArguments: remoteArguments, standardInput: Optional(standardInput), timeout: timeout)
    }

    private func run(
        remoteArguments: [String],
        standardInput: Data?,
        timeout: TimeInterval
    ) async throws -> RemoteCommandResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw SSHFailure.sshUnavailable(path: executablePath)
        }
        let remoteCommand = ShellQuoting.join(remoteArguments)
        return try await ProcessRunner.run(
            executable: executablePath,
            arguments: sshArguments(remoteCommand: remoteCommand),
            timeout: timeout,
            maxOutputBytes: Self.maxOutputBytes,
            standardInput: standardInput
        )
    }
}
