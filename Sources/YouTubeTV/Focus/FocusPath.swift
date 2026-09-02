import Foundation
import YouTubeCore

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
    /// Trending plus every category, as rows on one surface.
    case explore
    /// A playlist's contents, opened from a playlist tile. Carries the title
    /// because the playlist browse response does not return one.
    case playlist(id: String, title: String)
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
        // Backed by the playlists fetch for now; a real Library combines
        // history + playlists + downloads.
        case .library:       "playlists"
        case .music:         "music"
        case .gaming:        "gaming"
        case .live:          "live"
        case .news:          "news"
        case .sports:        "sports"
        // Podcasts has no InnerTube browse id of its own — `FEpodcasts` is not
        // valid, the same way `FEnews` is not (see fetchNews). It is served by a
        // search instead, handled in AppModel.open.
        case .podcasts:      nil
        // Assembled from several fetches in AppModel, not one browse section.
        case .explore, .playlist: nil
        case .account, .search, .settings, .channel: nil
        }
    }

    /// What VoiceOver says when the entry takes focus.
    public func accessibilityLabel(channels: [Channel], accountName: String?) -> String {
        switch self {
        case .account:       accountName ?? "Sign in"
        case .search:        "Search"
        case .home:          "Home"
        case .shorts:        "Shorts"
        case let .channel(id): channels.first { $0.id == id }?.title ?? "Channel"
        case .subscriptions: "Subscriptions"
        case .library:       "Library"
        case .explore:       "Explore"
        case let .playlist(_, title): title
        case .music:         "Music"
        case .gaming:        "Gaming"
        case .live:          "Live"
        case .news:          "News"
        case .podcasts:      "Podcasts"
        case .sports:        "Sports"
        case .settings:      "Settings"
        }
    }

    /// The fixed entries, in guide order, with channels omitted. Used as the
    /// signed-out default.
    public static let fixed: [RailItem] = [
        .account, .search, .home, .shorts, .subscriptions, .library,
        .explore, .music, .gaming, .live, .news, .podcasts, .sports, .settings,
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

/// The focusable elements above the shelves.
///
/// The search pill is the top bar proper — the account avatar belongs to the
/// guide, and the bar merely reserves its column as blank space. `subscribe`
/// is the channel header's button, which sits below the bar and above the
/// shelves, and exists only while a channel surface is showing.
public enum TopBarItem: Equatable, Hashable, Sendable, CaseIterable {
    case search
    case subscribe
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
    /// Whether a channel header with a Subscribe button sits between the top
    /// bar and the shelves.
    public var hasChannelHeader: Bool

    public init(railItems: [RailItem] = RailItem.fixed,
                shelfSizes: [Int] = [],
                hasTopBar: Bool = true,
                hasChannelHeader: Bool = false) {
        self.railItems = railItems
        self.shelfSizes = shelfSizes
        self.hasTopBar = hasTopBar
        self.hasChannelHeader = hasChannelHeader
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
