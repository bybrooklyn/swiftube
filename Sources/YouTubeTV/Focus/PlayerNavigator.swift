import Foundation
import YouTubeCore

/// The focusable controls in the player's bottom band, in visual order.
///
/// Modelled on the routing proven upstream in SmartTubeIOS's tvOS player
/// (`TVPlayerControl` / `tvNextControl(from:direction:)`), which resolves d-pad
/// movement in software rather than leaving it to the focus engine. Doing it
/// explicitly is what lets left/right walk the band in a predictable order
/// instead of wandering by geometry.
public enum PlayerControl: String, CaseIterable, Equatable, Hashable, Sendable {
    // Left group
    case description
    case subscribe
    // Centre group
    case previous
    case playPause
    case next
    // Right groups
    case like
    case dislike
    case comments
    case save
    /// Save to a playlist other than Watch Later — opens the picker.
    case addToPlaylist
    case stats
    case settings

    func symbol(isPlaying: Bool, likeStatus: LikeStatus,
                isSubscribed: Bool = false, isSaved: Bool = false) -> String {
        switch self {
        case .description: "text.alignleft"
        case .subscribe:   isSubscribed ? "bell.fill" : "bell"
        case .previous:    "backward.end.fill"
        case .playPause:   isPlaying ? "pause.fill" : "play.fill"
        case .next:        "forward.end.fill"
        case .like:        likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup"
        case .dislike:     likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown"
        case .comments:    "text.bubble"
        case .save:        isSaved ? "bookmark.fill" : "bookmark"
        case .addToPlaylist: "text.badge.plus"
        case .stats:       "eye"
        case .settings:    "gearshape"
        }
    }
}

public enum PlayerNavigator {

    /// Left/right walk the band and stop at both ends — wrapping would make it
    /// impossible to tell, without looking, that you had reached the end.
    public static func next(from control: PlayerControl, direction: MoveDirection) -> PlayerControl? {
        let all = PlayerControl.allCases
        guard let position = all.firstIndex(of: control) else { return nil }
        switch direction {
        case .left:
            return position > 0 ? all[position - 1] : control
        case .right:
            return position < all.count - 1 ? all[position + 1] : control
        case .up, .down:
            // Vertical movement leaves the band entirely; the caller decides
            // whether that means the info panel or the up-next shelf.
            return nil
        }
    }
}
