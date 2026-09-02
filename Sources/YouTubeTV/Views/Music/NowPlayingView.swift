import SwiftUI
import YouTubeCore

/// The now-playing panel: art and transport on the left, a tab strip over
/// UP NEXT and LYRICS on the right.
///
/// That split is YouTube Music's own player page, and it is the right shape for
/// a 10-foot screen too — the artwork carries the room, and the queue and the
/// lyrics are the two things anyone actually opens the panel for.
struct NowPlayingView: View {

    @Bindable var model: MusicModel
    @Environment(\.viewportSize) private var viewport

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.rem(4, viewport)) {
            leftColumn
            rightColumn
        }
        .padding(Theme.Metrics.playerInset(viewport))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
    }

    // MARK: - Left: artwork, titles, scrubber, transport

    private var artSize: CGFloat { Theme.Metrics.rem(26, viewport) }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rem(1.5, viewport)) {
            ThumbnailView(url: model.session.currentTrack?.thumbnailURL, maxPixel: 1080)
                .frame(width: artSize, height: artSize)
                .clipShape(.rect(cornerRadius: Theme.Metrics.rem(1, viewport)))

            VStack(alignment: .leading, spacing: Theme.Metrics.rem(0.25, viewport)) {
                Text(model.session.currentTrack?.title ?? "")
                    .font(.system(size: Theme.Metrics.rem(2, viewport), weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(model.session.currentTrack?.artistLine ?? "")
                    .font(.system(size: Theme.Metrics.rem(1.15, viewport)))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: artSize, alignment: .leading)

            scrubber
            transport
        }
    }

    private var scrubber: some View {
        VStack(spacing: Theme.Metrics.rem(0.4, viewport)) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(Theme.textPrimary).frame(width: geo.size.width * progress)
                }
            }
            .frame(width: artSize, height: Theme.Metrics.scrubberHeight(viewport))

            HStack {
                Text(formatDuration(model.playback.currentTime))
                Spacer()
                Text(formatDuration(model.playback.duration))
            }
            .font(.system(size: Theme.Metrics.timeLabelSize(viewport)))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: artSize)
        }
    }

    private var progress: CGFloat {
        guard model.playback.duration > 0 else { return 0 }
        return min(max(model.playback.currentTime / model.playback.duration, 0), 1)
    }

    private var transport: some View {
        HStack(spacing: Theme.Metrics.transportGap(viewport)) {
            ForEach(Array(model.transportControls.enumerated()), id: \.offset) { index, control in
                let isFocused = model.nowPlayingFocus.row == 0 && model.nowPlayingFocus.column == index
                Image(systemName: control.symbol(isPlaying: model.playback.isPlaying,
                                                 repeatMode: model.session.queue.repeatMode))
                    .font(.system(size: Theme.Metrics.rem(1.25, viewport), weight: .semibold))
                    .foregroundStyle(tint(for: control, isFocused: isFocused))
                    .frame(width: Theme.Metrics.transportButton(viewport),
                           height: Theme.Metrics.transportButton(viewport))
                    .background(isFocused ? Theme.textPrimary.opacity(0.15) : .clear, in: .circle)
                    .overlay {
                        Circle().strokeBorder(Theme.focusRing,
                                              lineWidth: isFocused ? Theme.Metrics.rem(0.2, viewport) : 0)
                    }
            }
        }
        .animation(Theme.stateChange, value: model.nowPlayingFocus)
    }

    /// Shuffle and repeat light up when they are *on*, which is the only way to
    /// tell a toggle's state on a screen with no hover.
    private func tint(for control: MusicModel.Transport, isFocused: Bool) -> Color {
        let isEngaged = (control == .shuffle && model.session.queue.isShuffled)
            || (control == .repeatMode && model.session.queue.repeatMode != .off)
        if isEngaged { return Theme.brand }
        return isFocused ? Theme.textPrimary : Theme.textSecondary
    }

    // MARK: - Right: tabs over the queue or the lyrics

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rem(1.5, viewport)) {
            tabStrip
            switch model.nowPlayingTab {
            case .upNext: queueList
            case .lyrics: LyricsPanel(model: model)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var tabStrip: some View {
        HStack(spacing: Theme.Metrics.rem(0.75, viewport)) {
            ForEach(Array(MusicModel.NowPlayingTab.allCases.enumerated()), id: \.offset) { index, tab in
                MusicPill(label: tab.title,
                          isFocused: model.nowPlayingFocus.row == 1 && model.nowPlayingFocus.column == index,
                          isSelected: model.nowPlayingTab == tab)
            }
        }
    }

    private var queueList: some View {
        let tracks = model.session.queue.playOrder
        let playingId = model.session.currentTrack?.id
        let focusedRow = model.nowPlayingFocus.row == 2 ? model.nowPlayingFocus.column : -1

        return VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                MusicTrackRow(track: track,
                              number: index + 1,
                              isFocused: focusedRow == index,
                              isPlaying: track.id == playingId)
            }
        }
        // The queue is longer than the panel, so it travels under a fixed
        // focus position rather than scrolling a nested view.
        .offset(y: -CGFloat(max(focusedRow, 0)) * Theme.Metrics.rem(3.5, viewport))
        .animation(Theme.travel, value: focusedRow)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
    }
}

// MARK: - Lyrics

/// The lyrics tab.
///
/// Synced lyrics get the Apple Music treatment: the current line is bright and
/// large, its neighbours are dimmed, and the column travels so the current line
/// stays at a fixed height. Unsynced lyrics have no line to highlight, so they
/// scroll evenly with the song instead — the degradation the plan asks for,
/// which falls straight out of `Lyrics.isSynced` rather than being a mode.
private struct LyricsPanel: View {

    @Bindable var model: MusicModel
    @Environment(\.viewportSize) private var viewport

    private var lineHeight: CGFloat { Theme.Metrics.rem(3, viewport) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rem(1, viewport)) {
            if !model.lyricsActions.isEmpty { actions }

            if model.isLoadingLyrics {
                ProgressView().controlSize(.small)
            } else if model.isPickingLyrics {
                choices
            } else if let lyrics = model.lyrics {
                lines(lyrics)
                if model.showsLyricsAttribution {
                    // The credit appears once the song is over, matching Apple
                    // Music and YouTube Music — not a banner during playback.
                    Text(lyrics.attribution)
                        .font(.system(size: Theme.Metrics.rem(0.9, viewport)))
                        .foregroundStyle(Theme.textTertiary)
                        .transition(.opacity)
                }
            } else {
                Text("No lyrics found for this song.")
                    .font(.system(size: Theme.Metrics.rem(1.1, viewport)))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var actions: some View {
        HStack(spacing: Theme.Metrics.rem(0.75, viewport)) {
            ForEach(Array(model.lyricsActions.enumerated()), id: \.offset) { index, action in
                MusicPill(label: label(for: action),
                          symbol: symbol(for: action),
                          isFocused: model.nowPlayingFocus.row == 2
                              && model.nowPlayingFocus.column == index,
                          isSelected: action == .toggleRomanization && model.showsRomanization)
            }
        }
    }

    private func label(for action: MusicModel.LyricsAction) -> String {
        switch action {
        case .toggleRomanization: return model.showsRomanization ? "Original" : "Romanized"
        case .fixMatch:           return "Fix lyrics"
        case .cancelPick:         return "Cancel"
        case let .choose(index):
            guard model.lyricsChoices.indices.contains(index) else { return "" }
            let candidate = model.lyricsChoices[index].lyrics
            return "\(candidate.matchedTitle) — \(candidate.matchedArtist) (\(candidate.source.displayName))"
        }
    }

    private func symbol(for action: MusicModel.LyricsAction) -> String? {
        switch action {
        case .toggleRomanization: return "textformat.abc"
        case .fixMatch:           return "magnifyingglass"
        case .cancelPick:         return "xmark"
        case .choose:             return nil
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rem(0.5, viewport)) {
            if model.lyricsChoices.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Text("Pick the right match")
                    .font(.system(size: Theme.Metrics.rem(1, viewport)))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func lines(_ lyrics: Lyrics) -> some View {
        let highlighted = model.highlightedLyricLine

        return VStack(alignment: .leading, spacing: Theme.Metrics.rem(0.6, viewport)) {
            ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                Text(text(of: line))
                    .font(.system(size: Theme.Metrics.rem(index == highlighted ? 1.9 : 1.5, viewport),
                                  weight: index == highlighted ? .bold : .medium))
                    .foregroundStyle(colour(index: index, highlighted: highlighted))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: -scrollOffset(lyrics, highlighted: highlighted))
        .animation(Theme.travel, value: highlighted)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private func text(of line: LyricLine) -> String {
        if model.showsRomanization, let romanized = line.romanized, !romanized.isEmpty {
            return romanized
        }
        return line.text
    }

    private func colour(index: Int, highlighted: Int?) -> Color {
        guard let highlighted else { return Theme.textSecondary }
        if index == highlighted { return Theme.textPrimary }
        // Lines already sung fade further than the ones still to come, which is
        // what makes the column read as moving forward rather than as a list.
        return index < highlighted ? Theme.textTertiary.opacity(0.5) : Theme.textSecondary
    }

    private func scrollOffset(_ lyrics: Lyrics, highlighted: Int?) -> CGFloat {
        if let highlighted {
            // Keep the current line a few lines down from the top, so what is
            // coming next is always visible.
            return max(0, CGFloat(highlighted - 2) * lineHeight)
        }
        // Unsynced: pace the whole column against the song's own progress.
        guard model.playback.duration > 0, lyrics.lines.count > 8 else { return 0 }
        let fraction = min(max(model.playback.currentTime / model.playback.duration, 0), 1)
        return CGFloat(lyrics.lines.count - 8) * lineHeight * fraction
    }
}
