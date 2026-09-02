import SwiftUI

/// The in-player settings menu, anchored to the bottom-right above the gear.
///
/// Two columns rather than nested pages: on a d-pad a submenu is expensive to
/// escape, and keeping the value visible next to each category means most trips
/// here are a glance rather than a navigation.
struct PlayerMenuView: View {

    @Bindable var model: PlayerMenuModel
    var onBack: () -> Void = {}
    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    var body: some View {
        VStack(alignment: .leading, spacing: rem(0.6)) {
            BackChip(action: onBack)
            HStack(alignment: .top, spacing: 0) {
                categories
                options
            }
        }
        .padding(rem(1))
        // The "small button cluster over video" case: glass here is sanctioned,
        // and it is the one place the app draws any.
        .glassPanel(tint: .black.opacity(0.55),
                    fallback: .black.opacity(0.92),
                    corner: Theme.Metrics.sheetCorner(viewport))
        // The options column changes length with the category, and the glass
        // shape follows it — animated, so the panel morphs rather than snaps.
        .animation(Theme.travel, value: model.category)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, Theme.Metrics.playerInset(viewport))
        .padding(.bottom, viewport.height * 0.20)
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: rem(0.2)) {
            ForEach(model.categories) { category in
                let isFocused = model.column == .categories && model.category == category
                let isActive = model.category == category

                HStack(spacing: rem(0.7)) {
                    Image(systemName: category.symbol)
                        .font(.system(size: rem(1), weight: .regular))
                        .frame(width: rem(1.4))
                    Text(category.title)
                        .font(.system(size: rem(1.05), weight: .medium))
                    Spacer(minLength: rem(1.5))
                    Text(model.summary(for: category))
                        .font(.system(size: rem(1.0)))
                        .foregroundStyle(isFocused ? Theme.canvas.opacity(0.7) : Theme.textSecondary)
                }
                .foregroundStyle(isFocused ? Theme.canvas : Theme.textPrimary)
                .padding(.horizontal, rem(0.8))
                .frame(height: rem(2.4))
                .frame(width: rem(17), alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Metrics.plateCorner(viewport), style: .continuous)
                        .fill(isFocused ? Theme.focusRing
                              : (isActive ? Theme.control.opacity(0.6) : .clear))
                }
                .animation(Theme.stateChange, value: isFocused)
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: rem(0.2)) {
            ForEach(Array(model.options.enumerated()), id: \.element.id) { index, option in
                let isFocused = model.column == .options && model.optionIndex == index

                HStack(spacing: rem(0.5)) {
                    Image(systemName: option.isSelected ? "checkmark" : "")
                        .font(.system(size: rem(0.9), weight: .semibold))
                        .frame(width: rem(1.1))
                    Text(option.title)
                        .font(.system(size: rem(1.05)))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isFocused ? Theme.canvas : Theme.textPrimary)
                .padding(.horizontal, rem(0.8))
                .frame(height: rem(2.4))
                .frame(width: rem(11), alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Metrics.plateCorner(viewport), style: .continuous)
                        .fill(isFocused ? Theme.focusRing : .clear)
                }
                .animation(Theme.stateChange, value: isFocused)
            }
        }
        .padding(.leading, rem(0.6))
    }
}
