# Roadmap — bringing skins fully to life

## Where the project is now

The static half is done. `WMZKit` parses the `.wms` definition, lays out views and
subviews, keys out the transparency colour, derives hit zones from the skin's
mapping images, fits slider geometry from the sprite strips, binds
`wmpprop:` metadata and the `time1…time4` digit strips, and renders all of it into
a shaped window. The players are wired: Apple Music and Spotify over AppleScript,
Tidal through `MediaRemote`, with transport, seek, volume and now-playing metadata
working end to end. What is missing is everything that moves. Only the skin's
primary view is shown, `<playlist>`, equalizer, `<video>` and `<effects>` are
stubbed, and the skin's JScript is parsed for command text but never executed.

## What the archive actually contains

Measured across the 175-skin WMP archive. The counts are what the skins declare,
not what a given skin needs to work.

| Feature | Skin count |
| --- | --- |
| `<effects>` visualizer host | 163 |
| `<playlist>` | 154 |
| Equalizer controls | 159 |
| `<video>` | 162 |
| 3+ views | 84 |
| Timer-driven scripts | 93 |
| `moveTo(...)` animation calls | 130 skins / 1,178 calls |
| `alphaBlendTo(...)` | 44 skins / 857 calls |
| `openView` / `closeView` | 88 / 84 |
| `savePreference` | 97 |
| `theme.openDialog` | 80 |
| Animated GIFs | 110 skins / 4,287 files |
| WAV effects | 23 |
| `eval(...)` inside skin JS | 66 |

There are 5,825 `onClick` handlers in total. Transport is mostly semantic
elements that are already handled. The unhandled bulk is `launchURL` (486),
`returnToMediaCenter` (194), view switches (229) and `openDialog` (36).

## Phase 1 — static UI, fully wired (implemented on `feature/phase-1-panels`)

- **Multi-window view manager.** Views become separate panels instead of one
  window. Each panel is sized from the view's own geometry (typically 406×209),
  positioned per the skin's offsets, and opened and closed by the skin's buttons.
- **Button map completion.** `openView` / `closeView`, `savePreference` tokens,
  `returnToMediaCenter`, `launchURL`, `theme.openDialog` / `openMediaFile`,
  shuffle and repeat, and `playSound` for the smaller WAV effects.
- **`<playlist>` renderer.** Draw the skin's own column set, widths, fonts and
  colours, fed from the Music queue. Read-only in this phase; clicking a row
  jumps playback.
- **Animated GIF playback.** Step the 4,287 GIF frames on their declared delays
  instead of showing frame zero.
- **Album art in `<effects>`.** Use the current track's artwork as the visualizer
  fallback so that panel is not empty.

## Phase 2 — run the skin's JavaScript (implemented on `feature/phase-2-js`)

Embed JavaScriptCore and expose the WMP object model the skins expect:
`player.controls`, `player.settings`, `player.currentMedia`, `player.currentPlaylist`,
`theme`, `view`, `eq`, `mediacenter`, every element id as a global, element
properties (`left`, `top`, `visible`, `alphaBlend`), `moveTo`, `alphaBlendTo`,
`setTimeout` / `setInterval`, `event`, `savePreference` / `loadPreference`, and
`playSound`.

Two facts make this tractable. `document.` appears zero times across the archive,
so there is no DOM to emulate. And JSC provides `eval`, which the 66 skins that
depend on it require.

This unlocks movement animation (130 skins), fades (44) and timer logic (60).
The static engine stays as a fallback: a skin with broken or unsupported script
still renders and still plays. JS exceptions are caught at the call boundary,
logged, and must never terminate the app.

### Phase 2 status

- **Script host implemented.** JavaScriptCore runs the skin's own scripts, so
  timers, `moveTo` and `alphaBlendTo` animate the skin instead of being read
  and discarded.
- **Shared element registry.** All views resolve element ids through one
  registry, so a script that moves or hides an element is seen by every panel.
- **Known gaps.** Script errors that are bugs in the skin itself are not yet
  catalogued, so `scripts/skin-sweep.sh` output has to be read by hand; the
  `<effects>` panel still shows artwork because there is no audio visualizer
  yet; the Music queue fetch moved off the main thread, which keeps the window
  responsive but lets the playlist panel open empty until the fetch lands.
- **Remaining phases.** Phase 3 (visualizer) and Phase 4 (equalizer).

## Phase 3 — visualizer (implemented)

Tap the audio with `AudioHardwareCreateProcessTap` (macOS 14.2+), scoped to the
player's process only so system audio is untouched. Run an FFT through
Accelerate/vDSP and draw bars or a waveform inside the `<effects>` rectangle,
honouring the skin's own colours and `colorBand` hints.

This adds an audio-capture permission prompt. If it is denied or the OS is too
old, fall back to artwork motion in the same rect. No shaders needed initially;
Core Graphics is enough for bar and waveform drawing.

## Phase 4 — equalizer

The sliders already render and persist. They cannot affect another app's audio
without a virtual audio device in the signal path, because macOS offers no API
to process a process tap in place. So the equalizer is cosmetic by default, and
the UI says so rather than pretending otherwise. Real EQ becomes possible only
if a virtual driver is installed and the player routes through it; that is a
documented, opt-in path, not the default.

## Not deliverable

- **WMP visualization plugins (DLLs).** Windows binaries against a COM interface;
  no way to host them.
- **True per-app EQ.** See Phase 4 — needs a virtual audio device, not an API.
- **Spotify / Tidal queues.** Neither exposes queue contents over AppleScript or
  `MediaRemote` in a usable form. `<playlist>` is Music-only.
- **WMP "media center" full mode.** The 10-foot UI is a separate shell, not a
  skin feature, and nothing in the archive depends on it.
