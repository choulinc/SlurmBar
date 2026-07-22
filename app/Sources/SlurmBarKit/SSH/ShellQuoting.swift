import Foundation

/// POSIX shell quoting for the *remote* command line.
///
/// `ssh host cmd args...` concatenates its arguments with spaces and hands the result to the
/// remote user's login shell. That shell — not `ssh` — does word splitting and expansion, so
/// every argument must be quoted before it goes over the wire, even though the local side uses
/// `Process` with an argv array and never invokes a local shell.
public enum ShellQuoting {
    /// Characters that are safe unquoted in every POSIX shell.
    private static let safeCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:=@,+"
    )

    /// Single-quote a value so the remote shell treats it as one literal word.
    ///
    /// Single quotes suppress every form of expansion. The only character that cannot appear
    /// inside them is `'` itself, which is emitted as `'\''` — close, escaped quote, reopen.
    public static func quote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.unicodeScalars.allSatisfy({ safeCharacters.contains(Character($0)) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote and join an argv into a single remote command string.
    ///
    /// Uses ``quoteRemotePath(_:)`` for every element, so a leading `~/` still expands on the
    /// remote side. Quoting the tilde is the difference between
    /// `python3 ~/.local/share/slurmbar/slurmbar-agent.pyz` working and the remote Python
    /// trying to open a literal `$HOME/~/.local/share/...`.
    ///
    /// This is safe for non-path arguments: `quoteRemotePath` only behaves differently from
    /// `quote` when a value begins with `~`, and nothing SlurmBar sends (subcommands, flags,
    /// validated job ids) legitimately starts with one.
    public static func join(_ arguments: [String]) -> String {
        arguments.map(quoteRemotePath).joined(separator: " ")
    }

    /// Expand a leading `~/` locally-written path into a remote-safe form.
    ///
    /// `~` must stay *outside* the quotes or the remote shell will not expand it, so the tilde
    /// prefix is emitted bare and only the remainder is quoted.
    public static func quoteRemotePath(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            return rest.isEmpty ? "~/" : "~/" + quote(rest)
        }
        return quote(path)
    }
}
