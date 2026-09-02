import Foundation
import Testing
@testable import YouTubeMedia
@testable import YouTubeCore
// `canImport(MediaPlayer)`, not `canImport(UIKit)`. MediaPlayer *is* available on
// macOS — PlaybackViewModel+NowPlaying.swift calls MPRemoteCommandCenter.shared()
// unguarded, and un-gating Now Playing for macOS is one of the port's headline
// changes. Gating on UIKit meant these six regression tests for that exact change
// were compiled out on the only platform this app ships to.
#if canImport(MediaPlayer)
import MediaPlayer

/// Tests that setupRemoteCommandCenter registers next/previous track commands and
/// that updateNowPlayingInfo correctly reflects hasNext/hasPrevious in the enabled
/// state of those commands.
///
/// Regression test for Task #233: lock screen Now Playing widget was missing
/// next/previous buttons because nextTrackCommand / previousTrackCommand were never
/// registered in setupRemoteCommandCenter().
@MainActor
struct NowPlayingCommandsTests {

    // MARK: - Next/previous command registration

    /// After setupRemoteCommandCenter(), nextTrackCommand must be registered and
    /// isEnabled must start false (no queue yet).
    @Test func nextTrackCommandRegisteredAfterSetup() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()
        let cmd = MPRemoteCommandCenter.shared().nextTrackCommand
        // The command should exist (non-nil isEnabled is always accessible).
        // The key assertion: we successfully called addTarget without crashing —
        // verified by the fact we reached this line — and isEnabled is false
        // because hasNext defaults to false.
        #expect(cmd.isEnabled == false)
    }

    @Test func previousTrackCommandRegisteredAfterSetup() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()
        let cmd = MPRemoteCommandCenter.shared().previousTrackCommand
        #expect(cmd.isEnabled == false)
    }

    // MARK: - isEnabled reflects hasNext / hasPrevious

    /// When hasNext is true and updateNowPlayingInfo() is called,
    /// nextTrackCommand.isEnabled must be true.
    @Test func nextTrackCommandEnabledWhenHasNext() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()

        // Provide a minimal video so updateNowPlayingInfo() doesn't bail early.
        let video = Video(id: "testVideo", title: "Test", channelTitle: "Chan")
        vm.currentVideo = video
        vm.hasNext = true
        vm.hasPrevious = false

        vm.updateNowPlayingInfo()

        #expect(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled == true)
        #expect(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled == false)
    }

    @Test func previousTrackCommandEnabledWhenHasPrevious() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()

        let video = Video(id: "testVideo2", title: "Test 2", channelTitle: "Chan")
        vm.currentVideo = video
        vm.hasNext = false
        vm.hasPrevious = true

        vm.updateNowPlayingInfo()

        #expect(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled == false)
        #expect(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled == true)
    }

    // MARK: - Artwork fetch starts on new video

    /// updateNowPlayingInfo() should set cachedArtworkVideoID when a video with a
    /// thumbnailURL is first seen, signalling a fetch was kicked off.
    @Test func artworkFetchStartedForNewVideo() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()

        let thumbURL = URL(string: "https://i.ytimg.com/vi/testArtwork/hqdefault.jpg")!
        let video = Video(id: "artworkVideo", title: "Art", channelTitle: "Chan", thumbnailURL: thumbURL)
        vm.currentVideo = video
        vm.updateNowPlayingInfo()

        // cachedArtworkVideoID should be set after the first updateNowPlayingInfo call.
        #expect(vm.cachedArtworkVideoID == "artworkVideo")
    }

    /// Calling updateNowPlayingInfo() again for the same video must NOT reset
    /// cachedArtworkVideoID (i.e. the redundant-fetch guard works).
    @Test func artworkFetchNotRestartedForSameVideo() {
        let vm = PlaybackViewModel()
        vm.setupRemoteCommandCenter()

        let thumbURL = URL(string: "https://i.ytimg.com/vi/sameVideo/hqdefault.jpg")!
        let video = Video(id: "sameVideo", title: "Same", channelTitle: "Chan", thumbnailURL: thumbURL)
        vm.currentVideo = video

        vm.updateNowPlayingInfo()
        // Simulate the fetch completing and setting cachedArtwork.
        // `PlatformImage` is the shim PlaybackViewModel actually stores:
        // UIImage on iOS, NSImage here.
        vm.cachedArtwork = PlatformImage()

        vm.updateNowPlayingInfo()
        // cachedArtwork must still be non-nil (was not reset to nil on the second call).
        #expect(vm.cachedArtwork != nil)
        #expect(vm.cachedArtworkVideoID == "sameVideo")
    }
}
#endif
