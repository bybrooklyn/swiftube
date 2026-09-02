import AppKit
import Testing
@testable import YouTubeTV

@Suite("Typed text")
@MainActor
struct TypedTextTests {

    private func event(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    @Test("letters type, including the ones that are shortcuts elsewhere")
    func letters() {
        #expect(KeyboardReader.typedText(for: event("m", keyCode: 46)) == "m")
        #expect(KeyboardReader.typedText(for: event("K", keyCode: 40, modifiers: .shift)) == "K")
        #expect(KeyboardReader.typedText(for: event(" ", keyCode: 49)) == " ")
    }

    @Test("delete is backspace; arrows, return and escape are navigation")
    func navigationKeys() {
        #expect(KeyboardReader.typedText(for: event("\u{7F}", keyCode: 51)) == "\u{8}")
        #expect(KeyboardReader.typedText(for: event("\u{F703}", keyCode: 124)) == nil)   // right arrow
        #expect(KeyboardReader.typedText(for: event("\r", keyCode: 36)) == nil)
        #expect(KeyboardReader.typedText(for: event("\u{1B}", keyCode: 53)) == nil)
        #expect(KeyboardReader.typedText(for: event("a", keyCode: 0, modifiers: .control)) == nil)
    }
}
