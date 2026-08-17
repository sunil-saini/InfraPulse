import Foundation

/// kubectl discovery and context inspection. Stateless.
enum KubernetesClient {
    struct KubernetesSnapshot: Sendable {
        let contexts: [String]
        let context: String?
        let state: KubernetesState
    }

    static func inspectKubernetesState(profile: String) -> KubernetesSnapshot {
        guard kubectlURL() != nil else {
            return KubernetesSnapshot(contexts: [], context: nil, state: .notConnected)
        }

        let contexts = runKubectl(["config", "get-contexts", "-o", "name"])?.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
        let currentContext = runKubectl(["config", "current-context"])?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let savedContext = UserDefaults.standard.string(forKey: "kubernetesContext") ?? ""
        let context = contexts.contains(savedContext) ? savedContext : currentContext

        guard !context.isEmpty else {
            return KubernetesSnapshot(contexts: contexts, context: nil, state: .noContext)
        }

        var state = reachContext(context)

        // Refreshing costs an `aws` run, so it waits until one is refused
        if state == .authenticationRequired, refreshCredentials(profile: profile) {
            state = reachContext(context)
        }

        return KubernetesSnapshot(contexts: contexts, context: context, state: state)
    }

    private static func reachContext(_ context: String) -> KubernetesState {
        let result = runKubectl([
            "get", "--raw=/version",
            "--request-timeout=5s",
            "--context", context
        ])
        guard let result, result.exitCode == 0 else {
            return classify(result?.stderr ?? "")
        }
        return .connected
    }

    /// Matched on a *rejected* request: kubectl wraps an offline plugin failure
    /// in the same `getting credentials:` text as a refused one.
    static func classify(_ stderr: String) -> KubernetesState {
        let error = stderr.lowercased()
        let rejected = [
            "unauthorized",
            "forbidden",
            "accessdenied",
            "invalid, expired, revoked",
            "createoauth2token",
            "sso session",
            "sso token",
            "token has expired",
            "expiredtoken",
            "invalidclienttokenid",
            "security token included in the request is expired"
        ].contains { error.contains($0) }

        return rejected ? .authenticationRequired : .notConnected
    }

    /// A refresh token is only redeemable in the session's own region, but a
    /// kubeconfig exec block passes the cluster's. Returns whether to retry.
    private static func refreshCredentials(profile: String) -> Bool {
        let result = AWSSession.runAWSCommand(
            profile == "default"
                ? ["sts", "get-caller-identity", "--output", "json"]
                : ["sts", "get-caller-identity", "--profile", profile, "--output", "json"])
        return result?.exitCode == 0
    }

    static func runKubectl(_ arguments: [String]) -> Shell.Result? {
        guard let kubectl = kubectlURL() else { return nil }
        var environment = ProcessInfo.processInfo.environment
        if let aws = AWSSession.awsURL() {
            let awsDirectory = aws.deletingLastPathComponent().path
            let existingPath = environment["PATH"] ?? ""
            let pathEntries = existingPath.split(separator: ":").map(String.init)
            if !pathEntries.contains(awsDirectory) {
                environment["PATH"] = ([awsDirectory] + pathEntries).joined(separator: ":")
            }
        }
        return Shell.run(kubectl, arguments, environment: environment)
    }

    private static func kubectlURL() -> URL? {
        Shell.locate("kubectl")
    }
}
