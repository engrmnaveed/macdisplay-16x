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

### With and without other display utilities (09:31 to 09:37)

Every DDC number above was taken with BetterDisplay running. For this check the owner quit BetterDisplay and the earlier prototype. `spikes/ddc-reliability-probe.swift` is read-only and sends each monitor 120 queries: brightness 40 times with a single query, 40 times with the query sent twice, and the five codes the app uses in turn, 40 queries, each sent twice.

| Who else was running | Lenovo P32p-20 | LG SDQHD |
| --- | --- | --- |
| BetterDisplay, the prototype and Display 16X (one run) | Single 40 of 40. Twice 40 of 40. Five codes 40 of 40 | Single 0 of 40, all null messages. Twice 40 of 40. Five codes 40 of 40 |
| Display 16X alone (one run) | Single 36 of 40, and 4 replies that named another question. Twice 40 of 40. Five codes 40 of 40 | Single 0 of 40. Twice 40 of 40. Five codes 40 of 40 |
| Nothing else at all (two runs) | Single 80 of 80. Twice 80 of 80. Five codes 80 of 80 | Single 0 of 80. Twice 80 of 80. Five codes 80 of 80 |

On the Lenovo, "answered" for the mute code means the proper "unsupported" reply, 8 of 8 in every run.

- **The LG refusing a single query is the monitor's own behavior.** It did so 160 times out of 160 with nothing else on the channel. Sending the query twice is needed for this monitor whoever else is running.
- **With the query sent twice, no reply was lost in any run**: 320 queries per monitor, with and without the other utilities.
- **Other utilities sitting idle cost nothing.** The run with both of them running is identical to the runs with nothing running. So the numbers taken earlier with BetterDisplay running stand.
- **A program that is reading at that moment does cost replies.** The only strays in these runs came while Display 16X itself was running: 4 single-query replies on the Lenovo named another question. The app does not log its reads, and the probe did not yet say which question, so the source is not proven. The panel being opened during the run would explain it.
- **Reading all five codes takes about half a second per monitor** on the quiet channel, through `display16x probe`: 507 ms for the Lenovo, 461 ms for the LG.

Display 16X was quit for the two runs with nothing else running, and started again afterwards from the same build. At that start both monitors were read, every value matched, and nothing was written. The Accessibility grant was still in place.

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

### Reading a value back after a write (27 November 2026)

Measured with `spikes/ddc-settle-write-probe.swift` on a Mac17,9 with macOS 27.2.1 (26B131). The monitors were the Lenovo P32p-20 on HDMI and the LG SDQHD on USB-C, rotated, with no copy of Display 16X running. The probe writes and reads the way the app does: each write sent twice 10 ms apart, each query twice 10 ms apart, the reply read 50 ms later, and burst writes 50 ms apart. It reads back at about 0, 50, 100, 200, 400, 800 and 1,600 ms after the last write, plus once with the first read only after a second. Every run put the starting value back and checked it.

The question was raised by the report "LEN P32p-20: sent 63, but the display reports 50" after a dragged slider.

**Awake** (before the displays turned off at 12:56:24):

| Monitor and control | After one write | After a burst | First read after a second |
| --- | --- | --- | --- |
| Lenovo brightness, 100 → 90 | new value at the first read, about 95 ms | new value at the first read, about 95 ms | new value |
| LG brightness, 50 → 40 | new value at the first read, about 90 ms | 1 of 2 bursts: no reply for about 900 ms, then **41, the step before the last, for good** | new value |
| Lenovo volume, 50 → 44 | **never**: 50 at every read up to 1.7 s | never | never |

**Displays asleep**, still answering at first:

| Monitor and control | Result |
| --- | --- |
| LG volume, 70 → 64 | new value at the first read, about 95 ms, after one write and after a burst |
| LG brightness, bursts, first read at once | 1 of 8 lost the last write (reported 41, for good) |
| LG brightness, bursts, first read after 100 ms | 0 of 8 lost |
| LG brightness, a third batch | the LG stopped answering DDC from the fifth burst on, as its standby deepened. These runs are not counted. Its last restore could not be confirmed and is checked once it wakes |
| Lenovo brightness, 10 bursts, first read at once | 0 of 10 lost |

What it shows:

- **Neither monitor needs time before it reports a value it took.** When a value is taken, the first read has it, about 90 to 100 ms after the write. A longer wait would not have changed the reported value in any run.
- **The Lenovo never takes a volume.** It reports 50 whatever is written, as the earlier check in this file found. The banner was the app learning that from scratch on a fresh settings file: two such reads mark volume as reported and ignored.
- **The LG can lose the last write of a burst** when the read's query follows it within about 10 ms. It then reports the step before for good, and two reads that agree make the app believe the write was ignored. That would turn a dragged brightness slider into a false mismatch, and a second one would hide brightness as ignored. A first read held back 100 ms lost none in 8 bursts. The earlier write probe, which read 150 ms after each sweep, never lost a last value on either monitor. The DDC/CI standard asks for 50 ms after a Set VCP Feature before the next command, and the app sends its query after 10.
- **Not settled at first, and needed the displays awake:** how often the LG loses the last write with the query at once (1 of 2 awake, 1 of 8 asleep), and whether a 60 ms wait is enough.

**Awake re-run**, the same afternoon from 14:31, with the owner at the desk and `caffeinate -d` keeping the displays on (they had come on at 14:28). Bursts of 10 brightness writes, 50 → 40, counted by whether the last value was ever reported:

| Monitor | Each write sent | First read | Bursts that lost the last write |
| --- | --- | --- | --- |
| LG | twice | at once | 0 of 10 (and 1 of 2 earlier) |
| LG | twice | after 60 ms | 1 of 10: no reply for about 250 ms, then 45, five steps short |
| LG | twice | after 100 ms | 0 of 10 |
| LG | once | at once | 1 of 10: no reply for about 800 ms, then 43, three steps short. The probe's own three single restore writes after that run were ignored too, and the LG stayed at 40 until it was set back to 50 with each write sent twice |
| Lenovo | twice | at once | 0 of 10 |

Every value was back where it started at the end: LG brightness 50 and volume 70, Lenovo brightness 100 and volume 50.

What the re-run changes:

- **When the LG loses writes does not depend on when the next query comes.** It lost one with the first read held back 60 ms, and none with the read at once. Each loss looks the same: the monitor stops answering for a quarter of a second to a second, and then keeps a value one to five steps short of the last one written. It drops a run of writes while it is busy, the last among them. A wait before the read would not have saved any of these writes.
- **About one burst in ten loses its last write on the LG**, awake, whatever the read timing: 3 of 42 in all. None was lost on the Lenovo in 22 bursts.
- **Sending each write once is not safer on the LG.** It lost a burst too, and then ignored three single writes in a row, which the doubled writes never did.
- So the read-back that follows a drag finds the LG on an older value about one time in ten. A wait does not prevent that. Only sending the last value again once the monitor answers would.
- **So no settle gap was added.** A gap before the first read after a write made no measurable difference (3 losses in 42 bursts, whatever the timing). The gap that was written and tested for it is kept out of the code; its patch is with the bug notes.

**Through the app, with the value sent again** (test build 0.5.1, 224, of `473fd42`), awake at 14:57 with the owner at the desk. The app ran in safe mode with a settings folder of its own, and the displays were held on. Thirty drags were played on the LG through the command line: nine unverified steps from 49 to 41, then 40 with read-back, then 50 with read-back.

| Verified write | Confirmed | Needed one re-send | Needed two | Failed |
| --- | --- | --- | --- | --- |
| 40, after the burst | 30 of 30 | 2 (the LG reported 47 and 46) | 0 | 0 |
| 50, a single write after a confirmed 40 | 30 of 30 | 5 (the LG still reported 40) | 0 | 0 |

- Seven of 60 verified writes were lost on the LG, and one re-send brought each to the value. On 0.5.1 each would have shown "sent …, but the display reports …".
- The five where the LG had not moved at all would also have counted as evidence that brightness is ignored, and two of those hide it.
- **A single write can be lost too**, not only the last of a burst: 5 of 30 here.
- LG brightness was 50 and Lenovo brightness 100 before and after.


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

- **It now stays across a lock and unlock (09:23, checked by the owner).** With software dimming on and the LG at the far left, the owner locked the screen and unlocked about ten seconds later. The picture stayed dimmed. The app's log for that minute:

| Time | What the app did |
| --- | --- |
| 09:23:30.8 | Wrote the LG's table again after a display reconfiguration that came with the lock, and once more a second later |
| 09:23:32.8 | Wrote it again after the wake, then 1 and 3 seconds later. Both monitors were read and still had their values |
| 09:23:40.4 | Wrote it again at the unlock, then 1 and 3 seconds later |

The earlier failure was at exactly this point: the picture came back dimmed and went bright a couple of seconds after the unlock. Writing blindly at the unlock and shortly after is what holds it.

Not watched: a lock with a display sleep long enough for the LG to leave the system, where the dimming is written again from the stored level when the LG returns, and the lift to the floor after 30 minutes away. A custom color profile was not present in any of these checks, so color tables stay off by default, as decided.

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
- Not tested: full system sleep. The wake from a long standby and the cable checks came later, below.

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
- The app logs nothing at the normal level when a monitor still has its values. A line in the verbose log now says which controls were asked and matched.

#### A start with the displays awake (09:02)

The build with the two later decisions (the floor only after a long absence, and reading the monitor at start) was started at 09:02 with both displays awake. BetterDisplay and the earlier prototype were running.

- The check of the LG took 0.48 seconds and the check of the Lenovo 0.50 seconds. Every control answered.
- The verbose log says "At startup, #2 LG SDQHD still has its brightness, contrast, volume, mute" and "At startup, #1 LEN P32p-20 still has its brightness, contrast". The Lenovo's volume is not asked, because that control is marked as reported and ignored.
- Nothing was written to either monitor.
- Not seen yet on hardware: the floor after a long absence, because software dimming is switched off, and a value taken over from a monitor that was changed elsewhere.

#### The first wake with the same build (09:17)

The displays were off from 09:07:58 to 09:17:49, which is 9 minutes 51 seconds (macOS's own power log). No probe was on the DDC channel. BetterDisplay and the earlier prototype were running. From the app's verbose log, in seconds after the wake:

| Seconds after the wake | What the app did |
| --- | --- |
| 0.0 | Saw the reconfiguration begin |
| 1.3 | Reconfiguration settled. "Display #2 disconnected": the LG had left again |
| 3.5 | "After wake, #1 LEN P32p-20 still has its brightness, contrast." The wake settled at 3.0 and the two reads took half a second |
| 4.7 | Second reconfiguration settled. "Display #2 connected: LG SDQHD" |
| 5.2 | The check of the LG finished in 0.49 seconds with all five controls. "After the display returned, #2 LG SDQHD still has its brightness, contrast, volume, mute." |
| Afterwards | Nothing. No write to either monitor |

- **Both paths of one wake ran as designed**: "after wake" for the Lenovo, which stayed, and "the display returned" for the LG, which left. Neither wrote anything. The LG was not asked twice.
- **The LG leaves after less than ten minutes of display sleep.** Sleeps measured so far: 74 and 88 seconds (stayed), 9 minutes 51 seconds, 37 minutes and five and a half hours (left each time).
- **Both monitors kept every value again.** That is five measured wakes without a lost value.

Other things the probe's log showed while the owner was using the panel earlier: a size change on the LG is reported with the "mode", "moved" and "desktop shape" flags for the LG and with "desktop shape" alone for the Lenovo. So one display changing size is announced as a move, although nobody changed the arrangement.

### Cables: unplug, replug and another port (09:41 to 09:44, done by the owner)

Four steps, with Display 16X running. After each reconnect a watcher saved what `display16x list` and the system's display list said, and compared them with a record taken before.

| Step | Away for | Check of the monitor after its return | Tag, system UUID, display ID | Arrangement, mode, rotation, main display |
| --- | --- | --- | --- | --- |
| LG unplugged and plugged back into the same port | 23 s | 1.0 s, all five controls | Same | Same |
| Lenovo (HDMI, the main display) unplugged and plugged back | 20 s | 1.4 s, all four controls | Same | Same |
| LG moved to another port on the Mac | 10 s | 1.0 s, all five controls | Same | Same |
| LG moved back to its first port | 7 s | 1.0 s, all five controls | Same | Same |

- **The system UUID did not change in any step, also not on another port.** Neither did the display ID. Each monitor came back under its own tag, and no second record was created: there are still two records.
- **macOS put the arrangement back by itself each time**: the same origins, the LG still at 270°, the Lenovo main again after its own replug.
- **Nothing was written to a monitor.** After every return the app read the monitor, every value matched, and the verbose log says so ("After the display returned, #2 LG SDQHD still has its brightness, contrast, volume, mute").
- The check of a monitor right after a cable reconnect took about a second, twice as long as at a start with the monitor already connected.
- Not tested: a monitor that was powered off while unplugged, a dock or adapter in between, and a second unit of the same model.

### Rotation through the timed revert (09:30, with the owner present)

One run, on the Lenovo, which was at 0° and is the main display. The LG stayed at its 270°. Command: `display16x set rotation 90 --tag 1 --try`.

| Time | What happened |
| --- | --- |
| Before | Lenovo 3200 × 1800 at the origin, 0°, main. LG 2304 × 2048 to its left, 270° |
| 09:30:13.8 | The Lenovo turned to 90° and became 1800 × 3200. The command answered "confirmed 90, keep or revert within 15 seconds". The LG did not move |
| While waiting | The recovery store held the unconfirmed rotation with 0° as the way back |
| 09:30:29.9 | Nobody answered. "Mode change on #1 was not confirmed. Reverting." |
| 09:30:31.4 | Back at 0°. Origins, sizes, rotation, the main display and both modes were identical to the record taken before. The recovery store was empty again |

- The write path through the MonitorPanel class works on this Mac, and so does the way back.
- Rotating one display did not disturb the other one's place in the arrangement.
- Not run: Keep, Revert by hand, 180° and 270°, and a rotation of the LG.

### Interfaces and modes

- Rotation: the display preferences class of the MonitorPanel framework is present, reports the same angle as Core Graphics for both monitors, and says both can be rotated. The write path ran once, on 23 November at 09:30, described below.
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

### A second machine: the CI runner (23 November)

The first CI run on the pull request is the first time the project was built and run anywhere but the developer's Mac.

| | Developer's Mac | GitHub's `macos-latest` runner |
| --- | --- | --- |
| Machine | Mac17,9, Apple M5 Pro | VirtualMac2,1, Apple M1 (Virtual), 7 GB |
| macOS | 27.2.1 | 26.7.2 (25G332) |
| Swift | 6.4.2, Command Line Tools | 6.3.3, Xcode |
| Build and 224 unit tests | Pass | Pass |
| Packaging and smoke test | Pass | Pass |

What the read-only hardware report said on the runner:

- All four private interfaces resolved on macOS 26.7.2 as well: the AV service for DDC, native brightness, rotation and the window server's mode list. The nine symbols reserved for later milestones were present too.
- The runner has one display, "Apple Virtual", with vendor 0 and model 0. The app classes it as an external placeholder. It offers 12 modes, 11 of them marked safe, at 1024 × 768 and 60 Hz, and macOS offers rotation for it.
- No DDC channel and no native brightness on that display, and both are reported as a missing control, not as an error.
- Without the app running, a command for the app exits with "not running" at once. This branch of the smoke test cannot run on the developer's Mac while the app is in use.

This is a virtual machine with no monitor, so it says nothing about DDC or real modes on macOS 26. It does show that the app's own rule holds there: a control that is missing is switched off, and nothing stops the tool.

The runner's older compiler (Swift 6.3.3) gave up on a SwiftUI expression that this Mac's Swift 6.4.2 accepts: the body of the v0.2 arrangement canvas, which took 18 ms to type-check here and mixed `Double` and `CGFloat` arithmetic inside one modifier chain. No compile time on this Mac predicts that limit, so the v0.2 app files are now held to 10 ms per expression and 15 ms per function body here, measured with `-warn-long-expression-type-checking=10 -warn-long-function-bodies=15`, with geometry worked out in typed constants before the view uses it. The whole package also builds clean at 100 and 200 ms.

### Where v0.1 Core stands at the end of 23 November

Checked on this desk, by measurement or by the owner's own hands: display records and tags, the mode list and the text-size strip with Keep and Revert, refresh rate, DDC brightness, contrast, volume and mute, the brightness and volume keys with the indicator, software dimming while awake and across a lock, one rotation with the revert on its own, DDC replies with and without other display utilities, identity across a cable replug and a change of port, reading the monitors at start and after wake, the idle and memory budgets, and the build with the Command Line Tools alone.

Built and unit-tested, and not run on hardware:

- Input switching. It can cut the Mac off from the monitor, and nothing on this desk needs it.
- Launch at login, and native brightness (no built-in or Apple display here).
- "Put my values back after sleep" writing a value back, and the app taking over a value that was changed on a monitor during a sleep. Neither test monitor loses a value, and nobody changed one by its buttons while the displays slept.
- The lift of software dimming to the floor after 30 minutes away, and software dimming with a custom color profile.

Not measured:

- A full system sleep, as opposed to a display sleep.
- Any real Mac other than the M5 Pro, in particular the MacBook Air M1 the PRD sets the budgets for. The CI runner is a virtual M1 on macOS 26 with no monitor.

## 23 November 2026 · v0.2 Layout spikes · Apple M5 Pro (Mac17,9) · macOS 27.2.1 (26B131)

Same Mac and monitors as above. Display 16X 0.1.0 from the main checkout, BetterDisplay and the earlier prototype were running and were left alone. Everything in this section is read-only unless it says otherwise.

### What macOS reports about the layout (11:12, displays asleep)

`spikes/layout-probe.swift`, with nobody at the Mac:

| | Lenovo P32p-20 (HDMI) | LG SDQHD (DisplayPort) |
| --- | --- | --- |
| Display ID | 4 | 5 |
| Global frame, top-left origin | (0, 0), 3200 × 1800 | (−2304, −248), 2304 × 2048 |
| Screen frame, bottom-left origin | (0, 0), 3200 × 1800 | (−2304, 0), 2304 × 2048 |
| Main display | Yes | No |
| Rotation | 0° | 270° |
| Mirroring | None, not in a mirror set | None, not in a mirror set |

- **The main display is the one at the global origin.** The LG sits to the left of the Lenovo with the bottom edges aligned: −248 + 2048 = 1800. The two coordinate systems differ only in where y starts, so an arrangement is stored in the global, top-left frame and converted once for the panel.
- **The sizes are logical sizes in the rotated frame.** The LG's 2304 × 2048 at 270° is its HiDPI mode turned on its side. A rotation or a size change moves the frame, which is why macOS reports a size change as a move.
- **While the displays sleep, the active display list is empty** and the online list still has both. The inventory reads the online list, which is right. Anything that looks at "active" displays during a display sleep sees none.
- **The lid is closed.** `AppleClamshellState` is 1 and `AppleClamshellCausesSleep` is 1 in the power management root. This Mac is a laptop in clamshell mode, so it does have a built-in panel. macOS leaves it out of the online list while the lid is closed. See the domain log.
- **Private symbols present** (looked up, never called): `SLSConfigureDisplayEnabled` and its older name `CGSConfigureDisplayEnabled`, `SLSDetectDisplays`, `SLSConfigureDisplayMirrorOfDisplay`. Origins, mirroring and the main display need only the public configuration transaction (`CGConfigureDisplayOrigin`, `CGConfigureDisplayMirrorOfDisplay`).

### What a configuration transaction announces

Not yet seen for an arrangement, main display or mirroring change, because making one needs the owner. What earlier logs already show:

- A size change on the LG arrives as "mode, moved, desktop shape" for the LG and "desktop shape" for the Lenovo (v0.1 notes above). Arrangement protection therefore cannot treat "moved" as an outside change of the arrangement. It compares origins after the reconfiguration settles.
- At a wake after a long sleep the LG leaves with "removed, disabled, desktop shape" and returns with "added, enabled, mode, moved, desktop shape".

`spikes/layout-probe.swift --watch` was left running from 11:13 to log every callback and the layout one second after the last one, so the next wake on this desk is recorded without anyone touching the layout.

### A wake seen by the layout watch (11:39)

The displays had been asleep since before 11:12, with nobody at the Mac, when they woke at 11:39:48. `layout-probe --watch` logged, in seconds after the "screens did wake" notification:

| Seconds | What macOS reported |
| --- | --- |
| 0.00 | A reconfiguration with no flags for both displays |
| 0.17 | The LG: removed, disabled, desktop shape. The Lenovo: mode, desktop shape |
| 1.2 | One display online. **The Lenovo at 1920 × 1080**, its default size, instead of 3200 × 1800 |
| 3.62 | The LG: moved, mode, added, enabled, desktop shape. The Lenovo: mode, desktop shape |
| 4.7 | Both online. The Lenovo back at 3200 × 1800 at the origin, the LG back at (−2304, −248), 270°, both unchanged |

- **While the LG is away, macOS runs the Lenovo in another mode.** It looks like the configuration macOS keeps for the Lenovo alone. When the LG returns, the two-display configuration comes back, size and arrangement included, with no help from any app.
- **The app's wake pass runs before the LG is back.** The wake settles 3 seconds after the notification and the LG returned at 3.6. Mode protection acting at that moment would see the Lenovo "wrong", put 3200 × 1800 back, and write it into macOS's configuration for the Lenovo alone. Protection now waits until the set of connected displays has been the same for 5 seconds, and a unit test replays this wake.
- The LG's absence lasted 3.45 seconds, in line with 3.3 seconds measured on 22 and 23 November.

### Prepared, not run: the checks that change the layout

`spikes/layout-write-probe.swift` holds one step per check. Each records the layout, applies one transaction "for this session" (logging out undoes it too), logs the callbacks, holds for 8 seconds, puts the recorded layout back and compares. Ctrl-C also puts it back. It refuses to disconnect the main display or the only display.

| Step | Command | What it answers |
| --- | --- | --- |
| Empty transaction | `layout-write-probe noop --yes` | Whether a transaction with no change announces a reconfiguration |
| Move a display and back | `layout-write-probe move 5 --yes` | The flags of a real move, and whether macOS keeps a 100-point slide along the edge |
| Main display and back | `layout-write-probe main 5 --yes` | The flags of a main change, and that shifting every origin is how it is done |
| Mirror and unmirror | `layout-write-probe mirror 5 4 --yes` | The flags, what the mirror target's frame and mode become, and the way back |
| Disconnect and reconnect | `layout-write-probe disconnect 5 --yes` | Whether a disabled display leaves the online list, keeps its display ID, and comes back with the same tag, mode, rotation and place |

None of them has run. Each needs the owner at the desk and a yes in the session.

### Shortcuts actions and the Command Line Tools

An App Intent with a parameter and an App Shortcuts provider compiles and links with Swift 6.4.2 from the Command Line Tools: the AppIntents framework and its Swift module are in the SDK. The build step that extracts the intents' metadata into the app bundle, `appintentsmetadataprocessor`, ships with Xcode only. The Command Line Tools hold its build specification and not the tool. Shortcuts discovers an app's actions from that metadata, so an app built without it offers none. This was not tried against the Shortcuts app, because that means registering a test app with the system. Shortcuts actions are left out of v0.2 (see the domain log).

### Where v0.2 stands at the end of 23 November

Built and unit-tested with fakes (308 tests pass, 84 of them new): arrangement, the main display, placement, mirroring, disconnect and reconnect with the connection policy, Keep and Revert for all of them, protection of mode, rotation and the saved layout, presets, shortcuts, links, settings export, import and reset, the CLI verbs and the plain panel entries.

Run on hardware, read-only: the layout probe, the layout watch across one wake, the hardware report's new layout section, and the adapters' read path (frames, main display, mirror source, the lid, the connection interface's presence). They agree with each other.

Not run on hardware, because each one changes the layout and needs the owner: every write of the layout adapter and the connection adapter, and so every v0.2 feature end to end. The app was not started: the owner's copy of Display 16X 0.1.0 is running from the main checkout and holds the settings folder and both DDC channels.

Not measured: the idle and memory budgets with v0.2. Nothing in v0.2 repeats: every wait is one-shot (the countdown, the protection check, the gathering of size steps), the lid is followed through notifications, and shortcuts are system hot keys.

#### The checks for the owner, in order

Before starting: record the layout with `layout-probe`, and decide which Display 16X runs. The v0.2 build refuses to start while the 0.1.0 copy runs, so that copy is quit first. Start the v0.2 build with `DISPLAY16X_SUPPORT_DIRECTORY=~/d16x-dev` so it keeps its settings apart and never writes the 0.1.0 copy's file, and use the command line tool with the same variable. An ad hoc build loses the Accessibility grant (shortcuts do not need it, the brightness keys do).

| # | Check | How | Done when |
| --- | --- | --- | --- |
| 1 | Empty transaction | `layout-write-probe noop --yes` | The callbacks it causes, if any, are logged |
| 2 | Move and back | `layout-write-probe move 5 --yes` | Flags logged, layout matches the record afterwards |
| 3 | Main display and back | `layout-write-probe main 5 --yes` | As above, the menu bar moves and returns |
| 4 | Mirror and back | `layout-write-probe mirror 5 4 --yes` | As above, the LG shows the Lenovo's picture and returns |
| 5 | Disconnect and back | `layout-write-probe disconnect 5 --yes` | The LG leaves the online list, returns under the same display ID with its mode, 270° and place |
| 6 | Main display from the CLI | `display16x set main on --tag 2 --try`, left unanswered | Back after 15 seconds |
| 7 | Placement and Keep | `display16x set placement right:start --tag 2 --of-tag 1 --try`, then `display16x keep` | Stays; then `display16x revert` puts the LG back left |
| 8 | Mirroring | `display16x set mirror on --tag 2 --of-tag 1 --try`, Revert in the window | Back at once |
| 9 | Disconnect | `display16x disconnect --tag 2 --try` unanswered, then `disconnect --tag 2` and quit the app | Back after 15 seconds; back at quit |
| 10 | The panel | Actions menu and the arrangement canvas, Keep and Revert | Same results as 6 to 9 |
| 11 | Saved layout across wake | `display16x set protectLayout on`, display sleep of 10 minutes or more | The LG leaves and returns, the log shows no layout or mode write |
| 12 | Saved layout after an outside change | Move the LG in System Settings | Put back once, with the notice |
| 13 | Preset from a shortcut | `display16x preset save Desk`, change the main display, `display16x shortcut add ctrl+opt+1 set preset Desk`, press the keys | The setup returns |
| 14 | Budgets | Ten minutes idle with the panel closed, then memory after use | Within the PRD's targets |
| 15 | Lid, optional | Turn on "Built-in panel off while an external display is attached", open the lid | The built-in panel comes on and the app turns it off; the log shows the lid events |

The links (`display16x://`) can be checked once the packaged v0.2 app has run once, so macOS knows it declares the scheme: switch links on in the panel, then `open "display16x://get/brightness?main&token=TOKEN"`.

### The owner checks (23 November, 12:17 to 13:09, the owner at the desk)

The layout was recorded at 12:17 (the Lenovo, display 4, main at 0,0, 3200 × 1800; the LG, display 5, at −2304,−248, 2304 × 2048, 270°) and matched that record after every check. The owner's Display 16X 0.1.0 ran during checks 1 to 5 and was quit, with the owner's agreement, for the rest. The v0.2 build ran from its own folder (`DISPLAY16X_SUPPORT_DIRECTORY`), and the checksum of the 0.1.0 copy's settings file was recorded before. Other display utilities were not inspected and may have been running.

| # | Check | Result |
| --- | --- | --- |
| 1 | Empty transaction | Completed with status 0 and **no reconfiguration callback**. A transaction that sets every origin to its current value is silent too |
| 2 | Move the LG 100 points and back | macOS kept the exact place asked for. The LG got "moved, desktop shape", the Lenovo "desktop shape" alone |
| 3 | LG main and back | Shifting every origin is the whole change. The new main display got "moved, set main, desktop shape", the old one "moved, desktop shape". The online list puts the main display first |
| 4 | Mirror and back | The LG got "moved, mode, mirror, desktop shape" and then **reported the Lenovo's frame and size** (3200 × 1800 at 0,0). Ending the mirror ("moved, mode, unmirror") gave it back its own mode, its 270° and its place |
| 5 | Disconnect and back, private call | The LG left the online list ("removed, disabled"). While it was out **the Lenovo ran at 1920 × 1080**, as at the 11:39 wake. Reconnect brought the LG back under the same display ID, mode, rotation and place |
| 6 | Main display from the CLI, unanswered | Reverted on its own at 15 seconds |
| 7 | Placement right:start, Keep, revert | Placed at 3200,0 exactly, kept, and put back by `display16x revert` |
| 8 | Mirroring with the countdown | **Failed at first**: the revert was refused as an overlap and the LG stayed mirrored until it was put back by hand. Fixed (the saved size is used for a display that stops mirroring). The rerun reverted in one transaction |
| 9 | Disconnect, unanswered, then quit | Back 1.35 seconds after the countdown ended, under tag 2. Disconnected again and the app quit: reconnected at quit, nothing left in the recovery store |
| 10 | The panel | Make Main, a canvas drag (snapped to 3200,−248, bottoms aligned), Mirror and Disconnect, each with Revert in the Keep window: all four worked, confirmed by the owner and the log |
| 11 | Saved layout across a long sleep | **Not run, deferred by the owner** to a later version, which verifies it with its improvements. The displays did sleep for about an hour afterwards (to 14:11) with the v0.2 build running and protection off: the LG left and returned in 3.5 seconds and the app wrote nothing |
| 12 | Moving the LG in System Settings with protection on | Put back after each of the owner's two drags, with the notice |
| 13 | A preset from ⌃⌥1 | The menu bar moved back to the Lenovo. The press arrived without the Accessibility permission |
| 14 | Idle budget | 0.02 s of CPU in 610 seconds (0.003% of a core), 1 idle wakeup, 3 threads, a 47 MB footprint after a heavy session (50 MB at the start of the ten minutes). Within the budget; memory is 6 MB above v0.1's measurement |
| 15 | Lid, with the built-in panel turned off automatically | The lid event arrived, macOS added the panel 1.3 seconds later and the app turned it off 1.2 seconds after that. **Turning the panel back on with the lid closed lit it up**: macOS made it the main display, ran the Lenovo at 1920 × 1080 and the LG at 2560 × 2880 unrotated. Opening and closing the lid put everything back. Fixed: a built-in panel now comes back only once the lid is open |

Still to do, for a later version: check 11 as planned above (layout protection on, a display sleep of ten minutes or more, the LG leaving and returning, and nothing written), the offer of decision 13 seen on screen, and turning the built-in panel back on when the last external display goes away. Afterwards the owner's 0.1.0 copy was started again from the main checkout as before; its settings and recovery files were unchanged.

Also seen: `AppleClamshellCausesSleep` read 1 at 11:12 and 12:17 and 0 from about 12:50, after the built-in panel had been turned off, and stayed 0 after it came back. Whether the app caused it is not known.

## 23 November 2026 · How a display is connected · Apple M5 Pro (Mac17,9) · macOS 27.2.1 (26B131)

Read-only and unattended, for the interface pass: the card of a display says "External" today and should name the connection. Only the I/O registry and the window server's display list were read. Nothing was sent to a monitor, no DDC and no I2C, and the owner's Display 16X 0.1.0 kept running throughout. Other display utilities were not inspected.

The probe is [`spikes/connection-probe.swift`](../spikes/connection-probe.swift). It prints no serial number, UUID or EDID. Its output with the displays awake:

```text
Ports macOS lists:
  USB-C 1: active transports: none
  USB-C 2: active transports: none
  USB-C 3: active transports: CC, USB2, DisplayPort
  MagSafe 3 1: active transports: CC
  HDMI 1: active transports: DisplayPort
  SD Card 1: active transports: none

DisplayPort links macOS reports: 2
  LEN P32p-20: port HDMI, the Mac's own port HDMI 1 (port built in: yes), transport DisplayPort, tunneled no, 4 lanes at 8.1 Gbps (HBR3), through a converter
  LG SDQHD: port USB-C, the Mac's own port USB-C 3 (port built in: yes), transport DisplayPort, tunneled no, 4 lanes at 8.1 Gbps (HBR3)

Displays: 2
  LEN P32p-20: matched by vendor, model and serial number to the HDMI port
  LG SDQHD: matched by vendor, model and serial number to the USB-C port
```

What this shows:

- **macOS describes each of the Mac's ports and each display link in the I/O registry.** A port entry (class `IOPort`) carries its type in words ("USB-C", "HDMI", "MagSafe 3", "SD Card") and what is active on it. Each display has a link entry (class `IOPortTransportStateDisplayPort`) under its port, with the type of the Mac's own port, whether the picture is tunneled, the lane count and rate, and the monitor's EDID. Reading them needs no private symbol, only public IOKit calls. The names are undocumented.
- **The EDID in the link entry pairs it with a display.** Both monitors matched on vendor, model and serial number, the same way the DDC channel is paired.
- **Every external display is a DisplayPort link as far as the Mac is concerned,** the one on the HDMI port too: the Mac drives its HDMI port through a converter, and the link entry says so. So "DisplayPort" tells two connections apart no better than "external" does. The port does.
- **The Lenovo is on the Mac's HDMI port. The LG is on a USB-C port that carries DisplayPort, not tunneled.** These notes call the LG's connection DisplayPort throughout, which is the signal. The port also has USB 2 active. That fits a USB-C cable to the monitor's own USB-C input as well as a DisplayPort cable with a small USB device in its plug, and nothing macOS reports tells the two apart.
- **macOS does not know the far end of the cable.** A USB-C port can lead to a monitor's USB-C input, a DisplayPort plug, or an adapter to HDMI. A converter in the path is visible, as it is inside the Mac's own HDMI port, but not what it converts to.

With the displays asleep at 16:26 (both reported asleep, the Mac idle for 650 seconds), the same read gave:

```text
  LEN P32p-20: port HDMI, the Mac's own port HDMI 1 (port built in: yes), transport DisplayPort, tunneled no, 4 lanes at 8.1 Gbps (HBR3), through a converter
  LG SDQHD: port USB-C, the Mac's own port USB-C 3 (port built in: yes), transport DisplayPort, tunneled no, 4 lanes at No Link
```

- **The link entries stay through a display sleep,** still marked active and still holding the EDID, so the connection stays known. The LG's direct link is down while it sleeps ("No Link"). The Lenovo's is not, because that link ends at the converter inside the Mac.

The app's own read, through the same inventory the running app uses and without a DDC query, named the Lenovo "HDMI" and the LG "USB-C" on this Mac (a read-only unit test, `ConnectionMatcherTests.inventory`).

Not checked, because nothing on this desk offers it or the Mac was unattended:

- A Thunderbolt dock or a Thunderbolt display. The link entry has a "Tunneled" flag, and the app reads a tunneled link as Thunderbolt. That reading has not met one.
- An adapter (USB-C to HDMI, a hub), a DisplayLink adapter, AirPlay, Sidecar, a virtual display. The last four should have no link entry and read as not known.
- Two units of one model on different kinds of port. The app leaves both as not known, by a unit test only.
- Another Mac and another macOS release. Since which release the registry has these entries is not known. On the CI runner, a virtual Mac, there is nothing to read and the connection is not known.
- Which cable the LG is on. The owner can say.
- How a value is known (read back, sent, not known), the other fact built in the same change, has run in unit tests only. Nothing on the desk ran this build.

## 23 November 2026 · Interface pass, checked off screen · Apple M5 Pro (Mac17,9) · macOS 27.2.1 (26B131)

The rebuilt interface was checked from the render harness, in the test process, on made-up monitors. The app was not started, no display was touched, and the copy in daily use was left alone. Nothing below has been seen on screen yet.

### What VoiceOver is given

Every one of the 47 surfaces and states is drawn with a text file of its accessibility tree, and the render run fails when a control has no name or a slider no value. It passes. A bar speaks its value in words ("53 percent"), each text-size stop is a button named by its size ("3200 by 1800"), the one in use is marked selected, and the pop-ups carry a name and their choice. Not checked, because it needs VoiceOver running: that pressing a pop-up opens its menu, and the order in which the panel is read.

### Contrast

`SkinContrastTests` measures the skin's color pairs in light, dark and both increased-contrast looks, with the luminance formula of the Web Content Accessibility Guidelines. Text on cards, the canvas, quiet buttons and banners is at 7 to 1 or more, secondary text and the accent as text at 4.5 to 1 or more, and with Increase Contrast 10 and 7. One value was short and was changed: the bed of a bar in the dark increased-contrast look.

**macOS hands out its increased-contrast appearance only while Increase Contrast is on in System Settings.** Asked for by name with the setting off, it returns the ordinary appearance. So the harness draws the two contrast looks by telling the skin to answer with its increased-contrast colors, and the system's own controls in those pictures (switches, the settings tabs) stay ordinary. The pictures called "increased contrast" before this was found were the ordinary looks.

### Motion and transparency

The only animations are the countdown ring and line, one linear animation each, started when they appear. With Reduce Motion they stay full and the digits tell the time. The indicator and the notices are opaque with Reduce Transparency. The panel paints an opaque canvas in every case. Read from the code and not seen on screen: a picture cannot show either setting.

### How long the panel takes to build

`DISPLAY16X_MEASURE=1 swift test --filter PanelSpeed` builds the panel's two models, its views and their first layout forty times on the sample desk, off screen.

| Page | Median | Worst |
| --- | --- | --- |
| Displays, two cards and three scenes | 18 to 21 ms | 33 ms |
| One display's page | 25 to 30 ms | 46 ms |
| Arrange | 18 ms | 36 ms |

Debug and release builds gave the same within a few milliseconds. This is a stand-in for the budget "the panel opens in under 100 ms warm": it leaves out the popover itself and the monitors' own answers, and it is the M5 Pro and not the MacBook Air M1 the budget is written for.

### On screen, 19:50 to 19:55 (the owner at the desk)

A build packaged from this branch ran in place of the copy in daily use, with a settings folder of its own, on the Lenovo P32p-20 and the LG SDQHD. At start it read both monitors and wrote nothing ("still has its brightness, contrast, volume" for both). The owner opened the panel five times.

| Budget | Target | Measured here |
| --- | --- | --- |
| Panel open, the first time | None set | 133 ms |
| Panel open, warm | Under 100 ms | 85, 88, 76 and 76 ms |
| Memory, panel closed, after four opens | At most 50 MiB | 40 MB physical footprint, peak 44 MB |
| Idle CPU and wakeups over 10 minutes | 0.1% of a core, no recurring wakeups | Not measured. The run ended after four minutes, see below |

The open time is from the click to the popover being shown and key. It is inside the budget on the M5 Pro. The budget is written for a MacBook Air M1, where it is likely to be over: the panel's own content builds in about 20 ms off screen, so most of the time is elsewhere, and the verbose log now splits it into models, views, bringing the app forward and showing the popover to find out where.

**The run ended at 19:55 when an uninstaller removed the copy in daily use.** The owner removed the 0.1.0 bundle from the main checkout's `dist/` folder and the app's standard settings folder with an uninstaller, and it quit the build under test, which has the same bundle identifier. The ten-minute idle measurement had run for one minute. The build under test in this worktree's own `dist/` and its settings folder were not touched.

### The copy in daily use from 19:59 on: this branch at `897c40f`

The owner removed the 0.1.0 copy and asked for the latest build to run in its place. The planning thread packaged this branch's tip (version 0.1.0, build 116, signed ad hoc) and started it at 19:59:31 from the main checkout's `dist/` with `--verbose` and the standard settings location, which was created fresh. Everything below was read from outside: the process was sampled with `top`, `ps` and `footprint`, and its log was read with `display16x get log`.

- **Start:** both monitors connected, DDC working on both, values read and nothing written.
- **Accessibility:** not granted at start, granted by the owner by 20:19.

| Budget | Target | Measured here (M5 Pro) |
| --- | --- | --- |
| Panel open, warm | Under 100 ms | 81, 109, 103, 102, 96 and 77 ms |
| Memory, panel closed, after about ten opens | At most 50 MiB | 52 MB physical footprint, peak 59 MB. 57 MB straight after a burst of opens |
| Idle CPU and wakeups over 10 minutes | 0.1% of a core, no recurring wakeups | See below |

**Two budgets are at or over the line on the fastest Mac we have.** The log splits an open: building the two models takes 33 to 51 ms, building the views 0, bringing the app forward 2 to 5, and showing the popover 36 to 61. Off screen, on made-up monitors, models and views together took about 20 ms, so on real displays it is the models that cost: what they ask the system for on every open has not been profiled yet. Memory was 41 MB for v0.1 and 47 MB for v0.2 by the same measure.

**Idle.** The first ten-minute window (20:04:31 to 20:14:32) had four panel opens in it and was thrown away: 3.30 s of CPU and 23 idle wakeups with those opens. The second window, 20:14:33 to 20:24:34, had none: **0.20 s of CPU in 601 s, which is 0.033% of a core, and no idle wakeup.** The owner was typing in that time and the key capture was on, which v0.1's figure of 0.02 s did not have. Memory at the end: 53 MB, peak 59 MB.

**Where an open's time went, and the one thing changed.** The calls behind one build of the panel's models were timed on these two monitors, read-only:

| Call | Time |
| --- | --- |
| Whether a display can be rotated | 21.7 ms for the Lenovo, 4.3 ms for the LG |
| The list of modes | 2.2 ms and 0.6 ms |
| The current mode, the frame, the main display, mirroring, the lid | 0.05 ms or less each |
| Listing the connected displays (not part of an open; it runs when the set of displays changes) | 17.5 ms |

The rotation question was asked for every display on every build, and only a display's page shows the answer. It is now asked once, when that page opens. That takes about 26 ms out of the 33 to 51 ms the models took. **Not measured on screen yet:** the copy in daily use is `897c40f`, which does not have this change.

**The owner's word on the budgets (23 November, in the interface session):** no over-engineering. Where a budget is still missed after a quick look, it may be extended by 10%. Memory with the panel closed is the one that needs it: 53 MB against 50 MiB.

### Still to be measured with the app running

A development build in place of the copy in daily use: the panel's open time on screen, memory with the panel closed (at most 50 MiB), and wakeups when idle. And by eye: the popover's arrow against the skin's canvas, real blur, the feel of the bars, full keyboard access through the panel, VoiceOver, and Increase Contrast, Reduce Motion and Reduce Transparency switched on in System Settings.

## 23 November 2026 · v0.3 Advanced scaling spikes · Apple M5 Pro (Mac17,9) · macOS 27.2.1 (26B131)

**Proven with the owner at the desk, 21:44 to 21:51** (see [the writing checks](#the-writing-checks-with-the-owner-2144-to-2151)): macOS 27 reads an override file from `/Library/Displays` when the display reconnects, the app's own disconnect and reconnect is enough, the 8- and 12-byte size entries work and the 16-byte one is ignored, the app's marker key does no harm, removal brings the list back exactly, and a virtual screen can be created and removed by a running process. **Still unproven:** why the panel's full grid as HiDPI was left out, whether a replug or a logout activates as well, the keys other than `scale-resolutions`, an override for a model macOS has its own file for, and the virtual screen's HiDPI on a mirror. The read-only parts were read without writing anything.

Same Mac and monitors as above: the Lenovo P32p-20 on the Mac's HDMI port (main display) and the LG SDQHD on a USB-C port, rotated 270°. The owner's Display 16X 0.2.0 and other display utilities were running and were left alone. The probes print no serial number, UUID or manufacture date. Vendor and product numbers below name a model, not a unit.

### Override files: what is on this Mac (read-only, `spikes/override-probe.swift`)

- **The system's own overrides are in `/System/Library/Displays/Contents/Resources/Overrides`**: 37 vendor folders and 441 product files, owned by root, on the sealed system volume. A file is named `DisplayVendorID-<vendor in hex>/DisplayProductID-<product in hex>`, with no leading zeros, and has no extension. Next to them are a few `.icns`, `.tiff` and `.mtdd` files. Two product files are not dictionaries.
- **Neither test monitor has a system override.** The Lenovo is vendor 30ae, product 62a2. The LG is vendor 1e6d, product 5bf6. macOS ships 22 files for LG's vendor number, none for this model.
- **`/Library/Displays` does not exist** on this Mac, and neither does a folder under the user's own Library. An install has to create the whole chain `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-1e6d`. Whether macOS 27 reads `/Library` at all is the first thing the writing spike answers. A folder in the user's Library was not looked for any further: nothing on this Mac or in the system's files suggests it is read.
- **What the system's files carry.** By how many of the 441 product files use them: vendor and product (373 and 371), product name (290), `scale-resolutions` (251), color and gamma keys (about 179), `DisplayIsTV` (37), `target-default-ppmm` (33), `IODisplayEDID` (27), `edid-patches` (18), `DisplayPixelDimensions` (6), `default-resolution` (6). The rest are rarer.
- **A `scale-resolutions` entry is a small block of big-endian 32-bit words**: width, height, then flags. Seen: 1,860 entries of 12 bytes (flags 1), 639 of 16 bytes (flags 1 with `0x00200000`, or flags 9 with `0x00a00000`), 341 of 8 bytes (width and height only), 63 of 9 bytes and 4 that are not data at all. On a built-in "Color LCD" whose `DisplayPixelDimensions` is 2304 × 1440, the 16-byte entries run up to 2560 × 1440 and 2880 × 1800, larger than the panel. So the width and height of a 16-byte entry are the backing store of a HiDPI size, twice its points. That is the shape the generator uses, and the one the writing spike tests.
- `DisplayPixelDimensions` is 8 bytes, width and height of the panel. `default-resolution` is 12 bytes, for example 1024, 768, then `0x004bffff`. The meaning of that last word is not known.

### What the window server already offers (read-only)

| | Lenovo P32p-20 | LG SDQHD |
| --- | --- | --- |
| Panel, before rotation | 3840 × 2160 | 2560 × 2880 |
| Modes in the window server's list | 158 | 53 |
| HiDPI sizes | 33, from 400 × 300 to 3840 × 2160 | 23, from 300 × 400 to 2304 × 2048 |
| Largest HiDPI size | 3840 × 2160, backed by 7680 × 4320 | 2304 × 2048, backed by 4608 × 4096 |
| Refresh rates | 30, 50, 60 Hz | 30, 50, 60 Hz |
| Physical size reported | 701 × 391 mm | 520 × 471 mm |

- **The Lenovo already offers its own native grid as a HiDPI size.** An override can only add finer steps between the ones it has, for example 2880 × 1620 or 3456 × 1944.
- **The LG stops at 2304 × 2048 HiDPI**, which is 0.8 of its panel. 2560 × 2880 HiDPI (backing 5120 × 5760) is missing, although the Lenovo's list shows the window server driving a 7680 × 4320 backing store on this Mac. This is the case the feature is for.
- **The list is reported in the rotated frame.** The LG's native-flagged mode reads 2880 × 2560 while the display is turned 270°. An override is written in the panel's own frame, so the app has to turn sizes back before it writes them.
- About a third of each list is sizes off the panel's aspect (14 on the Lenovo, 11 on the LG).

### The virtual display interface (read-only, `spikes/virtual-display-probe.swift`)

- **All four classes resolve**: `CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode`, `CGVirtualDisplaySettings` and `CGVirtualDisplay`, exported by Core Graphics. Their properties are the ones the MIT-licensed DeskPad documents (name, vendor, product and serial, maximum pixels, size in millimetres, a dispatch queue and a termination handler; modes of width, height and refresh rate; settings with modes and a HiDPI flag; the display with its ID and `applySettings:`). macOS 27 adds color primaries and a white point to the descriptor, a rotation, a "reference" flag and a refresh deadline to the settings, and a transfer function to the mode.
- **A newer family resolves too**, exported by SkyLight: `SLVirtualDisplay` with `initWithConfiguration:error:`, `applySettings:error:`, `destroy` and a delegate, and configuration, mode, settings and capability classes. Its class method `capabilities` answers without creating anything: **at most 16384 × 16384 pixels, 0.25 to 4 pixels per point, and no slower than 24 Hz.** That is the window server's limit for "sizes above 8K".
- Neither family was used to create a display. No virtual display was online.

### The writing spikes, as prepared

Each records the state before, does one thing, and puts it back. Each needs the owner at the desk and a yes in the session. All of them ran, see below.

| Step | Command | What it answers |
| --- | --- | --- |
| Show the file | `override-write-probe plan 1e6d 5bf6` | Read-only. The file byte for byte (692 bytes), where it goes and the folders it creates |
| Install | `override-write-probe install 1e6d 5bf6 --yes` | Records the LG's sizes and the folders that exist, then writes the file through the macOS administrator prompt, which the owner answers |
| Activate | `override-write-probe activate 1e6d 5bf6 --yes` | Takes the LG out of use for 3 seconds and back, the way the app's own disconnect works. Whether that is enough for macOS to read the file. A cable replug or a logout are the other ways |
| Check | `override-write-probe check 1e6d 5bf6` | Read-only. Which of the four sizes appeared: 1792 × 2016 HiDPI (a step inside the range the LG has, so a size limit cannot explain its absence), 2304 × 2592 HiDPI, 2560 × 2880 HiDPI, and 1792 × 2016 at low density (the 8-byte shape) |
| Remove | `override-write-probe remove 1e6d 5bf6 --yes` | Deletes the file and only the folders install created, through the administrator prompt. Then activate and check again: the list should be what it was |
| Virtual screen | `virtual-display-write-probe run --yes` | Creates "Display 16X probe", 1920 × 1080 HiDPI at 60 Hz, reads what the window server reports for it, holds 8 seconds, releases it, compares the arrangement with the record and puts the origins back if they moved |

The file the install writes, for the record:

```xml
<dict>
	<key>DisplayProductID</key>      <integer>23542</integer>
	<key>DisplayVendorID</key>       <integer>7789</integer>
	<key>com.16xbrains.macdisplay16x</key>
	<dict><key>format</key><integer>1</integer><key>generator</key><string>Display 16X override-write-probe</string></dict>
	<key>scale-resolutions</key>
	<array>
		<data>AAAOAAAAD8AAAAABACAAAA==</data>   <!-- 3584 × 4032, flags 1, 0x00200000: 1792 × 2016 HiDPI -->
		<data>AAASAAAAFEAAAAABACAAAA==</data>   <!-- 4608 × 5184: 2304 × 2592 HiDPI -->
		<data>AAAUAAAAFoAAAAABACAAAA==</data>   <!-- 5120 × 5760: 2560 × 2880 HiDPI -->
		<data>AAAHAAAAB+A=</data>               <!-- 1792 × 2016, low density -->
	</array>
</dict>
```

Two side effects the owner was told of before saying yes. The virtual screen is a new display to every running display utility, the owner's Display 16X included, which will remember it as a display of its own (vendor 1616) until the retention period removes it. And the activate step is a disconnect and reconnect of the LG, which v0.2's checks showed macOS puts back in its place.

### The writing checks, with the owner (21:44 to 21:51)

The owner was at the desk, said yes in the session, and typed the administrator password into macOS's own dialog three times. The probes ran from this session's scratch folder. The layout was recorded before and was the same after every step: the Lenovo at (0, 0), 3200 × 1800, main; the LG at (−2304, −248), 2304 × 2048.

**Install, first version (21:44:22).** The administrator step took 14 seconds, most of it the owner typing. It created `/Library/Displays` and the four folders below it, owned by root, and the 692-byte file, root-owned, mode 644, with the SHA-256 the plan printed. Read straight after: the LG's list unchanged, 42 sizes. **macOS does not read an override until the display connects.**

**Activate (21:44:52).** The probe took the LG out of use for 3 seconds and brought it back, the same call the app's disconnect uses. Back online in 6 seconds, in the same place. **That was enough: macOS read the file.** The list grew to 44:

| Entry | Shape | Result |
| --- | --- | --- |
| 3584 × 4032, flags 1, `0x00200000`, for 1792 × 2016 HiDPI | 16 bytes | not listed |
| 4608 × 5184, the same, for 2304 × 2592 HiDPI | 16 bytes | not listed |
| 5120 × 5760, the same, for 2560 × 2880 HiDPI | 16 bytes | not listed |
| 1792 × 2016 | 8 bytes | listed, as 2016 × 1792 (turned with the rotation), and also as 1008 × 896 HiDPI |

**Replace with a second version (21:48:02), activate, check.** The owner agreed to one more round to tell the shapes apart. The list grew to 46:

| Entry | Shape | Result |
| --- | --- | --- |
| 3584 × 4032, for 1792 × 2016 HiDPI | 8 bytes | listed, as 2016 × 1792 HiDPI |
| 5120 × 5760, for 2560 × 2880 HiDPI | 8 bytes | not listed |
| 3328 × 3744, flags 1, for 1664 × 1872 HiDPI | 12 bytes | listed, as 1872 × 1664 HiDPI |
| 3072 × 3456, flags 9, `0x00a00000`, for 1536 × 1728 HiDPI | 16 bytes | not listed |
| 1792 × 2016 | 8 bytes | listed, and its HiDPI half again |

**Remove (21:48:36), activate, check.** One administrator step deleted the file and the five folders. `/Library/Displays` no longer exists. After the reconnect the LG listed the same 42 sizes as before the install, with nothing new and nothing gone, and its mode stayed 2304 × 2048 HiDPI throughout.

What this shows:

- **An entry is a backing-store size in the panel's own frame**, and the window server turns it with the rotation. The 8-byte shape offers the size at low density when the panel can show it, and its half as HiDPI. The 12-byte shape with flags 1 gave its half as HiDPI, and the size itself is larger than the panel, so whether it would also offer low density is not shown. **The 16-byte shapes are ignored on macOS 27**, with either flag, although 639 of the system's own entries have that shape.
- **The panel's full grid as HiDPI (backing 5120 × 5760) was left out in both versions**, with a shape that works. The Lenovo's list shows a 7680 × 4320 backing store on this Mac, so it is not a limit of the Mac as a whole. The reason is not known: a limit for this display's pipe, for its height, or for a factor of its panel. **The app cannot predict which sizes macOS takes**, so after an install it reads the list and says which sizes appeared.
- **The marker key did no harm.** A file carrying `com.16xbrains.macdisplay16x` was read like any other.
- **The app's own disconnect and reconnect activates an override**, about 6 seconds per display, with the display back in its place. A cable replug and a logout were not tried. The main display cannot be taken out of use that way, so for it the app has to ask for a replug or a logout.
- **The owner's Display 16X 0.2.0 saw three disconnects and reconnects of the LG**, read its DDC values after each and wrote nothing ("still has its brightness, contrast, volume, mute").

**Virtual screen (21:50:16, and again at 21:50:59).**

- `initWithDescriptor:` and `applySettings:` both succeeded in under 0.2 seconds. The screen came online as an external display: not built in, not main, rotation 0, with the made-up vendor 1616 and product 316 it was given, in the requested mode, 1920 × 1080 points backed by 3840 × 2160 pixels at 60 Hz.
- **macOS made a list of 24 modes from the one mode given**, at both densities, from 400 × 300 HiDPI to 3840 × 2160.
- **macOS put the screen to the left of the main display and moved the LG out of its way**, from −2304 to −4224, in the first run.
- **The display ID changes every time a screen is created**: 8, then 9. The owner's running 0.2.0 matched both to the same record (#3, "Display 16X probe") by vendor, product and serial number, so the app's tag holds across them.
- **macOS remembers a layout for a set of displays that includes a virtual screen.** In the first run the probe put the LG back while the screen was still there, and the screen moved to −4224. In the second run the screen appeared at −4224 straight away and the LG stayed in its recorded place.
- **Releasing the object removes the screen while the process keeps running**, within 3 seconds, and the arrangement went back to the record by itself. The termination handler was not called for a release made by the owner of the screen. In the first run the probe still held a second reference by mistake, so the screen stayed until the process ended, 3 seconds later, and then went too. **A screen never outlives the process that made it.**
- The owner's 0.2.0 now remembers record #3 for the probe's screen. It reads nothing from it and writes nothing to it.
- **macOS made a color profile for the screen and kept it** after the screen was gone: `/Library/ColorSync/Profiles/Displays/Display 16X probe-<system UUID>.icc`, 3,384 bytes, owned by root, written at 21:50 when the screen first appeared. One profile for both creations. The folder is root's, so removing the profile needs administrator rights. **It is still on the owner's Mac**, the only thing the checks left behind. The Lenovo's profile in the same folder was rewritten at 21:51 (524 bytes). Its size before was not recorded, so whether the check changed it is not known. macOS also updated its own saved display configurations (`/Library/Preferences/com.apple.windowserver.displays.plist` and one under `~/Library/Preferences/ByHost`) at 21:51, as it does for any new set of displays.

Not checked: a virtual screen mirrored onto a panel (stage 5, mirror-based HiDPI), sleep and wake with a screen present, a screen of more than 8K, and the `SLVirtualDisplay` family.


### Where v0.3 stands at the end of 23 November

Built at unit-test level on top of what the writing checks proved: overrides staged, previewed, written in one administrator step through `osascript`, activated by the app's own reconnect, read back size by size, undone and removed, the list of what was written kept in the app's folder and every file found by its marker, also from the command line without the app; virtual screens saved, made through the `CGVirtualDisplay` classes, restored at launch and after wake, linked to a display, discarded with their color profile; mirror-based HiDPI behind its own switch. 440 unit tests pass. **The app itself has not written an override or made a virtual screen on hardware yet**: only the probes above did.

Left on the owner's Mac by the checks: the color profile `/Library/ColorSync/Profiles/Displays/Display 16X probe-<system UUID>.icc` (removing it needs an administrator password: `sudo rm` on that file), and record #3 "Display 16X probe" in the 0.2.0 copy's settings, which costs nothing and goes with the retention period or Forget.

#### The checks for a later round, in order

Each needs the owner at the desk, a development build or the build in daily use with this branch, and the layout recorded first.

1. **The app's own override, end to end, on the LG.** Turn on Scaling through overrides, Add Fine Steps on the LG's page, open the preview, Write as Administrator, and let the app reconnect the LG. Check that the page then shows each size as offered or left out, that the list matches the 23 November check (1792 × 2016 and 1664 × 1872 HiDPI offered, 2560 × 2880 HiDPI left out), and that a new size works from the strip with Keep and Revert. Then Remove… and reconnect: 42 sizes, as before.
2. **Removal without the app.** Write an override, quit the app, run `display16x override list` and `display16x override delete all --confirm`, and check that the folders the app made are gone.
3. **The main display.** An override for the Lenovo (for example 2880 × 1620 HiDPI): the app must not reconnect it. Replug the HDMI cable and check that macOS reads the file then. Remove it.
4. **A virtual screen from the app.** Create, connect, disconnect, connect again (a new display ID, the same tag), with the arrangement put back after it appears. Check that the card shows it as a display, that the policy refuses to take the Lenovo out while only the screen and the Lenovo are in use, and that Discard removes the profile macOS made, through the administrator prompt.
5. **A virtual screen across sleep.** A display sleep of ten minutes or more and a full system sleep with a screen connected: whether macOS ends it, and whether the app makes it again after the wake.
6. **Restore at launch.** Quit and start the app with a screen that was connected.
7. **Mirror-based HiDPI on the LG.** A matched screen, 2880 × 2560 HiDPI, linked with mirroring: how the picture looks, the GPU's load and the app's own CPU with it running (Activity Monitor's GPU history, or `sudo powermetrics --samplers gpu_power`), then the switch off and the LG back in its own mode.
8. **The other override keys.** Panel size, the size macOS picks first, the name macOS shows and the television flag were never written on hardware. Their effect is not known.
9. **Idle cost** with a virtual screen connected and with none, against the PRD's budget.
10. **A full reset with the system's settings.** Not on the owner's Mac in daily use: it makes macOS forget every arrangement it saved. A spare Mac or a test account, with the put-back step afterwards.

## 24 November 2026 · v0.4 HDR and color spikes · Apple M5 Pro (Mac17,9) · macOS 27.2.1 (26B131)

The Lenovo P32p-20 on HDMI and the LG SDQHD on USB-C, rotated 270°. The MacBook's lid is closed, so its XDR panel is out of use. Run at 01:20, with the owner's copy of Display 16X running and other display utilities left as they were.

**What stays unproven:** choosing a link color mode and switching dithering (no interface with a known shape), everything about the built-in XDR panel beyond what the registry says (the lid is closed), reference presets (no Apple display), and anything the app itself does: the writing checks below were run by the probe, not by the app.

### What macOS reports (read-only, `spikes/hdr-color-probe.swift`)

| | Lenovo P32p-20 (HDMI) | LG SDQHD (USB-C) |
| --- | --- | --- |
| HDR in the window server | not supported | supported, off |
| HDR in System Settings' model (`MPDisplay`) | no HDR modes | HDR modes, not preferred |
| Headroom (EDR): now, potential, reference | 1.0, 1.0, 0.0 | 1.0, 1.0, 0.0 |
| EDID | nothing about HDR | PQ, static metadata type 1, BT.2020 RGB and YCC, no HLG. Peak 295 nits, minimum 0.3 |
| Color space in use | wide gamut | not wide gamut |
| Factory profiles | two: "HDMI HD" (default, the monitor's own) and "HDMI SD" (`SD 170M-A`, a system file) | one: the monitor's own |
| Custom profile | none | none |
| Link color modes in the registry | 20 | 18 |
| Dithering | on | on |
| Reference presets | none | none |

- **HDR is offered by the window server and by the model System Settings uses, and both agree.** The switch System Settings shows is `setPreferHDRModes:` on `MPDisplay` in MonitorPanel. The Objective-C runtime gives its shape (`v20@0:8B16`, one Boolean, no result), so it can be called without guessing. SkyLight also exports `SLSDisplaySetHDRModeEnabled`, whose arguments no permitted reference documents. The app uses the MonitorPanel switch and reads back through both.
- **A reference headroom of 0 means "not reported".** Both monitors give 1.0 for the current and potential headroom with HDR off. The value with HDR on is part of the writing check.
- **Every link color mode the monitor and the Mac agree on is listed in the I/O registry**, under the framebuffer (`IOMobileFramebufferShim`) as `ColorElements`: an ID, depth (8, 10 or 12 bits), pixel encoding (0 is RGB; 2, 3 and 6 are YCbCr variants whose chroma no permitted reference names), range (full or limited), transfer function (0 for SDR, 2 for PQ, which only appears with HDR-capable colorimetry) and colorimetry. Each timing lists the IDs it can carry (`ColorModes`). The LG offers 10-bit RGB with PQ at its own timing. The Lenovo at 3840 × 2160 over HDMI lists 8-bit RGB and no 10-bit RGB: its 10- and 12-bit entries at that timing are YCbCr. At 1920 × 1080 it lists 10-bit RGB. Entries marked "virtual" have no score and are not offered at the preferred timing.
- **Which link color mode is in use is not in the registry**, and choosing one is not possible with a documented shape. SkyLight exports `SLSGetDisplayOutputModeCount`, `SLSGetDisplayOutputModeLinkDescriptions`, `SLSConfigureDisplayOutputMode` and `SLSSetDisplayOutputMode`, with no Objective-C wrapper and no permitted reference for their arguments. They were looked up and not called.
- **Every window server mode reports a 30-bit pixel encoding** (`--RRRRRRRRRRGGGGGGGGGGBBBBBBBBBB`) on both monitors, while the depth field reads 8. The public interface reports 8 bits for every mode (v0.1 notes). Depth in the mode list therefore says nothing about the link.
- **Dithering is reported as on for all five framebuffers**, the three without a display included. Reading it is public IOKit. CoreDisplay exports `CGXDisplayGetDither` and `CGXDisplaySetDither`, again with no documented arguments.
- **The closed built-in panel's headroom is in the registry:** `EDRPotentialHeadroom` reads 16.0 (16.16 fixed point) on its backlight entries. That is the only fact about the XDR panel this desk gives with the lid closed.
- **Reference presets** are offered through `MPDisplay` (`hasPresets`, `presets`, `activePreset`, `setActivePreset:`, all typed) and SkyLight's preset functions. Neither monitor has any. They exist on Apple's own displays and XDR panels.
- **Night Shift and True Tone** are read through CoreBrightness's `CBBlueLightClient` and `CBTrueToneClient`, both typed. Night Shift was off, with no schedule (mode 0); the hours of a custom schedule are kept even so. Of the status struct's first two flags, the second is "on now": it is the one `setEnabled:` changes. The first stayed set throughout and its meaning is not known. True Tone reads supported and enabled, and not available, because no display that has it is in use.
- **Installed profiles:** 14 in the system folder (sRGB, Display P3, ITU-709, ITU-2020, AdobeRGB and the generic ones), 7 for all users, 4 in the displays folder (the monitors' own and the one v0.3's probe left), none for this user.
- No custom profile is assigned anywhere, so the gamma-table backend still reports itself safe.

### The writing checks, with the owner (01:27 to 01:29)

`spikes/hdr-color-write-probe.swift`. Each check prints the state, makes one change, logs every reconfiguration callback, prints the state again, holds for 10 seconds, puts back what it recorded and checks it. Ctrl-C puts it back too.

**HDR on the LG and off again** (`hdr 5 --yes`), through the System Settings switch:

| | Before | HDR on | After |
| --- | --- | --- | --- |
| Window server and System Settings | off, off | on, on | off, off |
| Headroom now, potential, reference | 1.0, 1.0, 0.0 | 1.2, 2.95, 0.0 | 1.0, 1.0, 0.0 |
| Mode | 2304 × 2048 HiDPI, 60 Hz | the same | the same |
| Color table | 1024 entries, plain ramp | plain ramp | plain ramp |
| Color space | unnamed, not extended | unchanged | unchanged |

- **The switch returns after about 0.75 seconds and the reconfiguration happens inside the call**: a "begin" and an empty end for both displays, 0.7 seconds after it was sent, with no add, remove, mode or move flag. The LG did not leave the system, and the Lenovo got the same pair of callbacks though nothing changed for it.
- **The owner saw the LG go black briefly** at each switch, **and the picture looked washed out** while HDR was on. macOS shows ordinary windows at the SDR level inside the HDR range, so this is expected, and it is why a switch to HDR needs Keep and Revert in the interface.
- **The potential headroom is the monitor's peak over the reference white**: 2.95 is the 295 nits of its EDID over 100. The current headroom rose only to 1.2, because nothing on screen asked for more.
- **The color table stayed a plain ramp in HDR.** macOS does not put its own table in place for HDR on this monitor.
- Back as it was: yes.

**The sRGB profile on the LG and back** (`profile 5 --yes`), through public ColorSync:

- Assigned to the LG's factory profile ID "1". **It took effect at once, with no reconfiguration callback**: the profile in use read "sRGB IEC61966-2.1" a second later. Passing `kCFNull` for the same ID put the factory profile back, and the custom profile list was empty again.
- The color table stayed a plain ramp with either profile.
- **While the custom profile was assigned, the core's color table check would have called table writes unsafe for every display** (`GammaTableBackend.safety()` treats any custom profile as unsafe). Choosing a profile through the app therefore switches software dimming off everywhere for as long as the profile is assigned. See the domain log.
- Back as it was: yes.

**Night Shift on and off again** (`nightshift --yes`):

- The first run read the wrong flag as "on now". Night Shift was off, so it sent "off" (no change), then "back on", which turned Night Shift on. It was turned off again by hand at 01:28:50, and the status matched the one before the run. The spike was corrected to read the second flag.
- The corrected run turned Night Shift on and then off, read back each time, with the schedule mode unchanged. `setEnabled:` is a clean switch in both directions.
- Back as it was: yes.

### The adapters, read on the desk (`display16x probe --color`, 02:20)

The hardware report gained a read-only HDR and color section, which sends nothing to a monitor. Through the app's own adapters it read the same as the probe: the LG offers HDR, off; both headrooms 1.0; each monitor's own profile in use; Night Shift off.

- **Each link color mode carries macOS's own ranking**, `Score` in the registry. The app lists offered modes in that order and calls the first "ranked first by macOS", never "in use". For the LG that is 10-bit RGB, full range, SDR. For the Lenovo at 3840 × 2160 over HDMI it is 12-bit YCbCr, limited range, ahead of 8-bit RGB.
- **The Lenovo's link offers 3840 × 2160 at 23.98, 24 and 25 Hz**, which its mode list (30, 50, 60 Hz) leaves out. These are the "connection-only rates". The timings are listed as made up by macOS. Choosing one is not possible yet.
- **`ColorSyncProfileCopyHeader` gives each 32-bit field in the Mac's byte order**: the class of the system's sRGB profile reads "rtnm" and its space " BGR", where the file holds "mntr" and "RGB ". The app accepts both. 9 of the 14 system profiles are RGB display or color space profiles.

**Prepared and not run, by the owner's choice: a virtual screen with HDR modes** (`spikes/virtual-hdr-write-probe.swift`). `CGVirtualDisplayMode` takes a transfer function per mode (`initWithWidth:height:refreshRate:transferFunction:`, typed). The probe makes the v0.3 probe's screen again, with the same identity so macOS has no reason to keep a new color profile, with one mode at transfer function 0 and one at 2 (the PQ code of CTA-861, which the framebuffer registry also uses), and reads whether macOS then offers HDR for it. Carried forward: until it runs, which transfer function codes macOS accepts is not known.

**A link color mode change was not prepared**: no interface with a known shape can choose one, and a guessed call on the owner's monitor is not a check worth its risk. Reference presets need an Apple display.

### The built-in XDR panel, read through the running app (24 November, 12:05, lid open)

At midday the MacBook's lid was open and the external monitors were unplugged, so the built-in panel was in use for the first time in this milestone. Read-only, through the v0.4 build as the running copy and `display16x probe --color`:

- **No HDR switch.** System Settings' model reports no HDR modes for it, and the window server none either. It shows HDR content at all times: potential headroom **16.0**, now 1.0 with nothing bright on screen. The app now says "Always on" for such a panel instead of "offers no HDR modes".
- **Reference presets: 51 listed, 11 with names**: Apple XDR Display (P3-1600 nits), in use; Apple Display (P3-600 nits); HDR Video (P3-ST 2084); HDTV Video (BT.709-BT.1886); NTSC Video (BT.601 SMPTE-C); PAL & SECAM Video (BT.601 EBU); Digital Cinema (P3-DCI); Digital Cinema (P3-D65); Design & Print (P3-D50); Photography (P3-D65); Internet & Web (sRGB). The other 40 are empty slots for custom presets: macOS names them "Preset #11" to "Preset #50", and their dictionary holds only `PresetValid`, set to 0. The app leaves out every preset marked not valid.
- **Profile** "Color LCD", the panel's own. **True Tone** on and in use. **Night Shift** off.
- **No link details**: the built-in panel's framebuffer lists no color modes, so the app says macOS reports none for it.

### The crash at the first start, and why nothing caught it

The first v0.4 build crashed a second after it started as the owner's running copy, at 12:01:46 on 24 November: `EXC_BAD_ACCESS` in `objc_release`, while the main queue emptied an autorelease pool after a Swift task. The object System Settings' display model (`MPDisplay`) hands back from its initializer was released once more than it was retained. It was never released, and was fixed within minutes. Nothing caught it before, for these reasons:

- **The unit tests run the color service on a fake system.** The one real path into `MPDisplay` was never called from a test. The adapter tests read profile files only.
- **The probes and `display16x probe --color` made the same call and did not crash**, because a command line tool ends before the main thread's autorelease pool is emptied, so the extra release never ran. The app empties a pool after every task on the main queue, and the first such task after start, which reads HDR for each display, crashed.
- **The render harness uses sample adapters**, so the surfaces never touch the real system.
- **CI and the local checks never start the app.** The smoke test checks the bundle and runs the command line tool. A development build refuses to start while the copy in daily use runs, and that copy was running, so the first start of the new app was as the running copy.

What guards it now:

- `ColorAdapterTests` reads HDR and presets through `MPDisplay` five times, each inside an autorelease pool that is emptied, for the main display and for one that does not exist. With either unbalanced version of the call, the test process crashes. It runs on every `swift test`, on CI too.
- The call now gives the initializer a reference of its own and takes the result retained, which is right whether the initializer returns the receiver, another object or nil. `MPDisplay` returned an object even for a display ID that does not exist, so the nil path is not reachable today.

**The cheapest check that would have caught it at the level of the app:** start the packaged app for a few seconds in the smoke test, with a folder of its own and in safe mode, and fail if it is not still running and answering. Safe mode writes nothing, and the HDR read that crashed runs in safe mode too. It belongs in `scripts/smoke-test.sh`, which the release session wrote, so it is proposed and not made here. On a Mac where the copy in daily use runs it has to be skipped, as the smoke test already skips its check for a missing app.

### Where v0.4 stands at the end of 24 November

All five stages are built on the branch, with 495 unit tests passing. The packaged build's version check, archive and signature check, and the comparison of private interfaces under the hardened runtime pass locally. The smoke test and the full hardware report send DDC reads and were left to CI, because the owner's copy was running.

- **Proven on hardware, by probes with the owner at the desk:** HDR on and off on the LG through System Settings' switch, a profile assigned and taken off through ColorSync, Night Shift on and off.
- **Read on hardware through the app's own code** (`display16x probe --color`): HDR state, headroom, factory and custom profiles, the link's color modes in macOS's order, the rates the mode list leaves out, dithering, Night Shift and True Tone.
- **Unit-tested only:** everything the app does by itself with these features.
- **Not working by design until the core changes:** brightness above SDR white, which needs the pipeline to write a value above white (see the domain log).

Checks for a later round, in this order, each with the owner at the desk:

1. Make this build the running copy, then `display16x status` and `display16x probe --color`, and measure the idle budget again for ten minutes with every v0.4 switch off and then with HDR controls on.
2. HDR on the LG from its page: the Keep window on the LG, Keep. Again, and let it revert on its own. Then `display16x hdr on --tag 2 --try` and `display16x keep --tag 2`.
3. Quit during the countdown: HDR goes back off.
4. Night Shift on, Night Shift off in HDR switched on, HDR on: Night Shift goes off. HDR off: it comes back. HDR on again and quit: it comes back.
5. Protect HDR on, HDR switched off in System Settings: put back with a notice.
6. A profile from the LG's page with Keep. The panel says dimming pauses, and `display16x status` says color tables are blocked. Revert.
7. A profile for HDR (`display16x color hdr-profile "ITU-R BT.2020" --tag 2`), then HDR on and off: the profile follows.
8. Protect the profile, change it in System Settings, then any reconfiguration or a wake: put back.
9. Hardware brightness in HDR off: the brightness keys on the LG in HDR leave its backlight alone and the Lenovo still changes.
10. `spikes/virtual-hdr-write-probe.swift run --yes`, carried forward from the spikes, then `display16x virtual create Studio 2560x1440 hdr=on connect`.
11. `spikes/gamma-table-write-probe.swift` on the LG with HDR on and a top value of 1.5: whether a table value above white brightens anything. This decides the request to the core session.
12. A wake of ten minutes or more with HDR protected and the HDR profile set.
13. With an Apple display, or the MacBook's lid open: reference presets, True Tone off in HDR, and what direct XDR upscaling would drive.

## Running the probes

The hardware report is part of the command line tool. It is read-only and needs no app:

```sh
swift run display16x probe                  # add --capabilities or --modes for more, or --color for HDR and color only
```

The standalone probes in [`spikes/`](../spikes):

```sh
swiftc -O spikes/display-probe.swift -o /tmp/display-probe && /tmp/display-probe
swiftc -O spikes/ddc-probe.swift -o /tmp/ddc-probe && /tmp/ddc-probe
swiftc -O spikes/ddc-wake-probe.swift -o /tmp/ddc-wake-probe && /tmp/ddc-wake-probe
swiftc -O spikes/gamma-table-write-probe.swift -o /tmp/gamma-probe && /tmp/gamma-probe
swiftc -O spikes/ddc-write-probe.swift -o /tmp/ddc-write-probe && /tmp/ddc-write-probe "P32p"
swiftc -O spikes/ddc-reliability-probe.swift -o /tmp/ddc-reliability-probe && /tmp/ddc-reliability-probe
swiftc -O spikes/layout-probe.swift -o /tmp/layout-probe && /tmp/layout-probe   # add --watch to follow changes
swiftc -O spikes/connection-probe.swift -o /tmp/connection-probe && /tmp/connection-probe
swiftc -O spikes/override-probe.swift -o /tmp/override-probe && /tmp/override-probe
swiftc -O spikes/virtual-display-probe.swift -o /tmp/virtual-display-probe && /tmp/virtual-display-probe
swiftc -O spikes/override-write-probe.swift -o /tmp/override-write-probe          # writes: see its header
swiftc -O spikes/virtual-display-write-probe.swift -o /tmp/virtual-display-write-probe  # creates a display: see its header
swiftc -O spikes/hdr-color-probe.swift -o /tmp/hdr-color-probe && /tmp/hdr-color-probe
swiftc -O spikes/hdr-color-write-probe.swift -o /tmp/hdr-color-write-probe            # writes: see its header
swiftc -O spikes/virtual-hdr-write-probe.swift -o /tmp/virtual-hdr-write-probe        # creates a display: see its header
```

The first four change nothing unless asked: `gamma-table-write-probe` only writes with `--apply`. `ddc-write-probe` always writes: it moves one monitor's brightness a few steps and puts it back. `layout-probe` is read-only. `connection-probe` is read-only, sends nothing to a monitor, and prints no serial number or UUID. `layout-write-probe.swift` changes the layout and is run only with the owner present: see its header. `override-probe` and `virtual-display-probe` are read-only and create nothing. `override-write-probe.swift` writes a file as administrator and `virtual-display-write-probe.swift` creates a display: both are run only with the owner present, see their headers. `hdr-color-probe` is read-only, calls private interfaces only where their shape is known, and prints no serial number or UUID. `hdr-color-write-probe.swift` switches HDR, a color profile or Night Shift for a few seconds and puts it back: run only with the owner present.

To list the display-related functions a system framework exports on a given macOS version:

```sh
dyld_info -exports /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight | grep -i display
```
