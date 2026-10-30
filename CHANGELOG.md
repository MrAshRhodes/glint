# Changelog

All notable changes to Glint are documented here, newest first.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries for 1.0.0 through 1.1.1 were compiled retroactively from tagged history, pull requests, and published release notes.
See [GitHub Releases](https://github.com/MrAshRhodes/glint/releases) for downloads.

## [Unreleased]

## [1.5.5] - 2026-10-30

### Fixed

- Zoom cut-ins now float above window frames, screen effects, rounded corners and borders in both the editor preview and exported images, including when the card is tilted. Annotations above a cut-in stay visible and magnified content still respects redactions. ([#70])

## [1.5.4] - 2026-10-30

### Changed

- Releases are now signed with an Apple Developer ID certificate and notarized by Apple, so macOS verifies the download instead of relying on the app's quarantine flag being cleared. **Action needed once:** when updating from 1.5.3 or earlier, grant Screen Recording one more time with **Re-authorize Screen Recording…** in Preferences → About, because the signing identity changed; later updates keep the permission. ([#44](https://github.com/MrAshRhodes/glint/issues/44))

### Security

- The release pipeline now requires Apple Developer ID signing, the hardened runtime, secure timestamps and accepted notarization with validated stapled tickets for the app and the DMG. Signing and notarization credentials live in a tag-restricted release environment, and incomplete signing or notarization stops publication. The Homebrew cask no longer removes the quarantine flag or bypasses Gatekeeper. Releases 1.5.3 and earlier are unchanged legacy builds. ([#44](https://github.com/MrAshRhodes/glint/issues/44))

## [1.5.3] - 2026-10-28

### Fixed

- Menus, context menus and other pop-ups that are open in another app can now be captured. Previously, the selection overlay closed them as it appeared, so they were gone from the screenshot. Now, if one is open when you start an area, window or text capture, Glint grabs the screen before showing the overlay and takes the capture from that image, so the menu is included even though macOS closes it once the overlay appears. In window mode (`Space`), an open menu can be picked like a window. With nothing open, capture behaves as before. ([#65])
- The selection overlay no longer activates Glint. It takes keyboard focus without bringing Glint to the front, so `Esc`, `Space`, `Return`, the arrow keys and the `⇧` and `⌘` modifiers work as before. ([#65])

## [1.5.2] - 2026-10-27

### Fixed

- Clicking a tool in the editor toolbar selects it again. Since 1.5.0 the toolbar was drawn half a row below the area that receives its clicks, so clicking the lower part of a tool button reached the canvas instead and did nothing, while keyboard shortcuts kept working. Every tool button now responds across its whole area, and the toolbar lines up with the window's traffic-light buttons again. ([#63])
- Every toolbar tool now shows its shortcut key on the button, not only in its tooltip: **Select** (`V`), **Text** (`1`), **Arrow** (`2`), **Redact / Obfuscate** (`3`), **Shape** (`4`), **Zoom** (`Z`), **Pen** (`P`), **Highlighter** (`H`) and **Counter** (`C`). Clicking a tool, key label included, does exactly what pressing its key does: clicking the active **Text**, **Arrow**, **Shape** or **Zoom** tool again switches its variant, and switching tools with a click finishes the text you are editing. ([#63])

## [1.5.1] - 2026-10-27

### Added

- A **Zoom** tool (the magnifier in the toolbar, or `Z`) for calling out small details. Drag around text or a detail to create a circular or rectangular inset with an enlarged copy of just that area, 2× by default, while the original screenshot stays visible; press `Z` again to switch between circle and rectangle. Glint places the inset beside your selection. Drag the inset to move it on its own, drag the selection to change what is magnified, and use the corner handles to resize either. The inspector sets **Shape**, **Magnification** (1.25×–8×), **Show source outline**, **Connect to source**, colour and border width. ([#61])
- Insets can sit outside the screenshot: the canvas grows automatically to include them, while the frame, rounded corners and shadow stay on the screenshot and the inset floats over the background. Insets are included when you copy, save, drag or export. An inset shows what lies beneath its selection, redactions and other annotations included, so it never reveals pixels hidden by Solid or Pixelate redaction. ([#61])
- GlintCore API: `Magnifier` (`source`, `inset`, `shape`, `showsSourceOutline`, `showsConnector`, `magnification`) with `MagnifierShape` (`circle`, `rectangle`), plus `Annotation.isMagnifier`. ([#61])

### Changed

- GlintCore: `AnnotationKind` adds `magnify(Magnifier)`; exhaustive `switch` statements over it must handle the new case. `RenderLayout` adds `overflowRect` and `RenderResult` adds `region`; `Compositor.layout` takes an optional overflow argument, defaulted so existing calls compile unchanged. When an inset reaches beyond the screenshot, `contentRect` still marks the screenshot and `overflowRect` covers the expanded content. ([#61])

## [1.5.0] - 2026-10-27

### Changed

- Redesigned the UI around Apple's Liquid Glass guidelines (with material fallbacks on macOS 14–15). The editor canvas now fills the window, with the toolbar, inspector and action bar floating as glass. Every inspector section is collapsible and remembers its state, and **Collapse All**/**Expand All** is available. ([#57])
- Preferences now uses the standard toolbar-tab Settings window, which resizes to fit each tab. Advanced sections are collapsible, presets show as preview cards, and the About and setup screens have been refreshed. ([#57])
- The post-capture quick-access thumbnail floats on a glass panel, slides in and out (fade only with Reduce Motion), and has a close button on hover. Capture overlay labels and selection outlines have been refined. ([#57])
- GlintEditor API: `GlintDesign`, `GlintGlassView`, `GlintGlassContainer` and `glintGlass`/`glintCard` view helpers. ([#57])

## [1.4.0] - 2026-10-23

### Added

- **Reopen Last Image** in the menu bar menu (next to **Open Image…** and **Open Recent**) and the File menu, which reopens the latest image you copied or dragged out even if you never saved it. It works once you turn on **Keep copied and dragged screenshots for reopening** in Preferences → Output (off by default). Glint then keeps the finished image, annotations and redactions included, in the Output folder when you copy it (editor Copy, clipboard-only capture, automatic copy after capture) or drag it out (editor **Drag to share**, quick-access thumbnail). The image stays available after the editor closes, the clipboard changes or Glint restarts, and reopens as a flattened result, so a frame or background is never applied twice. Keeping images needs **Keep history**, reuses the file **Save styled output** already saved instead of adding a duplicate, never keeps the original capture, and leaves **Save untouched raw capture** images alone. ([#52])
- **Keep screenshots in Output for** in Preferences → Output: **Forever** (the default), **1 day**, **7 days**, **30 days** or **90 days**. A finite period moves expired images to the Trash, but only images Glint itself saved after you opted in. Raw captures, manual saves and exports, files that were already in the Output folder, symlinks and files in use for a drag are never removed. Cleanup runs in the background, never the instant you change the setting. Both new settings are off by default, so installing or upgrading Glint keeps its current behavior, and **Reset all preferences** restores them. ([#52])
- GlintCore API: `OutputRetention` with `OutputRetentionPeriod`, `OutputRetentionSource`, `RetainedOutput`, `OutputCleanupReport`, `OutputRetentionError` and `OutputActiveFiles`, plus `AppPreferences.keepCopiedImages` and `AppPreferences.outputRetention`. ([#52])
- Nine new frame styles alongside None, macOS and Browser, grouped in a **Frame** menu: Windows (Code Editor, Terminal), Devices (Phone, Retro Monitor, Handheld Console) and Playful (Pixel Arcade, Comic Panel, Film Strip, Photo Print). Each has light and dark versions and an optional label, such as a file name, caption or player name, looks the same in the preview and the export, and is saved in presets. Retro Monitor and Pixel Arcade add subtle scanlines and glare; uncheck **Screen effects** to turn them off. None, macOS and Browser frames are unchanged. ([#51])

### Changed

- The inspector's **Window frame** section is now **Frame**, with a grouped menu instead of a segmented control. The label field's placeholder shows what the chosen style uses it for. ([#51])
- GlintCore: `WindowFrameKind` adds `ide`, `terminal`, `phone`, `retro`, `arcade`, `handheld`, `comic`, `filmStrip` and `photo`, plus `displayName`, `category` and `titlePlaceholder`; exhaustive `switch` statements over it must handle the new cases. `WindowFrameSettings` adds backward-compatible `screenEffects` (stored only when off) and `metrics`/`insets` (`FrameMetrics`, `FrameInsets`, `FrameCornerRule`). `RenderLayout` adds `screenRect`; frames can now add chrome on any side, so `contentRect` may also be offset horizontally. ([#51])

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

[Unreleased]: https://github.com/MrAshRhodes/glint/compare/v1.5.5...HEAD
[1.5.5]: https://github.com/MrAshRhodes/glint/compare/v1.5.4...v1.5.5
[1.5.4]: https://github.com/MrAshRhodes/glint/compare/v1.5.3...v1.5.4
[1.5.3]: https://github.com/MrAshRhodes/glint/compare/v1.5.2...v1.5.3
[1.5.2]: https://github.com/MrAshRhodes/glint/compare/v1.5.1...v1.5.2
[1.5.1]: https://github.com/MrAshRhodes/glint/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/MrAshRhodes/glint/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/MrAshRhodes/glint/compare/v1.3.0...v1.4.0
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
[#51]: https://github.com/MrAshRhodes/glint/issues/51
[#57]: https://github.com/MrAshRhodes/glint/issues/57
[#61]: https://github.com/MrAshRhodes/glint/issues/61
[#63]: https://github.com/MrAshRhodes/glint/issues/63
[#65]: https://github.com/MrAshRhodes/glint/issues/65
[#70]: https://github.com/MrAshRhodes/glint/issues/70
