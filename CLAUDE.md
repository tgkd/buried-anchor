# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Per-app volume mixer (0–150%) for macOS, built on Core Audio process taps. SwiftPM executable, no
Xcode project, first-party frameworks only. Requires macOS 26+ and a real code-signing identity.

## Build and run

Everything goes through the Makefile; `swift build` alone produces a binary that cannot work (see
below). `IDENTITY` comes from the gitignored `local.mk`.

```
make identities   # list codesigning identities; then: echo 'IDENTITY = <hash>' > local.mk
make run          # debug build -> .build/BuriedAnchor.app -> sign -> open -a
make prod         # release bundle at dist/BuriedAnchor.app
make prod-run     # prod, then launch
make install      # prod, then copy to /Applications
make stop
make logs         # log stream for subsystem com.buriedanchor.mixer
make reset-tcc    # tccutil reset SystemAudioCaptureRequests com.buriedanchor.mixer
```

### Two failure modes that look like broken code

Both produce *silence or zero-filled buffers with no error*, so they are indistinguishable from an
engine bug unless you know about them.

1. **Never launch the inner binary directly** (`.../Contents/MacOS/BuriedAnchor`). TCC attributes
   the system-audio request to the *responsible process*; from a terminal that is the terminal,
   which has no `NSAudioCaptureUsageDescription`, so the request is denied silently — no prompt, and
   every captured sample arrives as `0.0` while the IOProc keeps firing at full rate. Always
   `open -a "$PWD/.build/BuriedAnchor.app"`, which is what `make run` does.
2. **Never ad-hoc sign** (`codesign -s -`). That pins the designated requirement to the binary
   hash, and TCC stores that requirement with the grant, so every rebuild invalidates permission.
   `make sign` refuses to run without `IDENTITY` for this reason.

## Verification

There is no test target. Verification is headless self-test modes inside the app itself, dispatched
from `AppDelegate.applicationDidFinishLaunching` (`SelfTest.swift`), which need real audio playing
and must be launched through `open`:

```
make run                                                    # or make prod
open -a "$PWD/.build/BuriedAnchor.app" --args --selftest afplay 150 [--switch]
open -a "$PWD/.build/BuriedAnchor.app" --args --multi tonePlayerA 50 tonePlayerB 150
open -a "$PWD/.build/BuriedAnchor.app" --args --suspend afplay
open -a "$PWD/.build/BuriedAnchor.app" --args --watch 30
open -a "$PWD/.build/BuriedAnchor.app" --args --loginitem
```

Output goes to `/tmp/buriedanchor-selftest.log` (appended) and to `make logs`. `--selftest` matches
one playing row by substring, boosts/mutes it and optionally switches the default output device
mid-playback; `--multi` needs **two distinct process names** — two instances of one binary collapse
into a single row by design, so make renamed ad-hoc-signed copies of `afplay` as the README shows.
`--watch` just dumps the row list every 3 s, which is how row-grouping/linger behavior gets checked.
`--loginitem` registers and unregisters the login item, printing `SMAppService.mainApp.status` at
each step; it leaves the registration alone if it was already enabled before the run.

## Architecture

`MixerModel` (`@MainActor @Observable`) is the only thing the SwiftUI layer touches. It owns a
`ProcessRegistry` (what apps exist) and a `TapEngine` (what audio actually happens), and drives both
from a single 100 ms timer: every tick refreshes meters, every 10th tick re-snapshots the process
list. Property listeners on `kAudioHardwarePropertyProcessObjectList` and
`kAudioHardwarePropertyDefaultOutputDevice` supplement the poll.

**One aggregate, N taps** — not one aggregate per app. `TapEngine` keeps one `CATapDescription` per
controlled *app* (`.mutedWhenTapped`, private, `processRestoreEnabled`) and puts them all in a single
private aggregate device built around the current default output, with one IOProc.

The load-bearing invariant is the slot mapping:

```
TapEngine.order[i]  ==  kAudioAggregateDeviceTapListKey[i]  ==  input buffer i  ==  renderer slot i
```

That positional identity is the only thing connecting a buffer back to an app. Anything that
reorders `order` without rebuilding the aggregate silently crosses apps' audio.

Two cost tiers, and the difference matters:

- **Changing a gain** is a relaxed atomic store into `MixRenderer.targets[slot]`. No rebuild, no
  lock, no glitch.
- **Adding or removing a controlled app** tears down the IOProc, destroys and recreates the
  aggregate, and recomputes every slot — briefly interrupting all other controlled apps. Same path
  runs on a default-output-device change.

An app is untapped and bit-transparent until its slider first leaves 100%, then keeps its tap for
the session. `MixRenderer.maxSlots` (32) caps controlled apps.

**Suspension** is the third tier. When every controlled app sits at exactly 100%, `MixerModel`
counts 15 ticks (1.5 s) and calls `engine.suspend()`, which tears down the IOProc but keeps the taps
and the aggregate. `.mutedWhenTapped` only mutes while a running IOProc consumes the tap, so this
hands every app back its own bit-transparent output and makes macOS drop the purple system-audio
indicator — verified with `--suspend`. Resume is `startIO()` on the surviving aggregate, so slot
mapping and gains are untouched; any gain leaving 1.0 resumes immediately, before the next tick.
This is why percentages are rounded in `setPercent` and on load: a slider left at 100.19% reads as
"100%" but is not `gain == 1`, so it would hold a tap and keep the indicator lit forever.

`MixerModel.reset(_:)` is the *only* caller of `engine.release`, so it is the only path back out of
the graph and the only way to free a slot. It is reached from the row's right-click menu — not from
the slider, and deliberately not from returning the slider to 100%, since that would rebuild the
aggregate whenever the slider crossed 100. Don't remove it without providing another release path.
Mute is a plain `setPercent(0,)` with the pre-mute level stashed in `premute`; it keeps the tap.

### Realtime callback (`Render.swift`)

`MixRenderer.render` runs on the Core Audio IO thread: **no allocation, no locks, no logging, no
Foundation**. Gains cross the thread boundary only through `Atomic<Float>`; meters and clip counts
come back the same way via `exchange(0)`. It clears the single output buffer, then for each slot does
gain-and-sum in one pass with `vDSP_vrampmuladd`, ramping toward the target over ~30 ms so slider
moves don't zipper. Output is hard-clipped with `vDSP_vclip` unless the soft-clip toggle switches to
`tanh` shaping above a 0.7 knee.

### Row identity (`ProcessRegistry.swift`)

Raw process objects are mostly invisible daemons, bundle IDs are sometimes nil and sometimes shared
across processes, and the user-visible app is often absent from the list entirely (Slack appears only
as helper processes). So a row key is, in order: the owning `NSRunningApplication`'s bundle ID found
by walking the parent PID chain via `sysctl` for a `.regular` (else `.accessory`) app, else
`exec:<comm>`, else the bundle ID, else `pid:<n>`. Processes that resolve to nothing and aren't
`IsRunningOutput` are dropped — that is what removes the daemon noise. The PID→owner cache is keyed
on process start time so PID reuse cannot alias.

Row keys are also the `UserDefaults` keys under `appVolumePercents` and `appVolumePremute`, so
changing the keying scheme silently orphans saved volumes.

### Settings (`Settings.swift`)

A standard SwiftUI `Settings` scene, opened from the panel footer via `SettingsLink`. Because this is
an `LSUIElement` app the window opens behind everything without an explicit `NSApp.activate()`, which
is why the footer link carries a `simultaneousGesture`. "Launch at login" wraps `SMAppService.mainApp`;
`register()` can land in `.requiresApproval` rather than `.enabled` if the user has denied it in
System Settings, so the toggle is a get/set `Binding` that reads back real status instead of trusting
its own value. Note that registration records the bundle's *current path* — registering from
`.build/` and then running `make clean` leaves a dangling login item, so test it against `make install`.

### Permission (`Permission.swift`)

TCC state is probed by creating a throwaway tap and attempting to *set* `kAudioTapPropertyDescription`
on it: `noErr` → granted, `kAudioDevicePermissionsError` (`'!hog'`) → denied. Detecting all-silent
buffers is the ambiguous signal; this is the reliable one. Re-probed on every slider move while denied.

## Conventions

- Swift 6 strict concurrency: everything except `MixRenderer` is `@MainActor`; `MixRenderer` is
  `@unchecked Sendable` and communicates only through atomics.
- Core Audio property access goes through the `AudioObjectID` helpers in `AudioObject.swift`
  (`value`/`array`/`string`/`dataSize`) and `propertyAddress(...)`, never raw
  `AudioObjectGetPropertyData` calls at the call site. `PropertyListener` is RAII — hold it or the
  listener is removed.
- Errors surface as `TapEngine.lastError` → `MixerModel.engineError` → an in-panel notice, plus
  `log.error` with `statusName()` for the four-CC OSStatus.
- The source carries no comments. Keep it that way.

## Documentation

`README.md` holds user-facing behavior and the measured verification table. `PLAN.md` is the original
design doc: its Part 1 records what was empirically disproven about the naive approach (per-app
aggregates, `TapAutoStart` semantics, TCC mechanism, process-list assumptions) and is worth reading
before changing the engine architecture.
