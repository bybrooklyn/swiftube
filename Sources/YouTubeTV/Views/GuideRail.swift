import SwiftUI
import YouTubeCore

/// The guide down the left edge.
///
/// Every metric here was measured off the real client (1920×1080, 1rem = 24px)
/// rather than estimated, because earlier guesses were consistently wrong:
///
///   * The collapsed rail draws **no highlight at all** — just outline icons on
///     the page background. The selection shape exists only while the guide has
///     focus. Drawing a permanent pill is what made every earlier version look
///     unlike the real thing.
///   * The expanded guide has **no panel colour**; it is the same `#0F0F0F` as
///     the page, and the content simply starts further right.
///   * The focused entry is a **filled `#F1F1F1` rectangle** 18.5rem wide with
///     its icon and label inverted to dark — not a translucent grey pill.
///   * Icons sit at the same x in both states (3.25rem), so opening the guide
///     moves only the labels.
struct GuideRail: View {

    let items: [RailItem]
    let focus: BrowseFocus
    let isExpanded: Bool
    let selected: RailItem
    let channels: [Channel]
    let accountName: String?
    let accountAvatarURL: URL?

    @Environment(\.viewportSize) private var viewport

    /// Namespace for the Liquid Glass highlight, so it travels between entries
    /// rather than fading out in one place and in at another.
    @Namespace private var glass

    private var focusedItem: RailItem? {
        if case let .rail(item) = focus { return item }
        return nil
    }

    /// The highlight is only drawn while the guide holds focus.
    private var guideHasFocus: Bool { focusedItem != nil }

    private var width: CGFloat {
        isExpanded ? Theme.Metrics.railExpanded(viewport) : Theme.Metrics.railCollapsed(viewport)
    }

    var body: some View {
        GeometryReader { geo in
            GlassEffectContainer(spacing: Theme.Metrics.rem(0.2, viewport)) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        if needsDividerBefore(item) { divider }
                        row(for: item)
                            .frame(height: Theme.Metrics.railItemHeight(viewport))
                    }
                }
                .offset(y: scrollOffset(in: geo.size))
                .animation(Theme.travel, value: focusedItem)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.vertical, Theme.Metrics.rem(2.4, viewport))
                .clipped()
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // Opaque, and the same colour as the page. Cards translate left as a row
        // scrolls and would otherwise draw straight through the rail.
        .background(Theme.canvas.ignoresSafeArea())
        .animation(Theme.travel, value: isExpanded)
    }

    private var divider: some View {
        // Width follows the guide's state. Fixed at the expanded pill width it
        // was ~3x wider than the collapsed rail, so the hairlines drew straight
        // across the shelves as two stray lines over the content.
        Rectangle()
            .fill(Theme.divider)
            .frame(width: isExpanded
                   ? Theme.Metrics.railPillWidth(viewport)
                   : Theme.Metrics.railCollapsed(viewport) - Theme.Metrics.railPillLeading(viewport) * 2,
                   height: 1)
            .frame(height: Self.dividerHeight(viewport))
            .padding(.leading, Theme.Metrics.railPillLeading(viewport))
    }

    static func dividerHeight(_ s: CGSize) -> CGFloat { Theme.Metrics.rem(1.0, s) }

    @ViewBuilder
    private func row(for item: RailItem) -> some View {
        let isFocused = focusedItem == item
        // Selection is shown by the same filled shape, but only while the guide
        // is open and focused; with focus in the content the rail is bare.
        let isHighlighted = guideHasFocus && (isFocused || (focusedItem == nil && selected == item))
        let pillHeight = Theme.Metrics.railPillHeight(viewport)
        let iconCentre = Theme.Metrics.railIconCentre(viewport)
        let labelLeading = Theme.Metrics.railLabelLeading(viewport)

        ZStack(alignment: .leading) {
            if isHighlighted {
                RoundedRectangle(cornerRadius: Theme.Metrics.railPillCorner(viewport), style: .continuous)
                    .fill(Theme.focusRing)
                    .frame(width: isExpanded
                           ? Theme.Metrics.railPillWidth(viewport)
                           : pillHeight,
                           height: pillHeight)
                    .padding(.leading, isExpanded
                             ? Theme.Metrics.railPillLeading(viewport)
                             : iconCentre - pillHeight / 2)
                    .glassEffectID("rail.selection", in: glass)
            }

            icon(for: item, size: Theme.Metrics.railIconSize(viewport))
                .frame(width: Theme.Metrics.railIconSize(viewport) * 1.6,
                       height: Theme.Metrics.railIconSize(viewport) * 1.6)
                .position(x: iconCentre, y: Theme.Metrics.railItemHeight(viewport) / 2)

            // Always laid out, revealed by the guide's width — inserting it
            // would re-lay-out the stack and make the icons jump.
            Text(label(for: item))
                .font(.system(size: Theme.Metrics.railLabelSize(viewport),
                              weight: .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, labelLeading)
                .opacity(isExpanded ? 1 : 0)
        }
        .foregroundStyle(isHighlighted ? Theme.canvas : Theme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// Keeps the focused entry inside the visible column.
    ///
    /// Stateless: derived from the focused index each time rather than
    /// accumulated, so it cannot drift out of step with focus. Zero until the
    /// focused row would fall past the bottom, then just enough to bring it back.
    private func scrollOffset(in size: CGSize) -> CGFloat {
        let itemHeight = Theme.Metrics.railItemHeight(viewport)
        let dividerHeight = Self.dividerHeight(viewport)
        let visible = max(size.height - Theme.Metrics.rem(2.4, viewport) * 2, itemHeight)

        var focusedTop: CGFloat = 0
        var total: CGFloat = 0
        for item in items {
            if needsDividerBefore(item) { total += dividerHeight }
            if item == focusedItem { focusedTop = total }
            total += itemHeight
        }

        guard total > visible else { return 0 }
        return -min(max(focusedTop + itemHeight * 2 - visible, 0), total - visible)
    }

    /// Two hairlines: after Shorts, and after Library.
    private func needsDividerBefore(_ item: RailItem) -> Bool {
        switch item {
        case .channel:
            return items.first { if case .channel = $0 { return true }; return false } == item
        case .subscriptions:
            return !items.contains { if case .channel = $0 { return true }; return false }
        case .music:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private func icon(for item: RailItem, size: CGFloat) -> some View {
        switch item {
        case .account:
            AvatarView(url: accountAvatarURL, fallbackSymbol: "person.crop.circle",
                       size: Theme.Metrics.avatarSize(viewport))
        case let .channel(id):
            AvatarView(url: channels.first { $0.id == id }?.thumbnailURL,
                       fallbackSymbol: "person.circle",
                       size: Theme.Metrics.avatarSize(viewport))
        default:
            Image(systemName: symbol(for: item))
                .font(.system(size: size, weight: .regular))
        }
    }

    private func label(for item: RailItem) -> String {
        switch item {
        case .account:       accountName ?? "Sign in"
        case .search:        "Search"
        case .home:          "Home"
        case .shorts:        "Shorts"
        case let .channel(id): channels.first { $0.id == id }?.title ?? "Channel"
        case .subscriptions: "Subscriptions"
        case .library:       "Library"
        case .music:         "Music"
        case .gaming:        "Gaming"
        case .live:          "Live"
        case .news:          "News"
        case .podcasts:      "Podcasts"
        case .sports:        "Sports"
        case .settings:      "Settings"
        }
    }

    /// Outline symbols, not the `.fill` variants — the real guide's icons are
    /// thin strokes.
    private func symbol(for item: RailItem) -> String {
        switch item {
        case .account:       "person.crop.circle"
        case .search:        "magnifyingglass"
        case .home:          "house"
        case .shorts:        "play.rectangle.on.rectangle"
        case .channel:       "person.circle"
        case .subscriptions: "play.square.stack"
        case .library:       "rectangle.stack"
        case .music:         "music.note"
        case .gaming:        "gamecontroller"
        case .live:          "dot.radiowaves.left.and.right"
        case .news:          "newspaper"
        case .podcasts:      "mic"
        case .sports:        "trophy"
        case .settings:      "gearshape"
        }
    }
}

/// A circular avatar with a symbol fallback while it loads or when there is none.
struct AvatarView: View {
    let url: URL?
    let fallbackSymbol: String
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                ThumbnailView(url: url)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.8, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }
}
