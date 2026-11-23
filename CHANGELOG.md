# Changelog

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
