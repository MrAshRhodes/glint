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
                  wallpaper: CGImage? = nil, annotationTime: TimeInterval? = nil) throws -> CGImage
Compositor.renderDetailed(...) throws -> RenderResult   // image + layout + border + region
Compositor.layout(contentSize:insetApplied:settings:backingScale:overflow:) -> RenderLayout // canvas/card/screen/content/overflow rects (px, top-left); overflow defaults to none
```
Pipeline: auto-balance crop → annotations baked into content (Solid and Pixelate replace covered pixels) → rotate/flip →
inset band → window frame → rounded card + two-layer shadow → background → aspect-ratio fit → floating zoom cut-ins → tilt → watermark.
`RenderLayout.screenRect` is the content plus its inset band; the frame's insets surround it inside `cardRect`,
so `contentRect` (where annotations land) is offset by the frame's left and top insets. Frames are drawn
deterministically by the compositor, so the editor preview and exports show the same frame.
Aspect-ratio fitting never grows a canvas beyond the larger of its own area and an internal area budget
(16,384 × 8,192 px), so a very tall scrolling capture with a wide aspect ratio keeps its natural size. The budget
is judged at an output scale of 1, so reduced previews and 1x/2x exports make the same choice.
Canvas expansion: only magnifier (`.magnify`) insets can enlarge the canvas. When an inset (with its outline,
connector, border and shadow) reaches beyond the base region (the auto-balance crop or the full image), the
baked content grows to include it; the auto-balance fill applies only inside the base region and the rest is
transparent. The card (inset band, frame, rounded corners, shadow, border) still wraps only the base content,
and the overflow floats over the background, with padding applied around both. `contentRect` keeps marking the
base content; `RenderLayout.overflowRect` is where the expanded content is drawn (equal to `contentRect` when
nothing overflows). Zoom cut-ins, their borders, outlines and connectors are composited above frame chrome,
screen effects, card corners and borders, even inside the card. Annotations ordered above a cut-in remain
visible over its inset. The first cut-in and all higher-z annotations form an ordered foreground above the frame;
lower-z annotations remain part of the screenshot. Redactions also replace their source pixels before the
frame is drawn. `RenderResult.region` is the base region in image pixels,
for mapping editor coordinates onto `contentRect`. Rotation, flips and tilt carry the overflow with the card.
`backgroundImage` supplies the wallpaper for `.image` styles (else loaded from path).
Both `render` and `renderDetailed` take the final optional `annotationTime` argument. Pass the frame's
source-recording time in seconds to draw only annotations for which `isVisible(at:)` is true. Leave it `nil`
for still-image rendering, which draws all annotations regardless of their ranges. Layout always uses the
complete annotation list, including inactive magnifier insets, so the canvas size and content placement do
not jump as annotations appear or disappear. Active redactions alone replace pixels and protect magnifier
samples for that frame; an inactive redaction does not hide content.
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
`Annotation(id,z,kind,style,visibleRange: AnnotationTiming? = nil)`; `AnnotationKind`: `.arrow(from,to) .line(from,to) .rectangle(CGRect)
.ellipse(CGRect) .pen([CGPoint]) .highlighter([CGPoint]) .text(origin,String,maxWidth) .counter(center,Int)
.blur(CGRect) .pixelate(CGRect) .redact(CGRect) .spotlight(CGRect) .emoji(center,String) .magnify(Magnifier)`.
Client code that switches exhaustively over `AnnotationKind` must handle `.magnify`.
`AnnotationStyle(color, fill?, strokeWidth, opacity, fontName, fontSize, bold, intensity, dashed, cornerRadius,
redactionPattern, redactionSecondaryColor, pixelateHighlight)`.
`annotation.boundingBox`, `.translated(by:)`, `Annotation.isRedaction` (solid/pixelate), `.isObfuscation` (blur only),
`.isMagnifier`.

`AnnotationTiming(start: TimeInterval, end: TimeInterval)` is a visible interval in **source-recording seconds**,
with an inclusive start and exclusive end (`start <= time && time < end`). Set `annotation.visibleRange` to
that interval for any annotation kind, or leave it `nil` for visibility throughout the clip. Annotations
decoded without a range keep the whole-clip behavior. `annotation.isVisible(at: TimeInterval)` tests this
visibility. `AnnotationTiming.isValid` requires finite values with `0 <= start < end`; decoding rejects an
invalid persisted range. If a mutable range is invalid or the timestamp is non-finite, visibility falls
back to showing the annotation rather than hiding a possible redaction.
Trimming does not rebase or rewrite annotation times: a range `[8, 10)` overlaps a trim starting
at 6 s at output times `[2, 4)`. A range outside the trim contributes no visible frames.
Time-limited redaction, pixelation and blur leave content exposed outside their ranges; default to `nil`
for redactions unless every other frame has been checked. Blur is not secure redaction at any time.

### Tracked redactions
`annotation.track: RedactionTrack?` (default `nil`) makes a `.redact` or `.pixelate` annotation follow moving
content. `RedactionTrack(keyframes:uncertainIntervals:analyzedRange:frameBounds:)` stores
`RedactionKeyframe(time:rect:source:)` (`.tracked` or `.manual`, rects in image space),
`RedactionUncertainInterval(start:end:anchorTime:anchorRect:resolution:)` (`resolution` `nil`, `.fixedCover` or
`.keyframes`), the analysed `AnnotationTiming` and the source frame bounds. `annotation.resolved(at:)` returns
the annotation drawn at a source time: keyframes interpolate (tracked samples hold until the next frame), and
unresolved or out-of-range time uses `FailSafeCover.rect(anchor:elapsed:bounds:)`, a padded rect that grows with
the time since the last confident frame. An invalid track covers the whole frame. `Compositor.render` resolves
tracks automatically when `annotationTime` is set. `editingView(at:)` gives the unpadded position for editors;
`setManualKeyframe(at:rect:)`, `removeKeyframe(near:)`, `resolveInterval(containing:as:visibleRange:sourceDuration:)`
and `reopenInterval(containing:)` edit a track.
`RedactionGate.unresolvedIntervals(in:sourceDuration:)` lists time that still needs review (uncertain tracking,
time outside the analysed range, invalid tracks or tracked Blur); `blocksExport(_:range:)` tests an export range
and `validate(_:at:sourceDuration:)` throws `RedactionGateError.unresolvedTracking` so renderers fail closed.
`RedactionTracker(url:)` (Vision-backed, on device) or `RedactionTracker(source:thresholds:makeTracker:)` runs
`track(RedactionTrackingRequest(anchorTime:anchorRect:range:), progress:)` forwards and backwards from the anchor
frame, honours task cancellation, and flags low-confidence results, sudden jumps, size changes and content leaving
the frame as uncertain intervals instead of following them.
Encoded, the optional `track` key holds `keyframes` (`time`, `rect`, `source`), `uncertainIntervals` (`start`,
`end`, `anchorTime`, `anchorRect`, optional `resolution`), `analyzedRange` and `frameBounds`; annotations without
it decode untracked. Tracking is an aid: callers remain responsible for reviewing every frame.

`Magnifier(source:inset:shape:showsSourceOutline:showsConnector:)` (the editor's **Zoom** tool): an enlarged copy
of `source` drawn in `inset`, both `CGRect`s in image space; `inset` may lie partly or fully outside the image
(see canvas expansion above). `shape: MagnifierShape` (`.circle` default, `.rectangle`), `showsSourceOutline`
and `showsConnector` (both default `true`, decoded as defaults when absent); `magnification` =
`inset.width / source.width`. `style.color` colours the border, outline and connector; `style.strokeWidth` sets the border width.
`boundingBox` spans source and inset; `translated(by:)` moves both. The inset samples what lies beneath it:
the source with every active `isRedaction` annotation applied (whatever its z order) plus annotations drawn before it.
It never shows pixels an active redaction covers; if sampling fails it draws a solid `style.color` fill instead.
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
highlight, and tile size. Blur shows an unsafe-for-secrets warning. Recording timing controls also warn when
Solid, Pixelate or Blur is limited to a range, because content outside it is exposed. Appearance defaults
are local to the editor session; automatic redaction remains plain opaque Solid.

## AutoBalance
`AutoBalance.detectBorder(in:maxPixels:) -> BorderInfo?` (`color`, `perimeterFraction`, `margins`),
`AutoBalance.balanceCropRect(imageSize:border:) -> CGRect` (may extend beyond image),
`AutoBalance.crop(_:to:fill:) -> CGImage`, `AutoBalance.balance(_:) -> BalanceResult?`.

## OCR / redaction
- `TextRecognizer.recognize(in:) async throws -> [RecognizedLine]` (`text`, `box`, `words`, `confidence`,
  `rect(for: Range<String.Index>)`).
  Images taller than 4,096 px are read in 4,096 px bands with a 256 px overlap; boxes are mapped back to the
  full image and lines repeated in an overlap are removed, so OCR and auto-redaction cover tall scrolling captures.
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

## Output retention (`OutputRetention.swift`)
Opt-in keeping of the composed images a user copied or dragged, plus age-based cleanup of the images Glint itself
saved to `Output/`. It backs **Reopen Last Image** and **Keep screenshots in Output for**. Nothing is written,
tracked or deleted until the user opts in (`AppPreferences.keepCopiedImages`, or a finite
`AppPreferences.outputRetention`), and everything is paused while `saveHistory` is off; history is never switched
back on. The Output folder is `prefs.outputPaths.outputDirectory`, read on every call, so a changed history folder
is respected.
```swift
public enum OutputRetentionPeriod: Int, CaseIterable, Sendable, Identifiable {
    case forever = 0, oneDay = 1, sevenDays = 7, thirtyDays = 30, ninetyDays = 90
    public init(storedDays: Int)    // unknown or negative → .forever (fail safe)
    public var days: Int?           // nil for .forever
    public var displayName: String  // "Forever", "1 day", "7 days", "30 days", "90 days"
    public var id: Int
}
public enum OutputRetentionSource: String, Codable, Sendable { case copied, dragged, saved }
public struct RetainedOutput: Equatable, Sendable {
    public let url: URL
    public let date: Date           // written or last reused; cleanup ages the file from here
    public let source: OutputRetentionSource
    public let backingScale: CGFloat  // pixels per point of the stored file, to reopen it at the right size
    public let reused: Bool         // an existing tracked file already held this image
    public init(url: URL, date: Date, source: OutputRetentionSource, backingScale: CGFloat, reused: Bool = false)
}
public struct OutputCleanupReport: Equatable, Sendable {
    public var removed: [URL]; public var skippedActive: [URL]; public var untracked: [URL]
    public var failures: [String]; public var isEmpty: Bool
    public init(removed: [URL] = [], skippedActive: [URL] = [], untracked: [URL] = [], failures: [String] = [])
}
public enum OutputRetentionError: Error, Equatable, LocalizedError { case disabled, encodingFailed, writeFailed(String) }

public final class OutputRetention: @unchecked Sendable {
    public init(preferences: AppPreferences, now: @escaping @Sendable () -> Date = { Date() },
                moveToTrash: @escaping @Sendable (URL) throws -> Void = { try OutputRetention.moveToSystemTrash($0) },
                activeFiles: OutputActiveFiles = .shared)
    public var retainsCopies: Bool       // keepCopiedImages && saveHistory
    public var tracksSavedOutputs: Bool  // saveHistory && (keepCopiedImages || outputRetention != .forever)
    public var cleansUp: Bool            // saveHistory && outputRetention != .forever
    public func retain(_ image: CGImage, source: OutputRetentionSource, backingScale: CGFloat) throws -> RetainedOutput
    public func register(savedFile url: URL, image: CGImage, backingScale: CGFloat)
    public func register(savedFile url: URL, image: CGImage, backingScale: CGFloat, exportScale: ExportScale)
    public func latest() -> RetainedOutput?
    public func isManaged(_ url: URL) -> Bool
    public func discard(_ url: URL)
    public func cleanUp() -> OutputCleanupReport
    public static func moveToSystemTrash(_ url: URL) throws
}

/// Files in use for a drag, which `cleanUp()` skips.
public final class OutputActiveFiles: @unchecked Sendable {
    public static let shared: OutputActiveFiles
    public init()
    public func begin(_ url: URL); public func end(_ url: URL); public func contains(_ url: URL) -> Bool
}
```
- Every method is thread-safe and touches the disk (`retain` also encodes the image), so call them off the main
  thread. One process-wide lock, shared by all instances, guards each read-modify-write of the index.
- `retain` takes the **successfully rendered** image (annotations and redactions baked in), never the original
  capture, so call it only after `Compositor.render` has succeeded. It throws `.disabled` unless `retainsCopies`
  (checked again before anything is written, so turning keeping off or moving the Output folder while an image is
  still being encoded writes nothing), writes the image to the Output folder with the user's `exportFormat`/`exportScale` and `OutputPaths.outputURL`
  naming, and records it. It never replaces an existing file, and removes the new file again if it cannot be
  tracked. An image whose pixels match an unchanged tracked file (SHA-256 of normalized sRGB RGBA8 pixels plus
  dimensions) reuses that file (`reused == true`) and refreshes its date instead of writing a duplicate. Report
  a failure, but do not treat the copy or drag it belongs to as failed.
- `register(savedFile:image:backingScale:)` tracks a file Glint just saved to the Output folder, such as the
  auto-saved styled output, as `.saved`, so it can be reopened, deduplicated and expired. No-op unless
  `tracksSavedOutputs`, or when `url` is not a regular file directly inside the current Output folder.
  The three-argument form uses the current export-scale preference. For deferred registration, use
  `register(savedFile:image:backingScale:exportScale:)` with the same export-scale snapshot passed to the writer:
  `.original` records the captured backing scale (or 1 if non-finite/nonpositive), `.x1` records 1 and `.x2`
  records 2. Later preference changes must not change the saved file's recorded density.
- `latest()` returns the newest tracked file that still exists as a regular, non-symlink file directly in the
  current Output folder and prunes entries whose file is gone. Reopen it with GlintEditor's
  `EditorContext(image:backingScale:rawURL:source:isComposed: true)`, passing `RetainedOutput.backingScale` as
  `backingScale` (the stored file's own pixel density, so a later 1×/2× export does not resample it again): the editor
  opens the flattened result without applying a frame or background again. `isManaged(_:)` reports whether the
  index in a URL's own folder tracks it; `discard(_:)` drops an entry without deleting the file.
- `cleanUp()` returns an empty report unless `cleansUp`. It moves expired entries to the Trash through `moveToTrash`;
  an entry expires when `date < now - days`, so an image exactly at the cutoff is kept. It only considers files
  listed in the index that Glint wrote directly inside the current Output folder: never `Raw/`, manual saves or
  exports, untracked or pre-existing files, or subfolders (no recursion), and never a file in `OutputActiveFiles`
  (`skippedActive`, still tracked). An entry whose file is no longer a regular file (such as a symlink), or whose
  size or modification date changed since Glint wrote it, is untracked (`untracked`), not deleted. A file that is
  already gone is just dropped from the index, and one that cannot be read right now is left alone. If the move
  fails, the file and its entry stay and the message is added to `failures`. Each file is judged on fresh state,
  so a preference change or a concurrent `retain` that reuses it is respected.
- The index is the hidden `.glint-output-index.json` in the Output folder: a `version` plus `entries` with a
  `fileName`, `date`, SHA-256 `digest`, `source`, `size`, `modified` and `backingScale`. An entry whose name is not
  a plain file name (empty, `.`, `..`, containing `/`, or the index itself) is dropped on read. Writes are atomic.
  A missing, corrupt or unknown-version index is treated as empty: it never crashes and never causes a deletion.
- The editor's drag cache (`Caches/Glint/Drag`, removed when the editor closes) is separate, and a retained Output
  file is never the editor's drag payload. A quick-access thumbnail drag can offer a file that is already in the
  Output folder, so wrap that drag in `OutputActiveFiles.begin/end` (calls nest) to keep `cleanUp()` from removing
  it. `begin` waits briefly if `cleanUp()` is moving that very file to the Trash at that moment, so check that the
  file still exists after calling it.

## Recording
Recording model, GIF/MP4 exporter, and file and clipboard helpers. GlintCapture hands over a `RecordedVideo`;
the recording editor trims and exports it. `RecordingTrim`, `RecordingExportOptions`, `GIFExportOptions`,
`RecordingFileFormat` and `GIFMaxWidth` are `Codable` so projects can store them (see Projects); the rest are not.
Shortcut: `HotkeyAction.recordScreen` (see Preferences).
```swift
public enum RecordingExporter {
    public typealias ProgressHandler = @Sendable (Double) -> Void
    public typealias FrameRenderer = @Sendable (CGImage, TimeInterval) throws -> CGImage
    public static func export(source: URL, range: ClosedRange<TimeInterval>, options: RecordingExportOptions,
                              outputDirectory: URL? = nil, progress: ProgressHandler? = nil,
                              frameRenderer: FrameRenderer? = nil) async throws -> URL
}
```
- `RecordedVideo(url:duration:pixelSize:deletesFileOnClose:)`: by default `url` is a unique temporary `.mp4` that the
  recording editor owns and deletes when it closes (a reopened project's clip is its private snapshot copy, so it is
  deleted too); pass `deletesFileOnClose: false` for a file someone else owns; `duration` is in seconds, as the capture layer measured it. `RecordingPhase` (for menu and
  status text): `.idle`, `.selecting`, `.ready`, `.countdown(Int)` (seconds left), `.recording`, `.finishing`.
- `export` returns a new `RecordingExport-<UUID>.gif|mp4` in `outputDirectory` (default
  `RecordingExportFiles.defaultWorkingDirectory`, created if missing); the caller owns it, and `source` is only read.
  `validatedRange(_:sourceDuration:)` runs before any frame is read: it throws `invalidRange`, or `rangeTooShort` under
  0.2 s (the whole file if shorter), and clamps an end up to 0.1 s past the duration. `readableDuration(of:)` gives an
  `AVAsset`'s duration (`sourceUnreadable` if it isn't a playable video). `progress` gets 0…1 off the main thread,
  ending with 1. Cancelling the surrounding `Task` deletes the partial file and throws `CancellationError`.
- `frameRenderer` is called for every exported frame with the oriented source frame at full size, before any resizing,
  and its source-recording timestamp in seconds: the requested sample time for GIF, or the presentation time clamped
  to the trim start for MP4. Do not subtract the trim start from that time. The editor passes it as `annotationTime`
  to `Compositor.render`, with the complete annotations list (redactions included), settings and
  background captured at export start. Annotation ranges are therefore evaluated on the same clock in preview,
  GIF/MP4 export and copy. The renderer must return a constant size (else `encodingFailed`). If it throws, the export
  deletes the partial file and rethrows it unchanged; no unrendered frame is ever substituted. Transparency is flattened
  on white. **API migration:** existing frame-renderer closures must accept the second argument; ignore it only when
  the rendering does not depend on annotation timing.
- GIF: `GIFLimits.frameCount(duration:framesPerSecond:)` frames (rounded, at least 1), one every `1/framesPerSecond` s
  from the start of `range`, rendered, scaled down to `maxWidth` (never up) and written one at a time (memory stays near
  one frame), looping forever. A range over the limits throws `gifLimitExceeded` and is never truncated; a rate outside
  `GIFLimits.frameRates` throws `unsupportedFrameRate`.
- MP4 without `frameRenderer`: the whole file is passed through (re-encoded if that fails), a trimmed range gets a
  highest-quality re-encode (a passthrough cut can only start on a keyframe). With one, each frame is decoded, rendered
  and re-encoded as H.264 at its source timing, without audio; odd sizes get white padding at the right and bottom.
- Options: `RecordingExportOptions(format:gif:)`; `RecordingFileFormat` `.gif`/`.mp4` (`fileExtension`, `displayName`,
  `utType`); `GIFExportOptions(framesPerSecond:maxWidth:)`; defaults are `.gif`, 15 fps and `.w640`. `GIFMaxWidth`
  `.w480`/`.w640`/`.w720`/`.original` (`pixelCap` 480/640/720/1280; `outputSize(for:)` keeps the aspect ratio).
- `GIFLimits`: `frameRates` `[10, 15, 20]`, `defaultFrameRate`, `maxDuration` 30 s, `maxFrameCount` 450,
  `originalWidthCap` 1280; `maxDuration(framesPerSecond:)` is the shorter of 30 s and 450 frames (22.5 s at 20 fps);
  `isSupported(framesPerSecond:)`; `estimatedByteCount(duration:options:sourceSize:)` (rough); `format(seconds:)`
  (`12.3 s`, `1:02.3`); `issue(duration:options:)` is nil when a range fits, else a `GIFLimitIssue` (`duration`,
  `framesPerSecond`, `frameCount`, `maxDuration`, plain-language `message`).
- `RecordingTrim(sourceDuration:)`: `start`, `end`, `duration`, `range`, `isFullRange`. `setStart(_:)` and `setEnd(_:)`
  clamp to `0…sourceDuration`, keep the handles at least `shortestDuration` apart (`minimumDuration` 0.2 s, or the whole
  file if shorter) and ignore non-finite values; `setSourceDuration(_:)` adopts the file's duration. To fit a GIF, call
  `limitDuration(to: GIFLimits.maxDuration(framesPerSecond: fps))`: it shortens from the end, only when asked.
- `RecordingExportError` (`LocalizedError`, `Equatable`; each case has a user-facing `errorDescription`):
  `sourceMissing(String)`, `sourceUnreadable(String)`, `invalidRange(start:end:sourceDuration:)`,
  `rangeTooShort(minimum:)`, `unsupportedFrameRate(Int)`, `gifLimitExceeded(GIFLimitIssue)`,
  `frameUnavailable(time:reason:)`, `encodingFailed(String)`, `writeFailed(String)`, `exportSessionFailed(String)`,
  `pasteboardWriteFailed`.
- `RecordingExportFiles`: `defaultFileName(format:date:timeZone:)` gives `Glint Recording 2026-11-05 at 14.29.16.gif`;
  `makeStagingDirectory(forDestination:)` makes a fresh empty folder, on the destination's volume when possible, that
  the caller removes; `commit(_:to:)` creates missing folders and replaces an existing file in one step, so a failure
  never leaves a half-written destination (no `-2` renaming: confirm overwrites yourself). To save: stage,
  `export(…, outputDirectory: staging)`, `commit`, remove the staging folder.
- `RecordingPasteboard.copy(_:format:to:directory:now:)` moves the exported file into a new subfolder of `directory`
  (default `defaultDirectory`, `Caches/Glint/Clipboard/Recordings`), puts it on the pasteboard (default `.general`) and
  returns the new URL; on failure the file stays where it was. A GIF goes on as `public.gif` data plus a file URL, an
  MP4 as a file URL only. Copies are kept for `retention` (24 h); each copy first runs
  `pruneExpired(in:now:retention:)`.

## Scrolling capture (`ScrollStitcher.swift`, `ScrollCapturePolicy.swift`)
- `ScrollStitchLimits(maxHeight: 16_384, maxPixels: 64_000_000, warningFraction: 0.9, maxUndoBytes: 16_000_000)`,
  `maxRows(width:)`. `maxUndoBytes` bounds the memory kept only for undo (earlier footers are stored only when
  they changed); past it the oldest steps can no longer be undone but stay in the image.
- `ScrollStitcher(limits:)` stitches same-size frames of a region scrolled downwards: `add(_ image:) ->
  ScrollStitchStep` (`addedRows`, `warning: ScrollStitchWarning?`), `undoLast() -> Bool`, `makeImage() -> CGImage?`,
  `thumbnail(maxWidth:maxHeight:)`, `height`, `width`, `frameHeight`, `frameCount`, `canUndo`, `undoableSteps`,
  `isEmpty`,
  `progress`, `isNearLimit`, `isAtLimit`, `sticky` (detected header/footer rows). Matching is pixel-based on the
  first frame size. Rows that stay fixed between the first two moving frames are treated as a sticky header and
  footer and appear once, at the top and bottom of the result. A frame that is rejected leaves the image unchanged.
- `ScrollStitchWarning`: `lowConfidence(rows:)` (frame added; rows of the result that differed, e.g. animation),
  `ambiguousRepeat`, `noMovement`, `scrolledBack`, `tooFast`, `sizeChanged`, `heightLimit`; `message` and
  `pausesCapture` (every warning except `noMovement`).
- `ScrollSignature(image:columns:)` is a small luma fingerprint of a frame, with `difference(from:)` and
  `shift(from:)` (estimated downward scroll in signature rows). `ScrollGrabPolicy(settleInterval:grabFraction:
  changeThreshold:)` decides when to grab: `shouldGrab(_:at:reference:)`, `reset()`. Grabs happen once the
  content has settled or has moved half a frame since the last grab.

## Projects (`GlintProject.swift`, `ProjectStore.swift`)
Editable `.glint` projects keep the original capture plus the editor state, so every element stays changeable after
reopening. **Privacy:** the original capture includes everything that was redacted; share flattened exports only.
```swift
public struct GlintProject {   // @unchecked Sendable
    var state: ProjectState; var source: ProjectSource; var snapshotDirectory: URL?
    func discardSnapshot(fileManager: FileManager = .default)
}
public enum ProjectState { case screenshot(ScreenshotProjectState), recording(RecordingProjectState) }
public enum ProjectSource { case image(CGImage), video(URL) }
public enum ProjectStore {
    public static func write(_ project: GlintProject, to url: URL, generator: String? = nil,
                             fileManager: FileManager = .default) throws
    public static func read(from url: URL, snapshotRoot: URL = defaultSnapshotRoot) throws -> GlintProject
    public static func removeAllSnapshots(in root: URL = defaultSnapshotRoot, fileManager: FileManager = .default)
}
```
- Package layout (a folder with the `glint` extension, UTI `io.github.mrashrhodes.glint.project`, conforming to
  `com.apple.package`): `manifest.json`, `project.json`, `source/capture.png` or `source/recording.mp4`, and optional
  `assets/background.png` / `assets/watermark.png`.
- `ScreenshotProjectState(settings:annotations:backingScale:source:)` and
  `RecordingProjectState(settings:annotations:trim:options:duration:pixelSize:)` are `Codable`; `ProjectState` encodes
  with a `"kind"` key (`"screenshot"`/`"recording"`) and exposes `settings` and `annotations`. A recording state only
  decodes when `RecordingProjectState.isValid(duration:pixelSize:)`: a finite duration up to `maxDuration` (24 h) and
  whole-pixel sides in `1...maxPixelSide` (16384); a `RecordingTrim` only when `0 ≤ start ≤ end ≤ sourceDuration`. Annotation ranges stay in
  source-recording seconds. A `.screenshot` state needs an `.image` source and `.recording` a `.video` source, else
  `ProjectFormatError.mismatchedSource`.
- `ProjectManifest(format:formatVersion:requiredFeatures:generator:)`: `format` must be `ProjectManifest.formatName`;
  `formatVersion` is `currentFormatVersion` (1). `validate(supportedFeatures:)` runs before `project.json` is decoded:
  a newer version throws `newerVersion`, an unknown required feature `unsupportedFeatures`. `generator` is
  informational only.
- **Extension point:** a later feature that changes how a project renders adds a string to
  `ProjectFeatures.supported` and returns it from `ProjectFeatures.required(by:)` when a project uses it, so older
  builds refuse that project instead of rendering it wrongly. Optional fields that older builds can ignore need no
  feature string; decode them with `decodeIfPresent` and a default.
- `write` encodes into a staging folder next to `url` and swaps it in with one replace, so a failure leaves any
  existing project untouched. Image backgrounds and watermarks are re-encoded into `assets/` (the user's file paths are
  never stored); a desktop-wallpaper background stores only the setting. Recordings are copied in, never moved.
- `read` opens every member relative to the package with `O_NOFOLLOW` (symlinks and folders where a file belongs are
  refused with `unsafeMember`), caps sizes (`ProjectStore.Limits`), never follows paths found in the JSON, and reads
  each member once. Assets are written from their validated bytes, and the video is cloned (or stream-copied) from the
  validated descriptor, into a new private `0700` folder under `snapshotRoot` (default: `GlintProjects` in the
  temporary folder); the returned URLs point there, so later changes to the package can't reach the open editor. The
  project owns that folder (`snapshotDirectory`): call `discardSnapshot()` once nothing reads it any more (the app
  does so when the editor closes and any project save has finished). A failed read leaves no snapshot behind;
  `removeAllSnapshots()` clears leftovers and is meant for launch only. Errors are `ProjectFormatError` (`LocalizedError`): `notAProject`,
  `newerVersion(Int)`, `unsupportedFeatures([String])`, `missingMember(String)`, `unsafeMember(String)`,
  `memberTooLarge(String)`, `damaged(String)`, `mismatchedSource`, `unreadableAsset(String)`, `writeFailed(String)`.
- `ProjectStore.isProject(_:)` checks the extension; `defaultFileName(date:timeZone:)` gives
  `Glint Project 2026-11-05 at 14.29.16.glint`; `contentType` is the exported `UTType`.
- Projects are never output-retention files: `OutputRetention` only manages the images it indexed.

## Preferences
`AppPreferences(defaults:)` (`.shared`), typed properties for folders, `saveHistory`, `saveRaw`, `saveOutput`,
`copyToClipboardAfterCapture`, `openEditorAfterCapture`, `autoBalance`, `autoRedact` + `autoRedactOptions`,
`defaultPresetName`, `hotkeys`, `hideDockIcon`, `launchAtLogin` (value only; app registers the login item),
`soundsEnabled`, `notificationsEnabled`, `theme` (`AppTheme`), `closeAfterCopy`, `hideWindowsDuringCapture`,
`fileNameTemplate`, `exportFormat`, `exportScale`, `lastRenderSettings`, `rememberSettings` (whether the editor
starts from `lastRenderSettings` instead of the default preset; until set, on unless `defaultPresetName` is set),
`keepCopiedImages` (opt-in, off by default: keep copied and dragged composed images for Reopen Last Image; key
`glint.keepCopiedImages`), `outputRetention` (`OutputRetentionPeriod`, `.forever` by default; stored as a day count
under `glint.outputRetentionDays`, where an unknown or negative value reads as `.forever`; see Output retention),
`annotationColor`, `redactColor`;
`AppPreferences.Key`, `resetToDefaults()` (which also restores `keepCopiedImages` and `outputRetention`).
The `AppPreferences.redactStyle` property has been removed. The legacy `glint.redactStyle` key is ignored
by editing and automatic redaction, and is still cleared by `resetToDefaults()`. Manual mode is not persisted.
`KeyCombo(keyCode, modifiers: KeyModifiers)` with `.displayString`, `.carbonModifiers`; `HotkeyAction`
(`captureArea` ⌃⌥⌘4, `captureAreaToClipboard` ⌃⌥⌘5, `captureWindow` ⌃⌥⌘6, `captureFullscreen` ⌃⌥⌘3,
`captureText` ⌃⌥⌘7, `repeatLast` ⌃⌥⌘R, `recordScreen` ⌃⌥⌘9, `captureScrolling` ⌃⌥⌘8); `HotkeyAction.defaultCombo`.
