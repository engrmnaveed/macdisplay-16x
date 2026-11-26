# Release runbook

A release is a tag. Pushing `vX.Y.Z` that matches [scripts/release-version](../scripts/release-version) runs **Release** ([release.yml](../.github/workflows/release.yml)), which builds, signs and archives the app, waits for the owner's approval, publishes the GitHub Release and updates the Homebrew cask. It works the same way as Space 16X, so the steps below are the same for both projects.

**Every milestone is a release.** When a milestone is merged into `main`, its version is released: 0.2.0 for v0.2, 0.3.0 for v0.3, and so on. A fix between milestones is a patch version, such as 0.2.1. A release takes two steps: [prepare](#1-prepare-the-version) the version in a pull request, then [tag](#2-tag-the-merged-version) the merged commit.

Every release so far is ad hoc signed, because the project certificate does not exist yet. See [Signing](#signing) for what that costs users and what changes the release after the certificate is made.

## 1. Prepare the version

1. Wait until the milestone is merged into `main` and CI has passed there. Cut a branch from it, such as `release/0.6.0`, in a clean checkout.
2. Run the prepare step:

   ```sh
   scripts/prepare-release 0.6.0
   ```

   It writes the version to `scripts/release-version`, renames the `## Unreleased` section of [CHANGELOG.md](../CHANGELOG.md) to `## 0.6.0` with a new, empty `## Unreleased` above it, and moves the version in the examples of the [installation guide](install.md). It refuses a version that is not later than the current one, a dirty working tree, an empty `## Unreleased` section, and a version that is tagged already. `scripts/release-version` is the only place the version is written: the packaging script reads it for the bundle, and the ReleaseVersion build plugin writes it into the app and the `display16x` tool.
3. Edit the new section for someone who uses the app: one section per release, what changed, and plainly what was checked on hardware and what was not. Between releases, every change adds its entry under `## Unreleased`.
4. If the signing level changes with this release, such as the first release signed with the project certificate, update the signing paragraphs at the top of the [installation guide](install.md) and in the Install section of the [README](../README.md).
5. Preview the release notes. They are the changelog section followed by the standard text about the assets and how the app is signed:

   ```sh
   scripts/release-notes 0.6.0 certificate
   ```

   The second argument is the signing level: `certificate` (the default), `developer-id` or `adhoc`. A third, the tag of the last release, adds the sentence for users whose Accessibility permission does not carry over because the signer changed. The workflow passes both: the level it read back from the signed app, and the last release's tag when the new app does not satisfy its signing requirement.
6. Run the checks CI runs:

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

   `check-version.sh` fails when the bundle, the tool and the version file disagree, or when the changelog has no section for the version. `check-hardened-runtime.sh` fails when the private interfaces resolve differently under the hardened runtime, which notarization needs. Neither changes a display. `smoke-test.sh` and `display16x probe` read every connected monitor over DDC; on a Mac where a copy of Display 16X is in use, leave them to CI. The smoke test ends by starting the app for a few seconds with `scripts/start-check.sh`: in safe mode, with a settings folder of its own in a temporary folder, and it fails if the app crashes, quits or stops answering. Nothing else starts the app, and the unit tests run on fakes, so this is the check that catches a crash at start. Where a copy of Display 16X is running, it is skipped and says so, because a build with a folder of its own does not start next to one.
7. Commit, open a pull request into `main`, and merge it once CI passes.

## 2. Tag the merged version

Once the pull request is merged, and once a build of that commit, or of code that contains it, has run as the copy in daily use on the real displays, tag the tip of `main`. CI starts the app on a runner with no monitor, and the first v0.4 build crashed at start only where one was attached.

```sh
scripts/tag-release 0.6.0 --push
```

It fetches `origin/main` and tags its tip only when that commit holds the version in `scripts/release-version`, a `## 0.6.0` section in the changelog, and a passing **Build, test and package** check, when the tag does not exist yet, and when the `release` environment has `HOMEBREW_TAP_DEPLOY_KEY`, without which Publish would stop. Reading an environment's secret names needs administrator access; without it the script says so and leaves the check to Publish. Without `--push` it makes the tag and prints the command that pushes it. It changes nothing in the working tree, so it can run from any checkout. The tag ruleset lets only the repository's administrators create a `v*` tag. With `tag.gpgSign` set in git, the tag is signed.

## How a tag becomes a release

The pushed tag runs these jobs:

1. **Tag matches scripts/release-version.** Fails unless the tag is `v` followed by the content of `scripts/release-version`, and `CHANGELOG.md` has a section for it.
2. **Same checks as CI.** Runs [ci.yml](../.github/workflows/ci.yml) unchanged: identifiers, build, unit tests, packaging, smoke test with the start of the app, version check, hardened runtime check, the archive, and `brew style` on the cask.
3. **Package, sign and archive**, in the `release-signing` environment, on macOS with the full history (the build number is the commit count). It signs at the level the environment's secrets allow (see [Signing](#signing)), writes `display16x-X.Y.Z-macos-arm64.zip` and its `.sha256` file, unpacks the ZIP with `unzip` as Homebrew does and verifies the signature and the version. It then starts the unpacked, signed app with `scripts/start-check.sh`, as the smoke test starts CI's own build, and stops if it crashes at start. It reads the signing level back from the signed app and stops if it is not the level it meant, so the cask's caveats and the release notes always describe the level users get. The run summary shows the signing level, the designated requirement and the digest. It compares the app with the published release just below this version, and warns when the designated requirement no longer matches that release's, because users would then lose the Accessibility grant and Homebrew's first-launch approval. It also warns when a lower version is tagged but not published, such as one whose run still waits for approval. The ZIP is kept as the run's artifact `display16x-macos-arm64`, with the notary log when the app was notarized.
4. **Publish**, in the `release` environment. It waits here for a required reviewer. Before you approve, read the run summary and, if you like, download the artifact and try it. After approval it:
   - checks that `HOMEBREW_TAP_DEPLOY_KEY` is set and can write to [engrmnaveed/homebrew-tap](https://github.com/engrmnaveed/homebrew-tap), and stops before anything is published if it cannot. Users install with Homebrew, so a release the tap does not get is not published,
   - checks the archive's digest again, renders the cask with `scripts/render-cask` and the notes with `scripts/release-notes`,
   - attests build provenance for the ZIP,
   - runs `gh release create --verify-tag` with the ZIP, its `.sha256` file and `display16x.rb`, titled "Display 16X vX.Y.Z", with the notes. It is marked as the latest release unless a later version is published already. With immutable releases on, its assets and its tag cannot be changed afterwards; its title and notes can still be edited,
   - commits `Casks/display16x.rb` to the tap with the deploy key, unless a later version is published already, whose cask the tap keeps. The tap is shared with DiskUse16x, so when one of its commits lands at the same moment, the job starts again from the tap as it is, up to three times. If the push still fails, the job fails, and the cask is [committed by hand](#commit-the-cask-by-hand).
5. **Install from the tap** ([tap-install.yml](../.github/workflows/tap-install.yml)), on a macOS runner that has never had Display 16X. It runs `brew install --cask engrmnaveed/tap/display16x`, the command the guides give users, checks that Homebrew, the app and the linked `display16x` command all say the version the tap should hold, then removes the app with `brew uninstall --cask --zap`. It is the step that proves users can install the release. See [When Install from the tap fails](#when-install-from-the-tap-fails).
6. **Why the release did not finish.** Runs only when Publish or Install from the tap did not succeed, and only reads. It writes to the run summary whether a release exists for the tag, which jobs failed or were cancelled, and, for a job GitHub found no runner for, how to run it again. See [If a job fails or never starts](#if-a-job-fails-or-never-starts).

**What the reviewer sees and clicks.** GitHub sends the reviewer a notification that a deployment to `release` waits for review. In the run (**Actions → Release →** the run for the tag), the summary lists the signing level, the designated requirement and the archive's SHA-256, and the artifact `display16x-macos-arm64` can be downloaded. An ad hoc build also shows the warning that it is not signed with the project certificate. Click **Review deployments**, tick **release**, and click **Approve and deploy**. **Reject** stops the run with nothing published. A pending review expires after 30 days.

**When two runs wait.** They can be approved in either order. The higher version stays the latest release and keeps the tap: a version approved after a later one is published is not marked as the latest and leaves the tap alone. That holds for tags from 0.3.0 on, because a run uses the workflow at its own tag. A release is compared with the release published just below it, so a lower version that is still waiting is left out of the comparison, and the run says so under **Earlier version not published**. That matters only when the two are signed differently, such as the last ad hoc release and the first one signed with the certificate. Then approve the lower one first, or, if it is published second, the higher release's notes lack the sentence about the Accessibility grant: print the notes with it, such as `scripts/release-notes 0.6.0 certificate v0.5.0` when 0.5.0 was the last ad hoc release, and replace them with `gh release edit v0.6.0 --notes-file` and that text.

### If a job fails or never starts

If a job fails before **Publish**, nothing is published. Fix the cause on `main`, delete the tag if your rules allow it, and tag again, or move on to the next patch version. Once **Publish** has created the release, the version is used up: fix forward with the next patch version.

A job can also end without running at all. When GitHub has no runner for it, most often a macOS one, the job waits and is then cancelled, with the annotation "The job was not acquired by Runner of type hosted even after multiple attempts". 0.3.0's packaging job was cancelled that way after 15 minutes. Nothing was signed or published, and nothing needs undoing. The last job, **Why the release did not finish**, says so in the run summary. Run it again from the run's page with **Re-run failed jobs**, or:

```sh
gh run rerun RUN_ID --failed
```

It runs the cancelled job and the jobs after it again, keeps the jobs that passed, and asks for the approval of **Publish** again. The tag stays as it is. The signer comparison runs again too, against the releases published by then. GitHub offers no setting for how long a hosted job may wait, so if runners stay short, re-run later; [githubstatus.com](https://www.githubstatus.com) says when GitHub Actions is degraded.

The run itself installs the release from the tap on a clean Mac. To try it on your own Mac as well, install it with Homebrew where no other copy of Display 16X is running, and open it once. Two copies must not run at once, because they share the settings folder and the command socket. With the first two releases signed with the project certificate, also do the [check across an update](#check-the-first-two-releases).

## Check the first two releases

The checks above prove that the signing requirement stays the same from release to release. They cannot prove what macOS and Homebrew do with it at a real update: that the Accessibility permission stays granted, and that the first launch is not blocked again. Check it once, with the first two releases signed with the project certificate, on your own Mac. The ad hoc releases do not count: the two are the first release whose run summary gives the signing level `certificate`, and the release after it, which can be a patch release.

**Before the first release:**

1. Quit every development copy of Display 16X, such as one started from `dist/`. Two copies must not run at once: they share the settings folder and the socket of the command line tool.
2. In **System Settings → Privacy & Security → Accessibility**, remove every **Display 16X** entry with **−**. Development builds are ad hoc signed under the same bundle identifier, and a leftover entry would spoil the result.

**With the first release:**

3. In the run summary, check that the signing level is `certificate` and that the designated requirement ends with `certificate leaf = H"…"`, where the hash is the certificate's SHA-1 fingerprint you recorded (lowercase, without colons).
4. Install it with `brew install --cask engrmnaveed/tap/display16x` and open it. macOS blocks the first launch. Allow it with **Open Anyway** in Privacy & Security, as users do, not with `xattr`.
5. Grant Accessibility from the panel. Check that the brightness and volume keys change a monitor and show the indicator.
6. Note the requirement of the installed app:

   ```sh
   codesign -d -r- "/Applications/Display 16X.app"
   ```

**With the second release:**

7. In the run summary, the step **Same signer as the last release** says this release satisfies the designated requirement of the first, and there is no **Signer changed** line.
8. Leave Display 16X running and upgrade it:

   ```sh
   brew update
   brew upgrade --cask display16x
   ```

   Homebrew quits the app, replaces it and opens it again. It must not print that the signer changed or that macOS may prompt, and macOS must not block the reopened app.
9. Without opening System Settings, press the brightness and volume keys. They work, the indicator shows, and the Accessibility list still has one **Display 16X** entry, switched on.
10. `codesign -d -r- "/Applications/Display 16X.app"` prints the same requirement as in step 6.

If all of this holds, the permission across an update is proven: record it in the [domain log](domain-log.md) with the Mac, the macOS build and the Homebrew version. If the keys stopped working or the launch was blocked, note which and the exact messages, get the keys back by removing the **Display 16X** entry and adding the app again, and log it, because the guides and the cask's caveats then promise something that does not happen.

## One-time GitHub settings

These live on GitHub, not in the repository. Set them before the first tag.

- **Settings → Environments → `release`:** add yourself, or the release owners, as required reviewers. Under deployment branches and tags, allow only tags matching `v*`. Without a reviewer, a tag push publishes at once. Add the `HOMEBREW_TAP_DEPLOY_KEY` secret here, as described under [Add the deploy key](#add-the-deploy-key). No release is published without it.
- **Settings → Environments → `release-signing`:** allow only tags matching `v*`, and add the project certificate's three secrets (see [Project certificate](#project-certificate)). A required reviewer here is optional: it gates signing as well, at the cost of a second approval per release. Without the environment, the workflow creates it empty on the first run and signs ad hoc.
- **Settings → Rules → Rulesets:** protect tags matching `v*` from creation, update and deletion by anyone outside the release owners. Protect `main` with required pull requests and the CI check **Build, test and package**.
- **Settings → General → Releases:** enable immutable releases, so a published release's assets and tag cannot be replaced.
- **Settings → Security → Private vulnerability reporting:** enable it so people can report a vulnerability privately.

## Signing

The Accessibility permission for the brightness and volume keys belongs to the app's code signature, more exactly to its designated requirement. Homebrew uses the same requirement to decide whether an upgrade keeps the user's first-launch approval. So the signing level decides what users go through at every update.

Releases are signed with one project certificate ([decision 12](roadmap.md#5-open-decisions), 23 November 2026). A Developer ID with notarization replaces it once the Apple Developer Program membership is there. Ad hoc remains as the fallback the workflow uses when `release-signing` holds no certificate, with a warning.

**Where it stands:** the certificate has not been made yet, so every release so far is ad hoc signed. For the next release to be signed with it, the owner does the seven [project certificate](#project-certificate) steps before tagging, and the release's pull request updates the signing paragraphs of the guides. The first release signed with it costs the users of the last ad hoc release their Accessibility grant and first-launch approval once more, and its release notes say so on their own. From then on both carry over.

| Level | Chosen when `release-signing` holds | First launch | After an update |
| --- | --- | --- | --- |
| Project certificate (decided) | a certificate, and no notary API key | Allowed once by hand in Privacy & Security | Accessibility stays granted. `brew upgrade` keeps the approval; a new direct download is allowed again by hand |
| Developer ID, notarized (later) | a Developer ID Application certificate and the notary API key | Opens normally | Accessibility stays granted |
| Ad hoc (fallback) | no certificate | Allowed by hand in Privacy & Security | Allowed by hand again, and Accessibility granted again: remove the old entry, add the new one |

The level can change between releases. Changing from one certificate to another, or from the project certificate to a Developer ID, costs users their Accessibility grant once. The build job warns about it, and the release notes of that version should say so.

### Project certificate

No Apple membership needed. One long-lived self-signed code signing certificate signs every release, so the designated requirement stays `identifier "com.16xbrains.macdisplay16x" and certificate leaf = H"…"` from release to release. This was checked: two different builds signed with one self-signed certificate had the identical requirement, and the second satisfied the first's, which is the test Homebrew applies at an upgrade. Whether macOS keeps the Accessibility permission across a real update is checked with the [first two releases](#check-the-first-two-releases).

> **Make it once, and never again.** The requirement names this exact certificate. A renewed, replaced or lost certificate is a different one, and every user then has to grant Accessibility again. So it is made valid for 20 years, backed up outside GitHub, and never created again. Guard the private key like a password: anyone who has it can sign an app that macOS treats as Display 16X, including the Accessibility permission users gave it. If it ever leaks, make a new one, sign the next release with it, and say in that release's notes that users have to grant Accessibility again.

The owner's steps, once, on a Mac you trust. They need the GitHub CLI signed in with access to the repository, and the `release-signing` environment created first (see [One-time GitHub settings](#one-time-github-settings)).

1. Work in a new folder outside the repository:

   ```sh
   mkdir ~/display16x-certificate && cd ~/display16x-certificate
   ```

2. Create the certificate and its private key, valid for 20 years. Use the system's `/usr/bin/openssl`: a PKCS#12 file from OpenSSL 3 or later uses an encryption that the macOS `security` tool may not import.

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
   ```

3. Note its fingerprint and end date. The SHA-1 fingerprint, in lowercase without colons, is the hash every release's requirement names after `certificate leaf =`, so each run summary can be compared with it.

   ```sh
   /usr/bin/openssl x509 -in display16x-release.pem -noout -subject -enddate -fingerprint -sha1
   ```

4. Export the certificate and the key together as a PKCS#12 file. It asks for an export password twice: use a long generated one from your password manager. Then check that the file opens with it; it prints `MAC verified OK`.

   ```sh
   /usr/bin/openssl pkcs12 -export -name "Display 16X Release" \
     -inkey display16x-release.key -in display16x-release.pem -out display16x-release.p12
   /usr/bin/openssl pkcs12 -in display16x-release.p12 -noout
   ```

5. Back it up before anything else. Store `display16x-release.p12`, its export password and the fingerprint in your password manager, and keep a second copy offline, such as on an encrypted disk. The `.p12` file holds both the certificate and the key.
6. Set the three secrets in the `release-signing` environment. The second command asks for the value: paste the export password.

   ```sh
   base64 -i display16x-release.p12 | gh secret set MACOS_CERTIFICATE_BASE64 --env release-signing --repo engrmnaveed/macdisplay-16x
   gh secret set MACOS_CERTIFICATE_PASSWORD --env release-signing --repo engrmnaveed/macdisplay-16x
   gh secret set MACOS_SIGN_IDENTITY --env release-signing --repo engrmnaveed/macdisplay-16x --body 'Display 16X Release'
   ```

   Do not set the three `APPLE_API_KEY` secrets: with them, the workflow switches to the Developer ID level.
7. Delete the local files once the backup is safe:

   ```sh
   cd ~ && rm -r ~/display16x-certificate
   ```

The next tag is signed with it. The run summary then says `certificate` and shows the fingerprint in the designated requirement.

Keychain Access (in `/System/Library/CoreServices/Applications` on recent macOS) → Certificate Assistant → Create a Certificate, with identity type Self Signed Root, certificate type Code Signing and "Let me override defaults" for a 20 year validity, makes an equivalent certificate, which is then exported as `.p12`. It leaves the key in that Mac's login keychain, so the steps above are preferred.

The release is not notarized at this level, so Gatekeeper still asks users to allow the first launch once.

### Developer ID

For later, with a membership in the Apple Developer Program.

1. Create a **Developer ID Application** certificate in the Apple Developer account, install it on a Mac, and export it with its private key from Keychain Access as a `.p12` file with a password.
2. In App Store Connect, under Users and Access → Integrations, create a team API key for the notary service and download its `.p8` file. Note the key ID and the issuer ID.
3. Replace the three certificate secrets in `release-signing` with the Developer ID's and add the three `APPLE_API_KEY` secrets. Keep the project certificate's backup.

The workflow signs a copy of the app inside out with the hardened runtime and a secure timestamp, checks that the private interfaces resolve as they do without the hardened runtime, notarizes it, staples the ticket and checks it with `spctl`. On the developer's Mac, a build signed ad hoc with the hardened runtime gave the same probe results as one without it, private interfaces and DDC replies alike, and passed the smoke test. The menu bar app itself has never run with the hardened runtime: open it after the first notarized build and check the controls and the keys. The change from the project certificate costs users the Accessibility grant once.

### Ad hoc

Nothing to set: with no certificate in `release-signing`, the workflow signs ad hoc and warns that it did. Every build has a new signature, so users allow the first launch and grant Accessibility again after every update. Use it only when the certificate is not available.

### Secrets for each level

All of them are secrets of the `release-signing` environment. The names are the same as Space 16X's.

| Secret | Project certificate | Developer ID | Ad hoc |
| --- | --- | --- | --- |
| `MACOS_CERTIFICATE_BASE64` | The project certificate and its private key, exported as PKCS#12, then base64 | The Developer ID Application certificate and its private key, exported as PKCS#12, then base64 | Not set |
| `MACOS_CERTIFICATE_PASSWORD` | The export password of that PKCS#12 file | The export password of that PKCS#12 file | Not set |
| `MACOS_SIGN_IDENTITY` | `Display 16X Release`, the certificate's name | The full identity, `Developer ID Application: Name (TEAMID)` | Not set |
| `APPLE_API_KEY_BASE64` | Not set | The App Store Connect API key file (`AuthKey_….p8`), base64 | Not set |
| `APPLE_API_KEY_ID` | Not set | The key's ID | Not set |
| `APPLE_API_ISSUER` | Not set | The issuer ID | Not set |

The `release` environment holds `HOMEBREW_TAP_DEPLOY_KEY` at every level.

## Homebrew tap

The cask is published through the public tap [engrmnaveed/homebrew-tap](https://github.com/engrmnaveed/homebrew-tap), next to DiskUse16x's (called Space 16X before its 1.0), so users run `brew install --cask engrmnaveed/tap/display16x`. Homebrew's official cask repository only accepts apps that pass Gatekeeper, which needs the Developer ID level. The template is [packaging/homebrew/display16x.rb.in](../packaging/homebrew/display16x.rb.in): it installs the app, links the `display16x` command, requires Apple silicon and macOS 14, quits the app before an upgrade (Homebrew reopens it afterwards), and its `zap` removes the app's settings folder. `scripts/render-cask VERSION SHA256 SIGNING` fills it in, with caveats about the first launch and Accessibility that depend on the signing level.

### Add the deploy key

Once, on a Mac with the GitHub CLI:

1. Make a key pair for this repository alone, so it can be revoked without touching DiskUse16x's:

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

**Each release:** the publish job commits `Casks/display16x.rb` to the tap after creating the release, and **Install from the tap** then installs it from there.

**Without the key, or with a key that cannot write:** `scripts/tag-release` refuses to tag while the secret is missing, and Publish stops at its first step, before anything is published, with the reason in the run summary. Add or replace the key as above, then use **Re-run failed jobs** on the run. Publish asks for approval again. From 0.2.0 to 0.5.0 a missing key only left a warning and the runs passed, so the tap never had the cask until 0.5.0's was committed by hand on 26 November 2026.

### Commit the cask by hand

When Publish created the release but its push to the tap failed, commit the release's `display16x.rb` yourself, here for 0.5.0. The tap holds one version, so only the newest release needs it:

```sh
gh repo clone engrmnaveed/homebrew-tap && cd homebrew-tap
gh release download v0.5.0 --repo engrmnaveed/macdisplay-16x --pattern display16x.rb --output Casks/display16x.rb --clobber
git add Casks/display16x.rb && git commit -m "display16x 0.5.0" && git push
```

Then check it the way the release does:

```sh
gh workflow run tap-install.yml --repo engrmnaveed/macdisplay-16x -f version=0.5.0
```

### When Install from the tap fails

The release and the tap's commit exist by then, so look at what users get before anything else. The job's log has brew's own output:

- **"Cask 'display16x' is unavailable" or "does not exist":** the tap has no `Casks/display16x.rb`. [Commit the cask by hand](#commit-the-cask-by-hand).
- **The tap installed another version:** a later release holds the tap, or the push did not land. Compare `Casks/display16x.rb` in the tap with the release's `display16x.rb`.
- **A checksum mismatch or a failed download:** the cask in the tap does not match the release's ZIP. Commit the release's own `display16x.rb` by hand, which carries the ZIP's digest.
- **The app or the `display16x` command says another version, or a signature does not verify:** the published ZIP is wrong. Its assets cannot be replaced, so fix forward with the next patch version.
- **The job never got a runner:** **Re-run failed jobs**. Nothing else runs again.

After a fix, run `gh workflow run tap-install.yml --repo engrmnaveed/macdisplay-16x -f version=X.Y.Z` to check again.

## Sign and notarize on a Mac

For a Developer ID build outside the workflow. Install the Developer ID Application identity in a keychain and store notary credentials in a keychain profile with `xcrun notarytool store-credentials`. `notarytool` and `stapler` come with the Command Line Tools.

```sh
scripts/package-macos.sh
MACOS_SIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
NOTARY_PROFILE='display16x-notary' \
  scripts/notarize-macos.sh "dist/Display 16X.app"
```

The script signs a copy, so the input bundle stays available for local checks, and writes the ZIP, its checksum and `dist/macos-notary-log.json`.

To check a build under the hardened runtime without any certificate, sign it ad hoc with the runtime and run the smoke test, which also starts the app where no copy is running:

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
