import AppKit
import SwiftUI

/// Reveals the window's close / minimise / zoom buttons when the pointer is in
/// the top-left corner, and hides them again when it leaves.
///
/// `TVWindowConfigurator` hides them outright, which is right for a Steam
/// session on a television but leaves a desktop user with no way to close the
/// window except ⌘Q. Revealing them on approach keeps the ten-foot surface
/// clean while the pointer is away and gives back the ordinary macOS controls
/// the moment someone reaches for them.
struct TrafficLights: View {

    @State private var isRevealed = false

    /// The corner the real buttons occupy, in points — they sit at roughly
    /// (20, 20) with about 54pt of run, so this covers them with enough margin
    /// to catch an approach rather than a direct hit.
    private static let hotCorner = CGSize(width: 110, height: 52)

    var body: some View {
        Color.clear
            .frame(width: Self.hotCorner.width, height: Self.hotCorner.height)
            // A clear view takes no hits without this, so the hover would never
            // register.
            .contentShape(.rect)
            .onHover { inside in
                isRevealed = inside
                Self.setButtonsHidden(!inside)
            }
            .onDisappear { Self.setButtonsHidden(true) }
            .accessibilityHidden(true)
    }

    private static func setButtonsHidden(_ hidden: Bool) {
        // The app has exactly one window; `keyWindow` is nil while another app
        // is frontmost, which is precisely when nothing needs revealing.
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = hidden
        }
    }
}
