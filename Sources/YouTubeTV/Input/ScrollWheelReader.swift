import AppKit
import Foundation

/// Turns scroll-wheel and trackpad scrolling into the same `.move` intents the
/// arrow keys produce, so a wheel notch or a two-finger swipe steps through a
/// rail the way a key press does. Nothing here scrolls a view: the surfaces
/// have no scroll views, only focus-driven offsets, so the only way to move
/// them is to move focus.
@MainActor
final class ScrollWheelReader {

    private var monitor: Any?
    private var handler: (NavigationIntent) -> Void = { _ in }
    /// Accumulated travel since the last emitted step, per axis. A trackpad
    /// reports a few points per event; a notched wheel reports a whole line.
    private var pendingX: CGFloat = 0
    private var pendingY: CGFloat = 0

    /// How much travel makes one step. Precise (trackpad) deltas are in points;
    /// a wheel notch arrives as a line delta of about 10 points.
    private static let preciseStep: CGFloat = 60
    private static let notchStep: CGFloat = 10

    func start(_ handler: @escaping (NavigationIntent) -> Void) {
        stop()
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            self.consume(event)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingX = 0
        pendingY = 0
    }

    private func consume(_ event: NSEvent) {
        // A fresh gesture starts from zero, and the momentum tail after the
        // fingers lift is ignored: focus should stop where the fingers stopped,
        // not fly on across the row.
        if event.phase == .began { pendingX = 0; pendingY = 0 }
        guard event.momentumPhase.isEmpty else { return }

        let step = event.hasPreciseScrollingDeltas ? Self.preciseStep : Self.notchStep
        pendingX += event.scrollingDeltaX
        pendingY += event.scrollingDeltaY

        // One step per event at most, on the axis with more travel.
        if abs(pendingY) >= step, abs(pendingY) >= abs(pendingX) {
            // Positive deltaY is "content moves down" — the user is heading
            // toward earlier rows, which is a move up.
            handler(.move(pendingY > 0 ? .up : .down))
            pendingY = 0
            pendingX = 0
        } else if abs(pendingX) >= step {
            handler(.move(pendingX > 0 ? .left : .right))
            pendingX = 0
            pendingY = 0
        }
    }
}
