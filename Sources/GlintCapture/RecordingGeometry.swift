import CoreGraphics

/// How a selected region is captured: the display-local source rectangle (points, snapped to whole pixels)
/// and the size of the encoded video in pixels. All H.264 dimensions are even.
struct RecordingGeometry: Equatable {
    /// Region in display-local points (SCK `sourceRect` space), trimmed so it covers an even number of pixels.
    let sourceRect: CGRect
    /// Pixels per point of the source display.
    let scale: CGFloat
    /// Pixels covered by `sourceRect`.
    let sourceWidth: Int
    let sourceHeight: Int
    /// Encoded video size; equals the source size unless the region exceeds the encoder limits.
    let outputWidth: Int
    let outputHeight: Int
    /// Top-left of the display in global CG coordinates, to map global pointer positions into the video.
    let displayOrigin: CGPoint

    /// Largest frame the hardware H.264 encoder accepts (level 5.1: 36 864 macroblocks).
    static let maximumPixelArea = 4096 * 2304
    static let maximumPixelSide = 8192

    var outputSize: CGSize { CGSize(width: outputWidth, height: outputHeight) }
    var isDownscaled: Bool { outputWidth != sourceWidth || outputHeight != sourceHeight }

    /// `region` and `display` are in global CG coordinates. Returns nil when the region misses the display.
    init?(region: CGRect, display: CGRect, scale: CGFloat) {
        guard scale > 0, display.width > 0, display.height > 0 else { return nil }
        let clipped = region.intersection(display)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        let local = CaptureGeometry.displayLocal(clipped, display: display, scale: scale)
        let width = Self.even(Int((local.width * scale).rounded()))
        let height = Self.even(Int((local.height * scale).rounded()))
        guard width >= 2, height >= 2 else { return nil }
        self.scale = scale
        displayOrigin = display.origin
        sourceWidth = width
        sourceHeight = height
        sourceRect = CGRect(x: local.minX, y: local.minY, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let (outW, outH) = Self.fitted(width: width, height: height)
        outputWidth = outW
        outputHeight = outH
    }

    /// Video pixels per screen point (the display scale, reduced when the output is downscaled).
    var videoPixelsPerPoint: CGFloat { scale * CGFloat(outputWidth) / CGFloat(sourceWidth) }

    /// Where a global CG point (top-left origin) lands in the encoded video, in pixels (top-left origin).
    /// Points outside the region map outside `0..<outputSize`.
    func videoPoint(forGlobal point: CGPoint) -> CGPoint {
        let sx = scale * CGFloat(outputWidth) / CGFloat(sourceWidth)
        let sy = scale * CGFloat(outputHeight) / CGFloat(sourceHeight)
        return CGPoint(x: (point.x - displayOrigin.x - sourceRect.minX) * sx,
                       y: (point.y - displayOrigin.y - sourceRect.minY) * sy)
    }

    /// Rounds down to an even number: H.264 4:2:0 needs whole chroma samples.
    static func even(_ value: Int) -> Int { value - value % 2 }

    /// Scales `width` × `height` down (never up) until it fits the encoder limits, keeping both sides even.
    static func fitted(width: Int, height: Int) -> (Int, Int) {
        let area = Double(width) * Double(height)
        let factor = min(1, (Double(maximumPixelArea) / area).squareRoot(),
                         Double(maximumPixelSide) / Double(max(width, height)))
        guard factor < 1 else { return (width, height) }
        let w = max(even(Int((Double(width) * factor).rounded(.down))), 2)
        let h = max(even(Int((Double(height) * factor).rounded(.down))), 2)
        return (w, h)
    }
}

/// The parts of a region a drag can grab, in CG coordinates (y grows downwards, so `top` is `minY`).
enum RegionHandle: CaseIterable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight, move

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}

/// Pure geometry behind the adjustable recording frame. Results are whole points inside `bounds`.
enum RegionAdjustment {
    static let minimumSide: CGFloat = 64
    static let handleTolerance: CGFloat = 10

    /// `rect` grown to the minimum size, shifted into `bounds` and snapped to whole points.
    static func clamped(_ rect: CGRect, to bounds: CGRect, minimumSide: CGFloat = minimumSide) -> CGRect {
        let width = min(max(rect.width.rounded(), minimumSide), bounds.width.rounded(.down))
        let height = min(max(rect.height.rounded(), minimumSide), bounds.height.rounded(.down))
        let x = min(max(rect.minX.rounded(), bounds.minX.rounded(.up)), bounds.maxX.rounded(.down) - width)
        let y = min(max(rect.minY.rounded(), bounds.minY.rounded(.up)), bounds.maxY.rounded(.down) - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Which handle the point grabs, or nil when it is further than `tolerance` outside the region.
    static func handle(at point: CGPoint, in rect: CGRect, tolerance: CGFloat = handleTolerance) -> RegionHandle? {
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
        let left = point.x < rect.minX + tolerance, right = point.x > rect.maxX - tolerance
        let top = point.y < rect.minY + tolerance, bottom = point.y > rect.maxY - tolerance
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return .move
        }
    }

    /// `start` after dragging `handle` by `delta`: a move keeps the size, a resize keeps the opposite edges fixed.
    static func adjusted(_ start: CGRect, handle: RegionHandle, by delta: CGSize, bounds: CGRect,
                         minimumSide: CGFloat = minimumSide) -> CGRect {
        let start = clamped(start, to: bounds, minimumSide: minimumSide)
        if handle == .move {
            let x = min(max((start.minX + delta.width).rounded(), bounds.minX), bounds.maxX - start.width)
            let y = min(max((start.minY + delta.height).rounded(), bounds.minY), bounds.maxY - start.height)
            return CGRect(x: x, y: y, width: start.width, height: start.height)
        }
        var left = start.minX, right = start.maxX, top = start.minY, bottom = start.maxY
        if handle.movesLeft {
            left = min(max((left + delta.width).rounded(), bounds.minX), right - minimumSide)
        }
        if handle.movesRight {
            right = max(min((right + delta.width).rounded(), bounds.maxX), left + minimumSide)
        }
        if handle.movesTop {
            top = min(max((top + delta.height).rounded(), bounds.minY), bottom - minimumSide)
        }
        if handle.movesBottom {
            bottom = max(min((bottom + delta.height).rounded(), bounds.maxY), top + minimumSide)
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// A keyboard or VoiceOver adjustment of the recording frame, the alternative to dragging it.
enum RegionNudge: CaseIterable {
    case moveLeft, moveRight, moveUp, moveDown, narrower, wider, shorter, taller

    /// Name of the VoiceOver action.
    var title: String {
        switch self {
        case .moveLeft: return "Move left"
        case .moveRight: return "Move right"
        case .moveUp: return "Move up"
        case .moveDown: return "Move down"
        case .narrower: return "Make narrower"
        case .wider: return "Make wider"
        case .shorter: return "Make shorter"
        case .taller: return "Make taller"
        }
    }

    /// The arrow keys move the frame; with Option they resize it from the bottom right corner.
    init?(arrowKeyCode keyCode: UInt16, resize: Bool) {
        switch (keyCode, resize) {
        case (123, false): self = .moveLeft
        case (124, false): self = .moveRight
        case (126, false): self = .moveUp
        case (125, false): self = .moveDown
        case (123, true): self = .narrower
        case (124, true): self = .wider
        case (126, true): self = .shorter
        case (125, true): self = .taller
        default: return nil
        }
    }

    fileprivate var handle: RegionHandle {
        switch self {
        case .moveLeft, .moveRight, .moveUp, .moveDown: return .move
        case .narrower, .wider: return .right
        case .shorter, .taller: return .bottom
        }
    }

    fileprivate func delta(step: CGFloat) -> CGSize {
        switch self {
        case .moveLeft, .narrower: return CGSize(width: -step, height: 0)
        case .moveRight, .wider: return CGSize(width: step, height: 0)
        case .moveUp, .shorter: return CGSize(width: 0, height: -step)
        case .moveDown, .taller: return CGSize(width: 0, height: step)
        }
    }
}

extension RegionAdjustment {
    /// `rect` after one nudge of `step` points; it stays inside `bounds` and above the minimum size.
    static func nudged(_ rect: CGRect, _ nudge: RegionNudge, step: CGFloat, bounds: CGRect) -> CGRect {
        adjusted(rect, handle: nudge.handle, by: nudge.delta(step: step), bounds: bounds)
    }
}

/// Where the floating control bar and recording pill sit, in CG coordinates.
enum RecordingLayout {
    static let gap: CGFloat = 20
    static let margin: CGFloat = 8

    /// Below the region when it fits on screen, else above it, else inside it along the bottom edge.
    /// `usable` is the display's visible area (without menu bar and Dock), so the bar is always reachable.
    static func barFrame(size: CGSize, region: CGRect, usable: CGRect, gap: CGFloat = gap,
                         margin: CGFloat = margin) -> CGRect {
        let area = usable.insetBy(dx: margin, dy: margin)
        let width = min(size.width, area.width), height = min(size.height, area.height)
        let x = min(max(region.midX - width / 2, area.minX), area.maxX - width)
        let below = region.maxY + gap
        if below + height <= area.maxY { return CGRect(x: x, y: below, width: width, height: height) }
        let above = region.minY - gap - height
        if above >= area.minY { return CGRect(x: x, y: above, width: width, height: height) }
        let inside = min(max(region.maxY - gap - height, area.minY), area.maxY - height)
        return CGRect(x: x, y: inside, width: width, height: height)
    }

    /// `frame` moved the least distance needed to lie inside `usable`.
    static func keepingOnScreen(_ frame: CGRect, in usable: CGRect, margin: CGFloat = margin) -> CGRect {
        let area = usable.insetBy(dx: margin, dy: margin)
        let x = min(max(frame.minX, area.minX), max(area.maxX - frame.width, area.minX))
        let y = min(max(frame.minY, area.minY), max(area.maxY - frame.height, area.minY))
        return CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
    }
}
