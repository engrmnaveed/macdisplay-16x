# Changelog

## Unreleased

### Homebrew

- `brew install --cask engrmnaveed/tap/display16x` now installs Display 16X. Until 26 November 2026 it said the cask does not exist: no release from 0.2.0 to 0.5.0 had reached the Homebrew tap. The tap has 0.5.0's cask now, and nothing had to change in 0.5.0 itself.
- A release is no longer published when it cannot update the tap, and before a release run finishes it installs the new version from the tap on a Mac that has never had Display 16X, then removes it again.

## 0.5.0

Skins: choose the colors Display 16X is drawn in, from six ready-made skins or two colors of your own. A skin changes how the app looks and nothing on your displays. Studio stays the default, so until you choose another skin the app looks as 0.4.0 did, apart from a settings window made wider for its new tab.

### Skins

- Choose how Display 16X looks in **Settings → Appearance**: six ready-made skins, Studio (the default, as before), System (the accent color chosen in System Settings), Graphite, Ember, Orchid and Moss, or **Custom** with an accent and a color for the surfaces of your own. Every skin follows light and dark mode and Increase Contrast. A choice shows at once on the panel, a display's page, Arrange, the settings window, the Keep windows, the indicator and the notices, with no restart.
- Custom colors stay readable: text and controls are worked out from your two colors in every look, and the accent is drawn lighter or darker only when it has to be, which the Appearance tab says. `display16x get skin` gives the accent as drawn.
- The menu bar icon keeps the system's color in every skin.
- From the command line: `display16x skin` shows the skin in use and every skin there is, `display16x skin ember` wears one, and `display16x skin custom accent=#D6336C surfaces=#E8D8C4` sets your own. `display16x set skin …` works too, and so do links where they are switched on. `display16x help skin` explains the values.
- The choice is part of the settings file, so settings export, import and reset carry it. An older version of the app shows Studio, and forgets the choice the next time it saves its settings.
- The settings window is 80 points wider, so its seven tabs fit.

### What was checked on hardware

- On an Apple M5 Pro Mac with macOS 27.2.1, a build with the skins has been the developer's copy in daily use since 24 November, in Studio.
- Not yet done in the running app: choosing another skin or Custom, and the System skin following a change of the Mac's accent color. Both are unit-tested. The tests measure the contrast of every pair of colors in Studio, every ready-made skin, every accent color macOS offers, awkward custom colors and two thousand random ones, in light, dark and both increased-contrast looks. An off-screen run opens the panel, a display's page, Arrange, the Appearance tab, a Keep window, the indicator and a notice, changes the skin, and checks that each one takes it at once.

### For developers

- A ready-made skin is one line in `Theme.skins`, in `Sources/Display16XApp/Design/Theme.swift`, and the tests measure its contrast on their own. The README's section on the look says how to check one by eye.

## 0.4.0

HDR and color: switch HDR on the displays that have it, choose color profiles with one to fall back to and one for HDR, see how each display's link carries the picture, and keep Night Shift out of the way in HDR. Every feature here is off until you turn it on, in Settings under Advanced or with `display16x set hdrControls on`, `profileControls on`, `nightShiftInHDR on` and `upscaling on`, and each says what it costs next to its switch. Until then Display 16X does what 0.3.0 did. The app has not yet used any of these features on a real display: they are unit-tested, and what test programs proved on hardware is listed below.

### HDR

- Switch HDR from a display's page or with `display16x hdr on --tag 2`, through the same switch System Settings uses. From the panel, and from the command line with `--try`, a small window asks Keep or Revert and switches back on its own when nobody answers. A switch still waiting when the app quits is undone, and one a crash left is undone at the next start.
- `display16x hdr headroom --tag 2` says how far above SDR white the display can show, now and at most, and what sets the level of ordinary windows in HDR.
- Protect HDR: the app puts it back after a wake, a reconnect and a change made elsewhere, and stops after three tries in two minutes, saying so.
- Night Shift and True Tone can go off while a display shows HDR, and come back on afterwards. Only what was on is turned off, only what the app turned off is turned back on, and it is given back when the app quits or, after a crash, when it starts again.
- A display that shows HDR at all times, such as a MacBook Pro's built-in XDR panel, reads as HDR always on, with how far above SDR white it can go. There is nothing to switch, and the app does not offer a switch.
- Hardware brightness in HDR is a switch per display. Turned off, brightness leaves a monitor's backlight alone while HDR is on and says why.
- A virtual screen can offer HDR modes next to its SDR ones, or only HDR: `display16x virtual create Studio 2560x1440 hdr=on connect`.

### Color profiles and presets

- Choose a display's color profile from its page or with `display16x color profile "Display P3" --tag 2`, or give it back its own with `factory`. From the panel it asks Keep or Revert. `display16x color profiles` lists every display profile installed.
- Choose a profile for HDR as well, and it goes on when HDR switches on and comes off when it switches off, whoever switched it.
- Name profiles to fall back to when the chosen one goes missing; the monitor's own comes last. Protect the profile and the app puts it back, through the fallback if it must.
- While a profile of your own is assigned, software dimming pauses on every display, and the panel says so.
- Reference presets of Apple's own displays can be chosen by name. Only the real ones are listed: the built-in XDR panel shows its eleven, without the forty empty slots macOS keeps for custom presets.

### The link

- `display16x color modes --tag 2` lists the ways the link can carry the picture, by depth, encoding, range and transfer, in macOS's own order. `display16x color rates --tag 1` lists refresh rates the link offers that macOS leaves out of the mode list, such as 24 and 25 Hz at 4K. `display16x color dithering --tag 1` says whether the GPU dithers. **On macOS 27 all three are read-only:** macOS offers no documented way to choose a link color mode, a rate outside the mode list, or dithering, so the app shows them and does not change them.
- `display16x probe --color` adds HDR and color to the hardware report, without sending anything to a monitor.

### Brightness above SDR white

- With HDR on, a display could go brighter than SDR white, from its page, with `display16x set upscale 50% --tag 2`, or with the brightness keys past 100%, which stop at 100% first. It has limits per display and never survives a sleep, a lock or the app. **This software upscaling is not active yet and brightens nothing:** the app's color pipeline cannot write a value above white, and the panel and the command line say so until it can.

### Not included

- Direct XDR upscaling, which would drive a built-in XDR panel's own brightness above white. No XDR panel was in use while this release was built, and for a built-in display the app says it is not built yet.
- Choosing a link color mode, a rate outside the mode list, or dithering, as above.

### What was checked on hardware

On an Apple M5 Pro Mac with macOS 27.2.1, an LG SDQHD on USB-C and a Lenovo P32p-20 on HDMI, with small test programs and the hardware report, not yet through the app:

- HDR switched on and off on the LG through System Settings' own switch. The display went dark for a moment and did not leave the system, its mode stayed, and its color table stayed as it was. Its headroom went from 1 to 2.95 potential, which is its 295 nits over 100. Ordinary windows looked paler in HDR.
- A color profile assigned to the LG took effect at once, and giving the monitor's own back removed it cleanly.
- Night Shift was switched on and off.
- The link's color modes, the rates the mode list leaves out, dithering and Night Shift's state read the same through the app's own code as through the test programs.
- Through the app, with the MacBook's lid open: its built-in XDR panel read as HDR always on, up to 16 times SDR white, with its eleven reference presets and its own color profile.

Unit-tested only: everything the app does on its own with these features, protection of HDR and profiles, the profile for HDR, Night Shift off in HDR, reference presets, virtual screens with HDR, and brightness above white.

## 0.3.0

Advanced scaling: sizes macOS does not offer, screens that exist only in the Mac, and HiDPI for a panel that has none of its own. Every feature in this release is off until you turn it on, in Settings under Advanced or with `display16x set overridesEnabled on`, `virtualScreens on` and `mirrorHiDPI on`, and each says what it costs next to its switch. Until then Display 16X does what 0.2.0 did. The app has not yet used any of these features on a real display: they are unit-tested, and what was proven on hardware is listed below.

### More sizes through display overrides

- Add sizes macOS does not offer, for any model of display: fine HiDPI steps across the panel's range (`display16x override flexible --tag 2`), sizes of your own at either density (`display16x override add 2592x2304 --tag 2`), and the panel size, the size macOS picks first, the name macOS shows and whether the display counts as a television. Sizes are typed as the display shows them, turned or not.
- Nothing is written until you have seen it. The preview names every display the file reaches (an override is for a model, so every unit of it), every step, and the file byte for byte. Writing asks for your administrator password in macOS's own dialog.
- Display 16X then reconnects the display so macOS reads the file, and reads back which sizes macOS offers: macOS 27 leaves out some sizes without saying so, and the app tells you which. The main display is not reconnected by the app; replug its cable or log out.
- Remove one override, undo the last change to one, or remove every one the app wrote, from the panel or with `display16x override delete all`. That works while the app is not running too, after a crash for example: every file the app writes carries a marker, so it finds its files from the files themselves. A full reset can also move macOS's saved display arrangements aside, from where `display16x override put-back` restores them. Removing the app leaves overrides and virtual screens' color profiles in place, so remove them first, as the installation guide describes.

### Virtual screens

- Make screens that exist only in the Mac, for headless and remote use: `display16x virtual create Studio 16:9 2560x1440 hidpi @60 connect`. Sizes are generated from an aspect, a step and a limit, or listed by hand, at refresh rates up to 240 Hz, up to the window server's limit of 16384 pixels a side. A screen can copy the shape of a connected display, stand in portrait, and report its own name, serial number and size.
- Connect, disconnect, reconnect or discard one screen or all of them. A disconnected screen keeps its definition. Discarding also removes the color profile macOS made for it.
- Saved screens come back when the app starts and after a wake. A screen linked to a display connects and disconnects with it, and can turn with it. Automatic connects stop after three in two minutes and say so. macOS moves your displays aside when a screen appears; the app puts them back.
- A virtual screen is never counted as a physical display, so the last real display in use is never taken out because a virtual one is there.

### Mirror-based HiDPI

- For a panel macOS gives no HiDPI size of its own, a matched HiDPI virtual screen can be shown on it: `display16x virtual create "LG HiDPI" match mirror=on connect --tag 2`. This keeps the GPU busy with a copy of the whole screen at every refresh, so it has its own switch, starts only for a screen you linked this way, ends when the switch is turned off, and `display16x status` says while it runs.

### What was checked on hardware

On an Apple M5 Pro Mac with macOS 27.2.1 and an LG SDQHD, with small test programs and not yet through the app:

- macOS reads an override file in `/Library/Displays` when the display connects, and not before. Taking the display out of use for a few seconds and back, the way the app reconnects it, is enough.
- Removing the file and reconnecting brings back exactly the sizes the display offered before: 42, with nothing new and nothing gone.
- macOS took some of the sizes the file asked for and left others out without saying why, among them the LG's full panel size as HiDPI. That is why the app reads the list back after writing.
- A virtual screen was created and released while the program kept running. It was gone within 3 seconds, and the displays went back to where they were.

Unit-tested only, and not yet run from the app on hardware: the app's own override write with its preview, its removal from the panel and from the command line, an override for the main display (a cable replug or a logout to make macOS read it was not tried), virtual screens made by the app, across sleep and when the app starts, mirror-based HiDPI, and the override settings other than sizes: the panel size, the size macOS picks first, the name and the television flag.

## 0.2.0

The first published release of Display 16X. It brings display layout and a redesigned interface, and it includes everything in 0.1.0 below, which was not published on its own. It needs an Apple silicon Mac with macOS 14 or later.

### Arrange your displays

- Make a display the main one, drag it on a picture of your desk drawn to scale, or put it next to another without the pointer (`display16x set placement left:end --tag 2 --of-tag 1`). Mirror one display onto another, and stop again. Each change asks **Keep** or **Revert** and goes back on its own after 15 seconds, and `display16x revert` puts the last layout change back.
- Take a display out of use without unplugging it, and bring it back, from the panel or with `display16x disconnect --tag 2` and `display16x reconnect --all`. The last display in use is never taken out unless you allow it. A disconnect lasts until you log out at most. The app reconnects what it disconnected when it quits, at its next start if it stopped unexpectedly, and at once if the last display in use goes away.
- Optionally turn the built-in panel off while an external display is attached, with displays you can exclude. It does nothing while the lid is closed. Off by default.
- Protection, off by default: save a layout and have it put back after sleep, after a reconnect and after a change made elsewhere, and keep a display's resolution or rotation the same way. It waits until displays have stopped coming and going, gives up after three attempts in two minutes, and says on screen what it did. After you keep an arrangement change, the app offers once to protect it.
- Scenes save the current sizes, rotation and arrangement, and brightness if you like, under a name. Apply one from the top of the panel, from the command line (`display16x preset apply Desk`) or with a keyboard shortcut.
- Global keyboard shortcuts for any command, recorded in the settings window or added with `display16x shortcut add ctrl+opt+1 set preset Desk`. They need no Accessibility permission, and a clash with your other shortcuts or with macOS's is pointed out.

### A new interface

- The panel has the app's own look, in navy and aqua. Each display is drawn to scale next to its name, brightness and volume are thick bars with the number beside them, and the text-size strip marks the default size with a dot.
- Each display has a page of its own, one level down: refresh rate, rotation, contrast, where its brightness comes from, what it does not offer and why, its place on the desk, and its options. The panel keeps its size and scrolls on a small screen.
- **Keep** or **Revert** says what changed ("Keep 2560 × 1440?"), what it goes back to and how long is left.
- A value says how it is known: read back from the display, only sent, as with software dimming, or not known yet, as just after a wake. A card says how the display is connected (HDMI, USB-C, Thunderbolt or built-in, named after the Mac's own port) and its size in inches.
- A settings window holds what applies to the whole app: opening at login, the keys, software dimming, scenes, shortcuts, the command line and links, the settings file, and About.
- What needs you comes first: a missing Accessibility permission with its steps, safe mode, a change that failed. The menu bar icon shows a dot when something waits for you, and is drawn dashed in safe mode.
- The on-screen indicator names the display a key reached. The app has an icon.

### Command line and settings

- Resolution by name (`default`, `native`, `previous`, `largest`, `smallest`), favourite modes, size steps along the text-size strip, and rotation in steps or as a toggle. Repeated size steps are gathered into one change.
- The brightness and volume keys reach every display that mirrors the one they target.
- Help for every feature (`display16x help placement`), `min` and `max` as values, a `perform` verb, JSON listings of a display's modes, inputs and identifiers, and raw DDC reads and writes (`display16x get vcp 0x10 --tag 1`; a write needs `--confirm`). A switch turns command line access off.
- `display16x list` and `display16x probe` say how each display is attached, and `get` says whether a value was read back from the monitor or only sent.
- `display16x://` links run commands, behind a switch of their own that is off by default and a token shown in the app, with x-callback-url callbacks.
- Export, import and reset all settings, in the settings window or with `display16x settings export`, `import` and `reset`. A scene or shortcut this version cannot read, for example one saved by a newer version, is left out and logged, and the rest of your settings are kept.

### What was checked on hardware

On an Apple M5 Pro Mac with macOS 27.2.1, a Lenovo P32p-20 and an LG SDQHD:

- Fourteen of the fifteen layout checks: arranging, the main display, placement, mirroring, disconnect and reconnect, from the command line and from the panel with **Keep** and **Revert**; reconnecting at quit; a scene from a shortcut; a layout put back after it was changed in System Settings; and the built-in panel turned off when the lid opens. They ran with the panel as it was before the redesign.
- The redesigned app, in daily use on that Mac since the evening of 23 November. It read both monitors at start and wrote nothing. The panel opened in 76 to 109 ms, the app used about 53 MB with the panel closed, and 0.03% of one core over ten idle minutes.

Not yet tried on hardware: a saved layout across a long display sleep with protection on, the built-in panel coming back when the last external display goes away, the offer to protect a kept arrangement, links, the brightness keys across a mirror set, and the redesigned panel's layout controls one by one. VoiceOver, full keyboard access, Increase Contrast, Reduce Motion and Reduce Transparency were checked in drawings of the interface, not with those settings switched on. What 0.1.0 lists below as not yet run still applies.

### Not included

Shortcuts app actions, which cannot be built with the Command Line Tools alone, and asking macOS to look for displays again.

### For developers

`scripts/render-surfaces.sh` draws every surface from made-up monitors without starting the app, and replaces the app's `--snapshot-panel` option. The look lives in `Design/Theme.swift` and `Design/Primitives.swift`. `DISPLAY16X_SUPPORT_DIRECTORY` gives a build its own settings folder and command socket, and such a build does not start while the normal copy runs. A release is prepared with `scripts/prepare-release` and tagged with `scripts/tag-release`.

## 0.1.0

The first version of Display 16X, a menu bar utility for the display controls macOS leaves out. It needs an Apple silicon Mac with macOS 14 or later. It was not published as a release on its own: 0.2.0 is the first release, and includes all of it.

- One card per display in the menu bar panel, with brightness, text size, refresh rate and rotation, and volume and input where the monitor supports them. The panel's content is built when it opens and released when it closes, and the app does nothing while nothing happens: no timers and no polling.
- Every resolution and HiDPI mode, including the scaled sizes macOS leaves out of its public mode list. Pick a size from the text-size strip, then **Keep** or **Revert**. A change left unanswered goes back on its own after 15 seconds. Rotation uses the same countdown.
- Hardware brightness, contrast, volume, mute and input on external monitors over DDC, with one queue per display so the latest value wins. Brightness is verified on a Lenovo P32p-20 and an LG SDQHD. Input switching has not been run on hardware yet.
- Native brightness for built-in and Apple displays. Built, and not yet tested on such a display.
- Software dimming through color tables, darker than a monitor's own minimum. It is off by default. Dimming left very dark is lifted to a readable level when the app starts and when you come back after the displays were off or the screen was locked for 30 minutes or more.
- Brightness and volume keys that work on a monitor that is not Apple's, with an on-screen indicator. They need the Accessibility permission, and the panel opens the right page in System Settings.
- At start, after wake and when a display comes back, the app reads each monitor and follows it, and writes nothing. For a monitor that forgets its values while asleep, switch on **Put my values back after sleep** in that display's details, or run `display16x set restoreAfterWake on`.
- Settings follow each monitor across restarts, sleeps, cable replugs and port changes, keyed by a tag the app assigns.
- Safe mode: hold Shift while the app starts, or pass `--safe`, and nothing is restored or reapplied automatically.
- Launch at login. Built, and not yet verified.
- The `display16x` command line tool, inside the app and linked by the Homebrew cask. `display16x probe` prints a read-only hardware report without the app, and is the thing to attach to a bug report. `get`, `set`, `step`, `toggle`, `keep` and `revert` go to the running app over a socket only your user can open, and each display's line says `confirmed`, `accepted` or `failed`.
- Settings are one JSON file in `~/Library/Application Support/com.16xbrains.macdisplay16x/`. Nothing leaves your Mac: there are no accounts and no telemetry.
- Each version tag publishes a GitHub Release with `display16x-X.Y.Z-macos-arm64.zip`, its SHA-256 file and a build-provenance attestation, and updates the `display16x` cask in the `engrmnaveed/tap` Homebrew tap. `docs/install.md` in the repository covers both ways to install.

Not yet run on hardware: a MacBook Air M1 with its built-in panel, an Apple display, a monitor that forgets its values in standby, a connection that carries video without DDC, two units of one model, and software dimming with a custom color profile or Night Shift.
