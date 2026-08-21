import AppKit
import SwiftUI
import YouTubeMedia

@main
struct YouTubeTVApp: App {

    init() {
        // Headless sign-in.
        //
        // Signing in is what makes the app look like the real client: signed out
        // YouTube returns an empty home feed (the shelves fall back to a plain
        // search), there is no account avatar, no subscriptions, and the player
        // is answered with LOGIN_REQUIRED. This path runs the device-code flow
        // on the command line and exits, so the token lands in the Keychain and
        // every later launch is signed in.
        //
        //   just signin
        if ProcessInfo.processInfo.environment["YOUTUBETV_AUTH"] != nil {
            HeadlessAuth.run()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 1280, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        // Targeted removals, NOT `.commandsRemoved()`.
        //
        // `.commandsRemoved()` strips *every* menu command — including Quit —
        // which left Force Quit as the only way out of the app. A TV app still
        // has no document model and no secondary windows, so those groups go;
        // app termination stays.
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .sidebar) { }
            CommandGroup(replacing: .toolbar) { }
            CommandGroup(replacing: .help) { }
        }
    }
}

/// Runs the OAuth device-code flow on the terminal and exits.
enum HeadlessAuth {

    static func run() -> Never {
        // Line-buffer stdout: this runs from `just`, so it is not a TTY, and
        // block buffering would hold the device code until the process exited —
        // which is exactly when it stops being useful.
        setvbuf(stdout, nil, _IOLBF, 0)

        // A box rather than a captured var: the Task is @MainActor-isolated, so
        // a plain local would be sent across an isolation boundary.
        final class Result: @unchecked Sendable {
            var code: Int32 = 1
            var done = false
        }
        let result = Result()

        Task { @MainActor in
            let auth = AuthService()

            if ProcessInfo.processInfo.environment["YOUTUBETV_SIGNOUT"] != nil {
                auth.signOut()
                print("✅ Signed out.")
                result.code = 0
                result.done = true
                return
            }

            if auth.isSignedIn {
                print("✅ Already signed in as \(auth.accountName ?? "your account").")
                print("   Run `just signout` to sign out.")
                result.code = 0
                result.done = true
                return
            }

            print("▶ Requesting a device code from YouTube…")
            await auth.beginSignIn()

            guard let info = auth.pendingActivation else {
                print("✗ Could not start sign-in: \(auth.error?.localizedDescription ?? "unknown error")")
                result.done = true
                return
            }

            let url = activationURL(info)
            print("")
            print("  ┌──────────────────────────────────────────────┐")
            print("     Go to:   \(info.verificationURL.absoluteString)")
            print("     Enter:   \(info.userCode)")
            print("  └──────────────────────────────────────────────┘")
            print("")
            print("  Opening \(url) in your browser (the code is pre-filled).")
            NSWorkspace.shared.open(URL(string: url) ?? info.verificationURL)
            print("  Waiting for you to approve… (Ctrl-C to cancel)")

            // AuthService polls on its own; watch for the result.
            let deadline = info.expiresAt
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
                if auth.isSignedIn {
                    // Confirm the token actually reached disk before exiting.
                    //
                    // `isSignedIn` flips as soon as the exchange succeeds, but
                    // persistence runs on the TokenManager actor. Exiting on the
                    // flag alone raced that write: sign-in reported success and
                    // the credentials file was still `{}`, so the next launch
                    // was signed out and playback failed with LOGIN_REQUIRED.
                    var persisted = false
                    for _ in 0..<20 {
                        if await auth.tokenManager.currentAccessToken() != nil {
                            persisted = true
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    guard persisted else {
                        print("✗ Signed in, but the credentials could not be saved.")
                        result.done = true
                        return
                    }
                    print("")
                    print("✅ Signed in as \(auth.accountName ?? "your account").")
                    print("   Launch the app with `just open-app`.")
                    result.code = 0
                    result.done = true
                    return
                }
                if let error = auth.error {
                    print("✗ Sign-in failed: \(error.localizedDescription)")
                    result.done = true
                    return
                }
            }
            print("✗ The code expired before it was approved.")
            result.done = true
        }

        // Pump the run loop rather than blocking on a semaphore. AuthService is
        // @MainActor, so its work is scheduled on the main queue — blocking the
        // main thread to wait for it deadlocks: the task can never run.
        while !result.done {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        exit(result.code)
    }

    /// Google pre-fills the code when it is passed on the activation URL.
    private static func activationURL(_ info: AuthService.ActivationInfo) -> String {
        guard var components = URLComponents(url: info.verificationURL, resolvingAgainstBaseURL: false) else {
            return info.verificationURL.absoluteString
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "user_code", value: info.userCode)
        ]
        return components.url?.absoluteString ?? info.verificationURL.absoluteString
    }
}
