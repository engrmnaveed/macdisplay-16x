# Display 16X — Product requirements

**Owner** 16X Brains  
**Status** Draft for review · 22 November 2026  
**Local project** macdisplay-16x  
**Working product name** Display 16X · CLI executable `display16x`  
**Company** [16X Brains](https://16xbrains.com/)

## Product

Display 16X is a free, open-source menu bar utility that gives Mac users the display controls macOS leaves out: every resolution and HiDPI mode, hardware brightness and volume on external monitors, display arrangement and connection management, and later flexible HiDPI scaling, virtual screens and HDR controls. It covers the everyday feature set people use in BetterDisplay and DisplayBuddy, written from scratch under the MIT License, with its own name, interface and branding.

It targets Apple silicon only. The 8 GB MacBook Air M1 is the performance baseline: every design choice must leave that machine as responsive with the app running as without it.

## Users and their jobs

- **People with an external monitor** want the brightness and volume keys to work on it, and want to pick a comfortable text size without opening System Settings.
- **Multi-display and docked-laptop users** want their arrangement, resolution and main display to survive sleep, reconnects and dock changes, and want to switch setups with one shortcut.
- **Power users** want scriptable control from a CLI and Shortcuts, custom scaled resolutions, and virtual screens for headless or remote Macs.
- **Open-source contributors** need a small project that builds with the Command Line Tools alone, a probe they can run on their own hardware, and clear rules about which system interfaces are in use.

## Principles

1. **Idle means idle.** No timers and no polling. The app reacts to display reconfiguration, wake and user input. With the menu closed and nothing changing it does no work.
2. **The window server does the pixels.** Prefer mechanisms where macOS scales or dims in its own display pipeline (native modes, system overrides, gamma tables). Anything that makes the app render or capture frames (mirrored virtual screens, overlays, picture-in-picture) is opt-in, off by default, and labelled with its cost.
3. **Detect, never assume.** Each capability is probed per display and per connection. A missing private symbol, an unsupported monitor or a silent DDC bus disables one control and leaves the rest working.
4. **Private interfaces live in one module.** They are resolved at run time, so a macOS update can turn a feature off without stopping the app from launching.
5. **Independent implementation.** Features and concepts are learned from public documentation and observable behavior. Code, names, icons, interface text and layouts are our own. See [AGENTS.md](AGENTS.md) for the reference rules.

## Features

Everything is free. Features are grouped by what they cost the machine. The [roadmap](docs/roadmap.md) maps each one to its mechanism and milestone, and the [feasibility notes](docs/feasibility.md) record what has been verified on real hardware.

| Group | Features | Default |
| --- | --- | --- |
| **Core** | Per-display resolution list and slider with HiDPI and refresh rate. Rotation. DDC brightness, contrast, volume and input on external monitors. Native brightness on built-in and Apple displays. Software dimming through gamma tables. Brightness and volume keys with an on-screen indicator. Launch at login. | On |
| **Layout** | Arrangement, main display and mirroring from the menu. Disconnect and reconnect a display without unplugging it. Restore resolution and arrangement after wake or reconnect. Presets with shortcuts. CLI, URL scheme and Shortcuts actions. | On |
| **Advanced** | Flexible HiDPI scaling and custom resolutions through system display overrides. Virtual screens. HDR switching and XDR brightness. Color profile and color mode selection. | Off until enabled per feature |
| **Later** | Picture-in-picture and streaming, image filters and LUTs, EDID overrides, HDMI-CEC and network TV control. | Not scheduled |

## Interface direction

The interface is our own design. It should feel like a small macOS control panel that needs no manual, where the reference apps offer a deep, highly configurable menu.

- **One card per display.** Name, connection, a brightness slider, and a text-size strip that runs from "larger text" to "more space" with the resolution shown as secondary detail. Volume and input appear only when the monitor supports them. Everything else sits one level down in a per-display detail view.
- **Safe changes.** A resolution or refresh change shows Keep and Revert and rolls back on its own after a short countdown, so a mode the monitor cannot show never strands the user.
- **Say why.** A control that is unavailable stays visible in the detail view with a one-line reason, such as a monitor that did not answer DDC on this port. Nothing disappears silently.
- **Scenes.** Saved setups (for example Desk, Presentation, Night) are first-class, one click or one shortcut to apply.
- **Honest cost.** Any Advanced feature that keeps the GPU busy says so next to its switch.
- **Keyboard and VoiceOver throughout**, with standard macOS controls before custom ones.

## Non-goals for the first releases

Intel Macs, the Mac App Store (private interfaces and no sandbox rule it out), DisplayLink and AirPlay hardware control, accounts, telemetry, and any paid tier or licensing code.

## Architecture and delivery

A SwiftPM package with no third-party dependencies in the core, built with Swift 6 and the Command Line Tools, the same way as Space 16X.

| Target | Role |
| --- | --- |
| `DisplayCore` | The domain model with no system dependencies: display records and identity, modes, controls and controllers, composite brightness, the command engine, events, the automation gate and settings. Unit-tested with fakes. |
| `DDC` | DDC/CI packet encoding, lenient reply parsing, one serial queue per display, write coalescing and a quirks table. |
| `DisplaySystem` | Adapters over public macOS interfaces: inventory, modes, gamma tables, reconfiguration, sleep and wake. |
| `DisplayPrivate` | The only target that touches private interfaces (SkyLight, DisplayServices, IOAVService, CGVirtualDisplay). Run-time symbol lookup, one capability flag per feature. |
| `Display16XApp` | AppKit status item with SwiftUI content built when the menu opens and released when it closes. |
| `display16x` | CLI for scripting and for the hardware probe used in bug reports. |

The [core architecture](docs/core-architecture.md) fixes five things from the first commit so later features do not force a rewrite. Displays are saved records with a stable tag, separate from the live connection. Each display has several controllers with declared capabilities. Brightness is one scale composed of hardware and software parts. The menu, keys and CLI all go through one command engine. Every automatic write passes one gate that safe mode can close. The [feature inventory](docs/feature-inventory.md) lists every capability considered and the core hook it depends on.

Use macOS 14 as the provisional deployment floor, in line with Space 16X. List a macOS version as supported only after a release build has been checked on it. Distribute a Developer ID signed and notarized app through GitHub Releases and a Homebrew cask.

### Performance budget

Provisional targets for the MacBook Air M1 (8 GB). Record measured numbers before making claims.

| Scenario | Target |
| --- | --- |
| Idle, menu closed, displays unchanged | No recurring wakeups from the app. Average CPU at most 0.1% of one core over 10 minutes. |
| Memory after first use | At most 50 MiB physical footprint with the menu closed. |
| Menu open | Under 100 ms warm, using cached capabilities. No DDC traffic on the main thread. |
| Brightness drag | At most 20 DDC writes per second per display, latest value wins, final value always sent. |
| Core features enabled | No measurable change in WindowServer CPU or GPU load compared with the app not running. |

## Milestones

| Milestone | Done when |
| --- | --- |
| Spikes | Each risky mechanism has a small probe and a recorded result on real hardware. Mode listing and DDC reads are done. See [feasibility](docs/feasibility.md). |
| v0.1 Core | Resolution, refresh rate, DDC brightness and volume, software dimming and brightness keys work from the menu bar on the test monitors. The idle and memory budgets are met. |
| v0.2 Layout | Arrangement, disconnect and reconnect, configuration restore, presets, and the CLI. |
| v0.3 Advanced | Flexible scaling through overrides and virtual screens, each behind its own switch with a clean uninstall path. |
| Public release | Signed, notarized artifacts, an installation guide, a tested-hardware list, and contribution issues. |

## Decisions before a public release

Confirm the final name and icon, the deployment floor after testing, the update mechanism, and when to add the project to the 16X Brains site.
