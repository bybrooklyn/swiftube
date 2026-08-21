import SwiftUI
import YouTubeCore

/// One shelf card: 16:9 thumbnail with title, channel and view/age line beneath.
///
/// Two things here were measured off the real client and are easy to get wrong:
///
/// 1. **The metadata is always visible.** Every tile renders title, channel and
///    view count whether or not it has focus. Focus changes the *title colour*
///    (`#AAAAAA` → `#F1F1F1`) and nothing else about the text.
/// 2. **Focus does not move or resize the card.** It draws a 0.375rem `#F1F1F1`
///    ring inset 0.35rem *outside* the thumbnail, with a correspondingly larger
///    corner radius so it stays concentric. No scale, no shadow, no dimming of
///    the unfocused cards. That stillness is a large part of why the real client
///    reads as a TV UI rather than a website.
struct VideoCard: View {

    let video: Video
    let isFocused: Bool
    /// The first shelf uses larger tiles than the rest.
    let isHero: Bool

    @Environment(\.viewportSize) private var viewport

    private var width: CGFloat { Theme.Metrics.cardWidth(viewport, hero: isHero) }
    private var thumbHeight: CGFloat { width / Theme.Metrics.cardAspect }
    private var corner: CGFloat { Theme.Metrics.thumbCorner(viewport) }
    private var ring: CGFloat { Theme.Metrics.focusRingWidth(viewport) }
    private var ringInset: CGFloat { Theme.Metrics.focusRingInset(viewport) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.thumbToMeta(viewport)) {
            thumbnail
            metadata
        }
        .frame(width: width, alignment: .leading)
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            ThumbnailView(url: video.thumbnailURL)
                .frame(width: width, height: thumbHeight)
                .clipShape(.rect(cornerRadius: corner))
                // The progress bar is an *overlay* on the thumbnail, not a
                // sibling in the ZStack. As a sibling its GeometryReader —
                // which is greedy — combined with `maxHeight: .infinity` made
                // the ZStack claim all offered height, so any card with watch
                // progress grew far taller than its thumbnail and sat out of
                // line with the rest of the row.
                .overlay(alignment: .bottom) {
                    if let progress = video.watchProgress, progress > 0.01 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Theme.track)
                                Rectangle().fill(Theme.brand)
                                    .frame(width: geo.size.width * min(progress, 1))
                            }
                        }
                        .frame(height: Theme.Metrics.watchProgressHeight(viewport))
                    }
                }
                .clipShape(.rect(cornerRadius: corner))

            if video.isLive {
                durationBadge("LIVE", fill: Theme.brand)
            } else if let duration = video.duration {
                durationBadge(formatDuration(duration), fill: Theme.durationBadge)
            }
        }
        .overlay {
            // Drawn outside the thumbnail rather than on its edge, so the ring
            // never eats into the image.
            RoundedRectangle(cornerRadius: corner + ringInset)
                .strokeBorder(Theme.focusRing, lineWidth: isFocused ? ring : 0)
                .padding(-ringInset)
        }
        .animation(Theme.stateChange, value: isFocused)
    }

    private func durationBadge(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(.system(size: Theme.Metrics.rem(1, viewport), weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Metrics.rem(0.25, viewport))
            .padding(.vertical, Theme.Metrics.rem(0.1, viewport))
            .background(fill, in: .rect(cornerRadius: Theme.Metrics.rem(0.25, viewport)))
            .padding(Theme.Metrics.badgeInset(viewport))
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.rem(0.15, viewport)) {
            Text(video.deArrowTitle ?? video.title)
                .font(.system(size: Theme.Metrics.cardTitleSize(viewport), weight: .bold))
                // The one thing focus changes about the text.
                .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .animation(Theme.stateChange, value: isFocused)

            Text(video.channelTitle)
                .font(.system(size: Theme.Metrics.cardMetaSize(viewport)))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            HStack(spacing: Theme.Metrics.rem(0.25, viewport)) {
                if let quality = Format.qualityBadge(video) {
                    Text(quality)
                        .font(.system(size: Theme.Metrics.cardMetaSize(viewport), weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.Metrics.rem(0.25, viewport))
                        .background(Theme.control, in: .rect(cornerRadius: Theme.Metrics.rem(0.25, viewport)))
                }
                Text(Format.metaLine(video))
                    .font(.system(size: Theme.Metrics.cardMetaSize(viewport)))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        // Fixed height regardless of content: a LazyHStack takes its height from
        // the first subview, so a variable metadata block would clip every card
        // after the first.
        .frame(width: width, height: Theme.Metrics.metaBlockHeight(viewport), alignment: .topLeading)
    }
}
