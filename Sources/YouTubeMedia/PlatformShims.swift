import Foundation
import AppKit
import IOKit.pwr_mgt

/// macOS stand-ins for the UIKit facilities the playback pipeline was written
/// against on iOS.
///
/// SmartTubeIOS gates those calls behind `#if canImport(UIKit)`, which on a
/// native macOS build silently compiles them out — the display would sleep
/// mid-video and the quality ladder would lose its screen-size input. These
/// types restore the behaviour with the AppKit/IOKit equivalents so the call
/// sites stay one line each.

// MARK: - Display sleep

/// Prevents the display from sleeping during playback — the macOS counterpart
/// of `UIApplication.shared.isIdleTimerDisabled`.
///
/// A TV app that lets the screen blank twenty minutes into a film is broken, and
/// there is no automatic equivalent on macOS: AVPlayer only defers *system* idle
/// sleep for its own window, which a Steam-launched borderless window driven by a
/// gamepad cannot be relied on to get. So we hold an explicit IOKit power
/// assertion, released the moment playback stops.
@MainActor
enum DisplaySleep {

    private static var assertionID: IOPMAssertionID = 0

    /// `true` while an assertion is held. Setting it is idempotent: repeated
    /// `true` will not stack assertions (the pipeline sets it from several
    /// playback paths), and repeated `false` is harmless.
    static var isPrevented: Bool = false {
        didSet {
            guard isPrevented != oldValue else { return }
            if isPrevented {
                var id: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypeNoDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "YouTube playback" as CFString,
                    &id
                )
                if result == kIOReturnSuccess {
                    assertionID = id
                } else {
                    // Non-fatal: playback continues, the screen may just dim.
                    isPrevented = false
                }
            } else if assertionID != 0 {
                IOPMAssertionRelease(assertionID)
                assertionID = 0
            }
        }
    }
}

// MARK: - Images

/// `UIImage` on iOS, `NSImage` here. Used for Now Playing artwork, which is the
/// only place the media layer touches an image type at all.
typealias PlatformImage = NSImage

extension NSImage {
    /// `UIImage(data:)` is failable and `NSImage(data:)` is too, but the latter
    /// is not exposed as a designated initializer the same way; this keeps the
    /// call sites identical across platforms.
    convenience init?(platformData data: Data) {
        self.init(data: data)
    }
}

// MARK: - Screen

/// The macOS counterpart of `UIScreen.main.nativeBounds`, used by the fallback
/// path to cap the quality ladder at something the display can actually show.
enum PlatformScreen {

    /// Size of the main display in physical pixels (not points).
    ///
    /// Falls back to 1080p when there is no main screen, which happens when the
    /// process is running without a window server — under a headless test run,
    /// for example. Returning a sane default there keeps quality selection
    /// deterministic instead of collapsing to zero.
    static var nativePixelSize: CGSize {
        guard let screen = NSScreen.main else {
            return CGSize(width: 1920, height: 1080)
        }
        let scale = screen.backingScaleFactor
        return CGSize(width: screen.frame.width * scale,
                      height: screen.frame.height * scale)
    }
}
