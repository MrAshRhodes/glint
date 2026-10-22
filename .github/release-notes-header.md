## Install

```sh
brew install --cask mrashrhodes/tap/glint
```

Or download `Glint-@VERSION@.zip` and its matching `Glint-@VERSION@.zip.sha256` below. For a DMG instead, download `Glint-@VERSION@.dmg` and `Glint-@VERSION@.dmg.sha256`. Keep the pair from this release in the same folder without renaming either file.

Before extracting the ZIP or opening the DMG, open Terminal and change to that folder (for example, `cd ~/Downloads`). Run **only the command for your chosen format**:

**ZIP:**

```sh
shasum -a 256 -c "Glint-@VERSION@.zip.sha256"
```

**DMG (instead of ZIP):**

```sh
shasum -a 256 -c "Glint-@VERSION@.dmg.sha256"
```

Continue only if the command succeeds and reports `Glint-@VERSION@.zip: OK` (or `Glint-@VERSION@.dmg: OK`). **If verification fails for any reason, including a mismatch or a missing archive or checksum, stop. Do not install the app or clear quarantine.** Download the matching pair again from this official release and verify again.

After successful verification, extract the ZIP or open the DMG and move **Glint.app** to your Applications folder. A matching checksum confirms agreement with the published checksum; it is not notarization or proof that the app is safe.

Glint is signed ad-hoc and not notarized, so macOS may block the first launch of a manual download. Only if you trust this release and have successfully verified the download, clear the quarantine flag if needed, then open the app:

```sh
xattr -dr com.apple.quarantine /Applications/Glint.app
```

This bypasses the app's Gatekeeper quarantine check; do not ignore a malware warning.

Glint asks for **Screen Recording** permission the first time you capture. Allow it in System Settings > Privacy & Security, then relaunch Glint.

## Update an existing installation

Glint does not install updates automatically. Save your work and quit Glint first.

**Homebrew:** run `brew update && brew upgrade --cask glint`, then reopen Glint. `brew update` alone does not upgrade the app. The new version becomes available once the Homebrew tap has been updated after this release.

**Manual download:** download the ZIP or DMG and its matching `.sha256` file from this release. Follow the verification steps in **Install** above before extracting or opening the download and replacing Glint.app in Applications, then reopen it. Preferences, presets and saved images are stored separately. macOS may ask for Screen Recording permission again because the app is ad-hoc signed.

[Changelog](https://github.com/MrAshRhodes/glint/blob/v@VERSION@/CHANGELOG.md) · [Product site](https://mrashrhodes.github.io/glint/) · [User and update guide](https://mrashrhodes.github.io/glint/guide.html#updates)
