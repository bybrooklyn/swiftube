import Foundation

// MARK: - Where focus can live

/// An entry in the guide down the left edge.
///
/// Not `CaseIterable`: the real guide interleaves the user's subscribed channels
/// between the fixed entries, so the list is built at runtime and travels with
/// `BrowseLayout` rather than being a static property of the type.
public enum RailItem: Hashable, Sendable {
    case account
    case search
    case home
    case shorts
    /// A subscribed channel, by channel id.
    case channel(String)
    case subscriptions
    case library
    case news
    case live
    case podcasts
    case music
    case gaming
    case sports
    case settings

    /// The browse section this entry loads, when it maps onto one.
    /// `account`, `search` and `settings` open their own surfaces instead.
    public var sectionTypeName: String? {
        switch self {
        case .home:          "home"
        case .shorts:        "shorts"
        case .subscriptions: "subscriptions"
        case .library:       "playlists"
        case .music:         "music"
        case .gaming:        "gaming"
        case .live:          "live"
        case .news:          "news"
        case .sports:        "sports"
        // Podcasts has no InnerTube browse id of its own; the real client maps
        // it to a search, which the Core layer does not expose as a section.
        case .podcasts:      nil
        case .account, .search, .settings, .channel: nil
        }
    }

    /// The fixed entries, in guide order, with channels omitted. Used as the
    /// signed-out default.
    public static let fixed: [RailItem] = [
        .account, .search, .home, .shorts, .subscriptions, .library,
        .music, .gaming, .live, .news, .podcasts, .sports, .settings,
    ]
}

/// Focus inside the browse surface.
///
/// The player has its own focus space (`PlayerControl`) because it is modal:
/// while it is up, no browse element is reachable.
public enum BrowseFocus: Equatable, Hashable, Sendable {
    case topBar(TopBarItem)
    case rail(RailItem)
    case card(shelf: Int, index: Int)
}

/// The focusable elements of the top bar.
///
/// Only the search pill: the account avatar belongs to the guide, and the bar
/// merely reserves its column as blank space.
public enum TopBarItem: Equatable, Hashable, Sendable, CaseIterable {
    case search
}

/// Sizes of the currently displayed browse surface. The navigator is a pure
/// function of (focus, direction, layout), which is what makes the whole
/// navigation model testable without rendering anything.
public struct BrowseLayout: Equatable, Sendable {
    /// The guide's entries, top to bottom, as currently displayed.
    public var railItems: [RailItem]
    /// Item count for each shelf, in display order. An empty shelf keeps its
    /// slot so indices stay stable while a row is still loading.
    public var shelfSizes: [Int]
    /// Whether a top bar is present to move up into.
    public var hasTopBar: Bool

    public init(railItems: [RailItem] = RailItem.fixed,
                shelfSizes: [Int] = [],
                hasTopBar: Bool = true) {
        self.railItems = railItems
        self.shelfSizes = shelfSizes
        self.hasTopBar = hasTopBar
    }

    /// Shelves that currently have something to focus. A shelf still loading has
    /// no focusable card, so vertical movement must skip it rather than parking
    /// focus on nothing.
    func isFocusable(shelf: Int) -> Bool {
        shelfSizes.indices.contains(shelf) && shelfSizes[shelf] > 0
    }

    var firstFocusableShelf: Int? {
        shelfSizes.indices.first { shelfSizes[$0] > 0 }
    }
}

public enum MoveDirection: Equatable, Sendable {
    case up, down, left, right
}
