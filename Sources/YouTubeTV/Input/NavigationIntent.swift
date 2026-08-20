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
}

public enum SeekDirection: Equatable, Sendable {
    case backward, forward
}

/// Timing for a held direction: one immediate move, a pause, then a steady
/// repeat. Matches the cadence of TV remotes closely enough that holding a
/// direction to cross a long row feels normal rather than laggy or runaway.
enum RepeatCadence {
    static let initialDelay: Duration = .milliseconds(400)
    static let interval: Duration = .milliseconds(110)
}
