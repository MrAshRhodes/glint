import AppKit
import Combine
@testable import GlintCore
import Testing
@testable import GlintEditor

/// A look with room around the capture and a background that is not the capture's colour.
private let framedLook = RenderSettings(padding: 10, inset: 0, cornerRadius: 0, shadow: .none,
                                        background: .solid(.black), autoBalance: false)
private let bareLook = RenderSettings(padding: 0, inset: 0, cornerRadius: 0, shadow: .none,
                                      background: .transparent, autoBalance: false)
private let email = RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 20, width: 80, height: 40))
private let redaction = Annotation(kind: .redact(CGRect(x: 10, y: 20, width: 80, height: 40)),
                                   style: AnnotationStyle(color: .black))

private struct RenderFailure: LocalizedError {
    var errorDescription: String? { "The preview could not be composed." }
}

private struct RecognitionFailure: Error {}

/// Holds every render until it is opened, so a test can look at the editor while its first composed preview is
/// still being made. An opened gate lets renders through and only counts them.
private final class RenderGate: @unchecked Sendable {
    private let lock = NSLock()
    private let waiting = DispatchSemaphore(value: 0)
    private var isOpen: Bool
    private var started = 0

    init(open: Bool = false) { isOpen = open }

    var renders: Int { lock.withLock { started } }

    var renderer: EditorModel.Renderer {
        { [self] image, settings, annotations, scale, background, wallpaper, time in
            let open = lock.withLock { () -> Bool in started += 1; return isOpen }
            if !open { waiting.wait() }
            return try Compositor.renderDetailed(image: image, settings: settings, annotations: annotations,
                                                 backingScale: scale, backgroundImage: background,
                                                 wallpaper: wallpaper, annotationTime: time)
        }
    }

    func open() {
        lock.withLock { isOpen = true }
        for _ in 0..<8 { waiting.signal() }
    }
}

/// A text recogniser that answers when the test says so, standing in for Vision's latency.
@MainActor
private final class RecognizerGate {
    private var waiting: CheckedContinuation<[RecognizedLine], Error>?
    private var answer: Result<[RecognizedLine], Error>?
    private(set) var calls = 0

    func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        calls += 1
        if let answer { return try answer.get() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func respond(_ result: Result<[RecognizedLine], Error>) {
        answer = result
        waiting?.resume(with: result)
        waiting = nil
    }
}

/// What a canvas puts on screen, drawn offscreen at 600 × 400 points.
@MainActor
private struct CanvasSnapshot {
    let pixels: PixelBuffer
    let scale: CGFloat

    init(_ canvas: CanvasView) throws {
        canvas.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        canvas.layoutSubtreeIfNeeded()
        let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let image = try #require(rep.cgImage)
        pixels = try #require(PixelBuffer(image))
        scale = CGFloat(pixels.width) / canvas.bounds.width
    }

    /// The box, in points, around the pixels that are clearly the red capture; nil when none are drawn.
    var redBounds: CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let (r, g, b, _) = pixels.pixel(x, y)
                guard r > 180, g < 90, b < 90 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}

/// A white capture with a red block in its top-left corner, so a stand-in that is turned, flipped or cropped
/// differently from the composed preview is told apart by where the red lands.
private func cornerCapture() throws -> CGImage {
    let bitmap = try #require(GlintBitmap.makeContext(width: 100, height: 80))
    bitmap.setFillColor(RGBAColor.white.cgColor)
    bitmap.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
    bitmap.setFillColor(RGBAColor(r: 1, g: 0, b: 0).cgColor)
    bitmap.fill(CGRect(x: 0, y: 50, width: 40, height: 30))
    return try #require(bitmap.makeImage())
}

private func redCapture() throws -> CGImage {
    let bitmap = try #require(GlintBitmap.makeContext(width: 100, height: 80))
    bitmap.setFillColor(RGBAColor(r: 1, g: 0, b: 0).cgColor)
    bitmap.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
    return try #require(bitmap.makeImage())
}

private func expectClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
                && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance,
            "\(a) is not close to \(b)", sourceLocation: sourceLocation)
}

/// Polls until `condition` holds, for at most `timeout` seconds.
@MainActor
private func eventually(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}

@Suite("Editor first frame")
@MainActor
struct ProvisionalPreviewTests {
    struct Orientation: Sendable, CustomTestStringConvertible {
        var rotation: Rotation
        var flipHorizontal = false
        var flipVertical = false

        var testDescription: String { "\(rotation), flipped horizontally \(flipHorizontal), vertically \(flipVertical)" }
    }

    enum Outcome: String, CaseIterable, Sendable {
        case nothingSensitive, recognitionFails

        var result: Result<[RecognizedLine], Error> {
            switch self {
            case .nothingSensitive: return .success([])
            case .recognitionFails: return .failure(RecognitionFailure())
            }
        }

        var summary: String {
            switch self {
            case .nothingSensitive: return "No sensitive information found."
            case .recognitionFails: return "Text recognition failed."
            }
        }
    }

    private func makeModel(_ f: EditorFixture, look: RenderSettings = framedLook, image: CGImage? = nil,
                       autoRedactionApplied: Bool = false, restored: EditorRestoreState? = nil,
                       recognizer: RecognizerGate? = nil) throws -> EditorModel {
        f.preferences.lastRenderSettings = look
        let context = EditorContext(image: try image ?? redCapture(), backingScale: 2, rawURL: nil, source: "test",
                                    restored: restored, autoRedactionApplied: autoRedactionApplied)
        guard let recognizer else {
            return EditorModel(context: context, preferences: f.preferences, presetStore: f.presets)
        }
        return EditorModel(context: context, preferences: f.preferences, presetStore: f.presets,
                           recognizeText: { try await recognizer.recognize($0) })
    }

    // MARK: The capture is the first thing on screen

    @Test func theCaptureIsOnScreenBeforeTheComposedPreviewExists() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let gate = RenderGate(); defer { gate.open() }
        let model = try makeModel(f)
        model.renderer = gate.renderer
        let canvas = CanvasView(model: model)

        let first = try CanvasSnapshot(canvas)
        #expect(model.preview == nil, "The composed preview is still being made")
        let shown = try #require(first.redBounds, "The capture is drawn before anything is composed")
        #expect(abs(shown.width / shown.height - 100.0 / 80.0) < 0.03, "It keeps the capture's proportions")
        #expect(abs(shown.midX - 300) <= 2 && abs(shown.midY - 200) <= 2, "It sits in the middle of the canvas")

        gate.open()
        #expect(await eventually { model.preview != nil })
        let composed = try #require(try CanvasSnapshot(canvas).redBounds)
        expectClose(shown, composed)
        #expect(model.provisional == nil, "Once the composed preview exists the stand-in is gone")
    }

    @Test(arguments: [
        Orientation(rotation: .none), Orientation(rotation: .cw90), Orientation(rotation: .cw180),
        Orientation(rotation: .cw270, flipHorizontal: true), Orientation(rotation: .none, flipVertical: true),
    ])
    func theCaptureStaysWhereTheComposedPreviewPutsIt(_ look: Orientation) async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        var settings = framedLook
        settings.rotation = look.rotation
        settings.flipHorizontal = look.flipHorizontal
        settings.flipVertical = look.flipVertical
        let gate = RenderGate(); defer { gate.open() }
        let model = try makeModel(f, look: settings, image: cornerCapture())
        model.renderer = gate.renderer
        let canvas = CanvasView(model: model)
        let provisional = try #require(model.provisional)
        let standIn = try #require(try CanvasSnapshot(canvas).redBounds)

        gate.open()
        #expect(await eventually { model.preview != nil })
        let preview = try #require(model.preview)
        #expect(preview.layout == provisional.frame.layout, "The same canvas, content and crop")
        #expect(preview.mapper == provisional.mapper)
        expectClose(standIn, try #require(try CanvasSnapshot(canvas).redBounds))
    }

    @Test func theStandInFollowsSettingChangesWhileTheComposedPreviewIsPending() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let gate = RenderGate(); defer { gate.open() }
        let model = try makeModel(f)
        model.renderer = gate.renderer
        let before = try #require(model.provisional).frame.layout

        model.settings.padding = 30
        let after = try #require(model.provisional).frame.layout
        #expect(after.canvasSize.width > before.canvasSize.width)
        #expect(after == Compositor.layout(contentSize: CGSize(width: 100, height: 80), insetApplied: false,
                                           settings: model.settings, backingScale: 2))

        model.settings.tilt = Tilt(x: 20, y: 0)
        #expect(model.provisional == nil, "A tilted card is not drawn from the flat capture")
    }

    @Test func annotationsNeverLetTheRawCaptureShowThrough() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let gate = RenderGate(); defer { gate.open() }
        let canvas = CanvasView(model: try makeModel(f, restored: EditorRestoreState(settings: framedLook,
                                                                                   annotations: [redaction])))
        canvas.model.renderer = gate.renderer
        #expect(canvas.model.provisional == nil)
        #expect(try CanvasSnapshot(canvas).redBounds == nil, "A restored redaction is never drawn around")

        let live = try makeModel(f)
        live.renderer = gate.renderer
        let liveCanvas = CanvasView(model: live)
        #expect(try CanvasSnapshot(liveCanvas).redBounds != nil)
        live.updateLive([redaction])
        #expect(live.provisional == nil)
        #expect(try CanvasSnapshot(liveCanvas).redBounds == nil, "Adding one withdraws the stand-in at once")
    }

    // MARK: Nothing sensitive is shown while automatic redaction is pending

    @Test func nothingIsShownWhileAutomaticRedactionHasYetToRun() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let renders = RenderGate(open: true)
        let recognizer = RecognizerGate()
        let model = try makeModel(f, look: bareLook, recognizer: recognizer)
        model.renderer = renders.renderer
        var published: [CGImage] = []
        let sink = model.$preview.compactMap { $0?.image }.sink { published.append($0) }
        defer { sink.cancel() }
        let canvas = CanvasView(model: model)

        #expect(model.awaitsRedaction && model.provisional == nil)
        #expect(try CanvasSnapshot(canvas).redBounds == nil, "The unredacted capture is not drawn")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(recognizer.calls == 1)
        #expect(renders.renders == 0 && model.preview == nil, "No composed preview is made from unredacted pixels")
        #expect(try CanvasSnapshot(canvas).redBounds == nil)

        recognizer.respond(.success([email]))
        #expect(await eventually { model.preview != nil })
        #expect(!model.awaitsRedaction && model.annotations.count == 1)
        #expect(!published.isEmpty)
        for image in published {
            #expect(try #require(PixelBuffer(image)).pixel(50, 40) == (0, 0, 0, 255), "Every preview is redacted")
        }
        #expect(renders.renders == 1, "The first preview already carries the redactions")
    }

    @Test(arguments: Outcome.allCases)
    func anAnswerWithNothingToRedactLiftsTheHold(_ outcome: Outcome) async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let gate = RenderGate(); defer { gate.open() }
        let recognizer = RecognizerGate()
        let model = try makeModel(f, recognizer: recognizer)
        model.renderer = gate.renderer
        let canvas = CanvasView(model: model)
        #expect(model.awaitsRedaction)
        #expect(await eventually { recognizer.calls == 1 })

        recognizer.respond(outcome.result)
        #expect(await eventually { !model.awaitsRedaction })
        #expect(model.lastRedactSummary == outcome.summary)
        #expect(model.annotations.isEmpty)
        #expect(model.preview == nil, "The composed preview is still pending")
        #expect(try CanvasSnapshot(canvas).redBounds != nil, "The capture shows as soon as nothing needs hiding")

        gate.open()
        #expect(await eventually { model.preview != nil })
        #expect(model.provisional == nil)
    }

    @Test func foundRedactionsStayHiddenUntilTheyAreRenderedIn() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let gate = RenderGate(); defer { gate.open() }
        let recognizer = RecognizerGate()
        let model = try makeModel(f, recognizer: recognizer)
        model.renderer = gate.renderer
        let canvas = CanvasView(model: model)
        #expect(await eventually { recognizer.calls == 1 })

        recognizer.respond(.success([email]))
        #expect(await eventually { !model.awaitsRedaction && gate.renders == 1 })
        #expect(model.annotations.count == 1 && model.provisional == nil)
        #expect(try CanvasSnapshot(canvas).redBounds == nil, "Nothing is drawn around the pending redaction")

        gate.open()
        #expect(await eventually { model.preview != nil })
        let composed = try #require(model.preview).image
        #expect(try #require(PixelBuffer(composed)).pixel(60, 60) == (0, 0, 0, 255))
    }

    @Test func aCaptureTheEditorIsToldIsAlreadyRedactedIsShownAtOnce() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let gate = RenderGate(); defer { gate.open() }
        let recognizer = RecognizerGate()
        let model = try makeModel(f, autoRedactionApplied: true, recognizer: recognizer)
        model.renderer = gate.renderer
        let canvas = CanvasView(model: model)

        #expect(!model.awaitsRedaction && model.provisional != nil)
        #expect(try CanvasSnapshot(canvas).redBounds != nil)
        #expect(await eventually { gate.renders == 1 }, "Its first render starts without waiting for the editor's own pass")
        #expect(recognizer.calls <= 1)
        gate.open()
        #expect(await eventually { model.preview != nil })
        recognizer.respond(.success([]))
    }

    @Test func aReopenedImageIsNeverHeldBack() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        f.preferences.lastRenderSettings = bareLook
        let context = EditorContext(image: try redCapture(), backingScale: 2, rawURL: nil, source: "last image",
                                    isComposed: true)
        let model = EditorModel(context: context, preferences: f.preferences, presetStore: f.presets)
        #expect(!model.awaitsRedaction)
        #expect(model.provisional != nil)
    }

    // MARK: Failure, churn and teardown

    @Test func aFailedFirstRenderDropsTheStandInAndSaysWhy() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let model = try makeModel(f)
        model.renderer = { _, _, _, _, _, _, _ in throw RenderFailure() }
        let canvas = CanvasView(model: model)
        #expect(model.provisional != nil)

        #expect(await eventually { model.statusMessage != nil })
        #expect(model.statusMessage == "The preview could not be composed.")
        #expect(model.preview == nil && model.provisional == nil, "No placeholder is left behind")
        #expect(try CanvasSnapshot(canvas).redBounds == nil)

        model.renderer = { image, settings, annotations, scale, background, wallpaper, time in
            try Compositor.renderDetailed(image: image, settings: settings, annotations: annotations,
                                          backingScale: scale, backgroundImage: background, wallpaper: wallpaper,
                                          annotationTime: time)
        }
        model.settings.padding = 12
        #expect(await eventually { model.preview != nil }, "The next change renders normally")
        #expect(model.provisional == nil)
    }

    @Test func rapidSettingChangesEndOnTheLatestPreview() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let gate = RenderGate(); defer { gate.open() }
        let model = try makeModel(f)
        model.renderer = gate.renderer
        var sizes: [CGSize] = []
        let sink = model.$preview.compactMap { $0?.layout.canvasSize }.sink { sizes.append($0) }
        defer { sink.cancel() }
        #expect(await eventually { gate.renders == 1 })

        for padding in stride(from: 11.0, through: 40.0, by: 1) { model.settings.padding = padding }
        gate.open()
        let latest = Compositor.layout(contentSize: CGSize(width: 100, height: 80), insetApplied: false,
                                       settings: model.settings, backingScale: 2).canvasSize
        #expect(await eventually { model.preview?.layout.canvasSize == latest })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(model.preview?.layout.canvasSize == latest, "A stale render cannot overwrite the latest one")
        #expect(sizes.last == latest)
        #expect(gate.renders == 2, "Thirty changes while rendering cost one more render")
    }

    @Test func closingTheEditorWhileTheFirstRenderIsInFlightIsSafe() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let gate = RenderGate(); defer { gate.open() }
        weak var released: EditorModel?
        do {
            let model = try makeModel(f)
            model.renderer = gate.renderer
            released = model
            #expect(await eventually { gate.renders == 1 })
        }
        gate.open()
        #expect(await eventually { released == nil }, "The model is not kept alive by its own render")
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: Measuring

    @Test func milestonesMarkTheFirstImageAndTheComposedPreviewInOrder() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let gate = RenderGate(); defer { gate.open() }
        let model = try makeModel(f)
        model.renderer = gate.renderer
        var events: [(EditorMilestone, TimeInterval)] = []
        model.onMilestone = { events.append(($0, $1)) }
        let canvas = CanvasView(model: model)
        #expect(events.isEmpty && model.milestones.isEmpty, "Nothing is marked before an image is drawn")

        _ = try CanvasSnapshot(canvas)
        #expect(events.map(\.0) == [.firstImage])
        gate.open()
        #expect(await eventually { model.preview != nil })
        _ = try CanvasSnapshot(canvas)
        #expect(events.map(\.0) == [.firstImage, .composedPreview], "Each milestone is marked once")
        #expect(events[0].1 >= 0 && events[0].1 <= events[1].1)
        #expect(model.milestones[.firstImage] == events[0].1 && model.milestones[.composedPreview] == events[1].1)
    }
}
