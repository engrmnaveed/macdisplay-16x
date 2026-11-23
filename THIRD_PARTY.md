# Third-party references

Display 16X is written from scratch and has no third-party dependencies. No code was copied from another project. The projects below were used as references for how macOS interfaces behave, and each is permissively licensed.

| Project | License | What was learned from it |
| --- | --- | --- |
| [MonitorControl](https://github.com/MonitorControl/MonitorControl) | MIT | That DDC/CI on Apple silicon goes through the display's AV service I2C channel, the names and argument order of `IOAVServiceCreateWithService`, `IOAVServiceReadI2C`, `IOAVServiceWriteI2C` and `IOAVServiceCopyEDID`, the `DisplayServices` brightness functions, and how the media keys arrive in a system-defined event. |
| [m1ddc](https://github.com/waydabber/m1ddc) · [AppleSiliconDDC](https://github.com/waydabber/AppleSiliconDDC) | MIT | That some monitors need input switching sent to host address `0x50` with feature code `0xF4`. |
| [displayplacer](https://github.com/jakehilborn/displayplacer) | MIT | That rotation on Apple silicon goes through the `MPDisplay` class of the MonitorPanel framework, with `initWithCGSDisplayID:` and `setOrientation:`. Also the window server's mode list: the functions that count, describe and select modes by number, and the layout of a mode description (which displayplacer credits to Phoenix Dev). That a display is taken out of use and brought back with the window server's enable flag, `CGSConfigureDisplayEnabled` (`SLSConfigureDisplayEnabled` in SkyLight), inside an ordinary display configuration. |

The DDC/CI packet format and the feature codes come from the public VESA DDC/CI and Monitor Control Command Set documents.

No proprietary application was opened, disassembled, traced or inspected, and no text, icon, screenshot or layout was copied from one. See [AGENTS.md](AGENTS.md) for the rules.
