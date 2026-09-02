import Foundation
import Testing
@testable import YouTubeTV

// The guide column's scroll rule: the anchor row (focused, else the current
// section) is always on screen, with a row of lookahead below it.

@Suite("GuideRail scroll offset")
struct GuideRailScrollTests {

    private let row: CGFloat = 50

    private func offset(anchor index: Int, count: Int, visible: CGFloat) -> CGFloat {
        GuideRail.scrollOffset(anchorTop: CGFloat(index) * row, itemHeight: row,
                               total: CGFloat(count) * row, visible: visible)
    }

    @Test("a list that fits never scrolls")
    func fits() {
        #expect(offset(anchor: 9, count: 10, visible: 600) == 0)
    }

    @Test("rows near the top leave the list where it is")
    func nearTop() {
        #expect(offset(anchor: 0, count: 20, visible: 400) == 0)
        #expect(offset(anchor: 5, count: 20, visible: 400) == 0)
    }

    @Test("a row past the fold scrolls in with one row of lookahead, and the row stays on screen")
    func pastFold() {
        let visible: CGFloat = 400
        for index in 0..<17 {
            let y = CGFloat(index) * row + offset(anchor: index, count: 20, visible: visible)
            #expect(y >= 0 && y + row <= visible, "row \(index) must be inside the visible band")
        }
        #expect(offset(anchor: 10, count: 20, visible: visible) == -(10 * row + 2 * row - visible))
    }

    @Test("the list never scrolls past its end")
    func clampedAtEnd() {
        #expect(offset(anchor: 19, count: 20, visible: 400) == -(20 * row - 400))
    }
}
