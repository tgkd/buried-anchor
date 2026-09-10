# Buried Anchor

Per-app volume mixer for macOS, 0–150%, built on Core Audio process taps. Menu-bar only, no kernel
driver, no HAL plug-in, no admin install, first-party frameworks only.

Requires macOS 26+ (uses `CATapDescription.processRestoreEnabled`) and a code-signing identity.

## Build and run

Signing is required (see below for why ad-hoc will not do). Point the build at one of your own
codesigning identities once:

```
make identities                                  # list what you have
echo 'IDENTITY = <40-char hash>' > local.mk      # gitignored
```

Then:

```
make run          # debug build, bundle, sign, launch via LaunchServices
make prod         # optimized release bundle at dist/BuriedAnchor.app
make prod-run     # prod, then launch it
make install      # prod, then copy to /Applications
make stop
make logs
make identities   # list signing identities; override with IDENTITY=<hash>
make reset-tcc    # forget the system-audio permission grant
```

**Do not ad-hoc sign this app.** Ad-hoc signing produces a designated requirement pinned to the
binary hash (`cdhash H"..."`), and TCC stores that requirement when you grant system-audio access —
so every rebuild invalidates the grant. A real signing identity yields an identity-based requirement
(`identifier "..." and anchor apple generic and certificate leaf[subject.CN] = "..."`) that survives
rebuilds. Given that a denied grant manifests as silently zero-filled buffers, an invalidated grant
looks exactly like a broken app.

Distribution to other machines additionally needs a Developer ID certificate plus notarization; an
Apple Development certificate only produces a build that runs locally.

**Never run `.build/BuriedAnchor.app/Contents/MacOS/BuriedAnchor` directly.** TCC attributes the
system-audio request to the *responsible process*. Launched from a terminal, that is the terminal,
which has no `NSAudioCaptureUsageDescription`, so the request is denied **silently** — no prompt,
and every captured sample arrives as `0.0` while the IOProc keeps firing normally. `make run` uses
`open -a` for this reason. This is the single most misleading failure mode in the project.

## How it works

Buried Anchor controls volume by capturing an app's output, suppressing that original path, and
rendering the captured samples at the requested gain. It uses public Core Audio process taps and a
private aggregate; it does not install an audio driver or change a native per-process volume knob.

The supported destination is the **default output device with one mono or stereo output stream**.
An app using another destination or multiple devices is left untouched and marked unsupported.
An idle app reports no output device at all; it is held by a device-scoped tap on the default
output and re-verified when its device list changes, without rebuilding the graph.
Device-and-stream taps restrict capture to the verified destination. A process-wide stereo-mixdown
tap is unsuitable for that restriction: macOS 27 discarded its `deviceUID` in live readback.

- **100% is bypass.** Returning to unity releases the app's tap, even when other apps remain controlled.
- **0% is explicit mute.** A verified `.muted` tap holds the mute once the tap has been read. HAL
  does not mute a process added to a tap that no IOProc is reading, so a fresh member of a muted
  source pre-rolls IO for 1.5 seconds with the tap kept `.muted`. Muting the last rendered source
  releases output without the idle delay.
- Nonzero adjusted sources use `.mutedWhenTapped` while rendering. Dormant adjusted sources are held
  by `.muted`; activity resumes rendering. New members of any adjusted source, muted ones included,
  pre-roll IO for 1.5 seconds to establish capture before a short sound. Pre-roll is tracked per
  source, and only a source that still exists with a non-unity gain can hold IO open.
- Before replacing a graph, the coordinator verifies mute guards, stops and destroys its IOProc,
  destroys the aggregate, reconciles taps, validates the new layout, then starts replacement IO.
- A mute guard that fails because the tap's output device disappeared (unplugged or lost across
  sleep) does not trap recovery: the coordinator confirms the device is absent from the HAL device
  list, destroys that tap, and recreates it on the current default output. Replacement taps pre-roll
  IO once, including muted ones, and that priming is repeated on retry until a graph starts. If the
  old device is still present or its availability cannot be read, the guard failure stands and the
  old graph is kept.
- On failure, nonzero sources return to direct playback when that state can be verified. Explicit
  mute is retained when verified. Failed mute/cleanup operations remain visible, and handles stay
  owned for retry. The app never claims bypass merely because graph construction failed.
- Helper processes come and go while an app is controlled. A member whose HAL object no longer
  exists is pruned from the request and the tap, including inside the mute guard; an app with
  no live members waits without a tap. A live process that HAL refuses to capture fails only
  that app's row. Neither case fails the other apps' graph or starts the global retry loop.
- Retries use monotonic 1/2/5/15/30-second deadlines. A Core Audio service reset invalidates taps,
  process IDs, cached ownership, listeners, and queued commands from the old generation; fresh
  discovery reapplies saved settings. Wake and route/format changes trigger reconciliation.
- One serial control queue owns graph mutations. The IO callback has preallocated storage and
  atomic gains/meters. SwiftUI receives snapshots and updates displayed meters only when visible.
- Gains are saved by bundle ID, or by full executable path when an owning app cannot be found.
  Legacy short executable-name preferences are discarded to avoid applying a gain to an unrelated
  program with the same truncated name. Bundle preferences are preserved.

## Architecture

| File | Responsibility |
|---|---|
| `ProcessRegistry.swift`, `SourceID.swift` | Process discovery, owning-app identity, presentation |
| `MixerModel.swift` | Saved intent, rows, discovery events, UI state |
| `TapEngine.swift` | Main-actor facade, serial control loop, generation-tagged listeners and commands |
| `AudioCoordinator.swift` | Resource ownership, transitions, mute policy, suspension, retries, recovery |
| `AudioHardwareBackend.swift` | HAL operations, readback verification, device-scoped taps, format discovery |
| `GraphLayout.swift`, `Render.swift` | Validated buffer/channel mapping, smoothed gain, mixing and saturation |
| `SelfTest.swift`, `CoordinatorChecks.swift` | Existing executable self-test modes and injected HAL failures |

`AudioHardwareBackend` is injectable. Tests exercise the actual coordinator, including partial
construction and failed destruction, without accessing real audio hardware.

The renderer uses the **aggregate's delivered sample rate**, allowing differently clocked taps
when HAL converts them. It validates buffer bounds and rejects changed callback shapes before
mixing. The general layout resolver supports explicit stereo channel matrices and normalized mono
fold-down; the live backend deliberately supports only the narrower verified mono/stereo topology.

## The panel

Rows show playing/recent apps and saved non-unity settings, including unavailable sources. The
percentage is requested gain; a warning indicates waiting, unsupported routing, or failed control.
Right-click → Reset removes saved intent even if no tap could be created. Double-click a slider to
return to 100% bypass. The mute button remembers and restores the previous percentage.

Waveforms indicate activity. Controlled rendering uses measured levels; untapped apps cannot
provide a measured level. Meter values clear when capture stops.

Settings include launch at login and optional **Soft saturation**. Saturation begins at 0.7 full
scale and deliberately changes some unclipped signals. With it disabled, the controlled mix is hard
clipped at full scale. Neither mode limits unmanaged apps mixed downstream by macOS.

## Diagnostic journal

Normal launches automatically append to `~/Library/Logs/BuriedAnchor/events.jsonl`.
Each JSON line includes UTC time, monotonic uptime, PID and a launch-session ID. Startup records
include the actual app path, Git revision, bundle build date, OS and login-item status.
The journal records saved/requested gains, source membership and playback changes, sleep/wake,
HAL notifications, tap writes and readback, graph start/stop, pre-roll expiration and recovery.
Every 30 seconds a heartbeat adds the callback count, coordinator state and read-only HAL tap,
process-route and activity snapshots. A reported mute is still not proof of physical silence.

Writing runs on a separate bounded queue, never in the audio callback. The callback only increments
an atomic diagnostic counter. Files rotate at 2 MiB, keeping four archives (`events.1.jsonl` is the
newest), about 10 MiB total. Overload drops are reported as `log.dropped`. The journal contains app
identifiers, executable paths and device identifiers, but no audio samples or document contents.
The synthetic `--render` mode tests its own temporary journal and does not write to the live log.

After a recurrence, keep `events.jsonl` and all four archives and note when the sound leaked and
which app played it. These files survive an app restart. To follow readable events:

```
tail -F ~/Library/Logs/BuriedAnchor/events.jsonl | jq -r '[.time, .event, .detail] | @tsv'
```

## Verification

The September 2026 rework was built and tested on macOS 27.0 (26A5425a), Xcode 27 beta 6. See
[AUDIO_MANAGEMENT_REVIEW.md](AUDIO_MANAGEMENT_REVIEW.md) for the original assessment and the
implementation/verification record. Historical measurements in `PLAN.md` and the older architecture
review describe previous revisions and are not certification of this implementation.

### Hardware-free checks

```
make build
.build/debug/BuriedAnchor --render
```

This mode is the exception to the LaunchServices rule: it does not access HAL or require audio/TCC.
It checks layouts, sample-rate validation, mono gain, selected channels, stale-buffer rejection,
gain ramps, clipping, source isolation, failure rollback, resource ownership, retry deadlines,
mute-before-stop ordering, unsupported routes, membership failures, and HAL reset recovery.
It appends `PASS`/`FAIL` and a final `RESULT` to `/tmp/buriedanchor-selftest.log`, and exits nonzero
on failure. There is no separate SwiftPM test target.

### Live checks

All live modes require a signed bundle launched through LaunchServices. Match a source that will
keep playing throughout the test. Settings changed by tests are restored afterward.

| Mode | Check |
|---|---|
| `--layout <match>` | Graph state, captured level, current tap membership and device restriction |
| `--selftest <match> <pct> [--switch]` | Gain/mute and optional default-device switch |
| `--multi <a> <pctA> <b> <pctB>` | Two independent sources, gain swapping, selective mute |
| `--suspend <match>` | 50% → true 100% bypass → 50% |
| `--capture <match>` | Rendering holds output, mute/unity release it, unmute resumes |
| `--watch <seconds>` | Source discovery and activity |
| `--loginitem` | Login-item registration round trip |

Example: `open -n -W -a "$PWD/.build/BuriedAnchor.app" --args --capture PlayerA`.
The shared log ends with `RESULT pass` or `RESULT fail (n)`. Tests measure the controlled signal and
HAL IO state; they do not independently certify audible silence at the physical output. A second
tap can observe audio before device-path muting and is not necessarily a valid silence detector.

## Remaining limitations

- Multichannel/multiple-stream output devices and per-app output selection are unsupported. The
  app reports the restriction instead of moving or silently downmixing another route's audio.
- Adding/removing sources, membership changes, and device reconfiguration rebuild the shared
  graph. Mute guards avoid intentionally opening the original path, but short interruptions remain.
- First playback after asynchronous process discovery/resume can lose an onset. Live testing found
  that adding a process to an unread muted tap leaks its onset, so a muted source's fresh helper
  briefly starts physical output to prime the tap. Short-sound mute coverage and Bluetooth
  transitions need hardware QA; this is not sample-accurate interception.
- If HAL fails, bypass restores the source's original level, which can be louder than its requested
  attenuation. An unverified mute is reported as a failure, not guaranteed silence.
- Helper ownership can be ambiguous, especially shared WebKit services. No automatic bundle-only
  restoration is used; live members and their routes are verified explicitly.
- Core Audio restart/failure recovery is covered by injection. Bluetooth call-mode changes,
  physical USB hotplug, sleep/wake, and audible transition timing need hardware verification.
- Not sandboxed. Distribution requires appropriate signing and notarization.
