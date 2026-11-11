import CoreGraphics
import Foundation

/// A tiny greyscale copy of a frame, cheap enough to grab about ten times a second to notice scrolling without
/// grabbing and comparing full-resolution frames.
public struct ScrollSignature: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Row-major luma, top row first.
    public let luma: [UInt8]

    public init(width: Int, height: Int, luma: [UInt8]) {
        self.width = width
        self.height = height
        self.luma = luma
    }

    /// `image` reduced to `columns` wide, keeping its aspect ratio within 8...128 rows.
    public init?(image: CGImage, columns: Int = 32) {
        let w = max(columns, 1)
        let h = min(max(Int((Double(w) * Double(image.height) / Double(max(image.width, 1))).rounded()), 8), 128)
        var luma = [UInt8](repeating: 0, count: w * h)
        let drawn = luma.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, luma: luma)
    }

    /// Mean absolute luma difference (0...255); infinite when the sizes differ.
    public func difference(from other: ScrollSignature) -> Double {
        guard other.width == width, other.height == height, !luma.isEmpty else { return .infinity }
        var sum = 0
        for i in luma.indices { sum += abs(Int(luma[i]) - Int(other.luma[i])) }
        return Double(sum) / Double(luma.count)
    }

    /// Rows the content moved up since `other` (negative: down), as the best match over at least a quarter of
    /// the rows.
    public func shift(from other: ScrollSignature) -> Int? {
        guard other.width == width, other.height == height, height > 1 else { return nil }
        var best: (shift: Int, score: Double)?
        let maxShift = height * 3 / 4
        for shift in -maxShift...maxShift {
            let rows = height - abs(shift)
            var sum = 0
            for y in 0..<rows {
                let a = (y + max(shift, 0)) * width, b = (y + max(-shift, 0)) * width
                for x in 0..<width { sum += abs(Int(other.luma[a + x]) - Int(luma[b + x])) }
            }
            let score = Double(sum) / Double(rows * width)
            if best == nil || score < (best?.score ?? .infinity) { best = (shift, score) }
        }
        return best?.shift
    }
}

/// Decides when the scrolling capture grabs a full frame: once the content has changed and then held still for
/// `settleInterval` (the user paused), as soon as it has moved `grabFraction` of the frame, or after it has kept
/// moving for `maxMovingInterval`, so fast or continuous scrolling still leaves the overlap the stitcher needs.
/// The time cap matters when fixed headers or footers hide how far the content moved from the signature shift.
public struct ScrollGrabPolicy: Sendable {
    public var settleInterval: TimeInterval
    public var grabFraction: Double
    public var maxMovingInterval: TimeInterval
    /// Mean luma difference below which two signatures count as the same picture.
    public var changeThreshold: Double

    private var last: ScrollSignature?
    private var stillSince: TimeInterval?
    private var movingSince: TimeInterval?

    public init(settleInterval: TimeInterval = 0.15, grabFraction: Double = 0.5, maxMovingInterval: TimeInterval = 0.3,
                changeThreshold: Double = 0.75) {
        self.settleInterval = settleInterval
        self.grabFraction = grabFraction
        self.maxMovingInterval = maxMovingInterval
        self.changeThreshold = changeThreshold
    }

    /// Feeds the latest signature; true when a frame should be grabbed now. `reference` is the signature of the
    /// last frame given to the stitcher.
    public mutating func shouldGrab(_ signature: ScrollSignature, at now: TimeInterval,
                                    reference: ScrollSignature?) -> Bool {
        defer { last = signature }
        guard let reference else { return true }
        guard signature.difference(from: reference) > changeThreshold else {
            stillSince = nil
            movingSince = nil
            return false
        }
        let moving = movingSince ?? now
        movingSince = moving
        if let shift = signature.shift(from: reference),
           Double(abs(shift)) >= Double(signature.height) * grabFraction {
            return grabbed()
        }
        if now - moving >= maxMovingInterval { return grabbed() }
        if let last, signature.difference(from: last) <= changeThreshold {
            let since = stillSince ?? now
            stillSince = since
            return now - since >= settleInterval ? grabbed() : false
        }
        stillSince = now
        return false
    }

    private mutating func grabbed() -> Bool {
        stillSince = nil
        movingSince = nil
        return true
    }

    /// Forgets the movement seen so far, for example after the user resumed from a warning.
    public mutating func reset() {
        last = nil
        stillSince = nil
        movingSince = nil
    }
}

/// Advisory feedback only: a slow scroll is safe, but the user may need a nudge to continue or finish.
public enum ScrollCapturePace: Equatable, Sendable {
    case ready, steady, tooFast, tooSlow

    public var message: String {
        switch self {
        case .ready: return "Scroll down steadily to capture more."
        case .steady: return "Steady — keep this pace."
        case .tooFast: return "Too fast — slow down to keep frames aligned."
        case .tooSlow: return "Too slow — scroll down a little, or choose Done if finished."
        }
    }
}

/// Measures viewport travel per second from successive observations, independently of the grab threshold.
public struct ScrollPacePolicy: Sendable {
    private var last: ScrollSignature?
    private var lastTime: TimeInterval?
    private var lastMovement: TimeInterval?
    private var pace: ScrollCapturePace = .ready

    public init() {}

    public mutating func observe(_ signature: ScrollSignature, at now: TimeInterval) -> ScrollCapturePace {
        defer {
            last = signature
            lastTime = now
        }
        guard let last, let lastTime else {
            lastMovement = now
            return .ready
        }
        let elapsed = now - lastTime
        if elapsed > 0, signature.difference(from: last) > 0.75,
           let shift = signature.shift(from: last), shift != 0 {
            let rate = Double(abs(shift)) / Double(max(signature.height, 1)) / elapsed
            lastMovement = now
            pace = rate > 1 ? .tooFast : (rate < 0.08 ? .tooSlow : .steady)
        } else if now - (lastMovement ?? now) >= 2 {
            pace = .tooSlow
        }
        return pace
    }

    public mutating func reset() { self = ScrollPacePolicy() }
}
