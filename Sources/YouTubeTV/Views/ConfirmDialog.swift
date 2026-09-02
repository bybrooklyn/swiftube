import SwiftUI

/// A single-question confirmation, centred over the surface.
///
/// Deliberately not a two-button row: on a d-pad, a row means the destructive
/// option can be one press away again, and which button is focused by default
/// becomes the whole design. Select confirms, Back cancels — the same two keys
/// that already mean yes and no everywhere else in this app — and the prompt
/// says so, so there is nothing to aim at.
struct ConfirmDialog: View {

    let title: String
    let detail: String
    var symbol: String = "questionmark.circle"
    /// With a pointer: the panel is the yes, the dimmed surface behind it the
    /// no — the same two answers, with the destructive one still the one you
    /// have to aim at.
    var onConfirm: () -> Void = {}
    var onCancel: () -> Void = {}

    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    var body: some View {
        ZStack {
            // Dims the surface behind it so it reads as modal rather than as
            // another card on the page.
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(spacing: rem(0.9)) {
                Image(systemName: symbol)
                    .font(.system(size: rem(2.6), weight: .thin))
                    .foregroundStyle(Theme.textTertiary)

                Text(title)
                    .font(.system(size: rem(1.6), weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(detail)
                    .font(.system(size: Theme.Metrics.cardMetaSize(viewport)))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: rem(34))

                Text("Select to confirm · Back to cancel")
                    .font(.system(size: Theme.Metrics.cardMetaSize(viewport)))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, rem(0.4))
            }
            .padding(rem(2.2))
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: rem(1), style: .continuous))
            .contentShape(.rect)
            .onTapGesture { onConfirm() }
        }
    }
}
