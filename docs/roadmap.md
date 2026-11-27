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
| Arrangement, main display, mirroring | Configuration transaction | Public Core Graphics | Built and unit-tested. No write has run on hardware yet | None | v0.2 |
| Disconnect and reconnect a display | Window server enable flag | Private SkyLight | Built and unit-tested. No write has run on hardware yet | None | v0.2 |
| Configuration restore | Reapply saved state on reconfiguration and wake events | Public | Built and unit-tested, off by default. Not yet seen across a wake | Event-driven | v0.2 |
| Presets, shortcuts, CLI, Shortcuts actions | Own code, App Intents | Public | Presets, custom shortcuts, CLI verbs and the link scheme are built. Shortcuts actions are left out: their metadata step ships with Xcode only | None | v0.2 |
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
- **The owner's running copy is the latest build.** The owner tests by using the app every day. When a milestone's work ends, its session makes that build the running copy, with the standard settings folder. It keeps the previous app and a copy of the settings folder, and writes down how to go back. Set by the owner on 23 November 2026, after the Mac had gone back to the 0.1.0 build once v0.2 was checked.

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
- [ ] Built-in display brightness on a MacBook. The test Mac is one, running with its lid closed, so this can be checked by opening the lid with the owner present
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

**Every version gets a release.** Set by the owner on 23 November 2026: the latest version is released now, and each later version is released when its milestone is on `main`. The first release is 0.2.0, which holds v0.2 Layout and the interface pass. 0.1.0 was never tagged. v0.3 ships as 0.3.0, v0.4 as 0.4.0, and so on. A release is: the version file and the changelog section in one pull request, then the tag, then the workflow.

**Status on 23 November 2026.** Merged into `main` as pull request 3. CI now runs the version check, the archive with an unpack-and-verify step, the cask style check on all three signing levels, and the comparison of the private interfaces with and without the hardened runtime, and all of it passed on the GitHub runner. The tag-triggered workflow has never run, because that needs a published tag. Before the first tag the owner has four steps, listed in [release.md](release.md): create the project certificate and back it up, add its three secrets to the `release-signing` environment, add the tap's deploy key to the `release` environment, and then tag `v0.1.0`. Both environments exist since 23 November, limited to `v*` tags, with the owner as required reviewer on `release` and no secrets yet. The other one-time settings are in place too: `main` accepts changes only through a pull request with the CI check passing, `v*` tags can be created, moved or deleted only by a repository admin, published releases are immutable, and private vulnerability reporting is on. With the first two releases the owner checks that the Accessibility permission survives an update.

**0.2.0 was tagged on 23 November 2026**, at the merge of [pull request 9](https://github.com/engrmnaveed/macdisplay-16x/pull/9), by the owner with `scripts/tag-release 0.2.0 --push`. It is the first run of the release workflow. From here a release is two steps: `scripts/prepare-release X.Y.Z` through a pull request, then `scripts/tag-release X.Y.Z --push`.

**0.2.0 was published on 23 November 2026**, after the owner's approval, as the first release. **0.3.0 was tagged on 24 November 2026** and approved by the owner the same day, after its packaging job had twice waited for a macOS runner until GitHub cancelled it. Both are signed ad hoc.

**A build is started on real hardware before its tag.** v0.4 crashed one second after start, and 495 unit tests, the local checks and CI all passed. CI now starts the packaged app at the end of the smoke test, which catches a crash at start in general. It would not have caught this one: the crashing commit ran clean on a GitHub runner, which has no real monitor for the HDR code to read. So the commit that is tagged, or code that contains it, has to have run as the owner's copy first. 0.4.0 was tagged on 24 November 2026 after its fix had run that way.

**0.4.0 was published on 24 November 2026 and 0.5.0 on 25 November 2026**, both signed ad hoc. 0.5.0 holds the skins. Its pull requests hung in CI's unit tests until the job's 30-minute limit, twice each. On the runner every test target runs in one process, a skins test held the main actor about 16 seconds there, and a core test then waited for something that never came. It never showed on the development Mac, where each target runs in a process of its own. The skins test now runs off the main actor, every app test suite has a time limit, and CI's unit-test step has a 10-minute limit of its own, so a hang fails in minutes with its log kept. The build that ran as the owner's copy before the tag was build 186: the skins with v0.4's fixes, without one change to the display model's initializer that 0.4.0 already carried. The exact 0.5.0 build has not run as the owner's copy.

**0.5.1 was published on 27 November 2026**, a fix release for three reports the owner made that day against the Homebrew install of 0.5.0, merged as [pull request 26](https://github.com/engrmnaveed/macdisplay-16x/pull/26).

- **Brightness and volume keys did nothing, from 0.2.0 to 0.5.0.** The app built its system adapters as a local value and handed the pointer lookup and the audio lookup to properties the core holds weakly. Nothing owned them, so they were freed as soon as start-up finished, and every brightness key was passed on to macOS as "the pointer is on no display". The command line's `--pointer` and `--focused` failed the same way. It came in with the render harness's adapter bundle during the interface pass. No test saw it, because the tests kept their sample adapters alive. The owner had run the app without the Accessibility grant since v0.1, so daily use did not see it either.
- **The settings window cut off its tabs after the first click.** The standard tab control asked for 679 points where the window gave 544. The tabs are now a strip of the design system that shares the width it is given.
- **The text-size strip shows the size of a step on hover**, asked for as an improvement.

What was seen on the owner's desk before the tag: the brightness keys, the settings tabs and the hover preview, on a build of the fixes, and the packaged release build started with both monitors attached. The volume keys are unit-tested only. The app now says what became of each key, in `display16x status` and in Settings, which is what showed the cause.

**Bugs have their own two sessions since 27 November 2026.** Set by the owner with these reports: the planning session investigates each report and sends it with direction to a bug-fix session on Opus, which takes most bugs; a second one on Fable takes only the hardest. The planning session reviews each fix before it is pushed. A fix release takes the next patch number.

**Signing, until the project certificate exists.** The workflow signs with what the `release-signing` environment holds. It holds nothing yet, so 0.2.0 is signed ad hoc: the first launch has to be allowed by hand, and every update costs the Accessibility grant. The owner's certificate, its three secrets and the tap's deploy key change that from the release after they are added.

### Interface pass

The v0.1 interface was built to exercise the core, and it looks like it. This milestone gives the app a designed interface before the public release. The design is our own, to the [interface direction](../PRD.md#interface-direction) in the PRD.

1. **Review and direction.** A screenshot of every surface as it is today with what is wrong with it, then two or three directions shown as real rendered panels. The owner chooses. Nothing is rebuilt before that.
2. **Design system.** Spacing, type, color in light, dark and increased contrast, control styles, system symbols and motion, defined once in the app target.
3. **Surfaces.** The menu bar icon and its states. The panel and the display cards. The text-size strip with Keep and Revert. The detail view with its "say why" rows. The on-screen indicator. The settings window. The first run and the permission flows, including the stale Accessibility entry. The empty and error states: no display, a silent monitor, safe mode.
4. **Identity.** The app icon, the name treatment and the About panel.
5. **Quality bar.** Every control reachable by keyboard and VoiceOver. Reduce Motion and Increase Contrast respected. The panel still opens in under 100 ms warm, is built on open and released on close, and the memory budget holds.

Ready when the owner has approved each surface on their own Mac and the budgets are measured again. Later milestones build their interface on the design system, so their first panels stay plain until it lands.

**Order.** On 23 November 2026 the owner moved this milestone ahead: it starts as soon as v0.2 is on `main`, before release 0.1.0 and before v0.3. It needs the owner's choices on rendered options and no time at the monitors. Release 0.1.0 waits on the owner's certificate, and v0.3 opens with hardware spikes. The surfaces now include the v0.2 panels: the arrangement canvas, mirroring, connection and presets, the Keep window for a layout change, the protection offer and the protection notices. Images and the app icon are made with the image generator the owner has set up, and each one is a candidate for the owner to approve.

**Done on 23 November 2026**, with 389 unit tests passing. It reached `main` as [pull request 7](https://github.com/engrmnaveed/macdisplay-16x/pull/7), carried in by pull request 9, and ships in 0.2.0.

- **Direction:** the owner chose B, "Studio": the family's navy and aqua, displays drawn to scale, thick bars and a stepped text-size strip.
- **Surfaces:** approved by the owner from renders. The panel is one column with three pages: the displays with scenes on top, one display's page, and Arrange with the desk drawn to scale. Its height is bounded and it scrolls. There is a settings window, and a menu bar icon drawn in code with three states. A card's caption reads size, connection and role, and a value that was only sent or is not known carries a small tag.
- **Icon:** the owner chose the code-drawn display on a foot. The image generator was signed out both times, so no generated candidate was made.
- **Checked off screen:** every control on all surfaces and states has a name and a spoken value for VoiceOver, and contrast was measured in four looks.
- **Measured on screen, M5 Pro:** the panel opens in 76 to 88 ms warm and 133 ms the first time. Memory with the panel closed is 53 MB after use, so the owner raised that budget to 55 MiB.
- **The owner's running copy is this build**, with fresh settings.

Left for daily use and a later round: real blur, full keyboard access, VoiceOver's reading order, the three accessibility settings switched on, and decision 18.

**The look must stay cheap to change.** The owner asked for an interface that is "easy and cost-effective (from agentic tokens POV) to re-skin". So the look has three layers: one file of values (colors, distances, fonts, symbols), a few files of pieces (bar, chip, card, banner), and surfaces that only compose them. A test fails when a surface holds a color, a font, a radius, a distance or a symbol of its own. A re-skin is checked on one sheet that shows every value and piece. Later milestones build their panels the same way.

What the review found, beyond looks:

- **The panel has no upper limit to its height.** With three displays and everything open it is about 2,170 points tall and nothing scrolls. The redesign gives it a bounded height.
- **Nothing on screen told a confirmed value from a sent one, and the card could not say how a display is connected.** The core now gives both facts, and the interface session is taking them in.
- **Scenes are three steps away**, where the PRD wants one click.
- **Protection notices began with a small letter**, and a three-line notice did not fit its window. The v0.2 session fixed the text, and the redesign measures the window for its text.
- **The Keep windows never take the keyboard.** See decision 18.
- **VoiceOver gets no name for three kinds of menu**, and the displays on the arrangement canvas can be moved with the pointer only. Both belong to stage 5.

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

**Built, and closed by the owner on 23 November 2026 with check 11 left for a later version.** All five stages are built, with 324 unit tests passing. Fourteen of the fifteen owner checks ran on the test desk, and the layout matched its record after every one. The four layout features work from the CLI and the panel and come back after a revert. A layout moved in System Settings is put back once, with a notice. A preset applies from a shortcut. The idle budget holds: 0.003% of a core over ten minutes, one idle wakeup, and a 47 MB footprint against 41 MB for v0.1. The checks found two bugs, both fixed on the branch: undoing a mirror was refused as an overlap, and the built-in panel was turned back on behind a closed lid. Decisions 13 and 14 are built.

Three more things were done after the checks, at unit-test level. The first is the core session's change. The other two came out of its review of how v0.2 uses the core:

- **The automation origin is in.** Layout protection and the automatic turn-off of the built-in panel write as automation. Undoing an unconfirmed change, reconnecting at quit or at the next start, and reconnecting when no display is left stay restores, because they put back the app's own change.
- **One unreadable stored command costs one preset or shortcut.** The lists are read entry by entry, and what was dropped is logged with its name.
- **The gate is checked before each protection write**, and again between a rotation write and the mode write that follows it.

Merged into `main` on 23 November 2026 as [pull request 5](https://github.com/engrmnaveed/macdisplay-16x/pull/5). Its first CI build failed on a view the runner's older compiler could not type-check, and the layout panel's views were broken up for it. The branch is closed.

Carried forward to a later version, by the owner's word:

- **Check 11.** A saved layout across a display sleep of ten minutes or more, with protection on. The displays did sleep for an hour with protection off, and the app wrote nothing.
- **The offer of layout protection after Keep**, seen on screen.
- **The built-in panel coming back** when the last external display goes away, on hardware. It is unit-tested.
- **Decision 16**, on turning the built-in panel off automatically. The switch is off by default until then.
- **The lid-sleep reading.** `AppleClamshellCausesSleep` in the power management root read 1 before the app first turned the built-in panel off, and has read 0 since. macOS may change this value by itself with power and attached displays, so the reading alone proves nothing. It is read again after a logout with the app not running, and around one more turn-off, before any build that turns the panel off by itself is released. A Mac that no longer sleeps when its lid closes would be a fault we cannot ship.

Left out of v0.2, both moved to Later in the inventory:

- **Shortcuts actions.** The step that produces what the Shortcuts app reads ships with Xcode only. The CLI and the link scheme reach every feature from a shortcut in the meantime. See decision 15.
- **Asking macOS to look for displays again.** The private call exists, and no permitted reference documents its arguments.

### After the interface pass

Set by the owner on 23 November 2026: the next milestones are built in new sessions on the Opus model, one milestone at a time, and two at once only where they touch different files.

1. **The interface pass lands first**, and 0.2.0 is released with it. Later panels are built on its design system, so nothing starts before it is on `main`.
2. **v0.3 Advanced scaling**, as below. Its first stage is spikes. The read-only ones run unattended. The ones that write an override file or create a virtual screen need the owner for a short check, and are carried forward when the owner is away.
3. **Release groundwork, alongside v0.3.** It touches documents and `.github` only, so it can run at the same time: the tested-hardware list, the contribution guide and issue templates, the note on running next to other display utilities, and a pass over the README and the install guide for the new interface.
4. **v0.4 HDR and color**, after v0.3, because both change the core and the app.
5. **A verification round** for what earlier milestones carried forward. Daily use of the latest build covers part of it.

### Skins

Asked for by the owner on 24 November 2026: the user chooses the interface's colors in Settings. A small set of ready-made skins, with "Studio" as the unchanged default, and a custom choice whose text and control colors are worked out from the chosen colors so contrast holds in light, dark and increased contrast. The choice applies at once to every surface, is stored in the settings, and is reachable from the command line. It is built in its own session on Opus, on the three layers the interface pass left, and adding one more skin stays one small entry in one file. The owner chooses which ready-made skins ship, from renders. It ships as its own version, 0.5.0, after 0.4.0.

**Built on 24 November 2026, on `main` as [pull request 21](https://github.com/engrmnaveed/macdisplay-16x/pull/21) and released as 0.5.0 on 25 November**, with 521 unit tests passing. Six ready-made skins ship: Studio, which is the unchanged default, System, Graphite, Ember, Orchid and Moss. A custom choice sits beside them. The choice is under Settings → Appearance and on the command line as `display16x skin NAME`. In daily use only Studio has been seen, in the owner's copy. The other skins are checked by renders and by contrast tests.

### v0.3 Advanced scaling

Flexible HiDPI scaling and custom resolutions through generated overrides, with a preview of what will be written, administrator authorization, and a one-click removal. Virtual screens for headless and remote use. Mirror-based HiDPI for panels that cannot get it natively, labelled with its GPU cost.

**Built on 23 November 2026, on `main` as [pull request 10](https://github.com/engrmnaveed/macdisplay-16x/pull/10) and tagged `v0.3.0` on 24 November**, with 440 unit tests passing. Its first CI build failed on one line the runner's older compiler read differently, a local constant named like the method it calls. All 33 inventory rows are built at unit-test level, in new files, with small additive edits to nine existing ones and no change needed from the core session.

- **Proven on hardware, with the owner at the desk:** macOS 27 reads an override file from `/Library/Displays` when the display connects, and the app's own disconnect and reconnect is enough to apply it. Removing the file and reconnecting restores the exact mode list. A virtual screen can be created and released in a running process, is gone within three seconds, and never outlives the process.
- **What macOS does with an override:** entries are backing-store sizes. An 8-byte entry gives the low-density size and its half as HiDPI, a 12-byte entry gives its half as HiDPI, and a 16-byte entry is ignored. The LG's full grid as HiDPI was left out twice, so the app checks the mode list after activation and says what did not appear.
- **Unit-tested only:** the app's own writing of an override behind the administrator prompt, virtual screens made by the app, and mirror-based HiDPI. Ten checks for a later round are listed in the feasibility notes.
- **Left by the spikes on the owner's Mac:** one color profile macOS keeps for the probe's virtual screen, under `/Library/ColorSync/Profiles/Displays`.

### v0.4 HDR and color

HDR switching, XDR brightness on capable hardware, color profile and color mode selection.

**Built on 24 November 2026** on the branch `claude/v0-4-hdr-color-f09b6b`, not pushed, with 495 unit tests passing. The 20 inventory rows are built at unit-test level, in new files, with small additive edits to 15 existing ones.

- **Read-only on macOS 27:** the link color mode and GPU dithering can be reported and not set, because their setters have no documented arguments.
- **Not built:** direct XDR upscaling, because the only XDR panel on the desk is behind a closed lid.
- **Waiting on one check with the owner:** whether a color table value above 1 reaches the panel at all. Software upscaling depends on it, and on the core change in the table at the end of this document.
- **Rule kept from the core:** a color profile chosen through the app pauses software dimming on every display, and the panel says so.

## 4. Risks

| Risk | Mitigation |
| --- | --- |
| The app frees something the core holds weakly | The core keeps its links to the system side weak, so the app has to own every object it wires in. A lookup freed at start made the brightness and volume keys silent from 0.2.0 to 0.5.0. The app context now keeps its whole adapter bundle, and a test builds the context as the app does, without holding the adapters itself. Rule: what the app wires into a weak property of the core, the app must own |
| A fault that only shows with a permission granted goes unseen | The keys need the Accessibility grant, and an ad hoc signed build loses it at every update, so the owner's copies ran without it for days. Until a stable signing identity exists (decision 6), a release that touches the keys gets one key press on the real keyboard before its tag |
| A test that holds the main actor, or waits without a limit, hangs CI | On the runner all test targets share one process, so one slow main-actor test delays every other one, and a wait that is never resumed holds the run with no thread busy. Rule for tests: nothing holds the main actor for more than a fraction of a second, and every wait has a limit. CI's unit-test step ends at 10 minutes. Seen with 0.5.0 on 25 November 2026 |
| Private interfaces change between macOS releases | One module, run-time lookup, a capability flag per feature, and the probe run on each macOS beta. CI runs the probe on its runner at every pull request. On the first run, macOS 26 on an Apple M1 virtual machine, all four private interfaces resolved. |
| System display identifiers change across wake, reconnects and OS installs, and identical monitors collide | Settings are keyed by our own record tag. The match rule is chosen per display, with a transfer operation between records. |
| A monitor is not ready for commands right after wake or reconnect | Reads and restores wait for reconfiguration to settle plus a per-display delay, pass the automation gate, and retry a bounded number of times. A missing reply never removes a control or a value that was known before. One test monitor gives "not ready" replies for at least 16 seconds after a long sleep. |
| Monitors differ in DDC behavior | Lenient parsing, a quirks table, bounded retries, per-display overrides, and software dimming as a fallback. One of our two test monitors needs every query twice and garbles the reply header. The other reports a volume control it ignores. |
| Another display utility shares the DDC channel | A reply counts only when it names the feature that was asked for. Expect more retries, and say so in the user-facing notes on running next to other display tools. |
| macOS resets the color table at unlock without telling the app | Write the table again at the known moments without checking. Report software dimming as accepted, never confirmed. Keep it off by default until this is proven. |
| The Accessibility grant is tied to the code signature | Sign every build with a stable identity. Tell the user to remove a stale entry when a grant does not take. |
| The public mode list hides modes | Use the window server's list, validate it as a whole, and fall back to the public list. |
| Override-based scaling may behave differently on current macOS | Probe it before building interface for it. Keep mirror-based scaling as the fallback. |
| CI builds with an older compiler than the development Mac | CI is the judge, and nothing reaches `main` without it. The runner's Swift 6.3.3 gave up on a SwiftUI expression that Swift 6.4.2 accepts: `Double` and `CGFloat` arithmetic mixed in one modifier chain. Keep view bodies small and work out typed values before drawing. Compile time on the development Mac does not predict the failure. |
| Hardware coverage | Publish a tested-hardware list and accept probe output in issues. |
| Scope | BetterDisplay is years of full-time work. Ship the core well before starting the next group. |
| A display the app turned off stays off while the app is not running | The app reconnects what it disconnected when it quits, and at its next start after a crash. It reconnects at once when no display is left in use. A disconnect lasts for the login session only. The automatic turn-off of the built-in panel is the case this does not cover fully, see decision 16. |
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
| 13 | Whether layout protection switches itself on | It stays off. The app offers the switch at the moment the user arranges displays through it. macOS already puts the arrangement back by itself after a cable change. |
| 14 | Safe mode when no display is left in use | When the last display in use goes away while the app holds others disconnected, the app reconnects them at once, in safe mode too. Without a picture nobody can act, and it only undoes the app's own change. |

The rules are written out in the [core architecture](core-architecture.md), sections 5 and 7.

### Open

| # | Decision | Current behavior | Recommendation | Needed for |
| --- | --- | --- | --- | --- |
| 5 | Labels for vendor-specific input values | Shown by number, the user can rename | Keep numbers. Add a table of confirmed labels later, from hardware reports | Later |
| 6 | A stable signing identity for development builds | Ad hoc, so the Accessibility grant is lost on every rebuild. The packaging script takes a certificate name | A local code-signing certificate on each developer's Mac, separate from the project certificate, whose key stays with the owner and the release secrets | Now. The running copy is replaced at the end of every milestone, and each replacement costs the Accessibility grant until this exists |
| 8 | Identical monitors and DDC pairing | Paired in a stable order and marked as a guess | A "which monitor is this?" confirmation step, in preference to another private lookup | Public release |
| 15 | Shortcuts actions | Left out, because the Command Line Tools cannot produce their metadata | Leave them out for now. Revisit at the public release: building releases with Xcode on CI would bring them back and would end "builds with the Command Line Tools alone" for releases only | Public release |
| 16 | Turning the built-in panel off automatically | Built, and off by default. The panel comes back when the app quits and when the last external display goes away, and only once the lid is open, because turned on behind a closed lid it becomes the main display. If the app is not running at that moment, the panel stays dark until the user logs out | Hold the switch back from the v0.2 release and keep the code. Closing the lid already gives the same result at a desk. Bring the switch back when there is a way back that works without the app running, and the lid-sleep reading is explained. The owner's view, given at the desk: the built-in display should not be left dark | Before the switch is shown |
| 17 | Brightness written by a rule | An automatic brightness change gets the restore floor and also stops just above black, unless the user allowed black at zero. A restore gets the floor alone. No rule writes brightness yet, so nothing changes today | Confirm it. A restore puts back a value the user already chose. A rule's value arrives with nobody watching, and a black picture is the worst case for this app | The first rule that writes a value |
| 18 | Whether Keep and Revert answer to the keyboard at once | The Keep window is shown without taking the keyboard, so Return and Escape reach it only after a click. That keeps a mode change from stealing the keyboard from the app in use | Take the keyboard only when the change was made from the app's own panel. Escape reverts. Keep never sits on Return, so a key pressed blind cannot keep a picture the monitor cannot show. A change from the CLI, a link or a shortcut leaves the keyboard where it is, and the countdown reverts it | Interface pass, stage 3 |
| 19 | The word for a USB-C port that carries the picture directly | "USB-C". macOS knows the Mac's own port and never the far end of the cable, and every external display is a DisplayPort link to the Mac, HDMI included. On the test desk the Lenovo reads HDMI and the LG reads USB-C | Keep "USB-C". The label names the Mac's port, which is true whatever cable or adapter follows | Interface pass |
| 20 | When "read back" ends | At sleep, at once: what was read back becomes not known, and what was only sent stays sent. The read the app makes anyway after the wake decides again | Keep it. A monitor can change while the Mac sleeps, and the app says only what it knows | Interface pass |
| 21 | One word for a saved setup | "Scene" in the interface, as the PRD says, and `preset` in the command line and the settings file | Leave both until the public release, then choose one word, with the other kept as an alias in the command line | Public release |
| 22 | How the app gets administrator rights for an override file | The system's own password prompt, through a script the user sees in the preview | Keep it. A privileged helper needs a Developer ID to be worth trusting, so it waits for that | Public release |
| 23 | Whether a mirror the user linked starts again at launch | Yes, through the automation gate, and not in safe mode. The user switched it on, and it stays on until they switch it off | Keep it. Without it a setup that depends on the mirror breaks at every login. It still never starts unless the user turned it on | v0.3 release |
| 24 | The vendor number virtual screens report | A made-up one, 0x1616, so settings can tell the app's own screens from real monitors | Keep it, and change it if a real monitor is ever reported with it | Public release |
| 25 | A review of the v0.3 surfaces by the interface session | Built from the design system's pieces, and the boundary test passes. Not reviewed by the session that designed the system | Let daily use show what needs changing, and review them in the verification round | Verification round |
| 26 | A color profile chosen through the app and software dimming | The profile pauses software dimming on every display, by the core's existing rule that the two share one color table, and the panel says so | Keep it for 0.4.0. Changing it means a core change to combine a profile with dimming | Verification round |

### Core changes waiting for the core session

Changes to what v0.1 built are made by the session that built it, on the line of development current at the time.

| Change | Why | Lands on | Status |
| --- | --- | --- | --- |
| A change origin for automation, next to restore | Automatic layout, protection and connection writes are logged as restores today. A distinct origin lets logs and later consumers tell a restore from an automatic disconnect | The v0.2 branch | Built by the core session on 23 November 2026, on the branch `core/automation-origin` cut from the v0.2 branch, with 321 unit tests passing, not pushed. Merged into the v0.2 branch the same day, where the rule-driven writes now use it. Nothing from outside can claim the origin: the socket and links always run as commands |
| Confirmed or only sent, for each control | The PRD shows a value the monitor read back as confirmed and one the app only sent as sent. The engine knows this for each write, and the panel is only told a value | The interface pass branch | Built by the core session on 23 November 2026 on the branch `core/panel-facts`, with 350 unit tests passing, and sent to the interface session to merge. Each control's value is read back, sent or not known. No read was added for it and nothing is stored. Not seen in the running app yet |
| How a display is connected | The PRD's card is "name, connection". The panel is told nothing, so the card says "External" | The interface pass branch | Built on the same branch. Built-in, HDMI, DisplayPort, USB-C, Thunderbolt or not known, read from the I/O registry with public calls. Thunderbolt, adapters and docks are unverified: none was on the desk |
| A color transform that multiplies above 1 without clamping | Software upscaling in v0.4 needs brightness above SDR white to pass through the color pipeline's reserved stage after dimming | The line current when it is asked for | Not sent. It waits for a one-minute check with the owner that a table value above 1 reaches the panel. If it does not, the change is not needed |
| The crash-recovery mode test waits without a limit | `ModeServiceTests.recoversAfterCrash` gives the undo 3 seconds of wall-clock time, moves its test clock once, then waits for detection with no limit. When the main actor is held longer than those 3 seconds, the run hangs. This is what hung CI for 0.5.0 | The line current when it is sent | Not sent. Found by the skins session on 25 November 2026 and written up in the domain log. Test code only: move the clock once the change has reached the display, and bound the wait |
| A connection test fails when the core tests run one at a time | The test at `ConnectionTests.swift:326` fails every time with `--no-parallel`, on `main` as well, and passes in parallel | The line current when it is sent | Not sent. Found the same day. The cause is not known yet |
