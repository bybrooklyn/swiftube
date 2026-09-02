import SwiftUI
import YouTubeCore

// MARK: - The four cell kinds a music row can hold
//
// Proportions follow YouTube Music's own apps rather than the video shelves:
// release art is square, artist art is round, and a track is a numbered row
// with the duration right-aligned. Focus behaves exactly as it does on a video
// card — a ring outside the art, a title that brightens, and no movement at
// all — so the two surfaces read as one app.

/// Square (or round) art with two lines under it: a carousel tile.
struct MusicTile: View {

    let item: MusicItem
    let isFocused: Bool

    @Environment(\.viewportSize) private var viewport

    /// Square, so narrower than a 16:9 video card at the same visual weight.
    private var size: CGFloat { Theme.Metrics.rem(13, viewport) }
    private var corner: CGFloat { Theme.Metrics.thumbCorner(viewport) }
    private var ring: CGFloat { Theme.Metrics.focusRingWidth(viewport) }
    private var ringInset: CGFloat { Theme.Metrics.focusRingInset(viewport) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rem(0.75, viewport)) {
            artwork
            VStack(alignment: item.isCircular ? .center : .leading,
                   spacing: Theme.Metrics.rem(0.15, viewport)) {
                Text(item.title)
                    .font(.system(size: Theme.Metrics.rem(1.15, viewport), weight: .medium))
                    .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(2, reservesSpace: true)
                Text(item.subtitle)
                    .font(.system(size: Theme.Metrics.rem(0.95, viewport)))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .multilineTextAlignment(item.isCircular ? .center : .leading)
            .frame(width: size, alignment: item.isCircular ? .center : .leading)
        }
        .frame(width: size, alignment: .leading)
        .animation(Theme.stateChange, value: isFocused)
    }

    /// Artists are round in YouTube Music; releases and playlists are square.
    /// Branching on the shape rather than type-erasing it: `strokeBorder` needs
    /// an `InsettableShape`, and `AnyShape` is not one.
    @ViewBuilder
    private var artwork: some View {
        let image = ThumbnailView(url: item.thumbnailURL, maxPixel: 540)
            .frame(width: size, height: size)

        if item.isCircular {
            image
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Theme.focusRing, lineWidth: isFocused ? ring : 0)
                        .padding(-ringInset)
                }
        } else {
            image
                .clipShape(.rect(cornerRadius: corner))
                .overlay {
                    RoundedRectangle(cornerRadius: corner + ringInset)
                        .strokeBorder(Theme.focusRing, lineWidth: isFocused ? ring : 0)
                        .padding(-ringInset)
                }
        }
    }
}

/// One row of a track list: index, art, title and artist, duration.
struct MusicTrackRow: View {

    let track: MusicTrack
    let number: Int?
    let isFocused: Bool
    /// Drawn in the accent colour when this is the track currently playing,
    /// which is how YouTube Music marks the queue position.
    let isPlaying: Bool

    @Environment(\.viewportSize) private var viewport

    private var height: CGFloat { Theme.Metrics.rem(3.5, viewport) }
    private var artSize: CGFloat { Theme.Metrics.rem(2.6, viewport) }

    var body: some View {
        HStack(spacing: Theme.Metrics.rem(1, viewport)) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: Theme.Metrics.rem(1, viewport)))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.Metrics.rem(2, viewport), alignment: .trailing)

            ThumbnailView(url: track.thumbnailURL, maxPixel: 180)
                .frame(width: artSize, height: artSize)
                .clipShape(.rect(cornerRadius: Theme.Metrics.rem(0.3, viewport)))

            VStack(alignment: .leading, spacing: 0) {
                Text(track.title)
                    .font(.system(size: Theme.Metrics.rem(1.15, viewport), weight: .medium))
                    .foregroundStyle(isPlaying ? Theme.brand
                                     : (isFocused ? Theme.textPrimary : Theme.textSecondary))
                    .lineLimit(1)
                if !track.artistLine.isEmpty {
                    Text(track.artistLine)
                        .font(.system(size: Theme.Metrics.rem(0.95, viewport)))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Metrics.rem(1, viewport))

            if track.isExplicit {
                Text("E")
                    .font(.system(size: Theme.Metrics.rem(0.75, viewport), weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.Metrics.rem(0.3, viewport))
                    .background(Theme.control, in: .rect(cornerRadius: Theme.Metrics.rem(0.2, viewport)))
            }
            if let duration = track.duration {
                Text(formatDuration(duration))
                    .font(.system(size: Theme.Metrics.rem(1, viewport)))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Metrics.rem(1, viewport))
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.rem(0.4, viewport))
                .fill(isFocused ? Theme.control : .clear))
        .animation(Theme.stateChange, value: isFocused)
    }
}

/// A pill: the header's Play/Shuffle/Radio buttons, and the Home/Library chips.
struct MusicPill: View {

    let label: String
    var symbol: String?
    let isFocused: Bool
    /// Chips mark the page you are on; action pills never look selected.
    var isSelected: Bool = false

    @Environment(\.viewportSize) private var viewport

    var body: some View {
        HStack(spacing: Theme.Metrics.rem(0.4, viewport)) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: Theme.Metrics.rem(1, viewport), weight: .semibold))
            }
            Text(label)
                .font(.system(size: Theme.Metrics.rem(1.05, viewport), weight: .semibold))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Theme.Metrics.rem(1.25, viewport))
        .frame(height: Theme.Metrics.rem(2.6, viewport))
        .background(background, in: .capsule)
        .overlay {
            Capsule().strokeBorder(Theme.focusRing,
                                   lineWidth: isFocused ? Theme.Metrics.rem(0.2, viewport) : 0)
        }
        .animation(Theme.stateChange, value: isFocused)
    }

    private var foreground: Color {
        if isSelected { return Theme.canvas }
        return isFocused ? Theme.textPrimary : Theme.textSecondary
    }

    private var background: Color {
        if isSelected { return Theme.textPrimary }
        return Theme.control
    }
}
