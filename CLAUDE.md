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
.build/BuriedAnchor.app/Contents/MacOS/BuriedAnchor --render   # the one exception, see below
open -a "$PWD/.build/BuriedAnchor.app" --args --layout PlayerA
open -a "$PWD/.build/BuriedAnchor.app" --args --selftest afplay 150 [--switch]
open -a "$PWD/.build/BuriedAnchor.app" --args --multi PlayerA 50 PlayerB 150
open -a "$PWD/.build/BuriedAnchor.app" --args --suspend afplay
open -a "$PWD/.build/BuriedAnchor.app" --args --capture PlayerA
open -a "$PWD/.build/BuriedAnchor.app" --args --watch 30
open -a "$PWD/.build/BuriedAnchor.app" --args --loginitem
```

Output goes to `/tmp/buriedanchor-selftest.log` (appended) and to `make logs`. Every mode ends with
`RESULT pass` or `RESULT fail (n)` and exits with a matching status, and every mode restores the
percentage it found on the row it touched — including removing the key again when there was none.

`--render` is the only mode that runs the **inner binary directly**, and the only one that may: it
touches no HAL object, asks for no system-audio access, and needs no audio playing, so the
responsible-process rule below does not apply and you get a real exit code. It covers
`GraphLayout.resolve` (duplex offset, non-interleaved, multichannel, mono fold, rejected formats)
and `MixRenderer.render` against synthetic `AudioBufferList`s. Run it after any change to
`Render.swift` or `GraphLayout.swift`.

`--layout <match>` dumps what the live aggregate actually looks like — tap list, sub-taps, per-stream
virtual formats, buffer shapes, terminal types. That dump is the evidence to look at first when
audio comes out wrong on unfamiliar hardware; do not assume every machine matches the built-in
speakers. `--selftest` matches one playing row by substring, boosts/mutes it and optionally switches
the default output device mid-playback; `--multi` needs **two distinct rows**, and row identity
follows the owning app up the parent chain, so an `afplay` started from a terminal groups under the
*terminal* — wrap each player in its own throwaway `.app` bundle as the README shows. `--watch`
dumps the row list every 3 s (`*` playing, `!` rendering, `?` tapped but idle), which is how
row-grouping, linger and suspend-on-exit behavior get checked. `--capture` walks one playing row
through 150% → 0% → 150% → 100% and asserts on our own process object's
`kAudioProcessPropertyIsRunningOutput` at each step, which is how "do we hold the output device"
gets checked. `--loginitem` registers and unregisters the login item, printing
`SMAppService.mainApp.status` at each step; it leaves the registration alone if it was already
enabled before the run.

Every mode that matches a playing row needs that row to keep playing for the *whole* run —
`--capture` takes about 20 s. A source that ends mid-run does not fail loudly, it just makes every
later step measure silence, so start a long tone fresh immediately before the run rather than
reusing one already in flight.

Debug-level `log.debug` lines never reach `log show` after the process exits — capture them live
with `make logs` (or `log stream`) running alongside the test, which is the only way to see
`graph up`, `suspended`, `route change` and eviction lines.

## Architecture

`MixerModel` (`@MainActor @Observable`) is the only thing the SwiftUI layer touches. It owns a
`ProcessRegistry` (what apps exist) and a `TapEngine` (what audio actually happens), and drives both
from a single 100 ms timer: every tick refreshes meters, drives suspension and services the engine's
retry backoff; every 10th tick re-snapshots the process list. That poll is a backstop, not the
primary signal — property listeners on `kAudioHardwarePropertyProcessObjectList`, on
`kAudioProcessPropertyIsRunningOutput` for *every* discovered process object, and on
`kAudioHardwarePropertyDefaultOutputDevice` drive reconciliation, coalesced through
`scheduleReconcile` so a burst of listener fires costs one `refreshList`.

**One aggregate, N taps** — not one aggregate per app. `TapEngine` keeps one `CATapDescription` per
controlled *app* (`.mutedWhenTapped`, private, `processRestoreEnabled`) and puts them all in a single
private aggregate device built around the current default output, with one IOProc.

The load-bearing invariant is still the slot mapping, but it is now **discovered and validated**
rather than assumed (`GraphLayout.swift`). After the aggregate comes up, `TapEngine.discoverLayout`:

1. reads `kAudioAggregateDevicePropertyTapList` and reorders `order` to match it, instead of
   trusting that the HAL kept composition order;
2. reads the aggregate's input buffer shape and finds where the taps sit in it by matching channel
   counts, so a duplex sub-device's own input streams cannot be rendered as an app's audio
   (`inputOffset`) — pick the tail-most alignment, since taps are appended after sub-devices;
3. maps every output channel to an explicit `(buffer, offset, stride)`, which is what makes
   non-interleaved and multichannel outputs correct;
4. rejects anything it cannot map — not 32-bit float, no output channels, taps that don't line up,
   disagreeing tap sample rates — and the engine then holds a `.failed` state and passes audio
   through untouched rather than rendering garbage.

`GraphLayout.resolve` is a pure function over `[TapFormat]`, input `BufferLayout` and output
`BufferLayout`, which is what makes `--render` able to test all of this without hardware.
`MixerModel.refreshMeters` still indexes slots by position in `engine.controlledKeys`, so that array
must stay equal to the renderer's slot order — `rebuild` maintains it from the resolved layout.

`TapEngine.state` is `idle | active | suspended | failed(String)`. `isControlled` means "we hold a
tap for this app" (drives the reset menu item and the row's saved volume); `isActive` means "the app
is actually being rendered right now" (drives the meter). Do not collapse them again: a tap can
exist while the graph is failed, and reporting that as control is what made a transient HAL failure
look permanent.

Two cost tiers, and the difference matters:

- **Changing a gain** is a relaxed atomic store into `MixRenderer.targets[slot]`. No rebuild, no
  lock, no glitch.
- **Adding or removing a controlled app** tears down the IOProc, destroys and recreates the
  aggregate, and recomputes every slot — briefly interrupting all other controlled apps. Same path
  runs on a default-output-device change.

`reconcile(reason:)` is the only place that decides what the graph should be — no aggregate, an
aggregate with the IOProc stopped, or a running one — and it also republishes tap mute behaviors on
every transition. It delegates to `rebuild` whenever the slot map itself changes (a tap added or
released, a route change, a retry).

`rebuild` is the only place that mutates the graph, and it does so in dependency order: stop IO →
destroy IOProc → destroy aggregate → destroy taps queued in `doomed` → create aggregate → validate
layout → prime gains → start IO → publish `.active`. `release` never destroys a tap inline; it moves
it to `doomed` so it dies only after the aggregate that contains it is gone. Every HAL lifecycle call
is status-checked through `check(_:_:)`, and a tap that refuses to die stays in `doomed` for the next
attempt rather than being forgotten. On any failure the engine cleans up what it created, enters
`.failed`, and retries on a 1/2/5/15/30 s backoff (`retryIfDue`, driven from the model tick) or on
the next relevant HAL event.

Besides the default-output-device listener, the engine watches the *current* output device's stream
configuration, nominal sample rate and is-alive, plus the aggregate's `IOStoppedAbnormally` and
buffer frame size. Route changes are gated on a `DeviceSignature` (uid + output channels + rate)
so a notification that carries no actual change cannot cause a rebuild — an unnecessary rebuild is
an audible glitch for every controlled app. Buffer-size changes only reconfigure the ramp.

An app is untapped and bit-transparent until its slider first leaves 100%, or until it appears while
carrying a saved non-unity volume — `MixerModel.refreshList` prepares the tap as soon as the app has
audio process objects, so playback does not start at the wrong level while a 1 s poll catches up.
Per-process `kAudioProcessPropertyIsRunningOutput` listeners (coalesced through
`scheduleReconcile`) drive that, with the poll left as a backstop.

`MixRenderer.maxSlots` (32) caps controlled apps, and slots are now reclaimed: a tap whose app has
had no process objects for 5 minutes is released, but `sweepRetention` defers that until the engine
is suspended or nothing controlled is playing, so reclaiming never interrupts audio. At the cap,
`claimSlot` evicts the least-recently-active non-playing source. Releasing a tap never touches the
saved percentage.

**Suspension** is the third tier, and it is what keeps us from holding the output device open.
Two things move independently, decided in one place — `TapEngine.reconcile`:

- **The aggregate** exists whenever any controlled gain is not exactly 1 (`needsGraph`). Keeping it
  is free: an aggregate with no running IOProc does **not** make the HAL report us as running
  output and does not keep the device running — measured with `--capture`. So resume stays a cheap
  `startIO()` rather than a rebuild.
- **The IOProc** runs only while some controlled app whose gain is neither 0 nor 1 is *actually
  playing*. `MixerModel.updateSuspension` waits 1.5 s (wall clock, since listener-driven reconciles
  make tick counting irregular) before tearing it down, and resumes the moment such an app starts
  playing again.

Whenever the IOProc is down, every tap whose gain is not 1 is switched from `.mutedWhenTapped` to
`.muted` (`applyMuteBehaviors`, written through `kAudioTapPropertyDescription` on the live tap, the
same way `syncObjectIDs` rewrites the process list). `CATapMuted` silences the process for as long as
the tap exists, with no reading client — which is what lets the engine stop rendering while an app is
merely silent. Without it a suspended graph is a pass-through graph and the first buffers after
playback resumes escape at full volume, which for a muted app is an audible burst. A tap at exactly
gain 1 keeps `.mutedWhenTapped`, which with no IOProc means bit-transparent pass-through.

Why this matters far beyond power: a running IOProc makes the HAL report **our own process** as
`kAudioProcessPropertyIsRunningOutput`, and that is the signal macOS arbitrates AirPods automatic
switching on. Holding it permanently drags AirPods off an iPhone onto the Mac and never hands them
back. A row muted at 0% used to pin the graph forever, since 0 is not 1 — the reported bug this
design replaced. `--capture` is the regression test: it asserts we report `IsRunningOutput` while
rendering and stop reporting it at 0% and at 100%.

Percentages are rounded in `setPercent` and on load for the same reason: a slider left at 100.19%
reads as "100%" but is not `gain == 1`, so it would hold a tap and an aggregate forever.

Whether a `.muted` tap is *audibly* silent cannot be verified from inside the process — see PLAN.md
❌6b, a global tap is taken before per-process muting and reads the same level in every state. That
one property is checked by ear.

`MixerModel.reset(_:)` — the row's right-click menu — is the user-facing path back out of the graph:
it drops the saved percentage *and* releases the tap. It is deliberately not reachable from the
slider returning to 100%, since that would rebuild the aggregate whenever the slider crossed 100.
The other two callers of `engine.release` are `sweepRetention` and `claimSlot`, and both keep the
saved percentage — only `reset` forgets it. Mute is a plain `setPercent(0,)` with the pre-mute level
stashed in `premute`; it keeps the tap.

### Realtime callback (`Render.swift`)

`MixRenderer.render` runs on the Core Audio IO thread: **no allocation, no locks, no logging, no
Foundation**. Gains cross the thread boundary only through `Atomic<Float>`; meters and clip counts
come back the same way via `exchange(0)`. The slot and output-channel maps are plain preallocated
`Int32` buffers written by `apply` only while IO is stopped, published by storing `activeSlots` with
release ordering and read with acquire ordering — that pairing is what makes the map safe to read
without a lock.

It clears **every** output buffer (not just the first — anything left unwritten is stale device
memory, which on a non-interleaved device is the entire right channel), then for each slot walks its
tap channels and does gain-and-sum in one strided `vDSP_vrampmuladd` per channel into the mapped
output channel, ramping toward the target over ~30 ms so slider moves don't zipper. Every slot
re-checks `mNumberChannels` against the map before touching memory and skips the slot on a mismatch.
Output is hard-clipped with `vDSP_vclip` unless the soft-clip toggle switches to `tanh` shaping above
a 0.7 knee.

### Row identity (`SourceID.swift`, `ProcessRegistry.swift`)

Raw process objects are mostly invisible daemons, bundle IDs are sometimes nil and sometimes shared
across processes, and the user-visible app is often absent from the list entirely (Slack appears only
as helper processes). So a row key is, in order: the owning `NSRunningApplication`'s bundle ID found
by walking the parent PID chain via `sysctl` for a `.regular` (else `.accessory`) app, else
`exec:<comm>`, else the bundle ID, else `pid:<n>`. Processes that resolve to nothing and aren't
`IsRunningOutput` are dropped — that is what removes the daemon noise. The PID→owner cache is keyed
on process start time so PID reuse cannot alias.

Those four cases are now the `SourceID` enum (`bundle` / `executable` / `ephemeral`), whose `raw`
string is byte-identical to the old key strings, so existing saved volumes keep working. Only
`isDurable` identities (bundle, executable) are ever written to `UserDefaults` — a `pid:<n>` key
cannot survive the process it names, so persisting it only accumulated garbage. Values are clamped
to 0–150 and dropped if non-finite on load, and the normalized dictionary is written back once.

Row keys are still the `UserDefaults` keys under `appVolumePercents` and `appVolumePremute`, so
changing `SourceID.raw` silently orphans saved volumes.

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
