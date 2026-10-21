#!/usr/bin/env swift
//
// make_icon.swift - draws the Glint app icon procedurally and builds AppIcon.icns.
//
//   swift Scripts/make_icon.swift [--keep-iconset]
//
// Outputs (the project root is found from this script's location):
//   Resources/AppIcon.icns       bundled into Glint.app by Scripts/build_app.sh
//   docs/assets/icon-1024.png    full-size render for the README
//   Resources/AppIcon.iconset/   intermediate PNGs, deleted afterwards unless --keep-iconset
//
// Only AppKit / CoreGraphics are used. The artwork is vector code that is re-run at every
// pixel size (nothing is downscaled from one bitmap), so the small sizes stay crisp.
//
// Design: a macOS squircle filled with a twilight gradient, a faceted four-point "glint"
// with a soft bloom and lens streak, and a few smaller sparkles around it.

import AppKit

// MARK: - Colour helpers

func sRGB() -> CGColorSpace {
    CGColorSpace(name: CGColorSpace.sRGB)!
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: sRGB(),
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ]
    )!
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat, alpha: CGFloat = 1) -> CGColor {
    func channel(_ hex: UInt32, _ shift: UInt32) -> CGFloat { CGFloat((hex >> shift) & 0xFF) }
    let r = channel(a, 16) + (channel(b, 16) - channel(a, 16)) * t
    let g = channel(a, 8) + (channel(b, 8) - channel(a, 8)) * t
    let bl = channel(a, 0) + (channel(b, 0) - channel(a, 0)) * t
    return CGColor(colorSpace: sRGB(), components: [r / 255, g / 255, bl / 255, alpha])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: sRGB(),
        colors: stops.map { $0.1 } as CFArray,
        locations: stops.map { $0.0 }
    )!
}

// MARK: - Shapes

/// A superellipse (exponent ~5) is a close match for the macOS icon "squircle".
func squirclePath(in rect: CGRect, exponent n: CGFloat = 5, segments: Int = 1440) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    for i in 0..<segments {
        let t = CGFloat(i) / CGFloat(segments) * 2 * .pi
        let c = cos(t)
        let s = sin(t)
        let point = CGPoint(
            x: rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
            y: rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        )
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// A four-point sparkle: long tapering arms joined at notches that sit on the diagonals.
struct Sparkle {
    let center: CGPoint
    let vertical: CGFloat    // reach of the up/down arms
    let horizontal: CGFloat  // reach of the left/right arms
    let waist: CGFloat       // notch offset along each axis (notches sit at +-waist, +-waist)

    /// Clockwise from the top tip: tip, notch, tip, notch, ...
    var vertices: [CGPoint] {
        [
            CGPoint(x: center.x, y: center.y + vertical),
            CGPoint(x: center.x + waist, y: center.y + waist),
            CGPoint(x: center.x + horizontal, y: center.y),
            CGPoint(x: center.x + waist, y: center.y - waist),
            CGPoint(x: center.x, y: center.y - vertical),
            CGPoint(x: center.x - waist, y: center.y - waist),
            CGPoint(x: center.x - horizontal, y: center.y),
            CGPoint(x: center.x - waist, y: center.y + waist),
        ]
    }

    /// The tip an edge (vertex i -> i + 1) belongs to.
    func tipIndex(forEdge i: Int) -> Int {
        i % 2 == 0 ? i : (i + 1) % 8
    }

    /// Silhouette whose edges bow in toward the arm axes, giving the classic sparkle look.
    var path: CGPath {
        let v = vertices
        let p = CGMutablePath()
        p.move(to: v[0])
        for i in 0..<8 {
            let to = v[(i + 1) % 8]
            let tip = v[tipIndex(forEdge: i)]
            let notch = i % 2 == 0 ? to : v[i]
            let along = CGPoint(x: notch.x + (tip.x - notch.x) * 0.40, y: notch.y + (tip.y - notch.y) * 0.40)
            let onAxis = abs(tip.x - center.x) < 0.001
                ? CGPoint(x: center.x, y: along.y)
                : CGPoint(x: along.x, y: center.y)
            let control = CGPoint(x: along.x + (onAxis.x - along.x) * 0.62, y: along.y + (onAxis.y - along.y) * 0.62)
            p.addQuadCurve(to: to, control: control)
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Artwork

/// Draws a single-tone sparkle (used for the small accents) with its own glow.
func drawAccentSparkle(_ ctx: CGContext, _ sparkle: Sparkle, scale s: CGFloat, glow: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: glow * s, color: color(0xFFD9F2, 0.95))
    ctx.addPath(sparkle.path)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(sparkle.path)
    ctx.clip()
    let top = sparkle.center.y + sparkle.vertical
    let bottom = sparkle.center.y - sparkle.vertical
    ctx.drawLinearGradient(
        gradient([(0, color(0xFFFFFF)), (1, color(0xE2C9FF))]),
        start: CGPoint(x: sparkle.center.x, y: top),
        end: CGPoint(x: sparkle.center.x, y: bottom),
        options: []
    )
    ctx.restoreGState()
}

/// Brightness of each facet of the hero sparkle, lit from the top left (index = edge index).
let facetLight: [CGFloat] = [0.78, 0.55, 0.22, 0.0, 0.14, 0.42, 0.82, 1.0]

func drawHeroSparkle(_ ctx: CGContext, _ star: Sparkle, scale s: CGFloat, fineDetail: Bool) {
    // Bloom: the silhouette's shadow, twice, to build a soft halo.
    for (blur, alpha) in [(150.0, 0.75), (60.0, 0.95)] as [(CGFloat, CGFloat)] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur * s, color: color(0xFFC6EE, alpha))
        ctx.addPath(star.path)
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Faceted body: eight triangles fanned from the centre, clipped to the silhouette.
    ctx.saveGState()
    ctx.addPath(star.path)
    ctx.clip()
    let v = star.vertices
    for i in 0..<8 {
        let tip = v[star.tipIndex(forEdge: i)]
        let light = facetLight[i]
        let inner = mix(0xD2C0FF, 0xFFFFFF, light)
        let outer = mix(0x9A7DF7, 0xFFF1FA, light)
        ctx.saveGState()
        ctx.move(to: star.center)
        ctx.addLine(to: v[i])
        ctx.addLine(to: v[(i + 1) % 8])
        ctx.closePath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0, inner), (1, outer)]),
            start: star.center,
            end: tip,
            options: [.drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }

    // Crisp ridges along the four arms make the facets read as cut glass.
    if fineDetail {
        ctx.setLineCap(.round)
        for tip in [v[0], v[2], v[4], v[6]] {
            ctx.setStrokeColor(color(0xFFFFFF, 0.55))
            ctx.setLineWidth(3 * s)
            ctx.move(to: star.center)
            ctx.addLine(to: tip)
            ctx.strokePath()
        }
    }
    ctx.restoreGState()

    // Hot spot at the heart of the glint.
    ctx.drawRadialGradient(
        gradient([(0, color(0xFFFFFF, 0.95)), (0.30, color(0xFFFFFF, 0.45)), (1, color(0xFFFFFF, 0))]),
        startCenter: star.center, startRadius: 0,
        endCenter: star.center, endRadius: star.vertical * 0.30,
        options: []
    )
}

func drawIcon(into ctx: CGContext, pixels: Int) {
    let s = CGFloat(pixels) / 1024  // device pixels per design unit
    let fineDetail = pixels >= 64   // streaks and stardust turn to mush below this
    let chunky = pixels <= 40       // fatter arms keep the star legible at 16 and 32 px

    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)  // Apple's 824 pt icon grid
    let shape = squirclePath(in: body)
    let hero = Sparkle(
        center: CGPoint(x: 522, y: 530),
        vertical: 338,
        horizontal: 296,
        waist: chunky ? 76 : 54
    )

    // Body, with the soft drop shadow (shadow geometry is not scaled by the CTM).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 26 * s, color: color(0x000000, 0.42))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x3A25B5))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Twilight gradient, deep indigo top left to coral bottom right.
    ctx.drawLinearGradient(
        gradient([
            (0.00, color(0x110D47)),
            (0.30, color(0x3722B3)),
            (0.58, color(0x8638DF)),
            (0.82, color(0xDF459D)),
            (1.00, color(0xFF8E6C)),
        ]),
        start: CGPoint(x: 180, y: 940),
        end: CGPoint(x: 860, y: 80),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // Pool of light behind the glint.
    ctx.drawRadialGradient(
        gradient([(0, color(0xFFFFFF, 0.42)), (0.35, color(0xD9B8FF, 0.22)), (1, color(0xB88BFF, 0))]),
        startCenter: hero.center, startRadius: 0,
        endCenter: hero.center, endRadius: 480,
        options: []
    )

    // Soft diagonal sheen from the top left, kept low-contrast so it never reads as a hard edge.
    ctx.drawLinearGradient(
        gradient([(0, color(0xFFFFFF, 0)), (0.5, color(0xFFFFFF, 0.09)), (1, color(0xFFFFFF, 0))]),
        start: CGPoint(x: 120, y: 930),
        end: CGPoint(x: 620, y: 520),
        options: []
    )

    // Depth: darken toward the bottom edge and the corners.
    ctx.drawLinearGradient(
        gradient([(0, color(0x2A0B5F, 0.26)), (1, color(0x2A0B5F, 0))]),
        start: CGPoint(x: 0, y: 100),
        end: CGPoint(x: 0, y: 400),
        options: []
    )
    ctx.drawRadialGradient(
        gradient([(0.62, color(0x2A0B5F, 0)), (1, color(0x2A0B5F, 0.22))]),
        startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 512), endRadius: 640,
        options: [.drawsAfterEndLocation]
    )

    if fineDetail {
        // Anamorphic lens streak through the glint.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: hero.center.x - 340, y: hero.center.y - 3, width: 680, height: 6))
        ctx.drawLinearGradient(
            gradient([(0, color(0xFFFFFF, 0)), (0.5, color(0xFFFFFF, 0.85)), (1, color(0xFFFFFF, 0))]),
            start: CGPoint(x: hero.center.x - 340, y: 0),
            end: CGPoint(x: hero.center.x + 340, y: 0),
            options: []
        )
        ctx.restoreGState()
    }

    drawHeroSparkle(ctx, hero, scale: s, fineDetail: fineDetail)

    if fineDetail {
        drawAccentSparkle(ctx, Sparkle(center: CGPoint(x: 258, y: 708), vertical: 80, horizontal: 66, waist: 12), scale: s, glow: 46)
        drawAccentSparkle(ctx, Sparkle(center: CGPoint(x: 800, y: 300), vertical: 58, horizontal: 48, waist: 9), scale: s, glow: 34)
        drawAccentSparkle(ctx, Sparkle(center: CGPoint(x: 322, y: 352), vertical: 30, horizontal: 25, waist: 5), scale: s, glow: 22)
        for (x, y, r) in [(738, 790, 8), (196, 506, 6), (846, 566, 5), (668, 238, 5)] as [(CGFloat, CGFloat, CGFloat)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 16 * s, color: color(0xFFD9F2, 0.9))
            ctx.setFillColor(color(0xFFFFFF, 0.92))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            ctx.restoreGState()
        }
    }

    // Rim light: bright along the top edge, dark along the bottom.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(8)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([
            (0.00, color(0xFFFFFF, 0.60)),
            (0.30, color(0xFFFFFF, 0.18)),
            (0.65, color(0xFFFFFF, 0.04)),
            (1.00, color(0x1A0840, 0.30)),
        ]),
        start: CGPoint(x: 0, y: 924),
        end: CGPoint(x: 0, y: 100),
        options: []
    )
    ctx.restoreGState()

    ctx.restoreGState()  // squircle clip
    ctx.restoreGState()  // scale
}

// MARK: - Output

func renderPNG(pixels: Int) -> Data {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create a \(pixels)px bitmap context")
    }
    drawIcon(into: ctx, pixels: pixels)
    guard
        let image = ctx.makeImage(),
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
        fatalError("Could not encode the \(pixels)px PNG")
    }
    return png
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make_icon: \(message)\n".utf8))
    exit(1)
}

func main() {
    let keepIconset = CommandLine.arguments.dropFirst().contains("--keep-iconset")
    let script = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let root = script.deletingLastPathComponent().deletingLastPathComponent()
    let fm = FileManager.default

    let iconset = root.appendingPathComponent("Resources/AppIcon.iconset", isDirectory: true)
    let icns = root.appendingPathComponent("Resources/AppIcon.icns")
    let readme = root.appendingPathComponent("docs/assets/icon-1024.png")

    // Pixel size for every file iconutil expects in an .iconset.
    let files: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]

    do {
        try? fm.removeItem(at: iconset)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        try fm.createDirectory(at: readme.deletingLastPathComponent(), withIntermediateDirectories: true)

        var rendered: [Int: Data] = [:]
        for (name, pixels) in files {
            let png = rendered[pixels] ?? renderPNG(pixels: pixels)
            rendered[pixels] = png
            try png.write(to: iconset.appendingPathComponent(name))
        }
        try (rendered[1024] ?? renderPNG(pixels: 1024)).write(to: readme)
    } catch {
        fail("could not write the iconset: \(error)")
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
    do {
        try iconutil.run()
    } catch {
        fail("could not run iconutil: \(error)")
    }
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        fail("iconutil failed with status \(iconutil.terminationStatus)")
    }

    if !keepIconset {
        try? fm.removeItem(at: iconset)
    }
    print("wrote \(icns.path)")
    print("wrote \(readme.path)")
}

main()
