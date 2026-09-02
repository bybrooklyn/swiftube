import Foundation

/// Owns both input sources and funnels them into one callback.
@MainActor
final class InputRouter {

    private let gamepad = GamepadReader()
    private let keyboard = KeyboardReader()

    func start(_ handler: @escaping (NavigationIntent) -> Void) {
        gamepad.start(handler)
        keyboard.start(handler)
    }

    func stop() {
        gamepad.stop()
        keyboard.stop()
    }
}
