<sub>[User guide](../user-guide.md) › Command line</sub>

# 💻 The command line

`display16x` does everything the panel does, for scripts, shortcuts and Terminal. It comes inside the app, and the Homebrew cask puts it on your `PATH`. For the ZIP, the [install guide](../install.md#install-the-release-zip) shows how to link it.

```sh
display16x help                    # every command
display16x features                # every feature and what can be done with it
display16x help brightness         # values and an example for one feature
```

> [!NOTE]
> `display16x probe` runs on its own, reads only, and is the thing to attach to a bug report. Every other command goes to the running app over a socket only your user can open. When the app is not running, the command says so and changes nothing.

### The shape of a command

```text
display16x  VERB  FEATURE  [VALUE]  DISPLAY  [OPTIONS]
display16x  set   brightness 60%    --tag 1  --try
```

| Verb | Does |
|---|---|
| `get` | Reads a value. Add `--stored` for the value the app remembers |
| `set` | Sets a value |
| `step` | Moves by steps, such as `+1` or `-2`. Add `--fine` for small steps |
| `toggle` | Flips a switch |
| `perform` | Runs an action, such as `stopMirroring` |
| `keep` · `revert` | Answers a change that waits for Keep or Revert. `revert` with no display puts the last layout change back |

### Name a display

| Option | Means |
|---|---|
| `--tag N` | The display with this tag. `display16x list` shows the tags |
| `--name "NAME"` | By name, as `list` shows it |
| `--main` · `--pointer` · `--focused` | The main display, the one under the pointer, the one with the active window |
| `--all` | Every display |
| `--of-tag N` and the like | The *other* display, for placement and mirroring |

### Values

| Kind | Examples |
|---|---|
| Levels | `60%`, `0.6`, `+10%`, `-5%`, `min`, `max` |
| Switches | `on`, `off` |
| Resolution | `2560x1440`, `"1920x1080 hidpi @60"`, `default`, `native`, `previous`, `largest`, `smallest`, `favourite:1` |
| Rotation | `0`, `90`, `180`, `270` |
| Placement | `left`, `right`, `above`, `below`, with `:start`, `:center` or `:end` |
| Keys for a shortcut | `ctrl+opt+1`, `cmd+shift+f13` |

### Options

| Option | Does |
|---|---|
| `--try` | For size, refresh rate, rotation, HDR, a profile or a preset: ask Keep or Revert on screen, and go back by itself if nobody answers |
| `--confirm` | Needed to write anything outside the app's folder, to switch an input, write raw DDC or import and reset settings. Without it you get the preview |
| `--exact` | Refuse a size that is not exactly the one asked for |
| `--no-verify` | Do not read the value back |
| `--json` | Print the raw result |
| `--timeout SECONDS` | How long to wait for the app. Default 10 |

Every display gets one line in the reply: **confirmed** (read back from the device), **accepted** (sent or stored, not proven), or **failed** with the reason.

## Every command, by task

| Task | Commands |
|---|---|
| **See what is there** | `list` · `status` · `arrangement` · `probe` · `probe --capabilities` · `probe --modes` · `probe --color` |
| **Brightness and sound** | `get/set/step brightness` · `contrast` · `volume` · `toggle mute` · `set input NAME --confirm` · `set restoreAfterWake on` · `perform indicator brightness` |
| **Text size and rotation** | `get/set/step resolution` · `set refreshRate` · `set/step/toggle rotation` · `keep` · `revert` · `set favourites add` · `get modes` |
| **Arrangement** | `set main on` · `set placement` · `set position X,Y` · `set mirror on` · `perform stopMirroring` · `disconnect` · `reconnect` · `perform keepOnlyMain` · `perform makeOnly` · `set protectLayout on` · `perform saveLayout` |
| **Scenes** | `preset list` · `preset save NAME [modes,rotation,layout,brightness]` · `preset apply NAME` · `preset delete NAME` |
| **Shortcuts** | `shortcut list` · `shortcut add KEYS VERB FEATURE [VALUE] [DISPLAY]` · `shortcut remove KEYS` |
| **Settings** | `settings export [FILE]` · `settings import FILE --confirm` · `settings reset --confirm` · `set commandLineAccess` · `set urlScheme` |
| **More sizes** | `override [show]` · `override add/remove SIZE` · `override flexible` · `override preview` · `override apply --confirm` · `override list` · `override delete … --confirm` · `override undo` · `override reset` · `override put-back` |
| **Virtual screens** | `virtual list` · `virtual create NAME OPTIONS` · `virtual edit` · `virtual connect/disconnect/reconnect NAME\|all` · `virtual discard NAME\|all --confirm` |
| **HDR** | `hdr [show]` · `hdr on/off/toggle --try` · `hdr headroom` · `hdr protect on` · `hdr hardware-brightness` · `hdr night-shift` · `hdr controls` |
| **Color** | `color profile NAME\|factory` · `color hdr-profile` · `color fallback` · `color protect on` · `color profiles` · `color preset` · `color modes` · `color rates` · `color dithering` · `color controls` |
| **Skins** | `skin` · `skin NAME` · `skin custom accent=#RRGGBB surfaces=#RRGGBB` |
| **Raw DDC** | `get vcp 0x10` · `set vcp 0x10=50 --confirm` |
| **The log** | `get log` · `probe --with-log` |

## Recipes

```sh
# Dim every display for the evening
display16x set brightness 30% --all

# A shortcut that turns the monitor under the pointer up
display16x shortcut add ctrl+opt+up step brightness +1 --pointer

# Try a size, and keep it from a script once it looks right
display16x set resolution 2560x1440 --tag 1 --try
display16x keep --tag 1

# Save the desk as it is now, and bring it back with one key
display16x preset save Desk
display16x shortcut add ctrl+opt+1 set preset Desk

# Present: only the projector, then everything back
display16x perform makeOnly --tag 3
display16x reconnect --all

# What does each monitor answer? Attach this to a bug report
display16x probe --capabilities > display16x-report.txt
```

### Exit codes

| Code | Means |
|:-:|---|
| 0 | Done |
| 1 | The command failed. The reply says why |
| 2 | The command was not understood |
| 3 | Display 16X is not running |
| 4 | The app did not answer in time |

<details>
<summary><b>Every feature name</b></summary>

Use these after `get`, `set`, `step`, `toggle` or `perform`. `display16x features` prints them with what each one does.

| Group | Features |
|---|---|
| Brightness and sound | `brightness` `hardwareBrightness` `softwareBrightness` `contrast` `volume` `mute` `input` `restoreAfterWake` `indicator` |
| Size and rotation | `resolution` `refreshRate` `rotation` `keepMode` `revertMode` `favourites` `modes` `protectMode` `protectRotation` `mirrorTargetSizes` |
| Arrangement | `main` `position` `placement` `arrangement` `mirror` `stopMirroring` `keepLayout` `revertLayout` `saveLayout` `protectLayout` `protectionNotices` `connected` `reconnectAll` `keepOnlyMain` `makeOnly` `allowDisconnectAll` `autoBuiltInOff` `turnsBuiltInOff` |
| Scenes and shortcuts | `preset` `savePreset` `deletePreset` `shortcuts` `removeShortcut` |
| The app | `displays` `status` `log` `inputs` `identifiers` `vcp` `settingsExport` `settingsImport` `settingsReset` `commandLineAccess` `urlScheme` `skin` |
| More sizes | `overridesEnabled` `virtualScreens` `mirrorHiDPI` `scaling` `overridePreview` `overrideApply` `overrideDiscard` `overrideActivate` `overrides` `overrideRemove` `overrideUndo` `fullReset` `putBackSystem` `virtualList` `virtualCreate` `virtualEdit` `virtualConnect` `virtualDisconnect` `virtualReconnect` `virtualDiscard` |
| HDR and color | `hdrControls` `profileControls` `nightShiftInHDR` `hdr` `headroom` `protectHDR` `hardwareInHDR` `profiles` `colorProfile` `hdrProfile` `profileFallback` `protectProfile` `referencePreset` `colorMode` `dithering` `linkRates` `keepColor` `revertColor` `upscaling` `upscale` `upscaleLimits` |

</details>

<p align="center"><sub><a href="settings.md">← Settings</a> · <a href="../user-guide.md">User guide</a> · <a href="troubleshooting.md">Help and safety →</a></sub></p>
