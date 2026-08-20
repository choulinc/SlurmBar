import Foundation

/// A categorized SSH or agent failure.
///
/// The whole point of this type is that the UI never has to say "Unknown error": every failure
/// mode a user actually hits on a cluster has its own case, its own explanation, and its own
/// suggested fix.
public enum SSHFailure: Error, Hashable, Sendable {
    case aliasNotFound(alias: String)
    case hostUnreachable(detail: String)
    case connectionRefused(detail: String)
    case networkUnreachable(detail: String)
    case authenticationFailed(detail: String)
    /// The cluster demands interactive authentication (OTP/2FA/password), which BatchMode
    /// cannot satisfy. Distinct from a plain auth failure because the fix is different.
    case interactiveAuthRequired(detail: String)
    case hostKeyUnknown(detail: String)
    case hostKeyMismatch(detail: String)
    case permissionDenied(detail: String)
    case timedOut(seconds: TimeInterval)
    case cancelled
    case remoteAgentMissing(detail: String)
    case remotePythonMissing(detail: String)
    case remoteCommandFailed(exitCode: Int32, stderr: String)
    case sshUnavailable(path: String)
    case launchFailed(detail: String)
    case protocolFailure(ProtocolError)

    // MARK: - Presentation

    public var title: String {
        switch self {
        case .aliasNotFound: return "SSH host not found"
        case .hostUnreachable, .networkUnreachable: return "Cluster unreachable"
        case .connectionRefused: return "Connection refused"
        case .authenticationFailed: return "Authentication failed"
        case .interactiveAuthRequired: return "Interactive login required"
        case .hostKeyUnknown: return "Unknown host key"
        case .hostKeyMismatch: return "Host key changed"
        case .permissionDenied: return "Permission denied"
        case .timedOut: return "Connection timed out"
        case .cancelled: return "Refresh cancelled"
        case .remoteAgentMissing: return "Agent not installed"
        case .remotePythonMissing: return "Python not found on the cluster"
        case .remoteCommandFailed: return "Remote command failed"
        case .sshUnavailable: return "ssh not available"
        case .launchFailed: return "Could not start ssh"
        case .protocolFailure(let error): return error.errorDescription ?? "Protocol error"
        }
    }

    public var message: String {
        switch self {
        case .aliasNotFound(let alias):
            return "ssh could not resolve the host “\(alias)”."
        case .hostUnreachable(let detail), .networkUnreachable(let detail):
            return detail.isEmpty ? "The cluster did not respond." : detail
        case .connectionRefused(let detail):
            return detail.isEmpty ? "The cluster refused the connection." : detail
        case .authenticationFailed(let detail):
            return detail.isEmpty ? "The cluster rejected the SSH credentials." : detail
        case .interactiveAuthRequired(let detail):
            return detail.isEmpty
                ? "This cluster requires interactive authentication, which SlurmBar cannot perform."
                : detail
        case .hostKeyUnknown(let detail):
            return detail.isEmpty ? "The host key for this cluster is not in known_hosts." : detail
        case .hostKeyMismatch(let detail):
            return detail.isEmpty
                ? "The host key does not match the one stored in known_hosts."
                : detail
        case .permissionDenied(let detail):
            return detail
        case .timedOut(let seconds):
            return "No response within \(Int(seconds)) seconds."
        case .cancelled:
            return "The refresh was cancelled."
        case .remoteAgentMissing(let detail):
            return detail.isEmpty ? "The slurmbar-agent was not found on the cluster." : detail
        case .remotePythonMissing(let detail):
            return detail.isEmpty ? "python3 was not found on the login node." : detail
        case .remoteCommandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "The agent exited with status \(code)." : trimmed
        case .sshUnavailable(let path):
            return "\(path) is missing. SlurmBar uses the system OpenSSH client."
        case .launchFailed(let detail):
            return detail
        case .protocolFailure(let error):
            return error.errorDescription ?? "The agent response could not be read."
        }
    }

    /// The concrete next step. Shown under the error in the popover.
    public var recoverySuggestion: String? {
        switch self {
        case .aliasNotFound(let alias):
            return "Add a Host block for “\(alias)” to ~/.ssh/config, or correct the alias in Settings."
        case .hostUnreachable, .networkUnreachable, .connectionRefused:
            return "Check your network. If the cluster requires a VPN, connect to it and retry."
        case .authenticationFailed:
            return "SlurmBar never prompts for a password. Make sure your key is loaded "
                + "(ssh-add -l) and that ssh <alias> works in Terminal."
        case .interactiveAuthRequired:
            return "SlurmBar runs ssh with BatchMode=yes and can never answer a password or "
                + "one-time-code prompt. Open Terminal, run `ssh <alias>` and complete the "
                + "login there. With ControlMaster/ControlPersist in your ~/.ssh/config, "
                + "SlurmBar then reuses that connection. Raising ControlPersist keeps it alive "
                + "longer between sessions."
        case .hostKeyUnknown:
            return "Run `ssh <alias>` once in Terminal and verify the fingerprint. SlurmBar will "
                + "not accept an unknown host key on your behalf."
        case .hostKeyMismatch:
            return "This can indicate a man-in-the-middle attack, or simply a rebuilt login node. "
                + "Verify the new fingerprint out-of-band before changing known_hosts."
        case .timedOut:
            return "Increase the timeout in Settings, or check whether the login node is under load."
        case .remoteAgentMissing:
            return "Open the cluster in Settings and click Install or Update Agent, or correct "
                + "the agent command if you use a custom installation."
        case .remotePythonMissing:
            return "Set the agent command in Settings to an absolute Python path, or load a "
                + "Python module in the remote command."
        case .permissionDenied:
            return "Check the permissions of the agent and of the progress directory."
        case .sshUnavailable:
            return "Reinstall the macOS command line tools."
        default:
            return nil
        }
    }

    /// SF Symbol, verified to exist on macOS 14.
    public var symbolName: String {
        switch self {
        case .hostKeyUnknown, .hostKeyMismatch, .authenticationFailed, .permissionDenied,
             .interactiveAuthRequired:
            return "lock.trianglebadge.exclamationmark"
        case .hostUnreachable, .networkUnreachable, .connectionRefused, .timedOut:
            return "wifi.slash"
        case .remoteAgentMissing, .remotePythonMissing:
            return "shippingbox"
        case .cancelled:
            return "xmark.circle"
        default:
            return "exclamationmark.triangle"
        }
    }

    /// True when retrying unattended is reasonable. A bad host key is not: it needs a human.
    public var isTransient: Bool {
        switch self {
        case .hostUnreachable, .networkUnreachable, .connectionRefused, .timedOut, .cancelled:
            return true
        default:
            return false
        }
    }
}

/// Turns OpenSSH's stderr into a categorized failure.
///
/// Matching on message text is unavoidable — OpenSSH's exit status is 255 for every connection
/// problem — so the patterns are kept narrow, ordered most-specific first, and every one of
/// them is covered by a test using real OpenSSH wording.
public enum SSHErrorClassifier {
    public static func classify(
        exitCode: Int32,
        stderr: String,
        alias: String,
        timeout: TimeInterval
    ) -> SSHFailure {
        let text = stderr.lowercased()

        // Host key problems first: they are security-relevant and must never be misreported.
        if text.contains("host key verification failed")
            || text.contains("no matching host key")
            || text.contains("host key for") && text.contains("has changed")
        {
            if text.contains("remote host identification has changed") || text.contains("has changed") {
                return .hostKeyMismatch(detail: firstMeaningfulLine(stderr))
            }
            return .hostKeyUnknown(detail: firstMeaningfulLine(stderr))
        }
        if text.contains("remote host identification has changed") {
            return .hostKeyMismatch(detail: firstMeaningfulLine(stderr))
        }
        if text.contains("no rsa host key is known")
            || text.contains("key fingerprint is")
            || (text.contains("authenticity of host") && text.contains("can't be established"))
        {
            return .hostKeyUnknown(detail: firstMeaningfulLine(stderr))
        }

        // Name resolution / alias problems.
        if text.contains("could not resolve hostname")
            || text.contains("name or service not known")
            || text.contains("nodename nor servname provided")
            || text.contains("hostname contains invalid characters")
        {
            return .aliasNotFound(alias: alias)
        }

        // Reachability.
        if text.contains("connection timed out") || text.contains("operation timed out") {
            return .hostUnreachable(detail: firstMeaningfulLine(stderr))
        }
        if text.contains("connection refused") {
            return .connectionRefused(detail: firstMeaningfulLine(stderr))
        }
        if text.contains("network is unreachable") || text.contains("no route to host") {
            return .networkUnreachable(detail: firstMeaningfulLine(stderr))
        }
        if text.contains("connection closed by") || text.contains("connection reset by peer") {
            return .hostUnreachable(detail: firstMeaningfulLine(stderr))
        }

        // BatchMode turns an OTP/password prompt into a keyboard-interactive rejection. This
        // is not a broken key, so it must not send the user chasing ssh-add.
        if text.contains("keyboard-interactive")
            || text.contains("permission denied (password")
            || text.contains("(gssapi-with-mic,password")
        {
            return .interactiveAuthRequired(detail: firstMeaningfulLine(stderr))
        }

        // Authentication. BatchMode turns an interactive prompt into this message.
        if text.contains("permission denied (publickey")
            || text.contains("permission denied, please try again")
            || text.contains("too many authentication failures")
            || text.contains("no supported authentication methods")
            || text.contains("host key verification")
        {
            return .authenticationFailed(detail: firstMeaningfulLine(stderr))
        }
        if text.contains("permission denied") && exitCode == 255 {
            return .authenticationFailed(detail: firstMeaningfulLine(stderr))
        }

        // Remote-side problems: ssh connected, the command did not work.
        if text.contains("python3: command not found")
            || text.contains("python: command not found")
            || (text.contains("python3") && text.contains("not found"))
        {
            return .remotePythonMissing(detail: firstMeaningfulLine(stderr))
        }
        if text.contains("no such file or directory")
            || text.contains("can't open file")
            || text.contains("cannot find")
        {
            return .remoteAgentMissing(detail: firstMeaningfulLine(stderr))
        }
        if text.contains("permission denied") {
            return .permissionDenied(detail: firstMeaningfulLine(stderr))
        }

        if exitCode == 255 {
            // 255 with nothing recognizable is still an ssh-layer failure, not an agent failure.
            return .hostUnreachable(detail: firstMeaningfulLine(stderr))
        }
        return .remoteCommandFailed(exitCode: exitCode, stderr: SanitizedText.clean(stderr, limit: 1000))
    }

    /// The first line that carries information, skipping OpenSSH's banner noise.
    static func firstMeaningfulLine(_ stderr: String) -> String {
        let ignored = ["warning: permanently added", "pseudo-terminal", "banner"]
        for rawLine in stderr.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lowered = line.lowercased()
            if ignored.contains(where: { lowered.hasPrefix($0) }) { continue }
            return SanitizedText.clean(line, limit: 300)
        }
        return SanitizedText.clean(stderr.trimmingCharacters(in: .whitespacesAndNewlines), limit: 300)
    }
}
