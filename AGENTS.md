# Working in this repo

Read this before touching the build, the playback pipeline, or verification —
the traps below cost real time to rediscover.

## Toolchain

There is **no Xcode on this machine**, only the Command Line Tools, and the
project is built that way deliberately (`Package.swift` + `Scripts/build-app.sh`,
patterned on `../velachat`).

- **`#Preview` and `@Entry` are unavailable** — those macro plugins ship with
  Xcode. `@Observable` works (`libObservationMacros.dylib` is in the CLT).
  Do not add a preview "just to check" a layout; it will not compile.
- **Build against the 26 SDK with `--build-system native`.** The macOS 27 CLT
  (Swift 6.4) defaults to the SwiftBuild backend, which needs `xcstringstool`
  (Xcode-only) for `Localizable.xcstrings`, and its 27.0 SDK makes `@State` a
  macro whose plugin is Xcode-only too — every `@State` in the app fails with
  "plugin for module `SwiftUIMacros` not found". The justfile exports
  `SDKROOT=…/MacOSX26.sdk` and passes the flag; `build-app.sh` does the same.
  A bare `swift build` in this shell hits both walls.
- **`swift test` does not work bare.** Swift Testing lives in
  `/Library/Developer/CommandLineTools/Library/Developer/Frameworks`, and the
  `_Testing_Foundation.framework` in there has an **empty Modules directory**, so
  any test importing `Foundation` *and* `Testing` fails with "no such module
  `_Testing_Foundation`" until cross-import overlay search is disabled. All the
  flags are in the `test` recipe — **always run `just test`**.
- **`--no-parallel` is load-bearing.** The suites inherited from SmartTubeIOS
  share global singletons (`CurrentQueueStore`, the UserDefaults-backed stores).
  Run in parallel they fail a different random 1–4 tests every time, which looks
  exactly like a real regression. Serially, all 904 pass, repeatably.

## Launching and verifying

- **Always launch the bundle with `open`**, never `.build/<config>/YouTubeTV`.
  Running the raw Mach-O produces a live process at 0% CPU with no window — it
  looks precisely like an app bug and is not one.
- `YOUTUBETV_WINDOWED=1 open build/YouTube.app` runs windowed instead of taking
  over the display, which is the only way to screenshot it alongside anything else.
- **A green `swift build` proves nothing about the `.app`.** `build-app.sh`
  asserts every `@rpath` dependency resolves inside the bundle and that
  `yt.solver.*.js` actually arrived in Resources — the n-descrambler loads those
  by name at runtime, and a plain `swift build` never notices they are missing
  because `.build/<config>` *is* the executable's directory there.
- Screenshot by window id; do not try to click:
  ```bash
  /usr/bin/python3 -c "import Quartz; ..."   # kCGWindowOwnerName == 'YouTube'
  screencapture -x -o -l <windowID> out.png
  ```
  Synthetic `CGEventPost` key events *do* work here and are how navigation was
  verified — `key(124)` etc. Mouse clicks and `osascript`/System Events do not.
- `/usr/bin/log stream --predicate 'subsystem == "dev.bybrooklyn.youtubetv"'` is
  the fastest way to see what the playback pipeline is actually doing. Note the
  full path: `log` is shadowed in this shell.

## Signing

`just setup-signing` is not optional. Ad-hoc signing hashes the binary into the
identity, so every rebuild is a different app to the Keychain — and
`AuthService+Keychain.swift` stores the Google OAuth tokens there. Without a
stable identity you re-authenticate after every build.

## The ported pipeline

`YouTubeCore` and `YouTubeMedia` come from SmartTubeIOS. Keep changes there
minimal and commented, so upstream fixes still cherry-pick when YouTube breaks
something. Four classes of change were needed and are worth knowing about:

1. **Swift 6.2 `sending` errors.** `??` takes its right-hand side as an
   autoclosure, and one capturing a non-Sendable `[String: Any]` isolated to the
   `InnerTubeAPI` actor is an error. Fixed with `firstText(in:_:)` in
   `InnerTubeAPI+TextHelpers.swift` and a couple of if/else ladders — prefer
   those over reintroducing `??` chains over renderer dictionaries.
2. **UIKit → AppKit**, in `YouTubeMedia/PlatformShims.swift`. Note that upstream
   gated far more than UIKit behind `#if canImport(UIKit)` — Now Playing, remote
   commands and the AirPlay observer all work on macOS and were compiled out.
   Only `AVAudioSession` is genuinely iOS-only; guards for it are `#if os(iOS)`.
   `DisplaySleep` holds an IOKit power assertion in place of
   `isIdleTimerDisabled`, without which the screen blanks mid-video.
3. **Firebase removed.** `CrashlyticsLogger` → `DiagnosticsLogger`, same API,
   `os.Logger` behind it.
4. **Genuine macOS-specific defects** (see below).

## Playback: how it works, and the trap under it

Playback works: **VISIONOS + HLS, 1080p**. If you are changing the playback
pipeline, know why that is the path, because every other one is a dead end.

`rqh=1` on a googlevideo URL is enforced **by position**. A signed progressive
URL serves a free budget — measured on this machine, exactly 3,276,800 bytes,
about 60 seconds — and then answers `403` for every range past it. That wall
does not move for:

- a `Range:` header, or a `range=` query parameter;
- a freshly re-signed URL from a new `/player` response;
- a BotGuard-minted `pot=` token (it is bound to the WEB visitor session, not
  to the ANDROID_VR one the URL belongs to).

All four were tried and all four were refused at the same offset. Getting past
it with progressive bytes means implementing SABR (`serverAbrStreamingUrl`),
which is its own project.

HLS sidesteps it entirely — segments are short and independently signed — and
the client that hands out a **token-free** HLS manifest is VISIONOS, seeded
first with an ordinary watch-page session (`seedVisionOSSession`). It is tried
at the top of `exhaustiveRetry`.

Two things worth not re-learning:

- **`AVURLAssetHTTPHeaderFieldsKey` does not reach CoreMedia's network stack.**
  A URL signed `c=ANDROID_VR` returns 403 through `AVURLAsset` with the Oculus
  UA set in that option, and 206 through `URLSession` with the identical header.
  That gap is what `YTHLSProxyLoader` closes for HLS and
  `YTProgressiveProxyLoader` closes for progressive MP4.
- **`HLSPlaybackPolicy.resolve` picks the UA from the label.** Its non-HLS
  branch used to return the iOS UA for every client, which 403s any URL signed
  for a different one.

The progressive path survives as a fallback and still hits the 60-second wall by
nature. If VisionOS ever stops returning HLS, that is what you will land on, and
the symptom will be playback that dies after a minute.

## UI conventions

- Focus logic belongs in `Sources/YouTubeTV/Focus/`, as pure functions over value
  types, with tests. Views render `focus`; they never decide where it goes next.
- Two curves, and only two: `Theme.stateChange` (0.15 s ease-out) for a focus ring
  or a colour change, `Theme.travel` (0.3 s) for a row or column actually moving.
  Mixing in a third makes the surface read as several objects instead of one.
  (An earlier version of this file named `Theme.focusSpring`, `.glassEffect` and
  `RailGlass`. None of those survived the rebuild in `f27381e` — do not go looking
  for them.)
- Liquid Glass is available but is used sparingly, and never as an empty wrapper:
  `GlassEffectContainer` only earns its render pass when a child actually applies
  `.glassEffect`. See the note at `GuideRail.swift:47`.
- Do not put full-width glass over playing video. The player's control bar uses a
  gradient scrim and keeps glass for the small button cluster.
