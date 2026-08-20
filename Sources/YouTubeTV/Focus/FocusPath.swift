import Foundation

// MARK: - Where focus can live

/// The items in the guide rail down the left edge, top to bottom.
public enum RailItem: String, CaseIterable, Hashable, Sendable {
    case account
    case search
    case home
    case shorts
    case subscriptions
    case library
    case history
    case settings
}

/// Focus inside the browse surface (guide rail + chips + shelves).
///
/// The player has its own focus space (`PlayerControl`) because it is a modal
/// surface: while it is up, no browse element is reachable.
public enum BrowseFocus: Equatable, Hashable, Sendable {
    case rail(RailItem)
    case chip(Int)
    case card(shelf: Int, index: Int)
}

/// Sizes of the currently displayed browse surface. The navigator is a pure
/// function of (focus, direction, layout), which is what makes the whole
/// navigation model testable without rendering anything.
public struct BrowseLayout: Equatable, Sendable {
    /// Number of category chips above the first shelf. Zero when the surface
    /// has no chip row (Subscriptions, Library, …).
    public var chipCount: Int
    /// Item count for each shelf, in display order. An empty shelf still
    /// occupies a slot so indices stay stable while a row is still loading.
    public var shelfSizes: [Int]

    public init(chipCount: Int = 0, shelfSizes: [Int] = []) {
        self.chipCount = chipCount
        self.shelfSizes = shelfSizes
    }

    /// Shelves that currently have something to focus. A shelf that is still
    /// loading has no focusable card, so vertical movement must skip over it
    /// rather than parking focus on nothing.
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
