import SwiftUI
import YouTubeCore

/// The guide down the left edge: an icon rail that widens into a labelled menu
/// when focus enters it.
///
/// Structure follows the real client: account · Search · Home · divider ·
/// subscribed channels · Subscriptions · Library · divider · categories ·
/// divider · Settings. The channel entries are what make it feel like the real
/// guide rather than a generic sidebar.
struct GuideRail: View {

    let items: [RailItem]
    let focus: BrowseFocus
    let isExpanded: Bool
    let selected: RailItem
    let channels: [Channel]
    let accountName: String?
    let accountAvatarURL: URL?

    @Environment(\.viewportSize) private var viewport

    /// Namespace for the Liquid Glass focus highlight. Sharing one
    /// `glassEffectID` across entries makes the highlight *travel* between them
    /// instead of fading out in one place and in at another — which is the whole
    /// reason to use glass here rather than a plain capsule.
    @Namespace private var glass

    private var focusedItem: RailItem? {
        if case let .rail(item) = focus { return item }
        return nil
    }

    private var width: CGFloat {
        isExpanded ? Theme.Metrics.railExpanded(viewport) : Theme.Metrics.railCollapsed(viewport)
    }

    var body: some View {
        GeometryReader { geo in
            GlassEffectContainer(spacing: Theme.Metrics.rem(0.2, viewport)) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        if needsDividerBefore(item) {
                            Divider()
                                .overlay(Theme.divider)
                                // Fixed height, matching the constant used by
                                // scrollOffset — if the two drift, the guide
                                // scrolls to the wrong place.
                                .frame(height: Self.dividerHeight(viewport))
                                .padding(.horizontal, Theme.Metrics.rem(0.4, viewport))
                        }
                        row(for: item)
                            .frame(height: Theme.Metrics.railItemHeight(viewport))
                    }
                }
                .padding(.horizontal, Theme.Metrics.rem(0.4, viewport))
                // The guide is taller than the window once a few subscribed
                // channels are in it, so it scrolls to keep the focused entry
                // visible instead of running off the bottom.
                .offset(y: scrollOffset(in: geo.size))
                .animation(Theme.travel, value: focusedItem)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.vertical, Theme.Metrics.rem(1.4, viewport))
                .clipped()
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            // Opaque in both states. Cards translate left as a row scrolls and
            // would otherwise draw straight through a transparent rail —
            // visible as card titles sliding behind the icons. Expanded uses the
            // lighter panel colour; collapsed matches the page so the rail reads
            // as part of the background rather than a floating strip.
            (isExpanded ? Theme.guidePanel : Theme.canvas)
                .ignoresSafeArea()
        }
        .animation(Theme.travel, value: isExpanded)
    }

    private static func dividerHeight(_ s: CGSize) -> CGFloat {
        Theme.Metrics.rem(0.7, s)
    }

    /// Keeps the focused entry inside the visible column.
    ///
    /// Stateless by design: the offset is derived from the focused index each
    /// time rather than accumulated, so it cannot drift out of step with focus.
    /// The result is zero (no scroll) until the focused row would fall past the
    /// bottom, then exactly enough to bring it back with one row of lookahead.
    private func scrollOffset(in size: CGSize) -> CGFloat {
        let itemHeight = Theme.Metrics.railItemHeight(viewport)
        let dividerHeight = Self.dividerHeight(viewport)
        let visible = max(size.height - Theme.Metrics.rem(1.4, viewport) * 2, itemHeight)

        var focusedTop: CGFloat = 0
        var total: CGFloat = 0
        for item in items {
            if needsDividerBefore(item) { total += dividerHeight }
            if item == focusedItem { focusedTop = total }
            total += itemHeight
        }

        guard total > visible else { return 0 }

        // One row of lookahead so the next entry is visible before you land on it.
        let overshoot = focusedTop + itemHeight * 2 - visible
        return -min(max(overshoot, 0), total - visible)
    }

    /// The real guide groups entries with hairlines: after Home, after Library,
    /// and before Settings.
    private func needsDividerBefore(_ item: RailItem) -> Bool {
        // Measured order: [account, Search, Home, Shorts] · channels,
        // Subscriptions, Library · categories … Settings. Two dividers, and
        // Settings is simply the last row rather than sitting behind a third.
        switch item {
        case .channel:
            // Only before the first channel.
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
    private func row(for item: RailItem) -> some View {
        let isFocused = focusedItem == item
        let isSelected = selected == item
        let iconSize = Theme.Metrics.railIconSize(viewport)

        HStack(spacing: Theme.Metrics.rem(1.0, viewport)) {
            icon(for: item, size: iconSize)
                .frame(width: iconSize * 1.6, height: iconSize * 1.6)

            if isExpanded {
                Text(label(for: item))
                    .font(.system(size: Theme.Metrics.railLabelSize(viewport), weight: .medium))
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .foregroundStyle(isFocused ? .black : (isSelected ? Theme.textPrimary : Theme.textTertiary))
        .padding(.horizontal, Theme.Metrics.rem(0.55, viewport))
        .padding(.vertical, Theme.Metrics.rem(0.35, viewport))
        // Collapsed, the pill hugs the icon; expanded, it runs the width of the
        // panel. The real client does this by laying the pill out at its full
        // width and scaling it in X — the visible result is the same, and
        // sizing it directly avoids a transform that would also squash the icon.
        .frame(width: isExpanded ? nil : Theme.Metrics.railCollapsed(viewport)
                                        - Theme.Metrics.rem(1.4, viewport),
               alignment: .leading)
        .frame(maxWidth: isExpanded ? .infinity : nil, alignment: .leading)
        .background {
            // Selection is a flat pill; focus is glass. Drawing them differently
            // is how the real client shows "you are on Home" and "your cursor is
            // here" at the same time.
            if isSelected && !isFocused {
                RoundedRectangle(cornerRadius: Theme.Metrics.railPillCorner(viewport))
                    .fill(Theme.control.opacity(0.7))
            }
        }
        // `.glassEffect(.identity, …)` rather than conditionally applying the
        // modifier: an `if` gives the two branches different structural identity,
        // which destroys the morph. `identity` is the documented no-op variant,
        // so the shape keeps one identity and travels between rows.
        .glassEffect(isFocused ? .regular.tint(.white.opacity(0.18)).interactive() : .identity,
                     in: .rect(cornerRadius: Theme.Metrics.railPillCorner(viewport)))
        .glassEffectID("rail.selection", in: glass)
    }

    @ViewBuilder
    private func icon(for item: RailItem, size: CGFloat) -> some View {
        switch item {
        case .account:
            AvatarView(url: accountAvatarURL, fallbackSymbol: "person.crop.circle", size: Theme.Metrics.avatarSize(viewport))
        case let .channel(id):
            AvatarView(url: channels.first { $0.id == id }?.thumbnailURL,
                       fallbackSymbol: "person.circle", size: Theme.Metrics.avatarSize(viewport))
        default:
            Image(systemName: symbol(for: item))
                .font(.system(size: size, weight: .medium))
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
        case .news:          "News"
        case .live:          "Live"
        case .podcasts:      "Podcasts"
        case .music:         "Music"
        case .gaming:        "Gaming"
        case .sports:        "Sports"
        case .settings:      "Settings"
        }
    }

    private func symbol(for item: RailItem) -> String {
        switch item {
        case .account:       "person.crop.circle"
        case .search:        "magnifyingglass"
        case .home:          "house.fill"
        case .shorts:        "play.rectangle.on.rectangle.fill"
        case .channel:       "person.circle"
        case .subscriptions: "play.square.stack.fill"
        case .library:       "rectangle.stack.fill"
        case .news:          "newspaper.fill"
        case .live:          "dot.radiowaves.left.and.right"
        case .podcasts:      "mic.fill"
        case .music:         "music.note"
        case .gaming:        "gamecontroller.fill"
        case .sports:        "trophy.fill"
        case .settings:      "gearshape.fill"
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
