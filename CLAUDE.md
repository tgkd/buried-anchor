# CLAUDE.md

Per-app volume mixer (0–150%) for macOS 26+, SwiftPM executable, first-party frameworks only.
Current architecture and support contract are in README.md. The September 2026 implementation
replaces the previous main-actor TapEngine; historical PLAN.md/review findings may be stale.

## Build, signing, launch

Use the Makefile. `local.mk` supplies a stable signing identity. Never ad-hoc sign the capturing
app: it invalidates its TCC grant on rebuild. Never launch the inner binary for a HAL test: TCC
attributes capture to the responsible process and can return zero samples without a useful error.
Use `open -a` / `open -n -W -a` for live tests. `--render` is the hardware-free exception.

```
make build        # compile
make sign         # debug bundle and stable signing
make run          # sign and launch via LaunchServices
make prod         # signed release in dist/BuriedAnchor.app
make prod-run     # release build and launch
make install      # release to /Applications
make logs         # live engine logging
make reset-tcc    # explicit capture-permission reset; unnecessary for normal rebuilds
```

Follow the user's agterm instructions: builds/tests run in their own background session with a
log and exit marker. Do not background invisible processes or run long one-shots in an overlay.

## Verification

There is no separate test target. Run the existing self-test:

```
make build
.build/debug/BuriedAnchor --render
```

This covers synthetic rendering and the actual AudioCoordinator through an injected fake HAL,
including failures of creation, description updates, start, stop, and destruction. It appends to
`/tmp/buriedanchor-selftest.log`, emits a final RESULT, and exits nonzero on failure. No HAL or TCC
is touched in this mode. Do not replace the fake with real devices for these checks.

Live examples (need an uninterrupted test source and a signed app):

```
open -n -W -a "$PWD/.build/BuriedAnchor.app" --args --layout PlayerA
open -n -W -a "$PWD/.build/BuriedAnchor.app" --args --capture PlayerA
open -n -W -a "$PWD/.build/BuriedAnchor.app" --args --multi PlayerA 50 PlayerB 150
open -n -W -a "$PWD/.build/BuriedAnchor.app" --args --suspend PlayerA
```

Use separate throwaway .app wrappers for two afplay fixtures; plain afplay children group under
their terminal's owning app. Tests restore source settings. Read the final RESULT rather than
assuming `open` exit status is the test's exit status. Meter checks measure the controlled signal,
not independent physical output silence. Keep live tests sequential; the log and app identity are
shared. Debug logs are not reliably retained; errors include actionable recovery status.

## Architecture invariants

- MixerModel owns persistent intent and AppKit discovery/presentation on the main actor.
- TapEngine is an asynchronous facade. AudioControlLoop owns a serial queue and publishes immutable
  snapshots. Normal UI actions never synchronously wait for HAL graph operations. Shutdown and
  explicit diagnostic snapshots are the only queue barriers.
- AudioCoordinator owns requests separately from actual tap/aggregate/IOProc handles. The backend
  performs HAL calls and verifies tap description readback. FakeAudioHardware tests the same
  coordinator. Every mutation must stay on the control queue outside the synthetic tests.
- Never stop an active graph until mute guards are verified. A failed guard keeps the old graph.
- Never mutate renderer layout storage until IOProc destruction succeeds. A failed Stop is not
  sufficient proof; successful Destroy is. Keep handles on cleanup failure for a later retry.
- Failed rendering restores nonzero sources to verified direct playback where possible. Explicit
  user mute remains only when verified. Do not put unconditional bypass claims in error messages.
- 100% releases capture. 0% can hold a .muted tap without active output. Dormant adjusted sources
  use .muted until playback resumes. Idle/pre-roll/retry deadlines use system uptime.
- Supported live route: default output, one mono/stereo stream. Device-and-stream tap descriptions
  are required: macOS 27 ignored deviceUID on a stereoMixdownOfProcesses tap. Verify device, stream,
  processes, and mute readback. Do not broaden support without real hardware evidence.
- Process restore by bundle ID is disabled because it bypasses live route/ownership validation.
  Fresh process objects must be explicitly included; early process-list events can pre-roll IO.
- Core Audio service restart increments a generation and discards old IDs/listeners. The facade
  rejects queued commands from an old generation; the UI rediscovers sources and reapplies intent.
- GraphLayout validates the delivered aggregate sample rate and exact input prefix + tap layout;
  raw taps may have different clocks because HAL drift-compensates them. Never infer identity from
  a coincidental channel-count match or fall back to an unverified tap order.
- Renderer is preallocated and lock-free at the application level. Atomic targets/meters are its
  only cross-thread mutable controls. Reject changed callback buffer shapes before any mixing.
- Device-scoped samples already have physical channel ordering. Do not remap a preferred pair
  twice. The general renderer supports normalized mono fold and explicit destination channels.
- Soft saturation is optional coloration beginning at 0.7, not a transparent global limiter.
- Durable fallback executable keys contain full paths. Do not reapply old truncated executable-name
  settings to guessed paths. Bundle keys retain their existing persistence format.
- UI percentages are requested values. Pending/unsupported/failed control must remain visible;
  reset is available even when no tap exists, and meters clear when rendering stops.

Keep README.md aligned with behavior, and distinguish synthetic/injected checks from physical
hardware verification. Never claim seamless switching or guaranteed physical silence from meter
values alone.
