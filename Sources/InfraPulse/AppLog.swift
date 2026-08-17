import os

enum AppLog {
    private static let logger = Logger(subsystem: "com.infrapulse", category: "error")

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
