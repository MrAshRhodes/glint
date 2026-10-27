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

Releases are signed with Glint's own certificate, not an Apple Developer ID, so they are not notarized. The Homebrew cask clears the quarantine flag for you. If you trust the release, have successfully verified the manual download, and macOS blocks its first launch, run `xattr -dr com.apple.quarantine /Applications/Glint.app`. This bypasses the app's Gatekeeper quarantine check; do not ignore a malware warning.

Requires macOS 14 or later. On first launch grant **Screen Recording** permission (System Settings → Privacy & Security). Every release is signed with the same certificate, so macOS keeps the permission when you update.

## Updates

Glint does **not** automatically download or install updates. **Check for Updates…** in the menu bar (also in Preferences → About) checks GitHub for a newer release and explains how to install it.

For a Homebrew installation, save your work, quit Glint, then run:

```sh
brew update && brew upgrade --cask glint
```

Reopen Glint afterward. `brew update` refreshes Homebrew's package list; only `brew upgrade` installs the newer app. A release must also be published to the Homebrew tap before it appears there.

For a manual installation, save your work and quit Glint, then download the latest ZIP or DMG and its matching `.sha256` file. Follow the [verification steps above](#install) before extracting or opening the download and replacing `/Applications/Glint.app`, then reopen Glint. Your separately stored preferences, presets and images remain in place. See the [update guide](https://mrashrhodes.github.io/glint/guide.html#updates).

Updates keep Glint's Screen Recording permission. **Updating from 1.2.0 or earlier** is the one exception: those releases were ad-hoc signed, so macOS needs the permission once more. Choose **Re-authorize Screen Recording…** in Preferences → About (Glint also opens its setup window if a capture fails for lack of access), allow Glint in System Settings, then relaunch Glint. If macOS cannot reset the old entry, Glint explains how to remove it and add it back manually. Later updates keep the permission ([#39](https://github.com/MrAshRhodes/glint/issues/39)).

## Features

- **Capture**: area (crosshair overlay), window picker, full screen, repeat last area, timer (3/5/10 s), capture text (OCR to clipboard). OCR notifications confirm copying without previewing recognized text. Multi-display and Retina aware.
- **Selection snapping**: opt in with **Snap to Edges** in the menu bar or **Snap selection to edges** in Preferences → Capture. Area selections align to visible window bounds and display edges, with snap guides. Hold ⌘ to temporarily invert snapping; Shift still constrains to a square. Snapping is off by default and does not detect arbitrary content inside windows.
- **Global hotkeys**: ⌃⌥⌘4 area to editor, ⌃⌥⌘5 area to clipboard, ⌃⌥⌘6 window, ⌃⌥⌘3 full screen, ⌃⌥⌘7 OCR, ⌃⌥⌘R repeat last area. All rebindable.
- **Beautify**: 32 built-in backgrounds (gradients, mesh, patterns, solid, transparent, your own image), padding, inset, corner radius, two-layer shadow, 3D tilt, rotate/flip, window, device and playful frames (macOS, browser, code editor, terminal, phone, retro monitor, pixel arcade, handheld console, comic panel, film strip, photo print), watermark.
- **Desktop wallpaper**: check **Use desktop wallpaper** in the Background controls to use your system wallpaper without importing a file. Preview and export share the same image; uncheck it to restore your previous background. See [wallpaper behavior and limitations](https://mrashrhodes.github.io/glint/guide.html#desktop-wallpaper).
- **Auto-balance**: detects uniform borders and balances the margins.
- **Aspect ratios**: auto, 1:1, 4:3, 3:2, 16:9, 9:16, 4:5, and social presets, plus custom.
- **Annotations**: arrow, line, rectangle, ellipse, pen, highlighter, text, numbered counters, **Zoom**, and a **Redact / Obfuscate** tool. **Zoom** (`Z`; press again for circle or rectangle) magnifies a selected detail 2× by default (1.25×–8×) in a movable inset beside it; the canvas grows automatically to fit an inset placed outside the screenshot, and insets never reveal redacted pixels. See [Zoom in on a detail](https://mrashrhodes.github.io/glint/guide.html#zoom). Click the current-style label to choose **Solid**, **Blur**, or **Pixelate**; the icon and `3` activate the tool without cycling styles. Each image starts with plain Solid. Solid offers an optional two-colour checkerboard; Pixelate uses an opaque decorative mosaic independent of the source image, with an optional solid-colour accent. Both replace covered pixels. **Blur is obfuscation only and unsafe for secrets.** Undo/redo, z-order, per-object styling.
- **Auto-redact**: on-device Vision OCR finds emails, phone numbers, credit cards (Luhn-checked), IP addresses, API keys and tokens, and covers detected regions with fully opaque solid fill, regardless of the manual tool mode. Solid redaction replaces the covered pixels in the exported image. Detection can miss information: review before sharing. Original images and saved raw captures are not erased.
- **Presets**: save, apply and set a default look. Create or edit presets from Preferences → Presets with live previews on a built-in sample image (or your own), then fine-tune them in the Preset Designer. **Remember settings** in Preferences → Editor starts each new screenshot with your last-used look; turn it off to always start from the default preset.
- **Export**: PNG, JPEG, HEIC, TIFF; 1x/2x; clipboard; Save As; share sheet; drag out. Optional raw and output folders.
- **Reopen Last Image**: opt in with **Keep copied and dragged screenshots for reopening** in Preferences → Output (off by default) and Glint keeps the finished image, annotations and redactions included, whenever you copy it or drag it out, including clipboard-only captures. **Reopen Last Image**, next to **Open Image…** and **Open Recent** in the menu bar menu and in the File menu, opens it again after the clipboard changes, the editor closes or Glint restarts. It opens as a flattened result, so a frame or background is never applied twice. It needs **Keep history**, reuses the file **Save styled output** already wrote instead of adding a duplicate, never keeps the original capture, and leaves **Save untouched raw capture** images alone. Installing or upgrading changes nothing until you opt in. See the [user guide](https://mrashrhodes.github.io/glint/guide.html#reopen-last-image).
- **Output retention**: **Keep screenshots in Output for** lets kept images expire after Forever (the default), 1, 7, 30 or 90 days. Glint moves to the Trash only images it saved itself after you opted in; Raw captures, manual saves and exports, and files that were already in the Output folder are never removed. See [how cleanup works](https://mrashrhodes.github.io/glint/guide.html#output-retention).
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
