import Foundation

/// Builds and runs `slurmbar-agent` invocations over a ``RemoteCommandRunner``.
///
/// This is the only place that knows the agent's command line. Every value that becomes an
/// argument is either a constant or has been validated first — job ids in particular go through
/// ``JobIDValidator`` before they can reach `cancel` or `logs`.
public struct AgentClient: Sendable {
    private let runner: RemoteCommandRunner
    private let profile: ClusterProfile
    private let decoder: ProtocolDecoder

    public init(runner: RemoteCommandRunner, profile: ClusterProfile, decoder: ProtocolDecoder = ProtocolDecoder()) {
        self.runner = runner
        self.profile = profile
        self.decoder = decoder
    }

    /// Convenience factory that wires up the real SSH runner for a profile.
    public static func live(profile: ClusterProfile) -> AgentClient {
        AgentClient(
            runner: SSHCommandRunner(
                alias: profile.sshAlias,
                username: profile.username.isEmpty ? nil : profile.username,
                connectTimeout: profile.connectTimeoutSeconds
            ),
            profile: profile
        )
    }

    private var timeout: TimeInterval { TimeInterval(profile.timeoutSeconds) }

    // MARK: - Commands

    public func snapshot() async throws -> Snapshot {
        var arguments = profile.agentCommand + ["snapshot", "--json"]
        arguments += ["--history-hours", String(max(0, profile.historyHours))]
        if !profile.slurmUser.isEmpty {
            arguments += ["--user", profile.slurmUser]
        }
        if !profile.progressDirectory.isEmpty {
            arguments += ["--progress-dir", profile.progressDirectory]
        }
        let data = try await execute(arguments)
        return try mapProtocol { try decoder.decodeSnapshot(from: data) }
    }

    public func doctor() async throws -> DoctorReport {
        var arguments = profile.agentCommand + ["doctor", "--json"]
        if !profile.progressDirectory.isEmpty {
            arguments += ["--progress-dir", profile.progressDirectory]
        }
        if !profile.slurmUser.isEmpty {
            arguments += ["--user", profile.slurmUser]
        }
        let data = try await execute(arguments)
        return try mapProtocol { try decoder.decodeDoctorReport(from: data) }
    }

    public func jobDetail(jobID: String) async throws -> JobDetailResponse {
        let validated = try JobIDValidator.validate(jobID)
        var arguments = profile.agentCommand + ["job", "--json", "--job-id", validated]
        if !profile.progressDirectory.isEmpty {
            arguments += ["--progress-dir", profile.progressDirectory]
        }
        let data = try await execute(arguments)
        return try mapProtocol { try decoder.decodeJobDetail(from: data) }
    }

    /// Reads a bounded tail. Only ever called because the user opened a job's logs.
    public func logs(
        jobID: String,
        stream: LogStream,
        lines: Int = 200,
        knownPath: String? = nil
    ) async throws -> LogTail {
        let validated = try JobIDValidator.validate(jobID)
        let boundedLines = min(max(lines, 1), 2000)
        var arguments = profile.agentCommand + [
            "logs", "--json",
            "--job-id", validated,
            "--stream", stream.rawValue,
            "--lines", String(boundedLines),
        ]
        if let knownPath, !knownPath.isEmpty {
            arguments += ["--path", knownPath]
        }
        let data = try await execute(arguments, timeoutOverride: max(timeout, 20))
        return try mapProtocol { try decoder.decodeLogTail(from: data) }
    }

    /// Cancels a job. Destructive: the UI must have obtained explicit confirmation first, and
    /// `--confirm` is what the agent requires before it will call `scancel` at all.
    public func cancel(jobID: String) async throws -> CancelResult {
        let validated = try JobIDValidator.validate(jobID)
        let arguments = profile.agentCommand + ["cancel", "--json", "--job-id", validated, "--confirm"]
        let data = try await execute(arguments, timeoutOverride: max(timeout, 20))
        return try mapProtocol { try decoder.decodeCancelResult(from: data) }
    }

    // MARK: - Plumbing

    private func execute(_ arguments: [String], timeoutOverride: TimeInterval? = nil) async throws -> Data {
        let result: RemoteCommandResult
        do {
            result = try await runner.run(
                remoteArguments: arguments,
                timeout: timeoutOverride ?? timeout
            )
        } catch let failure as SSHFailure {
            throw failure
        } catch is CancellationError {
            throw SSHFailure.cancelled
        }

        if result.succeeded {
            return result.standardOutput
        }

        // A nonzero exit with a JSON body is the agent reporting a structured failure; anything
        // else is an SSH-layer or shell-layer problem and gets categorized from stderr.
        if !result.standardOutput.isEmpty,
           let payload = try? ProtocolDecoder.makeJSONDecoder()
               .decode(AgentErrorPayload.self, from: result.standardOutput)
        {
            throw SSHFailure.protocolFailure(
                .agentError(code: payload.error.code, message: payload.error.message)
            )
        }

        throw SSHErrorClassifier.classify(
            exitCode: result.exitCode,
            stderr: result.standardError,
            alias: profile.sshAlias,
            timeout: timeoutOverride ?? timeout
        )
    }

    private func mapProtocol<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ProtocolError {
            throw SSHFailure.protocolFailure(error)
        }
    }

    /// The command a user can paste into Terminal to reproduce a refresh.
    public func debugCommandLine() -> String {
        let runner = SSHCommandRunner(
            alias: profile.sshAlias,
            username: profile.username.isEmpty ? nil : profile.username,
            connectTimeout: profile.connectTimeoutSeconds
        )
        let remote = ShellQuoting.join(profile.agentCommand + ["snapshot", "--json"])
        return runner.displayCommand(remoteCommand: remote)
    }
}

/// Job id validation, mirroring the agent's rules.
///
/// Validating on both sides is intentional: the app must not send a malformed id, and the agent
/// must not trust that the app didn't.
public enum JobIDValidator {
    public static func isValid(_ value: String) -> Bool {
        (try? validate(value)) != nil
    }

    @discardableResult
    public static func validate(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 40 else {
            throw SSHFailure.protocolFailure(.agentError(
                code: "INVALID_JOB_ID",
                message: "“\(SanitizedText.clean(value, limit: 40))” is not a valid job id."
            ))
        }
        // digits, optionally followed by _digits for an array task. Nothing else.
        let parts = trimmed.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            throw SSHFailure.protocolFailure(.agentError(
                code: "INVALID_JOB_ID",
                message: "“\(SanitizedText.clean(value, limit: 40))” is not a valid job id."
            ))
        }
        return trimmed
    }
}
