import SwiftUI

/// The visible way out of a panel, menu or sheet.
///
/// Every overlay in this app closes on Back, but Back is a key — Escape, the
/// controller's B — and nothing on screen said so. This chip sits at the top
/// of each one: it names the key for d-pad users and is a target for the
/// pointer. One shape everywhere, so a panel is recognisably a panel.
struct BackChip: View {

    var label = "Back"
    let action: () -> Void

    @Environment(\.viewportSize) private var viewport

    private func rem(_ n: CGFloat) -> CGFloat { Theme.Metrics.rem(n, viewport) }

    var body: some View {
        HStack(spacing: rem(0.35)) {
            Image(systemName: "chevron.left")
                .font(.system(size: rem(0.8), weight: .bold))
            Text(label)
                .font(.system(size: rem(0.9), weight: .semibold))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, rem(0.8))
        .frame(height: rem(2.0))
        .background(Theme.control.opacity(0.6), in: .capsule)
        .contentShape(.capsule)
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
    }
}
