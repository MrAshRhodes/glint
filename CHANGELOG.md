# Changelog

All notable changes to Glint are documented here, newest first.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries for 1.0.0 through 1.1.1 were compiled retroactively from tagged history, pull requests, and published release notes.
See [GitHub Releases](https://github.com/MrAshRhodes/glint/releases) for downloads.

## [Unreleased]

### Added

- **Reopen Last Image** in the menu bar menu (next to **Open Image…** and **Open Recent**) and the File menu, which reopens the latest image you copied or dragged out even if you never saved it. It works once you turn on **Keep copied and dragged screenshots for reopening** in Preferences → Output (off by default). Glint then keeps the finished image, annotations and redactions included, in the Output folder when you copy it (editor Copy, clipboard-only capture, automatic copy after capture) or drag it out (editor **Drag to share**, quick-access thumbnail). The image stays available after the editor closes, the clipboard changes or Glint restarts, and reopens as a flattened result, so a frame or background is never applied twice. Keeping images needs **Keep history**, reuses the file **Save styled output** already saved instead of adding a duplicate, never keeps the original capture, and leaves **Save untouched raw capture** images alone. ([#52])
- **Keep screenshots in Output for** in Preferences → Output: **Forever** (the default), **1 day**, **7 days**, **30 days** or **90 days**. A finite period moves expired images to the Trash, but only images Glint itself saved after you opted in. Raw captures, manual saves and exports, files that were already in the Output folder, symlinks and files in use for a drag are never removed. Cleanup runs in the background, never the instant you change the setting. Both new settings are off by default, so installing or upgrading Glint keeps its current behavior, and **Reset all preferences** restores them. ([#52])
- GlintCore API: `OutputRetention` with `OutputRetentionPeriod`, `OutputRetentionSource`, `RetainedOutput`, `OutputCleanupReport`, `OutputRetentionError` and `OutputActiveFiles`, plus `AppPreferences.keepCopiedImages` and `AppPreferences.outputRetention`. ([#52])

## [1.3.0] - 2026-10-22

### Added

- A style-label menu for choosing Solid, Blur, or Pixelate, an optional two-colour checkerboard for Solid, and an optional solid-colour highlight for the Pixelate mosaic. ([#45])
- Optional window/display-edge snapping for capture-area selections, with visible guides, a shared **Snap to Edges** menu item and **Snap selection to edges** preference (off by default). Hold Command to temporarily invert snapping; Shift keeps its square/10-point-nudge behavior. Arbitrary content inside windows is not detected. ([#43])

### Changed

- The Redact icon and `3` shortcut activate the tool without cycling its style. Each image still starts with plain Solid, and automatic redaction always uses plain opaque fill. ([#45])
- GlintCore: `AnnotationStyle` adds backward-compatible `redactionPattern`, `redactionSecondaryColor`, and `pixelateHighlight` fields. `Annotation.isRedaction` now includes secure Pixelate; `isObfuscation` identifies Blur only. ([#45])

### Security

- Pixelate now replaces covered pixels with an opaque, source-independent decorative mosaic instead of sampling sensitive content. Patterned Solid also replaces every tile and gap. Blur remains unsafe for secrets. ([#45])

### Fixed

- Capture overlays redraw changed display regions and reuse label layout instead of invalidating every display on each pointer move. Mouse input remains immediate, without smoothing or debounce. ([#42])

## [1.2.1] - 2026-10-22

### Added

- **Re-authorize Screen Recording…** in Preferences → About clears Glint's stale Screen Recording entry and requests access again; allow Glint in System Settings, then relaunch Glint. If the reset fails, Glint explains the manual recovery steps. If Glint has seen Screen Recording granted and it later goes missing, Glint opens its setup window at launch; otherwise it opens when a capture fails for lack of access. ([#39])

### Fixed

- Updates no longer reset Screen Recording permission. Releases were ad-hoc signed, and macOS tied the permission to each build's signature; releases are now signed with a persistent certificate, so macOS keeps the grant. They are still not notarized by Apple. **Action needed once:** when updating from 1.2.0 or earlier, grant Screen Recording one more time with **Re-authorize Screen Recording…**; later updates keep it. ([#39])

## [1.2.0] - 2026-10-22

### Added

- This changelog, covering every release since 1.0.0. GitHub release notes now come from the release's section here. ([#26], [#30])
- **Add Preset…** in Preferences → Presets opens a **New Preset** sheet. Pick a starting point (your last-used settings, a saved preset, or a deleted built-in preset), each previewed on a built-in sample image, then name it and choose **Add**, or **Customize in Editor…** to fine-tune it in the Preset Designer. **Use My Image…** previews your own image instead; it is never stored in the preset. ([#33])
- **Edit…** in Preferences → Presets opens the selected preset in the Preset Designer. Saving updates it in place, including a new name, and a default preset stays the default. Designing a preset does not change your last-used editor settings. ([#33])
- GlintCore API: `PresetStore.uniqueName(_:)`, which returns the base name or the first unused numbered variant, such as "Preset 2". ([#33])
- **Remember settings** in Preferences → Editor. When it is checked, the editor starts new screenshots with your last-used settings, including after restarting Glint; when it is unchecked, they start from the default preset. Its tooltip suggests saving a preset for a look you want to keep, and remembering never changes a saved preset. Until you change it, it keeps the previous behavior: checked unless you have chosen a default preset. ([#34])
- GlintCore API: `AppPreferences.rememberSettings`. ([#34])

### Changed

- **Add Preset…** replaces **Add from last used** in Preferences → Presets; last-used settings are now one of the starting points in the New Preset sheet. ([#33])
- Make editor sharing easier to discover with a labeled **Drag to share** preview tile and a visible **Copy ⌘C** shortcut. ([#32])

### Security

- Address CodeQL's script-tag matching alert in the theme-bootstrap test helper. Script tags are now matched case-insensitively, with attributes and closing-tag whitespace supported, while external scripts are excluded. This changes test code only, not application or site runtime behavior. ([#37])

## [1.1.1] - 2026-10-22

Security release. All users should update. Despite the patch version, this release includes behavior and public API changes; automation and GlintCore users should review the **Changed** and **Removed** sections.

### Security

- Fail closed when capture-time redaction cannot be completed. Failed captures offer **Retry** or **Discard Capture** instead of exposing an unredacted image, and rendering fails if annotations cannot be applied. ([#17])
- Use solid masks for automatic redaction, ignoring the legacy style preference. The **Redact / Obfuscate** tool starts with **Solid**; blur and pixelation are labeled as obfuscation, with a warning that they are not secure redaction. ([#22])
- Require confirmation for every capture-capable `glint://` request. **Cancel** is the default, approval applies to one request only, and overlapping requests are rejected rather than queued. There is no persistent "always allow" option. ([#21])
- Limit `--diagnose` output to aggregate information, without recognized text or raw framework error messages. ([#19])
- Replace recognized text in OCR notifications with the fixed message "Recognized text copied to clipboard". ([#20])
- Document SHA-256 verification of downloaded releases before extraction or removing quarantine attributes. ([#18])

### Added

- GlintCore APIs: `Annotation.isObfuscation`, `RedactionStyle.displayName`, `RedactionStyle.isObfuscation`, and `RenderError.annotationsNotApplied`. ([#17], [#22])
- System, Light, and Dark appearance options on the product site and user guide. ([#10])

### Changed

- **Breaking for URL-based automation:** `glint://capture-*` and `glint://repeat-last` now need an explicit confirmation click. Menu commands, keyboard shortcuts, non-capture URLs (`open`, `preset`, and `preferences`), and CLI rendering are unchanged by this gate. ([#21])
- **Breaking for GlintCore callers:** `Compositor.render` and `Compositor.renderDetailed` now throw on rendering failure; callers must handle these errors. `Annotation.isRedaction` now identifies solid masks only, rather than also including blur and pixelation. ([#17], [#22])
- Redesign the product site and user guide with a light-table layout. ([#8])

### Removed

- **Breaking for GlintCore callers:** `AutoRedactOptions.style`, its initializer's `style:` argument, and `AppPreferences.redactStyle`. Remove the obsolete style argument from automatic-redaction setup; automatic redaction always uses solid masks. ([#22])

## [1.1.0] - 2026-10-21

### Added

- **Use desktop wallpaper** as a screenshot background. Glint reads the main display's wallpaper file for the current Space, rather than capturing the desktop, and uses the same image for preview and export. Turning it off restores the selected background. ([#4])
- Wallpaper support in presets, direct export, and CLI rendering. Unreadable wallpaper files and rotating folders fall back to the selected background with an explanation; dynamic wallpapers use their primary still image. ([#4])
- GlintCore wallpaper APIs: `DesktopWallpaper`, `DesktopWallpaperError`, `RenderSettings.usesDesktopWallpaper`, and the compositor's `wallpaper:` argument. ([#4])

### Changed

- Require issue-linked pull requests and passing checks for changes to `main`. ([#3])

## [1.0.1] - 2026-10-21

### Added

- [Product site](https://mrashrhodes.github.io/glint/) and [user guide](https://mrashrhodes.github.io/glint/guide.html), with sample images rendered by Glint.
- Update instructions in the README and release notes.

### Changed

- Make **Check for Updates** an explicitly manual flow: **Copy Homebrew Command**, **Open Release Page**, or **Later**. Glint does not download or install updates in the background.
- Clarify manual updates in the About tab and link to the user guide.
- Keep published release assets immutable and pin the Homebrew cask to the published ZIP's SHA-256 checksum.

### Fixed

- Report direct-export success only when the operation succeeds, and notify users when saving a raw capture fails.
- Stop capture export when automatic-redaction OCR or annotation application fails, instead of continuing with the unredacted image.
- Close the editor after **Copy & Close** only when copying succeeds.
- Report drag-export failures and remove all temporary drag files when the editor closes.
- Prevent overlapping update checks and report GitHub response, clipboard, and browser-opening failures.
- Reject non-finite, zero, or negative `--render --scale` values with exit status 2 instead of silently using a scale of 1.
- Handle the `-h` and `-v` CLI aliases instead of launching the app.
- Correct the README's default keyboard shortcuts to match the app.

## [1.0.0] - 2026-10-21

First public release.

### Added

- A local-only macOS screenshot beautifier, with no screenshot uploads, for macOS 14 and later.
- Area, window, full-screen, and repeat-last captures; 3-, 5-, and 10-second capture timers; and OCR text capture.
- Configurable global keyboard shortcuts and a menu-bar capture workflow.
- An editor with 32 backgrounds, padding, inset, corner radius, two-layer shadows, 3D tilt, rotation, flipping, window frames, and watermarks.
- Automatic content balancing and automatic, fixed, social, and custom aspect ratios.
- Arrow, line, rectangle, ellipse, pen, highlighter, text, and counter annotations, plus solid masks, blur, and pixelation; annotation styling, stacking order, and undo/redo.
- OCR-based detection and automatic masking of email addresses, phone numbers, payment-card numbers with Luhn validation, IP addresses, and API keys or tokens.
- Reusable presets for rendering settings.
- PNG, JPEG, HEIC, and TIFF export at 1x or 2x scale, with clipboard copying, Save As, sharing, drag-and-drop, and configurable raw-capture and output folders.
- `glint://` actions for area, window, full-screen, and text capture, repeat-last capture, opening a file, selecting a preset, and opening preferences.
- CLI commands for headless rendering (`--render`, with `--preset` and `--scale`), listing presets, diagnostics, version information, and help.
- The reusable GlintCore library for capture, rendering, annotations, OCR, and sensitive-information detection.
- Homebrew cask installation and ad-hoc-signed ZIP and DMG downloads with SHA-256 checksums.

[Unreleased]: https://github.com/MrAshRhodes/glint/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/MrAshRhodes/glint/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/MrAshRhodes/glint/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/MrAshRhodes/glint/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/MrAshRhodes/glint/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/MrAshRhodes/glint/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/MrAshRhodes/glint/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/MrAshRhodes/glint/releases/tag/v1.0.0
[#3]: https://github.com/MrAshRhodes/glint/pull/3
[#4]: https://github.com/MrAshRhodes/glint/pull/4
[#8]: https://github.com/MrAshRhodes/glint/pull/8
[#10]: https://github.com/MrAshRhodes/glint/pull/10
[#17]: https://github.com/MrAshRhodes/glint/pull/17
[#18]: https://github.com/MrAshRhodes/glint/pull/18
[#19]: https://github.com/MrAshRhodes/glint/pull/19
[#20]: https://github.com/MrAshRhodes/glint/pull/20
[#21]: https://github.com/MrAshRhodes/glint/pull/21
[#22]: https://github.com/MrAshRhodes/glint/pull/22
[#26]: https://github.com/MrAshRhodes/glint/pull/26
[#30]: https://github.com/MrAshRhodes/glint/pull/30
[#32]: https://github.com/MrAshRhodes/glint/pull/32
[#33]: https://github.com/MrAshRhodes/glint/pull/33
[#34]: https://github.com/MrAshRhodes/glint/pull/34
[#37]: https://github.com/MrAshRhodes/glint/pull/37
[#39]: https://github.com/MrAshRhodes/glint/issues/39
[#45]: https://github.com/MrAshRhodes/glint/issues/45
[#42]: https://github.com/MrAshRhodes/glint/issues/42
[#43]: https://github.com/MrAshRhodes/glint/issues/43
[#52]: https://github.com/MrAshRhodes/glint/issues/52
