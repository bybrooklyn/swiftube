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
///
/// Picture in picture hangs off the same layer. The controller lives in the
/// coordinator, so it survives SwiftUI re-evaluating this view; a change in
/// `pipRequest` is the signal to toggle it — the model has no layer to talk to.
struct PlayerSurface: NSViewRepresentable {

    let player: AVPlayer
    var pipRequest = 0
    var onPictureInPictureActive: (Bool) -> Void = { _ in }
    /// The PiP window's "back to app" button. The model brings the player
    /// view back; AVKit is told the restore happened.
    var onPictureInPictureRestore: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.attach(to: view.playerLayer)
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        let coordinator = context.coordinator
        coordinator.onActive = onPictureInPictureActive
        coordinator.onRestore = onPictureInPictureRestore
        if coordinator.handledRequest != pipRequest {
            coordinator.handledRequest = pipRequest
            coordinator.toggle()
        }
    }

    @MainActor
    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        private var controller: AVPictureInPictureController?
        var handledRequest = 0
        var onActive: (Bool) -> Void = { _ in }
        var onRestore: () -> Void = {}

        func attach(to layer: AVPlayerLayer) {
            guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
            controller = AVPictureInPictureController(playerLayer: layer)
            controller?.delegate = self
        }

        func toggle() {
            guard let controller else { return }
            if controller.isPictureInPictureActive {
                controller.stopPictureInPicture()
            } else if controller.isPictureInPicturePossible {
                controller.startPictureInPicture()
            }
        }

        // AVKit calls these on the main thread; the protocol just does not say so.
        nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
            MainActor.assumeIsolated { onActive(true) }
        }

        nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            MainActor.assumeIsolated { onActive(false) }
        }

        nonisolated func pictureInPictureController(
            _ controller: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            MainActor.assumeIsolated { onRestore() }
            completionHandler(true)
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
