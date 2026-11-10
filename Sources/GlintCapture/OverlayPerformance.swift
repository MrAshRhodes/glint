import CoreGraphics
import os

@MainActor
enum OverlayPerformance {
    static let signposter = OSSignposter(subsystem: "io.github.mrashrhodes.glint", category: "SelectionOverlay")
    /// The `Capture` category of `CaptureSignposts` (GlintCore). This file also compiles on its own for
    /// Scripts/benchmark-overlay.sh, so it cannot import GlintCore; `SnapTargets` is the one capture interval it emits.
    private static let captureSignposter = OSSignposter(subsystem: "io.github.mrashrhodes.glint", category: "Capture")

    struct DirtyRegion {
        let rectCount: Int
        let coveredFraction: Double
        let boundingFraction: Double
        let fromAppKit: Bool

        init(rects: [CGRect], bounds: CGRect, fromAppKit: Bool) {
            self.fromAppKit = fromAppKit
            let clipped = rects.map { $0.intersection(bounds) }.filter { !$0.isEmpty && !$0.isInfinite }
            rectCount = clipped.count
            let area = bounds.width * bounds.height
            guard area > 0, area.isFinite, !clipped.isEmpty else {
                coveredFraction = 0
                boundingFraction = 0
                return
            }
            // Integrate merged y intervals in each x slab so overlapping damage is counted only once.
            let edges = Array(Set(clipped.flatMap { [$0.minX, $0.maxX] })).sorted()
            var covered: CGFloat = 0
            for (left, right) in zip(edges, edges.dropFirst()) {
                let spans = clipped.filter { $0.minX < right && $0.maxX > left }.sorted { $0.minY < $1.minY }
                var top = -CGFloat.infinity
                var height: CGFloat = 0
                for rect in spans {
                    height += max(0, rect.maxY - max(top, rect.minY))
                    top = max(top, rect.maxY)
                }
                covered += (right - left) * height
            }
            let bounding = clipped.reduce(CGRect.null) { $0.union($1) }
            coveredFraction = min(1, Double(covered / area))
            boundingFraction = min(1, Double(bounding.width * bounding.height / area))
        }
    }

    static func begin(_ name: StaticString) -> OSSignpostIntervalState? {
        guard signposter.isEnabled else { return nil }
        return signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func beginDraw(_ name: StaticString, region: DirtyRegion?) -> OSSignpostIntervalState? {
        guard signposter.isEnabled, let region else { return nil }
        return signposter.beginInterval(
            name, id: signposter.makeSignpostID(),
            "rects=\(region.rectCount, privacy: .public) covered=\(region.coveredFraction, format: .fixed(precision: 5), privacy: .public) bounding=\(region.boundingFraction, format: .fixed(precision: 5), privacy: .public) appkit=\(region.fromAppKit ? 1 : 0, privacy: .public)")
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState?, cancelled: Bool = false) {
        guard let state else { return }
        if cancelled {
            signposter.endInterval(name, state, "cancelled")
        } else {
            signposter.endInterval(name, state)
        }
    }

    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { end(name, interval) }
        return try body()
    }

    /// Like `measure`, in the `Capture` category.
    static func measureCapture<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        guard captureSignposter.isEnabled else { return try body() }
        let state = captureSignposter.beginInterval(name, id: captureSignposter.makeSignpostID())
        defer { captureSignposter.endInterval(name, state) }
        return try body()
    }
}
