import SwiftUI
import YouTubeCore

/// What plays next, along the bottom of the player.
///
/// Opened by pressing Down from the transport. The videos come from `/next`,
/// which the playback pipeline already fetched and already autoplays from — the
/// rail makes that queue visible rather than inventing a new one, so what the
/// user sees first is exactly what plays when the video ends.
struct UpNextRail: View {

    @Bindable var model: PlayerModel

    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    /// Cards here are smaller than a shelf's. The player is showing video
    /// behind them, and a full-size shelf tile covers most of the frame.
    private var cardWidth: CGFloat { Theme.Metrics.cardWidth(viewport, hero: false) * 0.78 }

    var body: some View {
        VStack(alignment: .leading, spacing: rem(0.6)) {
            Text("Up next")
                .font(.system(size: Theme.Metrics.shelfHeaderSize(viewport), weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            GeometryReader { geo in
                HStack(alignment: .top, spacing: Theme.Metrics.cardGutter(viewport)) {
                    ForEach(Array(model.upNext.enumerated()), id: \.element.id) { index, video in
                        UpNextCard(video: video,
                                   isFocused: model.upNextIndex == index,
                                   width: cardWidth)
                            .onHover { if $0 { model.hoverUpNext(index) } }
                            .onTapGesture { model.clickUpNext(index) }
                    }
                }
                // Same parking rule as a shelf: the focused card sits at the
                // left edge and the row translates under it, rather than the
                // highlight running off the side of the screen.
                .offset(x: -CGFloat(model.upNextIndex ?? 0)
                        * (cardWidth + Theme.Metrics.cardGutter(viewport)))
                .animation(Theme.travel, value: model.upNextIndex)
                .frame(width: geo.size.width, alignment: .leading)
            }
            .frame(height: cardWidth / Theme.Metrics.cardAspect + rem(4.2))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// A compact card: thumbnail, title, channel. No view count — at this size the
/// third line is unreadable and only makes the rail taller.
private struct UpNextCard: View {

    let video: Video
    let isFocused: Bool
    let width: CGFloat

    @Environment(\.viewportSize) private var viewport

    private var corner: CGFloat { Theme.Metrics.thumbCorner(viewport) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.thumbToMeta(viewport)) {
            ThumbnailView(url: video.thumbnailURL,
                          fallbacks: video.thumbnailFallbackURLs,
                          maxPixel: 480)
                .frame(width: width, height: width / Theme.Metrics.cardAspect)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay {
                    if isFocused {
                        RoundedRectangle(
                            cornerRadius: corner + Theme.Metrics.focusRingInset(viewport),
                            style: .continuous
                        )
                        .strokeBorder(Theme.focusRing, lineWidth: Theme.Metrics.focusRingWidth(viewport))
                        .padding(-Theme.Metrics.focusRingInset(viewport))
                    }
                }

            Text(video.title)
                .font(.system(size: Theme.Metrics.cardTitleSize(viewport) * 0.9, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(video.channelTitle)
                .font(.system(size: Theme.Metrics.cardMetaSize(viewport) * 0.9))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
    }
}
