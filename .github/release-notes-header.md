## Install

```sh
brew install --cask mrashrhodes/tap/glint
```

Or download `Glint-@VERSION@.zip` (or the `.dmg`) below and move **Glint.app** to your Applications folder. Each download has a matching `.sha256` file.

Glint is signed ad-hoc and not notarized, so macOS may block the first launch of a manual download. Clear the quarantine flag once, then open the app:

```sh
xattr -dr com.apple.quarantine /Applications/Glint.app
```

Glint asks for **Screen Recording** permission the first time you capture. Allow it in System Settings > Privacy & Security, then relaunch Glint.

## Update an existing installation

Glint does not install updates automatically. Save your work and quit Glint first.

**Homebrew:** run `brew update && brew upgrade --cask glint`, then reopen Glint. `brew update` alone does not upgrade the app. The new version becomes available once the Homebrew tap has been updated after this release.

**Manual download:** replace Glint.app in Applications with the new copy from this release, then reopen it. Preferences, presets and saved images are stored separately. macOS may ask for Screen Recording permission again because the app is ad-hoc signed.

[Product site](https://mrashrhodes.github.io/glint/) · [User and update guide](https://mrashrhodes.github.io/glint/guide.html#updates)
