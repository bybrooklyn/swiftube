import Foundation

/// The focusable controls in the player's transport bar, in visual order.
///
/// Modelled on the routing already proven in SmartTubeIOS's tvOS player
/// (`PlayerView+tvOS.swift`, `TVPlayerControl` / `tvNextControl(from:direction:)`),
/// which resolves d-pad movement in software rather than leaving it to the focus
/// engine. Doing it explicitly is what lets left/right on the transport row skip
/// straight along the buttons instead of wandering into the scrubber.
public enum PlayerControl: String, CaseIterable, Equatable, Hashable, Sendable {
    case previous
    case rewind
    case playPause
    case forward
    case next
    case captions
    case quality
    case more
}

public enum PlayerNavigator {

    /// Left/right walk the transport row and stop at both ends — wrapping would
    /// make it impossible to tell, without looking, that you had reached the end.
    public static func next(from control: PlayerControl, direction: MoveDirection) -> PlayerControl? {
        let all = PlayerControl.allCases
        guard let position = all.firstIndex(of: control) else { return nil }
        switch direction {
        case .left:
            return position > 0 ? all[position - 1] : control
        case .right:
            return position < all.count - 1 ? all[position + 1] : control
        case .up, .down:
            // Vertical movement leaves the transport row entirely; the caller
            // decides whether that means the info panel or the up-next shelf.
            return nil
        }
    }
}
