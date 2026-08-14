# Audio Source Architecture Review

Date: 2026-08-14  
Reviewed commit: 49d6c28 (master)  
Scope: the complete repository, emphasizing source identity, Core Audio tap ownership,
aggregate-device lifecycle, render-thread correctness, persistence, recovery, and verification.

## Executive verdict

The fundamental approach is correct: Core Audio process taps feeding one private aggregate device
is the right foundation for a driverless per-application volume mixer. The implementation should
not be replaced with AVAudioEngine, one aggregate per application, or an AudioServerPlugIn.

The current repository is nevertheless only demonstrated to be correct on its tested happy path:
a small number of controlled applications using a conventional interleaved Float32 stereo default
output. It is not yet a robust general sound-source manager.

The most important remaining work is not a change of audio technology. It is a refactor of source
lifecycle, graph transactions, and format validation:

1. Discover and validate the actual aggregate input and output stream layout before starting IO.
2. Make graph rebuilds transactional and report a source as controlled only after IO starts.
3. Stop and destroy the aggregate before destroying a tap that it contains.
4. Separate persistent source preferences from discovered processes, live taps, graph slots, and
   renderer state.
5. Add activity-driven source reconciliation and bounded tap retention.

## What was reviewed

- Sources/BuriedAnchor/AudioObject.swift
- Sources/BuriedAnchor/Permission.swift
- Sources/BuriedAnchor/ProcessRegistry.swift
- Sources/BuriedAnchor/TapEngine.swift
- Sources/BuriedAnchor/Render.swift
- Sources/BuriedAnchor/MixerModel.swift
- Sources/BuriedAnchor/App.swift
- Sources/BuriedAnchor/Settings.swift
- Sources/BuriedAnchor/SelfTest.swift
- Package.swift, Makefile, Resources/Info.plist, README.md, PLAN.md, and CLAUDE.md
- Core Audio declarations in the installed macOS 27 SDK
- Apple's current Core Audio tap and aggregate-device documentation

## What is already correct

### Core Audio topology

One tap per logical application, with all taps inserted into one private aggregate device, is a
good topology. It gives the application one IOProc, one hardware output path, and one positional
mapping to maintain. It avoids multiplying aggregate devices and IOProcs for no corresponding
audio benefit.

This agrees with Apple's supported model: a process tap becomes an input source in an aggregate
device configured for playback. See [Capturing system audio with Core Audio
taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps).

### Realtime boundary

MixRenderer has the right basic realtime discipline:

- fixed-capacity storage is allocated before rendering;
- gain targets, current gain, meters, and clipping state cross threads through atomics;
- the callback takes no locks;
- it performs no logging or Foundation work;
- gain changes do not rebuild the audio graph;
- the gain transition is smoothed rather than changed discontinuously.

This is the correct separation between control-plane work on the main actor and sample processing
on the Core Audio IO thread.

### Mute and suspension semantics

CATapMuteBehavior.mutedWhenTapped is the right behavior for this product. The Core Audio header
defines it as passing audio to hardware until another client reads the tap, then suppressing the
direct path for the duration of that read activity. Consequently, tearing down the IOProc when all
controlled gains are at unity safely returns applications to direct playback.

Keeping a live application's tap while its slider crosses 100% is also sensible. It avoids
rebuilding the shared aggregate repeatedly during ordinary slider movement.

### Process grouping

ProcessRegistry correctly treats raw Core Audio process objects as transient implementation details
rather than user-visible sources. Walking the parent PID chain to find the owning regular or
accessory NSRunningApplication is substantially better than relying on the raw process bundle ID,
which can be missing, duplicated, or associated with a helper.

Grouping multiple process objects under one application row matches the stated per-application
product behavior. Sorting member object IDs makes description comparisons deterministic.

### Process restoration

Setting isProcessRestoreEnabled is appropriate. Apple documents that it saves tapped processes by
bundle ID when they exit and restores them to the tap when they start again. See
[isProcessRestoreEnabled](https://developer.apple.com/documentation/coreaudio/catapdescription/isprocessrestoreenabled).

This makes the current object-ID-based tap more resilient to helper restart churn. It does not
replace the need for a coherent application-level lifecycle model.

### Permission, signing, and launch behavior

The repository handles several non-obvious TCC requirements correctly:

- NSAudioCaptureUsageDescription is present;
- permission is probed through kAudioTapPropertyDescription rather than inferred from silent
  samples;
- the Makefile refuses ad-hoc signing;
- the application is launched through LaunchServices rather than by executing the inner binary;
- the app is a menu-bar-only LSUIElement application;
- default-output changes trigger graph reconstruction.

These decisions eliminate common cases where the IOProc runs normally but every captured sample is
zero because system-audio access was silently denied.

### SwiftUI structure

The use of @MainActor @Observable for MixerModel, stable row IDs in ForEach, native MenuBarExtra,
and a native Settings scene is sound. The UI is not the primary architectural problem.

## Prioritized findings

### High: renderer correctness depends on an unvalidated buffer layout

Relevant code:

- [Render.swift](Sources/BuriedAnchor/Render.swift#L82)
- [TapEngine.configureRenderer](Sources/BuriedAnchor/TapEngine.swift#L198)

The renderer assumes all of the following:

- aggregate input buffer i is tap order[i];
- each tap is represented by exactly one AudioBuffer;
- samples are Float32;
- source and destination channel/sample layouts are compatible;
- the destination is completely represented by outputs.first;
- the first tap's sample rate is sufficient to configure the whole renderer.

Only the sample rate of the first tap is read. Its format flags, bytes per frame, channel count, and
interleaving are not validated. The output stream format is not inspected at all. The callback
casts buffer memory directly to Float and clears and writes only the first output buffer.

This is valid for the empirically observed interleaved Float32 stereo configuration. It is not a
general Core Audio guarantee established by this repository.

Failure cases include:

- output devices exposing more than one output buffer or stream;
- non-stereo or spatial/multichannel output;
- a channel count different from the stereo tap mixdown;
- a format that is not compatible Float32 PCM;
- stream-layout changes without a change of default device;
- a duplex subdevice contributing aggregate input streams in addition to tap streams.

The duplex-device case is an inference from aggregate-device semantics, not a reproduced failure in
this review. Apple describes an aggregate as combining input and output streams from real devices
and taps, and documents stream order as significant. The current code does not discover any input
offset, so the assumption that tap zero must always be input buffer zero remains unproved. See
[AudioHardwareAggregateDevice](https://developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice).

There is also a deliberate fidelity limitation: every source uses
CATapDescription(stereoMixdownOfProcesses:). Even if rendering is otherwise correct, a multichannel
or spatial source is collapsed to stereo. That limitation should either be explicit in the product
scope or removed through per-device/per-stream handling.

Recommended correction:

1. Inspect the aggregate input and output stream configuration after creation.
2. Read and validate every relevant stream's virtual format.
3. Build an explicit source-to-input-buffer mapping instead of assuming slot equals buffer index
   without runtime validation.
4. Initially reject unsupported layouts and leave applications on their direct path. A visible
   unsupported-output-format error is safer than corrupt or misrouted audio.
5. Add synthetic renderer tests for interleaved and non-interleaved layouts, multiple buffers,
   unequal buffer sizes, missing data pointers, and multichannel destinations.

### High: tap destruction occurs while the aggregate can still use the tap

Relevant code: [TapEngine.release](Sources/BuriedAnchor/TapEngine.swift#L73)

Release currently performs these operations:

1. remove the tap from the dictionaries and order;
2. destroy the process tap;
3. call rebuild;
4. rebuild then stops IO and destroys the old aggregate.

This reverses the safe resource dependency order. Before rebuild stops IO, the old aggregate and
IOProc can still reference the tap being destroyed. If destruction fails because the tap is in use,
the return status is ignored and the tap has already been removed from application state, so it can
become an untracked resource.

The correct removal order is:

1. stop aggregate IO;
2. destroy the IOProc;
3. destroy the aggregate;
4. destroy taps that are no longer desired;
5. create the replacement aggregate;
6. validate its stream layout;
7. create and start the replacement IOProc.

Every Core Audio destruction call should have its status checked and logged. State should only
forget an object after the operation succeeds or after the object is known to be invalid.

### High: tap existence is conflated with successful control

Relevant code:

- [TapEngine.isControlled](Sources/BuriedAnchor/TapEngine.swift#L50)
- [TapEngine.rebuild](Sources/BuriedAnchor/TapEngine.swift#L143)
- [TapEngine.startIO](Sources/BuriedAnchor/TapEngine.swift#L229)

The engine reports a source as controlled whenever its tap exists. A tap can still exist when:

- default-output resolution failed;
- aggregate creation failed;
- IOProc creation failed;
- AudioDeviceStart failed.

In those states the source is not being processed, but the UI can mark it as controlled. Later gain
changes see the existing tap and update only the renderer target; they do not retry aggregate or IO
startup. A transient startup failure can therefore become permanent until a default-device event,
manual reset, or application restart happens to force another rebuild.

startIO also stores the newly created IOProc before calling AudioDeviceStart. If the start call
fails, the IOProc is retained and the engine has no immediate retry path.

Recommended correction:

- represent runtime state explicitly: unprepared, prepared, active, suspended, or failed(error);
- define isControlled as membership in a successfully validated active or intentionally suspended
  graph, not dictionary membership;
- destroy the newly created IOProc immediately after a start failure;
- keep desired gains independently of active runtime state;
- retry transient failures with bounded backoff or on relevant HAL changes;
- preserve direct playback on failure by ensuring no client reads a mutedWhenTapped tap from an
  invalid graph.

### Medium-high: source allocation grows monotonically

Relevant code:

- [TapEngine.setGain](Sources/BuriedAnchor/TapEngine.swift#L54)
- [MixerModel.reset](Sources/BuriedAnchor/MixerModel.swift#L144)

An application receives a tap the first time it leaves 100%, and that tap remains until the user
uses the row's context-menu reset or quits Buried Anchor. This deliberately avoids rebuilds near
unity, but a long-running login-item process only consumes tap capacity and never recovers it
automatically.

Consequences:

- touching 32 applications over a long session exhausts the fixed slot limit;
- exited applications retain slots;
- a disappeared source remains represented by a synthetic controlled row;
- capacity recovery depends on discovering a context-menu action;
- rebuild cost grows with historical use rather than current need.

This is not an immediate happy-path bug. It is an incomplete retention policy.

Recommended correction:

- retain live taps across movements through 100%;
- retain recently active taps for a debounce or linger interval;
- remove absent taps after a longer idle interval;
- batch removals so several expired sources cause one aggregate rebuild;
- use least-recently-used inactive eviction near the 32-slot cap;
- never delete the persistent gain preference when evicting only the runtime tap.

### Medium-high: suspension follows desired gain, not source activity

Relevant code: [MixerModel.updateSuspension](Sources/BuriedAnchor/MixerModel.swift#L109)

The IOProc suspends only when every retained tap has exactly unity gain. If a source is saved at 50%
and the application exits, the source is silent but its non-unity target prevents suspension.
Buried Anchor can keep reading the aggregate, keep the system-audio indicator visible, and keep the
output device active indefinitely even though no controlled application is producing audio.

This behavior buys immediate processing if the application returns, but it is a poor energy and
privacy tradeoff for a login item unless made explicit.

Activity-aware suspension requires reliable wakeup signals. The engine should reconcile:

- desired non-unity gain;
- presence of process objects;
- kAudioProcessPropertyIsRunningOutput state;
- whether the graph is active or suspended.

If no relevant source has active output, IO can be suspended while retaining a bounded set of taps.
When an observed process becomes active, the engine should resume immediately. Whether the first few
frames can pass at direct gain needs a measured latency test.

### Medium: saved gain can miss the beginning of playback

Relevant code: [MixerModel.refreshList](Sources/BuriedAnchor/MixerModel.swift#L194)

For a source that has a saved non-unity gain but no current tap, the model creates the tap only when
the one-second reconciliation observes group.isPlaying as true. The system-wide process-object-list
listener fires when membership changes, but it does not fire merely because an existing process
changes its IsRunningOutput property.

The implementation plan explicitly called for per-process
kAudioProcessPropertyIsRunningOutput listeners, but the implementation contains only the
process-list listener and a one-second polling backstop.

A short notification or the beginning of ordinary playback can therefore pass through at its
original gain before the model notices activity and rebuilds the graph.

Recommended correction:

- maintain RAII property listeners for currently discovered process objects;
- reconcile immediately when their running-output state changes;
- for a present application with a saved non-unity preference, prepare its tap before it begins
  output rather than waiting for isPlaying;
- keep polling as a backstop rather than the primary activity signal.

### Medium: one string carries too many meanings

Relevant code:

- [ProcessRegistry.identify](Sources/BuriedAnchor/ProcessRegistry.swift#L84)
- [MixerModel persistence](Sources/BuriedAnchor/MixerModel.swift#L38)
- [TapEngine dictionaries](Sources/BuriedAnchor/TapEngine.swift#L17)

The same string acts as:

- user-visible row identity;
- persistence key;
- discovered application-group identity;
- tap dictionary key;
- aggregate ordering key;
- renderer ownership key.

The primary owning-application bundle-ID case is stable enough for per-application behavior. The
fallback cases are weaker:

- exec:comm uses a short process command name and can merge unrelated processes sharing a name;
- p_comm can be truncated;
- pid:n is unique only for one process lifetime and cannot support durable preferences;
- a future ownership-resolution change can orphan saved settings.

Recommended correction:

- introduce a typed SourceID with bundle, executable, and ephemeral cases;
- make only durable identities eligible for long-term persistence;
- retain actual member process bundle IDs separately from the owning application identity;
- treat object IDs, tap IDs, and renderer slots as ephemeral runtime identifiers;
- version the persisted preference schema so identity improvements can be migrated deliberately.

### Medium: graph reconstruction is not transactional

Rebuild destroys the current working aggregate before it knows whether the replacement can be
created and started. Some interruption is inherent when reusing taps, but state publication can
still be transactional.

At present, order, taps, renderer slot count, error state, aggregate ID, and IOProc ID can represent
different stages of a transition. Main-actor isolation prevents concurrent control-plane mutations,
but it does not make a multi-call HAL operation atomic.

Recommended correction:

- calculate the complete desired graph specification first;
- stop the old graph;
- perform HAL mutations in dependency order;
- validate the new graph;
- prime every renderer slot;
- start IO;
- only then publish the active slot map and controlled state;
- on failure, clean up every newly created resource and publish an explicit pass-through state.

### Medium: default-device recovery is narrower than device reconfiguration

The engine listens for kAudioHardwarePropertyDefaultOutputDevice, correctly handling common
headphone and route switches. It does not listen for:

- stream-configuration changes on the same device;
- virtual or actual sample-rate changes;
- buffer-frame-size changes;
- abnormal IO stoppage;
- device-alive or broader device-configuration changes.

The ramp coefficient is configured from buffer size and the first tap's sample rate only during a
rebuild, so an in-place change can also leave it stale.

The initial production scope can remain small, but unsupported changes should be detected and cause
a controlled graph rebuild or pass-through state.

### Medium-low: persistence values are rounded but not validated on load

Relevant code: [MixerModel.init](Sources/BuriedAnchor/MixerModel.swift#L58)

Slider input is clamped to 0–150%, but values loaded from UserDefaults are only rounded. Corrupt,
manually edited, or old-schema values can bypass the bounds and be applied directly during
refreshList.

Clamp saved percentages and pre-mute values during load, discard non-finite values, and write the
normalized representation back once.

### Medium-low: cache and linger behavior loses source presentation

When a controlled application disappears, the synthetic row is created before the linger fallback
and uses the raw key as its name with no icon. The source remains functionally represented but loses
its last known application name and icon.

forgetTerminated also filters appCache by comparing its key against live bundle IDs. Entries whose
keys use pid: cannot survive that filter even if the corresponding application is otherwise useful.
This mainly creates repeated resolution work rather than an audio error.

A persistent runtime SourceRecord should retain last-known presentation independently of current
process membership.

### Low: the SwiftUI model invalidates more UI than necessary

rows is an array of value-type rows. Meter refreshes mutate elements of that observed array at 10 Hz,
so views depending on it can re-evaluate broadly when only one source meter changed. refreshList
also assigns a newly constructed array every second, and Row is not Equatable.

At the current 32-row cap this is unlikely to dominate performance. A per-source observable record
would nevertheless align the UI with the recommended source lifecycle and allow one row's meter or
playback state to invalidate only that row.

outputDeviceName is a computed property backed by non-observable TapEngine state. It currently
repaints incidentally when other model properties change. It should be stored or explicitly
published by MixerModel when the engine reports a route change.

### Low: hardware self-tests are diagnostics, not regression tests

Relevant code: [SelfTest.swift](Sources/BuriedAnchor/SelfTest.swift#L115)

The self-test modes are valuable because behavior depends on TCC, signing, LaunchServices, and
physical hardware. They do not provide a complete automated pass/fail contract:

- several output lines are labelled PASS without numeric thresholds;
- failures generally log text but do not produce a nonzero exit status;
- tests change real persisted percentages and do not restore them;
- they do not cover failure recovery or resource cleanup;
- documented measurements are not asserted by code.

These should remain integration tests, but they should restore preferences and return meaningful
status. Pure logic should be extracted so source reconciliation and renderer behavior can be tested
without TCC or hardware.

## Recommended source model

The word source currently refers interchangeably to an application row, a changing set of Core
Audio process-object IDs, a process tap, and a renderer slot. Those have different lifetimes and
should be separate.

~~~
SourcePreference
  stable SourceID, desired gain, saved pre-mute value

SourceSnapshot
  current process IDs, member bundle IDs, activity, route, presentation

                    reconciliation
                         |
                         v

TapRuntime
  tap object ID, UUID, captured membership, lifecycle state

GraphRuntime
  aggregate ID, IOProc ID, validated formats, explicit source/slot/buffer mapping

                         |
                         v

Renderer
  fixed active mapping, atomic gain targets, current gains, meters
~~~

The exact Swift declarations can vary. The important invariants are:

- a saved gain can exist without a tap;
- a tap can exist without being falsely reported as active;
- process object IDs never become persistent identities;
- renderer slots exist only inside one successfully committed graph;
- source-to-buffer mapping is validated rather than assumed.

## Recommended lifecycle

### Adding a source

1. Update the desired source preference.
2. Resolve the current source snapshot.
3. If no eligible process exists, retain the preference without claiming active control.
4. Create the tap from current member process IDs and known member bundle IDs.
5. Rebuild and validate the graph.
6. Start IO.
7. Publish the source-to-slot map only after success.

### Updating source membership

1. Reconcile member process IDs from process-list and per-process listeners.
2. Update the tap description without changing the aggregate when Core Audio accepts it.
3. Keep the tap UUID and graph slot stable.
4. On failure, retain the last working membership and surface an error.

### Returning a live source to unity

1. Set its renderer target to 1.0.
2. Keep the tap while the source remains live or recently active.
3. If every active retained source is at unity, suspend IO after the current debounce.
4. Do not rebuild merely because the slider crossed 100%.

### Removing or evicting a source

1. Choose absent or inactive sources using timeout or LRU policy.
2. Batch multiple removals where possible.
3. Stop IO and destroy the old aggregate first.
4. Destroy evicted taps and check every status.
5. Rebuild, validate, and start the replacement graph.
6. Keep saved preferences unless the user explicitly requested a full reset.

### Failure

1. Stop reading taps so mutedWhenTapped returns applications to direct output.
2. Destroy any partially created IOProc or aggregate.
3. Keep desired preferences separately.
4. Mark affected sources as failed or pass-through, not controlled.
5. Retry only on a relevant event or bounded backoff.

## Verification gaps and proposed test matrix

### Pure tests

- grouping multiple helpers into one owning application;
- PID reuse with process start-time changes;
- executable-name collisions and ephemeral identities;
- source present, absent, and playing transitions;
- a persisted non-unity preference becoming active;
- unity retention followed by inactivity eviction;
- LRU eviction at the slot limit;
- graph state after each injected HAL failure;
- removal of a middle slot without source crossover;
- renderer gain and ramp behavior using synthetic AudioBufferList values;
- multiple input and output buffers;
- non-interleaved stereo and unsupported-format rejection;
- persistence normalization and migration.

### Hardware integration tests

- built-in stereo speakers;
- a duplex USB headset or interface;
- a device exposing more than two output channels;
- Bluetooth music and call-mode transitions;
- sample-rate changes with the same default-device UID;
- repeated default-device switches;
- source exit and relaunch with process restoration;
- helper-process addition and removal while playing;
- 32-source pressure and inactive eviction;
- aggregate-creation, IOProc-creation, and device-start recovery;
- a long-running session to detect zero-filled taps or abnormal IO stops;
- application shutdown with no leaked private taps or aggregates.

For hardware tests, record the discovered input/output buffer structure and ASBDs in non-realtime
setup code. That evidence is more useful than assuming every machine matches the original probe.

## Suggested implementation order

1. Fix tap removal ordering and check every HAL lifecycle status.
2. Introduce explicit graph and tap runtime states and correct isControlled semantics.
3. Validate input/output stream layouts and reject unsupported configurations.
4. Extract a pure source reconciler and add failure-injected unit tests.
5. Add per-process running-output listeners.
6. Separate preferences, snapshots, tap runtime, and graph slots.
7. Add inactive retention and LRU eviction.
8. Improve device reconfiguration listeners and retry behavior.
9. Convert rows to granular observable source records if profiling shows UI invalidation cost.
10. Expand the signed hardware-test matrix.

## Final assessment

The repository's research and central Core Audio choice are better than the typical first version of
this kind of application. The single-aggregate topology, realtime gain path, process grouping,
permission diagnosis, and suspension mechanism are all worth keeping.

The weak point is lifecycle modeling. A user-facing application, a Core Audio process object, a tap,
an aggregate input buffer, and a renderer slot are currently connected mostly by convention and one
string key. That is enough for controlled experiments, but not enough for arbitrary device layouts,
transient HAL failures, long-running source churn, or a 24/7 login item.

The correct next move is a focused refactor, not a rewrite: preserve process taps and the shared
aggregate, then make their state explicit, transactional, format-aware, and bounded.

## Verification performed for this review

The repository's own build command was run in a separate non-focused agterm session:

~~~
make build
swift build -c debug
Build complete! (0.52 sec)
EXIT=0
~~~

Environment:

- Apple Swift 6.4
- macOS 27 SDK from Xcode 27.0 beta 5
- arm64 target

The available /tmp/buriedanchor-selftest.log contained a successful suspension cycle:

~~~
A 50%: peak=0.1250 controlled=true
B 100%: peak=0.0049 controlled=true
C 50% again: peak=0.1258 controlled=true
PASS suspended at 100%
PASS resumed at 50%
PASS tap kept across the cycle
~~~

No signed live-audio, TCC-reset, multi-source, or device-switch test was run as part of this review.
Those tests affect real audio routing, system permission state, and persisted preferences. No
implementation files were changed during the analysis.
