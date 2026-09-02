import Testing
@testable import YouTubeTV
import YouTubeCore

// The player's transport band resolves d-pad movement in software rather than
// leaving it to geometry, for the same reason `BrowseNavigator` does — so the
// order is predictable and can be pinned down here rather than in a screenshot.
//
// It had no tests at all, despite the convention that focus logic in `Focus/`
// ships with them.

@Suite("PlayerNavigator")
struct PlayerNavigatorTests {

    private var all: [PlayerControl] { PlayerControl.allCases }

    // MARK: - Walking the band

    @Test("right walks the band one control at a time, in visual order")
    func rightWalksInOrder() {
        var control = all[0]
        var visited: [PlayerControl] = [control]
        for _ in 1..<all.count {
            control = PlayerNavigator.next(from: control, direction: .right) ?? control
            visited.append(control)
        }
        #expect(visited == all)
    }

    @Test("left walks back through the same order")
    func leftWalksBack() {
        var control = all[all.count - 1]
        var visited: [PlayerControl] = [control]
        for _ in 1..<all.count {
            control = PlayerNavigator.next(from: control, direction: .left) ?? control
            visited.append(control)
        }
        #expect(visited == all.reversed())
    }

    // MARK: - Ends

    // Stopping rather than wrapping is deliberate: with a wrap there is no way to
    // tell you have reached the end without looking.

    @Test("left from the first control stays put")
    func leftFromFirstStays() {
        #expect(PlayerNavigator.next(from: .description, direction: .left) == .description)
    }

    @Test("right from the last control stays put")
    func rightFromLastStays() {
        #expect(PlayerNavigator.next(from: .settings, direction: .right) == .settings)
    }

    @Test("the ends are the controls the band actually starts and finishes with")
    func endsAreWhereExpected() {
        #expect(all.first == .description)
        #expect(all.last == .settings)
    }

    // MARK: - Leaving the band

    @Test("up and down return nil — the caller decides what is above and below")
    func verticalLeavesTheBand() {
        for control in all {
            #expect(PlayerNavigator.next(from: control, direction: .up) == nil)
            #expect(PlayerNavigator.next(from: control, direction: .down) == nil)
        }
    }

    // MARK: - Reachability

    @Test("every control is reachable from either end")
    func everyControlIsReachable() {
        var reached: Set<PlayerControl> = [all[0]]
        var control = all[0]
        while let next = PlayerNavigator.next(from: control, direction: .right), next != control {
            reached.insert(next)
            control = next
        }
        #expect(reached == Set(all))
    }

    @Test("no control is a dead end horizontally")
    func noHorizontalDeadEnds() {
        for control in all {
            #expect(PlayerNavigator.next(from: control, direction: .left) != nil)
            #expect(PlayerNavigator.next(from: control, direction: .right) != nil)
        }
    }

    // MARK: - Glyphs

    // The symbol is state-dependent, and getting it wrong is the kind of thing
    // that only shows up in a screenshot. Cheap to pin down here.

    @Test("play/pause shows the action it will take, not the current state")
    func playPauseGlyphFlips() {
        #expect(PlayerControl.playPause.symbol(isPlaying: true, likeStatus: .none) == "pause.fill")
        #expect(PlayerControl.playPause.symbol(isPlaying: false, likeStatus: .none) == "play.fill")
    }

    @Test("like and dislike fill only for the side that is active")
    func likeGlyphsReflectStatus() {
        #expect(PlayerControl.like.symbol(isPlaying: false, likeStatus: .like) == "hand.thumbsup.fill")
        #expect(PlayerControl.like.symbol(isPlaying: false, likeStatus: .dislike) == "hand.thumbsup")
        #expect(PlayerControl.dislike.symbol(isPlaying: false, likeStatus: .dislike) == "hand.thumbsdown.fill")
        #expect(PlayerControl.dislike.symbol(isPlaying: false, likeStatus: .none) == "hand.thumbsdown")
    }

    @Test("save fills once the video is in Watch Later")
    func saveGlyphReflectsState() {
        #expect(PlayerControl.save.symbol(isPlaying: false, likeStatus: .none, isSaved: true) == "bookmark.fill")
        #expect(PlayerControl.save.symbol(isPlaying: false, likeStatus: .none, isSaved: false) == "bookmark")
    }

    @Test("every control produces a non-empty symbol in every state")
    func everyControlHasASymbol() {
        for control in all {
            for playing in [true, false] {
                for status in [LikeStatus.none, .like, .dislike] {
                    let symbol = control.symbol(isPlaying: playing, likeStatus: status)
                    #expect(!symbol.isEmpty, "\(control) had no symbol")
                }
            }
        }
    }
}
