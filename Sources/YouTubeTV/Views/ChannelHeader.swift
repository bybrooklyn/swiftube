import SwiftUI
import YouTubeCore

/// The banner at the top of a channel page: avatar, name, subscriber count and
/// a Subscribe button.
///
/// Before this, opening a channel from the guide ran a search for its uploads
/// and dropped the result into the ordinary feed — there was no indication of
/// whose channel it was, and no way to subscribe from anywhere in the app.
///
/// The button is focusable in its own right (`TopBarItem.subscribe`), sitting
/// between the search pill and the first shelf, so it is reached by pressing Up
/// from the top row exactly as the search bar is on every other surface.
struct ChannelHeader: View {

    let channel: Channel
    let isFocused: Bool
    var onSelect: () -> Void = {}

    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    private var avatarSize: CGFloat { rem(4.5) }

    var body: some View {
        HStack(spacing: rem(1.5)) {
            avatar

            VStack(alignment: .leading, spacing: rem(0.2)) {
                Text(channel.title)
                    .font(.system(size: Theme.Metrics.playerTitleSize(viewport), weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                if let count = channel.subscriberCount, !count.isEmpty {
                    Text(count)
                        .font(.system(size: Theme.Metrics.cardMetaSize(viewport)))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            subscribeButton
                .padding(.leading, rem(0.5))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var avatar: some View {
        ThumbnailView(url: channel.thumbnailURL, fallbacks: [], maxPixel: 240)
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
    }

    /// Subscribed reads as a quieter, secondary state — the same inversion the
    /// real client uses, so the loud pill always means "not yet subscribed".
    private var subscribeButton: some View {
        Text(channel.isSubscribed ? "Subscribed" : "Subscribe")
            .font(.system(size: Theme.Metrics.railLabelSize(viewport), weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, rem(1.1))
            .padding(.vertical, rem(0.5))
            .background(background, in: Capsule())
            .overlay {
                if isFocused {
                    Capsule()
                        .strokeBorder(Theme.focusRing, lineWidth: Theme.Metrics.focusRingWidth(viewport))
                        .padding(-Theme.Metrics.focusRingInset(viewport))
                }
            }
            .contentShape(Capsule())
            .onTapGesture(perform: onSelect)
            .animation(Theme.travel, value: isFocused)
            .animation(Theme.stateChange, value: channel.isSubscribed)
    }

    private var foreground: Color {
        if isFocused { return Theme.canvas }
        return channel.isSubscribed ? Theme.textPrimary : Theme.canvas
    }

    private var background: Color {
        if isFocused { return Theme.focusRing }
        return channel.isSubscribed ? Theme.surface : Theme.textPrimary
    }
}
