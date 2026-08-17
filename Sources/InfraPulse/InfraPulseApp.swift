import AppKit
import SwiftUI

struct InfraPulseApp: App {
    @StateObject private var model = AppModel.shared
    // SwiftUI overwrites a directly assigned NSApplication.shared.delegate
    // so the adaptor is the only way these callbacks fire
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        if let iconURL = currentIconURL(),
            let icon = NSImage(contentsOf: iconURL)
        {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Label {
                Text(model.menuTitle)
            } icon: {
                if let image = menuIconImage() {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: model.status.symbol)
                }
            }
            .font(.system(size: 15, weight: .medium))
        }
        .menuBarExtraStyle(.window)
    }
}
