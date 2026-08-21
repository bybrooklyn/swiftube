import Testing
@testable import YouTubeTV

@Suite("BrowseNavigator")
struct BrowseNavigatorTests {

    /// Three shelves of 5, 3 and 4 cards, beneath a top bar.
    private var layout: BrowseLayout {
        BrowseLayout(shelfSizes: [5, 3, 4])
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

    // MARK: - Channel header

    /// A channel surface: same shelves, plus the Subscribe button between the
    /// search bar and the first row.
    private var channelLayout: BrowseLayout {
        BrowseLayout(shelfSizes: [5, 3, 4], hasChannelHeader: true)
    }

    @Test("up from the top shelf reaches the channel header, not the search bar")
    func upFromTopShelfReachesChannelHeader() {
        var memory = BrowseNavigator.ColumnMemory()
        let result = move(.card(shelf: 0, index: 2), [.up], layout: channelLayout, memory: &memory)
        #expect(result == .topBar(.subscribe))
    }

    @Test("without a channel header, up from the top shelf still reaches search")
    func upFromTopShelfReachesSearchWithoutHeader() {
        var memory = BrowseNavigator.ColumnMemory()
        let result = move(.card(shelf: 0, index: 2), [.up], layout: layout, memory: &memory)
        #expect(result == .topBar(.search))
    }

    @Test("the header sits between the search bar and the shelves")
    func headerSitsBetweenSearchAndShelves() {
        var memory = BrowseNavigator.ColumnMemory()
        // Up from the header continues to the search bar.
        #expect(move(.topBar(.subscribe), [.up], layout: channelLayout, memory: &memory)
                == .topBar(.search))
        // And down from search stops at the header rather than skipping it.
        var fresh = BrowseNavigator.ColumnMemory()
        #expect(move(.topBar(.search), [.down], layout: channelLayout, memory: &fresh)
                == .topBar(.subscribe))
    }

    @Test("down from the channel header enters the first shelf")
    func downFromHeaderEntersShelf() {
        var memory = BrowseNavigator.ColumnMemory()
        let result = move(.topBar(.subscribe), [.down], layout: channelLayout, memory: &memory)
        #expect(result == .card(shelf: 0, index: 0))
    }

    @Test("left from the channel header opens the guide")
    func leftFromHeaderOpensGuide() {
        var memory = BrowseNavigator.ColumnMemory()
        let result = move(.topBar(.subscribe), [.left], layout: channelLayout, memory: &memory)
        if case .rail = result {} else {
            Issue.record("expected the guide, got \(result)")
        }
    }

    @Test("up and back down through the header returns to the column it left")
    func headerRoundTripKeepsColumn() {
        var memory = BrowseNavigator.ColumnMemory()
        // Arrive at the column by moving, the way the app does: `ColumnMemory`
        // is written by `next`, so a focus placed directly is not remembered.
        let start = move(.card(shelf: 0, index: 0), [.right, .right, .right],
                         layout: channelLayout, memory: &memory)
        #expect(start == .card(shelf: 0, index: 3))
        let result = move(start, [.up, .down], layout: channelLayout, memory: &memory)
        #expect(result == .card(shelf: 0, index: 3))
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

    @Test("left from the search pill opens the guide in one press")
    func leftFromSearchOpensGuide() {
        var memory = BrowseNavigator.ColumnMemory()
        // One press, not two. There is no avatar in the top bar to stop on —
        // the account entry lives in the guide.
        let rail = BrowseNavigator.next(from: .topBar(.search), direction: .left,
                                        layout: layout, memory: &memory)
        #expect(rail == .rail(.home))
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

    @Test("up from the top shelf reaches the search bar")
    func upFromTopShelfReachesSearch() {
        var memory = BrowseNavigator.ColumnMemory()
        let result = BrowseNavigator.next(from: .card(shelf: 0, index: 1), direction: .up,
                                          layout: layout, memory: &memory)
        #expect(result == .topBar(.search))
    }

    @Test("up from the top shelf is a no-op when there is no top bar")
    func upFromTopShelfWithoutTopBarIsNoOp() {
        var memory = BrowseNavigator.ColumnMemory()
        let bare = BrowseLayout(shelfSizes: [5, 3], hasTopBar: false)
        let result = BrowseNavigator.next(from: .card(shelf: 0, index: 1), direction: .up,
                                          layout: bare, memory: &memory)
        #expect(result == .card(shelf: 0, index: 1))
    }

    @Test("down from the top bar returns to the feed")
    func downFromTopBarReturnsToFeed() {
        var memory = BrowseNavigator.ColumnMemory()
        let result = BrowseNavigator.next(from: .topBar(.search), direction: .down,
                                          layout: layout, memory: &memory)
        #expect(result == .card(shelf: 0, index: 0))
    }

    @Test("a guide entry that disappears does not strand focus")
    func vanishingRailEntryFallsBackToHome() {
        var memory = BrowseNavigator.ColumnMemory()
        // Focus is on a subscribed channel, then the user signs out and the
        // channel list empties underneath them.
        let signedOut = BrowseLayout(railItems: RailItem.fixed, shelfSizes: [5, 3, 4])
        let result = BrowseNavigator.next(from: .rail(.channel("UC-gone")), direction: .down,
                                          layout: signedOut, memory: &memory)
        #expect(result == .rail(.home))
    }

    @Test("vertical movement skips shelves that have not loaded yet")
    func verticalMovementSkipsEmptyShelves() {
        var memory = BrowseNavigator.ColumnMemory()
        // Shelf 1 is still loading (zero items) and must not swallow focus.
        let loading = BrowseLayout(shelfSizes: [3, 0, 4])
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

    @Test("guide movement stops at both ends")
    func guideStopsAtEnds() {
        var memory = BrowseNavigator.ColumnMemory()
        let top = BrowseNavigator.next(from: .rail(.account), direction: .up,
                                       layout: layout, memory: &memory)
        #expect(top == .rail(.account))

        let bottom = BrowseNavigator.next(from: .rail(.settings), direction: .down,
                                          layout: layout, memory: &memory)
        #expect(bottom == .rail(.settings))
    }

    @Test("subscribed channels are reachable in the guide")
    func channelsAreReachable() {
        var memory = BrowseNavigator.ColumnMemory()
        let withChannels = BrowseLayout(
            railItems: [.account, .search, .home, .channel("UC-a"), .channel("UC-b"),
                        .subscriptions, .settings],
            shelfSizes: [5, 3, 4])
        let down = BrowseNavigator.next(from: .rail(.home), direction: .down,
                                        layout: withChannels, memory: &memory)
        #expect(down == .rail(.channel("UC-a")))
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
        let shrunk = BrowseLayout(shelfSizes: [2, 3, 4])
        let result = BrowseNavigator.clamped(.card(shelf: 0, index: 4), to: shrunk)
        #expect(result == .card(shelf: 0, index: 1))
    }

    @Test("focus moves to a neighbouring shelf when its own shelf empties")
    func focusMovesWhenShelfEmpties() {
        let emptied = BrowseLayout(shelfSizes: [0, 3])
        let result = BrowseNavigator.clamped(.card(shelf: 0, index: 2), to: emptied)
        #expect(result == .card(shelf: 1, index: 0))
    }

    @Test("focus in the guide is never disturbed by layout changes")
    func guideFocusSurvivesLayoutChange() {
        let empty = BrowseLayout(shelfSizes: [])
        #expect(BrowseNavigator.clamped(.rail(.subscriptions), to: empty) == .rail(.subscriptions))
    }
}
