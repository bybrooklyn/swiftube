import Foundation
import Observation
import YouTubeCore

/// Text entry for a new comment, on the same grid keyboard as search.
///
/// Lower-case letters, digits, and a Post key. There is no shift: a comment
/// typed from a remote is short, and a physical keyboard reaches this the
/// same way it reaches search.
// ponytail: no shift/punctuation; add a symbol row when someone asks for it.
@MainActor
@Observable
final class CommentComposer {

    nonisolated static let keys: [SearchModel.Key] = {
        let characters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
            .map { SearchModel.Key.character(String($0)) }
        return characters + [.space, .backspace, .clear, .submit]
    }()

    private(set) var text = ""
    private(set) var keyIndex = 0
    private(set) var isPosting = false
    /// Why the last post failed, shown under the field. Nil while all is well.
    private(set) var failure: String?

    var canPost: Bool { !isPosting && !text.trimmingCharacters(in: .whitespaces).isEmpty }

    func move(_ direction: MoveDirection) {
        keyIndex = SearchModel.nextKey(from: keyIndex, direction: direction, keys: Self.keys) ?? keyIndex
    }

    /// Applies the focused key. Returns true when Post was pressed with
    /// something to post.
    func select() -> Bool {
        guard Self.keys.indices.contains(keyIndex), !isPosting else { return false }
        failure = nil
        switch Self.keys[keyIndex] {
        case let .character(c): text += c
        case .space:            text += " "
        case .backspace:        if !text.isEmpty { text.removeLast() }
        case .clear:            text = ""
        case .submit:           return canPost
        }
        return false
    }

    func beginPosting() { isPosting = true; failure = nil }

    func fail(_ reason: String) { isPosting = false; failure = reason }
}
