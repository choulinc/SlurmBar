import Foundation

/// Decides *when* to poll. Deliberately a pure value type with no timers, no state and no
/// clock of its own, so every branch is directly testable.
///
/// The goal is to be a good citizen on a shared login node: a Slurm controller serves the whole
/// cluster, and an editor-refresh-rate menu bar app pointed at `squeue` is a genuine problem.
/// SlurmBar therefore polls slowly by default and speeds up only while the user is actually
/// looking at the popover.
public struct PollingPolicy: Hashable, Sendable {
    /// Interval while the popover is open — the user is watching, so keep it fresh.
    public var foregroundInterval: TimeInterval
    /// Interval while the popover is closed and jobs are active.
    public var backgroundInterval: TimeInterval
    /// Interval when nothing is running or pending: there is very little to learn.
    public var idleInterval: TimeInterval
    /// Multiplier applied per consecutive failure, so an unreachable cluster backs off.
    public var backoffMultiplier: Double
    /// Ceiling for the backed-off interval.
    public var maximumInterval: TimeInterval
    /// Random spread, as a fraction of the interval, so several clusters do not sync up.
    public var jitterFraction: Double

    public init(
        foregroundInterval: TimeInterval = 12,
        backgroundInterval: TimeInterval = 30,
        idleInterval: TimeInterval = 75,
        backoffMultiplier: Double = 2.0,
        maximumInterval: TimeInterval = 600,
        jitterFraction: Double = 0.1
    ) {
        self.foregroundInterval = foregroundInterval
        self.backgroundInterval = backgroundInterval
        self.idleInterval = idleInterval
        self.backoffMultiplier = backoffMultiplier
        self.maximumInterval = maximumInterval
        self.jitterFraction = jitterFraction
    }

    public static let `default` = PollingPolicy()

    /// Scale the defaults from the user's configured base interval.
    ///
    /// The base is the background (popover closed, jobs active) case; foreground and idle are
    /// derived from it so one slider stays meaningful.
    public static func fromBaseInterval(_ seconds: Int) -> PollingPolicy {
        let base = max(5.0, TimeInterval(seconds))
        return PollingPolicy(
            foregroundInterval: max(8, base * 0.4),
            backgroundInterval: base,
            idleInterval: max(base * 2.5, 60),
            backoffMultiplier: 2.0,
            maximumInterval: max(600, base * 20),
            jitterFraction: 0.1
        )
    }

    /// The inputs that determine the next delay.
    public struct Context: Hashable, Sendable {
        public var isPopoverOpen: Bool
        public var hasActiveJobs: Bool
        public var consecutiveFailures: Int
        /// User setting: stop polling entirely when nothing is active.
        public var pauseWhenIdle: Bool
        /// User setting: keep the faster cadence while the popover is open.
        public var refreshWhilePopoverOpen: Bool

        public init(
            isPopoverOpen: Bool = false,
            hasActiveJobs: Bool = false,
            consecutiveFailures: Int = 0,
            pauseWhenIdle: Bool = false,
            refreshWhilePopoverOpen: Bool = true
        ) {
            self.isPopoverOpen = isPopoverOpen
            self.hasActiveJobs = hasActiveJobs
            self.consecutiveFailures = consecutiveFailures
            self.pauseWhenIdle = pauseWhenIdle
            self.refreshWhilePopoverOpen = refreshWhilePopoverOpen
        }
    }

    /// The delay before the next poll, or nil to stop polling until something changes.
    ///
    /// `randomFraction` is injected so tests are deterministic; production passes
    /// `Double.random(in:)`.
    public func nextInterval(
        for context: Context,
        randomFraction: @autoclosure () -> Double = Double.random(in: -1...1)
    ) -> TimeInterval? {
        if context.pauseWhenIdle, !context.hasActiveJobs, !context.isPopoverOpen {
            return nil
        }

        var interval: TimeInterval
        if context.isPopoverOpen, context.refreshWhilePopoverOpen {
            interval = foregroundInterval
        } else if context.hasActiveJobs {
            interval = backgroundInterval
        } else {
            interval = idleInterval
        }

        if context.consecutiveFailures > 0 {
            // An unreachable cluster (VPN down, laptop asleep) must not be hammered.
            let factor = pow(backoffMultiplier, Double(min(context.consecutiveFailures, 8)))
            interval = min(interval * factor, maximumInterval)
        }

        guard jitterFraction > 0 else { return interval }
        let jitter = interval * jitterFraction * max(-1, min(1, randomFraction()))
        return max(1, interval + jitter)
    }

    /// Whether an automatic refresh should run at all right now.
    ///
    /// Manual refreshes bypass this; only the timer consults it.
    public func shouldPollAutomatically(for context: Context) -> Bool {
        nextInterval(for: context, randomFraction: 0) != nil
    }
}

/// How old a snapshot has to be before the UI stops presenting it as current.
public struct StalenessPolicy: Hashable, Sendable {
    /// Below this, the snapshot is simply "current".
    public var freshLimit: TimeInterval
    /// Above this, the snapshot is labelled stale regardless of connection state.
    public var staleLimit: TimeInterval

    public init(freshLimit: TimeInterval = 90, staleLimit: TimeInterval = 300) {
        self.freshLimit = freshLimit
        self.staleLimit = staleLimit
    }

    public static let `default` = StalenessPolicy()

    public enum Freshness: Hashable, Sendable {
        case fresh
        case aging
        case stale
    }

    public func freshness(of generatedAt: Date, now: Date = Date()) -> Freshness {
        let age = now.timeIntervalSince(generatedAt)
        if age <= freshLimit { return .fresh }
        if age <= staleLimit { return .aging }
        return .stale
    }
}
