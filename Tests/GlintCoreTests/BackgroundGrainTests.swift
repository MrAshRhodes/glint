import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

@Suite("Grain background")
struct BackgroundGrainTests {
    private func style(seed: UInt64 = 1, foreground: RGBAColor = .white) -> PatternStyle {
        PatternStyle(kind: .noise, foreground: foreground, background: RGBAColor(hex: "#374151") ?? .black,
                     scale: 2, seed: seed)
    }

    /// The per-cell loop `drawNoise` replaced, kept as the pixel reference.
    private func perCellGrain(_ p: PatternStyle, in ctx: CGContext, width: Int, height: Int, grain: Int) {
        var rng = SplitMix64(seed: p.seed)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let v = Double(rng.next() % 1000) / 1000
                ctx.setFillColor(p.foreground.with(alpha: p.foreground.a * v * 0.25).cgColor)
                ctx.fill(CGRect(x: x, y: y, width: grain, height: grain))
                x += grain
            }
            y += grain
        }
    }

    private func render(_ p: PatternStyle, width: Int, height: Int, _ draw: (CGContext) -> Void) throws -> CGImage {
        let ctx = try #require(GlintBitmap.makeContext(width: width, height: height))
        ctx.setFillColor(p.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(ctx)
        return try #require(ctx.makeImage())
    }

    @Test("Batched grain is pixel-identical to filling one cell at a time")
    func batchedGrainMatchesPerCellFills() throws {
        let sizes = [(97, 61), (100, 64), (53, 211), (1, 1), (7, 5), (300, 4)]
        for (width, height) in sizes {
            for grain in [1, 2, 3, 5, 9] {
                for seed in [UInt64(1), 12345] {
                    let p = style(seed: seed)
                    let expected = try render(p, width: width, height: height) {
                        perCellGrain(p, in: $0, width: width, height: height, grain: grain)
                    }
                    let actual = try render(p, width: width, height: height) {
                        BackgroundRenderer.drawNoise(p, ctx: $0, width: width, height: height, grain: grain)
                    }
                    try expectSamePixels(actual, expected)
                }
            }
        }
    }

    @Test("Bands of any height draw the same pixels")
    func bandsDoNotChangePixels() throws {
        let p = style(seed: 99, foreground: RGBAColor(r: 0.9, g: 0.4, b: 0.1, a: 0.8))
        let width = 83, height = 71, grain = 3
        let expected = try render(p, width: width, height: height) {
            perCellGrain(p, in: $0, width: width, height: height, grain: grain)
        }
        let columns = (width + grain - 1) / grain
        // One cell (clamped to one row), a band that is not a multiple of the grid, and a few whole rows.
        for bandCells in [1, columns - 1, columns + 5, columns * 3, columns * 1000] {
            let actual = try render(p, width: width, height: height) {
                BackgroundRenderer.drawNoise(p, ctx: $0, width: width, height: height, grain: grain,
                                             bandCells: bandCells)
            }
            try expectSamePixels(actual, expected)
        }
    }

    @Test("The renderer's grain preset keeps its cell size and pixels")
    func rendererGrainMatchesPerCellFills() throws {
        let p = style(seed: 3)
        let size = CGSize(width: 130, height: 90)
        for scale in [CGFloat(1), 1.5, 2, 3] {
            let grain = max(1, Int(max(2, CGFloat(p.scale) * scale)))
            let expected = try render(p, width: 130, height: 90) {
                perCellGrain(p, in: $0, width: 130, height: 90, grain: grain)
            }
            let actual = try render(p, width: 130, height: 90) {
                BackgroundRenderer.fill(.pattern(p), in: $0, size: size, scale: scale, image: nil)
            }
            try expectSamePixels(actual, expected)
        }
    }

    @Test("Grain is deterministic and the seed changes it")
    func grainIsSeeded() throws {
        func grain(seed: UInt64) throws -> CGImage {
            let p = style(seed: seed)
            return try render(p, width: 64, height: 48) {
                BackgroundRenderer.drawNoise(p, ctx: $0, width: 64, height: 48, grain: 2)
            }
        }
        try expectSamePixels(try grain(seed: 5), try grain(seed: 5))
        let a = try #require(PixelBuffer(try grain(seed: 5)))
        let b = try #require(PixelBuffer(try grain(seed: 6)))
        #expect(a.data != b.data)
    }

    @Test("An empty canvas draws nothing")
    func emptyCanvasIsSafe() throws {
        let p = style()
        let ctx = try #require(GlintBitmap.makeContext(width: 4, height: 4))
        BackgroundRenderer.drawNoise(p, ctx: ctx, width: 0, height: 4, grain: 2)
        BackgroundRenderer.drawNoise(p, ctx: ctx, width: 4, height: 0, grain: 2)
        let image = try #require(ctx.makeImage())
        let buffer = try #require(PixelBuffer(image))
        #expect(buffer.data.allSatisfy { $0 == 0 })
    }
}
