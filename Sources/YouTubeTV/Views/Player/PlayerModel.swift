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

    /// Takes the app's shared `InnerTubeAPI` so playback runs on the same
    /// session identity as browsing — see the note on `AppModel.api`.
    init(api: InnerTubeAPI) {
        playback = PlaybackViewModel(api: api)
    }

    private(set) var focusedControl: PlayerControl = .playPause
    private(set) var areControlsVisible = true

    /// Set when the player should close and hand focus back to the browse surface.
    var didRequestDismiss = false

    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// How long the controls stay up after the last input.
    private let autoHideDelay: Duration = .seconds(4)

    var title: String { playback.currentVideo?.title ?? "" }
    var channel: String { playback.currentVideo?.channelTitle ?? "" }

    var progress: Double {
        guard playback.duration > 0 else { return 0 }
        return min(max(playback.currentTime / playback.duration, 0), 1)
    }

    func play(_ video: Video) {
        playback.load(video: video)
        showControls()
    }

    func close() {
        hideTask?.cancel()
        playback.stop()
        didRequestDismiss = true
    }

    // MARK: - Intents

    func handle(_ intent: NavigationIntent) {
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
                withAnimation(Theme.focusSpring) { focusedControl = next }
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
            focusedControl = .more
        }
    }

    private func activate(_ control: PlayerControl) {
        switch control {
        case .playPause: playback.togglePlayPause()
        case .rewind:    playback.seekRelative(seconds: -10)
        case .forward:   playback.seekRelative(seconds: 10)
        case .previous:  playback.playPrevious()
        case .next:      playback.playNext()
        case .captions, .quality, .more:
            // Picker overlays are not built yet; the controls they will drive
            // (CaptionsManager, PlaybackQualityManager) already exist on
            // PlaybackViewModel.
            break
        }
    }

    // MARK: - Auto-hide

    func showControls() {
        if !areControlsVisible {
            withAnimation(Theme.panelSpring) { areControlsVisible = true }
        }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: self?.autoHideDelay ?? .seconds(4))
            guard !Task.isCancelled, let self, self.playback.isPlaying else { return }
            withAnimation(Theme.panelSpring) { self.areControlsVisible = false }
        }
    }
}
