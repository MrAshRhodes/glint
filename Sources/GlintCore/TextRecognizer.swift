import CoreGraphics
import Foundation
import Vision

public struct RecognizedWord: Equatable, Sendable {
    public var text: String
    /// UTF-16 range inside the line's `text`.
    public var range: NSRange
    /// Image pixels, origin top-left.
    public var box: CGRect
    public init(text: String, range: NSRange, box: CGRect) { self.text = text; self.range = range; self.box = box }
}

public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var box: CGRect
    public var words: [RecognizedWord]
    public var confidence: Float

    public init(text: String, box: CGRect, words: [RecognizedWord] = [], confidence: Float = 1) {
        self.text = text; self.box = box; self.words = words; self.confidence = confidence
    }

    /// Image-space rect covering the UTF-16 `range` of `text`. Uses word boxes when present (partial words
    /// are trimmed proportionally), otherwise spreads the line box evenly over the characters.
    public func rect(forUTF16Range range: NSRange) -> CGRect {
        let total = max((text as NSString).length, 1)
        func proportional(_ outer: CGRect, _ outerRange: NSRange, _ r: NSRange) -> CGRect {
            let len = max(outerRange.length, 1)
            let lo = CGFloat(max(r.location, outerRange.location) - outerRange.location) / CGFloat(len)
            let hi = CGFloat(min(r.location + r.length, outerRange.location + outerRange.length) - outerRange.location) / CGFloat(len)
            return CGRect(x: outer.minX + outer.width * lo, y: outer.minY, width: outer.width * max(hi - lo, 0), height: outer.height)
        }
        if words.isEmpty { return proportional(box, NSRange(location: 0, length: total), range) }
        var result: CGRect?
        for w in words {
            let inter = NSIntersectionRange(w.range, range)
            guard inter.length > 0 else { continue }
            let r = proportional(w.box, w.range, inter)
            result = result.map { $0.union(r) } ?? r
        }
        return result ?? proportional(box, NSRange(location: 0, length: total), range)
    }
}

public enum TextRecognizer {
    public struct Options: Equatable, Sendable {
        public var languages: [String]
        public var usesLanguageCorrection: Bool
        public var minimumTextHeight: Float
        public init(languages: [String] = [], usesLanguageCorrection: Bool = false, minimumTextHeight: Float = 0) {
            self.languages = languages; self.usesLanguageCorrection = usesLanguageCorrection
            self.minimumTextHeight = minimumTextHeight
        }
    }

    /// What the recognition passes of this process have cost so far. A pass is one call to `recognize` or
    /// `recognizeSync`, so an image read in several bands is still one pass. Read it before and after an action to
    /// count the passes the action ran; it only grows, and other work in the process adds to it too.
    public struct Statistics: Equatable, Sendable {
        /// Passes begun.
        public var passes = 0
        /// Passes that ended with an error.
        public var failures = 0
        /// Wall-clock seconds spent in passes that have ended.
        public var seconds = 0.0
        /// Passes begun and not yet ended.
        public var inFlight = 0
    }

    public static var statistics: Statistics { counter.statistics }

    /// Passes start on background queues and are read from anywhere, so the totals sit behind a lock. Tests build
    /// their own to check the arithmetic without being disturbed by the process-wide one.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var totals = Statistics()

        var statistics: Statistics {
            lock.lock()
            defer { lock.unlock() }
            return totals
        }

        /// Records a pass beginning and returns the time to hand to `end`.
        func begin() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            totals.passes += 1
            totals.inFlight += 1
            return DispatchTime.now().uptimeNanoseconds
        }

        func end(startedAt start: UInt64, failed: Bool) {
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            lock.lock()
            defer { lock.unlock() }
            totals.inFlight -= 1
            totals.seconds += Double(elapsed) / 1_000_000_000
            if failed { totals.failures += 1 }
        }
    }

    static let counter = Counter()

    /// Accurate-mode Vision OCR. Boxes are converted to image pixels with a top-left origin.
    public static func recognize(in image: CGImage, options: Options = Options()) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try recognizeSync(in: image, options: options)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Tallest slice given to Vision in one request. Vision scales a whole image down to its working size, so text
    /// in a very tall image (a scrolling capture) would shrink below what it can read; slices keep it legible.
    public static let maximumBandHeight = 4096
    /// Rows shared by neighbouring slices, taller than any line of text, so every line lies whole in one slice.
    public static let bandOverlap = 256

    /// One recognition pass: counted in `statistics` and timed as the `Recognize` signpost interval.
    public static func recognizeSync(in image: CGImage, options: Options = Options()) throws -> [RecognizedLine] {
        try recognizeSync(in: image, options: options, counter: counter)
    }

    static func recognizeSync(in image: CGImage, options: Options, counter: Counter) throws -> [RecognizedLine] {
        let started = counter.begin()
        do {
            let lines = try CaptureSignposts.measure("Recognize") { try recognizePass(in: image, options: options) }
            counter.end(startedAt: started, failed: false)
            return lines
        } catch {
            counter.end(startedAt: started, failed: true)
            throw error
        }
    }

    private static func recognizePass(in image: CGImage, options: Options) throws -> [RecognizedLine] {
        let ranges = bands(height: image.height)
        guard ranges.count > 1 else { return try recognizeSingle(in: image, options: options) }
        return try recognizeBanded(ranges) { range in
            let rect = CGRect(x: 0, y: range.lowerBound, width: image.width, height: range.count)
            guard let slice = image.cropping(to: rect) else { return [] }
            return try recognizeSingle(in: slice, options: options)
        }
    }

    /// Row ranges covering `height` in slices of at most `maxBand`, each overlapping the next by `overlap`.
    public static func bands(height: Int, maxBand: Int = maximumBandHeight, overlap: Int = bandOverlap) -> [Range<Int>] {
        guard height > maxBand, maxBand > overlap else { return [0..<max(height, 0)] }
        var ranges: [Range<Int>] = []
        var start = 0
        while true {
            let end = min(start + maxBand, height)
            ranges.append(start..<end)
            if end == height { return ranges }
            start = end - overlap
        }
    }

    /// Runs `recognize` on each slice (results in slice coordinates) and merges them into image coordinates. A
    /// line is kept by the slice that owns its centre (the overlap is split down the middle), and an identical line
    /// at the same place is dropped, so text in an overlap is reported once.
    public static func recognizeBanded(_ ranges: [Range<Int>],
                                       recognize: (Range<Int>) throws -> [RecognizedLine]) rethrows -> [RecognizedLine] {
        var merged: [RecognizedLine] = []
        for (i, range) in ranges.enumerated() {
            let ownedTop = i == 0 ? range.lowerBound : (range.lowerBound + ranges[i - 1].upperBound) / 2
            let ownedBottom = i == ranges.count - 1 ? range.upperBound : (range.upperBound + ranges[i + 1].lowerBound) / 2
            let dy = CGFloat(range.lowerBound)
            for var line in try recognize(range) {
                line.box = line.box.offsetBy(dx: 0, dy: dy)
                line.words = line.words.map { word in
                    var word = word
                    word.box = word.box.offsetBy(dx: 0, dy: dy)
                    return word
                }
                let mid = line.box.midY
                guard mid >= CGFloat(ownedTop), mid < CGFloat(ownedBottom) else { continue }
                let duplicate = merged.contains { other in
                    guard other.text == line.text else { return false }
                    let overlap = other.box.intersection(line.box)
                    guard !overlap.isNull else { return false }
                    return overlap.width * overlap.height >= 0.5 * min(other.box.width * other.box.height,
                                                                        line.box.width * line.box.height)
                }
                if !duplicate { merged.append(line) }
            }
        }
        return merged.sorted { $0.box.minY != $1.box.minY ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
    }

    private static func recognizeSingle(in image: CGImage, options: Options) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = options.usesLanguageCorrection
        if !options.languages.isEmpty { request.recognitionLanguages = options.languages }
        if options.minimumTextHeight > 0 { request.minimumTextHeight = options.minimumTextHeight }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let w = CGFloat(image.width), h = CGFloat(image.height)
        func toImage(_ n: CGRect) -> CGRect {
            CGRect(x: n.minX * w, y: (1 - n.maxY) * h, width: n.width * w, height: n.height * h)
        }
        var lines: [RecognizedLine] = []
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let text = cand.string
            var words: [RecognizedWord] = []
            let ns = text as NSString
            let tokens = try NSRegularExpression(pattern: "\\S+").matches(in: text, range: NSRange(location: 0, length: ns.length))
            for t in tokens {
                guard let swiftRange = Range(t.range, in: text), let box = try? cand.boundingBox(for: swiftRange) else { continue }
                words.append(RecognizedWord(text: ns.substring(with: t.range), range: t.range, box: toImage(box.boundingBox)))
            }
            lines.append(RecognizedLine(text: text, box: toImage(obs.boundingBox), words: words, confidence: cand.confidence))
        }
        return lines.sorted { $0.box.minY != $1.box.minY ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
    }
}
