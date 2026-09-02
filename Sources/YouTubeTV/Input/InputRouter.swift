import Foundation

/// Owns both input sources and funnels them into one callback.
@MainActor
final class InputRouter {

    private let gamepad = GamepadReader()
    private let keyboard = KeyboardReader()

    /// See `KeyboardReader.isTextEntryActive`.
    var isTextEntryActive: () -> Bool {
        get { keyboard.isTextEntryActive }
        set { keyboard.isTextEntryActive = newValue }
    }

    /// Controller transport gestures — see `TransportIntent`.
    var onTransport: (TransportIntent) -> Void {
        get { gamepad.transportHandler }
        set { gamepad.transportHandler = newValue }
    }

    func start(_ handler: @escaping (NavigationIntent) -> Void) {
        gamepad.start(handler)
        keyboard.start(handler)
    }

    func stop() {
        gamepad.stop()
        keyboard.stop()
    }
}
