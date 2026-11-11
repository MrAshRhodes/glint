# Changelog

All notable changes to Glint are documented here, newest first.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Entries for 1.0.0 through 1.1.1 were compiled retroactively from tagged history, pull requests, and published release notes.
See [GitHub Releases](https://github.com/MrAshRhodes/glint/releases) for downloads.

## [Unreleased]

## [1.9.2] - 2026-11-11

### Removed

- Scrolling capture has been removed because reliable end-to-end capture could not be verified. Its menu item, ⌃⌥⌘8 shortcut, `glint://capture-scrolling` URL and Preferences option are no longer available. Regular screenshots and screen recording are unchanged; Fit, Fit Width and 100% zoom, tall-image OCR and editing existing images remain available. ([#132])

## [1.9.1] - 2026-11-11

### Added

- Scrolling capture now scrolls automatically by default, advancing in small overlapping steps after each capture is stitched. Automatic scrolling needs Accessibility permission; unavailable scrolling, an apparent page bottom, a changed target window or a safety limit pauses for review, with **Resume** switching to manual capture. Turn off **Automatically scroll during scrolling capture** in Preferences → Capture to scroll manually without that extra permission; the capture panel highlights when your pace is too fast, too slow or steady. ([#132])

### Fixed

- Finishing a scrolling capture now includes the final short scroll even when **Done** is pressed before it settles; previously this could return only the first viewport. Finishing during an automatic step waits for that step, while an uncertain final join requires review instead of silently returning a truncated image. ([#132])

## [1.9.0] - 2026-11-10

### Added

- Capture/editor/export timing signposts, including hotkey delivery, permission checks, metadata lookup, image acquisition, rendering, encoding, clipboard publication and first preview. These record timings and fixed mode/trigger labels, never screenshot contents, coordinates, window titles or paths. ([#96])
- Opt-in `Glint --diagnose --timing` reports cold and warm capture-stage timings as JSON. Reading display pixels requires the separate `--allow-screen-capture` flag; plain `--diagnose` is unchanged. A permission-free weekly Performance workflow checks offscreen overlay drawing, synthetic rendering/encoding, output density and colour-profile metadata, retaining timing summaries and failing on gross regressions. ([#97])
- Hold `Space` while dragging a selection to move the whole rectangle; release it to continue resizing. Before a drag, `Space` still switches between area and window selection, and the hint explains both actions. ([#105])
- `Scripts/capture-latency.cjs` turns a `log stream --signpost` trace into p50/p95 hotkey latency per scenario (first capture of a process, warm, after 60 s of quiet, and after a named marker such as a wake or display change), split into key event → callback → main actor → first overlay frame. It reports durations and counts only; CONTRIBUTING.md explains how to collect an idle/wake trace. No live trace has been recorded yet. ([#106])

### Changed

- Window capture no longer waits a fixed 120 ms after you pick a window, and reuses the window list read when the selection opened instead of asking macOS again, so the screenshot is taken sooner. Live area grabs (timed area) wait only what is left of that 120 ms since the selection closed, and a window that closes or cannot be grabbed still falls back to the frozen pixels. ([#101])
- Screenshot composition, encoding, thumbnail preparation and file writes move off the main actor. Direct output is copied and shown before disk writes finish, and the editor opens before the optional raw file is saved. Thumbnails use downscaled images on the capture's display; recent-file entries, saved notifications and drag files appear only after a successful write. Quitting waits for pending writes, failures remain visible, and background saves do not overwrite a newly created file. ([#98])
- Clipboard publication shares an immutable image snapshot with background PNG preparation, makes TIFF only when a consumer requests it, and reuses encoded PNG bytes for saving. Editor Copy renders off-main, and dragging starts with a file promise while rendering and writing continue. Pending clipboard data is handed over on quit; output failures are reported rather than silently publishing an empty result. First-paste and drag-delivery latency still require live measurement. ([#99])
- Glint prewarms capture metadata, not pixels, after launch and display/session changes when Screen Recording is already allowed. Captures reuse it and retry once with fresh metadata after an acquisition failure. Screen freezing and window enumeration overlap, and shared hint layouts are prepared before the first overlay frame. This does not bypass permission checks or acquire background screenshots. ([#102])
- The editor's first frame shows a safely positioned capture with the composed preview's crop, orientation and proportions, without delaying the initial render to group later edits. Images awaiting automatic redaction remain covered and unavailable to preview/drag until analysis finishes. `ProvisionalFrame` shares compositor layout and crop rules. ([#109])
- Editor previews, copies and exports reuse sRGB conversion and annotation baking when only the look changes, with a 256 MB image budget. Background, wallpaper and watermark decoding also moves off-main and uses a separate 256 MB, three-image cache invalidated by file identity and metadata. Annotation edits invalidate baked pixels; redactions remain in every output. Grain backgrounds use equivalent band drawing. `RenderCache`, `ImageFileCache`, the compositor's optional `cache:` argument and `Scripts/benchmark-editor-render.sh` expose and measure this reuse. ([#110])
- Global shortcuts register before deferred menu/updater setup, and Settings is constructed only when opened. The Permissions pane polls only while visible and publishes only changed values. Launch, Settings, menu and permission-check signposts make the remaining cold/idle costs observable. ([#112])
- Full-screen and repeat-last-area captures keep existing editor and Settings windows visible, using capture exclusion instead of hide/restore flicker. Interactive, timed and scrolling capture retain their existing visibility behavior. ([#113])
- Overlay profiling now reports the effective AppKit dirty-region area, bounding area and rectangle count. The CPU benchmark compares disjoint and coalesced clipping; it does not claim a live frame-rate improvement. The screenshot colour policy is documented and regression-tested: raw PNG preserves the supplied profile, composed output is colour-managed in sRGB, and clipboard/encoded output are compared in a common colour space. Live redraw, wide-gamut display appearance and native-tool comparisons remain unmeasured. ([#107], [#111])
- Automatic redaction reads a capture's text once: the editor that opens a capture, or the one opened from a direct export's **Edit** action, reuses the pipeline's read instead of reading the already-redacted pixels again, unless the detection settings differ or that read did not finish. Redacting again with other categories, or **Detect Text**, reuses text already read from the same image. Covers use the same 3-point margin everywhere (6 px on a Retina capture), clipped at the image edge. ([#114])
- While the editor is still checking a capture for sensitive information, Copy, Save, Share and drag-out refuse with a retry instead of exporting pixels that may not be covered yet; closing the editor drops a read still running. GlintCore adds `RedactionAnalysis`, `RedactionPolicy`, `AutoRedactOptions`/`AutoRedact.analyse` and `TextRecognizer.statistics` (also a `Recognize` signpost); `EditorContext.redaction` describes what the pipeline already redacted, and `EditorHeadless.render` throws when text recognition fails instead of returning unredacted pixels. ([#114])

### Fixed

- Screenshots exported without opening the editor (**Open editor after capture** off, and clipboard-only captures) now start from the same look as the editor: your last-used settings when **Remember settings** is on, otherwise the default preset. They used to ignore Remember settings and always used the default preset. Auto-balance still follows Preferences. ([#108])
- Copied screenshots now match the saved file's resolution. The clipboard image carries the same pixel size and density as the saved PNG or TIFF, so apps that honour image resolution paste a Retina capture at the same size as the saved file instead of larger, and the **Scale** export setting applies to copied images as it does to saved ones. ([#100])
- Changing a global shortcut registers the replacement before releasing the working binding, saves only successful changes, and explains conflicts in its Settings row. Startup registration failures appear in Settings and a **Shortcut Problem…** menu item, with a notification when enabled. Unrelated preference changes no longer re-register every shortcut. ([#103])
- Busy capture requests beep instead of disappearing silently. Capture, OCR, output and recording failures use a notification when available or an alert and beep otherwise. Screen Recording refusal opens setup, and notification permission is not repeatedly requested after the user has answered. ([#104])
- Selection crosshairs also work on non-key display panels. Arrow nudges remain effective when mouse movement resumes, and arrows without an active drag move the real pointer within the displays. Space/display-layout changes cancel stale selections, with observers removed when selection ends. ([#105])

## [1.8.2] - 2026-11-10

### Fixed

- Screenshot selection opens more smoothly: Glint's windows stay visible until the frozen overlay covers them, the frozen desktop is composited separately from the selection controls, and dimming fades in briefly (without animation when Reduce Motion is enabled). Multi-display captures fetch shareable screen content once instead of once per display, reducing setup work before selection appears. ([#92])

## [1.8.1] - 2026-11-09

### Fixed

- Screenshot capture now honors **Hide Glint windows while capturing** throughout image acquisition and window selection: turn it off to capture the editor without losing the existing editing session. Immediate selections preserve the desktop before taking focus, and window picking supports floating panels as well as menus. Snapshot failures are reported instead of silently capturing a later image with missing content. Timers remain live, and the hide preference remains enabled by default. ([#88])

## [1.8.0] - 2026-11-07

### Added

- Scrolling capture. Choose **Scrolling Capture** from the menu bar icon or press ⌃⌥⌘8, select the scrolling area, then scroll at a steady pace. Glint grabs a frame whenever the content settles, stitches the frames into one tall image and shows a live preview with its height in a floating panel. Press the same shortcut or **Done** to finish, or Esc to cancel. Sticky headers and footers appear once. When Glint is unsure of a match, the content stops moving, scrolls back or jumps too far, it pauses and offers **Resume**, **Undo** or **Retry**; a low-confidence join is marked in the preview. Captures stop at 16,384 pixels high or 64 megapixels. The result opens in the editor like any screenshot, and OCR reads the whole height. Also available as `glint://capture-scrolling`. ([#80])
- The editor can zoom to **Fit**, **Fit Width** or **100%** from the bottom bar or with ⌘9, ⌘8 and ⌘0. Very tall images open at Fit Width so they can be scrolled. ([#80])
- GlintCore API: `ScrollStitcher`, `ScrollStitchLimits`, `ScrollStitchStep` and `ScrollStitchWarning` stitch scrolled frames with sticky header/footer detection and memory-bounded undo (`ScrollStitchLimits.maxUndoBytes`); `ScrollSignature` and `ScrollGrabPolicy` decide when to grab a frame. `TextRecognizer` reads images taller than 4,096 pixels in overlapping bands and removes duplicate lines. `Compositor.layout` no longer grows an extreme-aspect canvas past its area budget when matching an aspect ratio. ([#80])
- Editable projects. **Save as Project…** (⌥⌘S, in the editor's bottom bar or the File menu) saves a `.glint` package with the original screenshot or recording, the look, every annotation and, for recordings, the trim, annotation ranges and GIF/MP4 settings. Open it with **Open Image…**, **Open Recent** or a double-click in Finder to continue editing exactly where you left off: no preset, remembered look or auto-redaction is applied again, and edits are not remembered for the next capture. Projects contain the original capture including anything redacted, and the save panel says so; share exports instead. Glint refuses projects from a newer format or with features it doesn't support, and opens packages defensively (no symlinks, size limits, impossible clip sizes refused, and the editor works on a private copy so later changes to the package can't reach it). Closing an editor or quitting waits for a project save that is still running. Projects keep tracked redactions, and builds that predate tracking refuse such a project rather than open it without them. Projects are never removed by output cleanup. ([#78], [#79])
- GlintCore API: `GlintProject`, `ProjectState`, `ScreenshotProjectState`, `RecordingProjectState`, `ProjectSource`, `ProjectManifest`, `ProjectFeatures`, `ProjectFormatError` and `ProjectStore.read(from:snapshotRoot:)` / `write(_:to:generator:fileManager:)` / `removeAllSnapshots(in:fileManager:)`, with `GlintProject.discardSnapshot()`. `RecordingTrim`, `RecordingExportOptions`, `GIFExportOptions`, `RecordingFileFormat` and `GIFMaxWidth` are now `Codable`, and `RecordedVideo` gains `deletesFileOnClose` (default `true`). ([#78])
- Tracked redactions for recordings. Select a Solid or Pixelate redaction and choose **Track** to follow moving content forwards and backwards from the current frame, on this Mac. Frames where tracking is unsure are flagged in orange on the annotation lane and covered by a large fail-safe rect; every export, copy, share and drag stays blocked until each flagged interval inside the trim is accepted as a fixed cover, resolved with manual keyframes, or trimmed out. Editing a tracked redaction on the canvas adds a keyframe at the current frame. Review tools include frame-by-frame stepping, **Next flagged** (Shift+N), **Re-track** and **Remove tracking**, with keyboard and VoiceOver support. Blur can't be tracked. Tracking is an aid; you remain responsible for checking every frame. Saved projects keep tracked redactions: a reopened recording still shows each tracked position, the orange flagged intervals and the fail-safe cover, and every export, copy, share and drag stays blocked until each flagged interval inside the trim is accepted, resolved with keyframes or trimmed out; nothing is dropped on save or reopen. A project with a tracked redaction records the `redactionTracks` feature, so builds without it refuse the project with a message to update instead of opening it with redactions that no longer follow their content, while projects without tracked redactions still open in them. Tracking data that is oversized (over 100,000 keyframes or 1,000 flagged intervals) makes Glint refuse the project as damaged; data that is merely invalid opens covered by the whole frame, with export blocked. ([#78], [#79])
- GlintCore API: optional `Annotation.track` (`RedactionTrack` with keyframes, uncertain intervals, analysed range and frame bounds), `Annotation.resolved(at:)`, `RedactionTracker`, `FrameTracker`, `VisionFrameTracker`, `FailSafeCover` and `RedactionGate`. The compositor draws tracked redactions at their tracked position for each frame. `ProjectFeatures.redactionTracks` is now in `ProjectFeatures.supported`, and `ProjectFeatures.required(by:)` returns it for any project whose annotations include a track. `RedactionTrack.maxKeyframes` and `maxUncertainIntervals` bound the tracks a project may hold, and `ProjectStore.write` refuses a `project.json` larger than it can reopen (64 MiB). ([#78], [#79])
- Presentation tools for recordings. Glint now records where the pointer is and where you click while recording (no extra permission needed). In the editor, **Clicks & Cursor** in the inspector adds click ripples (left and right clicks in their own colours, with adjustable size and duration; remove any single click), a halo around the pointer, or a spotlight that dims everything else. Turn on **Editable pointer** in Preferences → Capture before recording to leave the pointer out of the footage, so the editor can enlarge or hide it. A new **Zoom** lane below the annotation timeline adds zoom segments at the playhead: each eases in, holds and eases out, keeps the output size, and its area is chosen by dragging on the canvas. Effects use original-recording times and follow trimming; the preview, GIF/MP4 exports and copied clips match, and redactions still cover their content at every zoom level. Saved projects preserve all pointer samples, clicks, removed-click choices, cursor settings and zooms, even when effects are disabled; older builds refuse presentation projects rather than silently dropping their edits. With the default settings, recordings export exactly as before. ([#81])
- GlintCore API: `Presentation`, `PresentationCapture`, `PresentationSettings`, `PointerTrack`, `ClickEvent`, `ClickHighlightStyle`, `CursorEmphasis` and `ZoomSegment` (all `Codable`, defaulting missing fields); optional `RecordedVideo.presentation`; defaulted `RecordingProjectState.presentation` and the `ProjectFeatures.presentation` compatibility gate; `RecordingExportOptions.resamplesStyledFrames` (styled MP4 rendered at a steady cadence, so effects animate through capture gaps); a final optional `presentation` argument on `Compositor.render` and `renderDetailed`, applied only with an `annotationTime`. ([#81])

## [1.7.0] - 2026-11-05

### Added

- Screen recording. Choose **Record Screen…** from the menu bar icon or press ⌃⌥⌘9, select and adjust an area, then record immediately or after a 3, 5 or 10 second countdown. A floating bar shows the elapsed time and a Stop button; stop with it, with the same shortcut or from the menu bar. Recordings are capped at 10 minutes, have no audio, and leave Glint's own windows out. A finished recording opens in the same editor as screenshots, with the same tools, annotations, frames, backgrounds and presets applied to the whole clip by default. Trim it, then export an animated GIF or an MP4, or copy, save, share or drag it out. Annotations stay in a fixed position; automatic redaction and Auto-balance are off for recordings so the picture never shifts. ([#74])
- Each annotation on a recording can now appear for a chosen time range, including zoom cut-ins and redactions. All start on **Whole clip**. Adjust each annotation's timeline lane with start/end handles, numeric times, **Start at playhead** / **End at playhead** or **Shift+I** / **Shift+O**; drag a shortened range's named bar to move it without changing its duration. Lanes align with the trim timeline, with range times on the right. **Whole clip** removes its limits. Keyboard and VoiceOver controls are supported. Ranges use original-recording times and follow trimming; preview playback, scrubbing, GIF/MP4 exports and copied clips respect them. Glint warns that a time-limited redaction, Pixelate or Blur effect exposes content outside its range. Annotations do not fade or track moving content. ([#75])
- GlintCore API: `AnnotationTiming(start:end:)`, optional `Annotation.visibleRange` (`nil` means throughout), and `Annotation.isVisible(at:)`. `Compositor.render` and `renderDetailed` accept an optional `annotationTime` in source-recording seconds, filtering visibility without changing the canvas layout. ([#75])

### Changed

- **Breaking for recording-export API callers:** `RecordingExporter.FrameRenderer` now receives `(CGImage, TimeInterval)` rather than only an image. The second argument is the frame's source-recording time, not time since the trim start; pass it to the compositor's `annotationTime` to apply annotation ranges. ([#75])

## [1.6.0] - 2026-11-03

### Added

- Direct downloads can now check, download and install verified updates in-app with Sparkle 2, asking before downloading and again before installation and relaunch. Check manually from either menu or Preferences → About, or opt into Daily, Weekly or Monthly checks; automatic checks are off by default. Homebrew installations keep using Homebrew and show its update command with a copy button. **Updating from 1.5.5 or earlier:** install this release once manually or with Homebrew before using in-app updates. ([#72])

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

[Unreleased]: https://github.com/MrAshRhodes/glint/compare/v1.9.2...HEAD
[1.9.2]: https://github.com/MrAshRhodes/glint/compare/v1.9.1...v1.9.2
[1.9.1]: https://github.com/MrAshRhodes/glint/compare/v1.9.0...v1.9.1
[1.9.0]: https://github.com/MrAshRhodes/glint/compare/v1.8.2...v1.9.0
[1.8.2]: https://github.com/MrAshRhodes/glint/compare/v1.8.1...v1.8.2
[1.8.1]: https://github.com/MrAshRhodes/glint/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/MrAshRhodes/glint/compare/v1.7.0...v1.8.0
[1.7.0]: https://github.com/MrAshRhodes/glint/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/MrAshRhodes/glint/compare/v1.5.5...v1.6.0
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
[#132]: https://github.com/MrAshRhodes/glint/issues/132
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
[#72]: https://github.com/MrAshRhodes/glint/issues/72
[#74]: https://github.com/MrAshRhodes/glint/issues/74
[#75]: https://github.com/MrAshRhodes/glint/issues/75
[#78]: https://github.com/MrAshRhodes/glint/issues/78
[#79]: https://github.com/MrAshRhodes/glint/issues/79
[#80]: https://github.com/MrAshRhodes/glint/issues/80
[#81]: https://github.com/MrAshRhodes/glint/issues/81
[#88]: https://github.com/MrAshRhodes/glint/issues/88
[#92]: https://github.com/MrAshRhodes/glint/issues/92
[#96]: https://github.com/MrAshRhodes/glint/issues/96
[#97]: https://github.com/MrAshRhodes/glint/issues/97
[#98]: https://github.com/MrAshRhodes/glint/issues/98
[#99]: https://github.com/MrAshRhodes/glint/issues/99
[#100]: https://github.com/MrAshRhodes/glint/issues/100
[#101]: https://github.com/MrAshRhodes/glint/issues/101
[#102]: https://github.com/MrAshRhodes/glint/issues/102
[#103]: https://github.com/MrAshRhodes/glint/issues/103
[#104]: https://github.com/MrAshRhodes/glint/issues/104
[#105]: https://github.com/MrAshRhodes/glint/issues/105
[#106]: https://github.com/MrAshRhodes/glint/issues/106
[#107]: https://github.com/MrAshRhodes/glint/issues/107
[#108]: https://github.com/MrAshRhodes/glint/issues/108
[#109]: https://github.com/MrAshRhodes/glint/issues/109
[#110]: https://github.com/MrAshRhodes/glint/issues/110
[#111]: https://github.com/MrAshRhodes/glint/issues/111
[#112]: https://github.com/MrAshRhodes/glint/issues/112
[#113]: https://github.com/MrAshRhodes/glint/issues/113
[#114]: https://github.com/MrAshRhodes/glint/issues/114
