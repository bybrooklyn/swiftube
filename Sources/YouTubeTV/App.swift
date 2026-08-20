import SwiftUI

@main
struct YouTubeTVApp: App {

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 1280, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        // A TV app has no document model and no secondary windows; leaving the
        // default New Window / tabbing commands in place would let a stray
        // keystroke open a second copy with its own feed and its own player.
        .commandsRemoved()
    }
}
