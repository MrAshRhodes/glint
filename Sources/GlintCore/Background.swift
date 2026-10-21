import CoreGraphics
import Foundation

public struct GradientStop: Codable, Equatable, Hashable, Sendable {
    public var location: Double
    public var color: RGBAColor
    public init(_ location: Double, _ color: RGBAColor) { self.location = location; self.color = color }
}

/// Linear gradient. `angle` follows CSS: 0° = towards the top, 90° = towards the right, clockwise.
public struct LinearGradient: Codable, Equatable, Hashable, Sendable {
    public var angle: Double
    public var stops: [GradientStop]
    public init(angle: Double, stops: [GradientStop]) { self.angle = angle; self.stops = stops }
    public init(angle: Double, hexes: [String]) {
        let n = max(hexes.count - 1, 1)
        self.init(angle: angle, stops: hexes.enumerated().map {
            GradientStop(Double($0.offset) / Double(n), RGBAColor(hex: $0.element) ?? .black)
        })
    }
}

/// Soft radial colour blob; `x`/`y` are 0…1 fractions of the canvas (y from the top), `radius` a fraction of the longer side.
public struct MeshPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var radius: Double
    public var color: RGBAColor
    public init(x: Double, y: Double, radius: Double, color: RGBAColor) {
        self.x = x; self.y = y; self.radius = radius; self.color = color
    }
}

public struct MeshGradient: Codable, Equatable, Hashable, Sendable {
    public var base: RGBAColor
    public var points: [MeshPoint]
    public init(base: RGBAColor, points: [MeshPoint]) { self.base = base; self.points = points }
}

public enum PatternKind: String, Codable, CaseIterable, Sendable {
    case dots, grid, stripes, checker, noise
}

public struct PatternStyle: Codable, Equatable, Hashable, Sendable {
    public var kind: PatternKind
    public var foreground: RGBAColor
    public var background: RGBAColor
    /// Cell size in points.
    public var scale: Double
    /// Rotation for stripes, degrees.
    public var angle: Double
    public var seed: UInt64
    public init(kind: PatternKind, foreground: RGBAColor, background: RGBAColor, scale: Double = 16,
                angle: Double = 45, seed: UInt64 = 1) {
        self.kind = kind; self.foreground = foreground; self.background = background
        self.scale = scale; self.angle = angle; self.seed = seed
    }
}

public enum ImageFit: String, Codable, Sendable { case fill, fit, stretch }

public enum BackgroundStyle: Codable, Equatable, Hashable, Sendable {
    case solid(RGBAColor)
    case linear(LinearGradient)
    case mesh(MeshGradient)
    case pattern(PatternStyle)
    case image(path: String, fit: ImageFit)
    case transparent
}

public struct BackgroundPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var style: BackgroundStyle
}

public enum BackgroundCatalog {
    public static let defaultID = "violet"

    private static func g(_ id: String, _ name: String, _ angle: Double, _ hexes: [String]) -> BackgroundPreset {
        BackgroundPreset(id: id, name: name, category: "Gradients",
                         style: .linear(LinearGradient(angle: angle, hexes: hexes)))
    }

    private static func m(_ id: String, _ name: String, base: String, _ pts: [(Double, Double, Double, String)]) -> BackgroundPreset {
        BackgroundPreset(id: id, name: name, category: "Mesh", style: .mesh(MeshGradient(
            base: RGBAColor(hex: base) ?? .black,
            points: pts.map { MeshPoint(x: $0.0, y: $0.1, radius: $0.2, color: RGBAColor(hex: $0.3) ?? .white) })))
    }

    public static let all: [BackgroundPreset] = [
        g("violet", "Violet", 135, ["#7F5AF0", "#2CB1F6"]),
        g("cool", "Cool", 160, ["#1FA2FF", "#12D8FA", "#A6FFCB"]),
        g("beach", "Beach", 120, ["#FFE29F", "#FFA99F", "#FF719A"]),
        g("rose", "Rose", 45, ["#FF9A9E", "#FAD0C4"]),
        g("love", "Love", 90, ["#F857A6", "#FF5858"]),
        g("flower", "Flower", 135, ["#D4A5FF", "#FFC3E1", "#FFE9B8"]),
        g("sky", "Sky", 180, ["#56CCF2", "#B8E6FF"]),
        g("sunset", "Sunset", 160, ["#FF512F", "#F09819"]),
        g("twilight", "Twilight", 150, ["#2E1A47", "#6A3093", "#FF7E5F"]),
        g("ocean", "Ocean Deep", 200, ["#0F2027", "#203A43", "#2C5364"]),
        g("mint", "Mint", 135, ["#00B09B", "#96C93D"]),
        g("peach", "Peach", 135, ["#FFECD2", "#FCB69F"]),
        g("lavender", "Lavender", 90, ["#C471F5", "#FA71CD"]),
        g("citrus", "Citrus", 100, ["#F7971E", "#FFD200"]),
        g("aurora", "Aurora", 140, ["#00C9FF", "#92FE9D"]),
        g("ember", "Ember", 20, ["#42275A", "#734B6D"]),
        g("graphite", "Graphite", 160, ["#232526", "#414345"]),
        g("midnight", "Midnight", 170, ["#0F0C29", "#302B63", "#24243E"]),
        g("candy", "Candy", 60, ["#FF6CAB", "#7366FF"]),
        g("forest", "Forest", 135, ["#134E5E", "#71B280"]),
        m("mesh-nebula", "Nebula", base: "#1B1034",
          [(0.15, 0.2, 0.7, "#7B2FF7"), (0.85, 0.15, 0.6, "#F107A3"), (0.5, 0.95, 0.8, "#00C6FB")]),
        m("mesh-citrus-pop", "Citrus Pop", base: "#FFE259",
          [(0.1, 0.9, 0.7, "#FF6B6B"), (0.9, 0.2, 0.6, "#FFA751"), (0.6, 0.6, 0.5, "#FFF3B0")]),
        m("mesh-lagoon", "Lagoon", base: "#0B3954",
          [(0.2, 0.3, 0.7, "#08BDBD"), (0.85, 0.8, 0.7, "#ABFF4F"), (0.8, 0.1, 0.5, "#3A86FF")]),
        m("mesh-blush", "Blush", base: "#FFD6E8",
          [(0.1, 0.1, 0.6, "#FFB3D1"), (0.9, 0.9, 0.7, "#C5B3FF"), (0.9, 0.1, 0.5, "#FFF1B8")]),
        BackgroundPreset(id: "solid-white", name: "White", category: "Solid", style: .solid(.white)),
        BackgroundPreset(id: "solid-black", name: "Black", category: "Solid", style: .solid(.black)),
        BackgroundPreset(id: "solid-slate", name: "Slate", category: "Solid",
                         style: .solid(RGBAColor(hex: "#1E293B") ?? .black)),
        BackgroundPreset(id: "pattern-dots", name: "Dots", category: "Pattern", style: .pattern(
            PatternStyle(kind: .dots, foreground: RGBAColor(hex: "#FFFFFF33") ?? .white,
                         background: RGBAColor(hex: "#3B82F6") ?? .black, scale: 18))),
        BackgroundPreset(id: "pattern-grid", name: "Blueprint", category: "Pattern", style: .pattern(
            PatternStyle(kind: .grid, foreground: RGBAColor(hex: "#FFFFFF40") ?? .white,
                         background: RGBAColor(hex: "#1D4ED8") ?? .black, scale: 24))),
        BackgroundPreset(id: "pattern-stripes", name: "Stripes", category: "Pattern", style: .pattern(
            PatternStyle(kind: .stripes, foreground: RGBAColor(hex: "#FFFFFF22") ?? .white,
                         background: RGBAColor(hex: "#DB2777") ?? .black, scale: 20, angle: 45))),
        BackgroundPreset(id: "pattern-noise", name: "Grain", category: "Pattern", style: .pattern(
            PatternStyle(kind: .noise, foreground: .white, background: RGBAColor(hex: "#374151") ?? .black,
                         scale: 2))),
        BackgroundPreset(id: "transparent", name: "None", category: "Solid", style: .transparent),
    ]

    public static func preset(id: String) -> BackgroundPreset? { all.first { $0.id == id } }
    public static var defaultStyle: BackgroundStyle { preset(id: defaultID)?.style ?? .solid(.white) }
}

/// Fills a context (bottom-left origin, pixel units) with a `BackgroundStyle`.
enum BackgroundRenderer {
    static func fill(_ style: BackgroundStyle, in ctx: CGContext, size: CGSize, scale: CGFloat, image: CGImage?) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch style {
        case .transparent:
            break
        case .solid(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(rect)
        case .linear(let lg):
            drawLinear(lg, ctx: ctx, rect: rect)
        case .mesh(let mesh):
            ctx.setFillColor(mesh.base.cgColor)
            ctx.fill(rect)
            let longest = max(size.width, size.height)
            for p in mesh.points {
                let center = CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
                let c = p.color
                let colors = [c.cgColor, c.with(alpha: 0).cgColor] as CFArray
                guard let grad = CGGradient(colorsSpace: ColorSpaces.sRGB, colors: colors, locations: [0, 1]) else { continue }
                ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: CGFloat(p.radius) * longest, options: [])
            }
        case .pattern(let p):
            drawPattern(p, ctx: ctx, rect: rect, scale: scale)
        case .image(_, let fit):
            guard let image else {
                ctx.setFillColor(RGBAColor(hex: "#808080")!.cgColor)
                ctx.fill(rect)
                return
            }
            drawImage(image, fit: fit, ctx: ctx, rect: rect)
        }
    }

    private static func drawLinear(_ lg: LinearGradient, ctx: CGContext, rect: CGRect) {
        let stops = lg.stops.sorted { $0.location < $1.location }
        guard !stops.isEmpty else { return }
        let colors = stops.map { $0.color.cgColor } as CFArray
        let locs = stops.map { CGFloat($0.location) }
        guard let grad = CGGradient(colorsSpace: ColorSpaces.sRGB, colors: colors, locations: locs) else { return }
        // CSS gradient line: length = |w·sinθ| + |h·cosθ|, centred on the rect.
        let theta = lg.angle * .pi / 180
        let dx = CGFloat(sin(theta)), dy = CGFloat(cos(theta)) // dy up in bottom-left space
        let len = abs(rect.width * dx) + abs(rect.height * dy)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let start = CGPoint(x: c.x - dx * len / 2, y: c.y - dy * len / 2)
        let end = CGPoint(x: c.x + dx * len / 2, y: c.y + dy * len / 2)
        ctx.drawLinearGradient(grad, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func drawPattern(_ p: PatternStyle, ctx: CGContext, rect: CGRect, scale: CGFloat) {
        ctx.setFillColor(p.background.cgColor)
        ctx.fill(rect)
        let cell = max(2, CGFloat(p.scale) * scale)
        ctx.setFillColor(p.foreground.cgColor)
        ctx.setStrokeColor(p.foreground.cgColor)
        switch p.kind {
        case .dots:
            let r = cell * 0.12
            var y = cell / 2
            while y < rect.height + cell {
                var x = cell / 2
                while x < rect.width + cell {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                    x += cell
                }
                y += cell
            }
        case .grid:
            ctx.setLineWidth(max(1, scale))
            var x: CGFloat = 0
            while x <= rect.width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: rect.height)); x += cell }
            var y: CGFloat = 0
            while y <= rect.height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: rect.width, y: y)); y += cell }
            ctx.strokePath()
        case .stripes:
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: CGFloat(p.angle) * .pi / 180)
            let diag = hypot(rect.width, rect.height)
            var x = -diag
            while x < diag { ctx.fill(CGRect(x: x, y: -diag, width: cell / 2, height: 2 * diag)); x += cell }
            ctx.restoreGState()
        case .checker:
            var row = 0
            var y: CGFloat = 0
            while y < rect.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < rect.width { ctx.fill(CGRect(x: x, y: y, width: cell, height: cell)); x += 2 * cell }
                y += cell; row += 1
            }
        case .noise:
            var rng = SplitMix64(seed: p.seed)
            let grain = max(1, Int(cell))
            var y = 0
            while y < Int(rect.height) {
                var x = 0
                while x < Int(rect.width) {
                    let v = Double(rng.next() % 1000) / 1000
                    ctx.setFillColor(p.foreground.with(alpha: p.foreground.a * v * 0.25).cgColor)
                    ctx.fill(CGRect(x: x, y: y, width: grain, height: grain))
                    x += grain
                }
                y += grain
            }
        }
    }

    private static func drawImage(_ image: CGImage, fit: ImageFit, ctx: CGContext, rect: CGRect) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        var dest = rect
        switch fit {
        case .stretch: break
        case .fill, .fit:
            let s = fit == .fill ? max(rect.width / iw, rect.height / ih) : min(rect.width / iw, rect.height / ih)
            dest = CGRect(x: rect.midX - iw * s / 2, y: rect.midY - ih * s / 2, width: iw * s, height: ih * s)
            if fit == .fit {
                ctx.setFillColor(RGBAColor.black.cgColor)
                ctx.fill(rect)
            }
        }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: dest)
        ctx.restoreGState()
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
