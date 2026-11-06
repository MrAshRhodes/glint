import AppKit
import GlintCore
import Testing
@testable import GlintCapture

// The scrolling capture runs on fakes: a synthetic page stands in for the screen, time only passes when the
// session sleeps, and the test plays the user.

private struct ScrollPage {
    static let width = 64
    static let visible = 160
    let rows: [[UInt8]]

    init(height: Int) {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        rows = (0..<height).map { _ in
            (0..<Self.width).flatMap { _ -> [UInt8] in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let v = state >> 24
                return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), 255]
            }
        }
    }

    func frame(at offset: Int) -> CGImage { Self.image(Array(rows[offset..<(offset + Self.visible)])) }
    func image(rows range: Range<Int>) -> CGImage { Self.image(Array(rows[range])) }

    static func image(_ rows: [[UInt8]]) -> CGImage {
        let data = Data(rows.flatMap { $0 }) as CFData
        return CGImage(width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: ColorSpaces.sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }
}

private func bytes(_ image: CGImage) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
    out.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: ColorSpaces.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return out
}

@MainActor
private final class ScrollFakePicker: RegionPicking {
    let region: RecordingRegion?
    private var continuation: CheckedContinuation<RecordingRegion, Error>?

    init(_ region: RecordingRegion?) { self.region = region }

    func pick() async throws -> RecordingRegion {
        if let region { return region }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func cancel() {
        continuation?.resume(throwing: CaptureError.cancelled)
        continuation = nil
    }
}

@MainActor
private final class ScrollFakePresenter: ScrollCapturePresenting {
    private(set) var shown: CGRect?
    private(set) var actions: ScrollCaptureControlActions?
    private(set) var statuses: [ScrollCaptureStatus] = []
    private(set) var dismissed = false

    func show(region: RecordingRegion, actions: ScrollCaptureControlActions) {
        shown = region.rect
        self.actions = actions
    }

    func update(_ status: ScrollCaptureStatus, preview: CGImage?) { statuses.append(status) }
    func dismiss() { dismissed = true }
}

@MainActor
private final class ScrollFakeSource: ScrollFrameSource {
    let page: ScrollPage
    var offset = 0
    private(set) var frames = 0

    init(page: ScrollPage) { self.page = page }

    func signature() async throws -> ScrollSignature { ScrollSignature(image: page.frame(at: offset))! }

    func frame() async throws -> CGImage {
        frames += 1
        return page.frame(at: offset)
    }
}

@MainActor
private final class ScrollHarness {
    let display = DisplayInfo(id: 3, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2,
                              name: "Synthetic", isMain: true)
    static let rect = CGRect(x: 100, y: 100, width: 320, height: 400)
    let picker: ScrollFakePicker
    let presenter = ScrollFakePresenter()
    let source = ScrollFakeSource(page: ScrollPage(height: 600))
    private(set) var session: ScrollCaptureSession!
    private(set) var presentersMade = 0
    /// Scroll positions the "user" moves to, one per tick.
    var script: [Int] = []
    /// Called on a tick once the script has run out.
    var onScriptEnd: ((ScrollHarness) -> Void)?
    private var clock: TimeInterval = 0

    init(waitsInPicker: Bool = false, limits: ScrollStitchLimits = ScrollStitchLimits()) {
        picker = ScrollFakePicker(waitsInPicker ? nil : RecordingRegion(rect: Self.rect, display: display))
        var environment = ScrollCaptureEnvironment(
            requirePermission: {},
            makePicker: { [unowned self] _ in picker },
            makePresenter: { [unowned self] in
                presentersMade += 1
                return presenter
            },
            makeSource: { [unowned self] _, _ in source },
            sleep: { [weak self] _ in await self?.tick() },
            now: { [unowned self] in clock })
        environment.limits = limits
        session = ScrollCaptureSession(snapToEdges: false, showsCursor: false, environment: environment)
    }

    func tick() async {
        clock += 0.1
        if script.isEmpty {
            onScriptEnd?(self)
        } else {
            source.offset = script.removeFirst()
        }
        await Task.yield()
    }

    func run() -> Task<CaptureResult, Error> {
        let session = session!
        return Task { try await session.run() }
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() { await Task.yield() }
    }
}

@MainActor
@Suite("Scrolling capture session")
struct ScrollCaptureSessionTests {
    @Test func stitchesWhileScrollingThenFinishes() async throws {
        let harness = ScrollHarness()
        harness.script = [90, 180, 270]
        harness.onScriptEnd = { $0.session.finish() }
        let result = try await harness.run().value

        #expect(result.kind == .scrolling)
        #expect(result.scale == 2)
        #expect(result.displayID == 3)
        #expect(result.rect == ScrollHarness.rect)
        #expect(result.image.width == ScrollPage.width && result.image.height == 430)
        #expect(bytes(result.image) == bytes(harness.source.page.image(rows: 0..<430)))
        #expect(harness.presenter.shown == ScrollHarness.rect)
        #expect(harness.presenter.dismissed)
        #expect(harness.presenter.statuses.last?.frames == 4)
        #expect(harness.session.phase == .idle)
    }

    @Test func finishingWhileSelectingCancels() async {
        let harness = ScrollHarness(waitsInPicker: true)
        let run = harness.run()
        await harness.waitUntil { harness.session.phase == .selecting }
        harness.session.finish()
        await #expect(throws: CaptureError.self) { try await run.value }
        #expect(harness.presentersMade == 0)
    }

    @Test func cancelFromControlsThrowsAndDismisses() async {
        let harness = ScrollHarness()
        harness.script = [90]
        harness.onScriptEnd = { $0.presenter.actions?.cancel() }
        do {
            _ = try await harness.run().value
            Issue.record("Expected the capture to be cancelled")
        } catch {
            guard case .cancelled = error as? CaptureError else {
                Issue.record("Unexpected error \(error)")
                return
            }
        }
        #expect(harness.presenter.dismissed)
    }

    @Test func scrollingTooFarPausesUntilResumed() async throws {
        let harness = ScrollHarness()
        harness.script = [90, 230, 230, 230, 230]
        let run = harness.run()
        await harness.waitUntil { harness.session.phase == .paused }
        #expect(harness.presenter.statuses.last?.warning == .tooFast)
        #expect(harness.presenter.statuses.last?.isPaused == true)

        // The user scrolls back up a little and resumes.
        harness.script = []
        harness.source.offset = 180
        harness.onScriptEnd = { $0.session.finish() }
        harness.presenter.actions?.resume()
        let result = try await run.value
        #expect(bytes(result.image) == bytes(harness.source.page.image(rows: 0..<340)))
    }

    @Test func undoRemovesTheLastStep() async throws {
        let harness = ScrollHarness()
        harness.script = [90, 180]
        harness.onScriptEnd = { harness in
            harness.onScriptEnd = nil
            harness.presenter.actions?.undo()
            harness.session.finish()
        }
        let result = try await harness.run().value
        #expect(bytes(result.image) == bytes(harness.source.page.image(rows: 0..<250)))
    }

    @Test func heightLimitPausesAndDoneKeepsTheImage() async throws {
        let harness = ScrollHarness(limits: ScrollStitchLimits(maxHeight: 300))
        harness.script = [90, 180, 270]
        let run = harness.run()
        await harness.waitUntil { harness.session.phase == .paused }
        #expect(harness.presenter.statuses.last?.warning == .heightLimit)
        // Resume does nothing at the limit; only Done, Undo and Cancel do.
        harness.presenter.actions?.resume()
        harness.presenter.actions?.done()
        let result = try await run.value
        #expect(result.image.height == 300)
    }
}

@Suite("Scrolling capture layout")
struct ScrollCaptureLayoutTests {
    let usable = CGRect(x: 0, y: 25, width: 1440, height: 875)
    let size = CGSize(width: 240, height: 360)

    @Test func controlsGoRightOfTheRegion() {
        let frame = ScrollCaptureLayout.hudFrame(size: size, region: CGRect(x: 200, y: 100, width: 600, height: 700),
                                                 usable: usable)
        #expect(frame == CGRect(x: 816, y: 100, width: 240, height: 360))
    }

    @Test func controlsGoLeftWhenTheRightIsFull() {
        let frame = ScrollCaptureLayout.hudFrame(size: size, region: CGRect(x: 600, y: 100, width: 800, height: 700),
                                                 usable: usable)
        #expect(frame == CGRect(x: 344, y: 100, width: 240, height: 360))
    }

    @Test func controlsGoInsideWhenNeitherSideFits() {
        let frame = ScrollCaptureLayout.hudFrame(size: size, region: CGRect(x: 100, y: 600, width: 1300, height: 290),
                                                 usable: usable)
        #expect(frame.maxX == 1384)
        #expect(frame.maxY <= usable.maxY - RecordingLayout.margin)
    }

    @Test func previewHighlightFollowsTheRows() {
        let rect = ScrollPreviewView.imageRect(imageSize: CGSize(width: 100, height: 400),
                                               in: CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(rect == CGRect(x: 75, y: 0, width: 50, height: 200))
        let band = ScrollPreviewView.highlightRect(rows: 100..<200, imageHeight: 400, imageRect: rect)
        #expect(band == CGRect(x: 75, y: 50, width: 50, height: 50))
    }
}
