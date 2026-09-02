import AppKit
import Testing
@testable import YouTubeTV

@MainActor
@Suite("KeyboardReader")
struct KeyboardReaderTests {

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test("WASD moves like the arrows")
    func wasd() {
        #expect(KeyboardReader.intent(for: key("w", code: 13)) == .move(.up))
        #expect(KeyboardReader.intent(for: key("a", code: 0))  == .move(.left))
        #expect(KeyboardReader.intent(for: key("s", code: 1))  == .move(.down))
        #expect(KeyboardReader.intent(for: key("d", code: 2))  == .move(.right))
        #expect(KeyboardReader.intent(for: key("W", code: 13)) == .move(.up))
    }

    @Test("Tab and Shift-Tab traverse")
    func tab() {
        #expect(KeyboardReader.intent(for: key("\t", code: 48)) == .tab(forward: true))
        #expect(KeyboardReader.intent(for: key("\t", code: 48, flags: .shift)) == .tab(forward: false))
    }

    @Test("unmapped keys pass through")
    func unmapped() {
        #expect(KeyboardReader.intent(for: key("x", code: 7)) == nil)
    }

    @Test("tab reduces to a move on single-axis surfaces and is otherwise untouched")
    func asMove() {
        #expect(NavigationIntent.tab(forward: true).asMove(horizontal: true) == .move(.right))
        #expect(NavigationIntent.tab(forward: false).asMove(horizontal: true) == .move(.left))
        #expect(NavigationIntent.tab(forward: true).asMove(horizontal: false) == .move(.down))
        #expect(NavigationIntent.select.asMove(horizontal: true) == .select)
    }
}
