#!/usr/bin/env bash
# Build a runnable YouTube.app bundle with SwiftPM and the macOS Command Line
# Tools. Xcode is not required.
#
#   ./Scripts/build-app.sh            # debug build
#   ./Scripts/build-app.sh --release  # release build

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="YouTube"
EXECUTABLE="YouTubeTV"
BUNDLE_ID="dev.bybrooklyn.youtubetv"

SHORT_VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
SHORT_VERSION="${SHORT_VERSION:-1.0.0}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

CONFIG="debug"
if [[ "${1:-}" == "--release" ]]; then
  CONFIG="release"
fi

echo "▶ Building $APP_NAME ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$ROOT/.build/$CONFIG/$EXECUTABLE"
APP="$ROOT/build/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/$EXECUTABLE"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>YouTube</string>
    <key>CFBundleDisplayName</key>
    <string>YouTube</string>
    <key>CFBundleIdentifier</key>
    <string>__BUNDLE_ID__</string>
    <key>CFBundleVersion</key>
    <string>__BUILD_NUMBER__</string>
    <key>CFBundleShortVersionString</key>
    <string>__SHORT_VERSION__</string>
    <key>CFBundleExecutable</key>
    <string>YouTubeTV</string>
    <key>CFBundleIconFile</key>
    <string>YouTubeTV</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.entertainment</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT. Derived from SmartTubeIOS. Not affiliated with YouTube or Google.</string>
</dict>
</plist>
PLIST

/usr/bin/sed -i '' \
  -e "s|__BUNDLE_ID__|$BUNDLE_ID|" \
  -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|" \
  -e "s|__SHORT_VERSION__|$SHORT_VERSION|" \
  "$CONTENTS/Info.plist"

# SwiftPM emits one .bundle per target that declares resources. `Bundle.module`
# resolves them via `Bundle.main.resourceURL`, which inside an .app is
# Contents/Resources — so they have to be copied in, or the n-descrambler dies at
# runtime looking for yt.solver.lib.min.js. A plain `swift build` never shows
# this, because there .build/<config> IS the executable's directory.
shopt -s nullglob
BUNDLES=("$ROOT/.build/$CONFIG"/*.bundle)
for b in "${BUNDLES[@]}"; do
  cp -R "$b" "$RESOURCES/"
done
echo "  copied ${#BUNDLES[@]} resource bundle(s)"

# Assert the resources the media stack loads by name actually arrived. These are
# read at runtime, so a missing one is a crash mid-playback rather than a build
# failure.
for required in yt.solver.lib.min.js yt.solver.core.min.js; do
  if ! find "$RESOURCES" -name "$required" -print -quit | grep -q .; then
    echo "✗ $required is missing from the bundle — playback would fail at runtime." >&2
    exit 1
  fi
done

if [[ ! -f "$ROOT/Resources/$EXECUTABLE.icns" ]]; then
  echo "✗ Resources/$EXECUTABLE.icns is missing — run \`just icon\` to build it." >&2
  exit 1
fi
cp "$ROOT/Resources/$EXECUTABLE.icns" "$RESOURCES/$EXECUTABLE.icns"

# Every @rpath dependency must resolve inside the bundle. A green `swift build`
# proves nothing here: debug builds resolve dylibs out of .build, so only the
# shipped bundle is broken, and only at launch.
MISSING=0
while read -r dep; do
  case "$dep" in
    @rpath/*)
      if [[ ! -f "$CONTENTS/Frameworks/${dep#@rpath/}" && ! -f "$MACOS/${dep#@rpath/}" ]]; then
        echo "✗ Unresolved dependency: $dep" >&2
        MISSING=1
      fi
      ;;
  esac
done < <(otool -L "$MACOS/$EXECUTABLE" | awk 'NR>1 {print $1}')
if [[ "$MISSING" -eq 1 ]]; then
  echo "✗ The bundle would crash at launch — fix the framework copy/rpath above." >&2
  exit 1
fi

# A stable local identity keeps the signature identical across rebuilds. That
# matters more here than in most apps: AuthService stores the Google OAuth
# tokens in the Keychain, and Keychain ties an item's ACL to the exact identity
# that created it. Ad-hoc signing (`codesign --sign -`) hashes the binary into
# the identity, so every rebuild would look like a different app and re-prompt.
IDENTITY="YouTube Local Dev"
if security find-certificate -c "$IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || true
else
  echo "  note: signing ad-hoc — run \`just setup-signing\` once to stop Keychain re-prompts."
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "✅ Built $APP"
echo "   Launch with: open \"$APP\""
