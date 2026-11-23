# Display 16X

A free, open-source menu bar utility for the display controls macOS leaves out: every resolution and HiDPI mode, hardware brightness and volume on external monitors, software dimming, and brightness and volume keys that work on a monitor that is not Apple's. By [16X Brains](https://16xbrains.com/), under the MIT License.

It targets Apple silicon, and it is built to do nothing when nothing is happening: no timers, no polling, and nothing that renders frames unless you turn a feature on.

**Status: v0.1 Core, in development.** It runs on the developer's Mac with two external monitors. It is not signed for distribution or tested on other hardware yet. See [what works](#what-works-today).

## Build and run

You need an Apple silicon Mac with macOS 14 or later and the Command Line Tools (`xcode-select --install`). Xcode is not required.

```sh
swift build
swift test
scripts/package-macos.sh
open "dist/Display 16X.app"
```

The app appears as a display icon in the menu bar and has no Dock icon. Click the icon for one card per display.

- **Safe mode:** hold Shift while the app starts, or pass `--safe`. Nothing is restored or reapplied automatically in safe mode.
- **After sleep:** the app does not push its values at a monitor that wakes up. It reads the monitor and follows it, so a change made with the monitor's buttons or another tool stays. If a monitor forgets its brightness or volume while asleep, switch on "Put my values back after sleep" in that display's details.
- **Verbose log:** pass `--verbose` to log debug detail and echo the log to standard error.
- **Brightness and volume keys** need Accessibility permission. The panel says so and opens the right page in System Settings. The package is ad hoc signed, so macOS asks again after every rebuild: remove the old Display 16X entry from the Accessibility list and add the new one. To keep the grant across rebuilds, create a code signing certificate in Keychain Access (Certificate Assistant, Create a Certificate, type Code Signing) and pass its name: `DISPLAY16X_SIGN_IDENTITY="name" scripts/package-macos.sh`.
- **Panel snapshot:** `--snapshot-panel FILE` renders the panel to a PNG without showing it and quits, and `--snapshot-details` opens the detail views in it. It is a development aid for checking the layout.

## Command line

`scripts/package-macos.sh` also produces `dist/display16x`.

```sh
dist/display16x probe                      # hardware report, works without the app
dist/display16x list                       # connected and remembered displays
dist/display16x get brightness --main
dist/display16x set brightness 60% --tag 1
dist/display16x step volume -1 --name "LEN P32p-20"
dist/display16x set resolution 2560x1440 --pointer --try   # asks Keep or Revert, goes back on its own
dist/display16x features                   # every feature and its operations
```

`probe` is read-only and runs on its own, which makes it the thing to attach to a bug report. Every other command is sent to the running app over a socket only your user can open, with a timeout and a clear message when the app is not running. Each display gets one line: `confirmed` (read back from the device), `accepted` (sent or stored, not proven) or `failed` with the reason.

## What works today

| Area | State |
| --- | --- |
| Display records with stable tags, matched across reconnects and restarts | Built, unit-tested, checked on hardware |
| Resolution list, text-size strip, refresh rate, Keep and Revert with a timed revert | Verified on hardware: size changes from the strip, Keep, Revert, and the revert on its own when unanswered. The list includes the scaled sizes macOS hides from its public mode list |
| DDC brightness, contrast, volume and input, one serial queue per display | Brightness verified on a Lenovo P32p-20 and an LG SDQHD by an independent read. Volume, contrast and mute are read on hardware and written only in unit tests. Input switching is never run on hardware |
| Native brightness for built-in and Apple displays | Built. No such display was available to test |
| Software dimming through color tables | Looks right while awake on both monitors: smooth, clearly darker than the monitor's own minimum, and back to normal. **Known problem:** it was lost when the screen is unlocked after a display sleep. A fix that writes the table again at unlock is built and not yet watched on hardware. Off by default |
| Brightness and volume keys, on-screen indicator | Verified on both monitors after granting Accessibility. If the grant does not take, remove the old Display 16X entry in System Settings and add it again |
| After wake and when a display returns | The app reads the monitor and shows what it has. Nothing is written. Built and unit-tested, hardware check pending. In three measured wakes, one after five and a half hours, neither test monitor had lost a value |
| "Put my values back after sleep", per display, off by default | For a monitor that forgets its values. Reads first and writes only a value you chose and the monitor no longer has. Built and unit-tested. Never seen repairing a lost value, because neither test monitor loses one |
| Safe mode | Built and unit-tested. Hardware check pending |
| Rotation | Built behind the timed revert. Never run on hardware |
| Launch at login | Built. Not verified |
| CLI and hardware probe | Working |

The measurements behind this table are in [docs/feasibility.md](docs/feasibility.md).

## How it is put together

A SwiftPM package with no third-party dependencies.

| Target | Role |
| --- | --- |
| `DisplayCore` | The domain model, with no system dependencies: display records and identity, modes, controls and controllers, composite brightness, the command engine, events, the automation gate, the reconciler and settings. |
| `DDC` | DDC/CI packet codec, lenient reply parsing, one serial queue per display with write coalescing, and a quirks table. |
| `DisplaySystem` | Adapters over public macOS interfaces: inventory, modes, gamma tables, reconfiguration, sleep and wake, audio output, and the hardware probe. |
| `DisplayPrivate` | The only target that touches private interfaces. Every symbol is looked up at run time, and a missing one turns one control off. |
| `Display16XApp` | The menu bar app. The panel's content is built when it opens and released when it closes. |
| `display16x` | The command line tool. |

The menu, the keys and the CLI all build a command and hand it to one command engine. Every automatic write passes one gate, which safe mode keeps closed. Settings are keyed by an app-assigned display tag, never by a system display ID.

- [PRD.md](PRD.md): scope and principles
- [docs/core-architecture.md](docs/core-architecture.md): the design the core is built to
- [docs/roadmap.md](docs/roadmap.md): capabilities, mechanisms and milestones
- [docs/domain-log.md](docs/domain-log.md): what building it taught us about monitors and macOS
- [AGENTS.md](AGENTS.md): rules for working on the project
- [THIRD_PARTY.md](THIRD_PARTY.md): references and credits

## Where your data lives

Settings are one JSON file in `~/Library/Application Support/com.16xbrains.macdisplay16x/`. Nothing leaves your Mac: there are no accounts and no telemetry. Deleting that folder resets the app.

## Limits you should know about

- Private interfaces are used for DDC, native brightness, rotation and the full mode list, so the app cannot be on the Mac App Store, and a macOS update can turn a control off until the app catches up. Without the private mode list the app falls back to the public one, which lacks some scaled sizes.
- A monitor in standby may not answer DDC. The app keeps what it learned and asks again after wake.
- After wake and on reconnect the app puts back only the values you set through it. A change made with the monitor's own buttons is left alone.
- Two identical monitors cannot be told apart for DDC with certainty. The probe says so when it applies.
- DDC changes stay in the monitor after the app quits.
