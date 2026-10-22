# Changelog

All notable changes to Glint are documented here, newest first.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries for 1.0.0 through 1.1.1 were compiled retroactively from tagged history, pull requests, and published release notes.
See [GitHub Releases](https://github.com/MrAshRhodes/glint/releases) for downloads.

## [Unreleased]

### Added

- This changelog, covering every release since 1.0.0.

### Changed

- Make editor sharing easier to discover with a labeled **Drag to share** preview tile and a visible **Copy ⌘C** shortcut. ([#27])

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

[Unreleased]: https://github.com/MrAshRhodes/glint/compare/v1.1.1...HEAD
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
[#27]: https://github.com/MrAshRhodes/glint/issues/27
