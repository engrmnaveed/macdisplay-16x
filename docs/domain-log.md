# Domain log

Findings about the domain and the product, reported by build work for the planning documents to absorb. See [AGENTS.md](../AGENTS.md#who-changes-what) for what belongs here.

Add new entries at the top. Each entry has a date, a one-line title, what was observed (with Mac model, macOS build, monitor and connection where relevant), and what it means for the product. Mark an entry **Decision needed** when the maintainer has to choose.

<!-- entries -->

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
