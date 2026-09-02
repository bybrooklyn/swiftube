# Backlog

Ideas confirmed as wanted but explicitly deferred to a later pass — not part of the
active work tracked in `/Users/brooklyn/.claude/plans/velvet-splashing-steele.md`
(the "Section 9"-style plan covering bugs, Liquid Glass, feature parity, navigation,
premium features, and the YouTube Music track). These came out of a second, later
round of grilling in the same session, after the main plan was already approved and
in flight — the user asked "any more ideas that aren't needed but could be cool or
helpful and opt in?" and this is what survived that pass.

Same north-star principles from the main plan apply whenever these get picked up:
**stay YouTube-authentic** (closely match the real YouTube app's look/layout/density,
improvements layered on top, not a generic redesign) and **"sexy"** — the user's own
word, broken into four confirmed axes: fluid motion, moody/cinematic, tight/responsive,
rich detail. See `user_motives_and_priorities.md` in the project's memory for the full
context on why: the user is building this as their own native-Mac daily driver first
("I wanted the YouTube TV client experience but on my Mac, with rich SwiftUI and hella
features"), with real intent to share it later, prioritizing craft/depth/privacy over
raw reliability *right now* — this backlog leans into that: mostly craft/depth
flourishes, nothing here is a bug fix or a stability item.

---

## Automation

### AppleScript/Shortcuts support via App Intents

Came up when the user asked for "more ideas that aren't needed but could be cool or
helpful and opt in" as a fourth candidate alongside super-resolution, Handoff, and
local-only smart re-ranking. Confirmed scope through grilling:

- **App Intents only** — not a legacy AppleScript dictionary. The user picked this
  explicitly over the broader "App Intents + AppleScript dictionary" option, trading
  compatibility with older automation tools (Keyboard Maestro, raw `osascript`) for a
  smaller, more modern, forward-compatible surface.
- Covers **play/pause/skip, search, add-to-queue**, and a queryable **"now playing"**
  value.
- This makes the app automatically usable from the macOS Shortcuts app, Spotlight, and
  Siri — no custom app-side automation UI needed, App Intents handles discovery.
- Why it made the cut where a "read-only, no remote control" option didn't: the user
  wants real control-surface automation (e.g. a Shortcut that pauses playback when a
  focus mode turns on, or searches for something by voice), not just a "what's
  playing" widget feed.

## Player

### Trickplay scrub preview

This one needed real back-and-forth to land correctly — worth preserving the reasoning
since it's a genuine design tension, not an obvious call:

1. The user initially picked "hover-scrub thumbnail preview (real trickplay)" from a
   list of extra ideas, modeled loosely on YouTube's own desktop hover-scrub.
2. When asked how it should work given mouse navigation was *already removed entirely*
   earlier in this session (per explicit instruction: "remove mouse navigation
   completely. keep keyboard though"), the user initially said "let's just keep what
   youtube tv client does now" — i.e., match the real YouTube TV app's scrub behavior.
3. Research turned up something important: **the real YouTube app on Apple TV has NO
   thumbnail preview at all while scrubbing** — this is a well-documented, often
   complained-about gap versus Netflix/Prime/etc., not a stylistic choice. So "keep
   what YouTube TV does" and "add the thumbnail preview idea already picked" were
   directly in tension.
4. Asked to clarify, the user resolved it precisely: **match the seek INTERACTION
   model** (discrete jumps, hold-to-accelerate — how the real client responds to
   remote/keyboard input) **but still add the thumbnail preview as our own
   improvement** — i.e., don't copy YouTube's gap just because it's authentic; the
   "sexy"/craft goal wins over blind fidelity here, but the *input feel* should still
   match.
5. Thumbnail data source: **use YouTube's real storyboard/sprite data** (what the
   actual InnerTube player response already references, the same data the real
   YouTube web/mobile players use for their own scrub previews) rather than generating
   preview frames locally — authentic, already server-generated, no extra local
   processing cost.

Net design: as you hold a seek direction (keyboard) or use the gamepad scrub wiring
(already planned as idea 7.6 in the main plan — `beginHoldSpeed`/`commitScrub` etc.),
a live thumbnail preview updates from YouTube's real storyboard sprites at the position
you'd land on, using the same discrete-jump/hold-to-accelerate feel the real TV client
already has.

### Custom subtitle positioning

Offered as one of four "batch 2" extra ideas alongside hover-scrub, an audio-reactive
menu-bar icon, and a private watch-stats page (the last of which was NOT selected).
Original framing included font/color/background/karaoke-highlight customization; the
user deliberately narrowed it: **position only**, explicitly rejecting the fuller
styling panel option. Reasoning given implicitly by the choice — this solves the
concrete, common annoyance ("captions cover something I want to see") without the
larger surface area of a full caption-styling system that duplicates what macOS/tvOS
system caption settings already offer.

## Menu bar

**Depends on 7.13** (menu-bar mini-controller) **in the active plan** — this can't be
built before that lands, since there's no menu-bar presence to attach an icon to yet.

### Tiered reactive icon

The user asked specifically to have the two reactivity options *explained concretely*
before picking — a good example of not letting a plausible-sounding option get chosen
without understanding what it actually does:

- **Subtle pulse** (explained as: "the menu-bar icon just gently breathes/pulses at a
  fixed slow rate while something's playing... it doesn't know or care what the music
  actually sounds like, just 'alive vs. idle'") — cheap, no real-time audio analysis.
- **Real waveform-reactive** (explained as: "genuinely reacts to the audio's actual
  levels... tapping the audio engine's output buffer continuously and redrawing the
  icon many times a second") — real, continuous CPU cost for a decorative flourish.

Final answer: **both, tiered** — subtle pulse ships as the default, available to turn
off (opt-out); the real waveform-reactive mode is a separate, heavier option that has
to be explicitly turned ON (opt-in), not on by default, given its real cost. This
mirrors the general pattern in this session of "ship the ambitious thing, but gate the
expensive/risky part behind an explicit choice" (see also: Focus Mode being opt-in in
the main plan, and the Musixmatch lyrics fallback being included with its risk stated
explicitly rather than silently).

## Visual — extends 7.9 (ambient backdrop) in the active plan

### Album-art color blending for Music

The user raised this unprompted while answering a batch-2 extra-ideas question,
tacked onto their selections: "also look at other apps to see what features we could
have. where it like takes the colors of the album cover or something and blends it
in." This is not a new independent feature — it's the same mechanism as 7.9 (ambient
backdrop: dominant color extracted from the focused video thumbnail, tinting the
background behind the rail), just extended to also read from album art once the Music
tab (section 9 of the main plan) exists.

Scope, confirmed via grilling between two options:
- **Chosen**: background/backdrop only — the tint stays behind content, chrome and
  controls stay neutral/readable.
- **Rejected**: extending the tint into accent/control theming (buttons, progress bar,
  focus rings picking up the color too) — more immersive, closer to how some music
  apps go all-in on color theming, but the user picked the more contained option,
  presumably for the same reason 7.9 itself stayed backdrop-only: readability risk
  versus a "which color am I even looking at" muddled UI.

---

## Shelved (not rejected, just not now)

### On-device super-resolution upscaling (Core ML)

Originally pitched as one of four "batch 1" extra ideas (alongside AppleScript/
Shortcuts, Handoff/Continuity, and local-only smart re-ranking — the latter two were
NOT picked and aren't tracked here since they weren't confirmed as wanted). The user
asked for more detail before deciding ("tell me more about that super res one.
maybe...").

Explanation given: a Core ML model running on the Neural Engine to sharpen/upscale
lower-bitrate streams in real time as they decode — helps a 480p fallback stream (e.g.
during network throttling, or an old low-res upload) look better on a big display.
Explicitly flagged as hard: real-time inference synced to every decoded frame without
adding latency, finding/bundling a model fast enough on M-series silicon, and — the
real catch — **it only helps already-low-quality sources**; a proper 1080p/4K stream
gains nothing from it, so it doesn't improve the common case.

After that explanation, the user said plainly: "no super res." Not rejected as a bad
idea — set aside because the effort-to-common-case-payoff ratio is poor relative to
everything else in flight. Worth revisiting specifically if/when downloads or
low-bandwidth playback (bandwidth profiles, idea 7.4 in the main plan) become a real
pain point where upscaling would actually matter more often.

---

## Explicitly rejected (recorded so they don't get re-proposed)

- **Sleep timer.** Not selected when offered alongside ambient backdrop and
  per-channel speed memory earlier in the session.
- **Per-channel playback-speed memory.** Same round, not selected.
- **Decaying/temporary "hide" strength levels.** The user asked directly whether
  YouTube's real API supports this distinction — it doesn't (only a binary
  dismiss/not-interested call exists), and once told that, the user chose to use the
  real binary API as-is rather than build a custom local-only temporary-hide layer on
  top of it.
- **Private local watch-stats page** (total watch time, top channels). Offered
  alongside trickplay, subtitle styling, and the menu-bar icon in "batch 2" — the only
  one of those four NOT selected.
- **Post-download re-encoding to a more efficient format.** The user asked this one
  directly as an exploratory question ("should we add a feature where we re-encode the
  downloaded video... i think no but its worth asking") and I agreed with their own
  instinct: real CPU/time cost plus a second lossy compression pass on top of an
  already-lossy source, for space savings already achievable more cheaply by picking a
  lower quality tier at download time (which the downloads feature, section 6.2 in the
  main plan, already supports as a fixed Settings-level choice).
- **Handoff/Continuity from iPhone/web** and **local-only smarter homepage
  re-ranking.** Offered in the same "batch 1" round as AppleScript/Shortcuts and
  super-resolution; the user picked AppleScript/Shortcuts and asked for more detail on
  super-resolution, but did not select either of these two — treat as not currently
  wanted, distinct from "shelved" (super-res) or "explicitly rejected" (the items
  above) since they simply weren't chosen, not actively discussed and set aside.
