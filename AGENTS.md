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
- **`swift test` does not work bare.** Swift Testing lives in
  `/Library/Developer/CommandLineTools/Library/Developer/Frameworks`, and the
  `_Testing_Foundation.framework` in there has an **empty Modules directory**, so
  any test importing `Foundation` *and* `Testing` fails with "no such module
  `_Testing_Foundation`" until cross-import overlay search is disabled. All the
  flags are in the `test` recipe — **always run `just test`**.
- **`--no-parallel` is load-bearing.** The suites inherited from SmartTubeIOS
  share global singletons (`CurrentQueueStore`, the UserDefaults-backed stores).
  Run in parallel they fail a different random 1–4 tests every time, which looks
  exactly like a real regression. Serially, all 803 pass, repeatably.

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

## Playback: where it stands

Playback **does not yet resolve a stream**. Three real defects were found and
fixed on the way there; none of them alone unblocks it:

- **`requiresDecryption` was a dead end.** `parsePlayerInfo` throws when every
  format URL is cipher-protected, and its own comment says it does so "so the
  caller's fallback chain fires" — but the catch in `loadAsync` only routed
  `signInRequired` and `httpError(403)`, so a cold start (PO token not yet
  minted) surfaced an error instead of retrying. Now a distinct `APIError` case
  routed to `exhaustiveRetry`.
- **`visitorData` was being wiped every ~5 seconds.** `handlePathUpdate` cleared
  it on any satisfied→satisfied `NWPathMonitor` update. A Mac has several
  interfaces up at once and reports those constantly; iOS, with one, is quiet —
  so this was invisible upstream. Now compares actual interface identity.
- **Browse and playback had separate sessions.** `HomeViewModel` and
  `PlaybackViewModel` each defaulted to their own `InnerTubeAPI`, each with its
  own `visitorData` — the identity a PO token is bound to. The player's had none
  at all. `AppModel` now owns one and injects it.

What the logs show now: BotGuard succeeds and mints a 164-byte token, the
fallback chain runs through every client, and YouTube still returns
cipher-protected URLs — answering one client with "Sign in to confirm you're not
a bot". **The next step is wiring the device-code OAuth flow in
`YouTubeMedia/Services/AuthService+DeviceFlow.swift` to a sign-in screen**, not
more work on stream extraction.

## UI conventions

- Focus logic belongs in `Sources/YouTubeTV/Focus/`, as pure functions over value
  types, with tests. Views render `focus`; they never decide where it goes next.
- One spring — `Theme.focusSpring` — for every focus transition. A second curve
  makes the surface read as several objects instead of one.
- `.glassEffect(.clear, …)` is **not** "no glass"; it still draws a glass shape.
  Apply the modifier conditionally instead (see `RailGlass`).
- Do not put full-width glass over playing video. The player's control bar uses a
  gradient scrim and keeps glass for the small button cluster.
