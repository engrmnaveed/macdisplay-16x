# Changelog

## Unreleased

Advanced scaling. Each feature below is off until you turn it on, in Settings under Advanced or with `display16x set overridesEnabled on`, `virtualScreens on` and `mirrorHiDPI on`, and each says what it costs next to its switch.

### More sizes through display overrides

- Add sizes macOS does not offer, for any model of display: fine HiDPI steps across the panel's range (`display16x override flexible --tag 2`), sizes of your own at either density (`display16x override add 2592x2304 --tag 2`), and the panel size, the size macOS picks first, the name macOS shows and whether the display counts as a television. Sizes are typed as the display shows them, turned or not.
- Nothing is written until you have seen it. The preview names every display the file reaches (an override is for a model, so every unit of it), every step, and the file byte for byte. Writing asks for your administrator password in macOS's own dialog.
- Display 16X then reconnects the display so macOS reads the file, and reads back which sizes macOS offers: macOS 27 leaves out some sizes without saying so, and the app tells you which. The main display is not reconnected by the app; replug its cable or log out.
- Remove one override, undo the last change to one, or remove every one the app wrote, from the panel or with `display16x override delete all`. That works without the app too, after a crash or once the app is gone: every file the app writes carries a marker, so it finds its files from the files themselves. A full reset can also move macOS's saved display arrangements aside, from where `display16x override put-back` restores them.

### Virtual screens

- Make screens that exist only in the Mac, for headless and remote use: `display16x virtual create Studio 16:9 2560x1440 hidpi @60 connect`. Sizes are generated from an aspect, a step and a limit, or listed by hand, at refresh rates up to 240 Hz, up to the window server's limit of 16384 pixels a side. A screen can copy the shape of a connected display, stand in portrait, and report its own name, serial number and size.
- Connect, disconnect, reconnect or discard one screen or all of them. A disconnected screen keeps its definition. Discarding also removes the color profile macOS made for it.
- Saved screens come back when the app starts and after a wake. A screen linked to a display connects and disconnects with it, and can turn with it. Automatic connects stop after three in two minutes and say so. macOS moves your displays aside when a screen appears; the app puts them back.
- A virtual screen is never counted as a physical display, so the last real display in use is never taken out because a virtual one is there.

### Mirror-based HiDPI

- For a panel macOS gives no HiDPI size of its own, a matched HiDPI virtual screen can be shown on it: `display16x virtual create "LG HiDPI" match mirror=on connect --tag 2`. This keeps the GPU busy with a copy of the whole screen at every refresh, so it has its own switch, starts only for a screen you linked this way, ends when the switch is turned off, and `display16x status` says while it runs.

### What was checked on hardware

On an Apple M5 Pro Mac with macOS 27.2.1, with probes and not yet through the app: an override for the LG SDQHD written to `/Library/Displays`, read by macOS after a reconnect, and removed again with the list exactly as before; one virtual screen created and removed while the probe kept running. The app's own write, the preview, virtual screens from the app and mirror-based HiDPI have run in unit tests only.

## 0.2.0

The first published release of Display 16X. It brings display layout and a redesigned interface, and it includes everything in 0.1.0 below, which was not published on its own. It needs an Apple silicon Mac with macOS 14 or later.

### Arrange your displays

- Make a display the main one, drag it on a picture of your desk drawn to scale, or put it next to another without the pointer (`display16x set placement left:end --tag 2 --of-tag 1`). Mirror one display onto another, and stop again. Each change asks **Keep** or **Revert** and goes back on its own after 15 seconds, and `display16x revert` puts the last layout change back.
- Take a display out of use without unplugging it, and bring it back, from the panel or with `display16x disconnect --tag 2` and `display16x reconnect --all`. The last display in use is never taken out unless you allow it. A disconnect lasts until you log out at most. The app reconnects what it disconnected when it quits, at its next start if it stopped unexpectedly, and at once if the last display in use goes away.
- Optionally turn the built-in panel off while an external display is attached, with displays you can exclude. It does nothing while the lid is closed. Off by default.
- Protection, off by default: save a layout and have it put back after sleep, after a reconnect and after a change made elsewhere, and keep a display's resolution or rotation the same way. It waits until displays have stopped coming and going, gives up after three attempts in two minutes, and says on screen what it did. After you keep an arrangement change, the app offers once to protect it.
- Scenes save the current sizes, rotation and arrangement, and brightness if you like, under a name. Apply one from the top of the panel, from the command line (`display16x preset apply Desk`) or with a keyboard shortcut.
- Global keyboard shortcuts for any command, recorded in the settings window or added with `display16x shortcut add ctrl+opt+1 set preset Desk`. They need no Accessibility permission, and a clash with your other shortcuts or with macOS's is pointed out.

### A new interface

- The panel has the app's own look, in navy and aqua. Each display is drawn to scale next to its name, brightness and volume are thick bars with the number beside them, and the text-size strip marks the default size with a dot.
- Each display has a page of its own, one level down: refresh rate, rotation, contrast, where its brightness comes from, what it does not offer and why, its place on the desk, and its options. The panel keeps its size and scrolls on a small screen.
- **Keep** or **Revert** says what changed ("Keep 2560 × 1440?"), what it goes back to and how long is left.
- A value says how it is known: read back from the display, only sent, as with software dimming, or not known yet, as just after a wake. A card says how the display is connected (HDMI, USB-C, Thunderbolt or built-in, named after the Mac's own port) and its size in inches.
- A settings window holds what applies to the whole app: opening at login, the keys, software dimming, scenes, shortcuts, the command line and links, the settings file, and About.
- What needs you comes first: a missing Accessibility permission with its steps, safe mode, a change that failed. The menu bar icon shows a dot when something waits for you, and is drawn dashed in safe mode.
- The on-screen indicator names the display a key reached. The app has an icon.

### Command line and settings

- Resolution by name (`default`, `native`, `previous`, `largest`, `smallest`), favourite modes, size steps along the text-size strip, and rotation in steps or as a toggle. Repeated size steps are gathered into one change.
- The brightness and volume keys reach every display that mirrors the one they target.
- Help for every feature (`display16x help placement`), `min` and `max` as values, a `perform` verb, JSON listings of a display's modes, inputs and identifiers, and raw DDC reads and writes (`display16x get vcp 0x10 --tag 1`; a write needs `--confirm`). A switch turns command line access off.
- `display16x list` and `display16x probe` say how each display is attached, and `get` says whether a value was read back from the monitor or only sent.
- `display16x://` links run commands, behind a switch of their own that is off by default and a token shown in the app, with x-callback-url callbacks.
- Export, import and reset all settings, in the settings window or with `display16x settings export`, `import` and `reset`. A scene or shortcut this version cannot read, for example one saved by a newer version, is left out and logged, and the rest of your settings are kept.

### What was checked on hardware

On an Apple M5 Pro Mac with macOS 27.2.1, a Lenovo P32p-20 and an LG SDQHD:

- Fourteen of the fifteen layout checks: arranging, the main display, placement, mirroring, disconnect and reconnect, from the command line and from the panel with **Keep** and **Revert**; reconnecting at quit; a scene from a shortcut; a layout put back after it was changed in System Settings; and the built-in panel turned off when the lid opens. They ran with the panel as it was before the redesign.
- The redesigned app, in daily use on that Mac since the evening of 23 November. It read both monitors at start and wrote nothing. The panel opened in 76 to 109 ms, the app used about 53 MB with the panel closed, and 0.03% of one core over ten idle minutes.

Not yet tried on hardware: a saved layout across a long display sleep with protection on, the built-in panel coming back when the last external display goes away, the offer to protect a kept arrangement, links, the brightness keys across a mirror set, and the redesigned panel's layout controls one by one. VoiceOver, full keyboard access, Increase Contrast, Reduce Motion and Reduce Transparency were checked in drawings of the interface, not with those settings switched on. What 0.1.0 lists below as not yet run still applies.

### Not included

Shortcuts app actions, which cannot be built with the Command Line Tools alone, and asking macOS to look for displays again.

### For developers

`scripts/render-surfaces.sh` draws every surface from made-up monitors without starting the app, and replaces the app's `--snapshot-panel` option. The look lives in `Design/Theme.swift` and `Design/Primitives.swift`. `DISPLAY16X_SUPPORT_DIRECTORY` gives a build its own settings folder and command socket, and such a build does not start while the normal copy runs. A release is prepared with `scripts/prepare-release` and tagged with `scripts/tag-release`.

## 0.1.0

The first version of Display 16X, a menu bar utility for the display controls macOS leaves out. It needs an Apple silicon Mac with macOS 14 or later. It was not published as a release on its own: 0.2.0 is the first release, and includes all of it.

- One card per display in the menu bar panel, with brightness, text size, refresh rate and rotation, and volume and input where the monitor supports them. The panel's content is built when it opens and released when it closes, and the app does nothing while nothing happens: no timers and no polling.
- Every resolution and HiDPI mode, including the scaled sizes macOS leaves out of its public mode list. Pick a size from the text-size strip, then **Keep** or **Revert**. A change left unanswered goes back on its own after 15 seconds. Rotation uses the same countdown.
- Hardware brightness, contrast, volume, mute and input on external monitors over DDC, with one queue per display so the latest value wins. Brightness is verified on a Lenovo P32p-20 and an LG SDQHD. Input switching has not been run on hardware yet.
- Native brightness for built-in and Apple displays. Built, and not yet tested on such a display.
- Software dimming through color tables, darker than a monitor's own minimum. It is off by default. Dimming left very dark is lifted to a readable level when the app starts and when you come back after the displays were off or the screen was locked for 30 minutes or more.
- Brightness and volume keys that work on a monitor that is not Apple's, with an on-screen indicator. They need the Accessibility permission, and the panel opens the right page in System Settings.
- At start, after wake and when a display comes back, the app reads each monitor and follows it, and writes nothing. For a monitor that forgets its values while asleep, switch on **Put my values back after sleep** in that display's details, or run `display16x set restoreAfterWake on`.
- Settings follow each monitor across restarts, sleeps, cable replugs and port changes, keyed by a tag the app assigns.
- Safe mode: hold Shift while the app starts, or pass `--safe`, and nothing is restored or reapplied automatically.
- Launch at login. Built, and not yet verified.
- The `display16x` command line tool, inside the app and linked by the Homebrew cask. `display16x probe` prints a read-only hardware report without the app, and is the thing to attach to a bug report. `get`, `set`, `step`, `toggle`, `keep` and `revert` go to the running app over a socket only your user can open, and each display's line says `confirmed`, `accepted` or `failed`.
- Settings are one JSON file in `~/Library/Application Support/com.16xbrains.macdisplay16x/`. Nothing leaves your Mac: there are no accounts and no telemetry.
- Each version tag publishes a GitHub Release with `display16x-X.Y.Z-macos-arm64.zip`, its SHA-256 file and a build-provenance attestation, and updates the `display16x` cask in the `engrmnaveed/tap` Homebrew tap. `docs/install.md` in the repository covers both ways to install.

Not yet run on hardware: a MacBook Air M1 with its built-in panel, an Apple display, a monitor that forgets its values in standby, a connection that carries video without DDC, two units of one model, and software dimming with a custom color profile or Night Shift.
