import Foundation

struct GitHubRelease: Decodable {
    let tagName: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}

/// Semantic version comparison for update checks.
enum ReleaseVersion {
    private static func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = versionComponents(candidate)
        let currentParts = versionComponents(current)
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }
}
