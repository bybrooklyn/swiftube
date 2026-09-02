import SwiftUI

/// The card action menu, centred over a dimmed surface like `ConfirmDialog`.
///
/// Rows are drawn the way the player menu draws its options, so the two
/// menus read as the same kind of object. Must sit inside a `GlassHost`.
struct CardMenuView: View {

    @Bindable var model: CardMenuModel
    var onBack: () -> Void = {}

    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(alignment: .leading, spacing: rem(0.8)) {
                BackChip(action: onBack)

                Text(model.title)
                    .font(.system(size: Theme.Metrics.cardMetaSize(viewport), weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: rem(24), alignment: .leading)

                VStack(alignment: .leading, spacing: rem(0.2)) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        let isFocused = model.index == index
                        HStack(spacing: rem(0.7)) {
                            Image(systemName: row.symbol)
                                .font(.system(size: rem(1), weight: .regular))
                                .frame(width: rem(1.4))
                            Text(row.title)
                                .font(.system(size: rem(1.05), weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(isFocused ? Theme.canvas : Theme.textPrimary)
                        .padding(.horizontal, rem(0.8))
                        .frame(height: rem(2.4))
                        .frame(width: rem(24), alignment: .leading)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Metrics.plateCorner(viewport), style: .continuous)
                                .fill(isFocused ? Theme.focusRing : .clear)
                        }
                        .contentShape(.rect)
                        .animation(Theme.stateChange, value: isFocused)
                    }
                }
            }
            .padding(rem(1.2))
            .glassPanel(tint: Theme.surface.opacity(0.75),
                        fallback: Theme.surface,
                        corner: Theme.Metrics.sheetCorner(viewport))
        }
    }
}
