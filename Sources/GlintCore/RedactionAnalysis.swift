import CoreGraphics
import Foundation

/// Where one capture's automatic redaction stands. The capture pipeline reads the text once and hands this to the
/// editor with the redacted pixels, so a capture is recognised once for a set of settings, not again when it is
/// edited or reopened from the quick-access thumbnail.
///
/// Only a finished answer for the same `Settings` is reused (`isReusable(for:)`). `pending`, `failed`, `cancelled`
/// and `notRequested` are not answers: whoever needs redaction asks again, and pixels that still need an answer must
/// not be shown or published while it is `pending`.
public enum RedactionAnalysis: Equatable, Sendable {
    /// Automatic redaction was not asked for this capture.
    case notRequested
    /// Text recognition is running and the answer is not known yet.
    case pending
    /// Finished, and nothing sensitive was found. This is an answer like any other, and is reused.
    case noMatches(Settings)
    /// Finished, and these were covered.
    case matches(Findings, Settings)
    /// Recognition failed; the text is what the user is told. Nothing is known about the capture.
    case failed(String)
    /// Stopped before it finished, because its editor closed or its source changed. Its result is never applied.
    case cancelled

    /// What decides which text counts as sensitive. The colour and padding of the cover are not part of it: they
    /// change how a finding is drawn, not what is found.
    public struct Settings: Equatable, Sendable {
        public var detector: SensitiveInfoOptions
        public var recognizer: TextRecognizer.Options

        public init(detector: SensitiveInfoOptions, recognizer: TextRecognizer.Options = .init()) {
            self.detector = detector
            self.recognizer = recognizer
        }
    }

    /// The covers a finished pass drew. Holds counts only: never the recognised text, which could be the very
    /// secret that was redacted.
    public struct Findings: Equatable, Sendable {
        /// Number of covers drawn, which is the sum of `byCategory`.
        public var count: Int
        public var byCategory: [SensitiveCategory: Int]

        public init(count: Int, byCategory: [SensitiveCategory: Int]) {
            self.count = count
            self.byCategory = byCategory
        }
    }

    public var isPending: Bool { self == .pending }

    /// True once a pass finished, with or without matches.
    public var isCompleted: Bool {
        switch self {
        case .noMatches, .matches: return true
        case .notRequested, .pending, .failed, .cancelled: return false
        }
    }

    /// The settings a finished pass used.
    public var settings: Settings? {
        switch self {
        case .noMatches(let settings), .matches(_, let settings): return settings
        case .notRequested, .pending, .failed, .cancelled: return nil
        }
    }

    /// True only for a finished answer taken with exactly `requested`.
    public func isReusable(for requested: Settings) -> Bool { settings == requested }

    /// What the editor tells the user, or `nil` while there is nothing to say.
    public var summary: String? {
        switch self {
        case .notRequested, .pending, .cancelled:
            return nil
        case .noMatches:
            return "No sensitive information found."
        case .matches(let found, _):
            let counts = found.byCategory.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.displayName) ×\($0.value)" }.joined(separator: ", ")
            return "Redacted \(found.count): \(counts)"
        case .failed(let message):
            return message
        }
    }
}

/// How recognised text becomes the pixels that are covered. The capture pipeline, the editor and
/// `EditorHeadless` share it, so one capture is covered identically wherever it is redacted.
///
/// 1. `TextRecognizer` turns Vision's normalised boxes (origin bottom-left) into image pixels with a top-left origin:
///    `x * width` and `(1 - maxY) * height`, for each word and each line.
/// 2. `SensitiveInfoDetector` narrows a match to the words it spans, trimming a partly matched word in proportion.
/// 3. The match grows by `padding(backingScale:)` on every side: `paddingPoints` logical points, so the same
///    physical margin at 1× and 2×.
/// 4. The result is clipped to the image, so a match at an edge is covered up to the edge, and dropped when nothing
///    is left inside.
public enum RedactionPolicy {
    /// Margin around a match, in logical points.
    public static let paddingPoints = 3.0

    /// `paddingPoints` in image pixels for a capture taken at `backingScale` pixels per point; a scale below 1 counts
    /// as 1.
    public static func padding(backingScale: CGFloat) -> Double {
        paddingPoints * Double(max(backingScale, 1))
    }
}

extension AutoRedactOptions {
    /// Options whose margin follows `RedactionPolicy` for a capture at `backingScale` pixels per point.
    public init(detector: SensitiveInfoOptions = .default, color: RGBAColor = .black, backingScale: CGFloat,
                recognizer: TextRecognizer.Options = .init()) {
        self.init(detector: detector, color: color, padding: RedactionPolicy.padding(backingScale: backingScale),
                  recognizer: recognizer)
    }

    /// The part of these options that decides what is found, for comparing with a recorded `RedactionAnalysis`.
    public var settings: RedactionAnalysis.Settings {
        RedactionAnalysis.Settings(detector: detector, recognizer: recognizer)
    }
}

extension AutoRedact {
    /// One automatic pass over recognised `lines`: the covers to draw, and the finished analysis to record with them.
    public static func analyse(_ lines: [RecognizedLine], options: AutoRedactOptions,
                               imageSize: CGSize) -> (annotations: [Annotation], analysis: RedactionAnalysis) {
        let covers = covered(lines, options: options, imageSize: imageSize)
        guard !covers.isEmpty else { return ([], .noMatches(options.settings)) }
        var byCategory: [SensitiveCategory: Int] = [:]
        for cover in covers { byCategory[cover.finding.category, default: 0] += 1 }
        let findings = RedactionAnalysis.Findings(count: covers.count, byCategory: byCategory)
        return (covers.map(\.annotation), .matches(findings, options.settings))
    }
}
