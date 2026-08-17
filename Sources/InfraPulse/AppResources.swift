import AppKit
import Foundation

let warningWindow: TimeInterval = 10 * 60
let reNotifyInterval: UInt64 = 30 * 60
let updateCheckInterval: TimeInterval = 6 * 60 * 60
let updatePopoverCheckInterval: TimeInterval = 5 * 60
/// How long the app waits for an upgrade it started before giving up on it.
let updateWatchInterval: TimeInterval = 2
let updateWatchAttempts = 150
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let latestReleaseURL = URL(string: "https://api.github.com/repos/sunil-saini/InfraPulse/releases/latest")!
/// The update check reads the release above while the upgrade installs from the
/// tap, so the two can disagree until a release reaches both.
let caskToken = "sunil-saini/tools/infrapulse"
let releasesPageURL = URL(string: "https://github.com/sunil-saini/InfraPulse/releases")!

private let resourceBundle: Bundle? = {
    let bundleName = "InfraPulse_InfraPulse.bundle"
    let candidates = [
        Bundle.main.bundleURL.appendingPathComponent(bundleName),
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/").appendingPathComponent(bundleName),
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(bundleName)
    ]
    return candidates.compactMap(Bundle.init(url:)).first
}()

func currentIconURL() -> URL? {
    let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
    let resourceName = appearance == .darkAqua ? "darkAppIcon" : "appIcon"
    return resourceBundle?.url(forResource: resourceName, withExtension: "png")
}

func menuIconImage() -> NSImage? {
    MenuIconCache.image
}

private enum MenuIconCache {
    static let image: NSImage? = {
        guard let url = resourceBundle?.url(forResource: "menuIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 20, height: 20)
        return image
    }()
}
