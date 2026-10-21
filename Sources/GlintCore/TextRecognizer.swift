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
    public struct Options: Sendable {
        public var languages: [String]
        public var usesLanguageCorrection: Bool
        public var minimumTextHeight: Float
        public init(languages: [String] = [], usesLanguageCorrection: Bool = false, minimumTextHeight: Float = 0) {
            self.languages = languages; self.usesLanguageCorrection = usesLanguageCorrection
            self.minimumTextHeight = minimumTextHeight
        }
    }

    /// Accurate-mode Vision OCR. Boxes are converted to image pixels with a top-left origin.
    public static func recognize(in image: CGImage, options: Options = Options()) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try recognizeSync(in: image, options: options)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    public static func recognizeSync(in image: CGImage, options: Options = Options()) throws -> [RecognizedLine] {
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
