# Install Display 16X

Display 16X needs an Apple silicon Mac with macOS 14 or later. Each release on the [releases page](https://github.com/engrmnaveed/macdisplay-16x/releases) has one ZIP with the menu bar app, and the `display16x` command line tool inside it. The release notes say how that release is signed, which decides what macOS asks of you at the first launch and after an update.

## Install with Homebrew

The cask lives in the project's tap, [engrmnaveed/homebrew-tap](https://github.com/engrmnaveed/homebrew-tap). Install it by its full name:

```sh
brew install --cask engrmnaveed/tap/display16x
```

Since Homebrew 6, Homebrew only loads casks from taps you trust, and installing by the full name trusts this one cask. To use the short name in later commands, trust the cask once:

```sh
brew trust --cask engrmnaveed/tap/display16x
```

The cask puts **Display 16X.app** in Applications and links the `display16x` command into Homebrew's `bin` folder.

- **Upgrade:** `brew upgrade --cask display16x`. If the app is running, Homebrew quits it, replaces it and opens it again.
- **Remove:** see [Remove Display 16X](#remove-display-16x).

## Install the release ZIP

Download `display16x-X.Y.Z-macos-arm64.zip` and its `.sha256` file from the [releases page](https://github.com/engrmnaveed/macdisplay-16x/releases) into one folder. Check the download and unpack it there. The commands use version 0.1.0 as an example.

```sh
shasum -a 256 -c display16x-0.1.0-macos-arm64.zip.sha256
ditto -x -k display16x-0.1.0-macos-arm64.zip .
```

The SHA-256 file only shows that the download is complete, since it comes from the same place. Each release also has a GitHub build-provenance attestation, which shows that the ZIP was built by this repository's release workflow from the tagged commit. Check it with the [GitHub CLI](https://cli.github.com/):

```sh
gh attestation verify display16x-0.1.0-macos-arm64.zip \
  --repo engrmnaveed/macdisplay-16x \
  --signer-workflow engrmnaveed/macdisplay-16x/.github/workflows/release.yml
```

Move **Display 16X.app** to Applications in Finder. To use the command line tool, link it into a folder on your `PATH`, for example:

```sh
mkdir -p ~/.local/bin
ln -sf "/Applications/Display 16X.app/Contents/MacOS/display16x" ~/.local/bin/display16x
```

To update, download the new ZIP and replace the app in Applications.

## Allow the first launch

A release signed with a Developer ID and notarized by Apple opens normally. Any other release is blocked by macOS at the first launch, because Apple has not checked it. You approve it once:

1. Open Display 16X. macOS says it could not verify that the app is free of malware. Click **Done**. Don't click **Move to Trash**, which deletes the app.
2. Open **System Settings → Privacy & Security**.
3. Scroll to **Security** and click **Open Anyway** next to the message about Display 16X.
4. Enter your password or use Touch ID, then click **Open Anyway** in the dialog that follows.

The app's icon then appears in the menu bar. It has no Dock icon.

**If Open Anyway isn't there:** the button appears only after you try to open the app, and for about an hour after that. Open Display 16X again, click **Done** and go back to Privacy & Security. If the app went to the Trash, run `brew reinstall --cask display16x` or download the ZIP again.

To skip the prompt, remove the quarantine attribute from a copy you have checked:

```sh
xattr -dr com.apple.quarantine "/Applications/Display 16X.app"
```

The `display16x` command is checked the same way the first time it runs. If macOS blocks it in Terminal, allow it under Privacy & Security as above, or use the `xattr` command.

**After an update:** a Homebrew upgrade keeps your approval when the new version has the same signature as the old one, which is the case for releases signed with a Developer ID or the project certificate. An update downloaded by hand is approved again with the same steps. An ad hoc signed release is a new app to macOS each time, so it is approved again after every update.

## Allow the brightness and volume keys

The brightness and volume keys need the Accessibility permission. Everything else works without it.

1. Click the Display 16X icon in the menu bar. The panel says when the keys need permission and opens the right page in System Settings.
2. In **System Settings → Privacy & Security → Accessibility**, switch on **Display 16X**. If it isn't listed, click **+** and choose it from Applications.
3. Close the panel and open it again.

macOS gives the permission to the app's signature. What happens after an update depends on how the release is signed:

- **Developer ID or the project certificate:** the signature stays the same from release to release, so the permission carries over. Nothing to do.
- **Ad hoc:** every build has a new signature, so the old permission no longer applies, even though Display 16X still looks switched on in the list. Select the old **Display 16X** entry, remove it with **−**, then add the new app with **+**, and close and open the panel.

To see how the installed app is signed, run:

```sh
codesign -d -r- "/Applications/Display 16X.app"
```

A requirement that names a `cdhash` means ad hoc. One that starts with `identifier "com.16xbrains.macdisplay16x"` or `anchor apple generic` means the project certificate or a Developer ID.

## Remove Display 16X

1. If you switched on launch at login in the app, switch it off there first, so macOS has no login item left pointing at a missing app.
2. Quit Display 16X from its panel. Changes made over DDC, such as brightness and volume, stay in the monitor.
3. Remove the app:
   - **Homebrew:** `brew uninstall --cask display16x`. Add `--zap` to also remove the settings folder.
   - **ZIP:** move **Display 16X.app** from Applications to the Trash, and remove the link you made, for example `rm ~/.local/bin/display16x`.
4. The settings are one folder. To remove them by hand:

   ```sh
   rm -rf ~/Library/Application\ Support/com.16xbrains.macdisplay16x
   ```

5. In **System Settings → Privacy & Security → Accessibility**, select **Display 16X** and remove it with **−**.

## Build from source

You need the Command Line Tools (`xcode-select --install`). Xcode is not required.

```sh
swift build
swift test
scripts/package-macos.sh
open "dist/Display 16X.app"
```

The app in `dist` is ad hoc signed for local use, so the Accessibility permission has to be given again after each rebuild. The [README](../README.md#build-and-run) says how to keep it with a certificate of your own, and the [release runbook](release.md) how releases are made.
