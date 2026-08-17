import AppKit
import SwiftUI

/// Hosts a SwiftUI view in a reusable floating window: at the normal level an
/// accessory app's windows drop behind the next click, Settings included.
@MainActor
final class AppWindow {
    /// The popover's contents, for when a full menu bar hides the icon it anchors to
    static let status = AppWindow(
        title: "InfraPulse",
        size: NSSize(width: 320, height: 520),
        sizesToFit: true
    )

    static let settings = AppWindow(
        title: "InfraPulse Settings",
        size: NSSize(width: 460, height: 450),
        sizesToFit: false
    )

    private let title: String
    private let size: NSSize
    private let sizesToFit: Bool
    private var window: NSWindow?

    private init(title: String, size: NSSize, sizesToFit: Bool) {
        self.title = title
        self.size = size
        self.sizesToFit = sizesToFit
    }

    /// The content is built only when the window is first created
    /// later calls reuse the existing window, so its state survives being closed
    func show<Content: View>(_ content: @autoclosure () -> Content) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(rootView: content())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hostingView
        if let contentView = window.contentView {
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        if sizesToFit {
            window.setContentSize(hostingView.fittingSize)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
