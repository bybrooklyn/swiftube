import Foundation

/// A single user intention, independent of where it came from.
///
/// Gamepad and keyboard both reduce to this before anything else sees them.
/// That indirection is what makes the app work under Steam: Steam Input may
/// present a virtual Xbox pad (which arrives via `GCController`) *or* emulate
/// key presses from a controller template (which arrives via the keyboard
/// monitor), and which one a given user's layout produces is not knowable in
/// advance. Both paths land here, so both work.
public enum NavigationIntent: Equatable, Sendable {
    case move(MoveDirection)
    case select
    case back
    case menu
    case playPause
    case seek(SeekDirection)
    /// Tab / Shift-Tab: the next or previous element in reading order. The
    /// browse surface walks cards across row ends; every other surface treats
    /// it as a move along its one axis (`asMove(horizontal:)`).
    case tab(forward: Bool)
    /// A typed character, only while a text field (search, the comment
    /// composer) is up — the keyboard reader asks before emitting these, so
    /// the m/j/k/l shortcuts keep working everywhere else. `"\u{8}"` is
    /// backspace.
    case text(String)

    /// `.tab` reduced to a plain move for surfaces that are a single list —
    /// horizontal for a row of controls, vertical for a column of rows.
    func asMove(horizontal: Bool) -> NavigationIntent {
        guard case let .tab(forward) = self else { return self }
        if horizontal { return .move(forward ? .right : .left) }
        return .move(forward ? .down : .up)
    }
}

public enum SeekDirection: Equatable, Sendable {
    case backward, forward
}

/// Transport gestures only a controller produces, kept apart from
/// `NavigationIntent` because nothing but the player ever handles them.
///
/// Right trigger held is 2× until released; a tap of either trigger skips a
/// chapter; the right stick scrubs — a stream of deflections while it is off
/// centre, then `nil` when it returns, which commits the seek.
public enum TransportIntent: Equatable, Sendable {
    case holdSpeed(Bool)
    case chapter(SeekDirection)
    case scrub(Float?)
}

/// Timing for a held direction: one immediate move, a pause, then a steady
/// repeat. Matches the cadence of TV remotes closely enough that holding a
/// direction to cross a long row feels normal rather than laggy or runaway.
enum RepeatCadence {
    static let initialDelay: Duration = .milliseconds(400)
    static let interval: Duration = .milliseconds(110)
}
