import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

@Suite("Fail-closed rendering")
struct FailClosedRenderTests {
    let framed = TestImages.framed(width: 200, height: 100, margins: EdgeMargins(top: 30, left: 30, bottom: 30, right: 30))
    let redaction = Annotation(kind: .redact(CGRect(x: 40, y: 40, width: 60, height: 20)), style: AnnotationStyle(color: .black))
    let failingBaker: Compositor.Baker = { _, _, _, _ in nil }

    func settings(autoBalance: Bool) -> RenderSettings {
        RenderSettings(padding: 20, inset: 15, cornerRadius: 0, shadow: .none, background: .solid(.black),
                       autoBalance: autoBalance)
    }

    @Test(arguments: [false, true])
    func failedBakeWithRedactionThrows(autoBalance: Bool) {
        #expect(throws: RenderError.annotationsNotApplied) {
            try Compositor.renderDetailed(image: framed, settings: settings(autoBalance: autoBalance),
                                          annotations: [redaction], backingScale: 1, bake: failingBaker)
        }
    }

    @Test func failedBakeWithMultipleAnnotationsThrows() {
        let blur = Annotation(kind: .blur(CGRect(x: 10, y: 10, width: 30, height: 30)))
        #expect(throws: RenderError.annotationsNotApplied) {
            try Compositor.renderDetailed(image: TestImages.solid(100, 50, .white), settings: settings(autoBalance: false),
                                          annotations: [redaction, blur], bake: failingBaker)
        }
    }

    @Test func failedBakeWithoutAnnotationsFallsBackToSource() throws {
        let s = settings(autoBalance: true)
        var called = false
        let result = try Compositor.renderDetailed(image: framed, settings: s, annotations: [], backingScale: 1,
                                                   bake: { _, _, _, _ in called = true; return nil })
        #expect(called) // auto-balance computed a crop region, so baking was attempted
        #expect(result.border != nil)
        // crop lost: uncropped 200×100 source + 2*(20+15)
        #expect(result.image.width == 200 + 70 && result.image.height == 100 + 70)
    }

    @Test(arguments: [false, true])
    func successfulBakeIsUsed(autoBalance: Bool) throws {
        let s = settings(autoBalance: autoBalance)
        var calls = 0
        let recording: Compositor.Baker = { source, annotations, region, fill in
            calls += 1
            return Compositor.defaultBaker(source, annotations, region, fill)
        }
        let seamed = try Compositor.renderDetailed(image: framed, settings: s, annotations: [redaction],
                                                   backingScale: 1, bake: recording)
        let pub = try Compositor.renderDetailed(image: framed, settings: s, annotations: [redaction], backingScale: 1)
        #expect(calls == 1)
        #expect(seamed.image.width == pub.image.width && seamed.image.height == pub.image.height)
        #expect(try #require(PixelBuffer(seamed.image)).data == #require(PixelBuffer(pub.image)).data)
    }

    @Test func errorDescribesThatNothingWasExported() throws {
        let description = try #require(RenderError.annotationsNotApplied.errorDescription)
        #expect(description.contains("not exported"))
        #expect(RenderError.annotationsNotApplied.localizedDescription == description)
    }
}
