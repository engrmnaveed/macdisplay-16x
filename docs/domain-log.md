# Domain log

Findings about the domain and the product, reported by build work for the planning documents to absorb. See [AGENTS.md](../AGENTS.md#who-changes-what) for what belongs here.

Add new entries at the top. Each entry has a date, a one-line title, what was observed (with Mac model, macOS build, monitor and connection where relevant), and what it means for the product. Mark an entry **Decision needed** when the maintainer has to choose.

<!-- entries -->

## 23 November 2026 · v0.2 core: what it adds to the v0.1 core, and the rules it adopted

**Where v0.2 touches the v0.1 core.** No existing behavior changed: every v0.1 test passes unchanged. Five additions, each a hook the architecture reserved or the smallest step that leaves v0.1 alone:

1. `CommandEngine.extensions`: handlers that see a command after validation and the automation gate, and may answer it. Every v0.2 feature, and the new size steps, named sizes and rotation steps, go through it. A command no extension claims runs exactly as before.
2. `DisplayRegistry.stateOverride`: lets connection management report `disconnectedByApp` and `disconnectedBySystem`, the two states v0.1 reserved.
3. One event, `layoutConfirmationChanged`, for Keep and Revert on a layout or connection change.
4. Optional `layout` sections in the settings document and in each record's settings, and three fields in the recovery store (the layout before a change, whether it waits for Keep, and the displays the app disconnected). The settings version stays 1. A v0.1 build reads the file and ignores the new keys, and a higher version would make it set the whole file aside. The cost: a v0.1 build that saves the file drops the v0.2 sections. That only happens when two builds share one settings folder, as during development on this Mac.
5. The v0.1 test rig takes the feature registry as a parameter.

**A change for the session that owns the core, not needed now:** automatic layout, protection and connection writes carry the origin `restore`. A distinct origin such as `automation` would read better in logs and let a later consumer tell a restore from an automatic disconnect. Adding one touches three exhaustive switches in v0.1 code, so v0.2 did not.

**Rules adopted where the documents left room:**

- **Configuration restore acts only on a target the user asked to protect.** Mode and rotation protection are switches per display, and the arrangement, main display and mirroring are protected together by one switch with a saved layout. All are off by default. The target follows every change made through the app. This follows the v0.1 rule that only what the user set through the app is desired state, and macOS already put the arrangement back by itself after every cable test on this desk. **Decision needed:** whether layout protection should switch itself on once the user arranges displays through the app, which the PRD's "Layout: on" could be read to mean.
- **Protection stops after three attempts within two minutes for one target** and says so on screen. It starts again when the target changes. A mode the display no longer offers is skipped and said once.
- **Presets apply without Keep and Revert,** as the architecture says for presets. A click in the panel counts as a command inside a preset, so one preset does not open one countdown per display. `--try` on the command that applies it gives the countdown.
- **A disconnect lasts for the session only,** so logging out brings the display back even if the app is gone. Displays the app disconnected are reconnected at quit without waiting for the gate, the same as color tables are cleared at quit, because that undoes the app's own change. At the next start after a crash they are reconnected through the gate.
- **When the last display in use goes away by itself** and the app holds others disconnected, they are reconnected, through the gate. **Decision needed:** in safe mode the gate stays closed, so a Mac could be left with no picture until logout. The options are to let this one reconnect pass the gate, or to leave it as built and rely on the session-only disconnect.
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
