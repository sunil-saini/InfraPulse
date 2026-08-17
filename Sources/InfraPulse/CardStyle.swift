import SwiftUI

extension View {
    /// Section styling for the menu bar popover and the status window.
    func popoverCard() -> some View {
        padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
    }

    /// Section styling for the Settings window, which sits on its own
    /// background and so needs a border rather than a fill.
    func settingsCard() -> some View {
        padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
    }
}
