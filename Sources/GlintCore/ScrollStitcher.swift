import Accelerate
import CoreGraphics
import Foundation

/// How tall a scrolling capture may grow. A stitched image is a single bitmap that the editor, the renderer and
/// OCR all hold in memory, so both the height and the total pixel count are capped.
public struct ScrollStitchLimits: Equatable, Sendable {
    /// Longest side in pixels; matches the renderer's `Compositor.maxExpandedSide`.
    public var maxHeight: Int
    /// Largest image in pixels (64 MP).
    public var maxPixels: Int
    /// Fraction of the limit at which the user is warned that the capture is nearly full.
    public var warningFraction: Double
    /// Most bytes kept only so steps can be undone (earlier footers and rows moved into the footer). When a step
    /// would exceed it, the oldest steps can no longer be undone; what they added stays in the image.
    public var maxUndoBytes: Int

    public init(maxHeight: Int = 16_384, maxPixels: Int = 64_000_000, warningFraction: Double = 0.9,
                maxUndoBytes: Int = 16_000_000) {
        self.maxHeight = maxHeight
        self.maxPixels = maxPixels
        self.warningFraction = warningFraction
        self.maxUndoBytes = maxUndoBytes
    }

    /// The tallest image allowed for frames `width` pixels wide.
    public func maxRows(width: Int) -> Int {
        max(1, min(maxHeight, maxPixels / max(width, 1)))
    }
}

/// Why a frame was not stitched cleanly. Every warning except `noMovement` stops the capture until the user
/// decides, so a bad join is never silently kept.
public enum ScrollStitchWarning: Equatable, Sendable {
    /// The frame lined up, but these rows of the stitched image (top-left origin) differed between frames,
    /// usually because something animated. The frame was added; undo it if the join looks wrong.
    case lowConfidence(rows: Range<Int>)
    /// The content repeats (stripes, identical rows, blank space), so more than one scroll distance fits.
    case ambiguousRepeat
    /// Nothing scrolled since the last frame.
    case noMovement
    /// The content moved up rather than down.
    case scrolledBack
    /// No overlap of at least a quarter of the frame was found: scrolled too far between frames.
    case tooFast
    /// The frame is not the size of the first one.
    case sizeChanged
    /// The maximum height was reached; nothing more is added.
    case heightLimit

    /// Whether the capture should stop and ask the user what to do.
    public var pausesCapture: Bool { self != .noMovement }

    /// A short explanation for the capture controls and VoiceOver.
    public var message: String {
        switch self {
        case .lowConfidence(let rows):
            return "Part of the content changed while scrolling (rows \(rows.lowerBound + 1)–\(rows.upperBound)), "
                + "so it may not line up. Check the highlighted area."
        case .ambiguousRepeat:
            return "The content repeats, so Glint can't tell how far it scrolled. Scroll by a different amount."
        case .noMovement:
            return "Nothing has scrolled yet."
        case .scrolledBack:
            return "The content moved up. Scroll back down to continue."
        case .tooFast:
            return "Scrolled too far at once. Scroll back up a little, then scroll more slowly."
        case .sizeChanged:
            return "The captured area changed size."
        case .heightLimit:
            return "Maximum height reached. Choose Done to finish."
        }
    }
}

/// The result of adding one frame.
public struct ScrollStitchStep: Equatable, Sendable {
    /// Rows appended to the stitched image (0 when the frame was rejected).
    public let addedRows: Int
    public let warning: ScrollStitchWarning?

    public init(addedRows: Int, warning: ScrollStitchWarning?) {
        self.addedRows = addedRows
        self.warning = warning
    }
}

/// Joins frames of a region that is scrolled vertically into one tall image.
///
/// Each frame is aligned to the previous one with a normalised cross-correlation of per-row luma profiles and the
/// best candidates are confirmed with a full-width pixel comparison over at least a quarter of the frame. Rows that
/// stay identical at the same place (fixed headers, toolbars and footers) are detected on the first scroll and kept
/// once. Only the newly revealed rows are copied, so memory grows with the result, not with the number of frames.
/// A value type: all pixels stay in memory and nothing is written to disk.
public struct ScrollStitcher {
    public let limits: ScrollStitchLimits

    public private(set) var width = 0
    /// Height of every frame.
    public private(set) var frameHeight = 0
    /// Fixed rows at the top and bottom of each frame, known after the first scroll.
    public private(set) var sticky: (top: Int, bottom: Int)?
    /// True once `limits` stopped the image growing.
    public private(set) var isAtLimit = false

    private var colorSpace: CGColorSpace = ColorSpaces.sRGB
    private var body: [UInt8] = []
    private var bodyRows = 0
    private var footer: [UInt8] = []
    private var reference: [UInt8] = []
    private var steps: [Record] = []
    private var frames = 0
    /// Bytes held by `steps` for undo; kept within `limits.maxUndoBytes`.
    private(set) var undoBytes = 0

    private struct Record {
        var addedRows: Int
        /// The footer before this step, or nil when the step left it unchanged.
        var footerBefore: [UInt8]?
        /// Rows moved from the body into the footer when this step found the sticky bands.
        var trimmed: [UInt8]?

        var bytes: Int { (footerBefore?.count ?? 0) + (trimmed?.count ?? 0) }
    }

    /// Rows whose mean per-channel difference is at most this are treated as equal.
    static let rowTolerance = 2.0
    /// Minimum overlap with the previous frame, as a fraction of the scrolling band.
    static let minimumOverlap = 0.25
    /// A verified join may differ in at most this fraction of the overlap and still be offered (with a warning).
    static let maximumMismatch = 0.25
    /// Fixed bands are capped so a mostly static frame still leaves a band to align.
    static let maximumStickyFraction = 0.4

    public init(limits: ScrollStitchLimits = ScrollStitchLimits()) {
        self.limits = limits
    }

    /// Height of the stitched image so far.
    public var height: Int { bodyRows + footerRows }
    public var isEmpty: Bool { width == 0 }
    /// Whether `undoLast()` can remove a step; the first frame stays, and so do steps that
    /// `limits.maxUndoBytes` no longer leaves room to undo.
    public var canUndo: Bool { !steps.isEmpty }
    /// How many of the latest steps can still be undone.
    public var undoableSteps: Int { steps.count }
    /// Frames that contributed to the image.
    public var frameCount: Int { frames }
    /// Largest height allowed for this width.
    public var maxRows: Int { limits.maxRows(width: max(width, 1)) }
    /// 0...1 of the height limit.
    public var progress: Double { isEmpty ? 0 : min(Double(height) / Double(maxRows), 1) }
    /// Past `limits.warningFraction` of the height limit.
    public var isNearLimit: Bool { progress >= limits.warningFraction }

    private var rowBytes: Int { width * 4 }
    private var footerRows: Int { rowBytes == 0 ? 0 : footer.count / rowBytes }

    // MARK: Adding frames

    /// Adds the next frame. A frame that can't be aligned is not used; the warning says why.
    public mutating func add(_ image: CGImage) -> ScrollStitchStep {
        if isEmpty { return start(with: image) }
        guard image.width == width, image.height == frameHeight,
              let frame = Self.pixels(of: image, colorSpace: colorSpace) else {
            return ScrollStitchStep(addedRows: 0, warning: .sizeChanged)
        }
        if isAtLimit { return ScrollStitchStep(addedRows: 0, warning: .heightLimit) }
        guard let bands = sticky ?? detectSticky(reference, frame) else {
            return ScrollStitchStep(addedRows: 0, warning: .noMovement)
        }
        let band = bands.top..<(frameHeight - bands.bottom)
        switch align(reference, frame, band: band) {
        case .none:
            return ScrollStitchStep(addedRows: 0, warning: .tooFast)
        case .ambiguous:
            return ScrollStitchStep(addedRows: 0, warning: .ambiguousRepeat)
        case .offset(let shift, let mismatch):
            if shift == 0 { return ScrollStitchStep(addedRows: 0, warning: .noMovement) }
            if shift < 0 { return ScrollStitchStep(addedRows: 0, warning: .scrolledBack) }
            return append(frame, shift: shift, band: band, bands: bands, mismatch: mismatch)
        }
    }

    /// Removes the last added step and makes its predecessor the frame the next one is compared with.
    @discardableResult
    public mutating func undoLast() -> Bool {
        guard let step = steps.popLast() else { return false }
        undoBytes -= step.bytes
        frames -= 1
        body.removeLast(step.addedRows * rowBytes)
        bodyRows -= step.addedRows
        if let footerBefore = step.footerBefore { footer = footerBefore }
        if let trimmed = step.trimmed {
            body.append(contentsOf: trimmed)
            bodyRows += trimmed.count / rowBytes
            sticky = nil
        }
        isAtLimit = height >= maxRows
        reference = reconstructedReference()
        return true
    }

    private mutating func start(with image: CGImage) -> ScrollStitchStep {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? ColorSpaces.sRGB
        guard image.width > 0, image.height > 0, let frame = Self.pixels(of: image, colorSpace: space) else {
            return ScrollStitchStep(addedRows: 0, warning: .sizeChanged)
        }
        colorSpace = space
        width = image.width
        frameHeight = image.height
        reference = frame
        body = frame
        bodyRows = frameHeight
        frames = 1
        if bodyRows > maxRows {
            body.removeLast((bodyRows - maxRows) * rowBytes)
            bodyRows = maxRows
            isAtLimit = true
            return ScrollStitchStep(addedRows: bodyRows, warning: .heightLimit)
        }
        isAtLimit = bodyRows >= maxRows
        return ScrollStitchStep(addedRows: bodyRows, warning: nil)
    }

    private mutating func append(_ frame: [UInt8], shift: Int, band: Range<Int>, bands: (top: Int, bottom: Int),
                                 mismatch: Range<Int>?) -> ScrollStitchStep {
        var record = Record(addedRows: 0, footerBefore: nil, trimmed: nil)
        if sticky == nil {
            let trimmed = Array(body[(frameHeight - bands.bottom) * rowBytes..<frameHeight * rowBytes])
            body.removeLast(trimmed.count)
            bodyRows -= bands.bottom
            record.trimmed = trimmed
            sticky = bands
        }
        let bodyBefore = bodyRows
        let allowed = max(maxRows - bodyRows - bands.bottom, 0)
        let added = min(shift, allowed)
        if added == 0, record.trimmed != nil {
            // Undo the lock so the state matches the frame that is still the reference.
            body.append(contentsOf: record.trimmed ?? [])
            bodyRows += bands.bottom
            sticky = nil
        }
        guard added > 0 else {
            isAtLimit = true
            return ScrollStitchStep(addedRows: 0, warning: .heightLimit)
        }
        let first = band.upperBound - shift
        body.append(contentsOf: frame[first * rowBytes..<(first + added) * rowBytes])
        bodyRows += added
        let newFooter = frame[(frameHeight - bands.bottom) * rowBytes..<frameHeight * rowBytes]
        if !footer.elementsEqual(newFooter) {
            record.footerBefore = footer
            footer = Array(newFooter)
        }
        reference = frame
        record.addedRows = added
        steps.append(record)
        frames += 1
        undoBytes += record.bytes
        while undoBytes > limits.maxUndoBytes, !steps.isEmpty {
            undoBytes -= steps.removeFirst().bytes
        }
        isAtLimit = height >= maxRows
        if let mismatch {
            // Band row y of the new frame sits at body row (bodyBefore - bandHeight + shift + y).
            let origin = bodyBefore - band.count + shift
            return ScrollStitchStep(addedRows: added,
                                    warning: .lowConfidence(
                                        rows: (origin + mismatch.lowerBound)..<(origin + mismatch.upperBound)))
        }
        return ScrollStitchStep(addedRows: added, warning: added < shift ? .heightLimit : nil)
    }

    /// The last accepted frame rebuilt from the stitched rows: the fixed header from the top of the image, the
    /// scrolling band from the end of the body and the footer kept with it.
    private func reconstructedReference() -> [UInt8] {
        guard let sticky else { return Array(body.prefix(frameHeight * rowBytes)) }
        let bandRows = frameHeight - sticky.top - sticky.bottom
        var frame = Array(body[0..<sticky.top * rowBytes])
        frame.append(contentsOf: body[(bodyRows - bandRows) * rowBytes..<bodyRows * rowBytes])
        frame.append(contentsOf: footer)
        return frame
    }

    // MARK: Output

    /// The stitched image: everything added so far plus the fixed footer once at the bottom.
    public func makeImage() -> CGImage? {
        guard !isEmpty else { return nil }
        var data = Data(capacity: body.count + footer.count)
        data.append(contentsOf: body)
        data.append(contentsOf: footer)
        return Self.image(data, width: width, height: height, colorSpace: colorSpace)
    }

    /// A small nearest-neighbour preview of the whole image, at most `maxWidth` × `maxHeight` pixels.
    public func thumbnail(maxWidth: Int, maxHeight: Int) -> CGImage? {
        guard !isEmpty, maxWidth > 0, maxHeight > 0 else { return nil }
        let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height), 1)
        let tw = max(Int((Double(width) * scale).rounded()), 1), th = max(Int((Double(height) * scale).rounded()), 1)
        var data = Data(count: tw * th * 4)
        data.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            for ty in 0..<th {
                let sy = min(Int(Double(ty) / scale), height - 1)
                let source = sy < bodyRows ? body : footer
                let row = sy < bodyRows ? sy : sy - bodyRows
                source.withUnsafeBytes { src in
                    for tx in 0..<tw {
                        let sx = min(Int(Double(tx) / scale), width - 1)
                        let s = row * rowBytes + sx * 4, d = (ty * tw + tx) * 4
                        for c in 0..<4 { out[d + c] = src[s + c] }
                    }
                }
            }
        }
        return Self.image(data, width: tw, height: th, colorSpace: colorSpace)
    }

    // MARK: Alignment

    private enum Alignment: Equatable {
        case offset(Int, mismatch: Range<Int>?)
        case ambiguous
        case none
    }

    /// Fixed rows at the top and bottom, or nil when the frames are the same.
    private func detectSticky(_ previous: [UInt8], _ next: [UInt8]) -> (top: Int, bottom: Int)? {
        var top = 0
        while top < frameHeight, rowDifference(previous, top, next, top) <= Self.rowTolerance { top += 1 }
        if top == frameHeight { return nil }
        var bottom = 0
        while bottom < frameHeight - top,
              rowDifference(previous, frameHeight - 1 - bottom, next, frameHeight - 1 - bottom) <= Self.rowTolerance {
            bottom += 1
        }
        let cap = Int(Double(frameHeight) * Self.maximumStickyFraction)
        return (min(top, cap), min(bottom, cap))
    }

    /// Finds how far `next` scrolled within `band`: positive when the content moved up (the user scrolled down).
    private func align(_ previous: [UInt8], _ next: [UInt8], band: Range<Int>) -> Alignment {
        let rows = band.count
        let overlap = max(Int((Double(rows) * Self.minimumOverlap).rounded(.up)), 1)
        let maxShift = rows - overlap
        guard maxShift >= 0 else { return .none }
        let bins = min(16, width)
        let a = rowProfiles(previous, band: band, bins: bins), b = rowProfiles(next, band: band, bins: bins)
        let scores = (-maxShift...maxShift).map { ncc(a, b, shift: $0, rows: rows, bins: bins) }
        let peaks = scores.indices.filter { i in
            (i == 0 || scores[i] >= scores[i - 1]) && (i == scores.count - 1 || scores[i] >= scores[i + 1])
        }
        .sorted { scores[$0] > scores[$1] }
        .prefix(6)
        let best = peaks.first.map { scores[$0] } ?? 0
        var clean: [Int] = []
        var partial: [(shift: Int, rows: Range<Int>)] = []
        for i in peaks where scores[i] >= 0.5 {
            let shift = i - maxShift
            switch verify(previous, next, band: band, shift: shift) {
            case .some(nil): clean.append(shift)
            case .some(let rows?): partial.append((shift, rows))
            case nil: break
            }
        }
        // Two different scroll distances that both match exactly can't be told apart.
        if let first = clean.first {
            if clean.contains(where: { abs($0 - first) > 1 }) { return .ambiguous }
            return .offset(first, mismatch: nil)
        }
        if let first = partial.first {
            let rivals = peaks.filter { scores[$0] >= best * 0.9 && abs($0 - maxShift - first.shift) > 1 }
            if partial.count > 1, !rivals.isEmpty { return .ambiguous }
            return .offset(first.shift, mismatch: first.rows)
        }
        return .none
    }

    /// Mean luma of `bins` column groups for every row of `band`, row after row.
    private func rowProfiles(_ frame: [UInt8], band: Range<Int>, bins: Int) -> [Float] {
        var out = [Float](repeating: 0, count: band.count * bins)
        frame.withUnsafeBufferPointer { p in
            for (r, y) in band.enumerated() {
                let base = y * rowBytes
                for bin in 0..<bins {
                    let x0 = bin * width / bins, x1 = max((bin + 1) * width / bins, x0 + 1)
                    var sum = 0
                    for x in x0..<x1 {
                        let i = base + x * 4
                        sum += Int(p[i]) * 54 + Int(p[i + 1]) * 183 + Int(p[i + 2]) * 19
                    }
                    out[r * bins + bin] = Float(sum) / Float((x1 - x0) * 256)
                }
            }
        }
        return out
    }

    /// Normalised cross-correlation of the overlapping profiles when `next` is `shift` rows further down.
    /// Two flat (featureless) overlaps score 1 when they have the same brightness, so blank space is ambiguous.
    private func ncc(_ a: [Float], _ b: [Float], shift: Int, rows: Int, bins: Int) -> Double {
        let count = (rows - abs(shift)) * bins
        guard count > 0 else { return 0 }
        let aStart = max(shift, 0) * bins, bStart = max(-shift, 0) * bins
        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                guard let xa = pa.baseAddress?.advanced(by: aStart), let xb = pb.baseAddress?.advanced(by: bStart) else {
                    return 0
                }
                let n = vDSP_Length(count)
                var sa: Float = 0, sb: Float = 0, saa: Float = 0, sbb: Float = 0, sab: Float = 0
                vDSP_sve(xa, 1, &sa, n)
                vDSP_sve(xb, 1, &sb, n)
                vDSP_svesq(xa, 1, &saa, n)
                vDSP_svesq(xb, 1, &sbb, n)
                vDSP_dotpr(xa, 1, xb, 1, &sab, n)
                let m = Double(count)
                let va = Double(saa) - Double(sa) * Double(sa) / m, vb = Double(sbb) - Double(sb) * Double(sb) / m
                let flat = 1e-3 * m
                if va <= flat || vb <= flat {
                    return va <= flat && vb <= flat && abs(Double(sa) - Double(sb)) / m < 1 ? 1 : 0
                }
                return (Double(sab) - Double(sa) * Double(sb) / m) / (va * vb).squareRoot()
            }
        }
    }

    /// Full-width comparison at `shift`. Nil when the frames don't match; `.some(nil)` for a clean match;
    /// `.some(rows)` (band rows of `next`) when a small part differs.
    private func verify(_ previous: [UInt8], _ next: [UInt8], band: Range<Int>, shift: Int) -> Range<Int>?? {
        let overlap = band.count - abs(shift)
        guard overlap > 0 else { return nil }
        let limit = Int(Double(overlap) * Self.maximumMismatch)
        var mismatched = 0
        var first = Int.max, last = Int.min
        for y in 0..<overlap {
            let ny = y + max(-shift, 0), py = y + max(shift, 0)
            if rowDifference(previous, band.lowerBound + py, next, band.lowerBound + ny) > Self.rowTolerance {
                mismatched += 1
                first = min(first, ny)
                last = max(last, ny)
                if mismatched > limit { return nil }
            }
        }
        return .some(mismatched == 0 ? nil : first..<(last + 1))
    }

    /// Mean absolute difference per channel between row `ya` of `a` and row `yb` of `b`.
    private func rowDifference(_ a: [UInt8], _ ya: Int, _ b: [UInt8], _ yb: Int) -> Double {
        let n = rowBytes
        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                let oa = ya * n, ob = yb * n
                var sum = 0
                for i in 0..<n {
                    let d = Int(pa[oa + i]) - Int(pb[ob + i])
                    sum += d < 0 ? -d : d
                }
                return Double(sum) / Double(max(n, 1))
            }
        }
    }

    // MARK: Pixels

    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    /// RGBA8 pixels of `image` in `colorSpace`, rows top to bottom.
    static func pixels(of image: CGImage, colorSpace: CGColorSpace) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func image(_ data: Data, width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
