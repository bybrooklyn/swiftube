import Foundation

// MARK: - Music surface focus
//
// Every music page — home, library, an album, an artist, and the now-playing
// panel — is a stack of rows, and a row is a run of focusable cells. Carousels,
// track lists, the header's Play/Shuffle buttons and the now-playing tab strip
// all reduce to that, so there is one navigator instead of five.
//
// Same discipline as `BrowseNavigator`: pure functions over value types, so
// "left from the first tile opens the guide" is a test rather than a screenshot.

/// A cell on a music page.
public struct MusicFocus: Equatable, Hashable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int = 0, column: Int = 0) {
        self.row = row
        self.column = column
    }
}

/// Cell counts per row, top to bottom. A row with zero cells is still present —
/// a carousel that has not loaded yet keeps its slot so indices stay stable —
/// and vertical movement steps over it.
public struct MusicLayout: Equatable, Sendable {
    public var rowSizes: [Int]

    /// Rows whose cells are stacked instead of strung out: a track list. Up and
    /// down walk *inside* one of these and only leave it at its ends, because a
    /// numbered track list that answered to left/right would read as broken
    /// however the movement rules were written.
    public var verticalRows: Set<Int>

    public init(rowSizes: [Int] = [], verticalRows: Set<Int> = []) {
        self.rowSizes = rowSizes
        self.verticalRows = verticalRows
    }

    public var isEmpty: Bool { rowSizes.allSatisfy { $0 == 0 } }

    func isFocusable(row: Int) -> Bool {
        rowSizes.indices.contains(row) && rowSizes[row] > 0
    }

    func isVertical(row: Int) -> Bool { verticalRows.contains(row) }

    var firstFocusableRow: Int? {
        rowSizes.indices.first { rowSizes[$0] > 0 }
    }
}

public enum MusicNavigator {

    /// Per-row column memory, for the same reason the browse surface has one:
    /// coming back down to a carousel should return to the tile it was left on,
    /// not to the column of the row above.
    public struct ColumnMemory: Equatable, Sendable {
        var columnByRow: [Int: Int] = [:]

        public init() {}

        func column(forRow row: Int, layout: MusicLayout) -> Int {
            guard layout.isFocusable(row: row) else { return 0 }
            return min(columnByRow[row] ?? 0, layout.rowSizes[row] - 1)
        }

        mutating func remember(_ focus: MusicFocus) {
            columnByRow[focus.row] = focus.column
        }
    }

    /// What a directional press resolves to.
    public enum Move: Equatable, Sendable {
        case focus(MusicFocus)
        /// Left from the leftmost column: the guide takes over, exactly as it
        /// does from a browse shelf.
        case exitLeft
        /// The press is an edge — nothing moves.
        case none
    }

    public static func next(
        from focus: MusicFocus,
        direction: MoveDirection,
        layout: MusicLayout,
        memory: inout ColumnMemory
    ) -> Move {
        let move = resolve(from: focus, direction: direction, layout: layout, memory: memory)
        if case let .focus(next) = move { memory.remember(next) }
        return move
    }

    private static func resolve(
        from focus: MusicFocus,
        direction: MoveDirection,
        layout: MusicLayout,
        memory: ColumnMemory
    ) -> Move {
        guard layout.isFocusable(row: focus.row) else {
            // The focused row emptied out under us (a page swapped while
            // loading). Land somewhere real rather than refusing to move.
            guard let row = layout.firstFocusableRow else { return .none }
            return .focus(MusicFocus(row: row, column: 0))
        }

        let last = layout.rowSizes[focus.row] - 1

        if layout.isVertical(row: focus.row) {
            switch direction {
            case .up:
                guard focus.column == 0 else {
                    return .focus(MusicFocus(row: focus.row, column: focus.column - 1))
                }
                return step(to: previousFocusableRow(before: focus.row, layout: layout),
                            layout: layout, memory: memory)
            case .down:
                guard focus.column == last else {
                    return .focus(MusicFocus(row: focus.row, column: focus.column + 1))
                }
                return step(to: nextFocusableRow(after: focus.row, layout: layout),
                            layout: layout, memory: memory)
            case .left:
                return .exitLeft
            case .right:
                return .none
            }
        }

        switch direction {
        case .left:
            guard focus.column > 0 else { return .exitLeft }
            return .focus(MusicFocus(row: focus.row, column: focus.column - 1))

        case .right:
            guard focus.column < last else { return .none }
            return .focus(MusicFocus(row: focus.row, column: focus.column + 1))

        case .up:
            return step(to: previousFocusableRow(before: focus.row, layout: layout),
                        layout: layout, memory: memory)

        case .down:
            return step(to: nextFocusableRow(after: focus.row, layout: layout),
                        layout: layout, memory: memory)
        }
    }

    /// Enters `row` at its remembered column, or reports the edge.
    ///
    /// A vertical row is entered at its remembered position too — coming back
    /// down to a track list should land where it was left, exactly as a carousel
    /// does.
    private static func step(to row: Int?, layout: MusicLayout, memory: ColumnMemory) -> Move {
        guard let row else { return .none }
        return .focus(MusicFocus(row: row, column: memory.column(forRow: row, layout: layout)))
    }

    /// Puts focus back in range after a page's rows change underneath it —
    /// shelves and track lists arrive asynchronously.
    public static func clamped(_ focus: MusicFocus, to layout: MusicLayout) -> MusicFocus {
        if layout.isFocusable(row: focus.row) {
            return MusicFocus(row: focus.row, column: min(focus.column, layout.rowSizes[focus.row] - 1))
        }
        if let fallback = nextFocusableRow(after: focus.row, layout: layout)
            ?? previousFocusableRow(before: focus.row, layout: layout) {
            return MusicFocus(row: fallback, column: 0)
        }
        return MusicFocus(row: layout.firstFocusableRow ?? 0, column: 0)
    }

    private static func nextFocusableRow(after row: Int, layout: MusicLayout) -> Int? {
        guard row + 1 < layout.rowSizes.count else { return nil }
        return (row + 1..<layout.rowSizes.count).first { layout.rowSizes[$0] > 0 }
    }

    private static func previousFocusableRow(before row: Int, layout: MusicLayout) -> Int? {
        // Clamped to the array, not just to `row`: a page can shrink under a
        // focus that is already past the end, and searching back from there
        // would index rows that no longer exist.
        let upper = min(row, layout.rowSizes.count)
        guard upper > 0 else { return nil }
        return (0..<upper).reversed().first { layout.rowSizes[$0] > 0 }
    }
}
