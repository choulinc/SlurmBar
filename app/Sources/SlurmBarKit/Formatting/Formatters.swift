import Foundation

/// Display formatting. Pure functions so every rule is directly testable.
///
/// The recurring principle: an unavailable value renders as `N/A`, never as `0`, `--`, or a
/// plausible-looking guess.
public enum Formatters {
    public static let notAvailable = "N/A"

    // MARK: - Durations

    /// Compact duration: `2d 4h`, `3h 12m`, `8m 20s`, `45s`.
    ///
    /// Two units at most: a menu bar row has no space for `2d 4h 17m 33s`, and the extra
    /// precision is meaningless for a job that has been running for days.
    public static func duration(seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return notAvailable }
        if seconds < 60 { return "\(seconds)s" }

        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return remainingSeconds > 0 ? "\(minutes)m \(remainingSeconds)s" : "\(minutes)m"
    }

    /// `HH:MM:SS`, for places where alignment matters more than brevity.
    public static func clockDuration(seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return notAvailable }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if days > 0 {
            return String(format: "%dd %02d:%02d:%02d", days, hours, minutes, secs)
        }
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    /// An ETA, always marked as approximate because it always is.
    public static func eta(seconds: Int?) -> String {
        guard let seconds, seconds >= 0 else { return notAvailable }
        if seconds < 60 { return "~\(seconds)s left" }
        return "~\(duration(seconds: seconds)) left"
    }

    /// Elapsed against a limit: `2h 20m / 24h`.
    public static func elapsedWithLimit(elapsed: Int?, limit: Int?) -> String {
        let left = duration(seconds: elapsed)
        guard let limit else { return left }
        return "\(left) / \(duration(seconds: limit))"
    }

    // MARK: - Bytes

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory  // powers of 1024, which is what Slurm reports
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    public static func bytes(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return notAvailable }
        return byteFormatter.string(fromByteCount: value)
    }

    /// Memory with its semantics attached, e.g. `112.6 GB peak / 256 GB per node`.
    ///
    /// This is the function that keeps the app honest about memory: a bare number would imply a
    /// precision and a meaning that Slurm's accounting does not have.
    public static func memory(_ resources: JobResources) -> String {
        let used = resources.memoryUsedBytes
        let limit = resources.memoryLimitBytes

        switch (used, limit) {
        case (nil, nil):
            return notAvailable
        case (let used?, nil):
            return qualified(bytes(used), resources.memorySemantics)
        case (nil, let limit?):
            return "— / " + qualified(bytes(limit), resources.memoryLimitSemantics)
        case (let used?, let limit?):
            return qualified(bytes(used), resources.memorySemantics)
                + " / " + qualified(bytes(limit), resources.memoryLimitSemantics)
        }
    }

    private static func qualified(_ text: String, _ semantics: MemorySemantics) -> String {
        let label = semantics.shortLabel
        return label.isEmpty ? text : "\(text) \(label)"
    }

    // MARK: - Numbers

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// Counter values: `375`, `4,820`, `1.5` when genuinely fractional.
    public static func count(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return integerFormatter.string(from: NSNumber(value: Int64(value))) ?? String(Int64(value))
        }
        return String(format: "%.2f", value)
    }

    public static func percent(_ value: Double?, decimals: Int = 0) -> String {
        guard let value, value.isFinite else { return notAvailable }
        let clamped = min(100, max(0, value))
        return String(format: "%.\(decimals)f%%", clamped)
    }

    public static func utilization(_ value: Double?) -> String {
        guard let value, value.isFinite else { return notAvailable }
        return String(format: "%.0f%%", min(100, max(0, value)))
    }

    // MARK: - Dates

    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    public static func timeOnly(_ date: Date?) -> String {
        guard let date else { return notAvailable }
        return timeOnlyFormatter.string(from: date)
    }

    public static func dateTime(_ date: Date?) -> String {
        guard let date else { return notAvailable }
        return dateTimeFormatter.string(from: date)
    }

    /// "just now", "2m ago", "3h ago".
    public static func relativeTime(from date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 5 { return "just now" }
        if interval < 60 { return "\(Int(interval))s ago" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    public static func relativeTime(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return notAvailable }
        return relativeTime(from: date, now: now)
    }

    /// How long a pending job has been waiting.
    public static func pendingDuration(submitTime: Date?, now: Date = Date()) -> String {
        guard let submitTime else { return notAvailable }
        return duration(seconds: max(0, Int(now.timeIntervalSince(submitTime))))
    }

    // MARK: - Exit status

    /// `0 (success)`, `1`, `killed by signal 9`.
    public static func exitStatus(exitCode: Int?, signal: Int?) -> String {
        if let signal, signal != 0 {
            return "killed by signal \(signal)"
        }
        guard let exitCode else { return notAvailable }
        return exitCode == 0 ? "0 (success)" : String(exitCode)
    }
}
