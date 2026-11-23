# Install Display 16X

Display 16X needs an Apple silicon Mac with macOS 14 or later. Each release on the [releases page](https://github.com/engrmnaveed/macdisplay-16x/releases) has one ZIP with the menu bar app, and the `display16x` command line tool inside it.

How a release is signed decides what you do when you install it and at every update. The release notes of each version say how it is signed.

**Every release so far is ad hoc signed** and not notarized by Apple. What that means for you:

- **Once:** macOS blocks the first launch until you allow it in Privacy & Security, and the brightness and volume keys need the Accessibility permission. Both are described below.
- **At every update:** macOS sees each ad hoc signed version as a new app. You allow the first launch again, and you give the Accessibility permission again by removing the old entry and adding the app. Homebrew warns about it during the upgrade.

Later releases are to be signed with the project's own certificate. Its signature stays the same from release to release, so the Accessibility permission carries over and a Homebrew upgrade keeps your first-launch approval. The first update to such a release still asks for both once, because its signature differs from the ad hoc one. A Developer ID with notarization will replace the certificate after that, and from then on the app opens without the first-launch step.

## Install with Homebrew

The cask lives in the project's tap, [engrmnaveed/homebrew-tap](https://github.com/engrmnaveed/homebrew-tap). Install it by its full name:

```sh
brew install --cask engrmnaveed/tap/display16x
```

Since Homebrew 6, Homebrew only loads casks from taps you trust, and installing by the full name trusts this one cask. To use the short name in later commands, trust the cask once:

```sh
brew trust --cask engrmnaveed/tap/display16x
```

The cask puts **Display 16X.app** in Applications and links the `display16x` command into Homebrew's `bin` folder. If Homebrew says it cannot find `display16x` in the tap, the tap has not been given the newest release yet: install the release ZIP below, or try again later.

- **Upgrade:** `brew upgrade --cask display16x`. If the app is running, Homebrew quits it, replaces it and opens it again. For an ad hoc signed release, Homebrew prints "display16x's signer changed so macOS may prompt at next launch": allow the launch and give the Accessibility permission again, as described below.
- **Remove:** see [Remove Display 16X](#remove-display-16x).

## Install the release ZIP

Download `display16x-X.Y.Z-macos-arm64.zip` and its `.sha256` file from the [releases page](https://github.com/engrmnaveed/macdisplay-16x/releases) into one folder. Check the download and unpack it there. The commands use version 0.3.0 as an example.

```sh
shasum -a 256 -c display16x-0.3.0-macos-arm64.zip.sha256
ditto -x -k display16x-0.3.0-macos-arm64.zip .
```

The SHA-256 file only shows that the download is complete, since it comes from the same place. Each release also has a GitHub build-provenance attestation, which shows that the ZIP was built by this repository's release workflow from the tagged commit. Check it with the [GitHub CLI](https://cli.github.com/):

```sh
gh attestation verify display16x-0.3.0-macos-arm64.zip \
  --repo engrmnaveed/macdisplay-16x \
  --signer-workflow engrmnaveed/macdisplay-16x/.github/workflows/release.yml
```

Move **Display 16X.app** to Applications in Finder. To use the command line tool, link it into a folder on your `PATH`, for example:

```sh
mkdir -p ~/.local/bin
ln -sf "/Applications/Display 16X.app/Contents/MacOS/display16x" ~/.local/bin/display16x
```

To update, download the new ZIP and replace the app in Applications. macOS asks you to allow the first launch of each downloaded version once more. The Accessibility permission carries over between releases signed with the project certificate. After an ad hoc signed one, give it again.

## Allow the first launch

No release is notarized by Apple yet, so macOS blocks the first launch of a downloaded version until you allow it:

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

**After an update:** an ad hoc signed version is allowed again with the same steps, however you installed it. Between releases signed with the project certificate, `brew upgrade` keeps your approval, because the new version has the same signature as the one you allowed, and the app opens again without asking. An update downloaded by hand is allowed again with the same steps.

## Allow the brightness and volume keys

The brightness and volume keys need the Accessibility permission. Everything else works without it.

1. Click the Display 16X icon in the menu bar. The panel says when the keys need permission and opens the right page in System Settings.
2. In **System Settings → Privacy & Security → Accessibility**, switch on **Display 16X**. If it isn't listed, click **+** and choose it from Applications.
3. Close the panel and open it again.

macOS gives the permission to the app's signature.

**After an update where either version is ad hoc signed, as every release so far is:** the list still shows Display 16X switched on, but the permission belongs to the version you replaced, so the keys do nothing. Select the **Display 16X** entry, remove it with **−**, add the app again with **+**, then close and open the panel. The same goes for builds you make yourself.

**Between releases signed with the project certificate:** every one has the same signature, so the permission carries over and there is nothing to do. If the keys stop working after such an update although Display 16X is still switched on, remove the entry and add the app again as above, and please [open an issue](https://github.com/engrmnaveed/macdisplay-16x/issues), because this should not happen.

To see how the installed app is signed, run:

```sh
codesign -d -r- "/Applications/Display 16X.app"
```

A requirement that starts with `identifier "com.16xbrains.macdisplay16x" and certificate leaf` means the project certificate, and it is the same for every release. One that starts with `anchor apple generic` means a Developer ID. One that names a `cdhash` means ad hoc.

## Remove Display 16X

1. If you switched on opening at login in the app's settings window, switch it off there first, so macOS has no login item left pointing at a missing app.
2. If you used the Advanced features, remove what they left outside the app's folder while the app still runs. Removing the app does not do it, and `brew uninstall --zap` does not either. Each command prints what it will do, and asks for your administrator password with `--confirm`:
   - `display16x virtual discard all --confirm` discards your virtual screens and the color profiles macOS made for them.
   - `display16x override delete all --confirm` removes every display override Display 16X wrote. Then replug those displays, or log out and in, so macOS stops offering the added sizes. This one also works when the app is not running, as long as the app is still installed.
   - If a full reset moved macOS's saved display arrangements aside, `display16x override put-back --confirm` puts them back.
3. Quit Display 16X from its panel. Changes made over DDC, such as brightness and volume, stay in the monitor.
4. Remove the app:
   - **Homebrew:** `brew uninstall --cask display16x`. Add `--zap` to also remove the settings folder.
   - **ZIP:** move **Display 16X.app** from Applications to the Trash, and remove the link you made, for example `rm ~/.local/bin/display16x`.
5. The settings are one folder. To remove them by hand:

   ```sh
   rm -rf ~/Library/Application\ Support/com.16xbrains.macdisplay16x
   ```

6. In **System Settings → Privacy & Security → Accessibility**, select **Display 16X** and remove it with **−**.

## Build from source

You need the Command Line Tools (`xcode-select --install`). Xcode is not required.

```sh
swift build
swift test
scripts/package-macos.sh
open "dist/Display 16X.app"
```

The app in `dist` is ad hoc signed for local use, so the Accessibility permission has to be given again after each rebuild. The [README](../README.md#build-and-run) says how to keep it with a certificate of your own, and the [release runbook](release.md) how releases are made.
