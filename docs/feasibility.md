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

Same Mac and monitors as above: Lenovo P32p-20 and LG SDQHD, both on DisplayPort transport, the LG rotated 270°. BetterDisplay 5 was running throughout and holds a client on both DDC channels, so every DDC number here was measured with a second utility present. Nothing looked disturbed by it.

### How the two monitors answer DDC

| | Lenovo P32p-20 | LG SDQHD |
| --- | --- | --- |
| Query sent once | Answers. The first query after a pause often returns zeros | Always answers with the DDC null message (`6e 80 be`): listening, not ready |
| Query sent twice, 5 to 100 ms apart | Answers | Answers, at any read delay from 10 to 50 ms |
| Reply framing | Standard | Second byte is `0x51` (the host address) where the length byte `0x88` belongs. The checksum is correct for the standard frame |
| While the display is asleep | Still answers | Returns filler: `a6` repeated, or zeros. EDID over I2C still reads |
| Brightness `0x10` | 75 of 100 | 63 of 100 |
| Contrast `0x12` | 71 of 100 | 70 of 100 |
| Volume `0x62` | 50 of 100 | 13 of 100 |
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

Not tested: a connection that carries video and no DDC. There is none on this desk.

### Color tables

`spikes/gamma-table-write-probe.swift`, run while the displays were asleep:

- Both displays have a 1024-entry table. The table in use is a plain ramp, and neither display has a custom color profile.
- A gain of 0.7 was written to both: status 0, and the table read back exactly as written.
- The original table was written back: read back identical to the original, and still identical after the process exited.

So the interface works on an M5 Pro. What is still open is what it looks like: the run was not watched, the behavior after wake was not observed, and no custom color profile was present. Color tables stay off by default until those three are checked.

### Sleep, wake and identity

- The displays woke at 00:05. The app saw the LG leave and return four seconds later. The Lenovo stayed connected.
- Display IDs (4 and 5) and system UUIDs were the same before the display sleep, during it and after the wake, including across the LG's reconnect.
- How soon each monitor accepts DDC after wake is **not measured yet.** The first version of the wake probe was a bare command-line process, which never receives sleep or wake notifications, so it missed the wake. The app's own probe one second after the LG returned got no answer, and that proves nothing, because it sent its query once and the LG never answers a single query. The fixed probe is waiting for the next wake.
- Not tested: full system sleep, unplugging a cable, and moving a monitor to another port.

### Interfaces and modes

- Rotation: the display preferences class of the MonitorPanel framework is present, reports the same angle as Core Graphics for both monitors, and says both can be rotated. The write path has never been run.
- Mode flags: 101 of the Lenovo's 140 modes and 27 of the LG's 46 are marked safe. Every mode reports the same 8-bit pixel encoding, so depth cannot be told apart through the public interface.
- Sizes on the text-size strip: 11 on the Lenovo (1280 × 720 to 3360 × 1890), 5 on the LG (900 × 800 to 2304 × 2048).

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
