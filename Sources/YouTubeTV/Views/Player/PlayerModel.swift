import Foundation
import Observation
import SwiftUI
import YouTubeCore
import YouTubeMedia

/// Presentation state for the player.
///
/// The playback pipeline itself — stream resolution, BotGuard, HLS fallbacks,
/// quality laddering, SponsorBlock — is `PlaybackViewModel`, inherited from
/// SmartTubeIOS and left alone. This type owns only what the TV chrome needs:
/// which control has focus, and whether the controls are showing.
@MainActor
@Observable
final class PlayerModel {

    let playback: PlaybackViewModel

    @ObservationIgnored private let api: InnerTubeAPI

    /// Takes the app's shared `InnerTubeAPI` so playback runs on the same
    /// session identity as browsing — see the note on `AppModel.api`.
    init(api: InnerTubeAPI) {
        self.api = api
        self.playback = PlaybackViewModel(api: api)
    }

    private(set) var focusedControl: PlayerControl = .playPause
    private(set) var areControlsVisible = true

    /// Non-nil while the settings menu is open. Modal within the player: it
    /// takes every directional press so the transport does not move underneath
    /// it.
    private(set) var menu: PlayerMenuModel?

    /// Set when the player should close and hand focus back to the browse surface.
    var didRequestDismiss = false

    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// How long the controls stay up after the last input.
    private let autoHideDelay: Duration = .seconds(4)

    var title: String { playback.currentVideo?.title ?? "" }
    var channel: String { playback.currentVideo?.channelTitle ?? "" }

    /// "Lofi Girl • 2.3M views • 5 minutes ago" — the line under the title.
    var metaLine: String {
        guard let video = playback.currentVideo else { return "" }
        return ([video.channelTitle] + [Format.metaLine(video)])
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    /// Channel avatar, fetched lazily — `PlayerInfo` does not carry one, so it is
    /// resolved from the channel id the first time a video loads.
    private(set) var channelAvatarURL: URL?

    /// "2:34 • Yasumu - We Met" — position, plus the chapter name when the video
    /// has chapters. On a long mix the chapter is the only useful position cue.
    var positionLabel: String {
        let time = formatDuration(playback.currentTime)
        if let chapter = playback.currentChapter, !chapter.title.isEmpty {
            return "\(time) • \(chapter.title)"
        }
        return time
    }

    func symbol(for control: PlayerControl) -> String {
        control.symbol(isPlaying: playback.isPlaying, likeStatus: playback.likeStatus)
    }

    var progress: Double {
        guard playback.duration > 0 else { return 0 }
        return min(max(playback.currentTime / playback.duration, 0), 1)
    }

    func play(_ video: Video) {
        playback.load(video: video)
        showControls()
        loadChannelAvatar(for: video.channelId)
    }

    /// Refreshes the avatar for whatever is playing now.
    ///
    /// Called on every video change, not just the first: next/previous go
    /// straight through `PlaybackViewModel`, so the title and metadata updated
    /// while the avatar kept showing the previous video's channel.
    func loadChannelAvatar(for channelId: String?) {
        guard channelId != avatarChannelId else { return }
        avatarChannelId = channelId
        channelAvatarURL = nil
        guard let channelId else { return }
        Task { [weak self, api] in
            guard let url = try? await api.fetchChannelThumbnailURL(channelId: channelId),
                  let self, self.avatarChannelId == channelId else { return }
            self.channelAvatarURL = url
        }
    }

    @ObservationIgnored private var avatarChannelId: String?

    func close() {
        hideTask?.cancel()
        playback.stop()
        didRequestDismiss = true
    }

    // MARK: - Intents

    func handle(_ intent: NavigationIntent) {
        if let menu {
            switch intent {
            case let .move(direction): menu.move(direction)
            case .select:              _ = menu.select()
            case .back, .menu:         closeMenu()
            case .playPause:           playback.togglePlayPause()
            case let .seek(direction): playback.seekRelative(seconds: direction == .forward ? 10 : -10)
            }
            showControls()
            return
        }

        // A SponsorBlock prompt takes Select first, whatever the transport is
        // doing — the prompt is time-limited, so making the user first reveal
        // the controls and then find a button would make it useless.
        if intent == .select, playback.currentToastSegment != nil {
            playback.skipToastSegment()
            showControls()
            return
        }

        // Any input at all brings the controls back and restarts the timer —
        // including a press that then does nothing, which is what makes the bar
        // feel responsive rather than modal.
        let wasHidden = !areControlsVisible
        showControls()

        switch intent {
        case let .move(direction):
            // The first press while the controls are hidden only reveals them.
            // Otherwise a nudge of the stick to see the timeline would also skip
            // a video, which is infuriating.
            guard !wasHidden else { return }
            if let next = PlayerNavigator.next(from: focusedControl, direction: direction) {
                withAnimation(Theme.stateChange) { focusedControl = next }
            }

        case .select:
            guard !wasHidden else { return }
            activate(focusedControl)

        case .back:
            close()

        case .playPause:
            playback.togglePlayPause()

        case let .seek(direction):
            playback.seekRelative(seconds: direction == .forward ? 10 : -10)

        case .menu:
            openMenu()
        }
    }

    private func activate(_ control: PlayerControl) {
        switch control {
        case .playPause: playback.togglePlayPause()
        case .previous:
            playback.playPrevious()
            loadChannelAvatar(for: playback.currentVideo?.channelId)
        case .next:
            playback.playNext()
            loadChannelAvatar(for: playback.currentVideo?.channelId)
        case .like:      playback.like()
        case .dislike:   playback.dislike()
        case .settings:  openMenu()
        case .description, .subscribe, .comments, .save, .stats:
            // Not yet wired to a surface of their own.
            break
        }
    }

    func openMenu() {
        menu = PlayerMenuModel(playback: playback)
        // The menu must not vanish under the auto-hide timer while it is open.
        cancelAutoHide()
    }

    private func closeMenu() {
        menu = nil
        focusedControl = .settings
        showControls()
    }

    // MARK: - Auto-hide

    private func cancelAutoHide() { hideTask?.cancel() }

    func showControls() {
        if !areControlsVisible {
            withAnimation(Theme.travel) { areControlsVisible = true }
        }
        hideTask?.cancel()
        guard menu == nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: self?.autoHideDelay ?? .seconds(4))
            guard !Task.isCancelled, let self, self.playback.isPlaying, self.menu == nil else { return }
            withAnimation(Theme.travel) { self.areControlsVisible = false }
        }
    }
}
