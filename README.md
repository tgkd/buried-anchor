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

One tap per controlled app, all taps in a **single private aggregate device** built around the
current default output device, with one `AudioDeviceIOProcID` on it.

- Each sub-tap contributes its own input stream to the aggregate. Which input buffer belongs to
  which app is **discovered after the aggregate comes up**, not assumed: the tap order is read back
  from `kAudioAggregateDevicePropertyTapList`, and the taps are located inside the aggregate's input
  buffer list by matching their channel counts, so any input streams a duplex sub-device contributes
  ahead of them are skipped rather than rendered as somebody's audio.
- The output side is mapped the same way. Every output stream's channel is given an explicit
  buffer/offset/stride, so non-interleaved devices get both buffers written and multichannel devices
  get the mix on their front pair with the rest cleared. A layout we cannot map — not 32-bit float,
  no output channels, taps that don't line up — is rejected: the graph is torn down, the panel shows
  why, and every app stays on its own direct output.
- Taps use `.mutedWhenTapped`, so an app's direct path is silenced only while we are reading it.
  We then re-render it at the chosen gain into the aggregate's output buffers.
- Gain is applied with `vDSP_vrampmuladd`, which multiplies by a per-frame ramp and accumulates
  into the output — gain and summing in one pass, with a 30 ms ramp so slider moves don't zipper.
- An app gets a tap the first time its slider leaves 100%, or as soon as it appears with a volume
  you saved earlier — before it starts playing, so the first notification chime is already at the
  level you chose. Apps you never touch stay entirely outside the graph and are bit-transparent.
- Once every controlled app is back at exactly 100%, *or* once none of them is running any more, the
  engine suspends itself after 1.5 s: the IOProc is torn down while the taps and the aggregate stay
  alive. Each app returns to its own bit-transparent output, and macOS drops the purple system-audio
  indicator. Any slider leaving 100% resumes it immediately, which costs one `AudioDeviceStart`
  rather than a rebuild.
- A tap whose app has been gone for five minutes is released, but only while the engine is suspended
  or nothing controlled is playing, so reclaiming a slot never interrupts audio. Your saved volume
  is kept; only the runtime tap goes. At the 32-slot cap a playing app can evict the
  least-recently-active idle one.

Above 100% the output can exceed full scale. Default is a hard clip at ±1.0 with a clip indicator;
Settings › Soft clip switches to `tanhf` saturation above a 0.7 knee.

## The panel

Each row has a mute button that drops the app to 0% and restores the previous level when pressed
again; the remembered level survives a quit. Right-click a row to reset it to 100% — that is a
different operation from dragging the slider back, because it also destroys the app's tap and takes
it out of the render graph entirely, returning it to bit-transparency and freeing one of the 32 tap
slots. Dragging to 100% deliberately keeps the tap, since releasing it there would rebuild the
shared aggregate every time the slider passed through 100 and interrupt every other controlled app;
the engine suspends instead, which reaches the same silence and the same dropped indicator without
touching the aggregate. Double-click a slider to snap it back to exactly 100%.

Settings (⌘, or the gear in the panel) holds "Launch at login", registered through
`SMAppService.mainApp`, and the soft-clip toggle, which persists across launches.

## Verified behavior

Measured on macOS 27.0 (arm64). Two players run the same 90 s tone at different source volumes so a
crossed slot would show up in the numbers: player A peaks at `0.0073`, player B at `0.0018`.

| Check | Result |
|---|---|
| Permission probe | `granted` (`kAudioTapPropertyDescription` set returns `noErr`) |
| Gain at 150% | `0.0110` = 0.0073 × 1.5, exact |
| Mute at 0% | `0.0000` |
| Two apps controlled at once | 50% / 150% → `0.0037` / `0.0027` |
| Gains swapped between them | → `0.0110` / `0.0009`; each row still tracks its **own** source amplitude, so the slot mapping did not cross |
| One muted, other untouched | `0.0000` / `0.0009` unchanged |
| Three taps in one aggregate | slots on input buffers 0,1,2, no error |
| Suspend at 100% | 50% → `0.0037`, 100% → `0.0002` (no render), 50% again → `0.0037`, tap kept |
| Suspend when the app exits | controlled app killed → graph suspends while its tap is kept |
| Saved volume applied before playback | app relaunched with a saved 50% is tapped as it appears |
| Default output change mid-playback | Bluetooth → built-in → Bluetooth, peak held at `0.0110` across both, slots preserved, no error |
| Layout on built-in speakers | `inputBuffers=[2]` for 1 tap, offset 0, output `[2]` interleaved float32 |
| Layout on a Bluetooth headset with a mic | `inputBuffers=[2,2]` for 2 taps, offset 0 — macOS exposes the mic as a **separate** device object, so it contributes no input stream |
| Renderer and layout resolver | 20 hardware-free checks, exit code 0 |

Carried over from the previous build and not re-measured: helper grouping (Slack's two process
objects collapse to one row), fallback to `exec:<name>` for processes with no bundle ID, and
`100.19` rounding to `100` on load so no tap is created.

The duplex case that the tap-offset discovery exists for — a sub-device that contributes its own
input streams ahead of the taps — has **not** been reproduced on real hardware. The Bluetooth
headset above does not do it. It is covered synthetically by `--render`.

### Self-test modes

All except `--render` must be launched via `open -a`, need real audio playing, append to
`/tmp/buriedanchor-selftest.log`, and end with a `RESULT pass` / `RESULT fail (n)` line. They restore
whatever volume the app had before the run.

| Mode | What it checks |
|---|---|
| `--render` | layout resolution and rendering against synthetic buffer lists — no HAL, no TCC, no audio. The only mode that may be run as the inner binary, which is how you get an exit code |
| `--layout <match>` | dumps the live aggregate's tap list, sub-taps, per-stream formats and buffer shapes |
| `--selftest <match> <pct> [--switch]` | boost, mute, and optionally a default-device switch mid-playback |
| `--multi <a> <pctA> <b> <pctB>` | two sources, gains swapped, then one muted |
| `--suspend <match>` | 50% → 100% → 50%, checking the middle step stops rendering but keeps the tap |
| `--watch <seconds>` | dumps the row list every 3 s; `*` playing, `!` rendering, `?` tapped but idle |
| `--loginitem` | round-trips the login-item registration |

The multi-app test needs two distinct rows, and row identity follows the *owning* app up the parent
chain — an `afplay` you start in a terminal groups under the terminal, not under itself. Wrap it in
a throwaway bundle per player to get its own row:

```
mkdir -p PlayerA.app/Contents/MacOS && cp /usr/bin/afplay PlayerA.app/Contents/MacOS/PlayerA
# Info.plist with CFBundleIdentifier com.example.PlayerA and LSUIElement
codesign --force --sign - PlayerA.app
open -a "$PWD/PlayerA.app" --args -v 0.03 tone.wav
```

## The row list and the waveform

Rows show apps that are playing now, apps played within the last 5 minutes, and any app whose volume
you have changed. The linger keeps short bursts — notification sounds, terminal bells — from flashing
in and out of the list, and it survives the app's audio process object disappearing entirely.

The animated waveform is an **activity indicator, not a calibrated meter**, and the distinction is
forced by the architecture. Real amplitude is only available for apps we tap, and an app is only
tapped once its slider leaves 100% — at exactly 100% it stays bit-transparent with no tap, so there
are no samples to measure. So: apps you have adjusted animate from their real output level; apps
playing at an untouched 100% animate at a fixed amplitude to show they are active; idle apps sit
flat and dim. Making every playing app show a true level would mean tapping everything, which gives
up bit-transparency at unity and routes audio you never asked us to touch through our render path.

## Known limitations

- Only apps playing to the **default output device** are affected. An app pinned to a different
  device is captured but its scaled audio lands on the default device.
- Every tap is a `stereoMixdownOfProcesses`, so a multichannel or spatial source is folded to stereo
  once you control it. On a multichannel output the mix lands on the front pair and the remaining
  channels are silent. Leaving such an app at 100% keeps it untapped and untouched.
- Adding or removing a controlled app rebuilds the shared aggregate, which briefly interrupts the
  other controlled apps. Changing a gain does not.
- Some processes cannot be traced to a user-visible app (`com.apple.WebKit.GPU` hosting Raycast
  audio, for example) and appear under their own name.
- If the default output device ever resolves to our own aggregate, the engine refuses to build and
  passes audio through untouched rather than creating a feedback loop.
- Not sandboxed. Developer ID signing + notarization would be needed to ship this to anyone else.
