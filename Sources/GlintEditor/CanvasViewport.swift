import CoreGraphics

/// How the image fits the editor canvas. Fit shows all of it; Fit Width and 100% can be larger than the window and
/// scroll, so a tall scrolling capture can be annotated at a readable size.
enum CanvasZoom: String, CaseIterable, Identifiable {
    case fit, fitWidth, actualSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fitWidth: return "Fit Width"
        case .actualSize: return "100%"
        }
    }

    /// The key that selects it together with Command, as in Preview.
    var shortcutKey: Character {
        switch self {
        case .fit: return "9"
        case .fitWidth: return "8"
        case .actualSize: return "0"
        }
    }

    init?(shortcutKey: String) {
        guard let zoom = Self.allCases.first(where: { String($0.shortcutKey) == shortcutKey }) else { return nil }
        self = zoom
    }

    /// Images much taller than wide, like a scrolling capture, open at Fit Width so their text is readable.
    static func initial(for imageSize: CGSize) -> CanvasZoom {
        imageSize.width > 0 && imageSize.height > imageSize.width * 3 ? .fitWidth : .fit
    }
}

/// Where a zoomed canvas sits in the editor and how far it can scroll. Fit is laid out by `CanvasView` itself.
enum CanvasViewport {
    /// Largest magnification, in view points per canvas pixel, matching Fit's limit for small images.
    static let maximumScale: CGFloat = 2

    /// Size on screen, in view points, of a canvas `canvasPixels` large at full resolution. `pointsPerPixel` is the
    /// 100% scale (one image point per view point).
    static func displaySize(_ zoom: CanvasZoom, canvasPixels: CGSize, available: CGSize,
                            pointsPerPixel: CGFloat) -> CGSize {
        guard canvasPixels.width > 0, canvasPixels.height > 0 else { return .zero }
        let scale: CGFloat
        switch zoom {
        case .fit: scale = min(available.width / canvasPixels.width, available.height / canvasPixels.height)
        case .fitWidth: scale = available.width / canvasPixels.width
        case .actualSize: scale = pointsPerPixel
        }
        let clamped = min(max(scale, 0.01), maximumScale)
        return CGSize(width: canvasPixels.width * clamped, height: canvasPixels.height * clamped)
    }

    /// How far content of `size` can scroll inside `area`: zero along an axis where it fits.
    static func maximumOffset(content size: CGSize, in area: CGRect) -> CGPoint {
        CGPoint(x: max(size.width - area.width, 0), y: max(size.height - area.height, 0))
    }

    static func clamped(_ offset: CGPoint, content size: CGSize, in area: CGRect) -> CGPoint {
        let limit = maximumOffset(content: size, in: area)
        return CGPoint(x: min(max(offset.x, 0), limit.x), y: min(max(offset.y, 0), limit.y))
    }

    /// The content's frame (flipped, top-left origin): centred along an axis where it fits, otherwise scrolled by
    /// `offset` from its leading or top edge.
    static func frame(content size: CGSize, in area: CGRect, offset: CGPoint) -> CGRect {
        let offset = clamped(offset, content: size, in: area)
        let x = size.width <= area.width ? area.midX - size.width / 2 : area.minX - offset.x
        let y = size.height <= area.height ? area.midY - size.height / 2 : area.minY - offset.y
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
