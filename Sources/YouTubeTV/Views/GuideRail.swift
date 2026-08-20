import SwiftUI

/// The guide down the left edge: an icon rail that widens into a labelled menu
/// when focus enters it, pushing the content across rather than covering it.
struct GuideRail: View {

    let focus: BrowseFocus
    let isExpanded: Bool

    /// Namespace for the Liquid Glass selection pill. Sharing one
    /// `glassEffectID` across the items makes the pill *travel* between them
    /// instead of fading out in one place and in at another — the difference is
    /// the whole reason to use glass here rather than a plain capsule.
    @Namespace private var glassNamespace

    private var focusedItem: RailItem? {
        if case let .rail(item) = focus { return item }
        return nil
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(RailItem.allCases, id: \.self) { item in
                    row(for: item)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 14)
        }
        .frame(width: isExpanded ? Theme.Metrics.railExpanded : Theme.Metrics.railCollapsed,
               alignment: .leading)
        .frame(maxHeight: .infinity)
        .background {
            // A scrim under the rail so shelf content sliding beneath the glass
            // never makes the labels unreadable.
            LinearGradient(
                colors: [Theme.canvas.opacity(0.96), Theme.canvas.opacity(isExpanded ? 0.88 : 0.0)],
                startPoint: .leading, endPoint: .trailing
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func row(for item: RailItem) -> some View {
        let isFocused = focusedItem == item

        HStack(spacing: 18) {
            Image(systemName: item.symbol)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 30)
            if isExpanded {
                Text(item.title)
                    .font(.system(size: 18, weight: isFocused ? .semibold : .regular))
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Applied only to the focused row. `.glassEffect(.clear, …)` is not the
        // "no glass" case — it still renders a glass shape, which put a chip
        // behind every item and made the collapsed rail read as a button column
        // instead of an icon strip.
        .modifier(RailGlass(isFocused: isFocused, namespace: glassNamespace))
    }
}

/// Glass on the focused row only.
private struct RailGlass: ViewModifier {
    let isFocused: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if isFocused {
            content
                .glassEffect(.regular.tint(.white.opacity(0.16)).interactive(),
                             in: .rect(cornerRadius: 16))
                .glassEffectID("rail.selection", in: namespace)
        } else {
            content
        }
    }
}

extension RailItem {
    var title: String {
        switch self {
        case .account:       "Account"
        case .search:        "Search"
        case .home:          "Home"
        case .shorts:        "Shorts"
        case .subscriptions: "Subscriptions"
        case .library:       "You"
        case .history:       "History"
        case .settings:      "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .account:       "person.crop.circle"
        case .search:        "magnifyingglass"
        case .home:          "house.fill"
        case .shorts:        "play.square.stack.fill"
        case .subscriptions: "rectangle.stack.badge.play.fill"
        case .library:       "person.crop.square.fill"
        case .history:       "clock.arrow.circlepath"
        case .settings:      "gearshape.fill"
        }
    }
}
