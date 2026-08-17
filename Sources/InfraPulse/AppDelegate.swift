import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private var appearanceObserver: NSObjectProtocol?

    /// Opening an already-running app sends a reopen event rather than starting a second process
    /// so Finder, Spotlight and the Dock arrive here
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        model.checkForUpdatesIfNeeded(force: true)
        AppWindow.status.show(MenuContent(model: model))
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startMonitoring()
        updateApplicationIcon()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateApplicationIcon()
            }
        }
    }

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    private func updateApplicationIcon() {
        guard let iconURL = currentIconURL(),
            let icon = NSImage(contentsOf: iconURL)
        else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
