import SwiftUI
import YouTubeCore

/// Comments, in a column down the right-hand side of the player.
///
/// A panel rather than a bottom sheet because comments are a long vertical
/// list and the video should stay watchable beside them — the same choice the
/// real TV client makes. Up and Down move through them; Back closes.
///
/// This is the one place in the player where a full glass panel is right: it is
/// a persistent surface the user reads, not a transient control bar, and it
/// covers a strip of video rather than the whole frame.
struct CommentsPanel: View {

    @Bindable var model: PlayerModel

    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    private var width: CGFloat { min(viewport.width * 0.34, rem(30)) }

    var body: some View {
        VStack(alignment: .leading, spacing: rem(1.0)) {
            Text("Comments")
                .font(.system(size: Theme.Metrics.shelfHeaderSize(viewport), weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            if model.isLoadingComments {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, rem(2))
            } else if model.comments.isEmpty {
                Text("Comments are turned off for this video.")
                    .font(.system(size: Theme.Metrics.cardMetaSize(viewport)))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                list
            }

            Spacer(minLength: 0)
        }
        .padding(rem(1.5))
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: rem(1.0), style: .continuous))
    }

    private var list: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: rem(1.25)) {
                ForEach(Array(model.comments.enumerated()), id: \.element.id) { index, comment in
                    row(comment, isFocused: model.commentIndex == index)
                        .onHover { if $0 { model.hoverComment(index) } }
                }
            }
            // Keeps the focused comment in view by translating the column, the
            // same stateless approach the guide uses: derived from the focused
            // index each time rather than accumulated, so it cannot drift.
            .offset(y: -CGFloat(model.commentIndex ?? 0) * rem(7.0))
            .animation(Theme.travel, value: model.commentIndex)
            .frame(width: geo.size.width, alignment: .topLeading)
        }
        .clipped()
    }

    private func row(_ comment: Comment, isFocused: Bool) -> some View {
        VStack(alignment: .leading, spacing: rem(0.3)) {
            HStack(spacing: rem(0.5)) {
                ThumbnailView(url: comment.authorAvatarURL, fallbacks: [], maxPixel: 120)
                    .frame(width: rem(1.6), height: rem(1.6))
                    .clipShape(Circle())
                Text(comment.author)
                    .font(.system(size: Theme.Metrics.cardMetaSize(viewport), weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text(comment.publishedTime)
                    .font(.system(size: Theme.Metrics.cardMetaSize(viewport) * 0.9))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }

            Text(comment.text)
                .font(.system(size: Theme.Metrics.cardMetaSize(viewport) * 1.05))
                .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !comment.likeCount.isEmpty {
                Label(comment.likeCount, systemImage: "hand.thumbsup")
                    .font(.system(size: Theme.Metrics.cardMetaSize(viewport) * 0.9))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(rem(0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: rem(0.5), style: .continuous)
                    .fill(Theme.surface)
            }
        }
    }
}
