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

- Each sub-tap contributes its own input stream to the aggregate. Input buffer index equals the
  tap's position in `kAudioAggregateDeviceTapListKey`, which is how a buffer maps back to an app.
- Taps use `.mutedWhenTapped`, so an app's direct path is silenced only while we are reading it.
  We then re-render it at the chosen gain into the aggregate's single output buffer.
- Gain is applied with `vDSP_vrampmuladd`, which multiplies by a per-sample ramp and accumulates
  into the output — gain and summing in one pass, with a 30 ms ramp so slider moves don't zipper.
- An app gets a tap the first time its slider leaves 100%, and keeps it for the session. Apps you
  never touch stay entirely outside the graph and are bit-transparent.

Above 100% the output can exceed full scale. Default is a hard clip at ±1.0 with a clip indicator;
Settings › Soft clip switches to `tanhf` saturation above a 0.7 knee.

## The panel

Each row has a mute button that drops the app to 0% and restores the previous level when pressed
again; the remembered level survives a quit. Right-click a row to reset it to 100% — that is a
different operation from dragging the slider back, because it also destroys the app's tap and takes
it out of the render graph entirely, returning it to bit-transparency and freeing one of the 32 tap
slots. Dragging to 100% deliberately keeps the tap, since releasing it there would rebuild the
shared aggregate every time the slider passed through 100 and interrupt every other controlled app.

Settings (⌘, or the gear in the panel) holds "Launch at login", registered through
`SMAppService.mainApp`, and the soft-clip toggle, which persists across launches.

## Verified behavior

Measured on macOS 27.0 (arm64) against a generated 0.20-amplitude tone:

| Check | Result |
|---|---|
| Permission probe | `granted` (`kAudioTapPropertyDescription` set returns `noErr`) |
| Gain at 150% | output peak `0.3000` = 0.20 × 1.5, exact |
| Mute at 0% | `0.0059`, decaying to zero |
| Two apps, one aggregate | separate streams, peaks `0.19999` / `0.05002`, no bleed |
| Two apps controlled at once | sources 0.10 / 0.04 at 50% / 150% → `0.0500` / `0.0600` |
| Gains swapped between them | → `0.1498` / `0.0206`, slot mapping holds, no crossover |
| One muted, other untouched | `0.0061` (decay) / `0.0206` unchanged |
| Default output change mid-playback | rebuilt on new device, peak held, no error |
| Helper grouping | Slack's 2 process objects collapse to one "Slack" row |
| Processes with no bundle ID | fall back to executable name (`exec:afplay`) |

`--selftest <match> <percent> [--switch]` and `--multi <matchA> <pctA> <matchB> <pctB>` run these
headlessly and write `/tmp/buriedanchor-selftest.log`. `--loginitem` round-trips the login-item
registration and reports `SMAppService` status at each step. All must be launched via `open -a`.

The multi-app test needs two distinct process names. Two instances of one binary collapse into a
single row by design, so make renamed copies and ad-hoc sign them (copying breaks the original
signature and the copy will not launch):

```
cp /usr/bin/afplay /tmp/tonePlayerA && codesign --force --sign - /tmp/tonePlayerA
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
- Adding or removing a controlled app rebuilds the shared aggregate, which briefly interrupts the
  other controlled apps. Changing a gain does not.
- Some processes cannot be traced to a user-visible app (`com.apple.WebKit.GPU` hosting Raycast
  audio, for example) and appear under their own name.
- If the default output device ever resolves to our own aggregate, the engine refuses to build and
  passes audio through untouched rather than creating a feedback loop.
- Not sandboxed. Developer ID signing + notarization would be needed to ship this to anyone else.
