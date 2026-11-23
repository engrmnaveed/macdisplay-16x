# Changelog

## Unreleased

Display layout, from v0.2 Layout. Fourteen of fifteen hardware checks ran on a Lenovo P32p-20 and an LG SDQHD: arranging, the main display, placement, mirroring, disconnect and reconnect from the command line and the panel with **Keep** and **Revert**, reconnecting at quit, a preset from a shortcut, protection after a change made in System Settings, and turning the built-in panel off when the lid opens. Built and unit-tested, and not yet tried on hardware: a saved layout across a long display sleep with protection on, the built-in panel coming back when the last external display goes away, the offer to protect a kept arrangement, links, and brightness keys across a mirror set.

- Arrange displays from the panel or the command line: make a display the main one, drag it on a small canvas, put it next to another (`display16x set placement left:end --tag 2 --of-tag 1`), mirror one display onto another and stop it again. Each change is one system transaction, and from the panel or with `--try` it asks **Keep** or **Revert** and goes back on its own after 15 seconds. `display16x revert` with no display named puts the last layout change back.
- Take a display out of use without unplugging it, and bring it back: `display16x disconnect --tag 2`, `display16x reconnect --all`, keep only the main display, or make one display the only one. The last display in use is never disconnected unless you allow it. A disconnect lasts until you log out at most, and the app reconnects what it disconnected when it quits, and at the next start if it stopped unexpectedly. If the last display in use goes away, the app brings back what it disconnected at once, in safe mode too. A built-in panel is turned back on only once the lid is open.
- Optionally turn the built-in panel off while an external display is attached, with displays you can exclude. It does nothing with the lid closed, and it steps back after you reconnect the panel by hand. Off by default.
- Protection: save a layout and have it put back after sleep, reconnects and changes made elsewhere, and keep a display's resolution or rotation the same way. It follows the changes you make through the app, skips a mode the display no longer offers, waits until displays have stopped coming and going, gives up after three attempts in two minutes, and says on screen what it did. Off by default. After you keep an arrangement change, the app offers to protect it, once; "Not Now" stops the offers until the app starts again.
- Presets: save the current sizes, rotation and arrangement (and optionally brightness) under a name, and apply them from the panel, the command line or a shortcut.
- A preset or shortcut that this version cannot read, for example one saved by a newer version or edited by hand, is left out and logged. The rest of your settings are kept.
- Global keyboard shortcuts for any command, recorded in the panel or added with `display16x shortcut add ctrl+opt+1 set preset Desk`. They need no Accessibility permission. Conflicts with your other shortcuts and with macOS's are pointed out. Repeated size steps are gathered into one change.
- Resolution by name (`default`, `native`, `previous`, `largest`, `smallest`), favourite modes, size steps along the text-size strip, and rotation by steps or as a toggle.
- Brightness and volume keys reach every display that mirrors the one they target. `display16x perform indicator --pointer` shows the indicator without changing anything.
- Command line: help for every feature (`display16x help placement`), a `perform` verb, `min` and `max` as values, JSON listings of a display's modes, inputs and identifiers, raw DDC reads and writes (`display16x get vcp 0x10 --tag 1`, writing needs `--confirm`), and a switch that turns command line access off.
- `display16x://` links run commands too, behind their own switch (off by default) and a token shown in the panel, with x-callback-url callbacks.
- Export, import and reset all settings from the panel or with `display16x settings export|import|reset`. What the app needs to undo its own changes on your Mac is never part of it.
- For development: `DISPLAY16X_SUPPORT_DIRECTORY` gives a build its own settings folder and command socket, and such a build does not start while the normal copy runs.
- Not included: Shortcuts app actions, which cannot be built with the Command Line Tools alone, and asking macOS to look for displays again.

## 0.1.0

The first release of Display 16X, a menu bar utility for the display controls macOS leaves out. It needs an Apple silicon Mac with macOS 14 or later.

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
