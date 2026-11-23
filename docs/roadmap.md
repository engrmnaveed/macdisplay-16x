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
| Software dimming | Scale the display's gamma table | Public Core Graphics | Verified while awake and across a lock and unlock, where the app writes the table again. Not checked with a custom color profile | None after the table is set | v0.1, off by default |
| Brightness and volume keys, on-screen indicator | Event tap for media keys (needs Accessibility permission) and a small indicator window | Public | Verified with Accessibility granted | Negligible | v0.1 |
| Rotation | Display preferences class of the MonitorPanel framework | Private | Verified once through the timed revert on one monitor | None | v0.1 |
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

### How the work is run

- **One supervising thread.** The planning thread keeps these documents and drives the work until the product is finished. Each milestone is built in its own session, on its own branch, in its own worktree.
- **A change goes back to the session that built the part.** That session holds the domain knowledge. The core belongs to the session that built v0.1. Before it changes anything, the planning thread tells it where the project stands: the branch to cut from, the milestone in progress and where the change lands.
- **Finished branches are closed.** `v0.1-core` was merged on 23 November 2026 and takes no more commits. A change lands on the current line of development and ships with the milestone in progress. It is never added to an older version or its branch.
- **`main` is the line everything merges into**, through pull requests that pass CI. Release tags are cut from `main` only.
- **Sessions commit locally.** Pushing a branch, opening a pull request, merging into `main`, tagging and publishing each wait for the owner's word.

### Spikes

One small probe per risky mechanism, each recording Mac model, macOS build, monitor, connection and result.

- [x] List displays and modes, check private interface availability
- [x] DDC brightness read on two monitors
- [x] DDC write with coalescing while dragging
- [ ] DDC on a connection that carries video and no DDC
- [x] Gamma-table dimming while awake
- [x] Gamma-table dimming across a lock and unlock
- [ ] Gamma-table dimming with Night Shift, and with a custom color profile on any connected display
- [x] DDC readiness after a short display sleep: both monitors answer within a second, and bad replies stop within 3.4 seconds
- [x] DDC readiness after a display sleep of ten minutes or more (measured at 10 minutes, 37 minutes, and five and a half hours): the DisplayPort monitor leaves the system and returns 3.3 seconds later, answers before it is listed, and gives "not ready" replies on and off for at least 16 seconds. Both monitors kept their values
- [ ] DDC readiness after a full system sleep and a cable reconnect
- [x] DDC with no other display utility running: identical results, and the DisplayPort monitor refuses a single query on a quiet channel too
- [ ] Key capture without Accessibility permission
- [x] A display's system UUID survives a display sleep and a reconnect during wake
- [x] The tag, the system UUID and the display ID survive an unplugged cable, and a move to another port
- [ ] Whether they survive a full system sleep, a dock or an adapter, and how two units of one model behave
- [x] Rotation write through the timed revert
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

**Done.** The owner called v0.1 Core complete on 23 November 2026. All four stages are built, with 224 unit tests and a CI run on every pull request ([pull request 1](https://github.com/engrmnaveed/macdisplay-16x/pull/1)). On the two test monitors the owner has checked brightness, contrast and volume from the panel, the text-size strip with Keep and Revert, refresh rate, one rotation through the timed revert, the brightness and volume keys with the indicator, software dimming while awake and across a lock, and the monitors across a cable replug and a port change. The idle and memory budgets are met on the M5 Pro.

Carried forward, none of it blocking the first release:

- A MacBook Air M1 with its built-in panel: the app, native brightness and the budget measurements.
- Hardware nobody on this desk has: a monitor that forgets its values in standby, a connection that carries video and no DDC, an Apple display, two units of one model.
- Software dimming with a custom color profile and with Night Shift. It stays off by default until then.
- Registering the login item once.
- Fine points of software dimming after a return, held at lower priority by the owner.

### Release mechanism

Built the same way as Space 16X, so one owner runs both projects with the same steps.

- **Version.** One file, `scripts/release-version`. Today the version is written twice, in the packaging script and in the core's source. Both take it from the file, and CI fails when they disagree. `CHANGELOG.md` has a section per version.
- **Tag to release.** Pushing a tag `vX.Y.Z` that matches the version file runs the release workflow: the same checks as CI, the packaged app zipped as `display16x-X.Y.Z-macos-arm64.zip` with a SHA-256 file, a build provenance attestation, and a GitHub Release with the version's changelog section as its notes. Publication waits in a `release` environment for the owner's approval.
- **Homebrew.** A cask named `display16x` in the existing tap `engrmnaveed/homebrew-tap`. It is rendered from a template with the version and the digest, attached to the release, and committed to the tap by the workflow through a deploy key. The cask installs the app and links the `display16x` command. The official cask repository is not an option until the app passes Gatekeeper. A formula that builds from source was considered and set aside: the app would land in Homebrew's own folders instead of Applications, and every upgrade would be a new ad hoc signature.
- **Signing.** The workflow signs with what the `release-signing` environment holds: a Developer ID with notarization, a project certificate, or neither, which means ad hoc. The `release` environment holds the tap's deploy key and the required reviewer, so the one approval comes after the app is signed and the signed archive can be tried first. Display 16X needs a stable identity more than Space 16X does, because the Accessibility grant belongs to the signature and an ad hoc build loses it at every update. Releases are signed with one project certificate ([decision 12](#5-open-decisions)). Notarization needs the hardened runtime. The command line tool's hardware report is identical with and without it, and CI compares the two on every pull request. The menu bar app itself has not been started under it yet.
- **Guides.** `docs/release.md` is the runbook, with the one-time GitHub settings. `docs/install.md` covers Homebrew, the direct download, the first launch, the Accessibility grant and removal.

The first release is 0.1.0, tagged by the owner after pull request 1 is merged.

**Status on 23 November 2026.** Merged into `main` as pull request 3. CI now runs the version check, the archive with an unpack-and-verify step, the cask style check on all three signing levels, and the comparison of the private interfaces with and without the hardened runtime, and all of it passed on the GitHub runner. The tag-triggered workflow has never run, because that needs a published tag. Before the first tag the owner has four steps, listed in [release.md](release.md): create the project certificate and back it up, add its three secrets to the `release-signing` environment, add the tap's deploy key to the `release` environment, and then tag `v0.1.0`. Both environments exist since 23 November, limited to `v*` tags, with the owner as required reviewer on `release` and no secrets yet. With the first two releases the owner checks that the Accessibility permission survives an update.

### Interface pass

The v0.1 interface was built to exercise the core, and it looks like it. This milestone gives the app a designed interface before the public release. The design is our own, to the [interface direction](../PRD.md#interface-direction) in the PRD.

1. **Review and direction.** A screenshot of every surface as it is today with what is wrong with it, then two or three directions shown as real rendered panels. The owner chooses. Nothing is rebuilt before that.
2. **Design system.** Spacing, type, color in light, dark and increased contrast, control styles, system symbols and motion, defined once in the app target.
3. **Surfaces.** The menu bar icon and its states. The panel and the display cards. The text-size strip with Keep and Revert. The detail view with its "say why" rows. The on-screen indicator. The settings window. The first run and the permission flows, including the stale Accessibility entry. The empty and error states: no display, a silent monitor, safe mode.
4. **Identity.** The app icon, the name treatment and the About panel.
5. **Quality bar.** Every control reachable by keyboard and VoiceOver. Reduce Motion and Increase Contrast respected. The panel still opens in under 100 ms warm, is built on open and released on close, and the memory budget holds.

Ready when the owner has approved each surface on their own Mac and the budgets are measured again. It runs after release 0.1.0 works end to end. Later milestones build their interface on the design system, so their first panels stay plain until it lands.

### v0.2 Layout

Arrangement, main display and mirroring. Disconnect and reconnect, including automatically turning off the built-in panel when an external display is attached. Configuration restore after wake and reconnect. Presets with global shortcuts. CLI, URL scheme and Shortcuts actions. The [feature inventory](feature-inventory.md) marks the 56 capabilities in scope.

Built in this order, on the hooks the core reserved:

1. **Spikes.** Read-only first: what the system reports about origins, the main display and mirror sets, and what a configuration transaction announces. Then, with the owner present: move a display and move it back, change the main display and restore it, mirror and unmirror, disconnect and reconnect one display. Also whether Shortcuts actions can be built with the Command Line Tools alone.
2. **Core.** The reserved display states for a display disconnected by the app or by the system. Relationships between two displays and the second selector. The connection policy, which never removes the last eligible physical display. Presets as command lists. Desired mode, rotation and arrangement in the reconciler, with a limit on repeated enforcement. Export, import and reset of settings.
3. **System adapters.** Arrangement, main display and mirroring through configuration transactions. Disconnect and reconnect through the private module. Lid events.
4. **Surfaces.** A CLI verb for every feature, with generated help. The URL scheme and Shortcuts actions, each behind its own switch. Custom keyboard shortcuts with a recorder. Plain panel entries for arrangement, mirroring, connection and presets, which the interface pass later designs.
5. **Connection automation.** Turning the built-in panel off when an external display is attached, with exceptions, a pause after a manual override, and reconnecting when no display is left.

Every change to arrangement, mirroring, the main display or a connection is reversible: the layout before the change is recorded in the recovery store, and an interactive change gets Keep and Revert like a mode change.

Ready when the four layout features work from the CLI and the panel on the test monitors and come back after a revert, a saved layout returns after wake and reconnect without a loop, a preset applies from a shortcut, and the budgets still hold.

### v0.3 Advanced scaling

Flexible HiDPI scaling and custom resolutions through generated overrides, with a preview of what will be written, administrator authorization, and a one-click removal. Virtual screens for headless and remote use. Mirror-based HiDPI for panels that cannot get it natively, labelled with its GPU cost.

### v0.4 HDR and color

HDR switching, XDR brightness on capable hardware, color profile and color mode selection.

## 4. Risks

| Risk | Mitigation |
| --- | --- |
| Private interfaces change between macOS releases | One module, run-time lookup, a capability flag per feature, and the probe run on each macOS beta. CI runs the probe on its runner at every pull request. On the first run, macOS 26 on an Apple M1 virtual machine, all four private interfaces resolved. |
| System display identifiers change across wake, reconnects and OS installs, and identical monitors collide | Settings are keyed by our own record tag. The match rule is chosen per display, with a transfer operation between records. |
| A monitor is not ready for commands right after wake or reconnect | Reads and restores wait for reconfiguration to settle plus a per-display delay, pass the automation gate, and retry a bounded number of times. A missing reply never removes a control or a value that was known before. One test monitor gives "not ready" replies for at least 16 seconds after a long sleep. |
| Monitors differ in DDC behavior | Lenient parsing, a quirks table, bounded retries, per-display overrides, and software dimming as a fallback. One of our two test monitors needs every query twice and garbles the reply header. The other reports a volume control it ignores. |
| Another display utility shares the DDC channel | A reply counts only when it names the feature that was asked for. Expect more retries, and say so in the user-facing notes on running next to other display tools. |
| macOS resets the color table at unlock without telling the app | Write the table again at the known moments without checking. Report software dimming as accepted, never confirmed. Keep it off by default until this is proven. |
| The Accessibility grant is tied to the code signature | Sign every build with a stable identity. Tell the user to remove a stale entry when a grant does not take. |
| The public mode list hides modes | Use the window server's list, validate it as a whole, and fall back to the public list. |
| Override-based scaling may behave differently on current macOS | Probe it before building interface for it. Keep mirror-based scaling as the fallback. |
| Hardware coverage | Publish a tested-hardware list and accept probe output in issues. |
| Scope | BetterDisplay is years of full-time work. Ship the core well before starting the next group. |
| An app that is not notarized is blocked at first launch, and Homebrew has tightened its rules | Publish through our own tap and install by the cask's full name, which trusts that one cask. Homebrew can no longer skip quarantine, so document the first launch. It keeps the approval across upgrades only for the same signer, so sign with one stable identity. It unpacks with `unzip`, so the archive carries no extended attributes and CI verifies the signature after unpacking. Move to a Developer ID when the membership is there. |

## 5. Open decisions

Raised by build work in the [domain log](domain-log.md). The maintainer decides. Until then the build keeps its current behavior.

### Decided on 23 November 2026

| # | Decision | Outcome |
| --- | --- | --- |
| 1 | Mode list in v0.1 | The window server's private list, with the public list as the fallback. With the public list alone, Revert could not return to a hidden mode. |
| 2 | DDC values after wake and on reconnect | Read and adopt what the monitor reports. "Restore after wake" is a setting per display, off by default, for monitors that forget. It reads first and writes only a value the monitor no longer has. |
| 3 | Software dimming by default | Off in v0.1. Revisit once it has been watched across a lock and with a custom color profile. |
| 4 | The restore floor | Hardware brightness set by hand is restored exactly as set. The floor applies to the software part only, when the user returns. |
| 10 | What counts as the user returning, for the floor | App start, and a wake, unlock or session return after the displays were off or the screen was locked for 30 minutes or more. A shorter blank leaves a picture that was dimmed on purpose alone. The time comes from the sleep and lock events, with no timer. |
| 11 | Values at app start | Read and adopt, the same rule as after wake. The check of each display already reads the values, so it costs no extra queries. |
| 7 | One rotation test on the owner's desk | Done with the owner present: 90° on one monitor, left unanswered, back on its own after 15 seconds, arrangement unchanged. |
| 9 | A DDC run with no other display utility running | Done. Results were identical. Idle utilities cost no replies. A program that is reading at that moment does. |
| 12 | The signing identity for releases | One project certificate, kept as a release secret. Two builds signed with it have the identical signing requirement, so the Accessibility grant and Homebrew's first-launch approval should carry across updates. Users allow the first launch by hand once. The certificate is made to last many years, backed up by the owner, and never created again, because replacing it costs every user the grant once. A Developer ID with notarization replaces it when the Apple Developer Program membership is there, and that switch costs the grant once too. |

The rules are written out in the [core architecture](core-architecture.md), sections 5 and 7.

### Open

| # | Decision | Current behavior | Recommendation | Needed for |
| --- | --- | --- | --- | --- |
| 5 | Labels for vendor-specific input values | Shown by number, the user can rename | Keep numbers. Add a table of confirmed labels later, from hardware reports | Later |
| 6 | A stable signing identity for development builds | Ad hoc, so the Accessibility grant is lost on every rebuild. The packaging script takes a certificate name | A local code-signing certificate on each developer's Mac, separate from the project certificate, whose key stays with the owner and the release secrets | Next development round |
| 8 | Identical monitors and DDC pairing | Paired in a stable order and marked as a guess | A "which monitor is this?" confirmation step, in preference to another private lookup | Public release |
