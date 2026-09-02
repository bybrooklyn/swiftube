import SwiftUI
import YouTubeCore

/// The Music tab.
///
/// Structurally a sibling of `ShelfListView`: a vertical stack translated so the
/// focused row parks near the top, with each row rendering its own cells. What
/// differs is the vocabulary, which follows YouTube Music rather than YouTube —
/// a detail page opens with large square art and a Play/Shuffle/Radio pill row
/// over a numbered track list, and a track list is walked with up/down.
struct MusicView: View {

    @Bindable var model: MusicModel
    @Environment(\.viewportSize) private var viewport

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                if let header = model.header {
                    MusicPageHeader(header: header)
                        .padding(.horizontal, inset)
                        .padding(.bottom, Theme.Metrics.rem(1.5, viewport))
                }
                rowStack
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if model.isLoading && model.rows.isEmpty {
                LoadingIndicator()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = model.message {
                SurfaceMessage(title: "Music", detail: message, symbol: "music.note")
            }

            // Hosted outside the conditional, like the app's other glass panels,
            // so the bar materialises rather than cutting (see GlassHost).
            GlassHost {
                if model.session.currentTrack != nil, !model.isNowPlayingOpen {
                    MiniPlayerBar(model: model)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(Theme.panelTransition)
                }
            }
            .animation(Theme.travel, value: model.session.currentTrack?.id)

            if model.isNowPlayingOpen {
                NowPlayingView(model: model)
                    .transition(Theme.panelTransition)
                    .zIndex(2)
            }
        }
        // The tab is a full surface, not an overlay with holes in it: without an
        // explicit frame the ZStack takes the width of the widest carousel strip
        // and inflates everything around it, the same trap `RootView` documents.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var inset: CGFloat { Theme.Metrics.contentInset(viewport) }

    private var rowStack: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.shelfGap(viewport)) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                MusicRowView(row: row,
                             rowIndex: index,
                             focus: model.focus,
                             model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same trick as the browse surface: translate the whole stack so the
        // focused row sits near the top, rather than nesting scroll views.
        .offset(y: -scrollOffset)
        .animation(Theme.travel, value: model.focus)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    /// Distance to lift the stack so the focused row — and, inside a track list,
    /// the focused *track* — stays near the top of the content area.
    private var scrollOffset: CGFloat {
        var offset: CGFloat = 0
        for index in 0..<model.focus.row where index < model.rows.count {
            offset += MusicRowView.height(of: model.rows[index], viewport: viewport)
                + Theme.Metrics.shelfGap(viewport)
        }
        if model.rows.indices.contains(model.focus.row),
           case .tracks = model.rows[model.focus.row].content {
            // A track list is taller than the screen, so scrolling has to follow
            // the cell rather than stop at the row.
            offset += CGFloat(model.focus.column) * MusicRowView.trackRowHeight(viewport)
        }
        return max(0, offset)
    }
}

// MARK: - Page header

/// The block above the rows on a detail page: art, title, the grey meta line.
/// Matches YouTube Music's release page — art on the left, text beside it.
private struct MusicPageHeader: View {

    let header: MusicModel.Header
    @Environment(\.viewportSize) private var viewport

    private var artSize: CGFloat { Theme.Metrics.rem(14, viewport) }

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Metrics.rem(2, viewport)) {
            artwork
            VStack(alignment: .leading, spacing: Theme.Metrics.rem(0.5, viewport)) {
                Text(header.title)
                    .font(.system(size: Theme.Metrics.rem(3, viewport), weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if !header.subtitle.isEmpty {
                    Text(header.subtitle)
                        .font(.system(size: Theme.Metrics.rem(1.1, viewport)))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                if let description = header.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: Theme.Metrics.rem(1, viewport)))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: Theme.Metrics.rem(40, viewport), alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Theme.Metrics.rem(1, viewport))
    }

    @ViewBuilder
    private var artwork: some View {
        let image = ThumbnailView(url: header.artworkURL, maxPixel: 720)
            .frame(width: artSize, height: artSize)
        if header.isCircularArtwork {
            image.clipShape(Circle())
        } else {
            image.clipShape(.rect(cornerRadius: Theme.Metrics.thumbCorner(viewport)))
        }
    }
}

// MARK: - One row

struct MusicRowView: View {

    let row: MusicModel.Row
    let rowIndex: Int
    let focus: MusicFocus
    @Bindable var model: MusicModel

    @Environment(\.viewportSize) private var viewport

    private var isActiveRow: Bool { focus.row == rowIndex }
    private var inset: CGFloat { Theme.Metrics.contentInset(viewport) }

    static func trackRowHeight(_ viewport: CGSize) -> CGFloat {
        Theme.Metrics.rem(3.5, viewport)
    }

    /// Height a row occupies, so the parent can translate the stack correctly.
    static func height(of row: MusicModel.Row, viewport: CGSize) -> CGFloat {
        let header = row.title.isEmpty ? 0 : Theme.Metrics.rem(2.625, viewport)
        switch row.content {
        case .tiles:
            // Square art plus the two-line label block beneath it.
            return header + Theme.Metrics.rem(13, viewport) + Theme.Metrics.rem(4, viewport)
        case let .tracks(tracks):
            return header + CGFloat(tracks.count) * trackRowHeight(viewport)
        case .actions, .chips:
            return header + Theme.Metrics.rem(2.6, viewport)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rem(0.75, viewport)) {
            if !row.title.isEmpty {
                Text(row.title)
                    .font(.system(size: Theme.Metrics.shelfHeaderSize(viewport), weight: .medium))
                    .frame(height: Theme.Metrics.rem(2.625, viewport), alignment: .bottom)
                    .foregroundStyle(isActiveRow ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.leading, inset)
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch row.content {
        case let .tiles(items):    tiles(items)
        case let .tracks(tracks):  trackList(tracks)
        case let .actions(actions): pills(actions.map { ($0.label, $0.symbol, false) })
        case let .chips(pages):
            pills(pages.map { (MusicModel.chipLabel($0), nil, $0 == model.page) })
        }
    }

    /// A horizontal strip, translated so the focused tile parks at the inset —
    /// the same overlay-on-a-spacer trick `ShelfListView` uses, and for the same
    /// reason: a strip laid out as a real child inflates every ancestor.
    private func tiles(_ items: [MusicItem]) -> some View {
        let size = Theme.Metrics.rem(13, viewport)
        let step = size + Theme.Metrics.cardGutter(viewport)
        let parked = isActiveRow ? focus.column : 0

        return Color.clear
            .frame(height: size + Theme.Metrics.rem(4, viewport))
            .overlay(alignment: .topLeading) {
                HStack(alignment: .top, spacing: Theme.Metrics.cardGutter(viewport)) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        MusicTile(item: item, isFocused: isActiveRow && focus.column == index)
                    }
                }
                .offset(x: -CGFloat(parked) * step)
                .fixedSize()
            }
            .padding(.leading, inset)
            .clipped()
            .animation(Theme.travel, value: parked)
    }

    private func trackList(_ tracks: [MusicTrack]) -> some View {
        let playingId = model.session.currentTrack?.id
        // Album pages number their tracks; a library or search list does not.
        let numbered = tracks.contains { $0.trackNumber != nil }

        return VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                MusicTrackRow(track: track,
                              number: numbered ? (track.trackNumber ?? index + 1) : index + 1,
                              isFocused: isActiveRow && focus.column == index,
                              isPlaying: track.id == playingId)
            }
        }
        .padding(.leading, inset)
        .padding(.trailing, Theme.Metrics.rem(4, viewport))
    }

    private func pills(_ items: [(String, String?, Bool)]) -> some View {
        HStack(spacing: Theme.Metrics.rem(0.75, viewport)) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                MusicPill(label: item.0,
                          symbol: item.1,
                          isFocused: isActiveRow && focus.column == index,
                          isSelected: item.2)
            }
        }
        .padding(.leading, inset)
    }
}

// MARK: - Mini player

/// The strip along the bottom while something is playing and the full panel is
/// closed — YouTube Music keeps one in every one of its apps.
private struct MiniPlayerBar: View {

    @Bindable var model: MusicModel
    @Environment(\.viewportSize) private var viewport

    var body: some View {
        HStack(spacing: Theme.Metrics.rem(1, viewport)) {
            ThumbnailView(url: model.session.currentTrack?.thumbnailURL, maxPixel: 180)
                .frame(width: Theme.Metrics.rem(3, viewport), height: Theme.Metrics.rem(3, viewport))
                .clipShape(.rect(cornerRadius: Theme.Metrics.rem(0.3, viewport)))

            VStack(alignment: .leading, spacing: 0) {
                Text(model.session.currentTrack?.title ?? "")
                    .font(.system(size: Theme.Metrics.rem(1.1, viewport), weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(model.session.currentTrack?.artistLine ?? "")
                    .font(.system(size: Theme.Metrics.rem(0.95, viewport)))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: model.playback.isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: Theme.Metrics.rem(1.1, viewport)))
                .foregroundStyle(Theme.textSecondary)
            Text("Menu for now playing")
                .font(.system(size: Theme.Metrics.rem(0.9, viewport)))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.Metrics.contentInset(viewport))
        .frame(height: Theme.Metrics.rem(5, viewport))
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}
