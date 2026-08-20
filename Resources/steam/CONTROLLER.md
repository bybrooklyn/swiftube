# Controller setup

The app reads **both** input paths, so any Steam Input layout works without
configuration:

- **Native gamepad** — `GameController.framework`. Any controller macOS already
  recognises (Xbox, DualSense, MFi), whether connected directly or presented by
  Steam as a virtual pad.
- **Keyboard** — arrow keys, Return, Escape, Space. This is the path a Steam
  Input *keyboard template* drives.

Both reduce to the same `NavigationIntent` stream before anything else sees
them (`Sources/YouTubeTV/Input/`), so neither is a second-class citizen. If one
path is unavailable on your setup, the other still drives the whole UI.

## Default bindings

| Action | Gamepad | Keyboard |
|---|---|---|
| Move focus | D-pad / left stick | Arrow keys |
| Select | A | Return |
| Back / open guide | B | Escape |
| Play / pause | X | Space or K |
| Menu | Y or Menu | M |
| Seek ∓10s | LB / RB | J / L |

## Recommended Steam Input layout

Steam Input on macOS is less reliable at presenting a virtual gamepad than it is
on Windows or Deck. If your controller does nothing in the app:

1. Steam → Library → **YouTube** → controller icon → **Browse Configs**.
2. Pick **Keyboard (WASD) and Mouse**, or any template that emits keystrokes.
3. Map the d-pad to the arrow keys, A to `Return`, B to `Escape`, X to `Space`.

That falls through to the keyboard path above and behaves identically.

## Notes

- Holding a direction repeats after ~400 ms at ~110 ms intervals, matching a TV
  remote's cadence.
- The left stick uses hysteresis (engage 0.65, release 0.40) so a stick resting
  near its edge does not chatter focus back and forth.
- Diagonal pushes resolve to the dominant axis only — a diagonal never moves
  focus twice.
