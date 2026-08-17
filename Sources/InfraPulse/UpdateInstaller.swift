import Foundation

/// Runs `brew upgrade` as its own LaunchAgent: a child of the app belongs to the
/// `com.infrapulse` job, which the cask's preflight boots out mid-install.
enum UpdateInstaller {
    enum Outcome {
        /// `log` is the tail of brew's output.
        case failed(exitCode: Int32, log: String)
        /// brew exited zero without installing it, so the tap lacks the release.
        case versionUnchanged(expected: String)
    }

    private static let label = "com.infrapulse.updater"
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    private static var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/InfraPulse", isDirectory: true)
    }
    private static var statusURL: URL {
        supportDirectory.appendingPathComponent("update-status")
    }
    private static var logURL: URL {
        supportDirectory.appendingPathComponent("update.log")
    }
    private static var agentURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private static var appAgentURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/com.infrapulse.plist")
    }

    /// Hands the upgrade to launchd. The caller is expected to terminate right
    /// after: brew cannot replace a bundle that is still running.
    static func start(brew: URL, targetVersion: String) throws {
        try FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: statusURL)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", script(brew: brew, targetVersion: targetVersion)],
            "RunAtLoad": true,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentURL)

        let domain = "gui/\(getuid())"
        // A leaked updater would hold the label and fail the bootstrap.
        _ = Shell.run(launchctl, ["bootout", "\(domain)/\(label)"])
        guard let result = Shell.run(launchctl, ["bootstrap", domain, agentURL.path]),
            result.exitCode == 0
        else {
            try? FileManager.default.removeItem(at: agentURL)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The outcome of the previous upgrade, or nil when there was none or it
    /// installed the version it aimed for. Consumes the record either way.
    static func pendingOutcome(currentVersion: String) -> Outcome? {
        guard let contents = try? String(contentsOf: statusURL, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: statusURL)

        let lines = contents.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let exitCode = lines.first.flatMap({ Int32($0) }) else { return nil }
        let expected = lines.count > 1 ? lines[1] : ""

        guard exitCode == 0 else {
            return .failed(exitCode: exitCode, log: logTail())
        }
        guard expected.isEmpty || expected == currentVersion else {
            return .versionUnchanged(expected: expected)
        }
        return nil
    }

    private static var launchctl: URL { URL(fileURLWithPath: "/bin/launchctl") }

    private static func logTail(lineLimit: Int = 12) -> String {
        guard let log = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(lineLimit).joined(separator: "\n")
    }

    private static func script(brew: URL, targetVersion: String) -> String {
        """
        set -u
        uid=$(/usr/bin/id -u)

        # The update check reads GitHub, but brew installs from its local tap,
        # which auto-update leaves up to a day stale. Refresh it or this no-ops.
        "\(brew.path)" update --quiet >"\(logURL.path)" 2>&1 || true

        # The app is left running so it can show its progress; the cask's
        # preflight stops it at the moment the bundle is actually replaced.
        "\(brew.path)" upgrade --cask \(caskToken) >>"\(logURL.path)" 2>&1
        code=$?

        # Written before the app can come back, so the next launch sees it.
        /bin/echo "$code" >"\(statusURL.path)"
        /bin/echo "\(targetVersion)" >>"\(statusURL.path)"

        # The cask's postflight covers a successful install; this covers a failed one.
        /bin/launchctl bootstrap gui/$uid "\(appAgentURL.path)" >/dev/null 2>&1 || true

        /bin/rm -f "\(agentURL.path)"
        /bin/launchctl bootout gui/$uid/\(label) >/dev/null 2>&1 || true
        """
    }
}
