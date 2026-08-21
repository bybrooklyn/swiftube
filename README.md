# SwifTube

A native macOS client for YouTube's **leanback** interface — the ten-foot UI
that ships on televisions and consoles — built in SwiftUI and designed to be
launched from Steam like a game.

It is not a wrapper around the website. Browsing, search, playback, captions,
quality selection and SponsorBlock all run against InnerTube directly, through
a pipeline ported from [SmartTubeIOS](https://github.com/bybrooklyn/SmartTubeIOS).

<sub>Not affiliated with, endorsed by, or sponsored by YouTube or Google LLC.</sub>

---

## What it does

- **The leanback surface.** Guide rail, shelves, search, settings, and a
  full-screen player, laid out from measurements taken off the real client
  rather than approximated. Every metric is a fraction of the viewport, so the
  proportions hold from a 1280-wide window up to a 4K television.
- **Playback** through `AVPlayer`, with adaptive formats, an HLS fallback chain,
  captions, playback speed, and audio-track selection.
- **SponsorBlock**, per category, each set to skip / toast / off.
- **DeArrow** titles where available.
- **Sign-in** over the OAuth device-code flow — no password is typed into the
  app and nothing touches the Keychain.
- **Steam integration** — an installer that registers the app as a
  non-Steam game with generated artwork.

## Requirements

macOS 26 or newer. **Xcode is not required** and is not used: the project builds
with the Command Line Tools via SwiftPM, and `Scripts/build-app.sh` assembles
the `.app` by hand.

## Getting started

```sh
just setup-signing   # once — a stable signing identity
just app             # build the bundle into build/YouTube.app
just signin          # OAuth device code; approve it in a browser
just open-app        # launch
```

`just setup-signing` is not optional. Ad-hoc signing hashes the binary into the
identity, so every rebuild would look like a different app and you would have to
sign in again each time.

To run in a window instead of taking over the display:

```sh
YOUTUBETV_WINDOWED=1 open build/YouTube.app
```

### Steam

```sh
just steam           # build and register as a non-Steam game
just steam-remove    # undo
```

## Controls

Designed for a d-pad first; the keyboard mirrors it, and the pointer works too.

| Action | Key |
|---|---|
| Move | Arrow keys |
| Select | Return |
| Back | Escape / Delete |
| Play / pause | Space or `K` |
| Seek | `J` / `L` |
| Player menu | `M` |
| Quit | ⌘Q |

Back retraces where you have been: it leaves the guide for the content behind
it, returns from a section to the previous one, and opens the guide from home.

The pointer moves focus on hover and activates on click — it drives the same
focus state the d-pad does rather than running a second selection model
alongside it. The window's close / minimise / zoom buttons are hidden until the
pointer reaches the top-left corner.

Many Steam Input templates emit keystrokes rather than a virtual gamepad, so
both paths are supported and any layout works without configuration.

## How it is put together

| Target | Role |
|---|---|
| `YouTubeCore` | InnerTube API, models, browse view models |
| `YouTubeMedia` | Auth, BotGuard/PO tokens, stream resolution, playback |
| `YouTubeTV` | The leanback UI |

`YouTubeCore` and `YouTubeMedia` are kept close to upstream so fixes still
cherry-pick when YouTube changes something. Changes there are deliberately
minimal and commented.

Two conventions in the UI worth knowing:

- **Focus logic lives in `Sources/YouTubeTV/Focus/`**, as pure functions over
  value types, with tests. Views render focus; they never decide where it goes.
- **The guide's icons are drawn as paths**, not SF Symbols
  (`Views/GuideIcons.swift`). YouTube's guide uses its own glyph set — the
  Shorts mark, the Music ring, the Library stack, the Gaming heart — and no SF
  Symbol comes close enough.

## Status

Browsing, search, settings, sign-in, the guide, the player and its menu all
work. Feature parity with the real client is not complete; the gaps are listed
in `CLAUDE.md` alongside the traps worth knowing before changing the build or
the playback pipeline.

**Signed out, YouTube returns an empty home feed**, and the app falls back to a
plain "popular" search — so if the shelves look generic, run `just signin`.

## Tests

```sh
just test
```

825 tests. `--no-parallel` is load-bearing: the suites inherited from
SmartTubeIOS share global singletons and fail randomly when run concurrently.

## Licence

MIT — see [LICENSE](LICENSE), which also carries the upstream notice for the
SmartTube-derived code.
