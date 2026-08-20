import Foundation

/// Installs the agent bundled inside SlurmBar into the connected user's remote home directory.
///
/// The operation deliberately mirrors `scripts/install-agent.sh`: it uses the existing OpenSSH
/// configuration in BatchMode, writes only below `$HOME`, preserves one backup, validates the
/// uploaded zipapp before replacing the active copy, and finishes with the normal doctor check.
public struct RemoteAgentInstaller: Sendable {
    public static let maximumAgentBytes = 8 * 1024 * 1024

    private let profile: ClusterProfile
    private let runner: any RemoteInputCommandRunner

    public init(profile: ClusterProfile, runner: any RemoteInputCommandRunner) {
        self.profile = profile
        self.runner = runner
    }

    public static func live(profile: ClusterProfile) -> RemoteAgentInstaller {
        RemoteAgentInstaller(
            profile: profile,
            runner: SSHCommandRunner(
                alias: profile.sshAlias,
                username: profile.username.isEmpty ? nil : profile.username,
                connectTimeout: profile.connectTimeoutSeconds
            )
        )
    }

    /// Uploads, validates and activates `agentData`, then returns a structured health report.
    public func install(agentData: Data) async throws -> DoctorReport {
        guard profile.isValid else {
            throw SSHFailure.launchFailed(detail: profile.validationErrors.joined(separator: " "))
        }
        guard !agentData.isEmpty, agentData.count <= Self.maximumAgentBytes else {
            throw SSHFailure.launchFailed(detail: "The bundled remote agent is missing or unexpectedly large.")
        }

        let timeout = TimeInterval(max(profile.timeoutSeconds, 30))
        let result = try await runner.run(
            remoteArguments: ["sh", "-c", Self.installScript],
            standardInput: agentData,
            timeout: timeout
        )
        guard result.succeeded else {
            throw SSHErrorClassifier.classify(
                exitCode: result.exitCode,
                stderr: result.standardError,
                alias: profile.sshAlias,
                timeout: timeout
            )
        }

        let remoteSizeText = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Int(remoteSizeText) == agentData.count else {
            throw SSHFailure.remoteCommandFailed(
                exitCode: 1,
                stderr: "The uploaded agent size did not match the bundled copy."
            )
        }

        var installedProfile = profile
        installedProfile.agentCommand = ClusterProfile.defaultAgentCommand
        return try await AgentClient(runner: runner, profile: installedProfile).doctor()
    }

    /// A single remote shell transaction makes activation atomic: a failed transfer or invalid
    /// archive leaves the previous agent untouched. Every path is constant and below `$HOME`.
    static let installScript = #"""
    set -eu
    command -v python3 >/dev/null 2>&1 || {
        echo 'python3: command not found' >&2
        exit 127
    }

    install_dir="$HOME/.local/share/slurmbar"
    bin_dir="$HOME/.local/bin"
    target="$install_dir/slurmbar-agent.pyz"
    launcher="$bin_dir/slurmbar-agent"

    umask 077
    if [ -L "$install_dir" ] || [ -L "$bin_dir" ]; then
        echo 'refusing to install through a symbolic-link directory' >&2
        exit 1
    fi
    mkdir -p "$install_dir" "$bin_dir"
    chmod 0700 "$install_dir"
    incoming="$(mktemp "$install_dir/.slurmbar-agent.pyz.incoming.XXXXXX")"
    launcher_tmp="$(mktemp "$bin_dir/.slurmbar-agent.incoming.XXXXXX")"
    trap 'rm -f "$incoming" "$launcher_tmp"' EXIT HUP INT TERM
    cat > "$incoming"
    chmod 0755 "$incoming"
    python3 "$incoming" --version >/dev/null

    if [ -L "$target" ] || [ -L "$launcher" ]; then
        echo 'refusing to replace a symbolic-link agent installation' >&2
        exit 1
    fi
    if [ -f "$target" ]; then
        cp -p "$target" "$target.bak"
    fi
    mv -f "$incoming" "$target"

    printf '%s\n' \
        '#!/bin/sh' \
        '# Installed by SlurmBar. Safe to delete.' \
        'exec python3 "$HOME/.local/share/slurmbar/slurmbar-agent.pyz" "$@"' \
        > "$launcher_tmp"
    chmod 0755 "$launcher_tmp"
    mv -f "$launcher_tmp" "$launcher"

    wc -c < "$target" | tr -d ' '
    """#
}
