# Feasibility notes

Measurements that back the [roadmap](roadmap.md). Add a dated section for each new machine or macOS release.

## 22 November 2026 · Apple M5 Pro · macOS 27.2.1 (26B131)

Toolchain: Swift 6.4.2 from the Command Line Tools, no Xcode. Two external monitors, no built-in panel active.

| Monitor | Panel | Mode in use | DDC brightness read |
| --- | --- | --- | --- |
| Lenovo P32p-20 | 3840 × 2160 | 3200 × 1800 HiDPI, 6400 × 3600 backing, 60 Hz | 75 of 100, standard reply, 71 ms round trip |
| LG SDQHD (rotated 270°) | 2560 × 2880 | 2304 × 2048 HiDPI, 4608 × 4096 backing, 60 Hz | 63 of 100, non-standard reply |

### Display modes

The public mode list with low-resolution duplicates included returns 140 modes for the Lenovo and 46 for the LG. The window server's private count is 158 and 53. The Lenovo offers 27 distinct HiDPI sizes from 400 × 300 to 3360 × 1890. The LG offers 16. Refresh rates are 30, 50 and 60 Hz on both.

The public API is enough for the v0.1 resolution list. No display override files are installed on this Mac, so both modes in use are ones macOS provides on its own.

### DDC

Both monitors answer a brightness query (VCP code 0x10) through the AV service I2C channel.

The Lenovo reply is standard:

```
6e 88 02 00 10 00 00 64 00 4b 8b
```

The LG reply carries the right payload with a wrong length byte and checksum:

```
6e 51 02 00 10 00 00 64 00 3f ff
```

A strict parser rejects the LG reply. Longer read delays (100 and 200 ms) return the same bytes, so it is the monitor's framing and not timing. The parser must accept a reply whose result code, VCP code and value fields are consistent even when the header or checksum is wrong, and record that as a quirk for the monitor. Both captures belong in the `DDC` unit tests.

*Corrected on 23 November:* the LG's checksum is not wrong. Only its second byte is. See [how the two monitors answer](#how-the-two-monitors-answer-ddc).

Only reads were sent. Writes are a separate spike.

### Interface availability

All present on macOS 27.2.1:

| Area | Interfaces checked |
| --- | --- |
| Virtual displays | `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`, `CGVirtualDisplayMode`, and the newer `SLVirtualDisplay` |
| Modes and configuration | `SLSGetNumberOfDisplayModes`, `SLSGetDisplayModeDescriptionOfLength`, `SLSConfigureDisplayMode`, `SLSConfigureDisplayResolution`, `SLSConfigureDisplayEnabled`, `SLSSetDisplayRotation` |
| HDR | `SLSDisplaySupportsHDRMode`, `SLSDisplayIsHDRModeEnabled`, `SLSDisplaySetHDRModeEnabled` |
| Brightness | `DisplayServicesCanChangeBrightness`, `DisplayServicesGetBrightness`, `DisplayServicesSetBrightness` |
| DDC transport | `IOAVServiceCreateWithService`, `IOAVServiceReadI2C`, `IOAVServiceWriteI2C`, `IOAVServiceCopyEDID` |

`DisplayServicesCanChangeBrightness` returns false for both external monitors, as expected for non-Apple displays. The LG reports HDR support and the Lenovo does not.

### Not yet verified

DDC writes, gamma dimming, override install and activation, virtual display creation, disconnect and reconnect, HDR switching, rotation, built-in display brightness, and everything on a MacBook Air M1. These are the open spikes in the [roadmap](roadmap.md#spikes).

## 23 November 2026 · v0.1 Core build · Apple M5 Pro (Mac17,9) · macOS 27.2.1 (26B131)

Same Mac and monitors as above: the Lenovo P32p-20 on HDMI (it reports input 17, and macOS names its factory color profiles "HDMI") and the LG SDQHD on DisplayPort (input 15), rotated 270°. BetterDisplay 5 was running throughout and holds a client on both DDC channels, so every DDC number here was measured with a second utility present. Nothing looked disturbed by it.

### How the two monitors answer DDC

| | Lenovo P32p-20 | LG SDQHD |
| --- | --- | --- |
| Query sent once | Answers. The first query after a pause often returns zeros | Always answers with the DDC null message (`6e 80 be`): listening, not ready |
| Query sent twice, 5 to 100 ms apart | Answers | Answers, at any read delay from 10 to 50 ms |
| Reply framing | Standard | Second byte is `0x51` (the host address) where the length byte `0x88` belongs. The checksum is correct for the standard frame |
| While the display is asleep | Still answers | Returns filler: `a6` repeated, or zeros. EDID over I2C still reads |
| Brightness `0x10` | 75 of 100 | 63 of 100 |
| Contrast `0x12` | 71 of 100 | 70 of 100 |
| Volume `0x62` | Reports 50 of 100 and ignores every write | 13 of 100 (19 later, changed by the owner) |
| Mute `0x8D` | Unsupported code | 2 (not muted) |
| Input `0x60` | 17, maximum 49 | 15, maximum 18 |
| Reading all five controls | About 0.9 s | Under 1 s |

Captured LG replies, all with a checksum that is right once `0x88` is put back in the second byte:

```
6e 51 02 00 10 00 00 64 00 3f ff     brightness 63
6e 51 02 00 12 00 00 64 00 46 84     contrast 70
6e 51 02 00 62 00 00 64 00 0d bf     volume 13
6e 51 02 00 8d 00 00 64 00 02 5f     mute off
6e 51 02 00 60 00 00 12 00 0f c9     input 15 of 18
6e 80 be 04 00 0d 12 18 27 16 1c     single query: null message, then leftovers
a6 a6 a6 a6 a6 a6 a6 a6 a6 a6 a6     display asleep
```

Capabilities strings, read with `display16x probe --capabilities`:

- Lenovo: `model(ThinkVision P32p-20)`, MCCS 2.2, 32 codes. It lists inputs `60(11 0F 31)` and does not list volume `62`, which it answers anyway. Fragments carry 26 bytes of text in a standard frame.
- LG: fragments carry 32 bytes of text, again with `0x51` where the length byte belongs, so the length is not stated. It is recovered as the length for which the checksum of the standard frame fits. Both monitors' first fragments are unit-test fixtures.

What the DDC code does with this: every query is sent twice, the null message and uniform filler count as "no reply" and are retried, and a reply with a garbled header is accepted when its checksum matches the standard frame. A reply whose checksum cannot be made to match is read twice and has to agree with itself. All of the captures above are unit-test fixtures.

### DDC writes

`spikes/ddc-write-probe.swift` sweeps brightness 8 to 10 steps away and back, reads the value at the far end and at the end, and restores the original.

| Monitor | Spacing | Sent | Far end read back | End read back | Failed write calls |
| --- | --- | --- | --- | --- | --- |
| Lenovo | 50 ms | twice | correct | correct | 0 of 20 |
| Lenovo | 50 ms, 20 ms, 5 ms | once | correct | correct | 0 of 20 each |
| LG | 50 ms | twice | correct | correct | 0 of 16 |
| LG | 50 ms, 20 ms, 5 ms | once | correct | correct | 0 of 16 each |

A write call takes 6 to 8 ms, so 5 ms spacing is about 80 writes a second. Both monitors keep up, a single send is enough on both, and the last value always wins. The Lenovo was swept asleep and awake with the same result. The LG was swept awake.

Through the app, 40 `set brightness` commands issued in 1.31 s (30 a second) became 17 writes on the wire. The other 23 were replaced in the queue before they started. The monitor ended on the last value issued, the app's stored value matched the device, and the rate stayed under the budget of 20 writes a second.

Brightness set through `display16x set` was confirmed by an independent read on both monitors (Lenovo 75 → 70 → 75, LG 63 → 58 → 56 → 63), and both were left at their original values.

Other controls, each changed by one step through `display16x set`, read back, and put back:

| Control | Lenovo | LG |
| --- | --- | --- |
| Contrast | 71 → 70 → 71, confirmed | 70 → 69 → 70, confirmed |
| Volume | Sent 49 and 48, monitor still reports 50. After the second attempt the app marked volume as "reported and ignored" | 19 → 18 → 19, confirmed |
| Mute | No mute command, and no working volume to fall back on | Read as off. Not written, because the LG was the audio output in use |
| Input | Read as HDMI 1 | Read as DisplayPort 1 |

Input switching was never sent to hardware. It can cut the Mac off from the monitor, and nothing on this desk needs it.

Not tested: a connection that carries video and no DDC. There is none on this desk.

### Color tables

`spikes/gamma-table-write-probe.swift`, run while the displays were asleep:

- Both displays have a 1024-entry table. The table in use is a plain ramp, and neither display has a custom color profile.
- A gain of 0.7 was written to both: status 0, and the table read back exactly as written.
- The original table was written back: read back identical to the original, and still identical after the process exited.

The same path through the app, with the displays awake and software dimming switched on for the test: `display16x set softwareBrightness 80% --tag 2` was confirmed, a separate read of the LG's table showed it scaled to 0.830 (the 0.15 zero level plus 80% of the rest), the Lenovo's table stayed a plain ramp, and setting 100% put the LG's table back to a plain ramp. With software dimming on, the LG's 63% hardware brightness sits at 0.704 on the composite scale, as the 0.2 switchover says it should.

So the interface works on an M5 Pro, in a spike and through the app.

#### Software dimming by eye (01:48 to 02:17, checked by the owner)

- **Looks right while awake.** On both monitors the picture dims smoothly through the switchover with no step, the bottom of the scale is clearly darker than the monitor's own lowest brightness, and dragging back up returns the picture to normal.
- **A fast drag lagged, and no longer does.** On a quick move from 29% to the bottom, the monitor got three commands (27, 21, 0) at least 50 ms apart, and the software part was applied only after the last of them. The software part now goes first. The owner confirmed the lag is gone.
- **It is lost after the screen is locked and the displays sleep. Open.** With the LG at the bottom of the software range, the screen was locked, the displays slept for 75 seconds, and the owner woke and unlocked. The LG came back dimmed, and a couple of seconds later went to its own lowest brightness and stayed there. This happened twice, the second time with a build that looks at the table again at unlock and at 1, 3 and 8 seconds after wake and unlock.
- **Why the second build did not help.** It writes the table again only when it finds it replaced, and it never found that. Read from inside the app, the table still looked like the app's own. Read at the same time from a separate process (`spikes/gamma-table-write-probe.swift`, read-only), the LG's table was a plain ramp. So a process that has set a table keeps reading its own table back after the system has stopped using it. There was no reconfiguration callback either.
- **Writing still works.** A new value sent through the app after the unlock showed up in the separate process's read at once (0.745 for 70%, 0.788 for 75%).

What follows: the table has to be written again without asking whether it is still there, at unlock and at a few bounded moments after wake and unlock.

- **That change is built, and not yet watched (04:36).** The app now writes the table again blindly on reconfiguration, wake, unlock and the return of the user's session, at 1, 3 and 8 seconds after each, and when the panel opens. The read-back check is gone. Software dimming is reported as accepted, never confirmed, and so is a brightness it has a share in. The unit tests cover the moments and that writing again never dims twice. Whether those moments catch the reset at unlock can only be seen by someone at the screen: switch software dimming on, leave a monitor in the software range, lock, let the displays sleep a minute, wake and unlock. The app's log then shows each rewrite with milliseconds ("Color table written again on #2 after unlock").

Until that has been watched, color tables stay off by default. A custom color profile was not present in any of these checks.

#### Started while the displays were asleep (04:36)

The new build was started 1 hour 52 minutes into a display sleep, with nobody at the Mac.

- The Lenovo answered DDC while asleep and its controls were available at once. The LG did not answer, and the app kept what it had learned about it earlier, with the remembered brightness shown as a stored value.
- Nothing was written to either monitor: both restores were skipped with "automatic changes are paused: the Mac is asleep".
- The wake from this sleep was measured at 08:09. See [a display sleep of five and a half hours](#a-display-sleep-of-five-and-a-half-hours-measured-0809).

#### A 75 second display sleep, measured (01:54)

The read-only wake probe across the same sleep, with BetterDisplay and Display 16X running:

| | Lenovo P32p-20 (HDMI) | LG SDQHD (DisplayPort) |
| --- | --- | --- |
| First query after wake | No reply | Answered |
| First usable answer | 0.93 s after wake | At once |
| Queries answered in 20 s | 41 of 44 | 40 of 44 |
| Last unusable reply | 1.95 s | 3.35 s |

Neither monitor left the system, and IDs and UUIDs did not change. The LG sent the "not ready" null message at 0.47, 1.50 and 2.89 seconds. At 3.35 seconds the probe, asking for brightness, received a valid reply about contrast: the answer to a question the app had asked on the same channel. That reply is now a test fixture. The app's restore went out 3.2 seconds after the wake and every write was accepted on the first attempt.

### The mode list, public and private

| | Lenovo P32p-20 | LG SDQHD |
| --- | --- | --- |
| Modes in the window server's list | 158 | 53 |
| Modes in the public list | 140 | 45, or 46 while a hidden mode is in use |
| Hidden from the public list | 18, among them 3840 × 2160 HiDPI | 8, among them 1512 × 1344, 1800 × 1600, 2160 × 1920 and 2304 × 2048 HiDPI |
| Sizes on the text-size strip, public list only | 11 | 5, and only 4 once the display leaves 2304 × 2048 |
| Sizes on the strip, window server list | 13, ending at 3840 × 2160 native | 9, ending at 2880 × 2560 native |

The hidden modes carry the flags `0x200001` in the window server's list. A mode's number there is its index, and it equals the mode number the public interface reports for the mode in use. The description of a mode is read with the layout the MIT-licensed displayplacer documents (size at offsets 8 and 12, refresh rate at `0xBE`, density at `0xD0`), and a list that does not look right (a density other than 1 or 2, a number that is not its index) is discarded as a whole.

What went wrong with the public list alone, on the owner's first try: the LG was on the hidden mode 2304 × 2048 HiDPI. A size change to 1440 × 1280 worked, and neither the automatic revert nor the Revert button could go back, with "the display no longer offers this mode" in the log.

After switching to the window server's list and selecting hidden modes by number, the owner repeated the test on the LG (2304 × 2048 ↔ 2160 × 1920, both hidden modes):

- Unanswered change: applied at 00:58:51, read back a second later, reverted on its own at 00:59:07, read back as 2304 × 2048.
- Revert button: back within two seconds.
- Keep: the size stayed, the strip kept all nine stops, and dragging back to 2304 × 2048 worked.

### Mode change with the timed revert

The Lenovo's refresh rate was changed from 60 to 50 Hz at 3200 × 1800 HiDPI with `display16x set refreshRate 50 --tag 1 --try`, which asks Keep or Revert the way the panel does.

- The change was applied in a persistent configuration transaction and read back as 50 Hz within two seconds.
- Nobody answered. After 15 seconds the app went back to 60 Hz, and a separate probe read 60 Hz.
- The recovery file held the mode to return to during the countdown and was empty afterwards.

A refresh-rate change was chosen because it does not move windows. Size changes through the text-size strip, and Keep and Revert as buttons, were checked by the owner afterwards (see the mode list section above).

### Sleep, wake and identity

- The displays woke at 00:05. The app saw the LG leave and return four seconds later. The Lenovo stayed connected.
- Display IDs (4 and 5) and system UUIDs were the same before the display sleep, during it and after the wake, including across the LG's reconnect.
- The first version of the wake probe was a bare command-line process, which never receives sleep or wake notifications, so it missed that wake. The app's own probe one second after the LG returned got no answer, and that proves nothing, because it sent its query once and the LG never answers a single query. The fixed probe caught the next wake, below.
- Not tested: full system sleep, unplugging a cable, and moving a monitor to another port. The wake from a long standby was measured later, below.

#### A short display sleep, measured (01:38)

The displays went to sleep on the 10 minute idle timer at 01:38:28.556 and were woken by input 1.42 seconds later. BetterDisplay and Display 16X were both running. The read-only probe (`spikes/ddc-wake-probe.swift`) asked each monitor for its brightness about twice a second for 20 seconds after the wake.

| | Lenovo P32p-20 (HDMI) | LG SDQHD (DisplayPort) |
| --- | --- | --- |
| First query after wake | Answered, 0.12 s after the notification | Answered, 0.21 s after the notification |
| Brightness before sleep and after wake | 69 and 69 | 56 and 56 |
| Queries answered in 20 s | 43 of 44 | 41 of 44 |
| Queries without a usable reply | 1.5 s (all zeros) | 0.5 s and 1.5 s (the "not ready" null message), 3.3 s (stray bytes) |

- Neither monitor left the system. Display IDs and UUIDs did not change, and the reconfiguration callback at wake carried no add, remove or mode flag.
- `CGDisplayIsAsleep` said "awake" for both displays inside the handler of the "screens did sleep" notification. The notification is the signal. The per-display flag lags behind it.
- Every reply that failed came within 3.4 seconds of the wake. Two other programs were talking to the same monitors in that window, and the app's own restore went out at 3.0 seconds, so a monitor that was not ready and two programs colliding on the channel cannot be told apart from this run.
- A blank this short does not put the monitors in standby and they keep their values. How long a monitor needs after a real standby is **still not measured.**

The app during the same wake, from its log:

| Time | What the app did |
| --- | --- |
| 01:38:29 | Saw the wake and the reconfiguration begin |
| 01:38:31 | Reconfiguration settled (the 1 second settle delay) |
| 01:38:33 | Wake settled (the 3 second delay). Restore sent brightness to both monitors, contrast to one and volume to the LG. Each write was accepted on the first attempt |
| Afterwards | Both monitors read back the stored brightness (0.688 and 0.562). The gate was open and nothing was left pending |

This is the first run of restore after wake on hardware. It shows the path works: wake, settle, gate, write, read back. It does not show a lost value being repaired, because the monitors had lost nothing, so all four writes put back what was already there.

#### A display sleep of five and a half hours, measured (08:09)

The displays slept from 02:43:47 to 08:09:57, with nobody at the Mac. The probe, started at 04:37, saw no system sleep, so this was a display sleep with the Mac awake. BetterDisplay, the earlier prototype and Display 16X were running, and the read-only probe asked each monitor for its brightness four times a second for 20 seconds after the wake. Times are seconds after the "screens did wake" notification.

| | Lenovo P32p-20 (HDMI) | LG SDQHD (DisplayPort) |
| --- | --- | --- |
| Stayed in the system | Yes | No. Reported removed at 0.22 s and added again at 3.55 s |
| First usable DDC answer | 1.09 s | 2.90 s, which is 0.65 s before the system announced its return |
| Brightness before the sleep and at the first answer | 53 and 53 | 68 and 68 |
| Queries answered in 20 s | 40 of 45 | 26 of 37 |
| Queries without a usable reply | 0.1 s and 1.5 s (all zeros) | The "not ready" null message at 4.5, 5.4, 7.7, 11.8, 15.5 and 19.2 s. Replies to other questions at 4.9 s (contrast) and 7.2 s (mute) |

- **A long standby is different from a short blank.** After 1.4 and 75 seconds neither monitor left the system. After five and a half hours the LG did, for 3.3 seconds, as it had at the 00:05 wake. The Lenovo stayed. Display IDs and UUIDs were the same afterwards.
- **Both monitors kept their brightness through the standby.** The probe read the old values before the app wrote anything.
- **The reconfiguration flags tell the story.** At the wake both displays got a callback with no flags. At 0.22 s the LG got "removed, disabled, desktop shape" and the Lenovo "mode, desktop shape". At 3.55 s the LG got "added, enabled, mode, moved, desktop shape" and the Lenovo "mode, desktop shape" again. One second after the first pair the system listed one display, and one second after the second pair it listed two.
- **The LG answers DDC before macOS says it is back**, and it is not dependable for some time after. Null messages kept arriving until the end of the 20 second window, about 3.7 seconds apart from 11.8 s on. The app was idle by then and never reads on a timer, so another program was probably asking on the same channel. The two replies to other questions were answers to this app's own check of the LG, taken by the probe.

The app during the same wake, from its log:

| Seconds after the wake | What the app did |
| --- | --- |
| 0.0 | Saw the reconfiguration begin |
| 1.2 | Reconfiguration settled. "Display #2 disconnected" |
| 3.1 | Wake settled. Brightness 53% written to the Lenovo, accepted on the first attempt |
| 4.5 | Second reconfiguration settled. "Display #2 connected: LG SDQHD" |
| 4.5 to 7.7 | Checked what the LG supports. Five questions took 3.2 seconds, and two of them (contrast and mute) got no usable reply |
| 7.8 to 8.0 | "After the display returned": brightness 68% and volume 44% written to the LG, each accepted on the first attempt |

- **The restore did not repair anything**, for the third time. Every value it wrote was the value the monitor already had.
- **The check of the LG lost two controls.** Contrast and mute had answered at every earlier check. This time their questions went unanswered while the probe, the app and at least one other program were on the channel, and the app took "no reply" as "not offered". The LG's contrast slider and its own mute disappeared from the panel, and the contrast the owner had chosen was not put back. The probe made this far more likely than it would be in normal use, because it asks four times a second. The mistake in the app was real all the same: a control that answered before is now kept when a later check gets no reply for it, and only the monitor saying it lacks a control removes it. There is a unit test with the captured null message.
- **The wake delay held for the Lenovo.** Its first usable answer came at 1.09 s and the app wrote at 3.1 s.
- Not measured: a full system sleep, and a wake with no other program on the DDC channel.

#### The first build that reads after wake (started 08:32)

The build with the decided after-wake rule (read the monitor and take its word, write nothing) was started at 08:32 while the displays were asleep again. As before, the Lenovo answered and the LG did not, and nothing was written. `display16x get restoreAfterWake --all` answered "off" for both monitors, which is the default.

The displays then woke at 08:54:30, after a sleep of 36 minutes 37 seconds (macOS's own power log: off at 08:17:53, on at 08:54:30). No probe was on the DDC channel this time. BetterDisplay and the earlier prototype were still running. From the app's log, in seconds after the wake:

| Seconds after the wake | What the app did |
| --- | --- |
| 0.0 | Saw the reconfiguration begin |
| 1.3 | Reconfiguration settled. "Display #2 disconnected": the LG had left again |
| 3.0 | Wake settled. This is where the Lenovo's brightness and contrast are read. The log has no line for it: neither a different value nor a missing answer was reported, which is what matching values produce. The reads themselves are not logged in this build |
| 4.8 | Second reconfiguration settled. "Display #2 connected: LG SDQHD" |
| 5.3 | The check of the LG finished in 0.46 seconds with all five controls answering: brightness, contrast, volume, mute and input |
| Afterwards | Nothing. No write to either monitor, no retry, nothing left pending |

- **Nothing was written**, at the wake or when the LG returned. The build before this one wrote brightness to the Lenovo and brightness and volume to the LG at the 08:09 wake.
- **Both monitors still held what the app had**, read afterwards through the app: Lenovo brightness 53% and contrast 71%, LG brightness 68%, contrast 68%, volume 44%, mute off. Every value came back "confirmed". The values the owner had chosen are still marked as chosen, because nothing differed.
- **The LG's contrast and mute are back.** The older build had lost them at 08:10.
- **The LG leaves the system after 37 minutes of display sleep too.** It stayed through sleeps of 74 and 88 seconds, and left after 37 minutes and after five and a half hours. Where between 88 seconds and 37 minutes it starts to leave is not measured.
- **Without the probe the check of the LG was fast and complete**: 0.46 seconds here, 3.2 seconds with two controls lost at 08:10. The other display utilities were running both times. So the losses at 08:10 came mostly from the probe asking four times a second.
- Not seen yet: the app taking over a value that was changed on the monitor during a sleep, and "Put my values back after sleep" writing one back. Both need someone to change a monitor by its own buttons while the displays are asleep, or a monitor that forgets.
- The app logs nothing at the normal level when a monitor still has its values. A line in the verbose log now says which controls were asked and matched. That line is in the source, not yet in the running build.

Other things the probe's log showed while the owner was using the panel earlier: a size change on the LG is reported with the "mode", "moved" and "desktop shape" flags for the LG and with "desktop shape" alone for the Lenovo. So one display changing size is announced as a move, although nobody changed the arrangement.

### Interfaces and modes

- Rotation: the display preferences class of the MonitorPanel framework is present, reports the same angle as Core Graphics for both monitors, and says both can be rotated. The write path has never been run.
- Mode flags: 101 of the Lenovo's 140 modes and 27 of the LG's 46 are marked safe. Every mode reports the same 8-bit pixel encoding, so depth cannot be told apart through the public interface.
- Sizes on the text-size strip: 11 on the Lenovo (1280 × 720 to 3360 × 1890), 5 on the LG (900 × 800 to 2304 × 2048).

### Idle cost, measured against the budget in the PRD

Release build, packaged app, both displays awake and unchanged, panel closed, measured for 10 minutes (00:14:38 to 00:24:39) with `top` and `ps`. This is an M5 Pro. The budget is written for a MacBook Air M1, which was not available.

| Budget | Target | Measured here |
| --- | --- | --- |
| Idle CPU, menu closed | At most 0.1% of one core over 10 minutes | 0.02 s of CPU in 600 s, which is 0.003% |
| Recurring wakeups | None | 1 idle wakeup in 10 minutes |
| Memory, menu closed | At most 50 MiB after first use | 15 MB physical footprint before the panel was ever opened. 41 MB (peak 44 MB) after the owner had opened and closed it several times and dragged sliders |
| Menu open | Under 100 ms warm, no DDC on the main thread | Not timed. Capabilities come from the cache, and DDC runs on each display's own queue |
| Brightness drag | At most 20 writes a second, last value wins, final value sent | 17 writes for 40 commands in 1.31 s, and the monitor ended on the last value |

The process had 3 threads while idle. A separate debug-build process that builds and renders the whole panel off screen peaked at 67 MB, which is an upper bound for "panel open".

Checked by the owner in the panel and on the keyboard, with BetterDisplay running:

- Both monitors appear by name, and both screens follow their brightness slider while it is dragged.
- Refresh rate from the detail view: the Lenovo went to 50 Hz, asked Keep or Revert, and Revert returned it to 60 Hz.
- The LG's volume follows its slider, and the speaker button mutes and unmutes.
- After Accessibility was granted, the brightness keys and the volume keys change the monitor and show the indicator. The grant took effect without restarting the app.

The first attempt at the grant failed: the app kept reporting Accessibility as not granted. System Settings had a single older entry named Display 16X. The owner deleted it, granted again from the panel's button, and the keys worked at once.

Launch at login was not exercised. The login item service reports "not found" for the packaged app before it has ever been registered, and registering it would have changed the owner's login items.

### Building with the Command Line Tools alone

Three things the toolchain does not do on its own, each worked around in the repository:

- XCTest is not shipped. Tests use Swift Testing.
- `swift test` does not find the Swift Testing macro plugin. The manifest adds its folder for the test targets.
- In the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin ships with Xcode only. The app declares view state with the `State` type instead.

## Running the probes

The hardware report is part of the command line tool. It is read-only and needs no app:

```sh
swift run display16x probe                  # add --capabilities or --modes for more
```

The standalone probes in [`spikes/`](../spikes):

```sh
swiftc -O spikes/display-probe.swift -o /tmp/display-probe && /tmp/display-probe
swiftc -O spikes/ddc-probe.swift -o /tmp/ddc-probe && /tmp/ddc-probe
swiftc -O spikes/ddc-wake-probe.swift -o /tmp/ddc-wake-probe && /tmp/ddc-wake-probe
swiftc -O spikes/gamma-table-write-probe.swift -o /tmp/gamma-probe && /tmp/gamma-probe
swiftc -O spikes/ddc-write-probe.swift -o /tmp/ddc-write-probe && /tmp/ddc-write-probe "P32p"
```

The first four change nothing unless asked: `gamma-table-write-probe` only writes with `--apply`. `ddc-write-probe` always writes: it moves one monitor's brightness a few steps and puts it back.

To list the display-related functions a system framework exports on a given macOS version:

```sh
dyld_info -exports /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight | grep -i display
```
