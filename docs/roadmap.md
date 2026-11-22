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

"Verified" means a probe in [`spikes/`](../spikes) or the app itself exercised it on the hardware listed in the feasibility notes. "Present" means the interface exists on macOS 27.2.1 and has not been exercised yet. Statuses are as of 23 November 2026.

| Capability | Mechanism | Interface | Status | Run-time cost | Milestone |
| --- | --- | --- | --- | --- | --- |
| Resolution, HiDPI and refresh rate | List modes from the window server, which includes the scaled HiDPI modes the public list hides. Apply in a configuration transaction that persists | Private SkyLight for the list, public Core Graphics to apply and as the fallback list | Verified on two monitors, with Keep and Revert | None | v0.1 |
| DDC brightness, contrast, volume, input | DDC/CI over the display's AV service I2C channel | Private IOKit | Read and write verified on two monitors. Input switching was never sent | On demand only | v0.1 |
| Built-in and Apple display brightness | System brightness service | Private DisplayServices | Present. No built-in panel or Apple display was available | None | v0.1 |
| Software dimming | Scale the display's gamma table | Public Core Graphics | Verified while awake. macOS resets it at unlock. The fix is built and not yet watched across a lock | None after the table is set | v0.1, off by default |
| Brightness and volume keys, on-screen indicator | Event tap for media keys (needs Accessibility permission) and a small indicator window | Public | Verified with Accessibility granted | Negligible | v0.1 |
| Rotation | Display preferences class of the MonitorPanel framework | Private | Present. The write path is built and has never been run | None | v0.1, unverified |
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

Measured on the M5 Pro with the packaged release build, panel closed, over 10 minutes: 0.02 seconds of CPU (0.003% of a core), one idle wakeup, and 41 MB of memory after use. The budget is written for a MacBook Air M1, which has not been measured yet.

## 3. Milestones

### Spikes

One small probe per risky mechanism, each recording Mac model, macOS build, monitor, connection and result.

- [x] List displays and modes, check private interface availability
- [x] DDC brightness read on two monitors
- [x] DDC write with coalescing while dragging
- [ ] DDC on a connection that carries video and no DDC
- [x] Gamma-table dimming while awake
- [ ] Gamma-table dimming across a lock and unlock (the blind rewrite needs to be watched once), with Night Shift, and with a custom color profile on any connected display
- [x] DDC readiness after a short display sleep: both monitors answer within a second, and bad replies stop within 3.4 seconds
- [ ] DDC readiness after a real standby, a full system sleep and a cable reconnect
- [ ] The same DDC timings with no other display utility running
- [ ] Key capture without Accessibility permission
- [x] A display's system UUID survives a display sleep and a reconnect during wake
- [ ] Whether it survives a full system sleep, an unplugged cable and a port change
- [ ] Rotation write through the timed revert
- [ ] Launch at login
- [ ] Display override install, activation and removal on macOS 27
- [ ] Virtual display create and destroy
- [ ] Disconnect and reconnect, HDR switch
- [ ] Built-in display brightness on a MacBook
- [ ] All of the above on a MacBook Air M1

### v0.1 Core

Built to the [core architecture](core-architecture.md), in this order:

1. **Domain core.** Display records with stable tags and identity matching, settings scopes, the mode model, controls and capabilities, composite brightness, the command engine and feature registry, the event bus and the automation gate. All unit-tested without hardware.
2. **System adapters.** Display inventory and modes with apply, verify and timed revert. The DDC transport with lenient parsing. Native brightness for Apple and built-in displays. Gamma-table dimming. Reconfiguration, sleep and wake events.
3. **App.** One card per display with brightness, text size, refresh rate and rotation. Volume and input where the monitor supports them. Brightness and volume keys with an on-screen indicator. Restore of brightness after wake and reconnect. Safe mode. Launch at login.
4. **CLI.** `display16x probe` standalone for bug reports, and get, set and step commands sent to the running app.

Ready when the performance budget in the [PRD](../PRD.md#performance-budget) is met on the baseline Mac, a monitor that ignores DDC leaves the menu responsive, and settings follow a monitor across a reconnect and a restart.

**Status on 23 November 2026.** All four stages are built on the `v0.1-core` branch, with 208 unit tests. On the two test monitors the owner has checked brightness, contrast and volume from the panel, the text-size strip with Keep and Revert, refresh rate, the brightness and volume keys with the indicator, and software dimming while awake. The idle and memory budgets are met on the M5 Pro.

Left before v0.1 is called done:

1. Watch software dimming across a lock and unlock.
2. Measure how soon each monitor accepts DDC after a real standby.
3. Settle the [open decisions](#5-open-decisions) marked v0.1.
4. One rotation run through the timed revert, or ship rotation marked unverified.
5. Register the login item once.
6. Run the app and the budget measurements on a MacBook Air M1, with its built-in panel.

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
| Monitors differ in DDC behavior | Lenient parsing, a quirks table, bounded retries, per-display overrides, and software dimming as a fallback. One of our two test monitors needs every query twice and garbles the reply header. The other reports a volume control it ignores. |
| Another display utility shares the DDC channel | A reply counts only when it names the feature that was asked for. Expect more retries, and say so in the user-facing notes on running next to other display tools. |
| macOS resets the color table at unlock without telling the app | Write the table again at the known moments without checking. Report software dimming as accepted, never confirmed. Keep it off by default until this is proven. |
| The Accessibility grant is tied to the code signature | Sign every build with a stable identity. Tell the user to remove a stale entry when a grant does not take. |
| The public mode list hides modes | Use the window server's list, validate it as a whole, and fall back to the public list. |
| Override-based scaling may behave differently on current macOS | Probe it before building interface for it. Keep mirror-based scaling as the fallback. |
| Hardware coverage | Publish a tested-hardware list and accept probe output in issues. |
| Scope | BetterDisplay is years of full-time work. Ship the core well before starting the next group. |

## 5. Open decisions

Raised by build work in the [domain log](domain-log.md). The maintainer decides. Until then the build keeps its current behavior.

| # | Decision | Current behavior | Recommendation | Needed for |
| --- | --- | --- | --- | --- |
| 1 | Use the window server's private mode list in v0.1, with the public list as the fallback | Built this way | Confirm. With the public list alone, Revert could not return to a hidden mode and the owner was left on the wrong size | v0.1 |
| 2 | Default for DDC values after wake | Restore what the user set through the app, 3 seconds after wake | Read and adopt what the monitor reports. Offer "restore after wake" per display for monitors that forget. Most monitors remember, and a restore undoes changes made with the monitor's buttons or another utility | v0.1 |
| 3 | Software dimming on by default | Off | Keep it off in v0.1. Revisit once it has been watched across a lock and with a custom color profile | v0.1 |
| 4 | The restore floor for values the user set by hand | A brightness set to 10% comes back as 15% | Restore hardware brightness as it was set. Apply the floor to the software part only, where a restore could leave the picture unreadable | v0.1 |
| 5 | Labels for vendor-specific input values | Shown by number, the user can rename | Keep numbers. Add a table of confirmed labels later, from hardware reports | Later |
| 6 | A stable signing identity for development builds | Ad hoc, so the Accessibility grant is lost on every rebuild | A local code-signing certificate now, Developer ID for releases. The packaging script already takes a certificate name | v0.1 |
| 7 | One rotation test on the owner's desk | Never run | One run on the monitor that is not rotated, through the timed revert, with the owner present | v0.1 |
| 8 | Identical monitors and DDC pairing | Paired in a stable order and marked as a guess | A "which monitor is this?" confirmation step, in preference to another private lookup | Public release |
| 9 | A clean DDC measurement with no other display utility running | Every number so far was taken with one running | One short run before v0.1 is called done, when the owner agrees to quit the other utility for a few minutes | v0.1 |
