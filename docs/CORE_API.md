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
- `WindowFrameSettings(style: .none/.macOS/.browser, dark, title)`, `BorderStyle` (outer stroke),
  `Tilt(x,y)` degrees (`Tilt(uiX:uiY:)` maps 0…30 sliders, 15 neutral), `Rotation`
  (`.none/.cw90/.cw180/.cw270`), `WatermarkSettings` (text/image, 9 positions, opacity, size, colour).
- `RenderSettings`: `padding, inset, insetColor?, cornerRadius, shadow, background, aspectRatio,
  border, windowFrame, tilt, rotation, flipHorizontal, flipVertical, watermark, autoBalance, outputScale`.
  `RenderSettings.default`.
- `Preset(id,name,settings)`; `PresetStore(url:)` (`presets`, `defaultPresetID`, `add/update/delete/rename`,
  `load()/save()`, `exportPresets(to:)`, `importPresets(from:) -> Int`, `PresetStore.defaultURL` =
  `~/Library/Application Support/Glint/presets.json`, `Preset.builtIn`).

## Compositor
```swift
Compositor.render(image: CGImage, settings: RenderSettings, annotations: [Annotation] = [],
                  backingScale: CGFloat = 1, backgroundImage: CGImage? = nil) -> CGImage
Compositor.renderDetailed(...) -> RenderResult   // image + layout + border
Compositor.layout(contentSize:insetApplied:settings:backingScale:) -> RenderLayout // canvas/card/content rects (px, top-left)
```
Pipeline: auto-balance crop → annotations baked into content (redactions destroy pixels) → rotate/flip →
inset band → window frame → rounded card + two-layer shadow → background → aspect-ratio fit → tilt → watermark.
`backgroundImage` supplies the wallpaper for `.image` styles (else loaded from path).

## Annotations
`Annotation(id,z,kind,style)`; `AnnotationKind`: `.arrow(from,to) .line(from,to) .rectangle(CGRect)
.ellipse(CGRect) .pen([CGPoint]) .highlighter([CGPoint]) .text(origin,String,maxWidth) .counter(center,Int)
.blur(CGRect) .pixelate(CGRect) .redact(CGRect) .spotlight(CGRect) .emoji(center,String)`.
`AnnotationStyle(color, fill?, strokeWidth, opacity, fontName, fontSize, bold, intensity, dashed, cornerRadius)`.
`annotation.boundingBox`, `.translated(by:)`, `Annotation.isRedaction`.
`AnnotationRenderer.draw(in ctx: CGContext, annotations:, imageSize:, source: CGImage?)` — `ctx` must map
image space (top-left, y down) onto the target (e.g. flipped context). `AnnotationRenderer.bake(source:annotations:) -> CGImage`.
Blur/pixelate/redact sample the *source* pixels; `.redact` is always drawn fully opaque.

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
- `AutoRedactOptions(detector:, style: .solid/.blur/.pixelate, color:, padding:)`;
  `AutoRedact.run(_ image:, options:) async -> [Annotation]`; `AutoRedact.annotations(for lines:, options:)`.

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
`fileNameTemplate`, `exportFormat`, `exportScale`, `lastRenderSettings`, `annotationColor`, `redactColor`;
`AppPreferences.Key`, `resetToDefaults()`.
`KeyCombo(keyCode, modifiers: KeyModifiers)` with `.displayString`, `.carbonModifiers`; `HotkeyAction`
(`captureArea` ⌃⌥⌘4, `captureAreaToClipboard` ⌃⌥⌘5, `captureWindow` ⌃⌥⌘6, `captureFullscreen` ⌃⌥⌘3,
`captureText` ⌃⌥⌘7, `repeatLast` ⌃⌥⌘R); `HotkeyAction.defaultCombo`.
