import AppKit
import Combine
import GlintCore

enum EditorTool: String, CaseIterable {
    case select, text, arrow, redact, shape, pen, highlighter, counter

    var title: String {
        switch self {
        case .select: return "Select"
        case .text: return "Text"
        case .arrow: return "Arrow"
        case .redact: return "Redact / Obfuscate"
        case .shape: return "Shape"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .counter: return "Counter"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .text: return "textformat"
        case .arrow: return "arrow.up.right"
        case .redact: return "eye.slash"
        case .shape: return "square.on.circle"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .counter: return "1.circle"
        }
    }

    var keyHint: String {
        switch self {
        case .select: return "V"
        case .text: return "1"
        case .arrow: return "2"
        case .redact: return "3"
        case .shape: return "4"
        case .pen: return "P"
        case .highlighter: return "H"
        case .counter: return "C"
        }
    }

    var tip: String {
        switch self {
        case .select: return "Click to select, drag to move, Delete removes"
        case .text: return "Click to add text (press 1 again to change size)"
        case .arrow: return "Drag to draw an arrow (press 2 again for a plain line); hold Shift for 45°"
        case .redact: return "Choose Solid or Pixelate for secrets; Blur only obscures. Use the style menu to change mode."
        case .shape: return "Drag to draw a shape (press 4 again to change shape); hold Shift for squares"
        case .pen: return "Draw freehand"
        case .highlighter: return "Highlight with a translucent stroke"
        case .counter: return "Click to place numbered markers"
        }
    }
}

enum ShapeVariant: String, CaseIterable {
    case rectangle, rounded, ellipse, line
    var next: ShapeVariant {
        let all = ShapeVariant.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum TextSizeVariant: Double, CaseIterable {
    case small = 15, normal = 30, big = 55
    var next: TextSizeVariant {
        let all = TextSizeVariant.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum ZOrderMove { case forward, backward, front, back }

struct Preview {
    var image: CGImage
    var layout: RenderLayout
    var mapper: CanvasMapper
}

@MainActor
final class EditorModel: ObservableObject {
    let image: CGImage
    let backingScale: CGFloat
    let rawURL: URL?
    let source: String?
    let preferences: AppPreferences
    let presetStore: PresetStore
    /// Set when the editor only designs a preset; the image is a throwaway preview.
    let design: PresetDesign?
    let undoManager = UndoManager()

    @Published var settings: RenderSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.usesDesktopWallpaper != oldValue.usesDesktopWallpaper { refreshWallpaper() }
            if design == nil {
                preferences.lastRenderSettings = settings
                preferences.autoBalance = settings.autoBalance
            }
            requestRender()
        }
    }
    @Published private(set) var annotations: [Annotation] = [] {
        didSet { requestRender() }
    }
    @Published var selection: Set<UUID> = []
    @Published var tool: EditorTool = .select
    @Published var shapeVariant: ShapeVariant = .rectangle
    @Published var arrowIsLine = false
    @Published var redactStyle: RedactionStyle = .solid
    @Published var textSize: TextSizeVariant = .normal
    @Published var defaultStyle: AnnotationStyle
    @Published var editingID: UUID? {
        didSet { if editingID != oldValue { requestRender() } }
    }
    @Published private(set) var preview: Preview?
    @Published private(set) var wallpaperProblem: String?
    @Published var presets: [Preset] = []
    @Published var statusMessage: String?
    @Published var ocrLines: [RecognizedLine] = []
    @Published var redactOptions: SensitiveInfoOptions
    @Published var redactColor: RGBAColor
    @Published var isBusy = false
    @Published var lastRedactSummary: String?
    @Published var designName: String
    @Published var designMakeDefault = false

    /// Desired preview size in device pixels (set by the canvas).
    var previewTarget = CGSize(width: 1800, height: 1200)

    private var backgroundCache: [String: CGImage] = [:]
    private let recognizeText: (CGImage) async throws -> [RecognizedLine]
    private let wallpaperProvider: @MainActor () -> Result<CGImage, DesktopWallpaperError>
    private var wallpaperImage: CGImage?
    private var rendering = false
    private var dirty = false
    private var scheduled = false
    private var interactionBase: [Annotation]?
    private var styleCoalesceKey: String?
    private var styleEditDate = Date.distantPast
    private var autoRedactIDs: Set<UUID> = []

    typealias Renderer = @Sendable (_ image: CGImage, _ settings: RenderSettings, _ annotations: [Annotation],
                                    _ backingScale: CGFloat, _ backgroundImage: CGImage?,
                                    _ wallpaper: CGImage?) throws -> RenderResult
    static let compositorRenderer: Renderer = { image, settings, annotations, scale, background, wallpaper in
        try Compositor.renderDetailed(image: image, settings: settings, annotations: annotations, backingScale: scale,
                                      backgroundImage: background, wallpaper: wallpaper)
    }
    /// Composes previews and final output; replaceable so tests can force render failures.
    var renderer: Renderer = EditorModel.compositorRenderer

    init(context: EditorContext, preferences: AppPreferences, presetStore: PresetStore, design: PresetDesign? = nil,
         recognizeText: @escaping (CGImage) async throws -> [RecognizedLine] = { try await TextRecognizer.recognize(in: $0) },
         wallpaperProvider: @escaping @MainActor () -> Result<CGImage, DesktopWallpaperError> = { DesktopWallpaper.current() }) {
        self.image = context.image
        self.backingScale = max(context.backingScale, 1)
        self.rawURL = context.rawURL
        self.source = context.source
        self.preferences = preferences
        self.presetStore = presetStore
        self.design = design
        self.designName = design?.name ?? ""
        self.recognizeText = recognizeText
        self.wallpaperProvider = wallpaperProvider
        self.settings = design?.settings ?? EditorHeadless.initialSettings(preferences: preferences, presetStore: presetStore)
        self.redactOptions = preferences.autoRedactOptions
        self.redactColor = preferences.redactColor
        var style = AnnotationStyle(color: preferences.annotationColor)
        style.strokeWidth = 4 * Double(max(context.backingScale, 1))
        style.fontSize = TextSizeVariant.normal.rawValue * Double(max(context.backingScale, 1))
        style.intensity = 14 * Double(max(context.backingScale, 1))
        self.defaultStyle = style
        self.presets = presetStore.presets
        self.designMakeDefault = designIsDefault
        refreshWallpaper()
        requestRender()
        if preferences.autoRedact, design == nil { Task { await self.runAutoRedact(announce: false) } }
    }

    // MARK: State helpers

    var isEditable: Bool {
        settings.tilt.isFlat && settings.rotation == .none && !settings.flipHorizontal && !settings.flipVertical
    }

    var selectedAnnotations: [Annotation] { annotations.filter { selection.contains($0.id) } }

    private func redactionMode(of annotation: Annotation) -> RedactionStyle? {
        switch annotation.kind {
        case .redact: return .solid
        case .blur: return .blur
        case .pixelate: return .pixelate
        default: return nil
        }
    }

    var activeRedactionModes: Set<RedactionStyle> {
        if selection.isEmpty { return tool == .redact ? [redactStyle] : [] }
        return Set(selectedAnnotations.compactMap { redactionMode(of: $0) })
    }

    var currentRedactStyle: RedactionStyle {
        selectedAnnotations.compactMap { redactionMode(of: $0) }.first ?? redactStyle
    }

    func redactionAppearance(for mode: RedactionStyle) -> AnnotationStyle {
        if let selected = selectedAnnotations.first(where: { redactionMode(of: $0) == mode }) {
            return selected.style
        }
        var style = defaultStyle
        style.color = redactColor
        return style
    }

    var showsObfuscationWarning: Bool {
        activeRedactionModes.contains(.blur)
    }

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    private var pixelScale: Double { Double(backingScale) }

    // MARK: Rendering

    private func refreshWallpaper() {
        wallpaperImage = nil
        wallpaperProblem = nil
        guard settings.usesDesktopWallpaper else { return }
        switch wallpaperProvider() {
        case .success(let image): wallpaperImage = image
        case .failure(let error): wallpaperProblem = error.localizedDescription
        }
    }

    func chooseBackground(_ background: BackgroundStyle) {
        var updated = settings
        updated.background = background
        updated.usesDesktopWallpaper = false
        settings = updated
    }

    func requestRender() {
        dirty = true
        guard !scheduled else { return }
        scheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard let self else { return }
            self.scheduled = false
            self.kick()
        }
    }

    private func previewScale() -> CGFloat {
        let size = image.pixelSize
        let est = Compositor.layout(contentSize: size, insetApplied: settings.inset >= 1, settings: settings,
                                    backingScale: backingScale)
        let target = previewTarget
        guard est.canvasSize.width > 0, est.canvasSize.height > 0 else { return 1 }
        let fit = min(target.width / est.canvasSize.width, target.height / est.canvasSize.height)
        return max(0.05, min(1, fit))
    }

    private func backgroundImage(for settings: RenderSettings) -> CGImage? {
        guard case .image(let path, _) = settings.background else { return nil }
        if let cached = backgroundCache[path] { return cached }
        let loaded = GlintImageIO.load(url: URL(fileURLWithPath: path))
        if let loaded { backgroundCache[path] = loaded }
        return loaded
    }

    private func kick() {
        guard !rendering, dirty else { return }
        dirty = false
        rendering = true
        var s = settings
        s.outputScale = settings.outputScale * Double(previewScale())
        let bg = backgroundImage(for: settings)
        let wallpaper = wallpaperImage
        let img = image, scale = backingScale
        let anns = annotations.filter { $0.id != editingID }
        let renderer = self.renderer
        Task.detached(priority: .userInitiated) { [weak self] in
            let r: RenderResult
            do {
                r = try renderer(img, s, anns, scale, bg, wallpaper)
            } catch {
                // Fail closed: never fall back to unannotated pixels; keep the last good preview.
                let message = error.localizedDescription
                await MainActor.run { self?.failRender(message) }
                return
            }
            var region = CGRect(origin: .zero, size: img.pixelSize)
            if let b = r.border { region = AutoBalance.balanceCropRect(imageSize: img.pixelSize, border: b) }
            let p = Preview(image: r.image, layout: r.layout,
                            mapper: CanvasMapper(region: region.integral, contentRect: r.layout.contentRect))
            await MainActor.run { self?.finishRender(p) }
        }
    }

    private func finishRender(_ p: Preview) {
        preview = p
        rendering = false
        if dirty { kick() }
    }

    private func failRender(_ message: String) {
        statusMessage = message
        rendering = false
        if dirty { kick() }
    }

    func updatePreviewTarget(_ size: CGSize) {
        guard size.width > 10, size.height > 10 else { return }
        let old = previewTarget
        previewTarget = size
        if abs(old.width - size.width) / max(old.width, 1) > 0.1 || abs(old.height - size.height) / max(old.height, 1) > 0.1 {
            requestRender()
        }
    }

    /// Full-resolution output with every annotation burned in.
    /// Throws (e.g. `RenderError.annotationsNotApplied`) rather than returning unredacted pixels.
    func renderFinal() throws -> CGImage {
        try renderer(image, settings, annotations, backingScale, backgroundImage(for: settings), wallpaperImage).image
    }

    // MARK: Annotation editing

    private func nextZ() -> Int { (annotations.map(\.z).max() ?? -1) + 1 }

    func setAnnotations(_ new: [Annotation], actionName: String?) {
        let old = annotations
        guard old != new else { return }
        styleCoalesceKey = nil
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setAnnotations(old, actionName: actionName) }
        }
        if let actionName, !undoManager.isUndoing, !undoManager.isRedoing { undoManager.setActionName(actionName) }
        annotations = new
        selection = selection.filter { id in new.contains { $0.id == id } }
        objectWillChange.send()
    }

    func beginInteraction() { interactionBase = annotations }

    /// Applies a live (non-undoable) change during a drag.
    func updateLive(_ new: [Annotation]) { annotations = new }

    func endInteraction(actionName: String) {
        guard let base = interactionBase else { return }
        interactionBase = nil
        let final = annotations
        guard final != base else { return }
        annotations = base
        setAnnotations(final, actionName: actionName)
    }

    func cancelInteraction() {
        if let base = interactionBase { annotations = base }
        interactionBase = nil
    }

    func makeAnnotation(_ kind: AnnotationKind) -> Annotation {
        var style = defaultStyle
        let k = pixelScale
        switch kind {
        case .highlighter:
            style.color = RGBAColor(r: 1, g: 0.86, b: 0.1)
            style.strokeWidth = 22 * k
            style.opacity = 0.5
        case .redact, .pixelate:
            style.color = redactColor.with(alpha: 1)
            style.redactionSecondaryColor = style.redactionSecondaryColor.with(alpha: 1)
            style.opacity = 1
            style.cornerRadius = 0
        case .text:
            style.fontSize = defaultStyle.fontSize
        case .counter:
            style.fontSize = max(defaultStyle.fontSize * 0.65, 18 * k)
        case .rectangle where shapeVariant == .rounded && tool == .shape:
            style.cornerRadius = 16 * k
        default: break
        }
        return Annotation(z: nextZ(), kind: kind, style: style)
    }

    func append(_ a: Annotation) { annotations.append(a) }

    func replace(_ a: Annotation) {
        guard let i = annotations.firstIndex(where: { $0.id == a.id }) else { return }
        annotations[i] = a
    }

    func nextCounterNumber() -> Int {
        let nums = annotations.compactMap { a -> Int? in if case .counter(_, let n) = a.kind { return n }; return nil }
        return (nums.max() ?? 0) + 1
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        setAnnotations(annotations.filter { !selection.contains($0.id) }, actionName: "Delete")
        selection = []
    }

    func duplicateSelected() {
        let copies = selectedAnnotations.map { a -> Annotation in
            var c = a.translated(by: CGSize(width: 20 * pixelScale, height: 20 * pixelScale))
            c.id = UUID()
            return c
        }
        guard !copies.isEmpty else { return }
        var all = annotations
        var z = nextZ()
        var placed: [Annotation] = []
        for var c in copies { c.z = z; z += 1; placed.append(c) }
        all.append(contentsOf: placed)
        setAnnotations(all, actionName: "Duplicate")
        selection = Set(placed.map(\.id))
    }

    func selectAll() { selection = Set(annotations.map(\.id)) }

    func nudge(dx: CGFloat, dy: CGFloat) {
        guard !selection.isEmpty else { return }
        let d = CGSize(width: dx, height: dy)
        setAnnotations(annotations.map { selection.contains($0.id) ? $0.translated(by: d) : $0 }, actionName: "Move")
    }

    func reorder(_ move: ZOrderMove) {
        guard !selection.isEmpty else { return }
        var arr = annotations.sorted { $0.z < $1.z }
        let sel = selection
        switch move {
        case .front:
            arr = arr.filter { !sel.contains($0.id) } + arr.filter { sel.contains($0.id) }
        case .back:
            arr = arr.filter { sel.contains($0.id) } + arr.filter { !sel.contains($0.id) }
        case .forward:
            if arr.count > 1 { for i in stride(from: arr.count - 2, through: 0, by: -1) where sel.contains(arr[i].id) && !sel.contains(arr[i + 1].id) { arr.swapAt(i, i + 1) } }
        case .backward:
            if arr.count > 1 { for i in 1..<arr.count where sel.contains(arr[i].id) && !sel.contains(arr[i - 1].id) { arr.swapAt(i, i - 1) } }
        }
        for i in arr.indices { arr[i].z = i }
        setAnnotations(arr, actionName: "Arrange")
    }

    /// Edits style of the selection (or only the defaults when nothing is selected).
    func updateStyle(key: String, _ change: (inout AnnotationStyle) -> Void) {
        change(&defaultStyle)
        if key == "color", !selectedAnnotations.contains(where: { $0.isRedaction || $0.isObfuscation }) {
            preferences.annotationColor = defaultStyle.color
        }
        guard !selection.isEmpty else { return }
        var new = annotations
        for i in new.indices where selection.contains(new[i].id) { change(&new[i].style) }
        let coalesce = styleCoalesceKey == key && Date().timeIntervalSince(styleEditDate) < 1
        if coalesce { annotations = new } else { setAnnotations(new, actionName: "Change Style") }
        styleCoalesceKey = key
        styleEditDate = Date()
    }

    func setRedactColor(_ c: RGBAColor) {
        let opaque = c.with(alpha: 1)
        redactColor = opaque
        preferences.redactColor = opaque
        updateRedactionAppearance(actionName: "Change Redaction Colour", matching: { $0.isRedaction }) {
            $0.color = opaque
        }
    }

    private func updateRedactionAppearance(actionName: String, matching: (Annotation) -> Bool,
                                           _ change: (inout AnnotationStyle) -> Void) {
        var updated = annotations
        for i in updated.indices where selection.contains(updated[i].id) && matching(updated[i]) {
            change(&updated[i].style)
        }
        setAnnotations(updated, actionName: actionName)
    }

    func setRedactPattern(_ pattern: RedactionPattern) {
        defaultStyle.redactionPattern = pattern
        updateRedactionAppearance(actionName: "Change Redaction Pattern", matching: { redactionMode(of: $0) == .solid }) {
            $0.redactionPattern = pattern
        }
    }

    func setRedactSecondaryColor(_ color: RGBAColor) {
        let opaque = color.with(alpha: 1)
        defaultStyle.redactionSecondaryColor = opaque
        updateRedactionAppearance(actionName: "Change Checkerboard Colour", matching: { redactionMode(of: $0) == .solid }) {
            $0.redactionSecondaryColor = opaque
        }
    }

    func setPixelateHighlight(_ enabled: Bool) {
        defaultStyle.pixelateHighlight = enabled
        updateRedactionAppearance(actionName: "Change Pixelate Highlight", matching: { redactionMode(of: $0) == .pixelate }) {
            $0.pixelateHighlight = enabled
        }
    }

    func setRedactCellSize(_ size: Double) {
        guard size.isFinite else { return }
        let size = min(max(size, 2 * pixelScale), 60 * pixelScale)
        defaultStyle.intensity = size
        updateRedactionAppearance(actionName: "Change Redaction Cell Size", matching: {
            self.redactionMode(of: $0) == .pixelate
                || (self.redactionMode(of: $0) == .solid && $0.style.redactionPattern == .checkerboard)
        }) { $0.intensity = size }
    }

    func setBlurIntensity(_ intensity: Double) {
        guard intensity.isFinite else { return }
        let intensity = min(max(intensity, 2 * pixelScale), 60 * pixelScale)
        defaultStyle.intensity = intensity
        updateRedactionAppearance(actionName: "Change Blur Intensity", matching: { redactionMode(of: $0) == .blur }) {
            $0.intensity = intensity
        }
    }

    func setRedactStyle(_ mode: RedactionStyle) {
        redactStyle = mode
        let updated = annotations.map { annotation -> Annotation in
            guard selection.contains(annotation.id), redactionMode(of: annotation) != nil else { return annotation }
            var annotation = annotation
            let rect = annotation.boundingBox
            if annotation.isObfuscation && mode != .blur { annotation.style.color = redactColor }
            switch mode {
            case .solid: annotation.kind = .redact(rect)
            case .blur: annotation.kind = .blur(rect)
            case .pixelate: annotation.kind = .pixelate(rect)
            }
            if mode != .blur {
                annotation.style.color = annotation.style.color.with(alpha: 1)
                annotation.style.redactionSecondaryColor = annotation.style.redactionSecondaryColor.with(alpha: 1)
                annotation.style.opacity = 1
                annotation.style.cornerRadius = 0
            }
            return annotation
        }
        setAnnotations(updated, actionName: "Change Redaction Mode")
    }

    // MARK: Tools

    func pressToolKey(_ tool: EditorTool) {
        if self.tool == tool {
            switch tool {
            case .text: textSize = textSize.next; defaultStyle.fontSize = textSize.rawValue * pixelScale
            case .arrow: arrowIsLine.toggle()
            case .shape: shapeVariant = shapeVariant.next
            default: break
            }
        } else {
            self.tool = tool
            if tool != .select { selection = [] }
        }
    }

    func variantDescription() -> String? {
        switch tool {
        case .text: return "\(Int(textSize.rawValue)) pt"
        case .arrow: return arrowIsLine ? "Line" : "Arrow"
        case .shape: return shapeVariant.rawValue.capitalized
        case .redact: return currentRedactStyle.displayName
        default: return nil
        }
    }

    // MARK: Transform

    func rotate(clockwise: Bool) {
        settings.rotation = clockwise ? settings.rotation.rotatedClockwise : settings.rotation.rotatedCounterClockwise
    }

    // MARK: Presets

    func refreshPresets() { presets = presetStore.presets }

    func applyPreset(_ p: Preset) {
        var s = p.settings
        s.autoBalance = settings.autoBalance
        settings = s
    }

    func savePreset(named name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        presetStore.add(name: n, settings: settings)
        persistPresets()
    }

    func renamePreset(_ p: Preset, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if preferences.defaultPresetName == p.name { preferences.defaultPresetName = n }
        presetStore.rename(id: p.id, to: n)
        persistPresets()
    }

    func deletePreset(_ p: Preset) {
        if preferences.defaultPresetName == p.name { preferences.defaultPresetName = nil }
        presetStore.delete(id: p.id)
        persistPresets()
    }

    func setDefaultPreset(_ p: Preset) {
        presetStore.setDefault(id: p.id)
        preferences.defaultPresetName = p.name
        persistPresets()
    }

    var defaultPresetID: UUID? { presetStore.defaultPresetID }

    private func persistPresets() {
        try? presetStore.save()
        refreshPresets()
    }

    // MARK: OCR / redaction

    func runAutoRedact(announce: Bool = true) async {
        isBusy = true
        defer { isBusy = false }
        preferences.autoRedactOptions = redactOptions
        guard let lines = try? await recognizeText(image) else {
            lastRedactSummary = "Text recognition failed."
            return
        }
        ocrLines = lines
        var options = AutoRedactOptions(detector: redactOptions, color: redactColor,
                                        padding: 3 * pixelScale)
        options.recognizer = TextRecognizer.Options()
        let findings = SensitiveInfoDetector(options: redactOptions).findings(in: lines)
        var made = AutoRedact.annotations(for: lines, options: options, imageSize: image.pixelSize)
        var z = nextZ()
        for i in made.indices { made[i].z = z; z += 1 }
        var counts: [SensitiveCategory: Int] = [:]
        for f in findings { counts[f.category, default: 0] += 1 }
        let summary = counts.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.displayName) ×\($0.value)" }.joined(separator: ", ")
        lastRedactSummary = made.isEmpty ? "No sensitive information found." : "Redacted \(made.count): \(summary)"

        var all = annotations.filter { !autoRedactIDs.contains($0.id) }
        all.append(contentsOf: made)
        autoRedactIDs = Set(made.map(\.id))
        setAnnotations(all, actionName: "Auto-Redact")
        if announce, made.isEmpty { NSSound.beep() }
    }

    func detectText() async {
        isBusy = true
        defer { isBusy = false }
        ocrLines = (try? await TextRecognizer.recognize(in: image)) ?? []
        statusMessage = ocrLines.isEmpty ? "No text detected." : "Detected \(ocrLines.count) lines."
    }

    func copyText(_ text: String? = nil) {
        let string = text ?? ocrLines.map(\.text).joined(separator: "\n")
        guard !string.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        statusMessage = "Text copied."
    }
}
