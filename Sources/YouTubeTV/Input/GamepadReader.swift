import Foundation
import GameController
import os

private let inputLog = Logger(subsystem: "dev.bybrooklyn.youtubetv", category: "Input")

/// Turns a connected controller into a stream of `NavigationIntent`s.
///
/// Covers both the d-pad and the left thumbstick, because a Steam Input layout
/// may map either to navigation and users will reasonably expect the stick to
/// work on a couch.
@MainActor
final class GamepadReader {

    private var handler: (NavigationIntent) -> Void = { _ in }
    /// Player-only gestures — see `TransportIntent`.
    var transportHandler: (TransportIntent) -> Void = { _ in }
    private var observers: [NSObjectProtocol] = []
    private var repeatTask: Task<Void, Never>?

    /// Right trigger: a tap skips a chapter, a hold is 2×. Which one it was
    /// is only known on release, so the hold starts on a timer.
    private var holdTask: Task<Void, Never>?
    private var isHoldingSpeed = false
    /// Latched right-stick deflection, so a stick resting off centre does not
    /// emit on every analog jitter and centring emits exactly once.
    private var scrubDeflection: Float?
    private let scrubThreshold: Float = 0.25
    static let holdDelay: Duration = .milliseconds(350)
    /// The direction currently driving auto-repeat. **Derived** from the two
    /// source latches below — never written from a handler directly.
    ///
    /// It used to be written by both sources, which made them cancel each other:
    /// releasing the d-pad emits (0, 0), so `heldDirection` went nil and the
    /// repeat stopped — while `stickDirection` stayed latched, so no further
    /// stick event fired until the stick re-centred. A held stick simply stopped
    /// repeating, permanently. The reverse held too, and each source biased the
    /// other's hysteresis threshold.
    private var heldDirection: MoveDirection?

    /// Latched d-pad direction.
    private var dpadDirection: MoveDirection?
    /// Latched stick direction — an analog stick sends a continuous stream of
    /// values, so without this every frame past the threshold would be a move.
    private var stickDirection: MoveDirection?

    /// Past this fraction of full deflection the stick counts as pressed; below
    /// 60% of it, released. The gap is deliberate hysteresis — a single
    /// threshold makes a stick resting near the edge chatter between states.
    private let stickThreshold: Float = 0.65
    private let stickRelease: Float = 0.40

    func start(_ handler: @escaping (NavigationIntent) -> Void) {
        // Idempotent: `AppModel.start()` runs from a `.task`, which SwiftUI can
        // run again. A second start used to append a second pair of notification
        // observers, doubling every intent.
        stop()
        self.handler = handler

        for controller in GCController.controllers() {
            attach(controller)
        }
        let center = NotificationCenter.default
        // Re-scan rather than reading the controller off the notification:
        // GCController is not Sendable, so carrying it across the isolation
        // boundary is a Swift 6 data-race error. `attach` is idempotent.
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for controller in GCController.controllers() { self.attach(controller) }
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in
            // Clear the latches too. A pad that disconnects mid-press left them
            // set, so the first press in that same direction after reconnecting
            // matched the stale latch and was swallowed.
            MainActor.assumeIsolated { self.releaseAllDirections() }
        })
    }

    func stop() {
        releaseAllDirections()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        // GCController instances outlive this reader, so leaving our closures on
        // them keeps `self` alive and lets a stopped reader still emit.
        for controller in GCController.controllers() {
            guard let pad = controller.extendedGamepad else { continue }
            pad.dpad.valueChangedHandler = nil
            pad.leftThumbstick.valueChangedHandler = nil
            pad.buttonA.pressedChangedHandler = nil
            pad.buttonB.pressedChangedHandler = nil
            pad.buttonX.pressedChangedHandler = nil
            pad.buttonY.pressedChangedHandler = nil
            pad.buttonMenu.pressedChangedHandler = nil
            pad.leftShoulder.pressedChangedHandler = nil
            pad.rightShoulder.pressedChangedHandler = nil
            pad.leftTrigger.pressedChangedHandler = nil
            pad.rightTrigger.pressedChangedHandler = nil
            pad.rightThumbstick.valueChangedHandler = nil
        }
        holdTask?.cancel()
        holdTask = nil
        isHoldingSpeed = false
        scrubDeflection = nil
    }

    /// Drops both source latches and the derived one, and stops any repeat.
    private func releaseAllDirections() {
        stopRepeating()
        dpadDirection = nil
        stickDirection = nil
        heldDirection = nil
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        inputLog.notice("controller attached: \(controller.vendorName ?? "unknown", privacy: .public)")

        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.handleDirectional(x: x, y: y, isStick: false) }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.handleDirectional(x: x, y: y, isStick: true) }
        }

        // Face buttons. A/B follow the platform convention; X and Y are left for
        // play/pause and the menu so a thumb never has to leave the cluster.
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.emit(.select) }
        }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.emit(.back) }
        }
        pad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.emit(.playPause) }
        }
        pad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.emit(.menu) }
        }
        pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.emit(.menu) }
        }

        // Shoulders seek — the same placement the console YouTube app uses.
        pad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.emit(.seek(.backward)) }
        }
        pad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.emit(.seek(.forward)) }
        }

        // Triggers: tap for a chapter, hold the right one for 2×. These were
        // the transport controls PlaybackViewModel already had and nothing on
        // macOS called.
        pad.rightTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.handleRightTrigger(pressed: pressed) }
        }
        pad.leftTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            guard !pressed else { return }
            MainActor.assumeIsolated { self?.transportHandler(.chapter(.backward)) }
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, _ in
            MainActor.assumeIsolated { self?.handleScrub(x: x) }
        }
    }

    private func handleRightTrigger(pressed: Bool) {
        holdTask?.cancel()
        if pressed {
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: Self.holdDelay)
                guard !Task.isCancelled, let self else { return }
                self.isHoldingSpeed = true
                self.transportHandler(.holdSpeed(true))
            }
        } else if isHoldingSpeed {
            isHoldingSpeed = false
            transportHandler(.holdSpeed(false))
        } else {
            transportHandler(.chapter(.forward))
        }
    }

    private func handleScrub(x: Float) {
        let deflection: Float? = abs(x) >= scrubThreshold ? x : nil
        guard deflection != scrubDeflection else { return }
        scrubDeflection = deflection
        transportHandler(.scrub(deflection))
    }

    private func handleDirectional(x: Float, y: Float, isStick: Bool) {
        // Hysteresis is per source: each latch is compared against its own
        // previous value, so one source's state cannot shift the other's
        // press/release threshold.
        let direction = Self.direction(x: x, y: y,
                                       press: isStick ? stickThreshold : 0.5,
                                       release: isStick ? stickRelease : 0.5,
                                       current: isStick ? stickDirection : dpadDirection)
        if isStick { stickDirection = direction } else { dpadDirection = direction }

        // The source that just changed wins while it is deflected; when it
        // releases, the other source takes over if it is still held. That is what
        // lets you release the d-pad without killing a held stick.
        let effective = direction ?? (isStick ? dpadDirection : stickDirection)

        guard effective != heldDirection else { return }
        heldDirection = effective
        stopRepeating()
        guard let effective else { return }

        emit(.move(effective))
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: RepeatCadence.initialDelay)
            while !Task.isCancelled {
                guard let self, self.heldDirection == effective else { return }
                self.emit(.move(effective))
                try? await Task.sleep(for: RepeatCadence.interval)
            }
        }
    }

    /// Resolves an axis pair to at most one direction. The dominant axis wins so
    /// a diagonal push never fires two moves at once, which on a grid reads as
    /// focus jumping unpredictably.
    /// `nonisolated` because it genuinely is: a pure function of its arguments,
    /// touching no reader state. That also lets it be tested without hopping to
    /// the main actor.
    nonisolated static func direction(x: Float, y: Float, press: Float, release: Float,
                                      current: MoveDirection?) -> MoveDirection? {
        let threshold = current == nil ? press : release
        // Radial, not per-axis. Testing each axis separately left the corners
        // dead: a clean 45° push at (0.65, 0.65) has a magnitude of 0.92 but
        // neither axis reaches a 0.65 press threshold, so nothing happened until
        // one axis alone crossed it. On a grid UI that reads as a stiff stick.
        if (x * x + y * y).squareRoot() < threshold { return nil }
        if abs(x) >= abs(y) {
            return x > 0 ? .right : .left
        } else {
            // GameController reports +y as up.
            return y > 0 ? .up : .down
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    private func emit(_ intent: NavigationIntent) {
        handler(intent)
    }
}
