import AppKit
import CryptoKit
import Foundation
import Network
import SwiftUI

@MainActor
final class AppModel: NSObject, ObservableObject {
    /// SwiftUI instantiates `AppDelegate` itself
    /// so it cannot be handed the model and reaches it here instead
    static let shared = AppModel()

    @Published private(set) var status: SessionStatus = .waiting
    @Published private(set) var expiresAt: Date?
    @Published private(set) var profile = "default"
    @Published private(set) var officePublicIPs = VPNDetector.defaultOfficePublicIPs
    @Published private(set) var isKubernetesMonitoringEnabled = true
    @Published private(set) var vpnState: VPNState = .notConnected
    @Published private(set) var kubernetesState: KubernetesState = .noContext
    @Published private(set) var kubernetesContext: String?
    @Published private(set) var availableKubernetesContexts: [String] = []
    @Published private(set) var isSwitchingKubernetesContext = false
    @Published private(set) var availableProfiles: [String] = []
    @Published private(set) var isLoggingIn = false
    @Published private(set) var isRefreshingSession = false
    @Published private(set) var latestReleaseVersion: String?
    @Published private(set) var isUpdating = false
    @Published var alert: AppAlert?

    private var refreshTimer: Timer?
    private var monitorTask: Task<Void, Never>?
    private var networkRefreshCounter = 0
    private var networkRefreshTask: Task<Void, Never>?
    private var kubernetesRefreshCounter = 0
    private var updateMonitorTask: Task<Void, Never>?
    private var updateWatchTask: Task<Void, Never>?
    private var lastUpdateCheck: Date?
    private var statusRequestObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var wasNetworkSatisfied = true
    /// Two working networks both report satisfied, so the interfaces are what
    /// notice a move between them
    private var lastPathSignature = ""
    /// Set on wake or when the network returns, so the next check happens now
    private var forceAccessCheck = false
    /// Set when the user dismisses the login dialog. They know the session is
    /// gone, so stop interrupting until a working one starts the next cycle
    private var expiryAcknowledged = false

    override init() {
        if let argument = CommandLine.arguments.dropFirst().first, !argument.isEmpty {
            profile = argument
        } else if let savedProfile = UserDefaults.standard.string(forKey: "awsProfile"),
            !savedProfile.isEmpty
        {
            profile = savedProfile
        }
        if let savedOfficePublicIPs = UserDefaults.standard.array(forKey: "officePublicIPs")
            as? [String]
        {
            officePublicIPs = savedOfficePublicIPs.filter(VPNDetector.isValidIPv4Address)
        }
        if UserDefaults.standard.object(forKey: "kubernetesMonitoringEnabled") != nil {
            isKubernetesMonitoringEnabled = UserDefaults.standard.bool(
                forKey: "kubernetesMonitoringEnabled")
        }
        super.init()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshClock()
            }
        }
        // Start after the run loop: LaunchServices can build the SwiftUI scene
        // before the app is active, where a task made in init is unreliable
        DispatchQueue.main.async { [weak self] in
            self?.startMonitoring()
            self?.reportPreviousUpdateOutcome()
            self?.startUpdateMonitoring()
            self?.startInstanceStatusListener()
            self?.startWakeListener()
            self?.startNetworkListener()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        monitorTask?.cancel()
        updateMonitorTask?.cancel()
        updateWatchTask?.cancel()
        if let statusRequestObserver {
            DistributedNotificationCenter.default().removeObserver(statusRequestObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        pathMonitor?.cancel()
    }

    /// A check that failed for being offline can answer as soon as the network
    /// returns, instead of sitting out a backoff of up to five minutes
    private func startNetworkListener() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            // Says the public IP the office check reads may have moved
            let signature =
                "\(path.status)|"
                + path.availableInterfaces.map(\.name).joined(separator: ",")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let pathChanged = signature != self.lastPathSignature
                    let returned = isSatisfied && !self.wasNetworkSatisfied
                    defer {
                        self.wasNetworkSatisfied = isSatisfied
                        self.lastPathSignature = signature
                    }
                    if returned {
                        self.forceAccessCheck = true
                    }
                    guard isSatisfied, pathChanged else { return }
                    self.refreshVPNState(invalidatingPublicIP: true)
                }
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// A session can expire or be revoked while the machine sleeps, and
    /// nothing in the cache records that
    private func startWakeListener() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forceAccessCheck = true
            }
        }
    }

    private func startInstanceStatusListener() {
        guard statusRequestObserver == nil else { return }
        statusRequestObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstanceGuard.showStatusRequest,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.presentRunningStatus()
            }
        }
    }

    var menuTitle: String {
        switch status {
        case .valid, .expiring: return countdown
        case .expired: return "Expired"
        case .waiting: return "AWS"
        case .signedOut: return "Signed out"
        case .unavailable: return "AWS"
        }
    }

    var countdown: String {
        guard expiresAt != nil else { return "AWS" }
        return "AWS \(remainingTime)"
    }

    var remainingTime: String {
        guard let expiresAt else { return "--" }
        let seconds = max(0, Int(expiresAt.timeIntervalSinceNow))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    var kubernetesContextDisplay: String? {
        guard let kubernetesContext else { return nil }
        return kubernetesContextDisplay(for: kubernetesContext)
    }

    func kubernetesContextDisplay(for context: String) -> String {
        let kubernetesContext = context

        if let eksRange = kubernetesContext.range(of: "aws:eks:") {
            let eksValue = kubernetesContext[eksRange.upperBound...]
            let parts = eksValue.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3, parts[2].hasPrefix("cluster/") {
                return "eks • \(parts[0]) • \(parts[2].dropFirst("cluster/".count))"
            }
        }

        guard let range = kubernetesContext.range(of: "cluster/") else {
            return kubernetesContext
        }
        return String(kubernetesContext[range.upperBound...])
    }

    func refreshClock() {
        networkRefreshCounter += 1
        if networkRefreshCounter == 1 || networkRefreshCounter % 2 == 0 {
            refreshVPNState()
        }
        if isKubernetesMonitoringEnabled {
            kubernetesRefreshCounter += 1
        }
        if isKubernetesMonitoringEnabled
            && (kubernetesRefreshCounter == 1 || kubernetesRefreshCounter % 30 == 0)
        {
            refreshKubernetesState()
        }

        guard let expiresAt else { return }
        let remaining = expiresAt.timeIntervalSinceNow

        // A spent countdown says nothing about whether AWS still accepts the
        // profile; that is the monitor loop's answer
        if remaining <= 0, status == .unavailable || status == .signedOut { return }

        // Derived in one expression: branch by branch, a spent expiry matched
        // both `remaining <= 0` and `remaining <= warningWindow` and flapped
        let derived: SessionStatus =
            remaining <= 0
            ? .expired
            : (remaining <= warningWindow ? .expiring : .valid)
        if derived != status { status = derived }
    }

    func refreshNow() {
        // Manual checks override dialog dismissal.
        expiryAcknowledged = false
        isRefreshingSession = true
        monitorTask?.cancel()
        startMonitoring(immediately: true)
    }

    func refreshProfiles() {
        let profiles =
            AWSSession.runAWSCommand(["configure", "list-profiles"])?.successfulOutput?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
        availableProfiles = Array(Set(profiles + [profile])).sorted {
            if $0 == "default" { return true }
            if $1 == "default" { return false }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func selectProfile(_ newProfile: String) {
        let trimmedProfile = newProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProfile.isEmpty, trimmedProfile != profile else { return }
        UserDefaults.standard.set(trimmedProfile, forKey: "awsProfile")
        profile = trimmedProfile
        monitorTask?.cancel()
        expiresAt = nil
        // A different profile is a different session; a dialog dismissed for
        // the old one says nothing about this one
        expiryAcknowledged = false
        status = .waiting
        startMonitoring()
    }

    @discardableResult
    func addOfficePublicIP(_ address: String) -> Bool {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VPNDetector.isValidIPv4Address(trimmedAddress),
            !officePublicIPs.contains(trimmedAddress)
        else { return false }

        officePublicIPs = (officePublicIPs + [trimmedAddress]).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        UserDefaults.standard.set(officePublicIPs, forKey: "officePublicIPs")
        refreshVPNState()
        return true
    }

    func removeOfficePublicIP(_ address: String) {
        officePublicIPs.removeAll { $0 == address }
        UserDefaults.standard.set(officePublicIPs, forKey: "officePublicIPs")
        refreshVPNState()
    }

    func setKubernetesMonitoringEnabled(_ enabled: Bool) {
        guard enabled != isKubernetesMonitoringEnabled else { return }
        isKubernetesMonitoringEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "kubernetesMonitoringEnabled")
        kubernetesRefreshCounter = 0
        isSwitchingKubernetesContext = false

        if enabled {
            refreshKubernetesState()
        } else {
            availableKubernetesContexts = []
            kubernetesContext = nil
            kubernetesState = .noContext
        }
    }

    var updateAvailable: Bool {
        guard appVersion != "dev",
            let latestReleaseVersion
        else { return false }
        return ReleaseVersion.isVersion(latestReleaseVersion, newerThan: appVersion)
    }

    func updateApplication() {
        guard updateAvailable, !isUpdating, let targetVersion = latestReleaseVersion else { return }
        guard let brew = Shell.locate("brew") else {
            alert = AppAlert(
                title: "Homebrew Not Found",
                message: "Install Homebrew to update InfraPulse automatically.",
                offersAWSLogin: false)
            return
        }

        isUpdating = true
        do {
            try UpdateInstaller.start(brew: brew, targetVersion: targetVersion)
            // The app keeps running, and the menu shows Updating, until the
            // cask's preflight stops it to swap the bundle.
            watchUpdateOutcome()
        } catch {
            isUpdating = false
            AppLog.error("Could not start InfraPulse upgrade: \(error.localizedDescription)")
            alert = AppAlert(
                title: "Could Not Update InfraPulse",
                message: error.localizedDescription,
                offersAWSLogin: false)
        }
    }

    /// A successful upgrade stops the app, so reaching an outcome here means the
    /// upgrade failed; without this the button would sit on Updating for good.
    private func watchUpdateOutcome() {
        updateWatchTask?.cancel()
        updateWatchTask = Task { [weak self] in
            for _ in 0..<updateWatchAttempts {
                try? await Task.sleep(nanoseconds: UInt64(updateWatchInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if let outcome = UpdateInstaller.pendingOutcome(currentVersion: appVersion) {
                    report(outcome)
                    isUpdating = false
                    return
                }
            }
            self?.isUpdating = false
        }
    }

    /// An upgrade can outlive the app that started it, so its failure surfaces
    /// either here or on the launch that follows.
    private func reportPreviousUpdateOutcome() {
        guard let outcome = UpdateInstaller.pendingOutcome(currentVersion: appVersion) else {
            return
        }
        report(outcome)
    }

    private func report(_ outcome: UpdateInstaller.Outcome) {
        switch outcome {
        case .failed(let exitCode, let log):
            AppLog.error("InfraPulse upgrade failed with exit code \(exitCode): \(log)")
            let detail = log.isEmpty ? "" : "\n\n\(log)"
            alert = AppAlert(
                title: "Update Failed",
                message: "Homebrew could not update InfraPulse (exit code \(exitCode)).\(detail)",
                offersAWSLogin: false)
        case .versionUnchanged(let expected):
            AppLog.error("InfraPulse upgrade left \(appVersion) installed, expected \(expected)")
            alert = AppAlert(
                title: "Update Not Installed",
                message: """
                    Homebrew finished without installing \(expected). Trying again usually \
                    resolves it; brew upgrade --cask \(caskToken) shows what Homebrew reports.
                    """,
                offersAWSLogin: false)
        }
    }

    func checkForUpdatesIfNeeded(force: Bool = false) {
        guard appVersion != "dev",
            (force
                || lastUpdateCheck.map({ Date().timeIntervalSince($0) >= updatePopoverCheckInterval })
                ?? true)
        else {
            return
        }
        lastUpdateCheck = Date()

        Task { [weak self] in
            var request = URLRequest(url: latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("InfraPulse/\(appVersion)", forHTTPHeaderField: "User-Agent")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode),
                let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                let self
            else { return }

            latestReleaseVersion = release.tagName
                .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        }
    }

    private func startUpdateMonitoring() {
        checkForUpdatesIfNeeded()
        updateMonitorTask?.cancel()
        updateMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(updateCheckInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.lastUpdateCheck = nil
                self?.checkForUpdatesIfNeeded()
            }
        }
    }

    func selectKubernetesContext(_ newContext: String) {
        guard isKubernetesMonitoringEnabled else { return }
        let trimmedContext = newContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContext.isEmpty,
            trimmedContext != kubernetesContext,
            !isSwitchingKubernetesContext
        else { return }

        isSwitchingKubernetesContext = true
        Task { [weak self] in
            let result = await Task.detached {
                KubernetesClient.runKubectl(["config", "use-context", trimmedContext])
            }.value

            guard let self else { return }
            if result?.exitCode == 0 {
                UserDefaults.standard.set(trimmedContext, forKey: "kubernetesContext")
                kubernetesContext = trimmedContext
                refreshKubernetesState { [weak self] in
                    self?.isSwitchingKubernetesContext = false
                }
            } else {
                isSwitchingKubernetesContext = false
            }
        }
    }

    /// Cancelling the previous task debounces the burst of updates one network
    /// change produces, so a single fetch answers for all of them
    private func refreshVPNState(invalidatingPublicIP: Bool = false) {
        let officePublicIPs = Set(officePublicIPs)
        networkRefreshTask?.cancel()
        networkRefreshTask = Task.detached(priority: .utility) { [weak self] in
            if invalidatingPublicIP {
                await VPNDetector.invalidatePublicIPCache()
            }
            async let officeNetwork = VPNDetector.isOnOfficeNetwork(
                officePublicIPs: officePublicIPs)
            let vpnConnected = VPNDetector.isVPNConnected()

            guard !Task.isCancelled else { return }
            await self?.applyVPNState(
                officeNetwork: await officeNetwork, vpnConnected: vpnConnected)
        }
    }

    private func applyVPNState(officeNetwork: Bool, vpnConnected: Bool) {
        let previousState = vpnState
        if officeNetwork {
            vpnState = .officeNetwork
        } else if vpnConnected {
            vpnState = .connected
        } else {
            vpnState = .notConnected
        }

        if vpnState != previousState {
            refreshKubernetesState()
        }
    }

    private func refreshKubernetesState(completion: (() -> Void)? = nil) {
        guard isKubernetesMonitoringEnabled else {
            completion?()
            return
        }
        let currentProfile = profile
        Task { [weak self] in
            let snapshot = await Task.detached {
                KubernetesClient.inspectKubernetesState(profile: currentProfile)
            }.value

            guard let self else { return }
            availableKubernetesContexts = snapshot.contexts
            kubernetesContext = snapshot.context
            kubernetesState = snapshot.state
            completion?()
        }
    }

    func startMonitoring(immediately: Bool = false) {
        guard monitorTask == nil || monitorTask?.isCancelled == true else { return }
        monitorTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.monitorLoop()
        }
    }

    func runLogin() {
        guard !isLoggingIn else { return }
        guard let aws = AWSSession.awsURL() else {
            alert = AppAlert(
                title: "AWS CLI not found",
                message: "Install AWS CLI v2 with AWS Login support, then try again")
            return
        }

        isLoggingIn = true
        let process = Process()
        process.executableURL = aws
        process.arguments = [
            "login", "--profile", profile, "--region", AWSSession.profileRegion(profile: profile),
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isLoggingIn = false
                self?.refreshNow()
            }
        }

        do {
            try process.run()
        } catch {
            isLoggingIn = false
            alert = AppAlert(
                title: "Could not start AWS Login",
                message: error.localizedDescription)
        }
    }

    func quit() {
        _ = Shell.run(
            URL(fileURLWithPath: "/bin/launchctl"),
            [
                "bootout",
                "gui/\(getuid())/com.infrapulse",
            ])
        NSApplication.shared.terminate(nil)
    }

    private func monitorLoop() async {
        var retrySeconds: UInt64 = 5

        while !Task.isCancelled {
            switch await inspectAndApply() {
            case .active(let expiry):
                retrySeconds = 5
                switch await sleepUntilExpiry(expiry) {
                case .cacheChanged:
                    continue
                case .expired:
                    // The introspection expiry is advisory; re-check STS first,
                    // as AWS Login renews credentials without touching the cache
                    continue
                }
            case .authenticatedWithoutExpiry:
                // STS confirms that AWS access works, but there is no
                // aws-login cache from which to determine an exact expiry
                await sleepUntilDue(60)
            case .inactive:
                await showExpiredAndWaitForLogin()
            case .missing:
                await showSignedOutAndWaitForLogin()
            case .unavailable:
                // Back off while AWS stays unreachable, but not through a
                // returning network: that once hid an expiry for five minutes
                status = .unavailable
                await sleepUntilDue(TimeInterval(retrySeconds))
                retrySeconds = min(retrySeconds * 2, 300)
            }
        }
    }

    /// Sleeps, but returns early once a wake or a returning network has made
    /// the last answer stale. Every wait in the monitor loop goes through here
    private func sleepUntilDue(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !Task.isCancelled, Date() < deadline {
            if forceAccessCheck { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func inspectAndApply() async -> IntrospectionResult {
        forceAccessCheck = false
        let currentProfile = profile
        let isManualCheck = isRefreshingSession
        let result = await Task.detached {
            AWSSession.introspect(profile: currentProfile)
        }.value
        if isManualCheck { isRefreshingSession = false }
        let previousStatus = status

        switch result {
        case .active(let expiry):
            expiryAcknowledged = false
            expiresAt = expiry
            refreshClock()
        case .authenticatedWithoutExpiry:
            expiryAcknowledged = false
            expiresAt = nil
            status = .valid
        case .inactive:
            expiresAt = nil
            status = .expired
        case .missing:
            expiresAt = nil
            status = .signedOut
        case .unavailable(let reason):
            // A spent expiry would keep rendering as a live "0m" countdown
            if let expiresAt, expiresAt <= Date() { self.expiresAt = nil }
            status = .unavailable
            if previousStatus != .unavailable {
                AppLog.error("AWS session check unavailable for \(currentProfile): \(reason)")
            }
        }

        if status != previousStatus {
            refreshKubernetesState()
        }
        return result
    }

    /// Answers a duplicate launch that exited on the single-instance lock
    func presentRunningStatus() {
        DistributedNotificationCenter.default().postNotificationName(
            SingleInstanceGuard.showStatusAck,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        AppWindow.status.show(MenuContent(model: self))
    }

    private func showExpiredAndWaitForLogin() async {
        status = .expired
        await showLoginDialogUntilCacheChanges(
            title: "AWS Session Expired",
            message: """
                Your AWS login session for the \(profile) profile has expired

                AI agents, MCPs, Lens might be failing silently
                """
        )
    }

    private func showSignedOutAndWaitForLogin() async {
        expiresAt = nil
        status = .signedOut
        await showLoginDialogUntilCacheChanges(
            title: "AWS Login Required",
            message: """
                The \(profile) profile is signed out

                AI agents, MCPs, Lens might be failing silently
                """
        )
    }

    private func showLoginDialogUntilCacheChanges(title: String, message: String) async {
        while !Task.isCancelled {
            let signature = AWSSession.cacheSignature()

            // Nothing to tell someone who already read it. Wait for a new
            // login rather than interrupting them every half hour
            if expiryAcknowledged {
                if await waitForCacheChangeOrTimeout(since: signature, timeout: reNotifyInterval) {
                    return
                }
                continue
            }

            let response = await showLoginDialog(title: title, message: message)
            // Only a dialog the user acted on counts as read; one that timed
            // out unseen leaves them none the wiser, so keep re-notifying
            if response == .dismissed { expiryAcknowledged = true }
            if AWSSession.cacheSignature() != signature { return }

            let refreshedResult = await inspectAndApply()
            switch refreshedResult {
            case .active, .authenticatedWithoutExpiry:
                return
            case .inactive, .missing, .unavailable:
                break
            }

            if await waitForCacheChangeOrTimeout(since: signature, timeout: reNotifyInterval) {
                return
            }
        }
    }

    private enum LoginDialogResponse {
        case runLogin
        case dismissed
        case timedOut
    }

    @discardableResult
    private func showLoginDialog(title: String, message: String) async -> LoginDialogResponse {
        let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
        let alertMessage = "\(message)\n\nClick Run AWS Login to reauthenticate"
        let iconClause: String
        if let iconURL = currentIconURL() {
            iconClause = "with icon file (POSIX file \(appleScriptString(iconURL.path)))"
        } else {
            iconClause = "with icon caution"
        }
        let script =
            "display dialog \(appleScriptString(alertMessage)) with title \(appleScriptString(title)) buttons {\"Run AWS Login\", \"Dismiss\"} default button \"Run AWS Login\" \(iconClause) giving up after 20"

        NSApp.activate(ignoringOtherApps: true)
        let result = await Task.detached {
            Shell.run(osascript, ["-e", script])?.stdout ?? ""
        }.value

        if result.contains("button returned:Run AWS Login") {
            runLogin()
            return .runLogin
        }
        // `gave up:true` is osascript closing the dialog itself; anything else,
        // Dismiss or Escape (non-zero with no stdout), was a deliberate answer
        return result.contains("gave up:true") ? .timedOut : .dismissed
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func waitForCacheChangeOrTimeout(since previous: String, timeout: UInt64) async -> Bool
    {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while !Task.isCancelled && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            if AWSSession.cacheSignature() != previous { return true }
        }
        return false
    }

    private func sleepUntilExpiry(_ expiry: Date) async -> SleepResult {
        let currentProfile = profile
        // Resolved once: the login session cannot change without the profile
        // changing, and that cancels this task
        let session = await Task.detached {
            AWSSession.configuredLoginSession(profile: currentProfile)
        }.value
        let wasPresent = await isCachePresent(session: session)

        while !Task.isCancelled {
            let seconds = expiry.timeIntervalSinceNow
            if seconds <= 0 { return .expired }
            let interval = min(seconds, 5)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if await isCachePresent(session: session) != wasPresent { return .cacheChanged }
        }
        return .expired
    }

    /// Off the main actor: this reads the cache directory every five seconds
    private func isCachePresent(session: String?) async -> Bool {
        await Task.detached {
            guard let session, !session.isEmpty else { return false }
            return AWSSession.matchingCacheFile(session: session) != nil
        }.value
    }

    private enum SleepResult {
        case expired
        case cacheChanged
    }

}
