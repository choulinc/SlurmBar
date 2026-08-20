import AppKit
import Foundation
import SlurmBarKit

/// Opens a short-lived `.command` file in Terminal so OpenSSH owns the password/OTP UI.
/// The file contains only public connection metadata (SSH alias and options), never credentials.
enum InteractiveSSHLoginLauncher {
    static func open(profile: ClusterProfile) throws {
        let script = try InteractiveSSHLogin.terminalScript(profile: profile)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlurmBar-SSH-Login", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let url = directory.appendingPathComponent(
            "Authenticate-\(profile.id.uuidString).command",
            isDirectory: false
        )
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)

        guard NSWorkspace.shared.open(url) else {
            throw LaunchError.couldNotOpenTerminal
        }
    }

    enum LaunchError: LocalizedError {
        case couldNotOpenTerminal

        var errorDescription: String? {
            "macOS could not open Terminal. Open Terminal yourself and run the SSH login command shown in Settings."
        }
    }
}
