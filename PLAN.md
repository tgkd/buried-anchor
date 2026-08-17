# buried-anchor — per-app volume mixer (0–150%)

## Part 1 — Judgment of the research plan

**Verdict: the core recommendation is right, the architecture is wrong, and several load-bearing details are wrong.** Build on Core Audio process taps. Do not build the AudioServerPlugIn fallback. Replace "one tap + one aggregate per app" with "N taps in one aggregate".

Everything below marked ✅/❌ was verified on this machine (macOS 27.0 / 26A5406e, arm64, Xcode 27, Swift 6.4) with a signed probe app, not reasoned from docs.

### Confirmed correct

- ✅ No per-process volume API exists. Grepped `AudioHardware.h`: no volume/gain selector in any process, tap, or client scope.
- ✅ `AudioHardwareCreateProcessTap` / `AudioHardwareDestroyProcessTap`, `macos(14.2)`.
- ✅ All aggregate + sub-tap keys exist as quoted: `taps`, `tapautostart`, `uid`, `drift`, `master`, `private`, `subdevices`.
- ✅ Process objects: `kAudioHardwarePropertyProcessObjectList` (`prs#`), `kAudioProcessPropertyPID`/`BundleID`/`IsRunning`/`IsRunningInput`/`IsRunningOutput`.
- ✅ Swift spellings `uuid`, `name`, `isPrivate`, `isMono`, `isExclusive`, `isMixdown`, `muteBehavior`, `deviceUID`, `stream`, `processes` all compile.
- ✅ Tap format is float32, non-interleaved, 48 kHz, 2 ch (`flags=9`, `bits=32`).
- ✅ Single `AudioDeviceIOProcID` on the aggregate is sufficient. No `AVAudioEngine`, no ring buffer, no second IOProc — the same callback delivers tap input and device output.
- ✅ Over-unity gain works. Measured `4.0 × 0.05 = 0.2000` exactly at the output stage.
- ✅ `.mutedWhenTapped` suppresses the app's direct path — no doubled audio.

### Wrong, with evidence

**❌ 1. One aggregate per app is unnecessary — this is the biggest error.**
The plan asserts per-app aggregates are "the clean way to get independent gain". Tested with two `afplay` sources at amplitudes 0.20 and 0.05, two taps, **one** aggregate:

```
agg INPUT  streams: [(0, 2), (1, 2)]      <- one input stream per tap
agg OUTPUT streams: [(0, 2)]              <- one output, must sum into it
inBuf[0] peak=0.19999   inBuf[1] peak=0.05002
```

Input buffer index maps to tap-list order, and capture is bit-exact per app. One aggregate, one IOProc, one drift domain, one TCC surface, one teardown path. The per-app design multiplies device count, IOProcs, and rebuild paths for nothing.

Its one genuine advantage: adding/removing an app means rebuilding the shared aggregate, which briefly interrupts *all* controlled apps. Mitigation is in Part 2 (§4).

**❌ 2. `kAudioAggregateDeviceTapAutoStartKey` semantics are misstated.**
Plan: *"required; tap-as-main-sub-device with empty sub-device list silently produces zero samples."* The header says it makes `AudioDeviceStart` **wait for the first tap to receive audio**. I ran every successful test with it set to `false` and got audio immediately. It is a deferred-start optimization, not a correctness requirement. Set `false`.

**❌ 3. `kAudioHardwarePropertyProcessPID` does not exist.** The real selector is `kAudioHardwarePropertyTranslatePIDToProcessObject` (`id2p`). Use it instead of scanning the list to map PID → object.

**❌ 4. `isMono` and `mixdown` are conflated.** They are two independent properties (`mono`, `mixdown`), not one boolean under two names.

**❌ 5. The TCC mechanism is mischaracterized, and the real behavior is a dev-loop landmine.**
Plan: the prompt *"only fires on a signed binary with deployment target ≥ 14.4."* Not the mechanism. What actually governs it is TCC **responsible-process attribution**. The identical Developer-signed bundle with `NSAudioCaptureUsageDescription`:

| launch method | result |
|---|---|
| `./TapProbe.app/Contents/MacOS/TapProbe` from terminal | **silently denied**, no prompt |
| `open -a TapProbe.app` (LaunchServices) | prompt shown, granted, audio flowed |

Run from a terminal, the *terminal* is the responsible process; it has no usage description, so TCC auto-denies with no UI. Any dev loop that runs the binary directly will look permanently broken.

**❌ 6b. A global tap cannot be used to check whether muting worked.** (Added after the
device-capture fix; the mistake cost several test cycles.) The obvious instrument for "did this app's
audio actually reach the speakers" is `CATapDescription(monoGlobalTapButExcludeProcesses:)` in its own
aggregate. It does not work: the global tap is taken at the same point as a process tap, **before**
per-process mute is applied to the device path. Measured with a 440 Hz tone at amplitude 0.025, the
monitor read `0.0250` in all three states — unmuted pass-through, `.mutedWhenTapped` with our IOProc
running (the shipped, known-working mute), and `.muted` with no IOProc. A run that appears to show a
drop is contamination from some other process in the mix, not the target being silenced. There is no
HAL-level instrument for this; whether a mute is audible has to be checked by ear.

**❌ 6. The "all-zero buffers" bug is over-attributed to an unresolved Apple bug.**
Plain TCC denial presents **identically**: IOProc fires with valid timestamps at full rate, every sample `0.0`. My first run: 326 cycles, peak `0.00000`. Do not build a teardown/rebuild watchdog around that symptom without first discriminating the cause. The reliable discriminator is real and worth building in:

```
AudioObjectSetPropertyData(tap, kAudioTapPropertyDescription, ...) == kAudioDevicePermissionsError
```
`kAudioDevicePermissionsError` is `'!hog'` = `560492391`. (The plan's suggested "detect all-silent buffers" is the ambiguous signal, not the answer.)

**❌ 7. The process list problem is far worse than "group Electron helpers".**
Idle machine, 30 process objects, nearly all invisible daemons — `com.apple.CoreSpeech`, `assistantd`, `audiomxd`, `TelephonyUtilities`, `replayd`, `systemsoundserverd`, `universalaccessd`, `cloudpaird`, `PowerChime`. Worse:

- `NSRunningApplication(processIdentifier:)` returns **nil for most** of them — no name, no icon.
- Bundle IDs are **nil** for some and **duplicated** across others (two `com.apple.WebKit.GPU`, two `com.tinyspeck.slackmacgap.helper`).
- The user-visible app is frequently **absent**: Slack appears only as `slackmacgap.helper`; Raycast only as `com.apple.WebKit.GPU` named "Raycast Beta Graphics and Media".

Bundle ID is not a key, and PID → app is not a lookup. This is a real subsystem, not a footnote.

**❌ 8. Missed the macOS 26 additions that solve two of the plan's own problems.**
`CATapDescription` gained `bundleIDs: [String]` and `processRestoreEnabled: Bool`, both `API_AVAILABLE(macos(26.0))`. `processRestoreEnabled` saves tapped processes by bundle ID on exit and **restores them when the app relaunches** — that is the app-restart churn problem, solved by the OS. `bundleIDs` lets one tap cover all of an app's helper processes. On macOS 27 these are free.

**❌ 9. Multi-channel attenuation did not reproduce.** Bluetooth output, capture was bit-exact (`0.19999` from `0.20`). Treat as unverified folklore; measure, don't pre-compensate.

### Missing from the plan

- **Apps pinned to a non-default output device.** Flagged only for the driver route, but it limits the tap route too: a process-mixdown tap follows the process, but the aggregate wraps *one* output device. If an app targets a different device, its scaled audio lands on the wrong one.
- **Format negotiation.** Tap is 48 kHz float32 here; the output device may differ. No resampling story.
- **Feedback risk.** The aggregate is a device; it must never become the tap target or the default output.
- **Milestones B and C are the same work.** "0–100%" then "extend to 150%" is one multiply split into two milestones. Collapse them.
- **Unity transparency conflicts with tap lifecycle.** Creating a tap when the slider leaves 100% switches the audio path mid-playback. Decide once (§4).

### Recommendation changes

1. **One aggregate, N taps.** Not N aggregates.
2. **Do not build the AudioServerPlugIn fallback.** It is roughly the whole project again, for pre-14.2 machines, requiring a root install and `sudo killall coreaudiod`. You are on macOS 27. Cut it; revisit only if you ever ship to strangers on old OSes.
3. **Target macOS 26.0**, not 14.4 — `bundleIDs` + `processRestoreEnabled` remove real work.
4. **Skip the soft-limiter in v1.** `vDSP_vsmul` + `vDSP_vclip` with a clip counter is enough to ship and measure. Add `tanh` saturation only if you actually hear clipping in use. Keep the 30 ms gain ramp — that one is not optional, zipper noise is immediate and obvious.

---

## Part 2 — Implementation plan

### 1. Shape

SwiftPM package + `Makefile` that assembles, signs, and `open`s a `.app` bundle. No Xcode project needed — this is exactly how the validation probe was built and run.

```
buried-anchor/
  Package.swift
  Makefile
  Resources/Info.plist
  Sources/BuriedAnchor/
    App.swift               MenuBarExtra(.window), LSUIElement
    MixerModel.swift        @MainActor @Observable, owns UI state
    AudioObject.swift       AudioObjectGetPropertyData wrappers
    ProcessRegistry.swift   process objects -> user-visible apps
    TapEngine.swift         taps + aggregate + IOProc lifecycle
    Render.swift            realtime mix, lock-free gain exchange
    Permission.swift        TCC probe via kAudioTapPropertyDescription
```

Non-negotiable in `Info.plist`: `NSAudioCaptureUsageDescription`, `LSUIElement = true`.
Non-negotiable in the Makefile: sign with the Developer ID/Development identity and launch via `open -a`. Never run the inner binary directly — it will be silently denied (§Part 1 ❌5).

### 2. `AudioObject.swift`

Generic property helpers, already proven in the probe: `arrayProp`, `scalarProp`, `stringProp` over `AudioObjectGetPropertyData` + `AudioObjectGetPropertyDataSize`, plus an `addr(selector, scope)` builder. Add `AudioObjectAddPropertyListenerBlock` wrappers returning a cancellation token.

### 3. `ProcessRegistry.swift` — the part the plan underestimated

Turn 30 raw process objects into the handful of rows a user recognizes.

- Enumerate `kAudioHardwarePropertyProcessObjectList`; read PID, bundle ID, `IsRunningOutput`.
- **Resolve to an owning app**: try `NSRunningApplication(processIdentifier:)`; on nil, walk the parent chain via `proc_pidinfo`/`KERN_PROC_PID` until an ancestor resolves to an `NSRunningApplication` with `.activationPolicy == .regular`. Cache PID → resolved app.
- **Group** every process object under its resolved app. One row per app, N tapped process objects behind it.
- **Filter** rows that resolve to nothing and are not `IsRunningOutput` — that removes the daemon noise.
- **Live updates**: listener on `kAudioHardwarePropertyProcessObjectList`, listener on each object's `kAudioProcessPropertyIsRunningOutput`, plus a 1 Hz reconcile poll as backstop.

Because a row owns multiple process objects, its tap is `CATapDescription(stereoMixdownOfProcesses: [all objects for that app])` — one tap per *app*, not per process. On macOS 26+ prefer `bundleIDs` + `processRestoreEnabled` so helper churn and app relaunch are handled by the OS.

### 4. `TapEngine.swift` — one aggregate, N taps

State: `[AppKey: (tapID, uuid, bufferIndex)]`, one aggregate, one IOProc.

**Tap lifecycle policy** (resolves the unity-transparency conflict): an app gets a tap the first time its slider moves off 100%, and **keeps it for the session** even if returned to 100%. Apps that were never touched stay completely outside the graph, bit-transparent. This keeps N at 1–3 in practice, which makes shared-aggregate rebuilds rare.

**Rebuild** (`addTap`/`removeTap`) is the only disruptive operation:
1. `AudioDeviceStop` + `AudioDeviceDestroyIOProcID`
2. `AudioHardwareDestroyAggregateDevice`
3. create/destroy the tap
4. recreate the aggregate with the full tap list, in a stable order
5. recompute `bufferIndex` = position in tap list — **validated: input buffer index == tap-list order**
6. new IOProc, `AudioDeviceStart`

Composition, exactly as validated:
```swift
kAudioAggregateDeviceMainSubDeviceKey: outputUID
kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]]
kAudioAggregateDeviceTapListKey: taps.map { [kAudioSubTapUIDKey: $0.uuidString,
                                             kAudioSubTapDriftCompensationKey: true] }
kAudioAggregateDeviceIsPrivateKey: true
kAudioAggregateDeviceTapAutoStartKey: false
```

**Default-device changes**: listener on `kAudioHardwarePropertyDefaultOutputDevice` → full rebuild against the new UID. This is the highest-frequency real-world failure (headphones, AirPods call mode) and must be handled from the start, not deferred to a "robustness" milestone.

**Guard**: never include the aggregate's own UID as the output device, and exclude our own PID from any tap.

### 5. `Render.swift` — the realtime callback

Allocation-free, lock-free, log-free. Gains cross the thread boundary through a fixed-size array of `atomic<Float>` targets indexed by buffer slot; the IOProc reads targets and ramps toward them locally.

```swift
vDSP_vclr(dst, 1, frames)
for b in 0..<min(ins.count, slotCount) {
    current[b] += (target[b] - current[b]) * coef
    vDSP_vsma(src, 1, &current[b], dst, 1, dst, 1, n)
}
vDSP_maxmgv(dst, 1, &peak, frames)
vDSP_vclip(dst, 1, &lo, &hi, dst, 1, frames)
```

`coef = 1 - exp(-1 / (fs * 0.03))`. Peak is published to the UI for a clip indicator. This is the validated code path — `vDSP_vsma` accumulate-into-output is what produced the exact `0.2000` measurement.

### 6. `Permission.swift`

On launch: create a throwaway global tap, attempt `AudioObjectSetPropertyData` on `kAudioTapPropertyDescription`, destroy it. `noErr` → granted. `kAudioDevicePermissionsError` (`'!hog'`) → denied; show an in-panel row linking to System Settings › Privacy & Security. Re-probe on activation. Reset during testing with `tccutil reset SystemAudioCaptureRequests <bundle-id>`.

### 7. `App.swift` / `MixerModel.swift`

`MenuBarExtra("...", systemImage:) { ... }.menuBarExtraStyle(.window)`. One row per resolved app: icon, name, `Slider(0...150)`, percent label, clip dot. `@MainActor @Observable` model (not `ObservableObject` — Swift 6). Slider writes percent/100 into the engine's atomic target; no rebuild, no lock, no glitch. Quit button, since there is no Dock icon.

### 8. Milestones

| # | Deliverable | Done when |
|---|---|---|
| M0 | Package, Makefile, signed bundle, `make run` via `open` | Empty menu bar app launches signed |
| M1 | `ProcessRegistry` + UI rows | Playing apps appear with correct name/icon; daemons absent; Slack shows as "Slack" |
| M2 | Permission probe + denied-state UI | Correctly reports granted/denied; survives `tccutil reset` |
| M3 | Engine: taps, shared aggregate, IOProc, gain 0–150% + ramp | Two apps, independent audible gain, one at 150% |
| M4 | Default-output-change rebuild | Switch output mid-playback, audio continues, gains preserved |
| M5 | Clip meter + optional `vvtanhf` soft-clip behind a toggle | 150% on loud source shows clip, soft mode removes it |

M3 is the only milestone with real unknowns left, and its architecture is already validated end-to-end.

### 9. Deferred / cut

- AudioServerPlugIn driver — **cut**, per Part 1.
- App Sandbox — deferred; non-sandboxed Developer ID first.
- Apps pinned to a non-default output device — known limitation, document it.
- Resampling for tap/output format mismatch — measure first, both were 48 kHz here.
