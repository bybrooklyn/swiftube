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
    var onCancel: () -> Void = {}

    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    var body: some View {
        ZStack {
            // Dims the surface behind it so it reads as modal rather than as
            // another card on the page.
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: rem(0.9)) {
                BackChip(label: "Cancel", action: onCancel)
                    .frame(maxWidth: .infinity, alignment: .leading)

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
            // Tinted harder than the player menu so a dialog reads as one tier
            // above a panel, not as another panel.
            .glassPanel(tint: Theme.surface.opacity(0.75),
                        fallback: Theme.surface,
                        corner: Theme.Metrics.sheetCorner(viewport))
        }
    }
}
