# Buried Anchor

A menu-bar volume mixer for macOS that sets each app's volume separately, from 0% to 150%.
Turn down a noisy browser tab or chat app, mute one app completely, or boost a quiet one, without
touching the system volume. No audio driver, no kernel extension, no admin install.

Requires macOS 26 or later.

## Install

Building needs one of your own code-signing identities:

```
make identities                                  # list what you have
echo 'IDENTITY = <40-char hash>' > local.mk
make install                                     # release build into /Applications
```

On first use, macOS asks for permission to capture system audio. Grant it, or no app can be
controlled.

## Use

Click the menu-bar icon. Every app that is playing, or recently played, gets a row with a slider.

- Drag the slider to set the app's volume. Double-click it to return to 100%.
- The mute button mutes the app and later restores its previous volume.
- Right-click a row and choose Reset to forget the app's saved setting.
- A warning icon means the app is waiting for audio, plays through an unsupported output, or could
  not be controlled.

Settings are remembered per app. Settings also offers launch at login and optional soft saturation
for the controlled mix.

## Limitations

- Only apps playing through the default output with a mono or stereo device are controlled. Others
  are shown as unsupported and left alone.
- Changing which apps are controlled, or switching output devices, can cause a brief audio
  interruption, and the very start of a sound can slip through before control takes over.
- If control fails, the app plays at its normal volume rather than the requested one.

## Troubleshooting

The app keeps a diagnostic journal at `~/Library/Logs/BuriedAnchor/events.jsonl` (reachable from
Settings → Diagnostics). If a sound leaks through a mute, keep that file and its numbered archives
and note when it happened and which app played it.
