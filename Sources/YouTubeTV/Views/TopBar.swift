import SwiftUI

/// The bar above the shelves: account avatar, the wide search pill, and the
/// YouTube mark on the right.
///
/// Proportions are measured off the real client — the pill is 37.6% of viewport
/// width and 6.3% of its height, sitting 6.5% down the page.
struct TopBar: View {

    let focus: BrowseFocus
    let accountAvatarURL: URL?
    let isPremium: Bool
    /// The search pill is navigable with the pointer as well as the d-pad.
    var onHover: (TopBarItem) -> Void = { _ in }
    var onSelect: (TopBarItem) -> Void = { _ in }

    @Environment(\.viewportSize) private var viewport

    private var focusedItem: TopBarItem? {
        if case let .topBar(item) = focus { return item }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            // No avatar here: the account entry lives at the top of the guide
            // rail, which is the column this leading inset reserves. The
            // reference has one avatar, not two.
            Color.clear.frame(width: Theme.Metrics.railCollapsed(viewport))

            searchPill

            Spacer(minLength: 0)

            logo
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Metrics.searchPillHeight(viewport))
        .padding(.top, Theme.Metrics.topBarTop(viewport))
        .padding(.trailing, Theme.Metrics.rem(4, viewport))
        .animation(Theme.stateChange, value: focusedItem)
    }

    private var searchPill: some View {
        let height = Theme.Metrics.searchPillHeight(viewport)
        return HStack(spacing: Theme.Metrics.rem(0.5, viewport)) {
            Text("Search")
                .font(.system(size: Theme.Metrics.rem(1.5, viewport), weight: .bold))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.rem(1.375, viewport))
        .frame(width: Theme.Metrics.searchPillWidth(viewport), height: height)
        .background(Theme.control, in: .capsule)
        .overlay {
            Capsule().strokeBorder(Theme.focusRing,
                                   lineWidth: focusedItem == .search
                                       ? Theme.Metrics.focusRingWidth(viewport) : 0)
        }
        .contentShape(.capsule)
        .onHover { inside in if inside { onHover(.search) } }
        .onTapGesture { onSelect(.search) }
    }

    /// Drawn rather than shipped as an asset — there is no asset catalog in this
    /// build (no Xcode), and a red rounded rect with a white triangle is the mark.
    private var logo: some View {
        let height = Theme.Metrics.rem(1.4, viewport)
        return HStack(spacing: height * 0.32) {
            ZStack {
                RoundedRectangle(cornerRadius: height * 0.28)
                    .fill(Theme.brand)
                    .frame(width: height * 1.42, height: height)
                Triangle()
                    .fill(.white)
                    .frame(width: height * 0.34, height: height * 0.40)
                    .offset(x: height * 0.03)
            }
            Text(isPremium ? "Premium" : "YouTube")
                .font(.system(size: height * 1.05, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

/// A right-pointing triangle — the play mark inside the logo.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
