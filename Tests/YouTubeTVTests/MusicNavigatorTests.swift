import Testing
@testable import YouTubeTV

@Suite("MusicNavigator")
struct MusicNavigatorTests {

    /// An album page: three action pills, then a stacked list of six tracks,
    /// then a carousel of four related releases.
    private var albumPage: MusicLayout {
        MusicLayout(rowSizes: [3, 6, 4], verticalRows: [1])
    }

    private func move(
        _ focus: MusicFocus,
        _ directions: [MoveDirection],
        layout: MusicLayout,
        memory: inout MusicNavigator.ColumnMemory
    ) -> MusicNavigator.Move {
        var current = MusicNavigator.Move.focus(focus)
        for direction in directions {
            guard case let .focus(position) = current else { return current }
            current = MusicNavigator.next(from: position, direction: direction,
                                          layout: layout, memory: &memory)
        }
        return current
    }

    private func focus(_ move: MusicNavigator.Move) -> MusicFocus? {
        if case let .focus(position) = move { return position }
        return nil
    }

    // MARK: - Horizontal rows

    @Test("Right and left walk a carousel and stop at its ends")
    func horizontalWalk() {
        var memory = MusicNavigator.ColumnMemory()
        let start = MusicFocus(row: 0, column: 0)
        #expect(focus(move(start, [.right], layout: albumPage, memory: &memory))
                == MusicFocus(row: 0, column: 1))
        #expect(focus(move(start, [.right, .right], layout: albumPage, memory: &memory))
                == MusicFocus(row: 0, column: 2))
        // Nothing past the last pill: the press is an edge, not a wrap.
        #expect(move(MusicFocus(row: 0, column: 2), [.right], layout: albumPage, memory: &memory)
                == .none)
        #expect(focus(move(MusicFocus(row: 0, column: 2), [.left], layout: albumPage, memory: &memory))
                == MusicFocus(row: 0, column: 1))
    }

    @Test("Left from the first column hands focus to the guide")
    func leftExits() {
        var memory = MusicNavigator.ColumnMemory()
        #expect(move(MusicFocus(row: 0, column: 0), [.left], layout: albumPage, memory: &memory)
                == .exitLeft)
    }

    // MARK: - Vertical rows

    @Test("Up and down walk inside a track list rather than leaving it")
    func verticalWalk() {
        var memory = MusicNavigator.ColumnMemory()
        let inList = MusicFocus(row: 1, column: 2)
        #expect(focus(move(inList, [.down], layout: albumPage, memory: &memory))
                == MusicFocus(row: 1, column: 3))
        #expect(focus(move(inList, [.up], layout: albumPage, memory: &memory))
                == MusicFocus(row: 1, column: 1))
    }

    @Test("A track list is left only at its ends")
    func verticalEdges() {
        var memory = MusicNavigator.ColumnMemory()
        #expect(focus(move(MusicFocus(row: 1, column: 0), [.up], layout: albumPage, memory: &memory))
                == MusicFocus(row: 0, column: 0))
        #expect(focus(move(MusicFocus(row: 1, column: 5), [.down], layout: albumPage, memory: &memory))
                == MusicFocus(row: 2, column: 0))
    }

    @Test("Left and right in a track list exit or do nothing, never move a row")
    func verticalSidewaysIsNotMovement() {
        var memory = MusicNavigator.ColumnMemory()
        #expect(move(MusicFocus(row: 1, column: 3), [.left], layout: albumPage, memory: &memory)
                == .exitLeft)
        #expect(move(MusicFocus(row: 1, column: 3), [.right], layout: albumPage, memory: &memory)
                == .none)
    }

    // MARK: - Column memory

    @Test("Coming back to a row returns to the cell it was left on")
    func columnMemory() {
        var memory = MusicNavigator.ColumnMemory()
        let layout = MusicLayout(rowSizes: [4, 4, 4])
        var current = MusicFocus(row: 0, column: 0)
        for direction in [MoveDirection.right, .right, .down, .up] {
            guard case let .focus(next) = MusicNavigator.next(
                from: current, direction: direction, layout: layout, memory: &memory) else {
                Issue.record("unexpected edge"); return
            }
            current = next
        }
        #expect(current == MusicFocus(row: 0, column: 2))
    }

    @Test("Remembered columns are clamped to a row that has since shrunk")
    func memoryClamped() {
        var memory = MusicNavigator.ColumnMemory()
        var layout = MusicLayout(rowSizes: [8, 4])
        var current = MusicFocus(row: 0, column: 7)
        memory.remember(current)
        // The carousel reloads with fewer tiles under the focus.
        layout = MusicLayout(rowSizes: [3, 4])
        guard case let .focus(next) = MusicNavigator.next(
            from: MusicFocus(row: 1, column: 0), direction: .up,
            layout: layout, memory: &memory) else {
            Issue.record("expected a move"); return
        }
        current = next
        #expect(current == MusicFocus(row: 0, column: 2))
    }

    // MARK: - Empty and changing layouts

    @Test("Vertical movement steps over rows that have not loaded")
    func skipsEmptyRows() {
        var memory = MusicNavigator.ColumnMemory()
        let layout = MusicLayout(rowSizes: [2, 0, 3])
        #expect(focus(move(MusicFocus(row: 0, column: 0), [.down], layout: layout, memory: &memory))
                == MusicFocus(row: 2, column: 0))
        #expect(focus(move(MusicFocus(row: 2, column: 0), [.up], layout: layout, memory: &memory))
                == MusicFocus(row: 0, column: 0))
    }

    @Test("A move from a row that emptied lands somewhere real")
    func recoversFromEmptiedRow() {
        var memory = MusicNavigator.ColumnMemory()
        let layout = MusicLayout(rowSizes: [0, 3])
        #expect(focus(move(MusicFocus(row: 0, column: 0), [.down], layout: layout, memory: &memory))
                == MusicFocus(row: 1, column: 0))
    }

    @Test("Nothing focusable at all is an edge, not a crash")
    func fullyEmpty() {
        var memory = MusicNavigator.ColumnMemory()
        let layout = MusicLayout(rowSizes: [0, 0])
        for direction in [MoveDirection.up, .down, .left, .right] {
            #expect(MusicNavigator.next(from: MusicFocus(), direction: direction,
                                        layout: layout, memory: &memory) == .none)
        }
        #expect(layout.isEmpty)
    }

    // MARK: - Clamping

    @Test("Clamping pulls focus back into a row that shrank")
    func clampWithinRow() {
        #expect(MusicNavigator.clamped(MusicFocus(row: 1, column: 9),
                                       to: MusicLayout(rowSizes: [3, 4]))
                == MusicFocus(row: 1, column: 3))
    }

    @Test("Clamping moves focus off a row that emptied")
    func clampAcrossRows() {
        #expect(MusicNavigator.clamped(MusicFocus(row: 1, column: 2),
                                       to: MusicLayout(rowSizes: [3, 0, 5]))
                == MusicFocus(row: 2, column: 0))
        #expect(MusicNavigator.clamped(MusicFocus(row: 5, column: 2),
                                       to: MusicLayout(rowSizes: [3]))
                == MusicFocus(row: 0, column: 0))
        #expect(MusicNavigator.clamped(MusicFocus(row: 0, column: 0),
                                       to: MusicLayout(rowSizes: []))
                == MusicFocus(row: 0, column: 0))
    }

    // MARK: - Now playing

    @Test("The now-playing panel is the same grid: transport, tabs, then a list")
    func nowPlayingShape() {
        var memory = MusicNavigator.ColumnMemory()
        let layout = MusicLayout(rowSizes: [5, 2, 12], verticalRows: [2])
        // Down from play/pause reaches the tab strip, then the queue.
        #expect(focus(move(MusicFocus(row: 0, column: 1), [.down], layout: layout, memory: &memory))
                == MusicFocus(row: 1, column: 0))
        #expect(focus(move(MusicFocus(row: 1, column: 1), [.down], layout: layout, memory: &memory))
                == MusicFocus(row: 2, column: 0))
        // And the queue itself walks vertically.
        #expect(focus(move(MusicFocus(row: 2, column: 0), [.down, .down], layout: layout, memory: &memory))
                == MusicFocus(row: 2, column: 2))
    }
}
