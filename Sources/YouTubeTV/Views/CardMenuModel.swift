import Foundation
import Observation
import YouTubeCore

/// The actions available on a focused card: a short vertical list, opened
/// with Menu (the `m` key, the controller's menu button) and closed with Back.
///
/// Modal over the browse surface in the same way the player menu is modal
/// over the player: while it is up it takes every directional press.
@MainActor
@Observable
final class CardMenuModel {

    struct Row: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let action: () -> Void
    }

    let title: String
    let rows: [Row]
    private(set) var index = 0

    init(title: String, rows: [Row]) {
        self.title = title
        self.rows = rows
    }

    func move(_ direction: MoveDirection) {
        switch direction {
        case .up:   index = max(index - 1, 0)
        case .down: index = min(index + 1, max(rows.count - 1, 0))
        case .left, .right: break
        }
    }

    func hover(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        index = row
    }

    func select() {
        guard rows.indices.contains(index) else { return }
        rows[index].action()
    }
}
