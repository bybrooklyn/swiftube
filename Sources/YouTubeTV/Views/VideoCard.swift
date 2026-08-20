import SwiftUI
import YouTubeCore

/// One 16:9 shelf card.
///
/// Unfocused it is thumbnail-only, which is what gives a leanback shelf its
/// clean look; the title and channel appear only under the focused card. The
/// metadata block is always laid out (hidden by opacity, not removed) so the
/// row's height never changes as focus travels along it.
struct VideoCard: View {

    let video: Video
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(url: video.thumbnailURL)
                    .frame(width: Theme.Metrics.cardWidth,
                           height: Theme.Metrics.cardWidth / Theme.Metrics.cardAspect)
                    .clipShape(.rect(cornerRadius: Theme.Metrics.cardCorner))

                if let duration = video.duration, !video.isLive {
                    Text(formatDuration(duration))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.78), in: .rect(cornerRadius: 5))
                        .padding(7)
                } else if video.isLive {
                    Text("LIVE")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.brand, in: .rect(cornerRadius: 5))
                        .padding(7)
                }

                if let progress = video.watchProgress, progress > 0.01 {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.28))
                            Rectangle().fill(Theme.brand)
                                .frame(width: geometry.size.width * min(progress, 1))
                        }
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .clipShape(.rect(bottomLeadingRadius: Theme.Metrics.cardCorner,
                                     bottomTrailingRadius: Theme.Metrics.cardCorner))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.cardCorner)
                    .strokeBorder(.white, lineWidth: isFocused ? 3 : 0)
            }
            .shadow(color: .black.opacity(isFocused ? 0.55 : 0),
                    radius: isFocused ? 24 : 0, y: isFocused ? 12 : 0)

            VStack(alignment: .leading, spacing: 3) {
                Text(video.deArrowTitle ?? video.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2, reservesSpace: true)
                Text(video.channelTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: Theme.Metrics.cardWidth, alignment: .leading)
            .opacity(isFocused ? 1 : 0)
        }
        .scaleEffect(isFocused ? Theme.focusedScale : 1, anchor: .center)
        .animation(Theme.focusSpring, value: isFocused)
    }
}
