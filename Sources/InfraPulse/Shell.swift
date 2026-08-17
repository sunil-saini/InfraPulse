import Foundation

/// Runs a command to completion and captures its output.
enum Shell {
    struct Result: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32

        var successfulOutput: String? {
            exitCode == 0 ? stdout : nil
        }
    }

    /// Finds an executable, preferring the usual install locations over `PATH`
    /// because a LaunchAgent inherits a minimal environment.
    static func locate(_ name: String, extraDirectories: [String] = []) -> URL? {
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            + extraDirectories
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .map(String.init)
        return directories.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Whether stderr describes an unreachable endpoint or throttling rather than
    /// a rejection, which would report a working session as expired.
    static func indicatesNetworkFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return [
            "could not connect",
            "unable to connect",
            "connection",
            "dial tcp",
            "dns",
            "endpoint url",
            "network",
            "no such host",
            "timed out",
            "timeout",
            "throttling",
            "throttled",
            "rate exceeded",
            "toomanyrequests",
            "requestlimitexceeded",
            "slowdown"
        ].contains { lowered.contains($0) }
    }

    /// Returns nil only when the executable could not be launched; a command
    /// that ran and failed comes back as a `Result` with a non-zero exit code.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) -> Result? {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorOutput
        if let environment {
            process.environment = environment
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drained before waiting: a command that fills the pipe buffer would
        // otherwise block forever on a full pipe while we wait for it to exit.
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }
}
