import Foundation

/// One configured cluster.
///
/// Note what is *not* here: no host name, no user credentials, no key path, no port. Those all
/// live in the user's `~/.ssh/config` under ``sshAlias``, which is the whole point — SlurmBar
/// stores a reference to the user's existing SSH setup, never a copy of it.
public struct ClusterProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Shown in the UI. Free text.
    public var displayName: String
    /// A `Host` entry in `~/.ssh/config`, or any host string `ssh` accepts.
    public var sshAlias: String
    /// The remote command that runs the agent, as an argv. Defaults to the documented zipapp path.
    public var agentCommand: [String]
    /// Overrides the SSH config's `User`. Usually empty.
    public var username: String
    /// Overrides the agent's default progress state directory. Usually empty.
    public var progressDirectory: String
    /// Slurm user to query. Empty means "whoever the SSH session logs in as".
    public var slurmUser: String
    /// Base polling interval in seconds; the adaptive policy scales it.
    public var pollIntervalSeconds: Int
    /// How far back to ask accounting for finished jobs.
    public var historyHours: Int
    /// Per-refresh wall-clock limit.
    public var timeoutSeconds: Int
    /// `ConnectTimeout` handed to `ssh`.
    public var connectTimeoutSeconds: Int
    public var isEnabled: Bool

    public static let defaultAgentCommand = [
        "python3", "~/.local/share/slurmbar/slurmbar-agent.pyz",
    ]

    public init(
        id: UUID = UUID(),
        displayName: String = "",
        sshAlias: String = "",
        agentCommand: [String] = ClusterProfile.defaultAgentCommand,
        username: String = "",
        progressDirectory: String = "",
        slurmUser: String = "",
        pollIntervalSeconds: Int = 30,
        historyHours: Int = 24,
        timeoutSeconds: Int = 12,
        connectTimeoutSeconds: Int = 8,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.sshAlias = sshAlias
        self.agentCommand = agentCommand
        self.username = username
        self.progressDirectory = progressDirectory
        self.slurmUser = slurmUser
        self.pollIntervalSeconds = pollIntervalSeconds
        self.historyHours = historyHours
        self.timeoutSeconds = timeoutSeconds
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.isEnabled = isEnabled
    }

    /// Name for the UI; falls back to the alias so a half-filled profile is still identifiable.
    public var effectiveName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? sshAlias : trimmed
    }

    public var agentCommandString: String {
        agentCommand.map(ShellQuoting.quoteRemotePath).joined(separator: " ")
    }

    /// Parse a user-typed command line back into an argv, honouring simple quoting.
    public static func parseAgentCommand(_ text: String) -> [String] {
        let parsed = CommandLineTokenizer.tokenize(text)
        return parsed.isEmpty ? defaultAgentCommand : parsed
    }

    /// Problems that must be fixed before the profile can be used.
    public var validationErrors: [String] {
        var errors: [String] = []
        if sshAlias.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("An SSH host or alias is required.")
        } else if sshAlias.contains(where: { $0.isWhitespace }) {
            errors.append("The SSH alias must not contain spaces.")
        } else if sshAlias.hasPrefix("-") {
            errors.append("The SSH alias must not begin with a dash.")
        }
        if agentCommand.isEmpty {
            errors.append("A remote agent command is required.")
        }
        if pollIntervalSeconds < 5 {
            errors.append("The polling interval must be at least 5 seconds.")
        }
        if timeoutSeconds < 3 {
            errors.append("The timeout must be at least 3 seconds.")
        }
        return errors
    }

    public var isValid: Bool { validationErrors.isEmpty }
}

/// Splits a user-typed command line into an argv, respecting quotes and backslash escapes.
///
/// This runs on text the *user* typed into Settings, not on remote input. It exists so that a
/// command like `module load python && python3 ~/agent.pyz` can be entered naturally; the parts
/// are re-quoted by ``ShellQuoting`` before they cross the wire.
public enum CommandLineTokenizer {
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?
        var escaped = false

        for character in text {
            if escaped {
                current.append(character)
                hasCurrent = true
                escaped = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                hasCurrent = true
                continue
            }
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                hasCurrent = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasCurrent = true
                continue
            }
            if character.isWhitespace {
                if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
                continue
            }
            current.append(character)
            hasCurrent = true
        }
        if hasCurrent {
            tokens.append(current)
        }
        return tokens
    }
}
