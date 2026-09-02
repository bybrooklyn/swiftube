import AppKit
import Foundation

/// Turns key presses into the same `NavigationIntent`s the gamepad produces.
///
/// This is not a convenience for desktop use — it is half of the Steam story.
/// Many Steam Input controller templates emit keystrokes rather than a virtual
/// gamepad, and on macOS that is the more reliable of the two paths. Supporting
/// both means any layout works without the user having to configure one.
///
/// Uses a local `NSEvent` monitor rather than SwiftUI's `.onKeyPress` because
/// this app deliberately bypasses SwiftUI's focus engine: with no focused
/// responder, `.onKeyPress` never fires.
@MainActor
final class KeyboardReader {

    private var monitor: Any?
    private var handler: (NavigationIntent) -> Void = { _ in }

    /// Whether a text field has focus right now. While it does, printable keys
    /// become `.text` instead of shortcuts, and Delete becomes backspace.
    var isTextEntryActive: () -> Bool = { false }

    func start(_ handler: @escaping (NavigationIntent) -> Void) {
        // Idempotent: assigning over a live monitor leaks it, and both copies
        // keep firing — every key press producing two intents.
        stop()
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Let anything with a command modifier through to the menu bar so
            // ⌘Q, ⌘W and friends keep working.
            if event.modifierFlags.contains(.command) { return event }
            if self.isTextEntryActive(), let text = Self.typedText(for: event) {
                self.handler(.text(text))
                return nil
            }
            guard let intent = Self.intent(for: event) else { return event }
            self.handler(intent)
            return nil   // swallow it: navigation keys must not also beep
        }
    }

    /// The character a key press types, or backspace; nil for anything that
    /// is navigation rather than typing (arrows, Return, Escape).
    static func typedText(for event: NSEvent) -> String? {
        if event.keyCode == 51 { return "\u{8}" }
        guard !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option),
              let text = event.characters, text.count == 1,
              let scalar = text.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        return text
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func intent(for event: NSEvent) -> NavigationIntent? {
        switch Int(event.keyCode) {
        case 126: return .move(.up)
        case 125: return .move(.down)
        case 123: return .move(.left)
        case 124: return .move(.right)
        case 36, 76: return .select          // Return, keypad Enter
        case 53: return .back                // Escape
        case 49: return .playPause           // Space
        case 51, 117: return .back           // Delete, forward-delete
        case 48: return .tab(forward: !event.modifierFlags.contains(.shift))
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        // WASD: the layout Steam Input templates emit most often. The header
        // above promised it; only the arrows were ever mapped.
        case "w": return .move(.up)
        case "s": return .move(.down)
        case "a": return .move(.left)
        case "d": return .move(.right)
        case "m": return .menu
        case "j": return .seek(.backward)
        case "l": return .seek(.forward)
        case "k": return .playPause
        default: return nil
        }
    }
}
