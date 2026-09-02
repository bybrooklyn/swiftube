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

    /// Who currently wants the display kept awake. A `Set` rather than a
    /// plain Bool: this app can have two live `PlaybackViewModel`s at once
    /// (the video player and the Music tab), and a Bool has no way to tell
    /// "still held by the other one" from "nobody wants this anymore" — the
    /// Music tab closing used to release the assertion while a detached PiP
    /// video was still playing. Keyed by the owner's identity so one
    /// instance's own repeated `hold` calls (it does this from several
    /// playback paths) don't double-count against itself.
    private static var holders: Set<ObjectIdentifier> = []

    static var isPrevented: Bool { !holders.isEmpty }

    static func hold(_ owner: AnyObject) {
        let wasEmpty = holders.isEmpty
        holders.insert(ObjectIdentifier(owner))
        guard wasEmpty else { return }

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
            holders.removeAll()
        }
    }

    static func release(_ owner: AnyObject) {
        holders.remove(ObjectIdentifier(owner))
        guard holders.isEmpty, assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
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
