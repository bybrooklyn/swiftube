import Foundation

/// Pure directional navigation for the browse surface.
///
/// Everything here is a static function over value types so the whole feel of
/// d-pad movement can be pinned down in unit tests — there is no way to check
/// "left from the first card opens the guide" by looking at a screenshot.
///
/// The rules match the YouTube TV/console client rather than SwiftUI's default
/// focus engine, which resolves moves geometrically and gets several of these
/// wrong (notably: it will not open the guide, and it loses each row's
/// remembered column).
public enum BrowseNavigator {

    /// Per-shelf column memory.
    ///
    /// Moving down to a shelf returns to the card that shelf was last left on,
    /// not the column of the shelf you came from. That is the behaviour of the
    /// real client and it is what makes long vertical travel feel unfussy —
    /// scrolling past a row and coming back does not reset it to the start.
    public struct ColumnMemory: Equatable, Sendable {
        var indexByShelf: [Int: Int] = [:]
        /// Where to return when leaving the guide rail.
        var contentFocus: BrowseFocus?
        /// Which rail item to highlight when the guide is opened again.
        var railItem: RailItem = .home

        public init() {}

        func index(forShelf shelf: Int, layout: BrowseLayout) -> Int {
            let remembered = indexByShelf[shelf] ?? 0
            guard layout.isFocusable(shelf: shelf) else { return 0 }
            return min(remembered, layout.shelfSizes[shelf] - 1)
        }

        mutating func remember(_ focus: BrowseFocus) {
            switch focus {
            case let .card(shelf, index):
                indexByShelf[shelf] = index
                contentFocus = focus
            case .topBar:
                contentFocus = focus
            case let .rail(item):
                railItem = item
            }
        }
    }

    /// Returns the focus that a directional press moves to, or the unchanged
    /// focus when the move is a no-op (an edge).
    public static func next(
        from focus: BrowseFocus,
        direction: MoveDirection,
        layout: BrowseLayout,
        memory: inout ColumnMemory
    ) -> BrowseFocus {
        let result = resolve(from: focus, direction: direction, layout: layout, memory: memory)
        memory.remember(result)
        return result
    }

    private static func resolve(
        from focus: BrowseFocus,
        direction: MoveDirection,
        layout: BrowseLayout,
        memory: ColumnMemory
    ) -> BrowseFocus {
        switch focus {

        // MARK: Guide rail
        case let .rail(item):
            let items = layout.railItems
            // The focused entry can vanish under us — the channel list arrives
            // asynchronously and changes on sign-out. Fall back to Home.
            guard let position = items.firstIndex(of: item) else {
                return .rail(items.first(where: { $0 == .home }) ?? items.first ?? item)
            }
            switch direction {
            case .up:
                return position > 0 ? .rail(items[position - 1]) : focus
            case .down:
                return position < items.count - 1 ? .rail(items[position + 1]) : focus
            case .left:
                // The guide is already the leftmost surface.
                return focus
            case .right:
                // Leaving the guide restores whatever was focused when it opened.
                return memory.contentFocus ?? defaultContentFocus(layout: layout)
            }

        // MARK: Top bar
        case let .topBar(item):
            switch direction {
            case .left:
                // Straight to the guide. There is no avatar in the top bar to
                // land on — the account lives at the top of the guide, and the
                // bar only reserves that column as blank space. Focusing it made
                // the highlight vanish and needed a second press to escape.
                _ = item
                return .rail(memory.railItem)
            case .right:
                return focus
            case .down:
                guard let shelf = layout.firstFocusableShelf else { return focus }
                return .card(shelf: shelf, index: memory.index(forShelf: shelf, layout: layout))
            case .up:
                return focus
            }

        // MARK: Shelf cards
        case let .card(shelf, index):
            switch direction {
            case .left:
                return index > 0 ? .card(shelf: shelf, index: index - 1) : .rail(memory.railItem)
            case .right:
                guard layout.isFocusable(shelf: shelf) else { return focus }
                return .card(shelf: shelf, index: min(index + 1, layout.shelfSizes[shelf] - 1))
            case .up:
                if let above = previousFocusableShelf(before: shelf, layout: layout) {
                    return .card(shelf: above, index: memory.index(forShelf: above, layout: layout))
                }
                // Above the topmost shelf sits the search bar.
                return layout.hasTopBar ? .topBar(.search) : focus
            case .down:
                if let below = nextFocusableShelf(after: shelf, layout: layout) {
                    return .card(shelf: below, index: memory.index(forShelf: below, layout: layout))
                }
                return focus
            }
        }
    }

    /// Focus to use when there is no remembered position — the first chip if the
    /// surface has chips, otherwise the first card of the first loaded shelf.
    public static func defaultContentFocus(layout: BrowseLayout) -> BrowseFocus {
        if let shelf = layout.firstFocusableShelf { return .card(shelf: shelf, index: 0) }
        // Rest on the first card even when no shelf has loaded yet.
        //
        // Returning the search pill here meant every transient empty layout —
        // the reload that follows sign-in, or switching guide section — parked
        // focus on the search bar, and `clamped` then preserved it once content
        // arrived. The user was left on the top bar and had to press Down.
        // The navigator already steps over empty shelves, so pointing at the
        // first card is safe before it exists.
        return .card(shelf: 0, index: 0)
    }

    /// Clamps a focus back into range after the layout changes underneath it —
    /// shelves arrive asynchronously, so the focused card can be pulled out from
    /// under the user mid-scroll.
    public static func clamped(_ focus: BrowseFocus, to layout: BrowseLayout) -> BrowseFocus {
        switch focus {
        case .rail:
            return focus
        case .topBar:
            return layout.hasTopBar ? focus : defaultContentFocus(layout: layout)
        case let .card(shelf, index):
            if layout.isFocusable(shelf: shelf) {
                return .card(shelf: shelf, index: min(index, layout.shelfSizes[shelf] - 1))
            }
            if let fallback = nextFocusableShelf(after: shelf, layout: layout)
                ?? previousFocusableShelf(before: shelf, layout: layout) {
                return .card(shelf: fallback, index: 0)
            }
            return defaultContentFocus(layout: layout)
        }
    }

    private static func nextFocusableShelf(after shelf: Int, layout: BrowseLayout) -> Int? {
        guard shelf + 1 < layout.shelfSizes.count else { return nil }
        return (shelf + 1..<layout.shelfSizes.count).first { layout.shelfSizes[$0] > 0 }
    }

    private static func previousFocusableShelf(before shelf: Int, layout: BrowseLayout) -> Int? {
        guard shelf > 0 else { return nil }
        return (0..<shelf).reversed().first { layout.shelfSizes[$0] > 0 }
    }
}
