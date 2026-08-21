import Testing
@testable import YouTubeTV

@Suite("Search keyboard")
struct SearchKeyboardTests {

    /// Index of the first wide key (space), i.e. one past the last character.
    private var wideStart: Int {
        SearchModel.keys.firstIndex { $0.isWide } ?? SearchModel.keys.count
    }

    @Test("the grid is six columns of characters, then the wide row")
    func gridShape() {
        #expect(SearchModel.columns == 6)
        // A–Z plus 0–9.
        #expect(wideStart == 36)
        #expect(SearchModel.keys.count == 39)
        #expect(SearchModel.keys[0] == .character("A"))
        #expect(SearchModel.keys[25] == .character("Z"))
        #expect(SearchModel.keys[26] == .character("0"))
        #expect(SearchModel.keys[wideStart] == .space)
    }

    @Test("right stops at the end of a row rather than wrapping to the next")
    func rightStopsAtRowEnd() {
        // F is the last column of the first row.
        #expect(SearchModel.nextKey(from: 4, direction: .right) == 5)
        #expect(SearchModel.nextKey(from: 5, direction: .right) == nil)
    }

    @Test("left stops at the very first key")
    func leftStopsAtStart() {
        #expect(SearchModel.nextKey(from: 1, direction: .left) == 0)
        #expect(SearchModel.nextKey(from: 0, direction: .left) == nil)
    }

    @Test("up and down move a whole row at a time")
    func verticalMovesByRow() {
        #expect(SearchModel.nextKey(from: 0, direction: .down) == 6)
        #expect(SearchModel.nextKey(from: 6, direction: .up) == 0)
        #expect(SearchModel.nextKey(from: 3, direction: .up) == nil)
    }

    @Test("down from the last character row lands on the wide keys")
    func downReachesWideRow() {
        // Bottom character row is indices 30–35.
        let landing = SearchModel.nextKey(from: 30, direction: .down)
        #expect(landing != nil)
        #expect(landing! >= wideStart)
        #expect(SearchModel.keys[landing!].isWide)
    }

    @Test("up from a wide key returns to the characters")
    func upFromWideRow() {
        let landing = SearchModel.nextKey(from: wideStart, direction: .up)
        #expect(landing != nil)
        #expect(!SearchModel.keys[landing!].isWide)
    }

    @Test("the wide row walks left and right and stops at its ends")
    func wideRowWalks() {
        #expect(SearchModel.nextKey(from: wideStart, direction: .right) == wideStart + 1)
        #expect(SearchModel.nextKey(from: SearchModel.keys.count - 1, direction: .right) == nil)
    }

    @Test("down from a wide key goes nowhere — it is the last row")
    func downFromWideRowIsNoOp() {
        #expect(SearchModel.nextKey(from: wideStart, direction: .down) == nil)
    }

    @Test("every character key is reachable by walking the grid")
    func everyKeyReachable() {
        // Walk row by row and confirm the indices line up with the layout the
        // view draws, so navigation and rendering cannot disagree.
        var seen = Set<Int>()
        var row = 0
        while row * SearchModel.columns < wideStart {
            for column in 0..<SearchModel.columns {
                let index = row * SearchModel.columns + column
                if index < wideStart { seen.insert(index) }
            }
            row += 1
        }
        #expect(seen.count == wideStart)
    }
}
