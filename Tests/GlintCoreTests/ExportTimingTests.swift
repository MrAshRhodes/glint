import Foundation
import ImageIO
import Testing
@testable import GlintCore

@Suite("Export timing fixture")
struct ExportTimingTests {
    /// Pixel size, density and colour profile name ImageIO recorded for the first image in `data`.
    private func properties(of data: Data) throws -> (width: Int, dpi: Double, profile: String?) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try #require(props[kCGImagePropertyPixelWidth] as? Int),
                try #require(props[kCGImagePropertyDPIWidth] as? Double),
                props[kCGImagePropertyProfileName] as? String)
    }

    @Test func syntheticFrameIsDeterministicAndMoreThanFlatColour() throws {
        let first = try #require(ExportTiming.syntheticFrame(width: 640, height: 400))
        let second = try #require(ExportTiming.syntheticFrame(width: 640, height: 400))
        #expect(first.width == 640 && first.height == 400)
        let firstPNG = try Exporter.data(for: first)
        #expect(firstPNG == (try Exporter.data(for: second)))
        let flatPNG = try Exporter.data(for: TestImages.solid(640, 400, .white))
        #expect(firstPNG.count > flatPNG.count * 10)
    }

    @Test func syntheticFrameDefaultsToARetinaFullScreenCapture() throws {
        let frame = try #require(ExportTiming.syntheticFrame())
        #expect(frame.width == 2880 && frame.height == 1800)
        #expect(ExportTiming.syntheticFrame(width: 0, height: 10) == nil)
    }

    @Test(arguments: [1, 2] as [CGFloat])
    func renderAndEncodeKeepsTheCapturesDensityAndAColourProfile(backingScale: CGFloat) throws {
        let frame = try #require(ExportTiming.syntheticFrame(width: 640, height: 400))
        let encoded = try properties(of: ExportTiming.renderAndEncode(frame, backingScale: backingScale))
        #expect(abs(encoded.dpi - 72 * backingScale) < 0.1)
        #expect(encoded.width > 640)
        #expect(encoded.profile?.isEmpty == false)
    }

    /// The CI performance guard (`.github/workflows/performance.yml`): times the screenshot export on a synthetic
    /// 2880×1800 frame and writes the samples as JSON for `.github/scripts/perf-guard.cjs`. It fails by itself only on
    /// a gross slowdown, so run-to-run noise on shared runners never breaks a build.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GLINT_EXPORT_BENCHMARK"] == "1"))
    func syntheticRetinaExportStaysWithinBudget() throws {
        let environment = ProcessInfo.processInfo.environment
        let iterations = environment["GLINT_EXPORT_BENCHMARK_ITERATIONS"].flatMap(Int.init) ?? 30
        let budgetMs = environment["GLINT_RENDER_ENCODE_BUDGET_MS"].flatMap(Double.init) ?? 5_000
        let backingScale: CGFloat = 2
        let frame = try #require(ExportTiming.syntheticFrame())
        var encoded = try ExportTiming.renderAndEncode(frame, backingScale: backingScale)
        var samples: [Double] = []
        let clock = ContinuousClock()
        for _ in 0..<iterations {
            let start = clock.now
            encoded = try ExportTiming.renderAndEncode(frame, backingScale: backingScale)
            samples.append(TimingStatistics.milliseconds(start.duration(to: clock.now)))
        }
        let summary = try #require(TimingStatistics.summarize(samples))
        let png = try properties(of: encoded)
        print("Synthetic \(frame.width)×\(frame.height) render+encode: p50 \(summary.p50Ms) ms, p95 \(summary.p95Ms) ms "
            + "over \(summary.count) runs, \(encoded.count) bytes")

        #expect(abs(png.dpi - 72 * backingScale) < 0.1)
        #expect(png.profile?.isEmpty == false)
        #expect(summary.p95Ms <= budgetMs, "p95 \(summary.p95Ms) ms is over the \(budgetMs) ms budget")

        if let path = environment["GLINT_EXPORT_BENCHMARK_OUTPUT"] {
            let report = ExportBenchmarkReport(
                measurement: "synthetic styled render + PNG encode, CPU only; no screen pixels",
                frame: .init(width: frame.width, height: frame.height, source: "synthetic"),
                backingScale: Double(backingScale), warmIterations: iterations,
                renderAndEncode: summary,
                png: .init(bytes: encoded.count, dpi: png.dpi, hasProfile: png.profile?.isEmpty == false))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

private struct ExportBenchmarkReport: Encodable {
    struct Frame: Encodable { let width: Int; let height: Int; let source: String }
    struct PNG: Encodable {
        let bytes: Int
        let dpi: Double
        let hasProfile: Bool
        enum CodingKeys: String, CodingKey { case bytes, dpi, hasProfile = "has_profile" }
    }

    let measurement: String
    let frame: Frame
    let backingScale: Double
    let warmIterations: Int
    let renderAndEncode: TimingSummary
    let png: PNG

    enum CodingKeys: String, CodingKey {
        case measurement, frame, png
        case backingScale = "backing_scale"
        case warmIterations = "warm_iterations"
        case renderAndEncode = "render_and_encode"
    }
}
