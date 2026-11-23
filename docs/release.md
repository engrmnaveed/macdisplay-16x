# Release runbook

A release is a tag. Pushing `vX.Y.Z` that matches [scripts/release-version](../scripts/release-version) runs **Release** ([release.yml](../.github/workflows/release.yml)), which builds, signs and archives the app, waits for the owner's approval, publishes the GitHub Release and updates the Homebrew cask. It works the same way as Space 16X, so the steps below are the same for both projects.

## Before a release

1. Merge the work into `main` and wait for CI to pass there.
2. Set the version in `scripts/release-version`. It is the only place the version is written: the packaging script reads it for the bundle, and the ReleaseVersion build plugin writes it into the app and the `display16x` tool. Use three numbers, such as `0.1.1`.
3. Give the version its section in [CHANGELOG.md](../CHANGELOG.md), headed `## X.Y.Z`. Write what changed for someone who uses the app. Collect changes under `## Unreleased` between releases and rename the heading when you set the version.
4. Preview the release notes. They are the changelog section followed by the standard text about the assets and how the app is signed:

   ```sh
   scripts/release-notes 0.1.1 certificate
   ```

   The second argument is the signing level, `developer-id`, `certificate` or `adhoc`. The workflow passes the level it actually signed with.
5. Run the checks CI runs, from a clean checkout of `main`:

   ```sh
   scripts/check-identifiers.sh
   swift build
   swift test
   scripts/package-macos.sh
   scripts/smoke-test.sh
   scripts/check-version.sh
   scripts/check-hardened-runtime.sh
   scripts/archive-macos.sh
   ```

   `check-version.sh` fails when the bundle, the tool and the version file disagree, or when the changelog has no section for the version. `check-hardened-runtime.sh` fails when the private interfaces resolve differently under the hardened runtime, which notarization needs. Neither changes a display.
6. Update the version in the examples of the [installation guide](install.md) if they name one.
7. Commit the version, the changelog and the guide to `main` through a pull request.

## How a tag becomes a release

Tag the reviewed commit on `main` and push the tag:

```sh
git tag -s v0.1.1 -m "Display 16X 0.1.1"
git push origin v0.1.1
```

Use `git tag -a` if you do not sign tags. The workflow then runs these jobs:

1. **Tag matches scripts/release-version.** Fails unless the tag is `v` followed by the content of `scripts/release-version`, and `CHANGELOG.md` has a section for it.
2. **Same checks as CI.** Runs [ci.yml](../.github/workflows/ci.yml) unchanged: identifiers, build, unit tests, packaging, smoke test, version check, hardened runtime check, the archive, and `brew style` on the cask.
3. **Package, sign and archive**, in the `release-signing` environment, on macOS with the full history (the build number is the commit count). It signs at the level the environment's secrets allow (see [Signing](#signing)), writes `display16x-X.Y.Z-macos-arm64.zip` and its `.sha256` file, unpacks the ZIP with `unzip` as Homebrew does and verifies the signature and the version. The run summary shows the signing level, the designated requirement and the digest. It warns when the designated requirement no longer matches the last release's, because users would then lose the Accessibility grant and Homebrew's first-launch approval. The ZIP is kept as the run's artifact `display16x-macos-arm64`, with the notary log when the app was notarized.
4. **Publish**, in the `release` environment. It waits here for a required reviewer. Before you approve, read the run summary and, if you like, download the artifact and try it. After approval it:
   - checks the archive's digest again, renders the cask with `scripts/render-cask` and the notes with `scripts/release-notes`,
   - attests build provenance for the ZIP,
   - runs `gh release create --verify-tag` with the ZIP, its `.sha256` file and `display16x.rb`, titled "Display 16X vX.Y.Z", with the notes,
   - commits `Casks/display16x.rb` to [engrmnaveed/homebrew-tap](https://github.com/engrmnaveed/homebrew-tap) with the deploy key, or leaves a notice when `HOMEBREW_TAP_DEPLOY_KEY` is not set.

If a job fails before **Publish**, nothing is published. Fix the cause on `main`, delete the tag if your rules allow it, and tag again, or move on to the next patch version.

After the release, install it with Homebrew on a Mac and open it once. For the first release signed with a certificate or a Developer ID, check with the next release that Accessibility stays granted after `brew upgrade`: that is the one thing the checks above cannot prove.

## One-time GitHub settings

These live on GitHub, not in the repository. Set them before the first tag.

- **Settings → Environments → `release`:** add yourself, or the release owners, as required reviewers. Under deployment branches and tags, allow only tags matching `v*`. Without a reviewer, a tag push publishes at once. Add the `HOMEBREW_TAP_DEPLOY_KEY` secret here.
- **Settings → Environments → `release-signing`:** allow only tags matching `v*`, and add the signing secrets for the level you chose. A required reviewer here is optional: it gates signing as well, at the cost of a second approval per release. Without the environment, the workflow creates it empty on the first run and signs ad hoc.
- **Settings → Rules → Rulesets:** protect tags matching `v*` from creation, update and deletion by anyone outside the release owners. Protect `main` with required pull requests and the CI check **Build, test and package**.
- **Settings → General → Releases:** enable immutable releases, so a published release's assets and tag cannot be replaced.
- **Settings → Security → Private vulnerability reporting:** enable it so people can report a vulnerability privately.

## Signing

The Accessibility permission for the brightness and volume keys belongs to the app's code signature, more exactly to its designated requirement. Homebrew uses the same requirement to decide whether an upgrade keeps the user's first-launch approval. So the signing level decides what users go through at every update.

| Level | Chosen when `release-signing` holds | First launch | After an update |
| --- | --- | --- | --- |
| Developer ID, notarized | a Developer ID Application certificate and the notary API key | Opens normally | Accessibility stays granted |
| Project certificate | a certificate, and no notary API key | Allowed once by hand in Privacy & Security | Accessibility stays granted. `brew upgrade` keeps the approval; a new direct download is allowed again by hand |
| Ad hoc | no certificate | Allowed by hand in Privacy & Security | Allowed by hand again, and Accessibility granted again: remove the old entry, add the new one |

Which level to use is [roadmap decision 12](roadmap.md#5-open-decisions). The workflow works with any of them, and the level can change between releases. Changing from one certificate to another, or from a certificate to a Developer ID, costs users their Accessibility grant once, and the build job warns about it.

### Secrets for each level

All of them are secrets of the `release-signing` environment. The names are the same as Space 16X's.

| Secret | Developer ID | Project certificate | Ad hoc |
| --- | --- | --- | --- |
| `MACOS_CERTIFICATE_BASE64` | The Developer ID Application certificate and its private key, exported as PKCS#12, then base64 | The project certificate and its private key, exported as PKCS#12, then base64 | Not set |
| `MACOS_CERTIFICATE_PASSWORD` | The password of that PKCS#12 file | The password of that PKCS#12 file | Not set |
| `MACOS_SIGN_IDENTITY` | The full identity, `Developer ID Application: Name (TEAMID)` | The certificate's name, or its SHA-1 hash from `security find-identity -p codesigning` | Not set |
| `APPLE_API_KEY_BASE64` | The App Store Connect API key file (`AuthKey_….p8`), base64 | Not set | Not set |
| `APPLE_API_KEY_ID` | The key's ID | Not set | Not set |
| `APPLE_API_ISSUER` | The issuer ID | Not set | Not set |

The `release` environment holds `HOMEBREW_TAP_DEPLOY_KEY` at every level.

Set a secret from a file with the GitHub CLI, for example:

```sh
base64 -i certificate.p12 | gh secret set MACOS_CERTIFICATE_BASE64 --env release-signing --repo engrmnaveed/macdisplay-16x
```

### Developer ID

Needs a membership in the Apple Developer Program.

1. Create a **Developer ID Application** certificate in the Apple Developer account, install it on a Mac, and export it with its private key from Keychain Access as a `.p12` file with a password.
2. In App Store Connect, under Users and Access → Integrations, create a team API key for the notary service and download its `.p8` file. Note the key ID and the issuer ID.
3. Set all six secrets in `release-signing`.

The workflow signs a copy of the app inside out with the hardened runtime and a secure timestamp, checks that the private interfaces resolve as they do without the hardened runtime, notarizes it, staples the ticket and checks it with `spctl`. On the developer's Mac, a build signed ad hoc with the hardened runtime gave the same probe results as one without it, private interfaces and DDC replies alike, and passed the smoke test. The menu bar app itself has never run with the hardened runtime: open it after the first notarized build and check the controls and the keys.

### Project certificate

No Apple membership needed. One long-lived self-signed code signing certificate signs every release, so the designated requirement stays `identifier "com.16xbrains.macdisplay16x" and certificate leaf = H"…"` from release to release. This was checked: two different builds signed with one self-signed certificate had the identical requirement, and the second satisfied the first's requirement, which is the test Homebrew applies at an upgrade.

The requirement names that exact certificate. A renewed or replaced certificate is a different one, and every user loses the grant once. So make it valid for many years, keep a backup of the `.p12` file and its password outside GitHub, and never create it again.

Create it on a Mac with the system's LibreSSL, outside any keychain:

```sh
cat > display16x-release.cnf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Display 16X Release
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 \
  -config display16x-release.cnf -keyout display16x-release.key -out display16x-release.pem
/usr/bin/openssl pkcs12 -export -name "Display 16X Release" \
  -inkey display16x-release.key -in display16x-release.pem -out display16x-release.p12
```

Use `/usr/bin/openssl`: a PKCS#12 file from OpenSSL 3 or later uses an encryption the macOS `security` tool may not import. Then set `MACOS_CERTIFICATE_BASE64` from the `.p12` file, `MACOS_CERTIFICATE_PASSWORD` to its export password and `MACOS_SIGN_IDENTITY` to `Display 16X Release`. Keep the `.key`, `.pem` and `.p12` files in a password manager and delete them from the disk. Keychain Access (in `/System/Library/CoreServices/Applications` on recent macOS) → Certificate Assistant → Create a Certificate, with identity type Self Signed Root, certificate type Code Signing and "Let me override defaults" for a longer validity than one year, makes an equivalent certificate, which is then exported as `.p12`. That puts it in the login keychain of that Mac.

The release is not notarized at this level, so Gatekeeper still asks users to allow the first launch.

### Ad hoc

Nothing to set. Every build has a new signature, so users allow the first launch and grant Accessibility again after every update. The build job says so with a warning.

## Homebrew tap

The cask is published through the public tap [engrmnaveed/homebrew-tap](https://github.com/engrmnaveed/homebrew-tap), next to Space 16X's, so users run `brew install --cask engrmnaveed/tap/display16x`. Homebrew's official cask repository only accepts apps that pass Gatekeeper, which needs the Developer ID level. The template is [packaging/homebrew/display16x.rb.in](../packaging/homebrew/display16x.rb.in): it installs the app, links the `display16x` command, requires Apple silicon and macOS 14, quits the app before an upgrade (Homebrew reopens it afterwards), and its `zap` removes the app's settings folder. `scripts/render-cask VERSION SHA256 SIGNING` fills it in, with caveats about the first launch and Accessibility that depend on the signing level.

### Add the deploy key

Once, on a Mac with the GitHub CLI:

1. Make a key pair for this repository alone, so it can be revoked without touching Space 16X's:

   ```sh
   ssh-keygen -t ed25519 -N '' -C 'macdisplay-16x release' -f display16x-tap
   ```

2. Add the public key to the tap as a deploy key with write access, under **engrmnaveed/homebrew-tap → Settings → Deploy keys → Add deploy key**, titled "macdisplay-16x release", with **Allow write access** ticked. Or:

   ```sh
   gh repo deploy-key add display16x-tap.pub --repo engrmnaveed/homebrew-tap --title 'macdisplay-16x release' --allow-write
   ```

3. Store the private key as `HOMEBREW_TAP_DEPLOY_KEY` in the `release` environment of this repository, then delete both files:

   ```sh
   gh secret set HOMEBREW_TAP_DEPLOY_KEY --env release --repo engrmnaveed/macdisplay-16x < display16x-tap
   rm display16x-tap display16x-tap.pub
   ```

**Each release:** the publish job commits `Casks/display16x.rb` to the tap after creating the release.

**Without the secret:** the job skips the tap and logs a notice. Download `display16x.rb` from the release and commit it to `Casks/display16x.rb` in the tap by hand.

## Sign and notarize on a Mac

For a Developer ID build outside the workflow. Install the Developer ID Application identity in a keychain and store notary credentials in a keychain profile with `xcrun notarytool store-credentials`. `notarytool` and `stapler` come with the Command Line Tools.

```sh
scripts/package-macos.sh
MACOS_SIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
NOTARY_PROFILE='display16x-notary' \
  scripts/notarize-macos.sh "dist/Display 16X.app"
```

The script signs a copy, so the input bundle stays available for local checks, and writes the ZIP, its checksum and `dist/macos-notary-log.json`.

To check a build under the hardened runtime without any certificate or starting the app, sign it ad hoc with the runtime and run the read-only checks:

```sh
DISPLAY16X_HARDENED_RUNTIME=1 scripts/package-macos.sh
scripts/smoke-test.sh
```

For a project certificate kept in a keychain file of its own, outside the login keychain and the search list:

```sh
DISPLAY16X_SIGN_IDENTITY='Display 16X Release' \
DISPLAY16X_SIGN_KEYCHAIN="$HOME/display16x-release.keychain-db" \
  scripts/package-macos.sh
scripts/archive-macos.sh
```

- [Apple: notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [GitHub: installing an Apple certificate on macOS runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [Homebrew: Cask Cookbook](https://docs.brew.sh/Cask-Cookbook) and [Tap Trust](https://docs.brew.sh/Tap-Trust)
