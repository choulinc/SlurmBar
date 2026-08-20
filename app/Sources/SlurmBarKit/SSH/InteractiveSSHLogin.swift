import Foundation

/// Builds the transparent Terminal command used when a cluster requires a password or OTP.
///
/// SlurmBar's background polling always remains `BatchMode=yes`. This command is only shown and
/// run after the user presses Authenticate in Terminal, so OpenSSH can use a real TTY for any
/// site-specific keyboard-interactive flow. No credential ever enters SlurmBar.
public enum InteractiveSSHLogin {
    public static func command(profile: ClusterProfile) throws -> String {
        guard profile.isValid else {
            throw SSHFailure.launchFailed(detail: profile.validationErrors.joined(separator: " "))
        }

        var arguments = [
            SSHCommandRunner.sshPath,
            "-o", "BatchMode=no",
            "-M", "-N", "-f",
        ]
        if !profile.username.isEmpty {
            arguments += ["-l", profile.username]
        }
        arguments.append(profile.sshAlias)
        return arguments.map(ShellQuoting.quote).joined(separator: " ")
    }

    public static func terminalScript(profile: ClusterProfile) throws -> String {
        let command = try command(profile: profile)
        return """
        #!/bin/zsh
        clear
        printf '\\033]0;SlurmBar SSH Authentication\\007'
        printf '%s\\n' 'SlurmBar needs an interactive SSH login.'
        printf '%s\\n\\n' 'Complete the password and/or OTP prompts below.'
        printf '%s\\n\\n' 'SlurmBar never receives or stores what you type in this Terminal window.'
        printf '%s\\n\\n' 'The SSH alias must have ControlMaster and ControlPath configured for reuse.'

        if \(command); then
            printf '\\n%s\\n' 'Authentication succeeded. SlurmBar will retry automatically.'
        else
            status=$?
            printf '\\n%s %d.\\n' 'SSH authentication failed with status' "$status"
            printf '%s\\n' 'Check the message above, then retry from SlurmBar.'
        fi

        printf '\\n%s' 'Press any key to close this window.'
        read -k 1
        printf '\\n'
        """
    }
}
