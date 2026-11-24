# Domain log

Findings about the domain and the product, reported by build work for the planning documents to absorb. See [AGENTS.md](../AGENTS.md#who-changes-what) for what belongs here.

Add new entries at the top. Each entry has a date, a one-line title, what was observed (with Mac model, macOS build, monitor and connection where relevant), and what it means for the product. Mark an entry **Decision needed** when the maintainer has to choose.

<!-- entries -->

## 24 November 2026 · The built-in XDR panel: HDR without a switch, and forty empty preset slots

Seen at 12:05 with the lid open, through the v0.4 build as the running copy, read-only. The panel has no HDR switch: it shows HDR content at all times, with a potential headroom of 16. **Rule:** a display that has headroom and no HDR switch reads as "HDR always on", and the app offers it nothing to switch. Its reference presets come as 51 entries, of which 40 are empty custom slots that macOS names "Preset #11" to "Preset #50" and marks not valid. The app offers only the valid ones. The macOS preset names are Apple's own and are shown as macOS gives them.

The first start of the v0.4 build as the running copy crashed a second in: the object System Settings' display model hands back was released once too often. It was fixed within minutes, with a test that crashes on the old line, and the copy has run since 12:04. **Rule kept from v0.1:** an object an initializer returns through a raw call is taken unretained when Swift still holds the receiver.

## 24 November 2026 · Release 0.4.0: two releases waiting at once, and a release run with no macOS runner

- **GitHub can fail to find a macOS runner for a release.** 0.3.0's packaging job waited 15 minutes and was cancelled with "The job was not acquired by Runner of type hosted even after multiple attempts", next to GitHub's notice that jobs for macOS arm64 runners may queue longer because of capacity. Its checks job had found a macOS runner six minutes earlier, and 0.2.0's packaging job had waited five minutes for one. Nothing was signed or published. GitHub offers no setting for how long a hosted job may wait. From 0.4.0's workflow on, a run that ends without a release says in its summary why, and for a job with no runner, that **Re-run failed jobs** runs it again with nothing to undo. The runbook says the same. No check was changed.
- **A release run needs a macOS runner twice**, for the checks and for packaging. If runners stay short, the two could become one job that packages what it has just tested. That changes how the release reuses CI unchanged, so it was not done. It is an option for the maintainer, not a recommendation.
- **Two releases can wait at once, and the order of approval does not matter** for tags from 0.3.0 on: the higher version stays the latest release and keeps the tap, and while both are ad hoc signed the notes are the same either way. The order matters once, at the change to the certificate: approve the last ad hoc release first, or add the sentence about the Accessibility grant to the first certificate release's notes by hand.

## 24 November 2026 · Brightness above SDR white: built up to the one hook only the core can give

**Request for the core session, through the planning thread: one transform in the color pipeline.** Everything else for "software upscaling" is built at unit-test level and stays inert until then, saying why in the panel and on the command line.

1. A `ColorTransform` case that multiplies by a factor above 1 without clamping the table at 1, for example `case boost(Float)`: `apply(to:)` multiplies and clamps only at 0, and it is neutral at 1. Today `.gain` clamps every entry at 1, so a factor of 1.5 brightens the middle and flattens the top, which is not a brighter picture.
2. The pipeline's reserved `upscaling` stage takes it, after dimming, so `pipeline.set(.boost(f), for: .upscaling)` writes one composed table. The gamma backend already writes floats and needs no change.
3. v0.4 then sets one closure in the app: `UpscalingService.boost`. Nothing else in v0.4 changes.

**A question to settle before the change is worth making:** whether a table value above 1 reaches the panel at all. The framebuffer reports `GCPBypassesEDRPixels = 1`, which reads as "the color table leaves pixels above white alone". The existing `spikes/gamma-table-write-probe.swift`, run on the LG with HDR on and a top value of 1.5, answers it in a minute with the owner at the desk. A pipeline only exists where color tables are switched on, so upscaling also needs that switch.

**What is built, with no change to the core:**

- **A level above white of its own**, `upscale`, 0 to 1 of what the display's limits allow, next to brightness rather than inside it. Putting it on the composite scale above 1 would change the engine, the control service and the keys. It is a later step for the core session, and nothing in v0.4 depends on it.
- **The neutral key stop through the engine.** The brightness keys already arrive as step commands, so a v0.4 extension sends a press past 100% to the level above white: the press that reaches 100% stops there, the next one goes above, and going down the level above white comes off first. With the stop off, the part past 100% goes above at once.
- **Limits per display**: the highest factor (1.6 by default), the share of the headroom that looks right (the "visual calibration"), and the key stop.
- **The headroom request**: a one-point, click-through window showing a pixel above white through public Metal, so macOS raises the headroom for that display. It costs while shown. Not proven on hardware.
- **Nothing survives the app.** The level lives in memory and is recorded in the recovery store before anything is written. It drops to white at sleep, at a lock, when HDR goes off, when the switch goes off and at quit. What a crash left is put back at the next start, through the gate.
- **Recovery after direct control** puts back a panel's brightness and its reference preset through the engine. Auto-brightness is recorded and not yet put back: there is no switch for it yet.
- **Direct XDR upscaling is not built.** It drives a built-in XDR panel's own brightness above white, and no XDR panel was in use on this desk. The command line says so for a built-in display.

## 24 November 2026 · Virtual HDR: an option on v0.3's virtual screens, built on a code macOS has not confirmed

**For the v0.3 session, through the planning thread.** "Virtual HDR" is a v0.4 row about v0.3's screens, so it touched four of v0.3's files, additively and with no change to what a screen did before: an optional `hdr` in a screen's definition (`hdr=on` adds HDR modes next to the SDR ones, `hdr=only` offers HDR alone), the same in what the window server is asked to make, a transfer function on each requested mode, and the words in the help. A screen saved before has no HDR and is made exactly as before.

- **macOS takes a transfer function per virtual mode**, through an initializer whose shape the runtime reports. The app passes 2, the PQ code of CTA-861, which the framebuffer registry also uses. **Whether macOS accepts it and then offers HDR for the screen is not proven**: the check that would show it (`spikes/virtual-hdr-write-probe.swift`) was carried forward by the owner.
- A macOS without that initializer refuses an HDR screen with the reason, and SDR screens are made as before.

## 24 November 2026 · v0.4 surfaces: where they plug into the interface pass's surfaces, and what they say

**For the interface session, through the planning thread.** The v0.4 surfaces are new files built from the skin's values and pieces only (`SkinBoundaryTests` passes), and add nothing to the skin. To reach them, four existing files got one optional entry point each, defaulting to nothing, so the panel and the settings window are drawn exactly as before when it is absent: `PanelView` and `DisplayDetail` take an optional color model, and `SettingsView` takes one for its Advanced tab. The render harness's sample desk carries a sample color system. Every picture is in the render harness, groups "color", "settings" and "floating".

- **"HDR and color" sits on a display's page after "More sizes"**: HDR with its cost, the profile with its HDR twin and its fallback, reference presets where the display has them, and the link, marked read only.
- **The three v0.4 switches sit at the bottom of the Advanced tab**, after v0.3's virtual screens and written files, each with its cost. The interface session may want them higher.
- **Keep or Revert for HDR, a profile or a preset** is a window of its own on the display that changed, built like the one for a size, with the same buttons.
- **Each part that is off says where to turn it on**, and a display without HDR says why in a "say why" row.
- **Not seen on screen.** The app with these surfaces has not run on the desk. The pictures are from the harness.

## 24 November 2026 · v0.4 core: what it adds to the core, the rules it adopted, and where the architecture did not fit

**Where v0.4 touches what earlier milestones built.** No existing behavior changed, and every earlier test passes unchanged. Three optional keys, the settings version stays 1, so an older build reads both files and ignores them:

1. `color` in the settings document, next to `layout` and `advanced`: the three switches.
2. `color` in a record's settings, next to `layout`: what protection puts back, the SDR and HDR profiles, the fallback list, and hardware brightness in HDR. Reset and transfer treat it like the rest of the record.
3. `color` in the recovery store: HDR, profile and preset before a change that waits for Keep, and what the app turned off for HDR. Reset, export and import never touch it, which is the inventory's "protected recovery values".

The v0.3 test rig takes the feature list and a recovery store as parameters. Everything else is in new files.

**Rules adopted where the documents left room:**

- **HDR, a profile and a reference preset each get Keep and Revert from the panel**, and from the command line with `--try`, as a mode does. A switch from the command line, a scene or protection applies at once. What was there is written to the recovery store before the change.
- **A color change still waiting for Keep is undone at quit**, and one left by a crash at the next start, through the gate. Safe mode leaves it for the next normal start.
- **Night Shift and True Tone off in HDR give back only what they took.** The debt is written to the recovery store before the switch, so a crash between the two still gives it back. If the user turned Night Shift on again in the meantime, the debt is dropped and nothing is written. At quit it is given back without the gate, because that undoes the app's own change.
- **The HDR profile goes on whenever HDR switches, whoever switched it**, once the user has chosen one. It is the user's own pair of profiles, so it does not wait for protection to be on. Protection adds the correction of a profile changed elsewhere.
- **A protected profile's target is what the user asked for, not the fallback used**, so the wanted file is used again once it is back.
- **A profile assigned elsewhere announces nothing.** It is put back only at the moments everything else is checked (start, wake, reconnect, any reconfiguration) and when HDR switches. Nothing polls for it.

**Where the architecture did not fit, and what was done instead:**

- **"Hardware brightness in HDR" names the resolver as its hook.** Changing how the resolver picks an owner would change the core. Instead the v0.4 command extension holds back a brightness command for a monitor in HDR when the user switched hardware brightness in HDR off, and says why. Other displays named in the same command run as before, one at a time through the engine. The switch is on by default, so nothing changes unless the user asks.
- **"SDR level in HDR" names the brightness composition.** On a display with its own brightness the composite already drives the panel's brightness, which macOS uses as the SDR level in HDR. External monitors have no SDR level of their own. So no composition was added: the headroom report says what sets the SDR level on each display. The framebuffer's registry entry says the color table leaves pixels above SDR white alone (`GCPBypassesEDRPixels`), which would make software dimming an SDR level in HDR. That is unverified.
- **"Neutral table reset" is already the core's rule**: at neutral the pipeline writes nothing and gives the table back to the system. The check with the owner showed the LG's table stays a plain ramp in HDR. v0.4 adds nothing here.
- **The protection stage was reserved and empty.** Color protection is that stage.
- **Keep and Revert:** the command line's `keep` and `revert` answer a color change too, when it is the only change waiting on the display named.

## 24 November 2026 · v0.4 spikes: how macOS 27 exposes HDR and color, and two inventory rows that can only be read

Read-only, on the M5 Pro (Mac17,9, macOS 27.2.1) with the Lenovo P32p-20 on HDMI and the LG SDQHD on USB-C, lid closed. The numbers are in the [feasibility notes](feasibility.md#24-november-2026--v04-hdr-and-color-spikes--apple-m5-pro-mac179--macos-2721-26b131).

- **HDR has one switch, and it is System Settings' own.** The model System Settings uses for a display offers "HDR modes" and a "prefer HDR" switch whose shape the Objective-C runtime reports. The window server's own HDR query agrees with it on both monitors. The app switches HDR through that switch and reads it back through both. Only the LG offers HDR. The Lenovo has no HDR in its EDID.
- **Switching HDR, checked with the owner at 01:27:** the LG went black briefly at each switch and looked washed out in HDR, as macOS shows ordinary windows at the SDR level inside the HDR range. It did not leave the system, kept its mode, and the color table stayed a plain ramp. The switch blocks for about 0.75 seconds and the reconfiguration callbacks arrive inside it. **Rule:** an HDR switch from the panel gets Keep and Revert, because the user is looking at a different picture and may want the old one back, and a switch from the command line, a scene or protection does not.
- **Headroom is public.** `NSScreen` gives the current, potential and reference headroom. With HDR off both monitors report 1.0, and the reference reads 0, which means "not reported". The built-in panel's registry entry says its potential headroom is 16, also with the lid closed.
- **The link color modes can be listed and not chosen.** Each display's framebuffer entry in the I/O registry lists every combination of depth, pixel encoding, range and transfer function the link can carry, and which ones each timing allows. The one in use is not listed. SkyLight exports functions to choose an "output mode", and no permitted reference gives their arguments. **The inventory row "Link color mode" is built as a report in v0.4**, with the choice reserved behind a capability that is off. Guessing the arguments of a call that reconfigures the owner's monitor link is not worth the risk.
- **GPU dithering can be read and not set**, for the same reason: the registry says it is on for every framebuffer, and CoreDisplay's setter has no documented shape. The row "GPU dithering" is built as a report with the switch reserved.
- **Every window server mode reports a 30-bit pixel encoding**, while the public interface reports 8 bits for all of them. Neither tells what the link carries. A mode's depth stays out of the size strip.
- **Night Shift and True Tone are global, not per display**, and their state can be read and switched. Night Shift was off, with no schedule. Its switch was checked on and off with the owner. "Night Shift off in HDR" turns it off only if it is on, remembers that it did, and turns it back on only then, so a schedule or a change the user made meanwhile is left alone.
- **A color profile assigned through ColorSync takes effect at once and comes off cleanly**, checked with the owner on the LG with sRGB. No reconfiguration event announces it.
- **Choosing a profile turns software dimming off on every display.** The core's color table check treats any custom profile on any connected display as unsafe, and blocks the table. That rule was written before the app could assign profiles itself. **Decision needed:** keep it (a profile chosen through the app pauses dimming everywhere, and the panel says so), or ask the core session to judge a profile by what it holds: a profile without a calibration curve (`vcgt`), such as the system's sRGB and Display P3, leaves the table to the app. Recommendation: keep the rule for 0.4.0 and say it in the panel, and refine it in the verification round with a check on hardware.
- **Nothing on this desk has reference presets or an XDR panel in use.** Both are built from their typed interfaces and unit-tested, and stay unproven on hardware.

## 24 November 2026 · Release 0.3.0: releases can be approved out of order, and removing the app leaves v0.3's files behind

**Prepared as the second release, ad hoc signed like 0.2.0**, while 0.2.0's run still waits at Publish for approval. Two things about releases as a process, and one about uninstalling, came out of it.

- **A version approved late used to become the latest release.** Each run waits for its own approval, so a lower version can be published after a higher one. GitHub then marks the version published last as the latest release, and the tap would get the older cask. From 0.3.0's workflow on, a release published after a later version is not marked as the latest, and the tap keeps the later cask. A run uses the workflow at its own tag, so **0.2.0's run does not have this**: approve or reject it before 0.3.0 is published. **Update, 24 November:** 0.2.0 was approved and published at 19:42 UTC on 23 November, before 0.3.0 was tagged, so the case did not arise. The signer check, run against the published 0.2.0, compares 0.3.0 with it and finds it ad hoc signed, as it should.
- **The signer check now compares with the release just below the new version**, not the one published last, and says when a lower version is tagged but not published. It cannot read the signature of a version that has no release yet. So if the first certificate-signed release is approved before the last ad hoc one, its notes lack the sentence about the Accessibility grant, and the run tells the reviewer to add it. The rule that avoids all of this is to approve releases in version order. The runbook says so.
- **Uninstalling does not remove what v0.3 wrote outside the app's folder**: override files in `/Library/Displays`, and the color profiles macOS made for virtual screens in `/Library/ColorSync/Profiles/Displays`. The cask's uninstall and `--zap` remove the app and its settings folder only. The installation guide now lists the commands to run first. `display16x override delete all` also works without the running app, but not once the app, with the tool inside it, is gone. **Decision needed:** whether the cask's uninstall should remove the overrides itself. It would ask for an administrator password while `brew uninstall` runs, and that has not been tried. Recommendation: keep the documented steps for 0.3.0, and decide after the check of the app's own removal on hardware.

## 23 November 2026 · v0.3 built at unit-test level: decisions for the maintainer, and what the app has not done on hardware

All five stages are built on the branch, with 440 unit tests passing. The writing checks proved macOS's side with probes. **The app's own override write, its virtual screens and mirror-based HiDPI have not run on hardware.** The checks for a later round are listed in order in the feasibility notes.

**Decisions needed:**

1. **Administrator rights** (raised with the spikes): the system's prompt through AppleScript, each time, as built; or a privileged helper once the project certificate exists. Recommendation: the prompt for 0.3.0.
2. **Mirror-based HiDPI at launch.** As built, a screen the user linked with mirroring comes back with its mirror at launch and after wake, through the gate, so the GPU cost resumes without a click. Safe mode skips it. The alternative is to bring the screen back and wait for a click before mirroring. Recommendation: keep it as built, because the user set it up on purpose and the status line says while it runs. Revisit if the check on the desk shows trouble.
3. **The made-up vendor number for virtual screens.** Screens report vendor `0x1616`, which read as a manufacturer code is the letters "EPV". Nothing is known to use it. A screen's identity can be set per screen. Recommendation: keep it, and note it in the user guide.
4. **Full reset on a Mac in use.** It is built to move the system's saved display arrangements aside and to put them back. It has never run, and running it makes macOS forget every arrangement it saved. Recommendation: ship it behind its preview as built, and run its check on a spare Mac or a test account, never on the owner's.
5. **For the interface session:** the v0.3 surfaces and the four optional entry points in its files (see the entry on v0.3 surfaces below). It may want to place or word them differently. Nothing it built draws differently when they are absent.

**Rules adopted in the last stages:**

- **A display showing a virtual screen gets its own picture back before the screen goes**, so it returns to its own mode and place the way v0.2 ends a mirror. The switch off ends every such mirror and leaves the screens.
- **The status report says while mirror-based HiDPI runs**, and on which display, because that is the one Advanced feature that costs while idle.
- **A screen copies a display's shape as it is seen**, turned with the display, so a screen made for the turned LG is 2880 × 2560 and not its panel's 2560 × 2880.

## 23 November 2026 · v0.3 surfaces: where they plug into the interface pass's surfaces, and what they say

**For the interface session, through the planning thread.** The v0.3 surfaces are new files built from the skin's values and pieces only (`SkinBoundaryTests` passes): "More sizes" on a display's page, the preview of what will be written as a window of its own, and an Advanced tab in Settings. To reach them, four existing files got one optional entry point each, defaulting to nothing, so the panel and the settings window are drawn exactly as before when it is absent: `PanelView` and `DisplayDetail` take an optional advanced model, `SettingsView` has an `advanced` tab, and the render harness's sample desk carries sample stand-ins for the administrator step and virtual screens. The interface session may want to place or word these differently. Every picture is in the render harness, groups "scaling", "preview" and "settings".

- **The preview is the only way to a write.** It names every display the file reaches, every step, what finishes it and the file byte for byte, and its button says "Write as Administrator". The command line prints the same preview and changes nothing without `--confirm`.
- **A size is shown in the frame the display is turned to**, as the size strip shows it. Where the panel's own frame is meant, the text says so.
- **What macOS made of a file is shown size by size**: "Offered", or "Written, and left out by macOS. It does not say why."
- **Each switch says its cost next to it.** Mirror-based HiDPI cannot be switched on while virtual screens are off.
- **Not seen on screen.** The app with these surfaces has not run on the desk yet. The pictures are from the harness.

## 23 November 2026 · v0.3 core: what it adds to the core, and the rules it adopted

**Where v0.3 touches what earlier milestones built.** No existing behavior changed, and every earlier test passes unchanged. Two additions:

1. An optional `advanced` section in the settings document, next to v0.2's `layout`, with the three switches, the override changes waiting to be written and the saved virtual screens. The settings version stays 1, so a v0.2 build reads the file and ignores the section.
2. The v0.2 test rig takes the feature list as a parameter, as v0.2 did for the v0.1 rig.

Everything else is in new files: the override model and service, the virtual screen model and service, the v0.3 features and their command extension, and a list of files written outside the app's folders, kept in its own file next to the recovery store and never touched by reset, export or import.

**Where the architecture did not fit, and what was done instead.**

- **The reserved `virtual` kind had nothing to set it.** The inventory reports every display macOS lists as built in or external. The app now wraps the inventory and marks the displays it made itself as virtual, so the registry records them so and the connection policy, which counts only built-in and external displays as physical, never lets a virtual screen stand in for the last physical display. No core file changed for it.
- **The reserved privileged path had no shape.** It is a plan: steps (create a folder, write, delete, delete a folder if empty, move aside, put back), the displays it reaches, notes, and what finishes it. The preview is the plan printed whole, every byte included, and the administrator step runs exactly its steps. The text of the shell commands is built in the core and unit-tested, quoting included.
- **Virtual screen commands cannot use a display selector**, because a screen that is not connected has no record yet, and a new one has none at all. They are app-wide features that take the screen's name. A connected screen is also an ordinary display by its tag, for its mode, brightness and arrangement.

**Rules adopted where the documents left room:**

- **A write outside the app's folders without `--confirm` prints its preview and changes nothing.** The panel shows the same preview before the administrator prompt.
- **Writing needs the feature switched on. Removing never does.** Turning a feature off must not trap the files it wrote.
- **The main display is not reconnected to activate an override.** Its result says "accepted", with the advice to replug the cable or log out, because the file is written and not yet read.
- **Sizes are typed as the display shows them**, in the frame it is turned to, as the size strip names them, and kept in the panel's own frame.
- **Removal deletes only files carrying the app's marker, and only empty folders the app itself created.** A file found by its marker that this account's list does not hold, for example one written from another account, is listed and removable, and its folders are left alone.
- **A full reset moves the system's saved display settings into the app's own folder instead of deleting them**, so "put back" can undo it. The backup folder is made by the app before the administrator step, so it belongs to the user and not to root.
- **Virtual screens follow the automation rules of v0.2.** Restoring at launch and after wake is a restore, connecting with a linked display is automation, both pass the gate and stop after three in two minutes with a notice. A connect by hand starts them again. An automatic change is nobody's choice: it never changes whether the user wants the screen.
- **A virtual screen's number is never reused**, also after a settings reset, because a new screen with an old serial number would bind to the old record and take its settings.

## 23 November 2026 · v0.3 spikes: macOS 27 reads an override when the display reconnects, and a virtual screen lives only while the app holds it

Apple M5 Pro (Mac17,9), macOS 27.2.1, the LG SDQHD on USB-C (rotated 270°) and the Lenovo P32p-20 on HDMI. Checked with the owner at the desk from 21:44 to 21:51, with three administrator prompts the owner answered. The measurements are in the feasibility notes.

**What macOS does with an override file.**

- **It reads `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<hex>/DisplayProductID-<hex>` when the display connects, and not before.** The app's own disconnect and reconnect is enough, about 6 seconds per display. The folder did not exist on this Mac, and the install created the whole chain.
- **A size is written as the backing store, in the panel's own frame before rotation.** The 8-byte entry (width, height) gives the size at low density where the panel can show it, and its half as HiDPI. The 12-byte entry (width, height, flags 1) gives its half as HiDPI. **The 16-byte entries are ignored**, with flags 1 and with flags 9, although a quarter of the system's own entries have that shape.
- **macOS leaves out some sizes that are written correctly**, with no message. The LG's full grid as HiDPI (backing 5120 × 5760) was left out twice, while a step inside its range was taken. Nothing the app can read predicts it.
- **A file carrying the app's own marker key is read like any other**, and deleting the file and reconnecting gives back exactly the list there was before.

**What a virtual screen is.**

- **It exists only while the process that made it holds it.** Releasing it removes it within 3 seconds, and so does the process ending, a crash included. Nothing is left on the system to clean up.
- **It gets a new display ID every time it is created**, and reports the vendor, product and serial number the app gives it. The running 0.2.0 matched two creations to one record by those numbers.
- **macOS places it next to the main display and moves other displays out of its way, and remembers that layout for the set of displays that includes it.** When it goes, the others return to the layout of the smaller set.
- **macOS makes a color profile for it and keeps it after the screen is gone**, in `/Library/ColorSync/Profiles/Displays`, named after the screen and its system UUID, owned by root. Discarding a virtual screen therefore has a file outside the app's folders to remove, with administrator rights, which is the inventory's "remove generated profile". The check left one such profile on the owner's Mac.
- macOS makes a list of 24 modes, at both densities, from the one mode the app gives it. The window server's limit for a virtual screen is 16384 × 16384 pixels, 0.25 to 4 pixels per point, and at least 24 Hz.

**Rules the build adopts from this:**

1. **An override belongs to a model, not a monitor.** Every unit of that vendor and product gets it. The preview lists every known display of the model, remembered ones included.
2. **HiDPI sizes are written as 12-byte entries, low-density sizes as 8-byte entries, and nothing is written as a 16-byte entry.** The preview says that a low-density size also brings its half as HiDPI.
3. **What was installed is checked after activation.** The app reconnects the display, reads the list and reports each size as offered or left out by macOS. A size is never shown as available because it was written.
4. **The main display cannot be reconnected by the app**, because the connection policy refuses it. Its override is activated by a cable replug or a logout, and the app says so.
5. **When macOS ships its own file for the model, the app's file starts from a copy of it.** Whether a file in `/Library` replaces the system's or adds to it was not tested, because neither test monitor has one. A copy is right in both cases.
6. **Every file the app writes carries its marker key, and a list of what was written is kept in the app's own folder.** The app, and the command line without the app, find every such file by the marker alone, so a lost list loses nothing. Removal deletes only files with the marker and only empty folders the app created.
7. **A virtual screen is a saved definition plus a live object.** Quitting removes the screens; starting again recreates the saved ones that were connected, through the gate. Its settings are keyed by its record tag, as for any display, never by its display ID.

**Decision needed:** how the app gets administrator rights. Built: the system's own prompt for each install and removal, through AppleScript's `do shell script … with administrator privileges`, which is public and documented by Apple and works for an ad hoc signed app. The alternative, a privileged helper registered with the system, needs a signing identity the project does not have yet (decision 12) and an approval in System Settings. **Recommendation:** keep the prompt for v0.3, and look at a helper when the project certificate exists.

## 23 November 2026 · The first release is 0.2.0, ad hoc signed, and every milestone gets a release

**Owner's word, through the planning thread:** "no release available on GitHub yet, please do release the latest version, and keep release cycle updated, every major version should have a release". So 0.1.0 is never published, 0.2.0 is the first release, and each milestone on `main` is released as its version (0.3.0 for v0.3). A release is two steps, prepare in a pull request and tag the merged commit, described in the release runbook.

- **0.2.0 is ad hoc signed, because the project certificate (decision 12) has not been made.** Its users allow the first launch and give the Accessibility permission again after every update, and Homebrew warns that the signer changed. That cost lasts until the first release signed with the certificate, which still asks for both once more, because its signature differs from the ad hoc one. Its release notes say so on their own: the release workflow now names the last release in them when the new app does not satisfy that release's signing requirement. **Decision needed from the owner:** make the certificate before v0.3 is released, or 0.3.0 is ad hoc signed as well and its users pay the same cost once more.
- **The cask reaches the tap only with the deploy key.** Without `HOMEBREW_TAP_DEPLOY_KEY` the release is published but `brew install --cask engrmnaveed/tap/display16x` does not find it until the owner commits the cask to the tap by hand. The run now says so in a warning and in its summary, not only in a notice.
- **GitHub was found set up as the runbook asks**, read only: the `release` environment with the owner as required reviewer and `v*` tags only, `release-signing` with `v*` tags only and no secrets, immutable releases on, and rulesets protecting `main` and `v*` tags. With immutable releases, a published version cannot get its assets replaced, so a fault found after **Publish** is fixed with the next patch version.
- **The release has never run.** The first tag push is the first real run of the workflow. The ad hoc path, the archive check, the signer comparison with no earlier release and the notes were run on the developer's Mac; the upload of the build, the attestation and the release itself have not run in this repository. Space 16X publishes the same way, so the step that hands the build to the publish job has worked there.

## 23 November 2026 · The app icon is chosen

**Decision made by the owner, in the interface session:** the icon is the code-drawn candidate A, a display with its menu bar line standing on a foot, in aqua on the family's navy. It is the mark the app already draws in its panel and in the menu bar, and it is drawn by a script in the repository, as Space 16X's icon is, so it can be changed and made again.

- **No candidate was made with Gemini.** Gemini in the built-in browser showed "Sign in" both times it was opened, so by the owner's rule the work stopped there and nothing was sent or downloaded. The three candidates shown were drawn in code and offered as extras. The owner chose from those.
- **The icon is in the bundle from the next package on.** The copy in daily use is `897c40f`, from before the icon, and has to be replaced once more. The planning thread arranges that with the owner. An ad hoc signed bundle is a new signature each time, so the Accessibility entry has to be added again after the replacement.

## 23 November 2026 · The budgets on screen, and the owner's word on them

Apple M5 Pro (Mac17,9), macOS 27.2.1, the Lenovo P32p-20 and the LG SDQHD. This branch at `897c40f` has been the owner's copy in daily use since 19:59. Figures are in the feasibility notes.

- **Decision made by the owner, in the interface session:** "don't try to over-engineer, we can extend the budget by 10% if needs to be, just have a quick look if anything in hindsight is there to improve else increase budget a little bit." **For the planning thread:** the PRD's memory line needs it, 50 MiB to 55 MiB: the app is at 53 MB with the panel closed after use (41 MB for v0.1, 47 MB for v0.2). The open-time line can stay at 100 ms if the change below holds on screen, and would otherwise go to 110 ms.
- **Asking macOS whether a display can be rotated is slow: 22 ms for one monitor, 4 ms for the other, every time.** The panel asked for every display on every build. It asks now when a display's page opens, once. **Rule: nothing that is only shown one level down is asked for when the panel opens.** For the core session, if it wants it: the answer could be kept per connected display.
- **Listing the connected displays takes 17 ms** since the port descriptions are read for the connection. It runs when the set of displays changes and not when the panel opens, so it costs nothing in daily use. For the core session to know.
- **Warm panel opens were 77 to 109 ms** before that change, of which 33 to 51 ms were the models and 36 to 61 ms showing the popover. **Idle is inside its budget:** 0.033% of a core over ten minutes with the key capture on and the owner typing, and no idle wakeup.

## 23 November 2026 · Interface pass, stage 5 off screen: Increase Contrast cannot be asked for by name

Apple M5 Pro (Mac17,9), macOS 27.2.1, from the render harness. Measurements are in the feasibility notes.

- **macOS gives out its increased-contrast appearance only while Increase Contrast is on in System Settings.** Asked for by name with the setting off, it returns the ordinary light or dark appearance. An app cannot preview its increased-contrast look, and a test cannot draw it, without the setting. The skin's colors therefore have a switch for the harness that makes them answer with their increased-contrast values. **Rule: a claim that the app respects Increase Contrast needs the setting switched on once, on screen.** The pictures the review called "increased contrast" in stage 1 were the ordinary looks.
- **Every control on every surface reaches VoiceOver with a name, and every bar with a value in words.** The render run fails when one does not.
- **The skin's contrast is measured in all four looks**, and a re-skin that makes text hard to read fails a test.
- **The panel's content builds in 18 to 30 ms off screen** on this Mac, against a budget of 100 ms for the open panel on a MacBook Air M1. The on-screen figure, memory and idle wakeups need a development build running in place of the copy in daily use, which the owner is asked for once.

## 23 November 2026 · Interface pass, stages 2 and 3: the direction the owner chose, and what the rebuilt surfaces settle

**The owner chose direction B, "Studio"**: the family's navy and aqua, displays drawn to scale, thick bars, a stepped text-size strip. The accent is the family's teal and aqua as drawn. **The owner also asked that the look stay cheap to change later.** So the look lives in two files, the skin (values) and the pieces (how a bar or a chip is drawn), surfaces only compose them, and a test fails when a surface brings a color, font, radius, distance or symbol of its own.

Every surface is rebuilt on that and drawn from sample data. The owner has not approved the surfaces yet. What this settles and what it leaves:

- **The panel is three pages in one column**: the displays, one display's page, and Arrange. A page takes the panel's place, and the panel scrolls inside 86% of the height of the screen it hangs from. Settings are a window of their own.
- **Saved setups are called scenes in the interface**, the PRD's word. The command line and the settings file keep `preset`. **Decision needed** only if one word should be used everywhere.
- **Confirmed or sent is shown, from what the panel already gets.** A brightness with a software share is marked sent. So is a value whose last change the display accepted without reading it back. Everything else was read from the display. The request to the core from stage 1 shrinks to this: a flag kept with the tracked value is only needed if a surface that never sent a command, such as the indicator, should say it too.
- **The card says the display's size in inches**, from the size its EDID gives, where the PRD says "connection". How a display is connected is still not available to the interface.
- **The greeting on first run shows in the first run only**: while the settings file did not exist when the app started. No setting was added for it.
- **A protection notice is shown as a sentence**, with a capital first. The core's text is unchanged.
- **Where a control moved.** Each display's mirroring, disconnect, protection switches and shortcuts are on its page. Scenes are on top of the panel and in Settings. Shortcuts, command line access, links and the settings file are in Settings. Displays that are disconnected, behind a closed lid or unplugged are listed under Arrange, and "Forget" is there.
- **Placing a display without the pointer** uses the placement command that the command line already has. It was not reachable from the panel before.
- **Not changed, and still open:** the floating Keep windows do not take the keyboard (decision asked for in the entry below). Whether the switch for turning the built-in display off is shown at all is roadmap decision 16; it is where it was, under Arrange.
- **To check on screen in stage 5:** the popover's arrow keeps the system's material while the panel has the skin's canvas. VoiceOver pressing the pop-ups, which are the system's menus under a drawn label.

Update, 23 November, after the core's two facts were merged, and after the owner approved the rebuilt surfaces:

- **The owner approved the rebuilt surfaces** from the renders. What renders cannot show (the popover's own frame, real blur, motion, the feel of the bars) is still to be seen on screen.
- **How a value is known comes from the core now**, and the panel no longer works it out. All three states are shown. A value that was read back is unmarked on a card and has a check on the display's page. "Sent" and "not known" are a small tag on the card, and on the page the row reads "Display 16X sent" or "Remembered, not confirmed since".
- **The card's line is size, connection, role**: "32-inch · HDMI · Main display". A connection macOS does not report leaves no word. The display's page lists "The Mac's port" and the size.
- **Protection notices are shown as the core writes them.** The interface's own capitalising is gone.

## 23 November 2026 · Interface pass, stage 1: what every surface shows when it is drawn from sample data

Every surface of the app was drawn off screen from made-up monitors, in light and dark, through the app's own panel models. No display was touched and the copy in daily use was left alone. What the pictures and the accessibility trees show about the product:

- **The panel has no upper limit to its height.** With two monitors and both Details open it is about 1,100 points tall, and with three displays and everything open about 2,170. A display 1,080 points high cannot show it, and nothing scrolls. Rule for the redesign: the panel has a bounded height whatever is connected and whatever is open.
- **A protection notice longer than two lines does not fit its window.** The window is measured for two lines whatever the text, and the three "stopped" notices are three lines long. Fixed with the notice's redesign.
- **Protection notices begin with a small letter**, for example "after a change made elsewhere, put the saved arrangement back." The sentence is put together in the core from an occasion that starts in lower case. For the v0.2 session.
- **Nothing on screen tells a confirmed value from a sent one.** The PRD asks for it. The panel is told a value and never whether the monitor read it back. **Needed from the core:** for each control, whether the value in use was read back from the monitor or only sent.
- **The panel is not told how a display is connected.** The PRD's card is "name, connection". Today it says "External". **Needed from the core:** HDMI, DisplayPort, USB-C, Thunderbolt or built-in, where macOS reports it.
- **The floating Keep windows never take the keyboard.** They are shown without becoming the key window, so Return and Escape reach them only after a click. That is what v0.1 and v0.2 built, and it keeps a mode change from stealing the keyboard from the app in use. **Decision needed:** whether Keep and Revert should answer to the keyboard at once, because "every control reachable by keyboard" is part of this milestone's quality bar.
- **VoiceOver gets no name for three kinds of menu**: each display's Actions, each preset's More, and the input menu. The displays on the arrangement canvas are read as plain text and can only be moved with the pointer. Both are for stage 5 of this milestone.
- **Scenes are three steps away.** A preset is applied by opening the panel, opening "Arrangement and presets" and pressing Apply. The PRD wants one click.

**The last v0.2 commit changed spacing and nothing else.** The arrangement panels were drawn at the commit that broke up their views for the older compiler and at the one before it. Rows of the display list are 4 points closer together, and the items of the protection group and of the integration group 2 points each, so the panel is 12 to 16 points shorter. Every element, every text and the accessibility tree are the same, and the Keep windows and the protection offer are identical.

## 23 November 2026 · Two facts for the panel: how a value is known, and how a display is connected

Asked for by the planning thread for the interface pass, built by the core session. Unit tests and a read-only look at the I/O registry. Nothing was written to a display and the app was not started.

**How a value is known.** Each control of a connected display now says one of three things about the value in use: read back from the monitor (the PRD's "confirmed"), only sent, or not known. It follows what the app does anyway. No read was added for it.

- **Read back:** the monitor reported the value when the display was checked, in the read that follows a write, in the read after wake, or when the panel asked.
- **Sent:** the app wrote it and nothing confirmed it: a drag in progress, a monitor that did not answer the read after a write, a control that cannot be read. Software dimming is always sent. A brightness it has a share in is sent at best, and read back again once dimming is back at neutral.
- **Not known:** no value, or a value remembered from before that the monitor has not confirmed in this connection.
- **Across sleep:** when the Mac or the displays go to sleep, what was read back stops counting, because a monitor can wake with other values. The read the app makes once the wake has settled renews it: the same value or a new one both count as read back. A monitor that does not answer then stays not known, with its last value still shown, until the panel reads it or the user sets something. A value that was only sent stays sent while asleep, since nothing was claimed for it, and the same read after wake then decides for it too. A control that cannot be read is never asked and stays sent.
- **Across a reconnect:** a display that leaves takes its facts with it. When it returns, the check it gets anyway reads its controls, and those are read back. A returning monitor that says nothing has values that are not known.
- **At start:** the same as a returning display. With the startup policy "trust the stored value" nobody asks the monitor, so the value is not known. In safe mode a monitor seen before is not compared either, and stays not known until the panel reads it.
- **Decision needed:** whether sleep should end "read back" at once, as built, or only when the monitor then fails to answer. Built this way because the facts say what is known now, and between falling asleep and the read after wake nothing is.

**How a display is connected.** macOS describes the Mac's ports and each display link in the I/O registry (measurements in the feasibility notes). What it knows is the Mac's own end: which port, and whether the picture travels inside a Thunderbolt connection. It does not know the far end of the cable.

- **The label names the Mac's own port:** HDMI, USB-C, built-in, or Thunderbolt when the picture is tunneled through a dock, a hub or a Thunderbolt display. "DisplayPort" is kept for a port macOS itself calls that, which no Apple silicon Mac has.
- **On this desk the Lenovo reads HDMI and the LG reads USB-C.** The planning documents and the feasibility notes call the LG's connection DisplayPort. That is the signal, and by that word the Lenovo is DisplayPort too: the Mac feeds its HDMI port through a converter. The signal does not tell connections apart. The port does.
- **A USB-C port can end in a monitor's USB-C input, a DisplayPort plug or an HDMI adapter,** and macOS cannot tell which. So a user with a DisplayPort cable sees "USB-C", which is true of the Mac's end and may not be the word they would use.
- **Decision needed:** keep "USB-C" for a USB-C port that carries the picture directly, or show "DisplayPort" there. The second matches the desk notes and reads wrong with an HDMI adapter. It is one line in the mapping.
- **Not known is a real answer:** a display with no link entry (AirPlay, Sidecar, a virtual display, a USB graphics adapter, an older macOS), a port type in words this build does not know, and two identical monitors on different kinds of port, where a label would be a guess.
- **A display sleep does not change it.** The link entry stays while the displays sleep.
- **Not seen on hardware:** Thunderbolt, an adapter, identical monitors, another Mac. Which cable the LG is on is for the owner to say.

## 23 November 2026 · v0.2 Layout closed by the owner with three things left for a later version

The owner ended the v0.2 build session after the hardware checks. Left open, to be picked up and verified by a later version's improvements:

1. Check 11: the saved layout across a display sleep of ten minutes or more, with layout protection on. A long sleep with protection off wrote nothing.
2. The offer of decision 13, built and unit-tested, not yet seen on screen.
3. The built-in panel coming back when the last external display goes away, unit-tested only, and the owner's decision on turning it off automatically at all (entry below).

## 23 November 2026 · A change origin for automation, and what comes with it

Asked for by the planning thread, built by the core session on a branch cut from the v0.2 line. Unit tests only, nothing was run on hardware.

Until now the app's own rule-driven writes (layout protection, turning the built-in panel off) called themselves a restore. They now have an origin of their own, **automation**. A restore puts back what was there before. Automation acts on a rule the user set up.

- **It is automatic.** It passes the automation gate exactly as a restore does: closed while the app starts, while the Mac sleeps, in another user's session, and for the whole run in safe mode.
- **Nothing from outside can claim it.** Commands from the command line tool and from links always run as commands, and shortcuts as keys.
- **Everywhere else it behaves as a restore does,** with one exception below: no Keep or Revert countdown, no on-screen indicator, a muted monitor stays muted, and a write the monitor ignores is not counted as evidence against the control.
- **The exception: an automatic brightness change never lands on black unasked.** A restore puts back a value that was checked when the user chose it. A rule's value was not, and nobody is watching it arrive. So it gets the restore floor and, like a command, stops just above black unless the user allowed black at zero. No rule writes brightness yet, so this changes nothing today. **Decision needed:** confirm, or say that automation should match a restore here too.
- **A value a rule wrote is tracked and is nobody's choice,** and it leaves an earlier choice standing, as a restore does. One consequence to settle before the first rule writes a value: with "Put my values back after sleep" on, what is put back is the last value written, so the rule's value and not the one the user chose by hand.

**What an older build does with the new word.** No file holds an origin for its own sake. The recovery store has none and the log is text. The released 0.1.0 can meet an origin only in a request on the command socket, where an unknown word makes it refuse the whole request ("the request could not be read") and change nothing. No build sends automation there.

From v0.2 on the settings file holds commands, in presets and shortcuts, and each carries an origin. The app stores only "command" and "keyboard" there and replaces the origin when the command is run, so the new word never reaches the file. **Rule: keep it that way.** **Decision needed:** one stored command a build cannot read, whether for an origin, an operation or a value added later, makes that build set the whole settings file aside and start from defaults. It should cost that one preset or shortcut. This is worth closing before v0.2 ships, because afterwards v0.2 builds are the older builds.

**The gate is checked before each automatic write, not once per pass.** Restored values do this already, because each one goes through the command engine. Layout protection checks once and then changes the mode of each display in turn, waiting for the system to settle each time, so a write can go out after the Mac has begun to sleep. Reported to the planning thread for the v0.2 session.


Update, 23 November, on the v0.2 line: the rule-driven writes now use it. Layout protection (mode, rotation and the saved arrangement) and turning the built-in panel off and back on write as `automation`. Undoing an unconfirmed layout change after a crash, reconnecting at start and at quit, a built-in panel's reconnect that waited for the lid, and reconnecting when no display is left in use stay `restore`: each puts back the app's own change and follows no rule the user set. The gate is checked before each protection write, and presets and shortcuts are read entry by entry, so one stored command a build cannot read costs only its own entry.
## 23 November 2026 · The owner checks: what macOS does when a layout changes, and two bugs they found

Mac17,9, macOS 27.2.1, the Lenovo P32p-20 on HDMI and the LG SDQHD on DisplayPort, with the owner at the desk. Every result is in the feasibility notes. What matters for the product:

- **macOS keeps a configuration per set of displays and applies it by itself.** Seen three ways now: at a wake when the LG is briefly away, when the app disconnects the LG, and when the built-in panel joins. In each case the remaining monitors change mode (the Lenovo to 1920 × 1080) and change back when the set does. The app must treat these as macOS's own, not as outside changes.
- **A display that mirrors reports its source's size,** and gets its own mode back when it stops. Undoing a mirror with the size it had while mirroring looked like an overlap and was refused. Fixed.
- **Never turn the built-in panel on while the lid is closed.** It lights up behind the lid, becomes the main display, takes the menu bar, and macOS switches the external monitors to the three-display configuration. Fixed: it waits for the lid to open, at quit too.
- **An empty configuration transaction is silent,** so the app could even apply a no-op safely. It skips them anyway.
- **Shortcuts work without the Accessibility permission,** as system hot keys.

**Decision needed, raised by the owner:** turning the built-in panel off automatically leaves it dark until something brings it back, and when the app is not running only logging out does. The owner's view is that the internal display should not be left dark. It is off by default and comes back when the last external display goes away (unit-tested, not yet tried on hardware). The options: keep it as built, drop the feature, or limit it, for example to a panel that is turned off only while the app runs and is turned back on at quit whatever the lid does.

## 23 November 2026 · A development build gets a settings folder of its own

A build under test shared the settings folder, the recovery store and the command socket of the copy in daily use, and a v0.2 build writes a settings document that a v0.1 copy drops parts of. The paths belong to the core, so this is said here: `AppPaths` now reads `DISPLAY16X_SUPPORT_DIRECTORY`. When it is set, the app and the command line tool keep settings, the recovery store and the socket in that folder. Unset, every path is what it was. A build with its own folder also refuses to start while the copy in daily use answers on the standard socket, because both would drive the same monitors and color tables. The socket path must stay under about 100 characters, so a short folder such as `~/d16x-dev` is the one to use.

A side benefit: the smoke test can now run its "the app is not running" branch on a Mac where the app is in use, with the variable pointing at a folder no app uses. It passed on the M5 Pro.

## 23 November 2026 · v0.2: links need one line in the packaging script

The `display16x://` handler is built: it runs behind its own switch, off by default, checks a token the panel shows, goes through the engine and opens x-callback-url callbacks. macOS only routes a scheme to an app whose `Info.plist` declares it under `CFBundleURLTypes`. The plist is written by `scripts/package-macos.sh`, which v0.2 was asked to leave alone until the release branch has merged. **Change needed after that merge:** add a `CFBundleURLTypes` entry with the scheme `display16x` to the generated `Info.plist`. Until then links do nothing, and the URL scheme row of the feature inventory is built but not reachable.

Update, 23 November, after main took the release branch: done. The generated `Info.plist` declares the scheme, and the packaged bundle passes `plutil` and the version check. Links have not been opened on hardware yet.

## 23 November 2026 · At a wake, macOS runs the remaining monitor in another mode while the LG is away

Mac17,9, macOS 27.2.1, Lenovo P32p-20 on HDMI, LG SDQHD on DisplayPort, a display sleep of at least 27 minutes, seen by the read-only layout watch. The LG left 0.17 seconds after the wake and returned 3.6 seconds after it, as before. New: while it was away, the Lenovo ran at 1920 × 1080, its default size, instead of the 3200 × 1800 it had before and after. When the LG returned, macOS put both monitors back as they were, size and arrangement included. Details in the feasibility notes.

What it means for the product:

- macOS keeps a configuration per set of connected displays and applies it by itself. A monitor that is away for a few seconds changes the set, and the others change with it. These transient modes are not outside changes and must not be "corrected".
- Anything that restores a mode, rotation or arrangement has to wait until the set of displays has stopped changing, not only until the wake has settled. The wake settles at 3 seconds and the LG returned at 3.6. v0.2 protection waits for 5 seconds without a display arriving or leaving. A fixed value in the code for now.
- If it had acted at once, it would have written 3200 × 1800 into macOS's configuration for the Lenovo alone, which changes what the user sees the next time the LG is unplugged.
- The value restore of v0.1 is not affected: it does not touch modes.

## 23 November 2026 · v0.2 core: what it adds to the v0.1 core, and the rules it adopted

**Where v0.2 touches the v0.1 core.** No existing behavior changed: every v0.1 test passes unchanged. Five additions, each a hook the architecture reserved or the smallest step that leaves v0.1 alone:

1. `CommandEngine.extensions`: handlers that see a command after validation and the automation gate, and may answer it. Every v0.2 feature, and the new size steps, named sizes and rotation steps, go through it. A command no extension claims runs exactly as before.
2. `DisplayRegistry.stateOverride`: lets connection management report `disconnectedByApp` and `disconnectedBySystem`, the two states v0.1 reserved.
3. One event, `layoutConfirmationChanged`, for Keep and Revert on a layout or connection change.
4. Optional `layout` sections in the settings document and in each record's settings, and three fields in the recovery store (the layout before a change, whether it waits for Keep, and the displays the app disconnected). The settings version stays 1. A v0.1 build reads the file and ignores the new keys, and a higher version would make it set the whole file aside. The cost: a v0.1 build that saves the file drops the v0.2 sections. That only happens when two builds share one settings folder, as during development on this Mac.
5. The v0.1 test rig takes the feature registry as a parameter.

**A change for the session that owns the core, not needed now:** automatic layout, protection and connection writes carry the origin `restore`. A distinct origin such as `automation` would read better in logs and let a later consumer tell a restore from an automatic disconnect. Adding one touches three exhaustive switches in v0.1 code, so v0.2 did not.

**Rules adopted where the documents left room:**

- **Configuration restore acts only on a target the user asked to protect.** Mode and rotation protection are switches per display, and the arrangement, main display and mirroring are protected together by one switch with a saved layout. All are off by default. The target follows every change made through the app. This follows the v0.1 rule that only what the user set through the app is desired state, and macOS already put the arrangement back by itself after every cable test on this desk. **Decision needed:** whether layout protection should switch itself on once the user arranges displays through the app, which the PRD's "Layout: on" could be read to mean. *Decided as decision 13 and built: protection stays off by default, and after Keep on an arrangement, main display or mirroring change made through the app, the app offers it once. "Not now" stops the offers until the app starts again. On the command line the offer is one line in the result of `keep`, once per run.*
- **Protection stops after three attempts within two minutes for one target** and says so on screen. It starts again when the target changes. A mode the display no longer offers is skipped and said once.
- **Presets apply without Keep and Revert,** as the architecture says for presets. A click in the panel counts as a command inside a preset, so one preset does not open one countdown per display. `--try` on the command that applies it gives the countdown.
- **A disconnect lasts for the session only,** so logging out brings the display back even if the app is gone. Displays the app disconnected are reconnected at quit without waiting for the gate, the same as color tables are cleared at quit, because that undoes the app's own change. At the next start after a crash they are reconnected through the gate.
- **When the last display in use goes away by itself** and the app holds others disconnected, they are reconnected, through the gate. **Decision needed:** in safe mode the gate stays closed, so a Mac could be left with no picture until logout. The options are to let this one reconnect pass the gate, or to leave it as built and rely on the session-only disconnect. *Decided as decision 14 and built: in exactly this case the displays come back at once, in safe mode too, logged with the reason, like the reconnect at quit. The gate is unchanged. While the Mac sleeps it waits for the wake to settle, and a built-in panel behind a closed lid waits for the lid.*
- **Reset keeps the displays known under their tags.** Names and every setting go back to defaults, so a script that names a tag keeps working. Export leaves out the link token and values waiting for a display.
- **The model safeguard list is empty.** Nothing is known about a Mac where turning the built-in panel off is risky. The rule and its override switch exist, and a hardware report adds a model.
- **Turning the built-in panel off automatically pauses after the user brings it back by hand,** until an external display is attached or detached.

## 23 November 2026 · v0.2: Shortcuts actions are left out, because the Command Line Tools cannot build them

**Decision, as the brief asked.** An App Intent compiles and links with the Command Line Tools. The step that turns the intents into the metadata Shortcuts reads, `appintentsmetadataprocessor`, ships with Xcode only. An app bundle without that metadata offers Shortcuts nothing. The project builds with the Command Line Tools alone, so v0.2 has no Shortcuts actions. Measured in the feasibility notes.

What a Shortcuts user has instead, without any new code: the "Run Shell Script" action calling `display16x`, which reaches every feature, and once the URL scheme is registered, the "Open URLs" action with a `display16x://` link.

What would bring them back, for the maintainer: build the release with Xcode on CI (the runner has it), which gives up "builds with the Command Line Tools alone" for releases only, or wait for Apple to ship the tool with the Command Line Tools.

## 23 November 2026 · This Mac has a built-in panel: it is a laptop with the lid closed

The planning notes describe the test Mac as having no built-in panel. The power management root of Mac17,9 reports `AppleClamshellState` 1 and `AppleClamshellCausesSleep` 1, so it is a laptop running closed with two external monitors. macOS keeps the built-in panel out of the display list while the lid is closed.

What it means for v0.2:

- The built-in panel rules (turning it off when an external display is attached, the exceptions, the pause after a manual override) can be tried on this desk, but only by opening the lid. Opening it brings the panel into the layout, so it is a connection change and needs the owner at the desk.
- Lid events can be observed here by opening and closing the lid, with the same caution.
- The connection policy must treat a closed lid as "the built-in panel is already out of use", not as a display the app can take away. It is reported as disconnected by the system, never counted as an eligible display, and never offered for disconnect.

## 23 November 2026 · v0.2: asking macOS to look for displays again is left out

SkyLight exports `SLSDetectDisplays` on macOS 27.2.1. None of the permitted references documents what it takes, and calling a private function with a guessed signature can corrupt the caller's state or crash it. The feature "Redetect displays" is therefore not built. The button the system once had for this is a reasonable thing to send users to instead. It can be added later in `DisplayPrivate` if an MIT, BSD or Apache project or Apple documentation describes the call.
## 23 November 2026 · Releases: one certificate keeps the same signing requirement across builds, and Homebrew now rewards that too

The release mechanism is built on its own branch (runbook: [release.md](release.md)). Checked on the Mac17,9 with macOS 27.2.1, the Command Line Tools with Swift 6.4.2, and Homebrew 7.0.15. No tag, release, secret or GitHub setting was created.

**Decision 12, the signing identity for releases: still open. Decision needed.** The workflow works with each answer, chosen by which secrets the signing environment holds: a Developer ID with notarization, one project certificate without notarization, or none (ad hoc). The findings below make the project certificate a much better fallback than ad hoc.

**The designated requirement test.** Two different builds of the app (versions 0.1.0 and 0.1.1, different code hashes) were signed with one self-signed code signing certificate, held in a throwaway keychain file outside the login keychain and the search list, and deleted afterwards. No password prompt or system dialog appeared.

- Both builds had the identical designated requirement: `identifier "com.16xbrains.macdisplay16x" and certificate leaf = H"…"`, where the hash is the certificate's.
- The second build satisfied the first build's requirement. That is the check macOS makes against a stored Accessibility grant, and the one Homebrew makes at an upgrade.
- Ad hoc builds, for comparison, each have the requirement `cdhash H"…"` naming their own code, and the second fails the first's.
- The certificate was untrusted on this Mac, as a self-signed one is, and signing and verifying worked anyway.

What it means: a project certificate should keep the Accessibility grant across updates. It is not proven with the grant itself, which needs a person to grant Accessibility to one release and update to the next. The owner checks that with the first two releases signed this way. The requirement names that exact certificate, so renewing or replacing it costs every user the grant once: make it valid for many years, keep a backup, never create it again. The release workflow warns before publishing when a release's requirement no longer matches the previous release's.

**What Homebrew's current rules change** (read from the documentation and source that ship with Homebrew 7.0.15):

- **Upgrades keep the first-launch approval only for the same signer.** When `brew upgrade` replaces an app the user has approved, Homebrew carries the approval over to the new version only if it satisfies the old version's designated requirement. Otherwise it warns that the signer changed and macOS asks again. So with a project certificate, Homebrew users allow the first launch once, ever. With ad hoc, at every update. This is a second reason for a stable identity, next to Accessibility.
- **Taps need trust since Homebrew 6.0.** Casks from a tap that is not Homebrew's own load only when trusted. Installing by the full name, `brew install --cask engrmnaveed/tap/display16x`, trusts that one cask, so the guides use it.
- **Quarantine cannot be switched off from Homebrew any more.** `brew install` has no `--no-quarantine` option in 7.0. Every cask download is quarantined, and only a Developer ID with notarization opens without the user's approval. A user who wants to skip it removes the attribute with `xattr`.
- **Homebrew unpacks a ZIP with `unzip`.** The first archive built on this Mac with `ditto` carried each file's `com.apple.provenance` attribute as a separate `._` file. Unpacked with `unzip`, those files land inside the bundle and the signature no longer verifies ("file added"), which macOS treats as a damaged app. The archive now leaves extended attributes out, and CI unpacks it with `unzip` and verifies it. Space 16X archives its app the same way, so its published ZIPs are worth the same check.
- **Unchanged from the plan:** the official cask repository accepts only apps that pass Gatekeeper, so it stays out of reach until a Developer ID. A cask can quit the menu bar app for an upgrade, and Homebrew opens it again afterwards. The cask's `zap` removes `~/Library/Application Support/com.16xbrains.macdisplay16x`, the only folder the app writes: the code writes nothing else, and this Mac has no preferences file, cache or saved state for it. Homebrew cannot remove the Accessibility entry or a login item, so the installation guide tells users how.

**The hardened runtime, which notarization needs: the private interfaces resolve the same under it.** Two builds of the same commit were packaged, one signed ad hoc as usual and one signed ad hoc with the hardened runtime: the app, the tool inside it and the copy next to it, with no entitlements. Each ran the full read-only `display16x probe` and the smoke test, and the results were identical:

- All four private interfaces available, nine of nine reserved ones present, both monitors found.
- The same DDC replies: five of five codes on one monitor, four of five on the other, whose missing one is mute, a code that monitor does not support.
- The smoke test passed for both.

The menu bar app was not started under the hardened runtime, because the owner's copy was running, so the keys, their event tap and the panel are still unchecked under it. Open the first notarized build and check them. CI now compares the private interfaces with and without the hardened runtime on every pull request, and the notarization step compares them again on the signed copy. `DISPLAY16X_HARDENED_RUNTIME=1 scripts/package-macos.sh` repeats the test above.

**Where the signing secrets live: a deviation from the roadmap's wording.** The roadmap says the workflow signs with what the `release` environment holds. The build keeps the signing secrets in a second environment, `release-signing`, as Space 16X does, and `release` holds the tap's deploy key and the required reviewer. That gives one approval per release, after the app is signed, so the signed ZIP can be downloaded from the run and tried before it is published. A reviewer on `release-signing` as well would gate signing too, at the cost of a second approval.

Update, 23 November, 11:10: decision 12 is decided. Releases are signed with one project certificate, and a Developer ID with notarization replaces it later. The guides, the README and the cask now describe a certificate release as the normal case: the first launch allowed once, and the Accessibility permission and Homebrew's approval kept across updates. `scripts/render-cask` and `scripts/release-notes` default to that level, and the release job reads the level back from the signed app and stops when it differs from the one the cask and the notes would describe. Two things only the owner can do remain: create the certificate, and check with the first two releases that the permission really survives an update (steps in the runbook). Until that check, the promise in the guides rests on the designated requirement test above.

## 23 November 2026 · v0.1 Core is complete, with a short list held for later

The owner called the core done on 23 November and asked for the branch to be pushed. All four stages are built, 224 unit tests pass, and everything the owner could check at the desk has been checked. The full list of what was and was not run on hardware is at the end of the 23 November section of the feasibility notes.

Held at lower priority, by the owner's word:

- Fine points of software dimming after a return, such as the picture coming back at the 15% floor. With the 30 minute rule this now happens only after a long absence or at the start of the app.

Left for the maintainer, unchanged from the roadmap's open decisions: vendor input labels (5), a stable signing identity (6), one rotation run (7), identical monitors (8) and a DDC run without another display utility (9). Decisions 7 and 9 need the owner at the desk and a clear go-ahead, and neither was run.

Still unknown from this desk, and worth a hardware report from anyone who has the kit: a monitor that really forgets its values in standby, a connection that carries video and no DDC, an Apple display, and a MacBook Air M1.

For the planning documents: the roadmap still describes v0.1 as in progress. Build work does not edit it.

Update, 23 November, 09:45: the owner then stayed at the desk and gave the go-ahead for the remaining checks. All three are done and in the feasibility notes.

- **Decision 7, the rotation run: done.** 90° on the Lenovo with the countdown, left unanswered, back on its own after 15 seconds, arrangement unchanged. The private write path works on this Mac and so does the way back.
- **Decision 9, DDC without another display utility: done.** The owner quit BetterDisplay and the prototype. Both monitors answered exactly as they had with everything running. The LG refuses a single query on a quiet channel too, so sending queries twice is this monitor's need and not a side effect of company on the channel. Idle utilities cost no replies. A program that is reading at that moment does.
- **Cables: done.** Each monitor kept its tag, its system UUID and its display ID across an unplug and replug, and the LG also on another port of the Mac. macOS restored the arrangement by itself. For the product this means the system UUID is a dependable match key on this Mac for these two monitors, across ports as well. It says nothing yet about docks, adapters or two units of one model.

## 23 November 2026 · The after-wake default and the restore floor are built as decided, with three things to confirm

Built to the decisions recorded this morning (core architecture, sections 5 and 7). Unit-tested. The first run on hardware is the next wake of the displays.

- After wake and when a display returns, each control with a tracked value is read once and the app takes the monitor's word. Nothing is written. A display that returns is not asked twice, because the check of what it supports already reads every control.
- "Put my values back after sleep" is a switch per display, off by default. It reads first and writes only a value the user chose and the monitor no longer has.
- The restore floor lifts software dimming only. Hardware brightness set by hand comes back exactly.

Three places where the decision left room, and what was built:

1. **A short blank counts as the user returning. Decision needed.** The floor applies at wake, and a display sleep can last one second (measured, see below in this log). Someone who dims below the floor on purpose for night work will find the picture lifted to the floor after every idle blank. Built as decided. If that is not wanted, the floor could apply only after an unlock, the return of the session, the start of the app, or a sleep longer than some minutes.
2. **A display that comes back is treated like a return, for software dimming.** When a monitor leaves and returns, its software dimming is written again from the stored level, lifted to the floor if it was below. The decision lists start, wake, unlock and session return. A reconnect is not in the list, but the LG leaves and returns on its own at every wake from a long sleep, after the wake itself has been handled, so without this it would be the one display that comes back too dark.
3. **At the start of the app the stored value is still trusted. Decision needed.** The decision covers wake and reconnect. At start the app keeps what it stored and writes nothing, as before, although its check of each display reads the monitor's values anyway. A monitor changed while the app was not running is therefore shown with the old value until the panel is opened, which reads it. Reading and adopting at start as well would be the same rule everywhere and costs no extra queries.

One consequence worth knowing: after the app takes a monitor's value, that control is no longer "chosen", so switching "Put my values back after sleep" on later restores nothing for it until the user sets a value through the app again.

Update, 23 November, 09:02: points 1 and 3 were decided (decisions 10 and 11) and are built.

- The floor applies at the start of the app, and at a wake, unlock or session return only after the displays were off or the screen was locked for 30 minutes or more. The threshold is a setting. The time is read from the clock at the sleep and lock events. Lock, then sleep, then wake at the login window, then unlock counts as one absence, from the lock.
- At start the app reads each monitor and takes its word. With "Put my values back after sleep" on, a chosen value the monitor no longer has is written back at start as well, since a monitor that forgets in standby forgets across a restart too. A controller's startup policy can still say trust or write.
- Point 2 was narrowed to fit decision 10. A display that comes back gets the floor only when it comes back within one minute of a return from a long absence, or of the start of the app. That covers the LG dropping off at wake. A monitor that drops off in the middle of a session gets its dimming back exactly as it was set. The one minute is a fixed value in the code, not a setting. Say so if it should be one.
- The first start on hardware with this rule: both monitors read in half a second each, every value matched, nothing was written.

## 23 November 2026 · After a long display sleep the LG leaves the system, and both monitors still have their values

Mac17,9, macOS 27.2.1, Lenovo P32p-20 on HDMI, LG SDQHD on DisplayPort. The displays slept for five and a half hours with nobody at the Mac. BetterDisplay and the earlier prototype were running. Timings are in the feasibility notes.

What happened at the wake:

- The LG (DisplayPort) was reported removed 0.2 seconds after the wake and added again 3.3 seconds later, with the same display ID and UUID. The Lenovo (HDMI) stayed. The same happened at an earlier long sleep. After sleeps of 1.4 and 75 seconds neither monitor left.
- Both monitors still had the brightness they went to sleep with. This is the third wake measured, and in none of them had a monitor lost a value. Every write the restore made put back what was already there.
- The LG answered DDC 0.65 seconds before macOS announced it, and then gave "not ready" replies on and off for at least 16 more seconds.

What it means for the product:

- One wake can be two different events for two monitors on the same Mac: "after wake" for the one that stayed and "the display returned" for the one that left. Any rule for wake has to hold for both paths. The decision recorded today (read and adopt, restore only as a setting per display) is written that way.
- These two monitors do not need a restore after wake at all. Whether any common monitor does is still unknown from this desk.
- "Is the monitor ready" cannot be read from the system's display list. The LG was answering before it was listed and unreliable after.

Update, 23 November, 08:54: the LG left and returned again at a wake after 37 minutes of display sleep. It stayed through sleeps of 74 and 88 seconds. So it leaves somewhere between a minute and a half and 37 minutes, which is ordinary use, not only overnight. (At 09:17 it left after a sleep of 9 minutes 51 seconds, so the line is below ten minutes.) This was also the first run of the read-and-adopt rule on hardware: the app wrote nothing at the wake or at the LG's return, and both monitors still held every value the app had.

## 23 November 2026 · No reply is not the same as no control

Same wake as the entry above. Right after the LG returned, the app asked it which controls it has. Contrast and mute got no usable reply, and the app dropped both from the panel. They had answered at every check before. The contrast the owner had chosen was not put back either, because the control was gone.

Three programs and a probe were on the LG's DDC channel in those seconds: this app, the read-only wake probe asking four times a second, BetterDisplay and the earlier prototype. The probe received the answers to two of the app's questions. So the probe caused a good part of this, and it would be rarer in normal use. It can still happen whenever another display utility is running, and in the seconds after a wake when the monitor itself sends "not ready".

The rule the product should follow, now built: a control that has answered before stays until the monitor itself says it does not have it. A missing reply keeps what was learned. A control that has never answered is still left out, because some monitors stay silent about controls they lack and the app cannot tell the two apart on first sight.

Still open, small: a control lost on the very first check stays missing until the next start, a reconnect, or "Check Again" in the panel. No evidence yet that this happens without a probe running.

Other utilities may have interfered with this result, as the rules ask to be noted: BetterDisplay and the prototype were running and were not inspected.

Update, 23 November, 08:54: at the next wake no probe was running, the other two utilities still were, and the same check of the LG finished in under half a second with every control answering. So the probe caused most of the loss at 08:10. Running next to another display utility did not, on this one occasion, cost a single reply.

## 23 November 2026 · Software dimming is lost when the screen is unlocked, and the app cannot see it

Mac17,9, macOS 27.2.1, LG SDQHD on DisplayPort, checked twice by the owner. Details and timings are in the feasibility notes.

With software dimming on and a monitor in the software range, lock the screen, let the displays sleep, wake and unlock. The monitor comes back dimmed and a couple of seconds later returns to its own lowest brightness and stays there. macOS puts its own color table back around the unlock. It sends no display reconfiguration for it.

The app cannot find this out by looking. A process that has set a color table keeps reading its own table back after the system has stopped using it. Only another process sees the truth. So "check, and write again if it is gone" does not work, and the build that tried it changed nothing. Writing again does work: a new value sent after the unlock took effect at once.

What follows for the product:

- Software dimming has to be written again blindly at the moments the system is known to reset it: unlock, wake, the return of the user's session, reconfiguration, and a few bounded moments after each. Not on a timer.
- The panel cannot honestly say "confirmed" for software dimming. It can say what the app last wrote.
- While awake it looks right: smooth through the switchover, clearly darker than the monitor's own minimum, and back to normal on the way up. The owner confirmed this on both monitors.

Status: open. The owner asked to set it aside for now. Software dimming stays off by default.

Update, 23 November, 04:36: the blind rewrite is built. The table is written again on reconfiguration, wake, unlock and the return of the user's session, at 1, 3 and 8 seconds after each, and when the panel opens. Software dimming is now reported as accepted, never confirmed, and so is a brightness it has a share in. Nobody has watched it across a lock and unlock yet, so the status stays open until the owner has.

**Decision needed:** none yet. It becomes a decision if blind rewrites turn out not to be enough: whether software dimming ships in v0.1 at all, or with a note that it is lost at unlock until the brightness is touched.

Update, 23 November, 09:23: closed. The owner dimmed the LG to the bottom of the software range, locked, unlocked, and the picture stayed dimmed. The log shows the table written again at the unlock and 1 and 3 seconds after. Blind rewrites are enough for this case, and no decision is needed. Software dimming stays off by default for the other reason: it has not been checked with a custom color profile.

## 23 November 2026 · Other programs on the DDC channel answer each other's questions

Three programs were reading the same monitor after a wake: this app, a read-only probe and another display utility. The probe asked the LG for brightness and received a valid, correctly checksummed reply about contrast, which was the answer to the app's question a moment earlier.

A reply is only an answer if it names the feature that was asked for. The parser already requires that, and the captured reply is now a test. The wider point is for users: with two display utilities running, each will see more failed reads and retries, and a utility that does not check the feature code will show wrong values. Worth a line in the user-facing notes about running alongside other display tools.

## 23 November 2026 · A display sleep can last a second, and the app still rewrites every value

Mac17,9, macOS 27.2.1, Lenovo P32p-20 on HDMI, LG SDQHD on DisplayPort, BetterDisplay running. The displays went to sleep on the idle timer and the owner woke them 1.4 seconds later. This was the first time restore after wake ran on hardware.

What happened:

- Neither monitor went into standby, left the system or lost a value. Both answered DDC within a quarter of a second of the wake.
- The app waited its 3 seconds and then wrote all four values the owner had set through it: brightness on both monitors, contrast on one, volume on the LG. All four were already in place. Each write was accepted and read back.
- In the first 3.4 seconds after the wake, 4 of 88 read queries from a separate read-only probe got no usable reply, the last of them at the moment the app's writes went out. Three programs were on the channel, so this does not say which one was at fault.

What it means for the product:

- "Wake" is not "the monitor was in standby". A lid bump, a hot corner or the idle timer followed by a mouse move all produce a sleep and wake pair, many times a day. A rule that writes to the monitor on every wake writes far more often than the case it exists for.
- Reading first would have sent nothing here. That is one more reason for the option already put to the maintainer in the entry below ("Restore after wake cannot tell..."): read after wake, and write only a value the monitor no longer has. The cost is one read per control, and on the LG a read is two queries.
- The 3 second wake delay looks right for a short sleep, and bounded retries cover the bad replies in that window. It is still unmeasured for a monitor coming out of a real standby.
- The system's per-display "asleep" flag was still false inside the sleep notification. Sleep has to be taken from the notification, which is what the app does.

One thing for a later feature: when one display changes size, macOS reports that display as moved, with nobody having touched the arrangement. Anything that watches for arrangement changes made elsewhere must not count those.

**Decision needed:** nothing new. This is evidence for the open decision on the default after wake.

Update, 23 November, 08:30: decided and built. After wake the app now reads the monitor and writes nothing. See the entry at the top of this log.

## 23 November 2026 · An older Accessibility entry under the same name blocks the grant

The owner switched Accessibility on for Display 16X and the app still reported it as not granted, so the keys did nothing. System Settings showed one entry named Display 16X, left from an earlier build or from another app of the same name. After the owner deleted that entry and granted again from the panel, brightness and volume keys worked at once, with the indicator, and without restarting the app.

macOS ties the grant to the code signature, and an ad hoc signature changes with every build, so an entry can look right and belong to a build that no longer exists. Two rules follow:

- When the app sees "not granted" after the user has been sent to System Settings, the notice should say to remove the old Display 16X entry and add it again. (Built later the same day: the notice changes once a check after the request still finds the grant missing.)
- A stable signing identity for development builds would make this go away. That decision is already open in the entry on toolchain limits.

Also confirmed here: the grant takes effect while the app is running. No restart was needed on macOS 27.2.1.

## 23 November 2026 · The public mode list is not enough, even for v0.1

The roadmap and the feasibility note of 22 November say the public Core Graphics mode list is enough for the v0.1 resolution list. It is not, and the owner hit the consequence within minutes of using the panel.

What was observed on both monitors (macOS 27.2.1):

- The window server lists 53 modes for the LG SDQHD and 158 for the Lenovo P32p-20. The public list has 45 and 140.
- The missing ones are scaled HiDPI modes, the kind System Settings offers toward "More Space". On the LG they are 1512 × 1344, 1800 × 1600, 2160 × 1920 and 2304 × 2048. On the Lenovo they include 3840 × 2160 HiDPI and several 4:3 sizes.
- The public list shows such a mode only while the display is on it. The LG was on 2304 × 2048 HiDPI, so that mode was listed. The moment the app switched the LG to 1440 × 1280, the mode vanished from the public list.

Two things went wrong because of it. The timed revert could not go back: "the display no longer offers this mode", and the LG stayed at the smaller size until the owner fixed it by hand. And the text-size strip lost its "more space" side as soon as the display moved left, because the sizes to the right no longer existed in the public list.

What the build does now:

- The mode list comes from the window server's own list (a private interface in `DisplayPrivate`, optional at run time). The public list supplies exact refresh rates and the safe flag for the modes it knows. Without the private interface the public list is used alone, with the limits above.
- A mode the public list hides is selected by its window-server number, inside an ordinary configuration transaction. That is the call the MIT-licensed displayplacer uses.
- The strip no longer depends on the mode in use. On a display that offers HiDPI it shows the HiDPI sizes and ends at the panel's own unscaled size ("Native"), which is what the owner expects to find at the far end of "more space".

Checked by the owner on the LG after the change: the strip keeps all nine stops from any size, an unanswered change goes back on its own, Revert goes back at once, and Keep keeps.

This changes two planning statements: the capability map's "Public Core Graphics" for resolution, and the principle that v0.1 needs private interfaces only for DDC, brightness and rotation. **Decision needed:** confirm that mode listing and selection belong to the private-interface set for v0.1, with the public list as the fallback.

## 23 November 2026 · Shift at launch needs to be held, not just down

Safe mode starts when Shift is held at launch. The app was once started while the owner was typing, Shift happened to be down at that instant, and the app came up in safe mode without anyone asking for it. A login item starts while people are typing, so this would not be rare. Shift now has to be down at launch and still down 0.8 seconds later. `--safe` is unchanged.

## 23 November 2026 · The CLI can ask for the countdown too

The architecture gives the timed revert to interactive changes only, because nobody is there to confirm a change from the CLI. That stays the default. An opt-in was added: `display16x set resolution … --try` (also for refresh rate and rotation) asks Keep or Revert on screen and goes back on its own, and `display16x keep` or `revert` answers it. Someone typing a mode they are not sure their monitor can show gets the same safety net as someone using the panel. It is one option on the command, and the engine and the mode service treat it exactly like an interactive change.

On hardware: the Lenovo went from 60 to 50 Hz, was left unanswered, and returned to 60 Hz after 15 seconds.

## 23 November 2026 · A monitor can report a control it does not have

The Lenovo P32p-20 answers a volume query with "50 of 100" and ignores every volume write. A change sent through the app read back as 50 each time, and an independent read agreed. Its capabilities string leaves volume out, and in this case the string was right.

So there are three sources and none is proof on its own: a capabilities string can omit controls that work, a read can succeed for a control that does nothing, and a write can be accepted without taking effect. Only a write that reads back as the new value proves a control works.

What the product does now:

- A control is offered when the monitor answers a read for it, as before.
- When two changes made by hand in a row read back unchanged, with two reads agreeing each time, the control is marked as one the monitor reports and ignores. It leaves the card and stays in the detail view with that reason. "Check Again" gives it another chance.
- Automatic restores never count as evidence, and neither does anything during a wake transition, because a monitor that is not ready yet ignores writes too.
- Mute by "volume to zero" goes away together with volume.

On this desk that means: the Lenovo offers brightness, contrast and input. The LG offers brightness, contrast, volume, mute and input, and its volume and contrast writes were confirmed.

## 23 November 2026 · Restore after wake cannot tell "the monitor forgot" from "someone changed it"

DDC has no change notifications. When the app wakes and finds a monitor at another brightness than the one the user set here, there are two explanations it cannot tell apart: the monitor lost the value, or the user changed it with the monitor's buttons or with another utility. Restoring is right in the first case and wrong in the second.

What the build does: it restores only values the user set through the app, and it stops restoring a control as soon as it has seen another value on the monitor (which happens when the panel opens and reads it). That still leaves a window: a change made elsewhere that the app never saw is undone at the next wake.

This matters on any Mac that runs a second brightness tool, and on this one it would have shown at once, because another utility is in charge of these monitors. Both test monitors keep their brightness through standby, so on them a restore after wake only ever undoes outside changes.

**Decision needed:** the default for DDC values after wake. Either restore (the current default, right for monitors that forget), or read first and adopt what the monitor reports (right for monitors that remember, which is most of them), with restore as an opt-in per display. Software dimming is not part of the question: it lives in the app and always has to be written again.

## 23 November 2026 · A monitor's own input list beats the generic one

The Lenovo P32p-20's capabilities string lists three inputs: 17 (HDMI 1), 15 (DisplayPort 1) and 49. The command set defines no input 49, so it is the monitor's own value, presumably for its USB-C port. The generic list offers USB-C as 27, which this monitor does not list. A generic "USB-C" entry would therefore send it a value it never said it accepts.

The same string leaves out volume (0x62), and the monitor answers volume queries anyway. *Later the same day it turned out the string was right: the monitor ignores volume writes. See the entry above.* The capabilities string is still treated as a hint, because other monitors are known to omit controls that work.

What the product does now:

- Controls are found by asking for each one. The capabilities string is never used to rule a control out.
- A monitor is asked once for its input values. When it lists any, its input list is built from them, and the input in use is selected. A value the command set does not define is shown by its number ("Input 49"), because a guessed label on a switch that can cut the picture off is worse than an honest number. The user's own list, once they have one, is never replaced.
- A monitor that lists no inputs keeps the generic list.

**Decision needed:** whether to ship known labels per vendor for vendor-specific input values (for example "USB-C" for 49 on Lenovo), which needs each one confirmed on hardware, or to leave unknown values numbered until the user renames them.

## 23 November 2026 · The LG needs every query twice, and its replies are sound

Correction to the feasibility note of 22 November, which said the LG SDQHD sends a wrong length byte and a wrong checksum.

Measured with the LG awake: a query sent once is always answered with the DDC null message (`6e 80 be`), which means "listening, nothing to say". The same query sent twice, 5 to 100 ms apart, gets a real reply. In that reply only the second byte is off: it is `0x51`, the host address, where the length byte `0x88` belongs. The checksum is correct for the standard frame. The `ff` at the end of the first capture was a valid checksum that happened to look like filler.

What it means for the product:

- Queries are sent twice to every monitor by default. The Lenovo also drops the first query after a pause, so this is the general rule and not an LG exception.
- A reply with a garbled header is accepted when its checksum matches the frame the monitor meant to send. It then carries real integrity, and is trusted like any other.
- A reply whose checksum cannot be made to match is still read twice and has to agree with itself. No monitor on this desk needs that path.
- The LG offers brightness, contrast, volume, mute and input. Writes need no doubling: a single write takes effect on both monitors.

## 23 November 2026 · A monitor is probed too early when it returns after wake

When the displays woke, the LG left and came back four seconds later, and the app probed it within a second of its return. Whether it would have answered is unknown (see the entry above), and it showed the gap: a display that is silent right after it connects must be asked again without waiting for the user. The app now asks again after 3 and 10 seconds, then stops until the next wake or until the panel opens. It never does this while the displays are asleep.

Still owed: the measured time from wake to the first DDC answer on each monitor. The probe is waiting for the next natural wake. The wake settle delay stays at 3 s until then.

## 23 November 2026 · Both monitors take writes far faster than the budget

Brightness sweeps at 50, 20 and 5 ms spacing ended on the right value on both monitors, with one send per write and no failed call. A write call takes 6 to 8 ms. The budget of 20 writes a second is therefore a courtesy to the monitor and to the bus, and neither test monitor needs it. Sending each write twice is kept as the default because other monitors are known to drop single writes. It could become a per-monitor setting that defaults to once if more hardware agrees.

## 23 November 2026 · Color tables work on this M5 Pro at the interface level

The guide notes warn that color tables may need to stay off on M5 Pro. On this Mac a 0.7 gain was written to both displays, read back exactly, and removed again without a trace. That run happened while the displays were asleep, so nobody saw the picture. Three things are still unverified: how it looks, whether the table survives wake, and what happens with a custom color profile. Software dimming stays off by default until the owner has watched one run.

**Decision needed** after that check: turn software dimming on by default, or keep it opt-in.

## 23 November 2026 · Toolchain limits that shape the build

- In the macOS 27 SDK, SwiftUI's `@State` is a macro, and its plugin ships with Xcode only. A project that must build with the Command Line Tools cannot use the attribute. The app uses the `State` type directly, which behaves the same.
- Sleep, wake and display reconfiguration notifications only reach a process that runs an application event loop. A bare command-line process never hears them, so anything that has to react to wake needs the app, or a helper built like one.
- macOS ties a privacy grant such as Accessibility to the code signature. The package is ad hoc signed, so the grant is lost on every rebuild. Brightness keys will only be pleasant to test and to use once builds carry a stable signature.

**Decision needed:** a signing identity for development builds (a free Apple Development certificate is enough), so that the Accessibility grant survives rebuilds.

## 22 November 2026 · A monitor in standby can stop answering DDC

Mac17,9 (Apple M5 Pro), macOS 27.2.1 (26B131). While the displays were asleep, the LG SDQHD returned filler bytes to every DDC read (`a6` repeated eleven times on some reads, zeros on others), with or without a query before it. Its I2C bus was still alive: the EDID read over I2C worked. The Lenovo P32p-20 kept answering brightness queries while asleep.

What it means for the product:

- Silence is not proof that a monitor lacks DDC. A probe that gets no answer keeps whatever was learned before, and the display is probed again after the next wake and when the panel opens.
- Nothing automatic should talk to monitors while the displays are asleep. If the app starts while they are asleep, it behaves as if it had seen them go to sleep.
- "The monitor did not answer DDC on this connection" is the right reason to show until the monitor answers, and it must clear by itself.

## 22 November 2026 · The Lenovo drops the first query after a pause

Lenovo P32p-20 on USB-C/DisplayPort. The first DDC query after some idle time often returns zeros at a 50 or 100 ms read delay, and the retry succeeds. Reading five controls takes about 0.9 s including retries. One retry with a longer read delay is enough. Detection must stay off the main thread, and the panel must open from cached capabilities.

## 22 November 2026 · What the two test monitors offer over DDC

| Control | Lenovo P32p-20 | LG SDQHD |
| --- | --- | --- |
| Brightness (0x10) | 75 of 100 | 63 of 100 |
| Contrast (0x12) | 71 of 100 | 70 of 100 |
| Volume (0x62) | reports 50 of 100 and ignores writes | 13 of 100, writes confirmed |
| Mute (0x8D) | reports "unsupported code" | 2, not muted |
| Input (0x60) | 17 (HDMI 1 in the standard table), maximum reported as 49 | 15 (DisplayPort 1), maximum 18 |

A monitor with volume and no mute command is muted by "volume to zero" with the old level remembered, and the product falls back to that strategy on its own. The Lenovo looked like such a monitor at first. It is not: it has no working volume at all (see 23 November).

Both input readouts are right: the Lenovo is on HDMI and reports 17 (HDMI 1), the LG is on DisplayPort and reports 15 (DisplayPort 1). *An earlier version of this entry said the Lenovo was on USB-C and its readout was wrong. That was a mistake about the cable, not about the monitor.*

## 22 November 2026 · Mode list facts on macOS 27

- The system marks 101 of the Lenovo's 140 modes and 27 of the LG's 46 as safe. The rest are valid and not usable for the desktop. The size strip and the list hide them unless the user asks.
- The "native" flag marks every mode whose pixel grid is the panel's, so both 3840 × 2160 at standard density and 1920 × 1080 HiDPI carry it on the Lenovo.
- The "default" flag is not consistent. On the Lenovo it is 1920 × 1080 HiDPI at 60 Hz. On the LG it is 2880 × 2560 at standard density. The strip therefore treats the native-flagged mode of the current density as the default size when no default-flagged mode has that density.
- Every mode reports the same 8-bit pixel encoding through the public interface, so color depth cannot be told apart, and 14 of the Lenovo's modes have a twin with identical attributes. A mode is chosen by size, density and refresh rate. Depth is in the model and always 8 for now.
- A rotated display reports its modes in the rotated frame. The LG at 270° offers 2304 × 2048, and also keeps a handful of portrait-shaped leftovers that the native-aspect rule removes.
- Sizes offered on the strip: 11 on the Lenovo (1280 × 720 to 3360 × 1890), 5 on the LG (900 × 800 to 2304 × 2048).

## 22 November 2026 · Identical monitors cannot be told apart for DDC

A display is paired with its DDC channel by comparing the vendor, model and serial the window server reports with the monitor's EDID. All three agree on both test monitors. With two units that report the same identity there is nothing public that says which channel belongs to which display, and the display pipeline names (`dispext0`, `dispext1`) did not follow the window server's unit numbers on this Mac. The product pairs them in a stable order and marks the pairing as a guess, so the probe and the detail view can say that a command may reach the other unit.

**Decision needed** before a public release: either accept a "which monitor is this?" confirmation step for identical monitors, or approve a private lookup for the link between a display and its channel.

## 22 November 2026 · Rotation is present and unexercised

The only open reference for rotation on Apple silicon (displayplacer, MIT) uses the private display preferences class of the MonitorPanel framework. On macOS 27.2.1 that class is present, reports the same angle as the public interface for both monitors (0° and 270°), and says both can be rotated. The write path is built behind the timed revert and has never been run, because rotation on the live setup is off limits.

**Decision needed:** permission from the owner for one rotation test with the timed revert, or leave rotation marked unverified in v0.1.

## 22 November 2026 · Rules the build adopted where the documents left room

- **Restore is on by default, and only for values the user set through the app.** After wake and on reconnect, brightness, contrast, volume and mute are put back when the user chose them here. A value that was only read from the monitor is a belief and is never written back, and a change seen on the monitor (when the panel opens and reads it) ends the restore of that control. Without this, the app would undo changes made with the monitor's own buttons or with another utility. At app start the monitor's own values are trusted and nothing is sent, except software dimming, which lives in the process and has to be written again.
- **The restore floor applies to values the user chose by hand.** A brightness set to 10% comes back as 15% after the next wake. That follows "automatic restores never go below a minimum level" literally. **Decision needed:** keep it literal, or let a value the user set by hand be restored as it was.
- **Safe mode does nothing automatic at all**, including undoing a mode change that was left unconfirmed by a crash. The entry waits in the recovery store for the next normal start.
- **A partial mode request is resolved in a fixed order:** size first, then density, then refresh rate, then depth. A size that is only offered at another refresh rate wins over the requested rate, and the difference is reported.
- **A second interactive mode change during the countdown** restarts the countdown and still reverts to the mode in use before the first change.
- **A value set on a remembered display** is stored, queued and applied when the display returns. One-shot actions and the addressable brightness parts are refused instead.
- **Fine key steps can be smaller than a monitor's raw step.** A fine step is 1/64 of the scale and most monitors have 100 raw steps, so some fine presses change nothing on the hardware until the next one.
- **Defaults chosen:** switchover point 0.2, software zero level 0.15, restore floor 0.15, mode revert after 15 s, reconfiguration settle 1 s, wake settle 3 s, retention 90 days, DDC writes sent twice with 3 bounded retries and at most 20 per second.
- **Color tables are off by default** until the gamma-table spike has been run on this Mac. The guide notes say color tables may need to stay off on M5 Pro, and this Mac is one.

## 22 November 2026 · Where the architecture did not fit

- **The CLI imports more than `DisplayCore`.** A standalone `probe` has to list displays and talk DDC, so `display16x` also depends on `DDC`, `DisplaySystem` and `DisplayPrivate`. Everything except `probe` stays a client of the running app.
- **`DisplaySystem` imports `DisplayCore`, `DDC` and `DisplayPrivate`.** It implements the core's protocols, and it holds the adapter that turns the DDC scheduler into a controller, because `DDC` and `DisplayCore` do not import each other.
- **Four events were added** to the bus beyond the list in section 7: mode confirmation changed (Keep and Revert appear and disappear), gate changed, permissions changed and settings changed. Rotation changes travel on the existing mode-changed event.
- **The recovery store also holds an unconfirmed rotation**, next to the unconfirmed mode.
- **Tests use Swift Testing.** The Command Line Tools ship it and do not ship XCTest. The package manifest points the test targets at the macro plugin folder inside the Command Line Tools, because `swift test` does not find it on its own.

## 22 November 2026 · Another utility holds both DDC channels

The I/O registry shows a second client on the AV service of both monitors while BetterDisplay is running. Any DDC timing or readback measured on this Mac today can be affected by it. No measurement so far looks wrong because of it. The clean measurement is still owed, with BetterDisplay quit briefly, if the owner agrees.
