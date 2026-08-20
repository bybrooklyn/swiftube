# SwifTube

A native SwiftUI YouTube client for macOS that looks and behaves like the
**YouTube app on TVs and consoles**, rendered in Liquid Glass, dark only, and
launchable as a tile in your Steam library with a controller.

Not affiliated with YouTube or Google.

## Attribution

SwifTube is a derivative work of
**[SmartTubeIOS](https://github.com/bybrooklyn/SmartTubeIOS)** by Milika Delic and
contributors, itself inspired by
[SmartTube](https://github.com/yuliskov/SmartTube) for Android. It is licensed
**GPL-3.0**, the same as its parent — see [LICENSE](LICENSE).

This repository was started from a squashed snapshot rather than a fork, so the
upstream commit history is not present here. Everything under
`Sources/YouTubeCore/` and most of `Sources/YouTubeMedia/` originates from that
project — the InnerTube client, BotGuard/PO-token handling, HLS extraction, the
n-descrambler, SponsorBlock and DeArrow integration, the OAuth device-code flow,
and the AVPlayer loading pipeline. `Sources/YouTubeTV/` is new work: the
leanback UI, focus engine and controller input.

```bash
just setup-signing   # once — keeps the Keychain trusting the app across rebuilds
just app             # build build/YouTube.app
just open-app        # run it
just steam           # add it to Steam (quit Steam first)
```

## What this is

The upstream project is a mature iOS/tvOS YouTube client. Its value is the half
that is *not* UI — InnerTube, BotGuard/PO tokens, HLS extraction, the
n-descrambler, SponsorBlock, DeArrow, OAuth — and it already talks to YouTube as
the `TVHTML5` client, so the feed arrives in the shape the console app receives.
That half is kept. The iOS view layer is replaced with a 10-foot one.

```
Sources/YouTubeCore/    Models, InnerTube API, SponsorBlock, caches. Foundation only.
Sources/YouTubeMedia/   Auth, BotGuard, HLS extraction, AVPlayer pipeline. Ported to macOS.
Sources/YouTubeTV/      The leanback UI: guide rail, shelves, player, focus engine, input.
```

## Building

**Xcode is not required and is not used.** Everything builds with the macOS
Command Line Tools via SwiftPM, and `Scripts/build-app.sh` assembles the `.app`
by hand. Two consequences are worth knowing before you write UI code here:

- **`#Preview` and `@Entry` do not work.** Their macro plugins ship with Xcode,
  not the CLT. (`@Observable` is fine — `libObservationMacros.dylib` does ship.)
  Every UI change therefore costs a `just app` + launch cycle.
- **`swift test` needs extra flags.** Swift Testing lives in
  `/Library/Developer/CommandLineTools/Library/Developer/Frameworks`, outside the
  default search path, and the `_Testing_Foundation` cross-import overlay is
  present but has an empty `Modules` directory, so any test importing both
  `Foundation` and `Testing` fails to build without
  `-disable-cross-import-overlay-search`. `just test` has all of this baked in;
  use it rather than bare `swift test`.

Requires macOS 26+ (Liquid Glass) on Apple Silicon.

## Navigation

Focus is **not** SwiftUI's focus engine. `Sources/YouTubeTV/Focus/` holds a pure
value-type navigator, so the rules that make a TV UI feel right are pinned by
unit tests rather than by eye:

- Pressing **left on the first card opens the guide** — it does not just stop.
- **Each shelf remembers its own column.** Coming back to a row finds it where
  you left it, rather than reset to the start.
- Vertical movement **skips shelves that have not loaded yet**.
- Rows and cards **park at fixed anchors** (a third down the screen, a fixed
  inset from the left). Content moves to meet the focus, never the reverse.

Controls: see [Resources/steam/CONTROLLER.md](Resources/steam/CONTROLLER.md).
Both a native gamepad and keyboard drive the same intent stream, which is what
makes any Steam Input layout work.

## Status

Working: the browse surface (home shelves against the live feed), the focus
engine, gamepad and keyboard input, the guide rail, and the player's chrome —
title, scrubber, glass transport row, auto-hide.

**Playback does not resolve a stream yet.** YouTube currently returns
cipher-protected URLs to every unauthenticated client and answers others with
"Sign in to confirm you're not a bot". The device-code OAuth flow exists in
`YouTubeMedia/Services/AuthService*` but is not yet wired to a sign-in screen;
that is the next piece of work and the most likely fix. See AGENTS.md for the
three defects already fixed along that path and what the logs show.

Not built yet: sign-in UI, Search, Subscriptions, Shorts, Library, Settings,
and the quality/captions/more picker overlays (their controllers already exist
on `PlaybackViewModel`).
