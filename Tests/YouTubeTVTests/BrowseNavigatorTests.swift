import Testing
@testable import YouTubeTV

@Suite("BrowseNavigator")
struct BrowseNavigatorTests {

    /// Three shelves of 5, 3 and 4 cards, with a chip row above them.
    private var layout: BrowseLayout {
        BrowseLayout(chipCount: 4, shelfSizes: [5, 3, 4])
    }

    private func move(
        _ focus: BrowseFocus,
        _ directions: [MoveDirection],
        layout: BrowseLayout,
        memory: inout BrowseNavigator.ColumnMemory
    ) -> BrowseFocus {
        var current = focus
        for direction in directions {
            current = BrowseNavigator.next(from: current, direction: direction,
                                           layout: layout, memory: &memory)
        }
        return current
    }

    // MARK: - Opening the guide

    @Test("left from the first card opens the guide rail")
    func leftFromFirstCardOpensGuide() {
        var memory = BrowseNavigator.ColumnMemory()
        let result = BrowseNavigator.next(from: .card(shelf: 0, index: 0), direction: .left,
                                          layout: layout, memory: &memory)
        #expect(result == .rail(.home))
    }

    @Test("left from a later card moves within the row, it does not open the guide")
    func leftFromLaterCardStaysInRow() {
        var memory = BrowseNavigator.ColumnMemory()
        let result = BrowseNavigator.next(from: .card(shelf: 0, index: 3), direction: .left,
                                          layout: layout, memory: &memory)
        #expect(result == .card(shelf: 0, index: 2))
    }

    @Test("left from the first chip opens the guide")
    func leftFromFirstChipOpensGuide() {
        var memory = BrowseNavigator.ColumnMemory()
        let result = BrowseNavigator.next(from: .chip(0), direction: .left,
                                          layout: layout, memory: &memory)
        #expect(result == .rail(.home))
    }

    @Test("right from the guide returns to whatever was focused when it opened")
    func rightFromGuideRestoresContent() {
        var memory = BrowseNavigator.ColumnMemory()
        // Walk to a specific card, open the guide, then come back.
        let card = move(.card(shelf: 0, index: 0), [.right, .right], layout: layout, memory: &memory)
        #expect(card == .card(shelf: 0, index: 2))

        let rail = BrowseNavigator.next(from: card, direction: .left, layout: layout, memory: &memory)
        // Two lefts from index 2 reach index 0; a third opens the guide.
        let backToStart = move(rail, [], layout: layout, memory: &memory)
        _ = backToStart

        var memory2 = BrowseNavigator.ColumnMemory()
        let opened = move(.card(shelf: 0, index: 2), [.left, .left, .left], layout: layout, memory: &memory2)
        #expect(opened == .rail(.home))
        let restored = BrowseNavigator.next(from: opened, direction: .right, layout: layout, memory: &memory2)
        #expect(restored == .card(shelf: 0, index: 0))
    }

    // MARK: - Vertical travel

    @Test("each shelf remembers its own column")
    func shelvesRememberTheirOwnColumn() {
        var memory = BrowseNavigator.ColumnMemory()
        // Move right twice on shelf 0, drop to shelf 1, move right once, then back up.
        var focus = move(.card(shelf: 0, index: 0), [.right, .right], layout: layout, memory: &memory)
        #expect(focus == .card(shelf: 0, index: 2))

        focus = BrowseNavigator.next(from: focus, direction: .down, layout: layout, memory: &memory)
        // Shelf 1 has not been visited, so it starts at its first card — it does
        // NOT inherit shelf 0's column.
        #expect(focus == .card(shelf: 1, index: 0))

        focus = BrowseNavigator.next(from: focus, direction: .right, layout: layout, memory: &memory)
        #expect(focus == .card(shelf: 1, index: 1))

        focus = BrowseNavigator.next(from: focus, direction: .up, layout: layout, memory: &memory)
        // Returning to shelf 0 restores the column we left it on.
        #expect(focus == .card(shelf: 0, index: 2))

        focus = BrowseNavigator.next(from: focus, direction: .down, layout: layout, memory: &memory)
        // And shelf 1 still remembers its own.
        #expect(focus == .card(shelf: 1, index: 1))
    }

    @Test("up from the top shelf reaches the chip row")
    func upFromTopShelfReachesChips() {
        var memory = BrowseNavigator.ColumnMemory()
        let result = BrowseNavigator.next(from: .card(shelf: 0, index: 1), direction: .up,
                                          layout: layout, memory: &memory)
        #expect(result == .chip(0))
    }

    @Test("up from the top shelf is a no-op when the surface has no chips")
    func upFromTopShelfWithoutChipsIsNoOp() {
        var memory = BrowseNavigator.ColumnMemory()
        let noChips = BrowseLayout(chipCount: 0, shelfSizes: [5, 3])
        let result = BrowseNavigator.next(from: .card(shelf: 0, index: 1), direction: .up,
                                          layout: noChips, memory: &memory)
        #expect(result == .card(shelf: 0, index: 1))
    }

    @Test("vertical movement skips shelves that have not loaded yet")
    func verticalMovementSkipsEmptyShelves() {
        var memory = BrowseNavigator.ColumnMemory()
        // Shelf 1 is still loading (zero items) and must not swallow focus.
        let loading = BrowseLayout(chipCount: 0, shelfSizes: [3, 0, 4])
        let down = BrowseNavigator.next(from: .card(shelf: 0, index: 0), direction: .down,
                                        layout: loading, memory: &memory)
        #expect(down == .card(shelf: 2, index: 0))

        let up = BrowseNavigator.next(from: down, direction: .up, layout: loading, memory: &memory)
        #expect(up == .card(shelf: 0, index: 0))
    }

    // MARK: - Edges

    @Test("right at the end of a row stays put")
    func rightAtRowEndStaysPut() {
        var memory = BrowseNavigator.ColumnMemory()
        let result = BrowseNavigator.next(from: .card(shelf: 1, index: 2), direction: .right,
                                          layout: layout, memory: &memory)
        #expect(result == .card(shelf: 1, index: 2))
    }

    @Test("down on the last shelf stays put")
    func downOnLastShelfStaysPut() {
        var memory = BrowseNavigator.ColumnMemory()
        let result = BrowseNavigator.next(from: .card(shelf: 2, index: 0), direction: .down,
                                          layout: layout, memory: &memory)
        #expect(result == .card(shelf: 2, index: 0))
    }

    @Test("guide rail movement stops at both ends")
    func guideRailStopsAtEnds() {
        var memory = BrowseNavigator.ColumnMemory()
        let top = BrowseNavigator.next(from: .rail(.account), direction: .up,
                                       layout: layout, memory: &memory)
        #expect(top == .rail(.account))

        let bottom = BrowseNavigator.next(from: .rail(.settings), direction: .down,
                                          layout: layout, memory: &memory)
        #expect(bottom == .rail(.settings))
    }

    @Test("the guide reopens on the item it was last left on")
    func guideReopensOnLastItem() {
        var memory = BrowseNavigator.ColumnMemory()
        var focus = BrowseNavigator.next(from: .card(shelf: 0, index: 0), direction: .left,
                                         layout: layout, memory: &memory)
        focus = move(focus, [.down, .down], layout: layout, memory: &memory)
        #expect(focus == .rail(.subscriptions))

        focus = BrowseNavigator.next(from: focus, direction: .right, layout: layout, memory: &memory)
        focus = BrowseNavigator.next(from: focus, direction: .left, layout: layout, memory: &memory)
        #expect(focus == .rail(.subscriptions))
    }

    // MARK: - Layout changing underneath focus

    @Test("focus is clamped back into range when a shelf shrinks")
    func focusClampsWhenShelfShrinks() {
        let shrunk = BrowseLayout(chipCount: 4, shelfSizes: [2, 3, 4])
        let result = BrowseNavigator.clamped(.card(shelf: 0, index: 4), to: shrunk)
        #expect(result == .card(shelf: 0, index: 1))
    }

    @Test("focus moves to a neighbouring shelf when its own shelf empties")
    func focusMovesWhenShelfEmpties() {
        let emptied = BrowseLayout(chipCount: 0, shelfSizes: [0, 3])
        let result = BrowseNavigator.clamped(.card(shelf: 0, index: 2), to: emptied)
        #expect(result == .card(shelf: 1, index: 0))
    }

    @Test("focus in the guide is never disturbed by layout changes")
    func guideFocusSurvivesLayoutChange() {
        let empty = BrowseLayout(chipCount: 0, shelfSizes: [])
        #expect(BrowseNavigator.clamped(.rail(.subscriptions), to: empty) == .rail(.subscriptions))
    }
}
