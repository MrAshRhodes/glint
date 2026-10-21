// Draws the fictional "raw capture" images used on the project website.
// Usage: swift Scripts/make_site_assets.swift OUT_DIR
// Everything here is drawn from scratch so the site ships only original artwork.
import AppKit

let scale: CGFloat = 2
let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "site-assets-src")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func hex(_ s: String, _ a: CGFloat = 1) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func render(_ name: String, width: CGFloat, height: CGFloat, _ draw: (CGRect) -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // Flip so drawing code can think top-down.
    ctx.cgContext.translateBy(x: 0, y: height)
    ctx.cgContext.scaleBy(x: 1, y: -1)
    draw(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    let url = outDir.appendingPathComponent("\(name).png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    print(url.path)
}

func text(_ s: String, at p: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular,
          mono: Bool = false) {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    NSGraphicsContext.saveGraphicsState()
    // Undo the flip locally so glyphs are upright.
    let t = NSAffineTransform()
    t.translateX(by: p.x, yBy: p.y + size)
    t.scaleX(by: 1, yBy: -1)
    t.concat()
    attr.draw(at: .zero)
    NSGraphicsContext.restoreGraphicsState()
}

func width(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) -> CGFloat {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    return (s as NSString).size(withAttributes: [.font: font]).width
}

func fill(_ r: CGRect, _ c: NSColor, radius: CGFloat = 0) {
    c.setFill()
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
}

// 1. A terminal session showing Glint's own CLI.
try render("terminal", width: 760, height: 430) { r in
    fill(r, hex("#15161B"))
    fill(CGRect(x: 0, y: 0, width: r.width, height: 38), hex("#1E2027"))
    for (i, c) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
        fill(CGRect(x: 16 + CGFloat(i) * 20, y: 13, width: 12, height: 12), hex(c), radius: 6)
    }
    let title = "zsh — ~/Desktop"
    text(title, at: CGPoint(x: (r.width - width(title, size: 13, weight: .medium)) / 2, y: 11), size: 13,
         color: hex("#8B8F9C"), weight: .medium)

    typealias Seg = (String, String)
    let lines: [[Seg]] = [
        [("~ ", "#7DD3A8"), ("❯ ", "#E8FF6A"), ("brew install --cask MrAshRhodes/tap/glint", "#F2F2EE")],
        [("==> ", "#6AA9FF"), ("Installing Cask glint", "#C9CBD3")],
        [("🍺  ", "#F2F2EE"), ("glint was successfully installed!", "#C9CBD3")],
        [],
        [("~ ", "#7DD3A8"), ("❯ ", "#E8FF6A"), ("glint=/Applications/Glint.app/Contents/MacOS/Glint", "#F2F2EE")],
        [("~ ", "#7DD3A8"), ("❯ ", "#E8FF6A"), ("$glint ", "#F2F2EE"), ("--list-presets", "#F5B86A")],
        [("Default", "#C9CBD3")], [("Clean", "#C9CBD3")], [("Social 16:9", "#C9CBD3")], [("Transparent", "#C9CBD3")],
        [],
        [("~ ", "#7DD3A8"), ("❯ ", "#E8FF6A"), ("$glint ", "#F2F2EE"), ("--render ", "#F5B86A"),
         ("shot.png out.png ", "#F2F2EE"), ("--preset ", "#F5B86A"), ("\"Social 16:9\" ", "#9EE6C4"),
         ("--scale ", "#F5B86A"), ("2", "#F2F2EE")],
        [("/Users/you/Desktop/out.png (1984x1116)", "#C9CBD3")],
        [("~ ", "#7DD3A8"), ("❯ ", "#E8FF6A"), ("▍", "#E8FF6A")],
    ]
    var y: CGFloat = 58
    for line in lines {
        var x: CGFloat = 22
        for (s, c) in line {
            text(s, at: CGPoint(x: x, y: y), size: 14, color: hex(c), mono: true)
            x += width(s, size: 14, mono: true)
        }
        y += line.isEmpty ? 10 : 24
    }
}

// 2. A light analytics card.
try render("dashboard", width: 640, height: 400) { r in
    fill(r, hex("#FBFAF7"))
    text("Weekly sign-ups", at: CGPoint(x: 32, y: 30), size: 15, color: hex("#6B6A66"), weight: .medium)
    text("12,480", at: CGPoint(x: 32, y: 56), size: 46, color: hex("#17171A"), weight: .bold)
    let pill = "▲ 18.2%"
    let pw = width(pill, size: 14, weight: .semibold) + 22
    fill(CGRect(x: 202, y: 74, width: pw, height: 28), hex("#DDF6E7"), radius: 14)
    text(pill, at: CGPoint(x: 213, y: 79), size: 14, color: hex("#13804A"), weight: .semibold)
    text("vs. last week", at: CGPoint(x: 210 + pw, y: 80), size: 14, color: hex("#8D8B86"))

    let values: [CGFloat] = [0.42, 0.55, 0.48, 0.71, 0.64, 0.88, 0.79]
    let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    let base: CGFloat = 340, maxH: CGFloat = 180, bw: CGFloat = 52, gap: CGFloat = 30
    for g in 0...3 {
        let gy = base - maxH * CGFloat(g) / 3
        fill(CGRect(x: 32, y: gy, width: r.width - 64, height: 1), hex("#ECEAE4"))
    }
    for (i, v) in values.enumerated() {
        let x = 44 + CGFloat(i) * (bw + gap)
        let h = maxH * v
        fill(CGRect(x: x, y: base - h, width: bw, height: h), hex(i == 5 ? "#17171A" : "#D9D6CD"), radius: 8)
        let d = days[i]
        text(d, at: CGPoint(x: x + (bw - width(d, size: 13)) / 2, y: base + 12), size: 13, color: hex("#8D8B86"))
    }
    fill(CGRect(x: 44 + 5 * (bw + gap) - 14, y: base - maxH * values[5] - 40, width: 80, height: 28), hex("#17171A"), radius: 8)
    text("2,214", at: CGPoint(x: 44 + 5 * (bw + gap) + 4, y: base - maxH * values[5] - 34), size: 14,
         color: .white, weight: .semibold)
}
