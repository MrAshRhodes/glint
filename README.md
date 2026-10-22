<p align="center"><img src="docs/assets/icon-1024.png" width="128" alt="Glint icon"></p>

# Glint

Open-source screenshot beautifier for macOS. Capture an area, window or screen, then turn it into a polished image with backgrounds, padding, shadows, annotations and automatic redaction of sensitive text. Everything runs locally. Nothing is uploaded.

Glint is an independent project, released under the MIT license. It is not affiliated with or endorsed by any other screenshot product.

**[Product site](https://mrashrhodes.github.io/glint/)** · **[User guide](https://mrashrhodes.github.io/glint/guide.html)** · **[Releases](https://github.com/MrAshRhodes/glint/releases/latest)** · **[Changelog](CHANGELOG.md)**

## Install

```sh
brew tap MrAshRhodes/tap
brew install --cask glint
```

Or install manually from the [Releases](https://github.com/MrAshRhodes/glint/releases) page. Download `Glint-<version>.zip` and its matching `Glint-<version>.zip.sha256` from the same release. For a DMG instead, download `Glint-<version>.dmg` and `Glint-<version>.dmg.sha256`. Keep the pair in the same folder without renaming either file.

Before extracting the ZIP or opening the DMG, open Terminal and change to that folder (for example, `cd ~/Downloads`). Replace `<version>` with the downloaded release's version and run **only the command for your chosen format**:

**ZIP:**

```sh
shasum -a 256 -c "Glint-<version>.zip.sha256"
```

**DMG (instead of ZIP):**

```sh
shasum -a 256 -c "Glint-<version>.dmg.sha256"
```

Continue only if the command succeeds and reports `Glint-<version>.zip: OK` (or `Glint-<version>.dmg: OK`). **If verification fails for any reason, including a mismatch or a missing archive or checksum, stop. Do not install the app or clear quarantine.** Download the matching pair again from the official release and verify again.

After successful verification, extract the ZIP or open the DMG and drag `Glint.app` to `/Applications`. A matching checksum confirms agreement with the published checksum; it is not notarization or proof that the app is safe.

The app is ad-hoc signed, not notarized. The Homebrew cask clears the quarantine flag for you. If you trust the release, have successfully verified the manual download, and macOS blocks its first launch, run `xattr -dr com.apple.quarantine /Applications/Glint.app`. This bypasses the app's Gatekeeper quarantine check; do not ignore a malware warning.

Requires macOS 14 or later. On first launch grant **Screen Recording** permission (System Settings → Privacy & Security).

## Updates

Glint does **not** automatically download or install updates. **Check for Updates…** in the menu bar (also in Preferences → About) checks GitHub for a newer release and explains how to install it.

For a Homebrew installation, save your work, quit Glint, then run:

```sh
brew update && brew upgrade --cask glint
```

Reopen Glint afterward. `brew update` refreshes Homebrew's package list; only `brew upgrade` installs the newer app. A release must also be published to the Homebrew tap before it appears there.

For a manual installation, save your work and quit Glint, then download the latest ZIP or DMG and its matching `.sha256` file. Follow the [verification steps above](#install) before extracting or opening the download and replacing `/Applications/Glint.app`, then reopen Glint. Your separately stored preferences, presets and images remain in place. Ad-hoc signing means macOS may require Screen Recording permission again after an update. See the [update guide](https://mrashrhodes.github.io/glint/guide.html#updates).

## Features

- **Capture**: area (crosshair overlay), window picker, full screen, repeat last area, timer (3/5/10 s), capture text (OCR to clipboard). OCR notifications confirm copying without previewing recognized text. Multi-display and Retina aware.
- **Global hotkeys**: ⌃⌥⌘4 area to editor, ⌃⌥⌘5 area to clipboard, ⌃⌥⌘6 window, ⌃⌥⌘3 full screen, ⌃⌥⌘7 OCR, ⌃⌥⌘R repeat last area. All rebindable.
- **Beautify**: 32 built-in backgrounds (gradients, mesh, patterns, solid, transparent, your own image), padding, inset, corner radius, two-layer shadow, 3D tilt, rotate/flip, window frames, watermark.
- **Desktop wallpaper**: check **Use desktop wallpaper** in the Background controls to use your system wallpaper without importing a file. Preview and export share the same image; uncheck it to restore your previous background. See [wallpaper behavior and limitations](https://mrashrhodes.github.io/glint/guide.html#desktop-wallpaper).
- **Auto-balance**: detects uniform borders and balances the margins.
- **Aspect ratios**: auto, 1:1, 4:3, 3:2, 16:9, 9:16, 4:5, and social presets, plus custom.
- **Annotations**: arrow, line, rectangle, ellipse, pen, highlighter, text, numbered counters, and a **Redact / Obfuscate** tool. Each image starts in Solid redaction mode. Blur and pixelate are obfuscation only: information may be recoverable, so they are unsafe for secrets. Undo/redo, z-order, per-object styling.
- **Auto-redact**: on-device Vision OCR finds emails, phone numbers, credit cards (Luhn-checked), IP addresses, API keys and tokens, and covers detected regions with fully opaque solid fill, regardless of the manual tool mode. Solid redaction replaces the covered pixels in the exported image. Detection can miss information: review before sharing. Original images and saved raw captures are not erased.
- **Presets**: save, apply and set a default look.
- **Export**: PNG, JPEG, HEIC, TIFF; 1x/2x; clipboard; Save As; share sheet; drag out. Optional raw and output folders.
- **Safe retry**: failed exports keep the image and annotations in the editor with a **Retry** action. If capture auto-redaction or rendering fails, choose **Retry** or **Discard Capture**. Recovery stays in memory while the editor or prompt is open; it never creates an unredacted backup or bypasses redaction.
- **Automation**: `glint://capture-area`, `capture-window`, `capture-fullscreen`, `capture-text`, `repeat-last`, `open?file=…`, and a CLI. Every capture URL requires confirmation before Glint captures, saves or copies anything, even with Screen Recording permission. Cancel leaves the screen uncaptured; there is no "always allow" option. Capture URLs received while confirmation or capture is in progress are rejected, not queued; send a new request afterward. Menu/hotkey captures, non-capture URLs and CLI rendering are unchanged:

```sh
Glint.app/Contents/MacOS/Glint --render in.png out.png --preset "Social 16:9" --scale 2
Glint.app/Contents/MacOS/Glint --list-presets
Glint.app/Contents/MacOS/Glint --diagnose
```

`--diagnose` checks Screen Recording permission without requesting access and prints only permission state,
aggregate display/window/application counts, and fixed status messages. It does not print window titles,
app identities, process/window/display identifiers, or per-display details. Review reports before sharing:
aggregate counts still describe your desktop activity.

## Build from source

```sh
make app        # dist/Glint.app
make universal  # arm64 + x86_64
make test
make run
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for architecture and environment notes.

## License

MIT. See [LICENSE](LICENSE).
