import AVFoundation
import AVKit
import AppKit
import SwiftUI

/// The video surface itself: an `AVPlayerLayer` fed by the shared `AVPlayer`.
///
/// AVKit's `VideoPlayer` is not used because it brings its own transport
/// controls, which is exactly the chrome this app replaces — and there is no
/// supported way to fully suppress them on macOS. A bare layer also keeps the
/// SwiftUI overlay compositing over one opaque layer, which is what lets the
/// glass control bar animate without forcing the video to re-composite.
struct PlayerSurface: NSViewRepresentable {

    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}

final class PlayerLayerView: NSView {

    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        // Resizing an AVPlayerLayer through the implicit animation makes the
        // video visibly stretch and settle on every window resize, which is very
        // obvious when entering full screen. Match the bounds without animating.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
