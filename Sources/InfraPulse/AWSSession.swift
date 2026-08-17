import CryptoKit
import Foundation

enum IntrospectionResult: Sendable {
    case active(Date)
    case authenticatedWithoutExpiry
    case inactive
    case missing
    case unavailable(String)
}

private enum AWSAccessState {
    case available
    case rejected
    case unavailable
}

/// AWS CLI invocation and login-session introspection. Stateless
enum AWSSession {
    static func introspect(profile: String) -> IntrospectionResult {
        guard let aws = awsURL() else { return .unavailable("AWS CLI not found") }
        let session = configuredLoginSession(profile: profile)
        switch verifyAWSAccess(profile: profile) {
        case .available:
            break
        case .unavailable:
            return .unavailable("Unable to reach AWS")
        case .rejected:
            if let session, !session.isEmpty, matchingCacheFile(session: session) != nil {
                return .inactive
            }
            return .missing
        }
        guard let session, !session.isEmpty else {
            return .authenticatedWithoutExpiry
        }
        guard let cache = matchingCacheFile(session: session) else {
            return .authenticatedWithoutExpiry
        }
        guard let refreshToken = cache.refreshToken else {
            return .authenticatedWithoutExpiry
        }

        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("aws-login-introspect-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: input) }

        do {
            let body = try JSONSerialization.data(withJSONObject: [
                "token": refreshToken,
                "tokenTypeHint": "refresh_token",
            ])
            try body.write(to: input, options: .completeFileProtection)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: input.path)
        } catch {
            return .unavailable(error.localizedDescription)
        }

        guard
            let result = Shell.run(
                aws,
                [
                    "signin", "introspect-oauth2-token-with-iam",
                    "--profile", profile,
                    "--region", profileRegion(profile: profile),
                    "--cli-input-json", "file://\(input.path)",
                    "--query", "{active:active,exp:exp}",
                    "--output", "json",
                ])
        else {
            return .unavailable("Could not run the AWS CLI")
        }

        if result.exitCode != 0 {
            let lower = result.stderr.lowercased()
            if lower.contains("invalid choice")
                || lower.contains("not a valid choice")
                || lower.contains("not a valid command")
            {
                // Older AWS CLI versions verify STS access but lack the Sign-In
                // introspection command; keep the session valid, drop the countdown
                return .authenticatedWithoutExpiry
            }
            if lower.contains("expired") || lower.contains("session has expired") {
                // STS already confirmed working credentials; introspection can be
                // stale or unavailable while they remain usable
                return .authenticatedWithoutExpiry
            }
            return .unavailable(result.stderr)
        }

        struct Response: Decodable {
            let active: Bool
            let exp: Int64?
        }

        do {
            let response = try JSONDecoder().decode(Response.self, from: Data(result.stdout.utf8))
            guard response.active else {
                // Never report Expired while get-caller-identity succeeds:
                // introspection describes the login, STS the credentials watched
                return .authenticatedWithoutExpiry
            }
            guard let exp = response.exp, exp > 0 else {
                return .authenticatedWithoutExpiry
            }
            return .active(Date(timeIntervalSince1970: TimeInterval(exp)))
        } catch {
            return .unavailable("Invalid introspection response")
        }
    }

    struct CachedLogin: Decodable {
        let refreshToken: String?
        let idToken: String?
    }

    static func configuredLoginSession(profile: String) -> String? {
        runAWSCommand(["configure", "get", "login_session", "--profile", profile])?
            .successfulOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func verifyAWSAccess(profile: String) -> AWSAccessState {
        let arguments =
            profile == "default"
            ? ["sts", "get-caller-identity", "--output", "json"]
            : ["sts", "get-caller-identity", "--profile", profile, "--output", "json"]
        guard let result = runAWSCommand(arguments) else { return .unavailable }
        guard result.exitCode != 0 else { return .available }

        return Shell.indicatesNetworkFailure(result.stderr) ? .unavailable : .rejected
    }

    static var cacheDirectory: String {
        ProcessInfo.processInfo.environment["AWS_LOGIN_CACHE_DIRECTORY"]
            ?? "\(NSHomeDirectory())/.aws/login/cache"
    }

    /// Fingerprints the login cache so a change can be detected without
    /// re-running the AWS CLI.
    static func cacheSignature() -> String {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: cacheDirectory),
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )
        else { return "missing" }

        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard
                let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey, .fileSizeKey,
                ]),
                let date = values.contentModificationDate,
                let size = values.fileSize
            else { return nil }
            return "\(file.lastPathComponent):\(date.timeIntervalSince1970):\(size)"
        }.sorted().joined(separator: "|")
    }

    static func matchingCacheFile(session: String) -> CachedLogin? {
        let directory = cacheDirectory
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: nil
            )
        else { return nil }

        let expectedFilename = "\(cacheFilename(for: session)).json"
        let candidates =
            files.filter { $0.lastPathComponent == expectedFilename }
            + files.filter {
                $0.pathExtension == "json" && $0.lastPathComponent != expectedFilename
            }

        for file in candidates where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let cache = try? JSONDecoder().decode(CachedLogin.self, from: data),
                file.lastPathComponent == expectedFilename
                    || (cache.idToken.flatMap(jwtSubject) == session)
            else { continue }
            return cache
        }
        return nil
    }

    private static func cacheFilename(for session: String) -> String {
        SHA256.hash(data: Data(session.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["sub"] as? String) ?? (object["session_arn"] as? String)
    }

    static func runAWSCommand(_ arguments: [String]) -> Shell.Result? {
        guard let aws = awsURL() else { return nil }
        return Shell.run(aws, arguments)
    }

    static func awsURL() -> URL? {
        Shell.locate("aws", extraDirectories: ["\(NSHomeDirectory())/.local/bin"])
    }

    static func profileRegion(profile: String) -> String {
        guard
            let output = runAWSCommand(["configure", "get", "region", "--profile", profile])?
                .successfulOutput
        else {
            return "us-east-1"
        }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "us-east-1" : value
    }
}
