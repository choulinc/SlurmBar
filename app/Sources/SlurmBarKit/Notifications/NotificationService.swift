import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Delivers ``JobEvent``s as native macOS notifications.
///
/// Behind a protocol so ``ClusterMonitor`` can be tested without a notification centre — and
/// because `UNUserNotificationCenter.current()` traps in a process that is not a bundled,
/// signed app, which is exactly what `swift test` runs in.
public protocol NotificationDelivering: AnyObject, Sendable {
    func requestAuthorizationIfNeeded() async
    func deliver(_ event: JobEvent) async
}

/// Records events instead of delivering them. Used by tests and previews.
public final class RecordingNotifier: NotificationDelivering, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [JobEvent] = []

    public init() {}

    public var delivered: [JobEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func requestAuthorizationIfNeeded() async {}

    public func deliver(_ event: JobEvent) async {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

#if canImport(UserNotifications)
/// The real implementation, using `UNUserNotificationCenter`.
public final class UserNotificationService: NotificationDelivering, @unchecked Sendable {
    private let lock = NSLock()
    private var didRequestAuthorization = false
    private var isAuthorized = false

    public init() {}

    public func requestAuthorizationIfNeeded() async {
        lock.lock()
        let alreadyAsked = didRequestAuthorization
        didRequestAuthorization = true
        lock.unlock()
        guard !alreadyAsked else { return }

        // Bundle check: UNUserNotificationCenter.current() raises when the executable is not a
        // bundled app, so a `swift run` of the raw binary must degrade rather than crash.
        guard Bundle.main.bundleIdentifier != nil else { return }

        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            lock.lock()
            isAuthorized = granted
            lock.unlock()
        } catch {
            NSLog("SlurmBar: notification authorization failed: %@", String(describing: error))
        }
    }

    public func deliver(_ event: JobEvent) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        lock.lock()
        let authorized = isAuthorized
        lock.unlock()
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = event.kind == .completed ? nil : .default

        // Identifier is per job-and-kind, so a repeated poll can never stack duplicates.
        let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            NSLog("SlurmBar: could not post notification: %@", String(describing: error))
        }
    }
}
#endif
