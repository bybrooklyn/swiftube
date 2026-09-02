import Foundation
import Testing
@testable import YouTubeTV

// `GamepadReader.direction` is a pure static function over an axis pair, so the
// stick's feel can be pinned down here rather than by holding a controller.
//
// The deadzone used to be tested per axis — `abs(x) < t && abs(y) < t` — which
// left the diagonals dead: a clean 45° push has a magnitude well past the
// threshold while neither axis alone reaches it.

@Suite("Gamepad direction")
struct GamepadDirectionTests {

    private let press: Float = 0.65
    private let release: Float = 0.40

    private func direction(_ x: Float, _ y: Float, current: MoveDirection? = nil) -> MoveDirection? {
        GamepadReader.direction(x: x, y: y, press: press, release: release, current: current)
    }

    // MARK: - Cardinals

    @Test("a full push in each cardinal direction resolves to that direction")
    func cardinalsResolve() {
        #expect(direction(1, 0) == .right)
        #expect(direction(-1, 0) == .left)
        #expect(direction(0, 1) == .up)      // GameController reports +y as up
        #expect(direction(0, -1) == .down)
    }

    // MARK: - Deadzone

    @Test("a centred stick is no direction")
    func centreIsNil() {
        #expect(direction(0, 0) == nil)
        #expect(direction(0.1, -0.1) == nil)
    }

    @Test("a push just short of the press threshold is ignored")
    func belowPressIsNil() {
        #expect(direction(0.6, 0) == nil)
    }

    @Test("a diagonal push is live once its magnitude crosses the threshold")
    func diagonalsAreNotDead() {
        // 0.5 on each axis: neither reaches 0.65, but the magnitude is 0.707.
        // Per-axis deadzoning returned nil here — the corner was dead.
        #expect(direction(0.5, 0.5) != nil)
        #expect(direction(-0.5, 0.5) != nil)
        #expect(direction(0.5, -0.5) != nil)
        #expect(direction(-0.5, -0.5) != nil)
    }

    @Test("a diagonal below the threshold magnitude is still ignored")
    func shallowDiagonalIsNil() {
        // Magnitude 0.42 — inside the deadzone from centre.
        #expect(direction(0.3, 0.3) == nil)
    }

    // MARK: - Hysteresis

    @Test("a held direction survives down to the lower release threshold")
    func heldSurvivesToRelease() {
        // 0.5 is below press (0.65) but above release (0.40): a stick already
        // deflected keeps its direction rather than chattering.
        #expect(direction(0.5, 0, current: .right) == .right)
    }

    @Test("a held direction is dropped below the release threshold")
    func heldDropsBelowRelease() {
        #expect(direction(0.3, 0, current: .right) == nil)
    }

    @Test("the press threshold applies only from centre")
    func pressAppliesFromCentre() {
        #expect(direction(0.5, 0, current: nil) == nil)
        #expect(direction(0.5, 0, current: .right) == .right)
    }

    // MARK: - Diagonal resolution

    @Test("the dominant axis wins, so a diagonal never fires two moves")
    func dominantAxisWins() {
        #expect(direction(0.9, 0.3) == .right)
        #expect(direction(0.3, 0.9) == .up)
        #expect(direction(-0.9, -0.3) == .left)
        #expect(direction(-0.3, -0.9) == .down)
    }

    @Test("an exact diagonal resolves horizontally rather than flickering")
    func exactDiagonalTiesToHorizontal() {
        #expect(direction(0.8, 0.8) == .right)
        #expect(direction(-0.8, 0.8) == .left)
    }

    @Test("a full-deflection sweep never returns nil")
    func sweepIsAlwaysLive() {
        // Walk the unit circle; at full deflection every angle is a direction.
        for degrees in stride(from: 0, to: 360, by: 15) {
            let radians = Float(Double(degrees) * .pi / 180)
            let x = cos(radians), y = sin(radians)
            #expect(direction(x, y) != nil, "dead at \(degrees)°")
        }
    }
}
