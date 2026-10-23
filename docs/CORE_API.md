# GlintCore public API

`import GlintCore`. All value types are `Codable, Equatable, Sendable`. Pixel images are `CGImage`
(sRGB, RGBA8 premultiplied). **Image space = pixels, origin top-left, y down** (annotations, OCR boxes,
crop rects). Units for `RenderSettings` lengths are *points*; the compositor multiplies by `backingScale`
(after flooring to an integer number of points,).

## Colour / image utilities (`Utilities.swift`)
- `RGBAColor(r,g,b,a)` (0…1) · `RGBAColor(hex:"#RRGGBB[AA]")?` · `.hexString` · `.cgColor` · `.nsColor` ·
  `RGBAColor.white/.black/.red/.clear`.
- `ColorSpaces.sRGB`; `GlintImageIO.load(url:) -> CGImage?` (EXIF-orientation applied), `GlintImageIO.load(data:)`,
  `CGImage.glintSRGB() -> CGImage` (convert), `GlintBitmap.makeContext(width:height:)`,
  `CGImage.glintCropped(to: CGRect)`.

## Models
- `BackgroundStyle` enum: `.solid(RGBAColor)`, `.linear(LinearGradient)` (`angle` CSS degrees: 0 = to top,
  90 = to right; `stops:[GradientStop]`), `.mesh(MeshGradient)` (base colour + radial blobs),
  `.pattern(PatternStyle)` (dots/grid/stripes/checker/noise), `.image(path:String, fit:ImageFit)`,
  `.transparent`.
- `BackgroundCatalog.all: [BackgroundPreset]` (id, name, category, style; ≥ 24 original presets),
  `BackgroundCatalog.preset(id:)`, `.defaultID`.
- `ShadowSettings` (`enabled`, `strength` 0…100, `customLayers: [ShadowLayer]?`, `color`),
  `.resolvedLayers` (two layers contact + ambient derived from strength; 50 is the default look),
  `ShadowLayer(opacity, blur, offsetX, offsetY)` in points.
- `AspectRatioPreset`: `.auto, .square (1:1), .r4x3, .r3x2, .r16x9, .r9x16, .r4x5, .twitterPost, .twitterHeader, .linkedInPost, .instagramSquare, .instagramPortrait, .facebookPost, .youTubeThumbnail, .openGraph, .pinterestPin, .custom(w,h)`; `.ratio: CGFloat?`,
  `.displayName`, `.recommendedPixelSize`, `AspectRatioPreset.parse("4:3" | "1200x630")`, `.allBuiltIn`.
- `WindowFrameSettings(style:dark:title:screenEffects:)`: decorative chrome around the card. `WindowFrameKind`
  raw values are persisted in presets and never renamed: `.none`; windows `.macOS`, `.browser`, `.ide` (code
  editor), `.terminal`; devices `.phone`, `.retro` (retro monitor), `.handheld` (handheld console); playful
  `.arcade` (pixel arcade), `.comic` (comic panel), `.filmStrip`, `.photo` (photo print). Each kind has
  `displayName`, `category: WindowFrameCategory?` (`.window/.device/.playful`, nil for `.none`),
  `titlePlaceholder` (what `title` means, e.g. address, file name, caption) and `metrics: FrameMetrics`
  (`insets: FrameInsets(top:left:bottom:right:)` in points, `corner: FrameCornerRule` (`.user`,
  `.atLeast(pt)`, `.fixed(pt)`; `resolve(_:)` applies it to `cornerRadius`), `supportsScreenEffects`).
  `screenEffects` (default `true`, only encoded when `false`) toggles the subtle scanlines and glare of styles
  that support them. `insets`/`metrics`/`barHeight` (= `insets.top`) are shortcuts. Client code that switches
  exhaustively over `WindowFrameKind` must handle the new cases. `BorderStyle` (outer stroke),
  `Tilt(x,y)` degrees (`Tilt(uiX:uiY:)` maps 0…30 sliders, 15 neutral), `Rotation`
  (`.none/.cw90/.cw180/.cw270`), `WatermarkSettings` (text/image, 9 positions, opacity, size, colour).
- `RenderSettings`: `padding, inset, insetColor?, cornerRadius, shadow, background, aspectRatio,
  border, windowFrame, tilt, rotation, flipHorizontal, flipVertical, watermark, autoBalance, outputScale`.
  `RenderSettings.default`.
- `Preset(id,name,settings)`; `PresetStore(url:)` (`presets`, `defaultPresetID`, `add/update/delete/rename`,
  `uniqueName(_:)` (`base`, else first unused `base 2`, `base 3`, …),
  `load()/save()`, `exportPresets(to:)`, `importPresets(from:) -> Int`, `PresetStore.defaultURL` =
  `~/Library/Application Support/Glint/presets.json`, `Preset.builtIn`).

## Compositor
```swift
Compositor.render(image: CGImage, settings: RenderSettings, annotations: [Annotation] = [],
                  backingScale: CGFloat = 1, backgroundImage: CGImage? = nil,
                  wallpaper: CGImage? = nil) throws -> CGImage
Compositor.renderDetailed(...) throws -> RenderResult   // image + layout + border
Compositor.layout(contentSize:insetApplied:settings:backingScale:) -> RenderLayout // canvas/card/screen/content rects (px, top-left)
```
Pipeline: auto-balance crop → annotations baked into content (Solid and Pixelate replace covered pixels) → rotate/flip →
inset band → window frame → rounded card + two-layer shadow → background → aspect-ratio fit → tilt → watermark.
`RenderLayout.screenRect` is the content plus its inset band; the frame's insets surround it inside `cardRect`,
so `contentRect` (where annotations land) is offset by the frame's left and top insets. Frames are drawn
deterministically by the compositor, so the editor preview and exports show the same frame.
`backgroundImage` supplies the wallpaper for `.image` styles (else loaded from path).
Rendering fails closed: if annotations cannot be baked in (e.g. the bitmap allocation fails), `render` throws
`RenderError.annotationsNotApplied` instead of returning the unredacted source, and every export path
(editor copy/save/share/drag, direct capture export, `--render`) aborts with an error.
The editor retains the image and annotations and offers **Retry** for the failed action, rendering again
with the current edits. Save retries keep the chosen destination and format; after retrying a drag export,
drag the **Drag to share** tile again to choose a destination. Capture auto-redaction and rendering failures offer
**Retry** or **Discard Capture**, retaining the same capture in memory and preserving required redactions.
Retries do not recapture the screen, repeat a raw-history save, or create a raw recovery file. This is
in-memory recovery, not protection against quitting or a crash. The CLI still exits with an error;
its input file is unchanged.

## Annotations
`Annotation(id,z,kind,style)`; `AnnotationKind`: `.arrow(from,to) .line(from,to) .rectangle(CGRect)
.ellipse(CGRect) .pen([CGPoint]) .highlighter([CGPoint]) .text(origin,String,maxWidth) .counter(center,Int)
.blur(CGRect) .pixelate(CGRect) .redact(CGRect) .spotlight(CGRect) .emoji(center,String)`.
`AnnotationStyle(color, fill?, strokeWidth, opacity, fontName, fontSize, bold, intensity, dashed, cornerRadius,
redactionPattern, redactionSecondaryColor, pixelateHighlight)`.
`annotation.boundingBox`, `.translated(by:)`, `Annotation.isRedaction` (solid/pixelate), `.isObfuscation` (blur only).
`AnnotationRenderer.draw(in ctx: CGContext, annotations:, imageSize:, source: CGImage?)` — `ctx` must map
image space (top-left, y down) onto the target (e.g. flipped context). `AnnotationRenderer.bake(source:annotations:) -> CGImage?` (nil on failure).
`.redact` and `.pixelate` replace covered pixels completely, regardless of color alpha or annotation opacity.
Solid defaults to `redactionPattern: .plain`; `.checkerboard` alternates `color` and
`redactionSecondaryColor`, with no transparent gaps. Pixelate draws a deterministic decorative mosaic from a
non-sensitive palette, never from source pixels. `pixelateHighlight: true` incorporates `color` as an accent
without removing the mosaic. `intensity` controls tile size in image pixels. New appearance fields decode
older annotations using plain fill, a light secondary color, and no pixelation highlight.
Blur alone samples source pixels and is obfuscation, not secure redaction: information may be recoverable,
so do not use it for secrets. It retains its opacity-independent rendering behavior.
Exported images contain the flattened replacement, not editable layers or embedded originals. This does
not erase original images, separately saved raw captures, or the editor's in-memory undo history.

`RedactionStyle` (`solid`, `blur`, `pixelate`) describes manual modes only, with `.displayName` and
`.isObfuscation`. The editor's **Redact / Obfuscate** tool starts in Solid redaction mode for each image.
The current-style label is a native menu for Solid, Blur, or Pixelate; the Redact icon and `3` shortcut
activate the tool without cycling modes. Inspector appearance controls edit patterns, colors, mosaic
highlight, and tile size. Only Blur shows an unsafe-for-secrets warning. Appearance defaults are local
to the editor session; automatic redaction remains plain opaque Solid.

## AutoBalance
`AutoBalance.detectBorder(in:maxPixels:) -> BorderInfo?` (`color`, `perimeterFraction`, `margins`),
`AutoBalance.balanceCropRect(imageSize:border:) -> CGRect` (may extend beyond image),
`AutoBalance.crop(_:to:fill:) -> CGImage`, `AutoBalance.balance(_:) -> BalanceResult?`.

## OCR / redaction
- `TextRecognizer.recognize(in:) async throws -> [RecognizedLine]` (`text`, `box`, `words`, `confidence`,
  `rect(for: Range<String.Index>)`).
- `SensitiveCategory` (`email, phone, creditCard, ipAddress, apiKey, ssn, url, macAddress, custom`),
  `SensitiveInfoOptions(categories:, customWords:, caseSensitive:)` (+ `.default`, `.all`),
  `SensitiveInfoDetector(options:).matches(in: String) -> [SensitiveMatch]`,
  `.findings(in: [RecognizedLine]) -> [SensitiveFinding]` (rect + category), `Luhn.isValid(_:)`.
- `AutoRedactOptions(detector:, color:, padding:, recognizer:)`;
  `AutoRedact.run(_ image:, options:) async -> [Annotation]`; `AutoRedact.annotations(for lines:, options:)`.
  Automatic redaction always generates solid `.redact` annotations, independent of the manual mode.
  Detection is a first pass, not a guarantee; review the exported image before sharing.

API migration: `AutoRedactOptions.style` and its initializer argument have been removed. Remove `style:`
from automatic-redaction calls. Explicit `.blur` annotations are manual obfuscation;
`.pixelate` now means secure source-independent replacement, not conventional source-derived pixelation.
`Annotation.isRedaction` includes `.redact` and `.pixelate`; `.isObfuscation` identifies only `.blur`.
Annotation case names and their serialized representations are unchanged.

## Export / paths
- `ExportFormat`: `.png(interlaced:)` (`.plainPNG`), `.jpeg(quality:)`, `.heic(quality:)`, `.tiff`; `.fileExtension`.
  `ExportScale`: `.original, .x1, .x2` (relative to the image's backing scale).
- `Exporter.data(for:format:scale:backingScale:) throws -> Data`, `Exporter.write(_:to:format:scale:backingScale:)`,
  `Exporter.copyToClipboard(_ image: CGImage)` (PNG on `NSPasteboard`).
- `OutputPaths(historyDirectory:, saveDirectory:, fileNameTemplate:)`: `rawURL(date:)`, `outputURL(date:)`,
  `saveURL(date:format:)`, `FileNaming.fileName(template:date:uuid:)` (`{datetime}` = `yyyy-MM-dd-HH.mm.ss`,
  `{uuid}`), `FileNaming.uniqueURL(directory:baseName:ext:)` (collision → `-2`, `-3`…). Default template
  `Glint-{datetime}`; raw = `Glint-{datetime}-{uuid}.png` in `Raw/`, output in `Output/`.

## Preferences
`AppPreferences(defaults:)` (`.shared`), typed properties for folders, `saveHistory`, `saveRaw`, `saveOutput`,
`copyToClipboardAfterCapture`, `openEditorAfterCapture`, `autoBalance`, `autoRedact` + `autoRedactOptions`,
`defaultPresetName`, `hotkeys`, `hideDockIcon`, `launchAtLogin` (value only; app registers the login item),
`soundsEnabled`, `notificationsEnabled`, `theme` (`AppTheme`), `closeAfterCopy`, `hideWindowsDuringCapture`,
`fileNameTemplate`, `exportFormat`, `exportScale`, `lastRenderSettings`, `rememberSettings` (whether the editor
starts from `lastRenderSettings` instead of the default preset; until set, on unless `defaultPresetName` is set),
`annotationColor`, `redactColor`;
`AppPreferences.Key`, `resetToDefaults()`.
The `AppPreferences.redactStyle` property has been removed. The legacy `glint.redactStyle` key is ignored
by editing and automatic redaction, and is still cleared by `resetToDefaults()`. Manual mode is not persisted.
`KeyCombo(keyCode, modifiers: KeyModifiers)` with `.displayString`, `.carbonModifiers`; `HotkeyAction`
(`captureArea` ⌃⌥⌘4, `captureAreaToClipboard` ⌃⌥⌘5, `captureWindow` ⌃⌥⌘6, `captureFullscreen` ⌃⌥⌘3,
`captureText` ⌃⌥⌘7, `repeatLast` ⌃⌥⌘R); `HotkeyAction.defaultCombo`.
