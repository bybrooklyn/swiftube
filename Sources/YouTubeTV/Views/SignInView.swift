import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import YouTubeMedia

/// The device-code sign-in screen.
///
/// The flow itself is entirely `AuthService`'s: `beginSignIn()` fetches a code
/// and starts polling on its own, and the only completion signal is `isSignedIn`
/// flipping. This view just renders `pendingActivation` and gets out of the way.
///
/// Signing in matters more here than "your subscriptions appear". Signed out,
/// YouTube answers the player with `LOGIN_REQUIRED / "Sign in to confirm you're
/// not a bot"`, and the home feed comes back empty (which is why the shelves
/// fall back to a plain search). Both are gated on this screen.
struct SignInView: View {

    let auth: AuthService
    let onDismiss: () -> Void

    @Environment(\.viewportSize) private var viewport

    var body: some View {
        // A Group with a background, not a ZStack layering content over a
        // Color. As a ZStack the background painted and the content did not,
        // even though the branch was confirmed to render with a valid viewport
        // and a real code. Making the backdrop a `.background` of the content
        // removes the layering question entirely.
        Group {
            if let info = auth.pendingActivation {
                activation(info)
            } else if let error = auth.error {
                failure(error)
            } else {
                ProgressView("Starting sign-in…")
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .task { await auth.beginSignIn() }

        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { onDismiss() }
        }

    }

    private func activation(_ info: AuthService.ActivationInfo) -> some View {
        // Deliberately a plain centred VStack with explicit sizes.
        //
        // The first version laid this out as a two-column HStack whose every
        // dimension was a fraction of the viewport. It rendered — the branch was
        // confirmed taken, with a valid viewport and a real code — but nothing
        // was visible, and chasing which of a dozen derived sizes collapsed was
        // costing more than rebuilding it simply. A sign-in screen has one job:
        // show a URL and a code big enough to read from a sofa.
        VStack(spacing: 28) {
            Text("Sign in to YouTube")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            VStack(spacing: 10) {
                Text("On your phone or computer, go to")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
                Text(verificationText(info))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            VStack(spacing: 10) {
                Text("and enter this code")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
                Text(info.userCode)
                    .font(.system(size: 64, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            }

            QRCodeView(content: activationURL(info))
                .frame(width: 190, height: 190)
                .padding(12)
                .background(.white, in: .rect(cornerRadius: 14))

            Countdown(expiresAt: info.expiresAt) {
                // The code expired — mint a fresh one rather than leaving a dead
                // code on screen.
                Task { await auth.beginSignIn() }
            }

            HStack(spacing: 14) {
                button("Open in browser") { openActivationPage(info) }
                button("Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.userCode, forType: .string)
                }
                button("Cancel") {
                    auth.cancelSignIn()
                    onDismiss()
                }
            }
        }
        // Top-leading with explicit padding, mirroring SettingsView — which
        // renders correctly in this same overlay position. Centring inside an
        // infinite frame is what the earlier version did, and it drew nothing
        // at all while its background still painted.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 96)
        .padding(.top, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

    }

    private func verificationText(_ info: AuthService.ActivationInfo) -> String {
        guard let host = info.verificationURL.host else { return info.verificationURL.absoluteString }
        return host + info.verificationURL.path
    }

    private func failure(_ error: Error) -> some View {
        VStack(spacing: viewport.height * 0.026) {
            Text("Sign-in failed")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(error.localizedDescription)
                .font(.system(size: 20))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 14) {
                button("Try again") {
                    auth.error = nil
                    Task { await auth.beginSignIn() }
                }
                button("Cancel") { onDismiss() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .medium))
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
        // Plain capsule rather than `.buttonStyle(.glass)`. Glass buttons here
        // sit outside any GlassEffectContainer, which Apple warns against, and
        // this screen is the only one in the app that used them.
        .buttonStyle(.plain)
        .background(Theme.control, in: .capsule)
        .foregroundStyle(Theme.textPrimary)
    }

    /// Google accepts `?user_code=` on the activation page and pre-fills the box,
    /// which saves typing the code by hand.
    private func activationURL(_ info: AuthService.ActivationInfo) -> String {
        guard var components = URLComponents(url: info.verificationURL, resolvingAgainstBaseURL: false) else {
            return info.verificationURL.absoluteString
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "user_code", value: info.userCode)
        ]
        return components.url?.absoluteString ?? info.verificationURL.absoluteString
    }

    /// Opens the activation page in the default browser.
    ///
    /// Deliberately `NSWorkspace.open` and not `ASWebAuthenticationSession`:
    /// upstream recorded that the latter crashes reliably on macOS when the user
    /// closes Safari — the SafariLaunchAgent XPC teardown fires off the main
    /// thread and AppKit's sheet dismissal asserts against the main queue. A
    /// device-code grant never needs a redirect callback, so a plain browser
    /// open is both simpler and crash-free.
    private func openActivationPage(_ info: AuthService.ActivationInfo) {
        guard let url = URL(string: activationURL(info)) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Counts the activation code down and reports when it dies.
private struct Countdown: View {
    let expiresAt: Date
    let onExpired: () -> Void

    @State private var remaining: TimeInterval = 0
    @Environment(\.viewportSize) private var viewport

    var body: some View {
        Text(remaining > 0 ? "Code expires in \(clock(remaining))" : "Code expired")
            .font(.system(size: 17))
            .foregroundStyle(Theme.textSecondary)
            .task {
                while !Task.isCancelled {
                    remaining = max(0, expiresAt.timeIntervalSinceNow)
                    if remaining <= 0 {
                        // Give an in-flight poll a moment to land before
                        // discarding a code that may have just been accepted.
                        try? await Task.sleep(for: .seconds(3))
                        onExpired()
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Renders a QR code for the activation URL so a phone can scan it.
///
/// The image is generated **once**, off the body, and the `CIContext` is shared.
///
/// The first version built a `CIContext()` and rasterized the code inside
/// `body`. `Countdown` ticks once a second, which re-evaluated this view — so
/// the app allocated a fresh Metal-backed `CIContext` every second and
/// rasterized a 10×-scaled image through it. The screen rendered correctly and
/// then went black moments later: GPU resources exhausted and the layer stopped
/// painting. A `CIContext` is documented as expensive to create and intended to
/// be long-lived; never build one in a view body.
struct QRCodeView: View {
    let content: String

    @State private var image: Image?

    /// One context for the process.
    private static let context = CIContext()

    var body: some View {
        Group {
            if let image {
                image.interpolation(.none).resizable().scaledToFit()
            } else {
                Color.white
            }
        }
        .task(id: content) {
            image = Self.make(content)
        }
    }

    private static func make(_ content: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.correctionLevel = "M"
        guard let data = content.data(using: .utf8) else { return nil }
        filter.message = data
        guard let output = filter.outputImage else { return nil }
        // Scale up before rasterizing so the code stays crisp at any size.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}
