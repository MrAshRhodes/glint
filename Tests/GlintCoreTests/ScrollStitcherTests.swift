import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

/// Synthetic scrolling pages: a tall page of unique noise rows, optionally with a fixed header and footer, cut
/// into viewport-sized frames the way a scrolled window would show it.
private struct Page {
    let width: Int
    let rows: [[UInt8]]
    var header: [[UInt8]] = []
    var footer: [[UInt8]] = []

    static func noise(width: Int = 48, height: Int, seed: UInt64 = 7) -> Page {
        var rng = SplitMix64(seed: seed)
        let rows = (0..<height).map { _ in
            (0..<width).flatMap { _ -> [UInt8] in
                [UInt8(rng.next() % 256), UInt8(rng.next() % 256), UInt8(rng.next() % 256), 255]
            }
        }
        return Page(width: width, rows: rows)
    }

    static func stripes(width: Int = 48, height: Int, period: Int = 8) -> Page {
        let rows = (0..<height).map { y -> [UInt8] in
            let v: UInt8 = (y % period) < period / 2 ? 20 : 230
            return Array(repeating: [v, v, v, 255], count: width).flatMap { $0 }
        }
        return Page(width: width, rows: rows)
    }

    static func solidRows(width: Int, count: Int, _ rgb: (UInt8, UInt8, UInt8), stripe: Int = 0) -> [[UInt8]] {
        (0..<count).map { y in
            (0..<width).flatMap { x -> [UInt8] in
                x < stripe && y % 2 == 0 ? [255, 255, 255, 255] : [rgb.0, rgb.1, rgb.2, 255]
            }
        }
    }

    /// The window scrolled to `offset` content rows, `visible` content rows tall.
    func frame(at offset: Int, visible: Int, editing: ((inout [[UInt8]]) -> Void)? = nil) -> CGImage {
        var all = header + Array(rows[offset..<(offset + visible)]) + footer
        editing?(&all)
        return Self.image(all, width: width)
    }

    var expected: [UInt8] { (header + rows + footer).flatMap { $0 } }

    static func image(_ rows: [[UInt8]], width: Int) -> CGImage {
        let data = Data(rows.flatMap { $0 })
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: ColorSpaces.sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

private func bytes(_ image: CGImage) -> [UInt8] {
    ScrollStitcher.pixels(of: image, colorSpace: ColorSpaces.sRGB)!
}

@Suite("Scroll stitching")
struct ScrollStitcherTests {
    @Test func slicedPageWithStickyBandsReconstructsPixelExact() throws {
        var page = Page.noise(height: 600)
        page.header = Page.solidRows(width: 48, count: 20, (30, 60, 200), stripe: 12)
        page.footer = Page.solidRows(width: 48, count: 16, (200, 200, 40), stripe: 6)
        var stitcher = ScrollStitcher()
        var added: [Int] = []
        for offset in [0, 60, 120, 190, 250, 330, 400, 476] {
            let step = stitcher.add(page.frame(at: offset, visible: 124))
            #expect(step.warning == nil)
            added.append(step.addedRows)
        }
        #expect(added == [160, 60, 60, 70, 60, 80, 70, 76])
        #expect(stitcher.sticky?.top == 20 && stitcher.sticky?.bottom == 16)
        let image = try #require(stitcher.makeImage())
        #expect(image.width == 48 && image.height == 20 + 600 + 16)
        #expect(bytes(image) == page.expected)
    }

    @Test func pageWithoutStickyBandsReconstructsPixelExact() throws {
        let page = Page.noise(width: 32, height: 400, seed: 11)
        var stitcher = ScrollStitcher()
        for offset in [0, 37, 81, 150, 210, 240] { _ = stitcher.add(page.frame(at: offset, visible: 160)) }
        #expect(stitcher.sticky?.top == 0 && stitcher.sticky?.bottom == 0)
        let image = try #require(stitcher.makeImage())
        #expect(bytes(image) == page.expected)
    }

    @Test func repeatingStripesAreAmbiguous() {
        let page = Page.stripes(height: 400)
        var stitcher = ScrollStitcher()
        _ = stitcher.add(page.frame(at: 0, visible: 160))
        let step = stitcher.add(page.frame(at: 13, visible: 160))
        #expect(step == ScrollStitchStep(addedRows: 0, warning: .ambiguousRepeat))
        #expect(stitcher.height == 160 && !stitcher.canUndo)
    }

    @Test func animatedBandIsAddedWithItsRowRange() {
        let page = Page.noise(height: 400)
        var stitcher = ScrollStitcher()
        _ = stitcher.add(page.frame(at: 0, visible: 160))
        // A spinner redraws screen rows 30..<40 between the frames.
        let animated = page.frame(at: 60, visible: 160) { rows in
            for y in 30..<40 { rows[y] = Array(repeating: [255, 0, 0, 255], count: 48).flatMap { $0 } }
        }
        let step = stitcher.add(animated)
        #expect(step == ScrollStitchStep(addedRows: 60, warning: .lowConfidence(rows: 90..<100)))
        #expect(step.warning?.pausesCapture == true)
        #expect(step.warning?.message.contains("rows 91–100") == true)
        #expect(stitcher.height == 220)
    }

    @Test(arguments: [5, 6]) func localizedAnimationOnlyPausesAboveFivePercentOfOverlap(changedRows: Int) throws {
        let page = Page.noise(height: 400)
        var stitcher = ScrollStitcher()
        _ = stitcher.add(page.frame(at: 0, visible: 160))
        let animated = page.frame(at: 60, visible: 160) { rows in
            for y in 30..<(30 + changedRows) {
                rows[y] = Array(repeating: [255, 0, 0, 255], count: 48).flatMap { $0 }
            }
        }
        let step = stitcher.add(animated)
        #expect(step.addedRows == 60)
        #expect(step.warning == (changedRows == 5 ? nil : .lowConfidence(rows: 90..<(90 + changedRows))))
        // The changed pixels were already captured in the overlap; no new content is discarded.
        let expected = Page(width: page.width, rows: Array(page.rows.prefix(220)))
        #expect(bytes(try #require(stitcher.makeImage())) == expected.expected)
        if changedRows == 5 {
            let next = stitcher.add(page.frame(at: 120, visible: 160))
            #expect(next == ScrollStitchStep(addedRows: 60, warning: nil))
            let continued = Page(width: page.width, rows: Array(page.rows.prefix(280)))
            #expect(bytes(try #require(stitcher.makeImage())) == continued.expected)
        }
    }

    @Test func scatteredAnimationStillRequiresReview() {
        let page = Page.noise(height: 400)
        var stitcher = ScrollStitcher()
        _ = stitcher.add(page.frame(at: 0, visible: 160))
        let animated = page.frame(at: 60, visible: 160) { rows in
            for y in [30, 70] {
                rows[y] = Array(repeating: [255, 0, 0, 255], count: 48).flatMap { $0 }
            }
        }
        #expect(stitcher.add(animated) == ScrollStitchStep(addedRows: 60, warning: .lowConfidence(rows: 90..<131)))
    }

    @Test func undoRestoresThePreviousState() throws {
        var page = Page.noise(height: 500)
        page.header = Page.solidRows(width: 48, count: 12, (90, 90, 90), stripe: 5)
        var stitcher = ScrollStitcher()
        _ = stitcher.add(page.frame(at: 0, visible: 140))
        _ = stitcher.add(page.frame(at: 70, visible: 140))
        let before = try #require(stitcher.makeImage())
        _ = stitcher.add(page.frame(at: 150, visible: 140))
        var undone = stitcher.undoLast()
        #expect(undone)
        #expect(bytes(try #require(stitcher.makeImage())) == bytes(before))
        // The reference frame is restored too, so the same frame joins exactly as before.
        _ = stitcher.add(page.frame(at: 150, visible: 140))
        _ = stitcher.add(page.frame(at: 220, visible: 140))
        let tail = Page(width: 48, rows: Array(page.rows[0..<360]), header: page.header)
        #expect(bytes(try #require(stitcher.makeImage())) == tail.expected)

        // Undoing the first scroll forgets the fixed bands and leaves the first frame alone.
        while stitcher.canUndo { stitcher.undoLast() }
        #expect(stitcher.sticky == nil && stitcher.height == 152 && stitcher.frameCount == 1)
        undone = stitcher.undoLast()
        #expect(!undone)
    }

    @Test func unchangedFooterKeepsNoUndoCopies() throws {
        // 201 frames, 5 rows apart, under a fixed 60-row footer: only the rows moved into the footer when it was
        // found are kept for undo, not a copy of the footer per frame.
        var page = Page.noise(width: 64, height: 1100, seed: 3)
        page.footer = Page.solidRows(width: 64, count: 60, (10, 120, 40), stripe: 9)
        var stitcher = ScrollStitcher()
        for offset in stride(from: 0, through: 1000, by: 5) {
            #expect(stitcher.add(page.frame(at: offset, visible: 100)).warning == nil)
        }
        #expect(stitcher.frameCount == 201 && stitcher.undoableSteps == 200)
        #expect(stitcher.undoBytes == 60 * 64 * 4)
        #expect(bytes(try #require(stitcher.makeImage())) == page.expected)
    }

    @Test func undoHistoryStaysWithinItsBudget() throws {
        var page = Page.noise(width: 64, height: 400, seed: 5)
        page.footer = Page.solidRows(width: 64, count: 60, (40, 40, 40))
        let footerBytes = 60 * 64 * 4
        var stitcher = ScrollStitcher(limits: ScrollStitchLimits(maxUndoBytes: 10 * footerBytes))
        // The footer changes on every frame after the first scroll (a live counter, say).
        func frame(_ i: Int) -> CGImage {
            page.frame(at: i * 10, visible: 100) { rows in
                if i >= 2 { rows[rows.count - 1][0] = UInt8(i) }
            }
        }
        for i in 0..<30 { #expect(stitcher.add(frame(i)).warning == nil) }
        #expect(stitcher.undoBytes <= 10 * footerBytes)
        #expect(stitcher.frameCount == 30)
        let undoable = stitcher.undoableSteps
        #expect(undoable > 0 && undoable < 29)

        while stitcher.canUndo { stitcher.undoLast() }
        let last = 29 - undoable
        #expect(stitcher.frameCount == last + 1)
        var rows = Array(page.rows[0..<(last * 10 + 100)]) + page.footer
        rows[rows.count - 1][0] = UInt8(last)
        #expect(bytes(try #require(stitcher.makeImage())) == rows.flatMap { $0 })
        // The next frame still joins exactly after undoing as far as the history allows.
        _ = stitcher.add(frame(last + 1))
        rows = Array(page.rows[0..<((last + 1) * 10 + 100)]) + page.footer
        rows[rows.count - 1][0] = UInt8(last + 1)
        #expect(bytes(try #require(stitcher.makeImage())) == rows.flatMap { $0 })
    }

    @Test func heightLimitStopsGrowth() {
        let page = Page.noise(height: 600)
        var stitcher = ScrollStitcher(limits: ScrollStitchLimits(maxHeight: 300))
        var step = stitcher.add(page.frame(at: 0, visible: 160))
        #expect(step.warning == nil)
        step = stitcher.add(page.frame(at: 60, visible: 160))
        #expect(step.warning == nil)
        #expect(!stitcher.isNearLimit)
        step = stitcher.add(page.frame(at: 120, visible: 160))
        #expect(step.warning == nil)
        #expect(stitcher.isNearLimit && !stitcher.isAtLimit)
        step = stitcher.add(page.frame(at: 180, visible: 160))
        #expect(step == ScrollStitchStep(addedRows: 20, warning: .heightLimit))
        #expect(stitcher.height == 300 && stitcher.isAtLimit && stitcher.progress == 1)
        step = stitcher.add(page.frame(at: 240, visible: 160))
        #expect(step == ScrollStitchStep(addedRows: 0, warning: .heightLimit))
        stitcher.undoLast()
        #expect(!stitcher.isAtLimit && stitcher.height == 280)
    }

    @Test func pixelBudgetLimitsHeight() {
        let limits = ScrollStitchLimits(maxHeight: 16_384, maxPixels: 48 * 250)
        #expect(limits.maxRows(width: 48) == 250)
        #expect(ScrollStitchLimits().maxRows(width: 1000) == 16_384)
        #expect(ScrollStitchLimits().maxRows(width: 8000) == 8000)
    }

    @Test func rejectedFramesExplainWhy() {
        let page = Page.noise(height: 600)
        var stitcher = ScrollStitcher()
        _ = stitcher.add(page.frame(at: 100, visible: 160))
        var step = stitcher.add(page.frame(at: 100, visible: 160))
        #expect(step.warning == .noMovement)
        step = stitcher.add(page.frame(at: 70, visible: 160))
        #expect(step.warning == .scrolledBack)
        step = stitcher.add(page.frame(at: 250, visible: 160))
        #expect(step.warning == .tooFast)
        step = stitcher.add(page.frame(at: 100, visible: 150))
        #expect(step.warning == .sizeChanged)
        #expect(stitcher.height == 160)
        #expect(ScrollStitchWarning.noMovement.pausesCapture == false)
        #expect(ScrollStitchWarning.tooFast.pausesCapture)
    }

    @Test func thumbnailFitsTheBox() throws {
        let page = Page.noise(height: 600)
        var stitcher = ScrollStitcher()
        for offset in [0, 90, 180, 270, 360, 440] { _ = stitcher.add(page.frame(at: offset, visible: 160)) }
        let thumb = try #require(stitcher.thumbnail(maxWidth: 24, maxHeight: 120))
        #expect(thumb.height == 120 && thumb.width == 10)
    }
}

@Suite("Scroll grab policy")
struct ScrollGrabPolicyTests {
    private func signature(_ page: Page, at offset: Int) -> ScrollSignature {
        ScrollSignature(image: page.frame(at: offset, visible: 160), columns: 16)!
    }

    @Test func signatureShiftFollowsScrolling() {
        let page = Page.noise(width: 64, height: 600)
        let a = signature(page, at: 0), b = signature(page, at: 40)
        #expect(a.height == 40)
        #expect(b.shift(from: a) == 10)
        #expect(a.shift(from: b) == -10)
        #expect(a.difference(from: a) == 0)
    }

    @Test func grabsFirstFrameThenAfterSettling() {
        let page = Page.noise(width: 64, height: 600)
        var policy = ScrollGrabPolicy()
        let first = signature(page, at: 0)
        var grabbed = policy.shouldGrab(first, at: 0, reference: nil)
        #expect(grabbed)
        grabbed = policy.shouldGrab(first, at: 0.1, reference: first)
        #expect(!grabbed)
        let moved = signature(page, at: 20)
        grabbed = policy.shouldGrab(moved, at: 0.2, reference: first)
        #expect(!grabbed)
        grabbed = policy.shouldGrab(moved, at: 0.3, reference: first)
        #expect(!grabbed)
        grabbed = policy.shouldGrab(moved, at: 0.4, reference: first)
        #expect(grabbed)
    }

    @Test func grabsEarlyWhenMovedHalfAFrame() {
        let page = Page.noise(width: 64, height: 600)
        var policy = ScrollGrabPolicy()
        let first = signature(page, at: 0)
        _ = policy.shouldGrab(first, at: 0, reference: nil)
        let grabbed = policy.shouldGrab(signature(page, at: 90), at: 0.1, reference: first)
        #expect(grabbed)
    }

    @Test func grabsDuringContinuousScrollingBeforeOverlapRunsOut() {
        let page = Page.noise(width: 64, height: 600)
        var policy = ScrollGrabPolicy()
        let first = signature(page, at: 0)
        _ = policy.shouldGrab(first, at: 0, reference: nil)
        // Never still and never half a frame: only the time cap can grab.
        var grabbed = policy.shouldGrab(signature(page, at: 12), at: 0.1, reference: first)
        #expect(!grabbed)
        grabbed = policy.shouldGrab(signature(page, at: 24), at: 0.2, reference: first)
        #expect(!grabbed)
        grabbed = policy.shouldGrab(signature(page, at: 36), at: 0.3, reference: first)
        #expect(!grabbed)
        grabbed = policy.shouldGrab(signature(page, at: 48), at: 0.4, reference: first)
        #expect(grabbed)
    }

    @Test func movingDeadlineStillAppliesDuringABriefPause() {
        let page = Page.noise(width: 64, height: 600)
        var policy = ScrollGrabPolicy()
        let first = signature(page, at: 0)
        _ = policy.shouldGrab(first, at: 0, reference: nil)
        _ = policy.shouldGrab(signature(page, at: 12), at: 0.1, reference: first)
        _ = policy.shouldGrab(signature(page, at: 24), at: 0.2, reference: first)
        let moved = signature(page, at: 36)
        var grabbed = policy.shouldGrab(moved, at: 0.3, reference: first)
        #expect(!grabbed)
        grabbed = policy.shouldGrab(moved, at: 0.4, reference: first)
        #expect(grabbed)
        grabbed = policy.shouldGrab(moved, at: 0.5, reference: moved)
        #expect(!grabbed)
        grabbed = policy.shouldGrab(signature(page, at: 48), at: 0.6, reference: moved)
        #expect(!grabbed)
    }

    @Test func paceDistinguishesSteadyTooFastAndTooSlow() {
        let page = Page.noise(width: 64, height: 600)
        var policy = ScrollPacePolicy()
        #expect(policy.observe(signature(page, at: 0), at: 0) == .ready)
        #expect(policy.observe(signature(page, at: 20), at: 0.5) == .steady)
        #expect(policy.observe(signature(page, at: 100), at: 0.6) == .tooFast)
        #expect(policy.observe(signature(page, at: 104), at: 1.6) == .tooSlow)
        policy.reset()
        #expect(policy.observe(signature(page, at: 104), at: 5) == .ready)
        #expect(policy.observe(signature(page, at: 104), at: 7.1) == .tooSlow)
        #expect(policy.observe(signature(page, at: 124), at: 7.6) == .steady)
    }
}

@Suite("Banded text recognition")
struct BandedRecognitionTests {
    @Test func bandsOverlapAndCoverTheImage() {
        #expect(TextRecognizer.bands(height: 3000) == [0..<3000])
        #expect(TextRecognizer.bands(height: 9000) == [0..<4096, 3840..<7936, 7680..<9000])
        #expect(TextRecognizer.bands(height: 4096) == [0..<4096])
    }

    @Test func linesInOverlapsAreReportedOnce() {
        let ranges = TextRecognizer.bands(height: 9000)
        func line(_ text: String, _ y: CGFloat) -> RecognizedLine {
            RecognizedLine(text: text, box: CGRect(x: 10, y: y, width: 200, height: 20),
                           words: [RecognizedWord(text: text, range: NSRange(location: 0, length: 1),
                                                  box: CGRect(x: 10, y: y, width: 40, height: 20))])
        }
        let perBand: [Range<Int>: [RecognizedLine]] = [
            ranges[0]: [line("top", 100), line("seam", 3900), line("edge", 4000)],
            ranges[1]: [line("seam", 60), line("edge", 160), line("middle", 1000), line("late", 3950)],
            ranges[2]: [line("late", 110), line("bottom", 1200)],
        ]
        let lines = TextRecognizer.recognizeBanded(ranges) { perBand[$0] ?? [] }
        #expect(lines.map(\.text) == ["top", "seam", "edge", "middle", "late", "bottom"])
        #expect(lines.map(\.box.minY) == [100, 3900, 4000, 4840, 7790, 8880])
        #expect(lines.first { $0.text == "middle" }?.words.first?.box.minY == 4840)
    }
}
