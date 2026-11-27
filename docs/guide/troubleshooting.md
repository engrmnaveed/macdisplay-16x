<sub>[User guide](../user-guide.md) › Help and safety</sub>

# 🛟 Help and safety

What the app asks of your Mac, how to undo anything, and what to do when something does not work.

## What it asks for

| Permission | Needed for | Where |
|---|---|---|
| **Allow the first launch** | Opening a release that Apple has not notarized | **System Settings → Privacy & Security → Open Anyway**, once per version |
| **Accessibility** | The brightness and volume keys only. Everything else works without it | **Privacy & Security → Accessibility**. The panel opens the page |
| **Login Items** | Opening at login, if you switch it on | macOS may ask you to approve it |
| **Administrator password** | Writing or removing a display override | macOS's own dialog, each time |

Global shortcuts, links and the command line need no permission.

## Undo anything

| What changed | How to undo |
|---|---|
| Size, refresh rate, rotation, HDR, a profile | **Revert**, or wait 15 seconds, or `display16x revert --tag N` |
| Arrangement, main display, mirroring | **Revert**, or `display16x revert` with no display named |
| A disconnected display | **Arrange → Off or away → Reconnect**, `display16x reconnect --all`, or quit the app |
| A display override | **Remove…** on the display's page, or `display16x override delete all --confirm`, which works without the app |
| A virtual screen | Disconnect it in **Settings → Advanced**, or `display16x virtual discard NAME --confirm` |
| Your settings | `display16x settings reset --confirm`, or delete the settings folder |

Brightness, contrast and volume set over DDC stay in the monitor after the app quits, as if you had used its buttons.

## Safe mode

Hold <kbd>Shift</kbd> while Display 16X starts, or start it with `--safe`:

```sh
open -a "Display 16X" --args --safe
```

Nothing is restored or put back by itself: no values after sleep, no protected layout, no automatic connects. The menu bar icon is drawn dashed and the panel says so. It ends when you quit Display 16X and open it again. Safe mode is unit-tested; a check on hardware is still to come.

## When something does not work

### The keys do nothing

1. Open the panel. If it asks for the Accessibility permission, click **Open Accessibility Settings** and switch on **Display 16X**.
2. **After an update**, the old entry no longer counts, even if it looks switched on. Select it, remove it with <kbd>−</kbd>, add the app with <kbd>+</kbd>, then close and open the panel.
3. Look at **Settings → General**. The line under the brightness switch says whether the keys are heard, and why the last one went to macOS. `display16x status` says the same.
4. Check **The keys reach**. With "under the pointer", the pointer has to be on the monitor.

### The volume keys do nothing

They change a monitor only while the sound plays through it. Pick the monitor as the sound output in Control Center or **System Settings → Sound**. Some monitors ignore volume over DDC; see the next answer.

### A monitor ignores a control

Each monitor decides which controls it accepts over DDC/CI. Display 16X reads a value back after it changes it, and marks a control the monitor reports but ignores. A monitor in standby may not answer at all: the app keeps what it knew and asks again after a wake. Click **Check Again** on the display's page to ask it what it supports.

### The picture is too dark

Software dimming can go below the monitor's own minimum. Drag the brightness bar up, or switch the dimming off in **Settings → General**. When you come back after half an hour with the screen locked or the displays off, very dark dimming is lifted by itself.

### A monitor forgets its brightness after sleep

Switch on **Put my values back after sleep** on its page, under Options. Without it the app only reads the monitor after a wake, so changes made with the monitor's buttons stay.

### The command line says the app is not running

Every command except `probe` needs the app. Open Display 16X and try again. If it is running, check **Settings → Scripting → The display16x command may control this app**.

### A shortcut does nothing

**Settings → Shortcuts** marks a shortcut whose keys another app holds. Record different keys.

### Homebrew says the cask does not exist

Your copy of the tap is older than the cask. Run `brew update`, then install again. The [install guide](../install.md#install-with-homebrew) has more.

## Report a problem

1. Run the hardware report. It reads only and works without the app:

   ```sh
   display16x probe --with-log > display16x-report.txt
   ```

2. [Open an issue](https://github.com/engrmnaveed/macdisplay-16x/issues) and attach it, with your Mac, macOS version, monitor and how it is connected.

> [!CAUTION]
> The report names your monitors with their serial numbers and system identifiers. Replace them with made-up ones before you post it publicly if you would rather not share them.

## Remove Display 16X

1. If you used **More sizes**, remove overrides and virtual screens first, while the app still runs: `display16x override delete all --confirm` and `display16x virtual discard all --confirm`.
2. Switch off opening at login, then quit the app.
3. `brew uninstall --cask display16x`, adding `--zap` to remove the settings too.
4. Remove **Display 16X** from **Privacy & Security → Accessibility**.

The [install guide](../install.md#remove-display-16x) has every step, for the ZIP as well.

<p align="center"><sub><a href="command-line.md">← Command line</a> · <a href="../user-guide.md">User guide</a></sub></p>
