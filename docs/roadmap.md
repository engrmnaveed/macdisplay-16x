# Display 16X roadmap

This document maps each planned capability to the macOS mechanism behind it, what it costs at run time, and the milestone it belongs to. The [feasibility notes](feasibility.md) hold the measurements.

## 1. Product references

| Product | License | What we take from it |
| --- | --- | --- |
| [BetterDisplay](https://github.com/waydabber/BetterDisplay) | Proprietary | The feature list and publicly documented behavior only. No code, assets, text or binary inspection. |
| [DisplayBuddy](https://displaybuddy.app/) | Proprietary | The idea of a few-click control surface for brightness, volume and inputs. |
| [MonitorControl](https://github.com/MonitorControl/MonitorControl) | MIT | Reference for DDC on Apple silicon, key handling and its supported-display notes. |
| [Lunar](https://github.com/alin23/Lunar) | MIT | Reference for DDC quirks and brightness behavior across monitors. |
| [m1ddc](https://github.com/waydabber/m1ddc) · [AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC) | MIT | Reference for the IOAVService I2C transport. |
| [displayplacer](https://github.com/jakehilborn/displayplacer) | MIT | Reference for mode enumeration and arrangement. |
| [DeskPad](https://github.com/Stengo/DeskPad) | MIT | Reference for virtual display creation. |
| [BrightIntosh](https://github.com/niklasr22/BrightIntosh) | GPL-3.0 | Concept reference for XDR brightness only. Its code cannot be copied into an MIT project. |

Licenses were read from the GitHub API on 22 November 2026. Credit any MIT source we adapt in a `THIRD_PARTY.md` file.

## 2. Capability map

"Verified" means the probe in [`spikes/`](../spikes) exercised it on the hardware listed in the feasibility notes. "Present" means the interface exists on macOS 27.2.1 and has not been exercised yet.

| Capability | Mechanism | Interface | Status | Run-time cost | Milestone |
| --- | --- | --- | --- | --- | --- |
| Resolution, HiDPI and refresh rate | Enumerate all modes including low-resolution duplicates, apply in a configuration transaction that persists | Public Core Graphics | Verified (listing) | None | v0.1 |
| DDC brightness, contrast, volume, input | DDC/CI over the display's AV service I2C channel | Private IOKit | Verified (read) on two monitors | On demand only | v0.1 |
| Built-in and Apple display brightness | System brightness service | Private DisplayServices | Present. No built-in panel was active during the probe | None | v0.1 |
| Software dimming | Scale the display's gamma table | Public Core Graphics | Not yet probed | None after the table is set | v0.1 |
| Brightness and volume keys, on-screen indicator | Event tap for media keys (needs Accessibility permission) and a small indicator window | Public | Not yet probed | Negligible | v0.1 |
| Rotation | Window server rotation call | Private SkyLight | Present | None | v0.1 |
| Arrangement, main display, mirroring | Configuration transaction | Public Core Graphics | Not yet probed | None | v0.2 |
| Disconnect and reconnect a display | Window server enable flag | Private SkyLight | Present | None | v0.2 |
| Configuration restore | Reapply saved state on reconfiguration and wake events | Public | Not yet probed | Event-driven | v0.2 |
| Presets, shortcuts, CLI, Shortcuts actions | Own code, App Intents | Public | — | None | v0.2 |
| Flexible HiDPI scaling, custom resolutions | Display override files per vendor and model with a generated resolution list. Needs administrator authorization and a reconnect | System file format | macOS ships 39 vendor override folders. Writing our own is not yet probed on macOS 27 | None after install | v0.3 |
| Virtual screens | Virtual display objects owned by the app | Private Core Graphics | Present | None while unused. Mirroring one to a panel adds a full-frame composite per refresh | v0.3 |
| HDR switching | Window server HDR flag | Private SkyLight | Present. One test monitor reports HDR support | None | v0.4 |
| XDR brightness | Extended-range surface plus gamma scaling | Public, on XDR hardware only | Needs XDR hardware | Small GPU cost while active | v0.4 |
| Color profile, color mode | ColorSync, window server output modes | Public and private | Present | None | v0.4 |
| Picture-in-picture, streaming | Screen capture | Public ScreenCaptureKit | — | High while active | Later |

### What the map says about performance

Every v0.1 and v0.2 item works by sending a short command and then getting out of the way. The app renders nothing between commands, which is how it can stay light on a base M1.

The expensive designs are the ones where an app sits in the pixel path: mirroring a virtual screen onto a physical panel to fake HiDPI, dimming with overlay windows, or capturing the screen. Display 16X uses native modes and system overrides for scaling and gamma tables for dimming. The pixel-path features are separate, off by default, and never start on their own.

## 3. Milestones

### Spikes

One small probe per risky mechanism, each recording Mac model, macOS build, monitor, connection and result.

- [x] List displays and modes, check private interface availability
- [x] DDC brightness read on two monitors
- [ ] DDC write with coalescing while dragging, and behavior on an unsupported connection
- [ ] Gamma-table dimming, including after wake, with Night Shift, and with a custom color profile on any connected display
- [ ] DDC readiness after wake and reconnect: how soon a write is accepted on each test monitor
- [ ] Key capture without Accessibility permission
- [ ] Whether a display's system UUID survives sleep, reconnect and a port change on the test monitors
- [ ] Display override install, activation and removal on macOS 27
- [ ] Virtual display create and destroy
- [ ] Disconnect and reconnect, HDR switch, rotation
- [ ] Built-in display brightness on a MacBook
- [ ] All of the above on a MacBook Air M1

### v0.1 Core

Built to the [core architecture](core-architecture.md), in this order:

1. **Domain core.** Display records with stable tags and identity matching, settings scopes, the mode model, controls and capabilities, composite brightness, the command engine and feature registry, the event bus and the automation gate. All unit-tested without hardware.
2. **System adapters.** Display inventory and modes with apply, verify and timed revert. The DDC transport with lenient parsing. Native brightness for Apple and built-in displays. Gamma-table dimming. Reconfiguration, sleep and wake events.
3. **App.** One card per display with brightness, text size, refresh rate and rotation. Volume and input where the monitor supports them. Brightness and volume keys with an on-screen indicator. Restore of brightness after wake and reconnect. Safe mode. Launch at login.
4. **CLI.** `display16x probe` standalone for bug reports, and get, set and step commands sent to the running app.

Ready when the performance budget in the [PRD](../PRD.md#performance-budget) is met on the baseline Mac, a monitor that ignores DDC leaves the menu responsive, and settings follow a monitor across a reconnect and a restart.

### v0.2 Layout

Arrangement, main display and mirroring. Disconnect and reconnect, including automatically turning off the built-in panel when an external display is attached. Configuration restore after wake and reconnect. Presets with global shortcuts. CLI, URL scheme and Shortcuts actions.

### v0.3 Advanced scaling

Flexible HiDPI scaling and custom resolutions through generated overrides, with a preview of what will be written, administrator authorization, and a one-click removal. Virtual screens for headless and remote use. Mirror-based HiDPI for panels that cannot get it natively, labelled with its GPU cost.

### v0.4 HDR and color

HDR switching, XDR brightness on capable hardware, color profile and color mode selection.

## 4. Risks

| Risk | Mitigation |
| --- | --- |
| Private interfaces change between macOS releases | One module, run-time lookup, a capability flag per feature, and the probe run on each macOS beta. |
| System display identifiers change across wake, reconnects and OS installs, and identical monitors collide | Settings are keyed by our own record tag. The match rule is chosen per display, with a transfer operation between records. |
| A monitor is not ready for commands right after wake or reconnect | Restores wait for reconfiguration to settle plus a per-display delay, pass the automation gate, and retry from a persisted queue. |
| Monitors differ in DDC behavior | Lenient parsing, a quirks table, bounded retries, per-display overrides, and software dimming as a fallback. One of our two test monitors already returns a non-standard reply. |
| Override-based scaling may behave differently on current macOS | Probe it before building interface for it. Keep mirror-based scaling as the fallback. |
| Hardware coverage | Publish a tested-hardware list and accept probe output in issues. |
| Scope | BetterDisplay is years of full-time work. Ship the core well before starting the next group. |
