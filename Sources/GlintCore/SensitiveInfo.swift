import CoreGraphics
import Foundation
import Darwin

public enum SensitiveCategory: String, Codable, CaseIterable, Sendable {
    case email, phone, creditCard, ipAddress, apiKey, ssn, url, macAddress, custom

    public var displayName: String {
        switch self {
        case .email: return "Email addresses"
        case .phone: return "Phone numbers"
        case .creditCard: return "Credit cards"
        case .ipAddress: return "IP addresses"
        case .apiKey: return "API keys & tokens"
        case .ssn: return "SSN-like numbers"
        case .url: return "URLs"
        case .macAddress: return "MAC addresses"
        case .custom: return "Custom words"
        }
    }
}

public struct SensitiveInfoOptions: Codable, Equatable, Sendable {
    public var categories: Set<SensitiveCategory>
    public var customWords: [String]
    public var caseSensitive: Bool

    public init(categories: Set<SensitiveCategory>, customWords: [String] = [], caseSensitive: Bool = false) {
        self.categories = categories; self.customWords = customWords; self.caseSensitive = caseSensitive
    }

    /// Default categories (API keys + credit cards) plus e-mail and SSN-like numbers.
    public static let `default` = SensitiveInfoOptions(categories: [.email, .creditCard, .apiKey, .ssn, .custom])
    public static let all = SensitiveInfoOptions(categories: Set(SensitiveCategory.allCases))
}

public struct SensitiveMatch: Equatable, Sendable {
    public var category: SensitiveCategory
    public var text: String
    /// UTF-16 range in the scanned string.
    public var range: NSRange
}

public struct SensitiveFinding: Equatable, Sendable {
    public var category: SensitiveCategory
    public var text: String
    /// Image pixels, origin top-left.
    public var rect: CGRect
}

public enum Luhn {
    /// True for 13–19 digit strings passing the Luhn checksum (separators ignored).
    public static func isValid(_ s: String) -> Bool {
        let stripped = s.filter { $0 != " " && $0 != "-" }
        guard stripped.allSatisfy({ $0.isASCII && $0.isNumber }), (13...19).contains(stripped.count) else { return false }
        let digits = stripped.compactMap { $0.wholeNumberValue }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }
}

public struct SensitiveInfoDetector: Sendable {
    public var options: SensitiveInfoOptions
    public init(options: SensitiveInfoOptions = .default) { self.options = options }

    private struct Rule {
        let category: SensitiveCategory
        let regex: NSRegularExpression
        let validate: (@Sendable (String) -> Bool)?
    }

    private static func rule(_ c: SensitiveCategory, _ pattern: String, options: NSRegularExpression.Options = [],
                             validate: (@Sendable (String) -> Bool)? = nil) -> Rule {
        Rule(category: c, regex: try! NSRegularExpression(pattern: pattern, options: options), validate: validate)
    }

    // Priority order: earlier rules win overlaps.
    private static let rules: [Rule] = [
        rule(.apiKey, #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[0-9A-Z]{16}\b"#),
        rule(.apiKey, #"\bgh[pousr]_[A-Za-z0-9]{36,255}\b|\bgithub_pat_[A-Za-z0-9_]{22,255}\b"#),
        rule(.apiKey, #"\bxox[abposr]-[A-Za-z0-9-]{10,}\b"#),
        rule(.apiKey, #"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}\b|\bwhsec_[A-Za-z0-9]{16,}\b"#),
        rule(.apiKey, #"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\b"#),
        rule(.apiKey, #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        rule(.apiKey, #"\bsk-[A-Za-z0-9_-]{20,}\b"#),
        rule(.apiKey, #"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])"#, validate: { highEntropy($0) }),
        rule(.creditCard, #"(?<![\d-])(?:\d[ -]?){12,18}\d(?![\d-])"#, validate: { Luhn.isValid($0) }),
        rule(.ssn, #"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#),
        rule(.email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}"#),
        rule(.macAddress, #"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#),
        rule(.ipAddress, #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])"#),
        rule(.ipAddress, #"(?<![0-9A-Fa-f:])[0-9A-Fa-f:]{2,39}(?![0-9A-Fa-f:])"#, validate: { isIPv6($0) }),
        rule(.url, #"\b(?:https?://|www\.)[^\s<>"']+"#, options: .caseInsensitive),
        rule(.phone, #"(?<![\w.])\+?\d[\d ().-]{7,18}\d(?![\w])"#, validate: { isPhone($0) }),
    ]

    static func highEntropy(_ s: String) -> Bool {
        let hasLetter = s.contains { $0.isLetter }, hasDigit = s.contains { $0.isNumber }
        guard hasLetter, hasDigit else { return false }
        var freq: [Character: Int] = [:]
        for ch in s { freq[ch, default: 0] += 1 }
        let n = Double(s.count)
        let entropy = -freq.values.reduce(0.0) { $0 + (Double($1) / n) * log2(Double($1) / n) }
        return entropy >= 3.5
    }

    static func isIPv6(_ s: String) -> Bool {
        guard s.filter({ $0 == ":" }).count >= 2 else { return false }
        var addr = in6_addr()
        return inet_pton(AF_INET6, s, &addr) == 1
    }

    static func isPhone(_ s: String) -> Bool {
        let digits = s.filter { $0.isNumber }.count
        guard (9...15).contains(digits) else { return false }
        let hasSeparator = s.contains { " ().-+".contains($0) }
        guard hasSeparator else { return false }
        if s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return false } // ISO date
        if s.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil { return false } // IPv4
        if Luhn.isValid(s) && !s.hasPrefix("+") { return false }
        return true
    }

    /// All non-overlapping matches of the enabled categories, sorted by position.
    public func matches(in text: String) -> [SensitiveMatch] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var accepted: [SensitiveMatch] = []
        func overlaps(_ r: NSRange) -> Bool { accepted.contains { NSIntersectionRange($0.range, r).length > 0 } }

        if options.categories.contains(.custom) {
            for word in options.customWords where !word.trimmingCharacters(in: .whitespaces).isEmpty {
                var search = full
                let cmp: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
                while search.length > 0 {
                    let r = ns.range(of: word, options: cmp, range: search)
                    if r.location == NSNotFound { break }
                    if !overlaps(r) { accepted.append(SensitiveMatch(category: .custom, text: ns.substring(with: r), range: r)) }
                    search = NSRange(location: r.upperBound, length: ns.length - r.upperBound)
                }
            }
        }
        for rule in Self.rules where options.categories.contains(rule.category) {
            for m in rule.regex.matches(in: text, range: full) {
                var r = m.range
                var s = ns.substring(with: r)
                if rule.category == .url { // trailing sentence punctuation is not part of the URL
                    while let last = s.last, ".,;:!?)".contains(last) { s.removeLast(); r.length -= 1 }
                }
                if let v = rule.validate, !v(s) { continue }
                if r.length > 0, !overlaps(r) { accepted.append(SensitiveMatch(category: rule.category, text: s, range: r)) }
            }
        }
        return accepted.sorted { $0.range.location < $1.range.location }
    }

    /// Findings with image-space rects for OCR output.
    public func findings(in lines: [RecognizedLine]) -> [SensitiveFinding] {
        var out: [SensitiveFinding] = []
        for line in lines {
            for m in matches(in: line.text) {
                out.append(SensitiveFinding(category: m.category, text: m.text, rect: line.rect(forUTF16Range: m.range)))
            }
        }
        return out
    }
}

// MARK: - Auto redact

/// Modes for manual editing. Only solid fill is redaction; the other modes are obfuscation.
public enum RedactionStyle: String, Codable, CaseIterable, Sendable {
    case solid, blur, pixelate

    public var displayName: String {
        switch self {
        case .solid: return "Solid redaction"
        case .blur: return "Blur (obfuscation)"
        case .pixelate: return "Pixelate (obfuscation)"
        }
    }

    public var isObfuscation: Bool { self != .solid }
}

public struct AutoRedactOptions: Sendable {
    public var detector: SensitiveInfoOptions
    public var color: RGBAColor
    /// Extra margin around each box, pixels.
    public var padding: Double
    public var recognizer: TextRecognizer.Options

    public init(detector: SensitiveInfoOptions = .default,
                color: RGBAColor = .black, padding: Double = 3, recognizer: TextRecognizer.Options = .init()) {
        self.detector = detector; self.color = color; self.padding = padding
        self.recognizer = recognizer
    }
}

public enum AutoRedact {
    /// OCR + detection; returns redaction annotations in image space. OCR failures yield an empty list.
    public static func run(_ image: CGImage, options: AutoRedactOptions = AutoRedactOptions()) async -> [Annotation] {
        guard let lines = try? await TextRecognizer.recognize(in: image, options: options.recognizer) else { return [] }
        return annotations(for: lines, options: options, imageSize: image.pixelSize)
    }

    /// Creates fully opaque solid redactions, never source-derived obfuscation.
    public static func annotations(for lines: [RecognizedLine], options: AutoRedactOptions = AutoRedactOptions(),
                                   imageSize: CGSize? = nil) -> [Annotation] {
        let findings = SensitiveInfoDetector(options: options.detector).findings(in: lines)
        let bounds = imageSize.map { CGRect(origin: .zero, size: $0) }
        return findings.enumerated().compactMap { index, f in
            var rect = f.rect.insetBy(dx: -options.padding, dy: -options.padding)
            if let bounds { rect = rect.intersection(bounds) }
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
            return Annotation(z: index, kind: .redact(rect), style: AnnotationStyle(color: options.color))
        }
    }
}
