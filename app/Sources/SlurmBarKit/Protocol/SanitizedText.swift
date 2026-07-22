import Foundation

/// Cleans text that came from a remote machine before it reaches the UI.
///
/// Job names, log lines and error messages are attacker-influenced in the general case (anyone
/// who can submit a job on the cluster picks the job name). Escape sequences and control
/// characters are removed so they cannot reposition, recolour or hide UI text, and lengths are
/// bounded so one pathological value cannot blow up layout.
public enum SanitizedText {
    /// ANSI CSI/OSC escape sequences.
    private static let ansiPattern = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"
    private static let ansiRegex = try? NSRegularExpression(pattern: ansiPattern)

    public static func clean(_ input: String, limit: Int = 500) -> String {
        var text = input

        if text.contains("\u{1B}"), let regex = ansiRegex {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }

        // Keep tab; drop every other C0 control character, DEL, and the Unicode
        // bidirectional-override codepoints used for text-spoofing.
        text = String(text.unicodeScalars.filter { scalar in
            if scalar == "\t" { return true }
            if scalar.value < 0x20 { return false }
            if scalar.value == 0x7F { return false }
            if (0x80...0x9F).contains(scalar.value) { return false }
            if (0x202A...0x202E).contains(scalar.value) { return false }
            if (0x2066...0x2069).contains(scalar.value) { return false }
            return true
        })

        if text.count > limit {
            text = String(text.prefix(limit)) + "…"
        }
        return text
    }
}
