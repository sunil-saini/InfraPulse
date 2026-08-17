import Foundation

/// Prevents a second instance. LaunchServices only deduplicates bundles it
/// launches and the LaunchAgent execs the binary, so an advisory lock covers both.
enum SingleInstanceGuard {
    private static var lockDescriptor: Int32 = -1

    static let showStatusRequest = Notification.Name("com.infrapulse.showStatusRequest")
    static let showStatusAck = Notification.Name("com.infrapulse.showStatusAck")

    static func acquireOrExit() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/InfraPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Not keyed by bundle identifier: the debug build uses a different one,
        // and a separate lock would let it run as a second, identical icon
        let lockURL = directory.appendingPathComponent("infrapulse.lock")

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        // If the lock file is unusable, prefer a running app over no app.
        guard descriptor >= 0 else { return }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            let existing =
                (try? String(contentsOf: lockURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            AppLog.error("Another InfraPulse instance is already running (pid \(existing)); exiting")
            requestStatusFromRunningInstance()
            exit(0)
        }

        // Held for the lifetime of the process; never closed.
        lockDescriptor = descriptor
        ftruncate(descriptor, 0)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        _ = pid.withCString { write(descriptor, $0, strlen($0)) }
    }

    /// Asks the running instance to open its status window, waiting for the ack
    /// so this process does not exit before the notification is delivered.
    private static func requestStatusFromRunningInstance() {
        let center = DistributedNotificationCenter.default()
        final class Ack { var received = false }
        let ack = Ack()
        let observer = center.addObserver(forName: showStatusAck, object: nil, queue: nil) { _ in
            ack.received = true
        }
        defer { center.removeObserver(observer) }

        center.postNotificationName(
            showStatusRequest, object: nil, userInfo: nil, deliverImmediately: true)

        let deadline = Date().addingTimeInterval(2)
        while !ack.received && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
