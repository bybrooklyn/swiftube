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
    /// Whether the account follows a channel. Answered by `AppModel` from the
    /// guide's subscription list; the button used to reset to "not subscribed"
    /// on every play with nothing ever fetching the real state.
    @ObservationIgnored private let isSubscribedTo: (String) -> Bool

    init(api: InnerTubeAPI, isSubscribedTo: @escaping (String) -> Bool = { _ in false }) {
        self.api = api
        self.isSubscribedTo = isSubscribedTo
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

    /// Which related video has focus while the up-next rail is open; nil when
    /// it is closed. The rail is opened by pressing Down from the transport,
    /// the same gesture the real client uses, and it is modal in the same way
    /// the settings menu is: while it is up it takes every directional press,
    /// so the transport cannot move underneath it.
    private(set) var upNextIndex: Int?

    var isUpNextOpen: Bool { upNextIndex != nil }

    /// What plays next. `PlaybackViewModel` already fills this from `/next` and
    /// already autoplays the first entry when a video ends — until now nothing
    /// ever showed it, so playback looked like a dead end even though it was not.
    var upNext: [Video] { playback.relatedVideos }

    // MARK: - Comments

    private(set) var comments: [Comment] = []
    private(set) var isLoadingComments = false
    /// Which comment has focus while the panel is open; nil when it is closed.
    private(set) var commentIndex: Int?
    var isCommentsOpen: Bool { commentIndex != nil }

    /// Whether the account follows the channel of whatever is playing, and
    /// whether this video is in Watch Later. Both are optimistic: the button
    /// changes on press and is put back if the write fails.
    private(set) var isSubscribed = false
    private(set) var isSaved = false

    /// Non-nil scroll offset while the description panel is up; nil when closed.
    /// Shaped like `commentIndex` so the two panels behave identically.
    private(set) var descriptionScroll: Int?
    var isDescriptionOpen: Bool { descriptionScroll != nil }

    /// The description text, cleaned of the trailing whitespace YouTube leaves.
    var descriptionText: String {
        (playback.currentVideo?.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isStatsVisible: Bool { playback.statsForNerdsVisible }

    /// True once the retry ladder has given up: not loading, and an error is set.
    var hasFailed: Bool { !playback.isLoading && playback.error != nil }

    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// How long the controls stay up after the last input. Settings offers this as
    /// "Controls timeout"; it used to be hardcoded here, so the setting did nothing.
    private var autoHideDelay: Duration { .seconds(max(1, playback.settings.controlsHideTimeout)) }

    /// Seeks by the interval the user chose in Settings.
    ///
    /// Both intervals were hardcoded to 10 s at all four call sites, so the two
    /// Settings rows were decorative — and the forward default is 30 s, so the
    /// value shown there disagreed with the player out of the box.
    private func seek(_ direction: SeekDirection) {
        let settings = playback.settings
        let seconds = direction == .forward
            ? Double(settings.seekForwardSeconds)
            : -Double(settings.seekBackSeconds)
        playback.seekRelative(seconds: seconds)
    }

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
        control.symbol(isPlaying: playback.isPlaying, likeStatus: playback.likeStatus,
                       isSubscribed: isSubscribed, isSaved: isSaved)
    }

    var progress: Double {
        guard playback.duration > 0 else { return 0 }
        return min(max(playback.currentTime / playback.duration, 0), 1)
    }

    func play(_ video: Video) {
        upNextIndex = nil
        commentIndex = nil
        descriptionScroll = nil
        comments = []
        isSubscribed = false
        isSaved = false
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
        // Before the same-channel guard: `play()` reset the flag already.
        isSubscribed = channelId.map(isSubscribedTo) ?? false
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
        // Every list in the player is horizontal except the two panels below,
        // which take Tab as a vertical step of their own.
        let intent = intent.asMove(horizontal: descriptionScroll == nil && commentIndex == nil)
        // A failed load owns every press: Select retries, anything else leaves.
        // `retryLoad()` had no caller at all before this, so the ladder's own
        // recovery path was unreachable from the UI.
        if hasFailed {
            switch intent {
            case .select:  playback.retryLoad()
            case .back:    close()
            default:       break
            }
            return
        }

        if let scroll = descriptionScroll {
            switch intent {
            case .move(.up):
                withAnimation(Theme.travel) { descriptionScroll = max(0, scroll - 1) }
            case .move(.down):
                withAnimation(Theme.travel) { descriptionScroll = scroll + 1 }
            case .move(.left), .move(.right), .select:
                break
            case .back, .menu:
                closeDescription()
            case .playPause:
                playback.togglePlayPause()
            case let .seek(direction):
                seek(direction)
            case .tab: break   // reduced to .move at the top of handle(_:)
            }
            showControls()
            return
        }

        if let menu {
            switch intent {
            case let .move(direction): menu.move(direction)
            case .select:              menu.select()
            case .back, .menu:         closeMenu()
            case .playPause:           playback.togglePlayPause()
            case let .seek(direction): seek(direction)
            case .tab:                 break   // reduced to .move at the top of handle(_:)
            }
            showControls()
            return
        }

        if let index = commentIndex {
            switch intent {
            case .move(.up):
                if index > 0 { withAnimation(Theme.stateChange) { commentIndex = index - 1 } }
            case .move(.down):
                if index + 1 < comments.count { withAnimation(Theme.stateChange) { commentIndex = index + 1 } }
            case .move(.left), .move(.right), .select:
                break
            case .back, .menu:
                closeComments()
            case .playPause:
                playback.togglePlayPause()
            case let .seek(direction):
                seek(direction)
            case .tab: break   // reduced to .move at the top of handle(_:)
            }
            showControls()
            return
        }

        if let index = upNextIndex {
            switch intent {
            case .move(.left):
                if index > 0 { withAnimation(Theme.stateChange) { upNextIndex = index - 1 } }
            case .move(.right):
                if index + 1 < upNext.count { withAnimation(Theme.stateChange) { upNextIndex = index + 1 } }
            case .move(.up), .back:
                closeUpNext()
            case .move(.down):
                break
            case .select:
                if upNext.indices.contains(index) {
                    let video = upNext[index]
                    closeUpNext()
                    play(video)
                }
            case .playPause:
                playback.togglePlayPause()
            case let .seek(direction):
                seek(direction)
            case .menu:
                closeUpNext()
                openMenu()
            case .tab: break   // reduced to .move at the top of handle(_:)
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
            if direction == .down, !upNext.isEmpty {
                withAnimation(Theme.stateChange) { upNextIndex = 0 }
                return
            }
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
            seek(direction)

        case .menu:
            openMenu()

        case .tab: break   // reduced to .move at the top of handle(_:)
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
        case .comments:  openComments()
        case .subscribe: toggleSubscribe()
        case .save:      toggleSaved()
        case .description: openDescription()
        case .stats:       playback.toggleStatsForNerds()
        }
    }

    private func openDescription() {
        withAnimation(Theme.stateChange) { descriptionScroll = 0 }
        cancelAutoHide()
    }

    private func closeDescription() {
        withAnimation(Theme.stateChange) { descriptionScroll = nil }
        focusedControl = .description
        showControls()
    }

    private func openComments() {
        guard let videoId = playback.currentVideo?.id else { return }
        withAnimation(Theme.stateChange) { commentIndex = 0 }
        cancelAutoHide()
        guard comments.isEmpty else { return }
        isLoadingComments = true
        Task { [api] in
            let loaded = (try? await api.fetchComments(videoId: videoId)) ?? []
            guard self.playback.currentVideo?.id == videoId else { return }
            self.comments = loaded
            self.isLoadingComments = false
        }
    }

    private func closeComments() {
        withAnimation(Theme.stateChange) { commentIndex = nil }
        focusedControl = .comments
        showControls()
    }

    /// Follows or unfollows the channel of whatever is playing.
    private func toggleSubscribe() {
        guard let channelId = playback.currentVideo?.channelId else { return }
        let was = isSubscribed
        isSubscribed = !was
        Task { [api] in
            do {
                if was { try await api.unsubscribe(channelId: channelId) }
                else    { try await api.subscribe(channelId: channelId) }
            } catch {
                guard self.playback.currentVideo?.channelId == channelId else { return }
                self.isSubscribed = was
            }
        }
    }

    /// Adds or removes the current video from Watch Later.
    private func toggleSaved() {
        guard let videoId = playback.currentVideo?.id else { return }
        let was = isSaved
        isSaved = !was
        Task { [api] in
            do {
                if was { try await api.removeFromWatchLater(videoId: videoId) }
                else    { try await api.addToWatchLater(videoId: videoId) }
            } catch {
                guard self.playback.currentVideo?.id == videoId else { return }
                self.isSaved = was
            }
        }
    }

    func hoverComment(_ index: Int) {
        guard comments.indices.contains(index), commentIndex != index else { return }
        withAnimation(Theme.stateChange) { commentIndex = index }
    }

    private func closeUpNext() {
        withAnimation(Theme.stateChange) { upNextIndex = nil }
    }

    /// Pointer support, matching the browse surface: hover focuses, click plays.
    func hoverUpNext(_ index: Int) {
        guard upNext.indices.contains(index), upNextIndex != index else { return }
        withAnimation(Theme.stateChange) { upNextIndex = index }
        showControls()
    }

    func clickUpNext(_ index: Int) {
        guard upNext.indices.contains(index) else { return }
        let video = upNext[index]
        closeUpNext()
        play(video)
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
        // Anything the user is currently navigating inside keeps the chrome up.
        // Up-next and comments live *inside* the overlay this timer hides, so
        // letting it fire while one was open left the selection invisible but still
        // live — Select then played a video the user could not see.
        guard menu == nil, upNextIndex == nil, commentIndex == nil, descriptionScroll == nil else { return }
        hideTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.autoHideDelay)
            guard !Task.isCancelled else { return }
            // Wait for playback to actually start before counting down. The guard
            // used to be `playback.isPlaying` and simply exited when it failed —
            // and nothing re-armed it — so on any video that took longer than the
            // timeout to resolve the control bar stayed up for the whole video.
            while !Task.isCancelled, !self.playback.isPlaying {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard !Task.isCancelled, self.menu == nil, self.upNextIndex == nil,
                  self.commentIndex == nil, self.descriptionScroll == nil
            else { return }
            withAnimation(Theme.travel) { self.areControlsVisible = false }
        }
    }
}
