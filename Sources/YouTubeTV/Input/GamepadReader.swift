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
    private var observers: [NSObjectProtocol] = []
    private var repeatTask: Task<Void, Never>?
    /// The direction currently held, so we know when to start and stop repeating.
    private var heldDirection: MoveDirection?
    /// Latched stick direction — an analog stick sends a continuous stream of
    /// values, so without this every frame past the threshold would be a move.
    private var stickDirection: MoveDirection?

    /// Past this fraction of full deflection the stick counts as pressed; below
    /// 60% of it, released. The gap is deliberate hysteresis — a single
    /// threshold makes a stick resting near the edge chatter between states.
    private let stickThreshold: Float = 0.65
    private let stickRelease: Float = 0.40

    func start(_ handler: @escaping (NavigationIntent) -> Void) {
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
            MainActor.assumeIsolated { self.stopRepeating() }
        })
    }

    func stop() {
        stopRepeating()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
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
    }

    private func handleDirectional(x: Float, y: Float, isStick: Bool) {
        let direction = Self.direction(x: x, y: y,
                                       press: isStick ? stickThreshold : 0.5,
                                       release: isStick ? stickRelease : 0.5,
                                       current: isStick ? stickDirection : heldDirection)
        if isStick { stickDirection = direction }

        guard direction != heldDirection else { return }
        heldDirection = direction
        stopRepeating()
        guard let direction else { return }

        emit(.move(direction))
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: RepeatCadence.initialDelay)
            while !Task.isCancelled {
                guard let self, self.heldDirection == direction else { return }
                self.emit(.move(direction))
                try? await Task.sleep(for: RepeatCadence.interval)
            }
        }
    }

    /// Resolves an axis pair to at most one direction. The dominant axis wins so
    /// a diagonal push never fires two moves at once, which on a grid reads as
    /// focus jumping unpredictably.
    static func direction(x: Float, y: Float, press: Float, release: Float,
                          current: MoveDirection?) -> MoveDirection? {
        let threshold = current == nil ? press : release
        if abs(x) < threshold && abs(y) < threshold { return nil }
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
