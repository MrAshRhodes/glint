import CoreGraphics
import Foundation
import Vision

/// Tracks a region with Vision's object tracker, then checks every result against the content first selected.
///
/// Vision reports high confidence even while slowly drifting off text and list rows, so each position is also
/// compared with the original patch by normalised cross-correlation of luma. The reported confidence is the lower
/// of the two, which lets `RedactionTracker` flag drift instead of following it.
public final class VisionFrameTracker: FrameTracker {
    /// Lowest acceptable correlation with the original patch.
    public let minimumCorrelation: Double
    private let handler = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest?
    private var template: LumaPatch?
    private var templateSize: CGSize = .zero

    public init(minimumCorrelation: Double = 0.6) {
        self.minimumCorrelation = minimumCorrelation
    }

    public func start(on frame: TrackingFrame, rect: CGRect) throws {
        let observation = VNDetectedObjectObservation(boundingBox: Self.normalized(rect, in: frame.sourceSize))
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        self.request = request
        template = LumaPatch(frame: frame, rect: rect)
        templateSize = rect.standardized.size
    }

    public func track(_ frame: TrackingFrame) throws -> FrameTrackerObservation? {
        guard let request, let template else { return nil }
        try handler.perform([request], on: frame.luma)
        guard let result = request.results?.first as? VNDetectedObjectObservation else { return nil }
        let found = Self.denormalized(result.boundingBox, in: frame.sourceSize)
        // Vision lags behind moving content and its confidence is not comparable between frames, so settle on the
        // nearby position that best matches the original content and trust only that match.
        let (rect, correlation) = refine(around: CGPoint(x: found.midX, y: found.midY), in: frame, template: template)
        // A new observation would start another Vision tracker, and only a few may exist at once.
        request.inputObservation = result
        return FrameTrackerObservation(rect: rect, confidence: correlation >= minimumCorrelation ? correlation : 0)
    }

    private func refine(around center: CGPoint, in frame: TrackingFrame, template: LumaPatch) -> (CGRect, Double) {
        let size = templateSize
        func candidate(_ c: CGPoint) -> (CGRect, Double) {
            let rect = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
            return (rect, LumaPatch(frame: frame, rect: rect).map { template.correlation(with: $0) } ?? -1)
        }
        let reach = max(size.width, size.height) / 2
        let coarse = max(1, (reach / 9).rounded())
        let fine = max(1, (coarse / 4).rounded())
        var best = candidate(center), bestCenter = center
        for dy in stride(from: -reach, through: reach, by: coarse) {
            for dx in stride(from: -reach, through: reach, by: coarse) {
                let point = CGPoint(x: center.x + dx, y: center.y + dy)
                let next = candidate(point)
                if next.1 > best.1 { best = next; bestCenter = point }
            }
        }
        let coarseCenter = bestCenter
        for dy in stride(from: -coarse, through: coarse, by: fine) {
            for dx in stride(from: -coarse, through: coarse, by: fine) {
                let point = CGPoint(x: coarseCenter.x + dx, y: coarseCenter.y + dy)
                let next = candidate(point)
                if next.1 > best.1 { best = next; bestCenter = point }
            }
        }
        return best
    }

    /// Vision uses normalised coordinates with a bottom-left origin.
    static func normalized(_ rect: CGRect, in size: CGSize) -> CGRect {
        let w = max(size.width, 1), h = max(size.height, 1)
        let r = rect.standardized
        return CGRect(x: r.minX / w, y: 1 - r.maxY / h, width: r.width / w, height: r.height / h)
    }

    static func denormalized(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: (1 - rect.maxY) * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }
}

/// A fixed-size grid of luma samples from one rect of a frame, for comparing content between frames.
struct LumaPatch {
    static let side = 24
    let values: [Double]

    init(values: [Double]) { self.values = values }

    /// `rect` is in the frame's source pixels. Nil when it lies outside the frame.
    init?(frame: TrackingFrame, rect: CGRect) {
        let image = frame.luma
        let sx = CGFloat(image.width) / max(frame.sourceSize.width, 1)
        let sy = CGFloat(image.height) / max(frame.sourceSize.height, 1)
        let scaled = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !scaled.isNull, scaled.width >= 1, scaled.height >= 1 else { return nil }
        let pixel = scaled.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let crop = image.cropping(to: pixel) else { return nil }
        let side = Self.side
        var bytes = [UInt8](repeating: 0, count: side * side)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            // Core Graphics draws bottom-up; place the crop so the requested patch fills the context.
            let k = CGFloat(side)
            let fx = k / scaled.width, fy = k / scaled.height
            context.draw(crop, in: CGRect(x: (pixel.minX - scaled.minX) * fx, y: (scaled.maxY - pixel.maxY) * fy,
                                          width: pixel.width * fx, height: pixel.height * fy))
            return true
        }
        guard drawn else { return nil }
        values = bytes.map(Double.init)
    }

    /// Normalised cross-correlation in -1...1. Two flat patches correlate when their brightness matches.
    func correlation(with other: LumaPatch) -> Double {
        guard values.count == other.values.count, !values.isEmpty else { return 0 }
        let n = Double(values.count)
        let meanA = values.reduce(0, +) / n, meanB = other.values.reduce(0, +) / n
        var cov = 0.0, varA = 0.0, varB = 0.0
        for (a, b) in zip(values, other.values) {
            cov += (a - meanA) * (b - meanB)
            varA += (a - meanA) * (a - meanA)
            varB += (b - meanB) * (b - meanB)
        }
        let flat = 4.0 * n // standard deviation below 2 of 255
        if varA < flat && varB < flat { return abs(meanA - meanB) < 12 ? 1 : 0 }
        if varA < flat || varB < flat { return 0 }
        return cov / (varA * varB).squareRoot()
    }
}
