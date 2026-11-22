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

## Running the probes

Both probes are read-only. They change no display setting.

```sh
swiftc -O spikes/display-probe.swift -o /tmp/display-probe && /tmp/display-probe
swiftc -O spikes/ddc-probe.swift -o /tmp/ddc-probe && /tmp/ddc-probe
```

To list the display-related functions a system framework exports on a given macOS version:

```sh
dyld_info -exports /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight | grep -i display
```
