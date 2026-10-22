<p align="center"><img src="docs/assets/icon-1024.png" width="128" alt="Glint icon"></p>

# Glint

Open-source screenshot beautifier for macOS. Capture an area, window or screen, then turn it into a polished image with backgrounds, padding, shadows, annotations and automatic redaction of sensitive text. Everything runs locally. Nothing is uploaded.

Glint is an independent project, released under the MIT license. It is not affiliated with or endorsed by any other screenshot product.

**[Product site](https://mrashrhodes.github.io/glint/)** · **[User guide](https://mrashrhodes.github.io/glint/guide.html)** · **[Releases](https://github.com/MrAshRhodes/glint/releases/latest)**

## Install

```sh
brew tap MrAshRhodes/tap
brew install --cask glint
```

Or download `Glint-<version>.zip` from the [Releases](https://github.com/MrAshRhodes/glint/releases) page and drag `Glint.app` to `/Applications`.

The app is ad-hoc signed, not notarized. The Homebrew cask clears the quarantine flag for you. If you install manually and macOS refuses to open it, run `xattr -dr com.apple.quarantine /Applications/Glint.app`.

Requires macOS 14 or later. On first launch grant **Screen Recording** permission (System Settings → Privacy & Security).

## Updates

Glint does **not** automatically download or install updates. **Check for Updates…** in the menu bar (also in Preferences → About) checks GitHub for a newer release and explains how to install it.

For a Homebrew installation, save your work, quit Glint, then run:

```sh
brew update && brew upgrade --cask glint
```

Reopen Glint afterward. `brew update` refreshes Homebrew's package list; only `brew upgrade` installs the newer app. A release must also be published to the Homebrew tap before it appears there.

For a manual installation, quit Glint, download the latest ZIP or DMG, replace `/Applications/Glint.app`, and reopen it. Your separately stored preferences, presets and images remain in place. Ad-hoc signing means macOS may require Screen Recording permission again after an update. See the [update guide](https://mrashrhodes.github.io/glint/guide.html#updates).

## Features

- **Capture**: area (crosshair overlay), window picker, full screen, repeat last area, timer (3/5/10 s), capture text (OCR to clipboard). OCR notifications confirm copying without previewing recognized text. Multi-display and Retina aware.
- **Global hotkeys**: ⌃⌥⌘4 area to editor, ⌃⌥⌘5 area to clipboard, ⌃⌥⌘6 window, ⌃⌥⌘3 full screen, ⌃⌥⌘7 OCR, ⌃⌥⌘R repeat last area. All rebindable.
- **Beautify**: 32 built-in backgrounds (gradients, mesh, patterns, solid, transparent, your own image), padding, inset, corner radius, two-layer shadow, 3D tilt, rotate/flip, window frames, watermark.
- **Desktop wallpaper**: check **Use desktop wallpaper** in the Background controls to use your system wallpaper without importing a file. Preview and export share the same image; uncheck it to restore your previous background. See [wallpaper behavior and limitations](https://mrashrhodes.github.io/glint/guide.html#desktop-wallpaper).
- **Auto-balance**: detects uniform borders and balances the margins.
- **Aspect ratios**: auto, 1:1, 4:3, 3:2, 16:9, 9:16, 4:5, and social presets, plus custom.
- **Annotations**: arrow, line, rectangle, ellipse, pen, highlighter, text, numbered counters, and redaction (blur, pixelate, solid). Undo/redo, z-order, per-object styling.
- **Auto-redact**: on-device Vision OCR finds emails, phone numbers, credit cards (Luhn-checked), IP addresses, API keys and tokens, and redacts them. Redactions destroy the pixels on export.
- **Presets**: save, apply and set a default look.
- **Export**: PNG, JPEG, HEIC, TIFF; 1x/2x; clipboard; Save As; share sheet; drag out. Optional raw and output folders.
- **Automation**: `glint://capture-area`, `capture-window`, `capture-fullscreen`, `capture-text`, `open?file=…`, and a CLI:

```sh
Glint.app/Contents/MacOS/Glint --render in.png out.png --preset "Social 16:9" --scale 2
Glint.app/Contents/MacOS/Glint --list-presets
Glint.app/Contents/MacOS/Glint --diagnose
```

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
