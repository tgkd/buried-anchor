# CLAUDE.md

Per-app volume mixer (0–150%) for macOS 26+, SwiftPM executable, first-party frameworks only.
README.md is the user-facing description; this file holds the architecture and support contract.
The September 2026 implementation replaces the previous main-actor TapEngine; PLAN.md
describes earlier revisions and is not certification of the current one.

## How it works

The app controls volume by capturing an app's output with public Core Audio process taps,
suppressing the original path, and rendering the captured samples at the requested gain through a
private aggregate. It installs no driver and does not change a native per-process volume.

## Build, signing, launch

Use the Makefile. `local.mk` (gitignored) supplies a stable signing identity; `make identities`
lists candidates, `IDENTITY=<hash>` overrides.

```
make build        # compile
make sign         # debug bundle and stable signing
make run          # sign and launch via LaunchServices
make prod         # signed release in dist/BuriedAnchor.app
make prod-run     # release build and launch
make install      # release to /Applications
make stop
make logs         # live engine logging
make reset-tcc    # explicit capture-permission reset; unnecessary for normal rebuilds
```

Never ad-hoc sign the capturing app. Ad-hoc signing pins the designated requirement to the cdhash,
TCC stores that requirement with the system-audio grant, and every rebuild invalidates it. A real
identity yields an identity-based requirement that survives rebuilds. A denied grant shows up as
silently zero-filled buffers, so an invalidated grant looks exactly like a broken app.
Distribution to other machines needs Developer ID plus notarization; the app is not sandboxed.

Never launch the inner binary for a HAL test. TCC attributes capture to the responsible process; a
terminal has no `NSAudioCaptureUsageDescription`, so the request is denied with no prompt and the
IOProc keeps firing with zero samples. Use `open -a` / `open -n -W -a` for live tests. `--render` is
the hardware-free exception.

Follow the user's agterm instructions: builds/tests run in their own background session with a
log and exit marker. Do not background invisible processes or run long one-shots in an overlay.

## Source map

| File | Responsibility |
|---|---|
| `ProcessRegistry.swift`, `Discovery.swift`, `SourceID.swift` | Process discovery off the main actor, owning-app identity, presentation |
| `MixerModel.swift` | Saved intent, rows, discovery events, UI state, member settle |
| `TapEngine.swift` | Main-actor facade, serial control loop, generation-tagged listeners and commands |
| `AudioCoordinator.swift` | Resource ownership, transitions, mute policy, suspension, retries, recovery |
| `AudioHardwareBackend.swift` | HAL operations, readback verification, device-scoped taps, format discovery |
| `GraphLayout.swift`, `Render.swift` | Validated buffer/channel mapping, smoothed gain, mixing and saturation |
| `DiagnosticLog.swift` | Diagnostic journal |
| `SelfTest.swift`, `CoordinatorChecks.swift`, `DiagnosticLogChecks.swift` | Self-test modes and injected HAL failures |

Timings (pre-roll, member settle, retry deadlines, heartbeat, quit barrier) and journal rotation
limits live as constants in the owning file; read them there.

## Verification

There is no separate test target. Run the existing self-test:

```
make build
.build/debug/BuriedAnchor --render
```

This covers synthetic rendering and the actual AudioCoordinator through an injected fake HAL,
including failures of creation, description updates, start, stop, and destruction. It appends to
`/tmp/buriedanchor-selftest.log`, emits a final RESULT, and exits nonzero on failure. No HAL or TCC
is touched in this mode, and it uses its own temporary journal. Do not replace the fake with real
devices for these checks.

Live modes need a signed bundle launched through LaunchServices and a source that keeps playing:

| Mode | Check |
|---|---|
| `--layout <match>` | Graph state, captured level, current tap membership and device restriction |
| `--selftest <match> <pct> [--switch]` | Gain/mute and optional default-device switch |
| `--multi <a> <pctA> <b> <pctB>` | Two independent sources, gain swapping, selective mute |
| `--suspend <match>` | 50% → true 100% bypass → 50% |
| `--capture <match>` | Rendering holds output, mute/unity release it, unmute resumes |
| `--watch <seconds>` | Source discovery and activity |
| `--loginitem` | Login-item registration round trip |

```
open -n -W -a "$PWD/.build/BuriedAnchor.app" --args --capture PlayerA
```

Use separate throwaway .app wrappers for two afplay fixtures; plain afplay children group under
their terminal's owning app. Tests restore source settings. Read the final RESULT rather than
assuming `open` exit status is the test's exit status. Meter checks measure the controlled signal
and HAL IO state, not physical output silence; a second tap can observe audio before device-path
muting and is not a valid silence detector. Keep live tests sequential; the log and app identity
are shared.

## Diagnostic journal

Normal launches append JSON lines to `~/Library/Logs/BuriedAnchor/events.jsonl`, rotated into
numbered archives (`events.1.jsonl` newest). Each line has UTC time, monotonic uptime, PID and a
launch-session ID; startup records app path, Git revision, build date, OS and login-item status.
It records gains, membership and playback changes, sleep/wake, HAL notifications, tap writes and
readback, graph start/stop, pre-roll expiry, recovery, and a periodic heartbeat with callback
count, coordinator state and read-only HAL snapshots. Writing runs on its own bounded queue, never
in the audio callback, which only bumps an atomic counter; overload is logged as `log.dropped`.
No audio samples or document contents are logged. A logged mute is not proof of physical silence.

```
tail -F ~/Library/Logs/BuriedAnchor/events.jsonl | jq -r '[.time, .event, .detail] | @tsv'
```

## Architecture invariants

- MixerModel owns persistent intent and AppKit discovery/presentation on the main actor.
- TapEngine is an asynchronous facade. AudioControlLoop owns a serial queue and publishes immutable
  snapshots. Normal UI actions never synchronously wait for HAL graph operations. Shutdown and
  explicit diagnostic snapshots are the only queue barriers, and both are bounded: if coreaudiod
  hangs, the journal records `engine.stopTimedOut` and the app exits without graph teardown.
- The main actor never calls Core Audio synchronously. Discovery, activity listeners and the
  capture-permission probe run on their own queues and post results back.
- AudioCoordinator owns requests separately from actual tap/aggregate/IOProc handles. The backend
  performs HAL calls and verifies tap description readback. FakeAudioHardware tests the same
  coordinator. Every mutation must stay on the control queue outside the synthetic tests.
- Graph replacement order: verify mute guards, stop and destroy the IOProc, destroy the aggregate,
  reconcile taps, validate the new layout, then start replacement IO.
- Never stop an active graph until mute guards are verified. A failed guard keeps the old graph,
  except when the tap's output device is confirmed absent from the HAL device list (unplugged,
  lost across sleep): then that tap is destroyed and recreated on the current default output. If
  the device is present or its availability cannot be read, the guard failure stands.
- Never mutate renderer layout storage until IOProc destruction succeeds. A failed Stop is not
  sufficient proof; successful Destroy is. Keep handles on cleanup failure for a later retry.
- Failed rendering restores nonzero sources to verified direct playback where possible. Explicit
  user mute remains only when verified. Do not put unconditional bypass claims in error messages.
- 100% releases capture, even when other apps stay controlled. 0% can hold a .muted tap without
  active output. Nonzero adjusted sources use .mutedWhenTapped while rendering; dormant adjusted
  sources use .muted until playback resumes. Muting the last rendered source releases output
  without the idle delay. Idle/pre-roll/retry deadlines use system uptime.
- HAL only mutes a .muted tap after an IOProc has read it on its current device. New members of
  any adjusted source, and every tap recreated for a new device, pre-roll IO before relying on the
  mute; priming repeats on retry until a graph starts. Pre-roll is per source, and only a source
  that still exists with a non-unity gain can hold IO open.
- Prime taps that only 0% sources need through a tap-only aggregate with a silent IOProc; never
  start the physical output device for a muted source, because that steals auto-switching
  headphones. If HAL rejects the tap-only aggregate, fall back to the output graph and journal
  `graph.primingFallback`. A pre-roll involving a nonzero source uses the output graph so its first
  sound renders at the requested level.
- A default output change recreates every controlled tap on the new device. Updating a tap's
  device in place left HAL reporting `muted` while the process played audibly on the new device.
- Supported live route: default output, one mono/stereo stream. Device-and-stream tap descriptions
  are required: macOS 27 ignored deviceUID on a stereoMixdownOfProcesses tap. Verify device, stream,
  processes, and mute readback. Do not broaden support without real hardware evidence. An idle
  process reports an empty device list: treat it as eligible, hold it with a device-scoped tap on
  the default output, and re-verify when its device list changes without rebuilding the graph.
- Process restore by bundle ID is disabled because it bypasses live route/ownership validation.
  A fresh process object joins a tap only after it has existed for the member-settle interval in
  MixerModel, unless it is the owning application's own main process, which joins at once. Both
  discovery paths must classify it, and a later positive identification promotes an object that was
  first seen as a helper. Short-lived helpers (Handy's per-dictation `osascript`) must never touch
  the graph: a priming aggregate created and destroyed inside a coreaudiod PauseAll/ResumeAll cycle
  left `ResumeAllContexts` waiting forever and hung every audio client on macOS 27.0. The main
  process exemption does not remove that race for a main process exiting during priming.
- A member whose HAL object no longer exists is pruned from the request and the tap, including
  inside the mute guard; an app with no live members waits without a tap. A live process HAL
  refuses to capture fails only that app's row. Neither case fails other apps or starts the global
  retry loop.
- Core Audio service restart increments a generation and discards old IDs/listeners. The facade
  rejects queued commands from an old generation; the UI rediscovers sources and reapplies intent.
  Wake and route/format changes trigger reconciliation.
- GraphLayout validates the delivered aggregate sample rate and exact input prefix + tap layout;
  raw taps may have different clocks because HAL drift-compensates them. Never infer identity from
  a coincidental channel-count match or fall back to an unverified tap order.
- Renderer is preallocated and lock-free at the application level. Atomic targets/meters are its
  only cross-thread mutable controls. Reject changed callback buffer shapes before any mixing.
  SwiftUI receives snapshots and updates displayed meters only when visible.
- Device-scoped samples already have physical channel ordering. Do not remap a preferred pair
  twice. The general renderer supports normalized mono fold and explicit destination channels;
  the live backend deliberately supports only the narrower verified mono/stereo topology.
- Soft saturation is optional coloration, not a transparent global limiter; without it the
  controlled mix hard-clips at full scale. Neither limits unmanaged apps mixed downstream.
- Durable fallback executable keys contain full paths. Do not reapply old truncated executable-name
  settings to guessed paths. Bundle keys retain their existing persistence format.
- UI percentages are requested values. Pending/unsupported/failed control must remain visible;
  reset is available even when no tap exists, and meters clear when rendering stops.

## Known limitations

- Multichannel/multi-stream devices and per-app output selection are unsupported; the app reports
  the restriction instead of moving or downmixing another route's audio.
- Source/membership changes and device reconfiguration rebuild the shared graph; mute guards avoid
  opening the original path, but short interruptions remain.
- First playback after asynchronous discovery/resume can lose or leak an onset. A brand-new helper
  of a controlled app is audible at its own level during the member settle. This is not
  sample-accurate interception.
- HAL failure falls back to the source's original level, which can be louder than requested. An
  unverified mute is reported as a failure, not as silence.
- Helper ownership can be ambiguous, especially shared WebKit services.
- Core Audio restart/failure recovery is covered only by injection. Bluetooth call-mode changes,
  USB hotplug, sleep/wake, and audible transition timing need hardware verification.

Keep README.md user-facing and this file aligned with behavior. Distinguish synthetic/injected
checks from physical hardware verification. Never claim seamless switching or guaranteed physical
silence from meter values alone.
