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

This release is signed with Apple Developer ID and notarized, with tickets stapled to the app and DMG. Gatekeeper checks stay enabled, including for Homebrew installations. If macOS rejects the app, stop and investigate; do not clear quarantine or bypass a warning.

Glint asks for **Screen Recording** permission the first time you capture. Allow it in System Settings > Privacy & Security, then relaunch Glint. Developer ID updates use the same signing requirement to preserve the permission.

## Update an existing installation

Glint does not install updates automatically. Save your work and quit Glint first.

**Homebrew:** run `brew update && brew upgrade --cask glint`, then reopen Glint. `brew update` alone does not upgrade the app. The new version becomes available once the Homebrew tap has been updated after this release.

**Manual download:** download the ZIP or DMG and its matching `.sha256` file from this release. Follow the verification steps in **Install** above before extracting or opening the download and replacing Glint.app in Applications, then reopen it. Preferences, presets and saved images are stored separately.

**Updating from 1.5.3 or earlier to 1.5.4 or later:** the transition from legacy signing to Developer ID changes the signing requirement, so macOS needs Screen Recording permission once more. Choose **Re-authorize Screen Recording…** in Glint's Preferences → About, allow Glint in System Settings, then relaunch Glint. If macOS cannot reset the old entry, Glint explains how to remove it and add it back manually. Subsequent Developer ID updates are expected to keep the permission.

[Changelog](https://github.com/MrAshRhodes/glint/blob/v@VERSION@/CHANGELOG.md) · [Product site](https://mrashrhodes.github.io/glint/) · [User and update guide](https://mrashrhodes.github.io/glint/guide.html#updates)
