import Foundation

/// Owns every input source and funnels them into one callback.
@MainActor
final class InputRouter {

    private let gamepad = GamepadReader()
    private let keyboard = KeyboardReader()
    private let wheel = ScrollWheelReader()

    func start(_ handler: @escaping (NavigationIntent) -> Void) {
        gamepad.start(handler)
        keyboard.start(handler)
        wheel.start(handler)
    }

    func stop() {
        gamepad.stop()
        keyboard.stop()
        wheel.stop()
    }
}
