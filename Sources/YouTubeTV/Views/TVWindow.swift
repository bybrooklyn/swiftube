import AppKit
import SwiftUI

/// Strips the window down to a bare canvas and, when asked, takes over the
/// whole display.
///
/// A Steam-launched app is expected to behave like a game: no titlebar, no
/// traffic lights, no menu bar, and the pointer out of the way until it moves.
/// SwiftUI has no API for most of that, so this reaches the `NSWindow` once it
/// exists and configures it directly.
struct TVWindowConfigurator: NSViewRepresentable {

    /// Full-screen on launch. Off during development so the window can be
    /// screenshotted and placed alongside an editor; Steam builds turn it on.
    let fullScreen: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window is not attached yet at make time, so configuration is
        // deferred to the next runloop turn.
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func configure(_ window: NSWindow?) {
        guard let window else { return }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(srgbRed: 0.059, green: 0.059, blue: 0.059, alpha: 1)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }

        // Let the window fill the screen including the menu bar area, and stop
        // macOS from restoring a stale frame over the top of it.
        window.collectionBehavior.insert(.fullScreenPrimary)

        if fullScreen && !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }
}

extension View {
    /// Applies the TV window treatment. `fullScreen` is read from the
    /// `YOUTUBETV_WINDOWED` environment variable so a developer (or an agent
    /// taking screenshots) can run windowed without a separate build:
    ///
    ///     YOUTUBETV_WINDOWED=1 open build/YouTube.app
    func tvWindow() -> some View {
        let windowed = ProcessInfo.processInfo.environment["YOUTUBETV_WINDOWED"] != nil
        return background(TVWindowConfigurator(fullScreen: !windowed))
    }
}
