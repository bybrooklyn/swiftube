# YouTube leanback client — task runner
set shell := ["bash", "-c"]

# Swift Testing and XCTest ship inside the Command Line Tools, but outside the
# default search path, so `swift test` cannot find them without these flags.
# The cross-import overlay has to be disabled too: _Testing_Foundation.framework
# is present but its Modules directory is empty in the CLT, so any test file
# importing both Foundation and Testing fails to build without it.
clt_frameworks := "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
test_flags := "-Xswiftc -F -Xswiftc " + clt_frameworks + \
              " -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlay-search" + \
              " -Xlinker -F -Xlinker " + clt_frameworks + \
              " -Xlinker -rpath -Xlinker " + clt_frameworks

default: build

# Compile everything.
build:
    swift build

check:
    swift build

build-release:
    swift build -c release

# --no-parallel is required, not a preference: these suites are inherited from
# SmartTubeIOS, where an Xcode test plan ran them serially. Several share global
# singletons (CurrentQueueStore, the UserDefaults-backed stores), so running them
# in parallel fails a different random handful every time.

# Run the full test suite (serially — see above).
test:
    swift test --no-parallel {{test_flags}}

# One-time: create a stable local signing identity so the Keychain keeps trusting
# the app (and your Google sign-in) across rebuilds.

# One-time signing setup — stops Keychain re-prompts after every rebuild.
setup-signing:
    ./Scripts/setup-signing.sh

# Regenerate the app icon. Committed output (Resources/YouTubeTV.icns) so a
# machine with no window server never has to rasterize it.

# Rebuild the app icon (.icns).
icon:
    swift Scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o Resources/YouTubeTV.icns
    @echo "✅ Resources/YouTubeTV.icns updated — commit it."

# Build build/YouTube.app (release).
app:
    ./Scripts/build-app.sh --release

# Build build/YouTube.app (debug).
app-debug:
    ./Scripts/build-app.sh

# Always launch the bundle, never .build/<config>/YouTubeTV directly — running
# the raw Mach-O produces a live process with no window, which looks exactly
# like an app bug and isn't one.

# Launch the built app bundle.
open-app:
    open "build/YouTube.app"

# Remove .build and build.
clean:
    rm -rf .build build

# Build the bundle and launch it.
smoke: app open-app

# Regenerate Steam library artwork (committed, like the icon).
steam-art:
    swift Scripts/make-steam-art.swift Resources/steam
    @echo "✅ Resources/steam/*.png updated — commit them."

# Add YouTube.app to Steam as a non-Steam game. Steam must be closed: it holds
# shortcuts.vdf in memory and rewrites it on exit, discarding outside edits.

# Build and add YouTube.app to your Steam library (Steam must be closed).
steam: app
    ./Scripts/install-to-steam.py

# Remove the Steam shortcut and its artwork.
steam-remove:
    ./Scripts/install-to-steam.py --remove

# Sign in to YouTube on the command line (device-code flow). Signing in is what
# makes the feed real: signed out, YouTube returns an empty home feed and
# answers the player with LOGIN_REQUIRED.
# Runs the binary *inside the bundle*, not .build/release: macOS scopes Keychain
# items to the signing identity, and the bundle is signed separately — a token
# stored by the loose binary would not be readable by the app.
signin: app
    @YOUTUBETV_AUTH=1 "build/YouTube.app/Contents/MacOS/YouTubeTV"

# Forget the stored account.
signout: app
    @YOUTUBETV_AUTH=1 YOUTUBETV_SIGNOUT=1 "build/YouTube.app/Contents/MacOS/YouTubeTV"
