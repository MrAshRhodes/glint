import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

/// Counts how often a render burns annotations in, which is exactly what a cache hit skips.
private final class BakeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var baker: Compositor.Baker {
        { source, annotations, region, fill in
            self.lock.lock()
            self.calls += 1
            self.lock.unlock()
            return Compositor.defaultBaker(source, annotations, region, fill)
        }
    }
}

private func displayP3(_ width: Int, _ height: Int) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for x in stride(from: 0, to: width, by: 4) {
        ctx.setFillColor(red: CGFloat(x % 7) / 6, green: CGFloat(x % 5) / 4, blue: CGFloat(x % 3) / 2, alpha: 1)
        ctx.fill(CGRect(x: x, y: 0, width: 4, height: height))
    }
    return try #require(ctx.makeImage())
}

@Suite("Render cache")
struct RenderCacheTests {
    private let framed = TestImages.framed(width: 240, height: 160,
                                           margins: EdgeMargins(top: 20, left: 20, bottom: 20, right: 20))
    private let redaction = Annotation(kind: .redact(CGRect(x: 60, y: 50, width: 60, height: 20)),
                                       style: AnnotationStyle(color: .black))
    private let box = Annotation(kind: .rectangle(CGRect(x: 30, y: 30, width: 50, height: 40)))

    private func base(autoBalance: Bool = false) -> RenderSettings {
        RenderSettings(padding: 20, inset: 6, cornerRadius: 8, shadow: .none, background: .solid(.black),
                       autoBalance: autoBalance)
    }

    /// Looks that change the card, background or output but nothing a bake depends on.
    private func looks(of settings: RenderSettings) -> [(String, RenderSettings)] {
        var result: [(String, RenderSettings)] = []
        func make(_ name: String, _ change: (inout RenderSettings) -> Void) {
            var s = settings
            change(&s)
            result.append((name, s))
        }
        make("background") { $0.background = .solid(RGBAColor(r: 0.2, g: 0.4, b: 0.9)) }
        make("shadow") { $0.shadow = ShadowSettings(strength: 80) }
        make("padding") { $0.padding = 44 }
        make("output scale") { $0.outputScale = 0.5 }
        make("corner radius") { $0.cornerRadius = 0 }
        make("frame") { $0.windowFrame = WindowFrameSettings(style: .browser, title: "Glint") }
        make("border") { $0.border = BorderStyle(enabled: true, width: 3) }
        make("aspect ratio") { $0.aspectRatio = .square }
        make("tilt") { $0.tilt = Tilt(x: 5, y: 8) }
        make("rotation and flip") { $0.rotation = .cw90; $0.flipHorizontal = true }
        make("watermark") { $0.watermark = WatermarkSettings(enabled: true, text: "Example") }
        return result
    }

    private func render(_ image: CGImage, _ settings: RenderSettings, _ annotations: [Annotation],
                        cache: RenderCache?, count: BakeCount) throws -> RenderResult {
        try Compositor.renderDetailed(image: image, settings: settings, annotations: annotations, backingScale: 2,
                                      bake: count.baker, cache: cache)
    }

    @Test(arguments: [false, true])
    func changingOnlyTheLookReusesTheBake(autoBalance: Bool) throws {
        let cache = RenderCache(), count = BakeCount()
        let first = base(autoBalance: autoBalance)
        _ = try render(framed, first, [redaction, box], cache: cache, count: count)
        #expect(count.value == 1)
        for (name, look) in looks(of: first) {
            let cached = try render(framed, look, [redaction, box], cache: cache, count: count)
            let plain = try Compositor.renderDetailed(image: framed, settings: look, annotations: [redaction, box],
                                                      backingScale: 2)
            #expect(cached.layout == plain.layout && cached.region == plain.region && cached.border == plain.border,
                    "\(name)")
            try expectSamePixels(cached.image, plain.image)
        }
        #expect(count.value == 1)
    }

    @Test func changedInputsBakeAgain() throws {
        let cache = RenderCache(), count = BakeCount()
        let settings = base(autoBalance: true)
        _ = try render(framed, settings, [redaction], cache: cache, count: count)
        #expect(count.value == 1)

        let moved = Annotation(kind: .redact(CGRect(x: 70, y: 50, width: 60, height: 20)),
                               style: AnnotationStyle(color: .black))
        _ = try render(framed, settings, [moved], cache: cache, count: count)
        #expect(count.value == 2, "moved annotation")
        _ = try render(framed, settings, [moved, box], cache: cache, count: count)
        #expect(count.value == 3, "added annotation")
        _ = try render(framed, settings, [moved, box], cache: cache, count: count)
        #expect(count.value == 3, "same inputs")

        let recapture = TestImages.framed(width: 240, height: 160,
                                          margins: EdgeMargins(top: 20, left: 20, bottom: 20, right: 20))
        _ = try render(recapture, settings, [moved, box], cache: cache, count: count)
        #expect(count.value == 4, "another capture")

        var uncropped = settings
        uncropped.autoBalance = false
        let result = try render(recapture, uncropped, [moved, box], cache: cache, count: count)
        #expect(count.value == 5, "crop and fill changed")
        let plain = try Compositor.renderDetailed(image: recapture, settings: uncropped, annotations: [moved, box],
                                                  backingScale: 2)
        try expectSamePixels(result.image, plain.image)
    }

    @Test func displayP3CaptureIsConvertedOnceAndRendersIdentically() throws {
        let capture = try displayP3(200, 120)
        #expect(!capture.isGlintSRGB)
        let cache = RenderCache(), count = BakeCount()
        let settings = base()
        let plain = try Compositor.renderDetailed(image: capture, settings: settings, annotations: [redaction],
                                                  backingScale: 2)
        for _ in 0..<3 {
            let cached = try render(capture, settings, [redaction], cache: cache, count: count)
            try expectSamePixels(cached.image, plain.image)
        }
        #expect(count.value == 1)
        let converted = cache.normalised(capture)
        #expect(cache.normalised(capture) === converted)
        try expectSamePixels(converted, capture.glintSRGB())
    }

    @Test func srgbCaptureIsUsedAsItIs() {
        let cache = RenderCache()
        #expect(framed.isGlintSRGB)
        #expect(cache.normalised(framed) === framed)
        #expect(cache.retainedBytes == 0)
    }

    @Test func imagesBeyondTheBudgetAreNotKept() throws {
        let cache = RenderCache(maxBytes: 1000), count = BakeCount()
        let capture = try displayP3(200, 120)
        for _ in 0..<2 {
            let cached = try render(capture, base(), [redaction], cache: cache, count: count)
            let plain = try Compositor.renderDetailed(image: capture, settings: base(), annotations: [redaction],
                                                      backingScale: 2)
            try expectSamePixels(cached.image, plain.image)
        }
        #expect(count.value == 2)
        #expect(cache.retainedBytes == 0)
    }

    @Test func holdsNoMoreThanTheBudget() throws {
        let capture = try displayP3(200, 120)
        let one = capture.bytesPerRow * capture.height
        let cache = RenderCache(maxBytes: one + one / 2), count = BakeCount()
        _ = try render(capture, base(), [redaction], cache: cache, count: count)
        #expect(cache.retainedBytes > 0 && cache.retainedBytes <= cache.maxBytes)
        let moved = Annotation(kind: .redact(CGRect(x: 10, y: 10, width: 30, height: 30)))
        _ = try render(capture, base(), [moved], cache: cache, count: count)
        #expect(cache.retainedBytes <= cache.maxBytes)
    }

    @Test func aFailedBakeStillFailsAndIsNotRemembered() throws {
        let cache = RenderCache(), count = BakeCount()
        let failing: Compositor.Baker = { _, _, _, _ in nil }
        #expect(throws: RenderError.annotationsNotApplied) {
            try Compositor.renderDetailed(image: framed, settings: base(), annotations: [redaction], backingScale: 2,
                                          bake: failing, cache: cache)
        }
        #expect(cache.retainedBytes == 0)
        let result = try render(framed, base(), [redaction], cache: cache, count: count)
        #expect(count.value == 1)
        let plain = try Compositor.renderDetailed(image: framed, settings: base(), annotations: [redaction],
                                                  backingScale: 2)
        try expectSamePixels(result.image, plain.image)
    }

    @Test func magnifierBakesAreNeverKept() throws {
        let lens = Annotation(kind: .magnify(Magnifier(source: CGRect(x: 40, y: 40, width: 20, height: 20),
                                                       inset: CGRect(x: 120, y: 60, width: 60, height: 60),
                                                       shape: .circle, showsSourceOutline: true,
                                                       showsConnector: true)),
                              style: AnnotationStyle(color: .red, strokeWidth: 4))
        let cache = RenderCache(), count = BakeCount()
        for _ in 0..<2 {
            let cached = try render(framed, base(), [lens, redaction], cache: cache, count: count)
            let plain = try Compositor.renderDetailed(image: framed, settings: base(), annotations: [lens, redaction],
                                                      backingScale: 2)
            try expectSamePixels(cached.image, plain.image)
        }
        #expect(count.value == 2)
        #expect(cache.retainedBytes == 0)
    }

    @Test func timedRendersBypassTheCache() throws {
        let cache = RenderCache(), count = BakeCount()
        for _ in 0..<2 {
            _ = try Compositor.renderDetailed(image: framed, settings: base(), annotations: [redaction],
                                              backingScale: 2, bake: count.baker, annotationTime: 0, cache: cache)
        }
        #expect(count.value == 2)
        #expect(cache.retainedBytes == 0)
    }

    @Test func concurrentRendersMatchUncachedOnes() throws {
        let capture = try displayP3(300, 200)
        let cache = RenderCache()
        let settings = looks(of: base()).map(\.1)
        let sets = [[redaction], [redaction, box], [box]]
        var expected: [[CGImage]] = []
        for look in settings {
            expected.append(try sets.map { try Compositor.render(image: capture, settings: look, annotations: $0, backingScale: 2) })
        }
        let lock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 48) { i in
            let look = i % settings.count, set = i % sets.count
            do {
                let image = try Compositor.render(image: capture, settings: settings[look], annotations: sets[set],
                                                  backingScale: 2, cache: cache)
                if PixelBuffer(image)?.data != PixelBuffer(expected[look][set])?.data {
                    lock.lock(); failures.append("look \(look) set \(set)"); lock.unlock()
                }
            } catch {
                lock.lock(); failures.append("\(error)"); lock.unlock()
            }
        }
        #expect(failures.isEmpty, "\(failures)")
        #expect(cache.retainedBytes <= cache.maxBytes)
    }

    @Test func backgroundAndWatermarkFilesAreDecodedOncePerRevision() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glint-render-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let background = dir.appendingPathComponent("background.png"), mark = dir.appendingPathComponent("mark.png")
        try Exporter.write(TestImages.solid(64, 48, RGBAColor(r: 1, g: 0, b: 0)), to: background)
        try Exporter.write(TestImages.solid(16, 16, RGBAColor(r: 0, g: 1, b: 0)), to: mark)
        var settings = base()
        settings.background = .image(path: background.path, fit: .fill)
        settings.watermark = WatermarkSettings(enabled: true, kind: .image, imagePath: mark.path, position: .center,
                                               opacity: 1, size: 10)
        let cache = RenderCache()
        let plain = try Compositor.render(image: framed, settings: settings, annotations: [box], backingScale: 2)
        for _ in 0..<2 {
            let cached = try Compositor.render(image: framed, settings: settings, annotations: [box], backingScale: 2,
                                               cache: cache)
            try expectSamePixels(cached, plain)
        }
        #expect(cache.images.count == 2)
        #expect(TestImages.pixel(plain, 1, 1).r == 255)

        try Exporter.write(TestImages.solid(64, 48, RGBAColor(r: 0, g: 0, b: 1)), to: background)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: background.path)
        let replaced = try Compositor.render(image: framed, settings: settings, annotations: [box], backingScale: 2,
                                             cache: cache)
        #expect(TestImages.pixel(replaced, 1, 1).b == 255 && TestImages.pixel(replaced, 1, 1).r == 0)
    }
}
