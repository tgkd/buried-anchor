# Audio management review — 2026-09-07

Baseline reviewed: `a5c8ae4`. The findings below describe that baseline. The subsequent user-authorized rework implements the core recommendations; current behavior is documented in README.md and the implementation record below.

## Verdict

The Core Audio topology is legitimate. It is a reasonable foundation for a driverless per-app volume utility, but the implementation is not yet robust enough to call a general macOS audio manager. Keep process taps and the renderer; rework lifecycle, recovery, and the supported-routing contract.

The app does not change a native per-process volume control. It captures selected process output, suppresses the original path, scales the captured samples, and renders them through a private aggregate containing the default output device. This makes the app responsible for continuity, routing, channel mapping, clipping, and recovery while it controls a source. Apple's [Core Audio taps sample](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) documents this capture/aggregate mechanism.

The previous `AUDIO_SOURCE_ARCHITECTURE_REVIEW.md` predates several fixes. Do not treat its old findings about absent retry logic, unbounded tap allocation, unvalidated persisted percentages, or absent synthetic renderer tests as current defects. Those mechanisms now exist.

## What is worth keeping

- One tap per logical app provides independent gain. A single global mix cannot recover independent source gains after summation.
- One shared aggregate is a defensible initial topology: one output clock and callback, bounded at 32 sources. A separate graph per app would add resource, synchronization, and scheduling costs.
- The render path uses preallocated storage, atomics, Accelerate, and gain smoothing; it contains no obvious application-level allocation, logging, HAL calls, or lock acquisition per buffer.
- The app excludes its own PID during discovery, creates private resources, and destroys IO before aggregates in the normal teardown path.
- Process-list and activity listeners, periodic reconciliation, PID birth-time validation, tap retention/eviction, settings normalization, and synthetic renderer checks are useful existing infrastructure.
- Keeping the output device idle when nothing needs rendering matters for Bluetooth device handoff and power use. Removing suspension altogether would sacrifice an intentional product behavior.
- The SwiftUI ownership setup is broadly sensible. The audio lifecycle is a much higher priority than replacing UI architecture or framework APIs.

## Findings, in priority order

### 1. High: mute and failure transitions have no consistent contract

Evidence: `TapEngine.swift:198`, `:205`, `:283`, `:349`, `:487`.

`muteBehavior(for:)` chooses `.muted` for every non-unity gain when there is no IOProc, including attenuation and boost. This deliberately holds dormant sources silent. But `fail()` only records an error and schedules a retry; it never reconciles that mute behavior.

A concrete failure sequence is: a source at 50% becomes idle, suspension changes its tap to `.muted`, a route change triggers reconstruction, and output discovery or aggregate creation fails. The tap remains `.muted` with no render path, while the error can say that audio is passing through untouched. Initial graph creation can enter the same situation because taps are created before the graph and `wantsIO` initially is false.

The opposite problem occurs while rebuilding an active graph: `stopGraph()` stops reading `.mutedWhenTapped` taps before replacing them with a guarded mute state. Their direct paths are allowed to resume during the gap. A source at 0% can therefore have an unmuted interval during another source's addition/removal or a device switch. Suspension also tears down IO before applying `.muted`.

Apple's [mute semantics](https://developer.apple.com/documentation/coreaudio/catapmutebehavior?language=objc) distinguish unconditional mute from mute that depends on another client reading the tap. The transition ordering matters. The code paths are confirmed; the duration and audibility of these intervals were not measured in this review.

Rework:

- Define separate intent for mute, unity, attenuation/boost, temporary transition guard, and failure bypass.
- Before stopping a working graph, establish and verify the chosen transition policy for affected sources. Start and validate the replacement before releasing the guard.
- Recommended failure policy: restore direct playback for nonzero gain when rendering cannot recover; retain an explicit user mute only while its HAL state can be verified. Expose the actual result in the UI.
- Do not report bypass until the mute-state write or tap removal succeeds. A log line is not recovery.
- Do not claim lossless short-sound startup: asynchronous discovery and graph restart can trade a full-volume onset for a clipped onset. That tradeoff needs measurements and an explicit product choice.

### 2. High: Core Audio service restart cannot be recovered by rebuilding only the aggregate

Evidence: `TapEngine.swift:60`, `:181`, `:283`, `:526`; `ProcessRegistry.swift:35`; `MixerModel.swift:46`.

The engine observes default-output changes and some device events, but never subscribes to `kAudioHardwarePropertyServiceRestarted`. Recovery reuses the current tap IDs and UUIDs. After a HAL reset, rebuilding an aggregate around invalid tap objects cannot restore capture. Cached process object ownership and listeners also need a fresh generation.

Apple's installed `AudioHardware.h` explicitly requires re-establishing client state, caches, and listeners after this event. The public selector is documented [here](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertyservicerestarted).

Rework: introduce a HAL generation. On service reset, invalidate old handles and queued callbacks, re-enumerate devices/processes, recreate listeners and taps, then reapply saved user intent. Add wake-time reconciliation. Normal route rebuilds and service-reset recovery must be distinct operations. This is a source-level finding; no audio service was restarted during review.

### 3. High: a volume adjustment can change where an app plays

Evidence: `TapEngine.swift:274`, `:360`, `:603`; `ProcessRegistry.swift:6`.

The tap is a process-wide stereo mixdown, while the aggregate always renders to the system default output. The registry does not record a process's output devices. An app explicitly using a USB interface or another output can be captured, suppressed there, and replayed through the default speakers when its slider changes. The README acknowledges this, although its phrase “only apps playing to the default output device are affected” is misleading.

Rework in two stages:

1. Define the initial product as a default-output stereo mixer. Read and observe output-scoped `kAudioProcessPropertyDevices`; leave incompatible or uncertain routes untouched and show why. Re-evaluate when the app changes its own route, not only when the system default changes.
2. If preserving multiple routes is a requirement, prototype device/stream-scoped taps and one graph per physical destination. Keep a logical app's gain shared across its route-specific members. Validate mute scope before shipping this design.

Apple exposes [process device discovery](https://developer.apple.com/documentation/coreaudio/audiohardwareprocess?changes=__11%2C__11) and [device/stream-scoped tap initializers](https://developer.apple.com/documentation/coreaudio/catapdescription). These are building blocks, not proof that a multi-route implementation will be transparent on every device.

### 4. High/medium: format and buffer mapping validation is incomplete

Evidence: `GraphLayout.swift:68`, `:80`, `:121`; `TapEngine.swift:387`, `:412`, `:427`; `AudioObject.swift:112`; `Render.swift:120`.

Confirmed by a temporary probe: one 48 kHz tap, a 48 kHz input layout, and a 44.1 kHz output layout resolve successfully with graph rate 48 kHz. `BufferLayout.sampleRate` is never consulted. Conversely, raw tap-rate differences are rejected even though aggregate drift compensation may convert tap data to the aggregate's timeline. The correct contract concerns the actual delivered aggregate stream formats.

Other weaknesses:

- Float32 validation checks format ID, float flag, and bit depth, but does not describe or validate the full byte stride/interleaving contract.
- Input mapping selects the last contiguous sequence of matching channel counts. Matching shapes alone do not establish source identity.
- An unreadable/incomplete tap list falls back to composition order instead of treating source mapping as unverified.
- Format reads use `compactMap`, silently dropping streams whose format could not be read.
- The engine does not observe tap format, aggregate input layout, or individual stream virtual-format changes. Device signatures omit format flags and device-alive state.

Rework: build a validated layout from actual aggregate stream descriptions, channel offsets, verified tap membership/order, and the negotiated clock. Fail explicitly if identity or format cannot be established. Publish the layout as an immutable generation; the callback must validate buffer bounds against it. Observe relevant format changes and rebuild deliberately.

The probe establishes a resolver validation gap, not an observed 44.1/48 kHz hardware playback failure. Do not “fix” it by blindly requiring every raw tap format to equal the output rate; that can reject valid HAL conversion.

### 5. Medium: channel mapping changes level and can select the wrong speakers

Evidence: `GraphLayout.swift:107`; `Render.swift:159`.

Confirmed by running the renderer: stereo samples `L = R = 0.25`, at gain 1, become `0.5` on a mono output. The map sends both channels to the same destination and adds them without normalization. Apple's installed `CATapDescription.h` says stereo mixdown duplicates mono sources into L/R, so folding that result back to mono introduces +6.02 dB for such a source.

For outputs with more than two channels, the code always chooses indices 0 and 1. These need not be the user's preferred stereo pair. Consult the output device's preferred stereo channels/channel layout; Apple provides [the preferred-channel selector](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertypreferredchannelsforstereo).

Rework: use an explicit channel matrix, including a documented stereo-to-mono rule such as `0.5L + 0.5R` for this consumer mixer. Validate preferred-channel routing. Either explicitly limit controlled sources to stereo or implement and verify a separate multichannel path; the current stereo tap inherently discards multichannel/spatial structure.

### 6. Medium: partial control and teardown failures are only logged

Evidence: `TapEngine.swift:185`, `:224`, `:205`, `:487`, `:497`, `:502`; `MixerModel.swift:110`, `:369`; `App.swift:206`.

If updating tap membership fails, the old membership remains, but the logical row can still appear active. A new helper may play outside the tap at its original gain. Mute-description failures are similarly logged without changing the reported engine state. Stop/destroy errors are logged and their handles are then forgotten, except for the limited doomed-tap list. Its retries occur on later graph rebuilds/shutdown, not on a dedicated cleanup schedule.

Rework: distinguish desired gain from applied state and verified member coverage. Represent per-source states such as bypassed, applying, rendering, muted, partial, and failed. Preserve resource ownership until successful teardown or a confirmed HAL generation change. Ensure the renderer's raw layout storage is never rewritten while an old callback might still be running.

### 7. Medium: unity and clipping behavior depend on control history

Evidence: `TapEngine.swift:97`, `:133`, `:362`; `Render.swift:192`, `:225`; `Settings.swift:70`.

Returning a slider to 100% keeps its tap in the shared aggregate. If another source still requires rendering, the unity source continues through the renderer, stereo mixdown, and shared clipper. An app never adjusted remains on the direct path. Thus 100% does not always mean bypass.

Soft clip is a saturator beginning at magnitude 0.7, not a transparent limiter that only catches overloads. A probe confirmed an unclipped unity sample of 0.9 becomes approximately 0.874835 with soft clip enabled. This can be a legitimate sound effect, but it should not be described as transparent gain control. Clipping indicators describe only the controlled mix; unmanaged apps are mixed downstream.

Rework: define unity as a product behavior and make it consistent. Ideally release a unity source's render path after a controlled transition, batching membership changes to avoid repeated shared-graph interruptions. Keep saturation as an explicitly named option, or implement a specified limiter with documented latency and headroom. Do not promise protection of the whole device mix while some apps bypass the engine.

### 8. Lower priority: control scheduling, identity, and UI work

Evidence: `MixerModel.swift:95`, `:242`, `:303`, `:335`, `:447`; `ProcessRegistry.swift:120`, `:149`; `TapEngine.swift:453`.

- Both discovery and synchronous HAL graph operations run on the main actor. UI work can delay short-sound recovery; HAL calls can stall the UI. Move graph control to a dedicated serial executor, with a pure desired-state reconciler. Keep AppKit presentation lookup and SwiftUI publication on the main actor.
- Separate meter polling from recovery/activity scheduling. The 100 ms timer currently does both, including when the panel is closed. Use monotonic time for retry and retention deadlines and keep low-rate reconciliation as a backstop.
- Meter writes mutate a shared `rows` array, and full snapshots replace it even when unchanged. Per-row observable meter state or snapshot equality can narrow UI work. This is an optimization suggestion, not a measured bottleneck.
- Executable identity comes from `p_comm`, a short process name, and is persisted as durable. Different executables can share that name. Prefer a validated executable path/code identity for fallback persistence and retain PID plus birth time for transient instances.
- macOS 26 already exposes `CATapDescription.bundleIDs`. Evaluate durable membership for known app-owned bundle IDs, but never assume a shared WebKit helper bundle belongs exclusively to one visible app. Keep observed process ownership and presentation identity separate. See Apple's [bundleIDs property](https://developer.apple.com/documentation/coreaudio/catapdescription/bundleids?language=objc).
- The IOProc block is synchronously dispatched onto `ioQueue`. Apple's installed header allows a nil queue for direct invocation. Profile direct invocation or a C-style callback as a later latency improvement; an API spelling change alone does not prove realtime safety.
- Fix user-facing truth first: a zero-percent icon reflects requested gain today, not verified silence. Show pending/error state and allow resetting a saved setting even when tap creation failed.

## Recommended rework

Retain the current shared aggregate initially. Split responsibilities into a few concrete pieces:

| Piece | Responsibility |
|---|---|
| Source intent store | Durable gain, explicit mute, premute value, supported-route preference |
| HAL inventory | Live processes, ownership, device routes, formats, activity, generation-tagged listeners |
| Audio coordinator | Serial reconciliation, suspension policy, mute handover, retries, recovery, owned graph resources |
| Render plan / renderer | Validated immutable layout and channel matrix; atomic gain targets and meters |
| UI model | Requested and applied states, presentation, visible meter sampling |

Implement in this order:

1. **Lifecycle correctness.** Extract an explicit transition policy, propagate membership/mute/teardown failures, implement HAL reset recovery, and add failure injection to the existing self-test approach. Acceptance: a failed build never leaves a nonzero source silently stranded while claiming bypass; a user mute has a verified and truthful status.
2. **Routing and DSP contract.** Enforce initial default-output support, validate actual aggregate formats/mapping, normalize mono fold-down, and respect the preferred stereo pair. Acceptance: adjusting volume does not silently move audio to another destination; a duplicated mono signal survives stereo-to-mono conversion at the specified gain.
3. **Continuity and efficiency.** Move control work off the main actor, batch source additions/removals, measure handover and onset loss, gate UI meter work, and clarify unity/limiter behavior. Do not mutate live tap lists and assume callbacks keep the same layout.
4. **Expand only against requirements.** Prototype per-destination graphs if multi-device routing is wanted. Consider a virtual driver only if the required routing/format/control guarantees cannot be achieved with measured process-tap behavior. A driver adds a separate deployment and reliability project; it is not an automatic fix for current lifecycle bugs.

Do not start by replacing everything with AVAudioEngine, a global tap, a driver, or an XPC daemon. None resolves the existing state-transition contract by itself. Preparing replacement metadata off to the side is useful, but running two overlapping muting/rendering graphs is not automatically a safe crossfade.

## Verification performed and remaining

Executed on macOS 27.0 build `26A5425a`, with Xcode 27 beta 6:

- `make build`: passed, exit 0.
- Fresh `.build/debug/BuriedAnchor --render`: all 20 existing checks passed, `RESULT pass`, exit 0.
- Temporary probe compiled directly against the unchanged `SourceID.swift`, `GraphLayout.swift`, and `Render.swift`: reproduced accepted 48/44.1 kHz layout mismatch, +6.02 dB duplicated-mono fold, and soft saturation below full scale; exit 0.

Probe source/results are in `/tmp/buried-anchor-review-probe/`. Build and renderer exit logs are `/tmp/buried-anchor-review-build.log` and `/tmp/buried-anchor-review-render.log`; the existing self-test appends details to `/tmp/buriedanchor-selftest.log`.

No physical playback, TCC reset, device switch, service restart, Bluetooth handoff, or end-to-end audible mute test was performed. Those behaviors are not certified by the synthetic checks. Existing peak tests mostly observe the app's own captured/scaled signal; they do not prove that the original device path is silent or that the right physical output receives the mix.

Before calling the rework complete, exercise controlled tones and short sounds through built-in output, a USB duplex interface, Bluetooth media/call-mode transitions, and a source pinned to another device. Cover cold start, helper churn, mute during another source's addition/removal, permission denial/revocation, route disappearance, sleep/wake, Core Audio restart, and each HAL creation/update/teardown failure. Verify routing, audible gaps/bursts, gain, cleanup, retry behavior, and saved-state restoration separately. A second process tap may observe audio before device-path muting; choose an endpoint measurement that actually observes the output under test.


## Implementation record

The authorized rework retains Core Audio taps and a shared aggregate, introduces a serial
AudioCoordinator with an injectable HAL backend, and separates desired gain from verified source
state. It adds guarded graph transitions, owned-handle cleanup retries, monotonic deadlines,
generation-based HAL recovery, stale-command rejection, route verification, actual unity bypass,
strict aggregate format/layout checks, normalized mono rendering, callback shape rejection, and
per-source UI status. Source membership changes are batched; ordinary gain changes remain atomic
updates. Meter collection is keyed by source and stale levels clear when capture ends.

Live verification found an additional platform behavior: on this macOS 27 build, HAL discarded
`deviceUID` on a stereo-mixdown tap even though the write succeeded. The implementation therefore
uses `CATapDescription(processes:deviceUID:stream:)` and verifies device/stream/membership/mute
readback. The supported live topology is deliberately one mono/stereo output stream on the default
device. Wider/multi-stream devices and processes using another/multiple destinations are rejected.
The generic channel mapper remains separately tested; this does not imply live multichannel support.

The rework does not add a driver, an XPC service, or multi-destination routing. Physical Bluetooth,
USB hotplug, service restart, and audible handover timing still require dedicated hardware QA.
