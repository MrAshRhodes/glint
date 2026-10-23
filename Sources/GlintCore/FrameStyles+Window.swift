import CoreGraphics
import CoreText
import Foundation

// Code editor, terminal and phone frames.
extension FrameRenderer {
    static let ideMetrics = FrameMetrics(insets: FrameInsets(top: 64, bottom: 22))
    static let terminalMetrics = FrameMetrics(insets: FrameInsets(top: 28, left: 2, bottom: 2, right: 2))
    static let phoneMetrics = FrameMetrics(insets: FrameInsets(top: 48, left: 14, bottom: 34, right: 14), corner: .atLeast(48))

    // MARK: Code editor

    private struct IDEPalette {
        let chrome, surface, separator, title, text, textDim, accent, status, statusText: CGColor
        init(dark: Bool) {
            func c(_ hex: String) -> CGColor { FrameRenderer.color(hex) }
            if dark {
                chrome = c("#14141D"); surface = c("#1E1E2E"); separator = c("#0A0A10")
                title = c("#7C829C"); text = c("#D6DBF2"); textDim = c("#6E738D")
                accent = c("#A48CF7"); status = c("#6A55D0"); statusText = c("#F5F3FF")
            } else {
                chrome = c("#ECECF1"); surface = c("#FFFFFF"); separator = c("#D8D9E1")
                title = c("#777A8E"); text = c("#2A2C3A"); textDim = c("#8E91A3")
                accent = c("#4F6BED"); status = c("#4F6BED"); statusText = c("#FFFFFF")
            }
        }
    }

    static func drawIDE(_ c: FrameCanvas) {
        let ctx = c.ctx, k = c.k, p = IDEPalette(dark: c.dark), top = c.topBand
        let given = singleLine(c.title)
        let name = given.isEmpty ? "untitled" : given
        let ext = fileExtension(name)
        if top.height > 0 {
            fill(top, p.chrome, in: ctx)
            let strip = CGRect(x: top.minX, y: top.minY, width: top.width, height: min(34 * k, top.height))
            let bar = CGRect(x: top.minX, y: strip.maxY, width: top.width, height: top.maxY - strip.maxY)
            if bar.height > 0 {
                let dotsEnd = drawWindowDots(c, midY: bar.midY)
                let font = TextDrawing.font(name: "Helvetica Neue", size: 12 * k, bold: false)
                if let t = barTitleLayout(name, font: font, prefix: 0, c, bar: bar, minX: dotsEnd + 12 * k) {
                    drawText(t.label, font: font, color: p.title, x: t.x, midY: bar.midY, in: ctx)
                }
            }
            drawIDETabs(c, strip: strip, name: name, ext: ext, p: p)
        }
        drawIDEStatus(c, ext: ext, p: p)
    }

    static func drawIDEOverlay(_ c: FrameCanvas) {}

    private static func drawIDETabs(_ c: FrameCanvas, strip: CGRect, name: String, ext: String, p: IDEPalette) {
        let ctx = c.ctx, k = c.k, hair = max(1, 0.5 * k)
        fill(CGRect(x: strip.minX, y: strip.minY, width: strip.width, height: hair), p.separator, in: ctx)
        let font = TextDrawing.font(name: "Helvetica Neue", size: 12 * k, bold: false)
        let padX = 12 * k, dot = 7 * k, dotGap = 7 * k, closeGap = 12 * k, close = 6 * k
        let maxTab = min(strip.width, 280 * k)
        var fixed = padX + dot + dotGap + closeGap + close + padX
        var label = truncated(name, font: font, maxWidth: maxTab - fixed)
        let bare = padX + dot + dotGap + padX
        let roomier = truncated(name, font: font, maxWidth: maxTab - bare)
        let showClose = label == name || roomier.count <= label.count
        if !showClose { fixed = bare; label = roomier }
        let active = CGRect(x: strip.minX, y: strip.minY,
                            width: min(fixed + textWidth(label, font: font), strip.width), height: strip.height)
        fill(active, p.surface, in: ctx)
        fill(CGRect(x: active.minX, y: active.maxY - 2 * k, width: active.width, height: 2 * k), p.accent, in: ctx)
        fill(CGRect(x: active.maxX, y: strip.minY, width: hair, height: strip.height), p.separator, in: ctx)
        let midY = active.midY - 1 * k
        ctx.setFillColor(fileColor(ext))
        ctx.fillEllipse(in: CGRect(x: active.minX + padX, y: midY - dot / 2, width: dot, height: dot))
        let textX = active.minX + padX + dot + dotGap
        drawText(label, font: font, color: p.text, x: textX, midY: midY,
                 clip: CGRect(x: textX, y: active.minY, width: max(active.maxX - textX - (showClose ? padX + close + closeGap / 2 : padX / 2), 0), height: active.height),
                 in: ctx)
        if showClose, active.width >= fixed {
            let cx = active.maxX - padX - close / 2
            ctx.setStrokeColor(p.textDim)
            ctx.setLineWidth(max(1, 1.2 * k))
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: cx - close / 2, y: midY - close / 2)); ctx.addLine(to: CGPoint(x: cx + close / 2, y: midY + close / 2))
            ctx.move(to: CGPoint(x: cx - close / 2, y: midY + close / 2)); ctx.addLine(to: CGPoint(x: cx + close / 2, y: midY - close / 2))
            ctx.strokePath()
        }

        var x = active.maxX + hair
        let reserve = 34 * k
        for other in ["README.md", "styles.css"] where other != name {
            let w = padX + dot + dotGap + textWidth(other, font: font) + padX
            guard x + w <= strip.maxX - reserve else { break }
            ctx.setFillColor(fileColor(fileExtension(other)).copy(alpha: 0.55) ?? p.textDim)
            ctx.fillEllipse(in: CGRect(x: x + padX, y: midY - dot / 2, width: dot, height: dot))
            drawText(other, font: font, color: p.textDim, x: x + padX + dot + dotGap, midY: midY, in: ctx)
            fill(CGRect(x: x + w, y: strip.minY, width: hair, height: strip.height), p.separator, in: ctx)
            x += w + hair
        }
        if strip.maxX - x >= reserve {
            let d = 3 * k
            ctx.setFillColor(p.textDim)
            for i in 0..<3 {
                ctx.fillEllipse(in: CGRect(x: strip.maxX - 16 * k - d / 2 - CGFloat(2 - i) * 5 * k, y: midY - d / 2, width: d, height: d))
            }
        }
    }

    private static func drawIDEStatus(_ c: FrameCanvas, ext: String, p: IDEPalette) {
        let ctx = c.ctx, k = c.k, band = c.bottomBand
        guard band.height > 0 else { return }
        fill(band, p.status, in: ctx)
        let font = TextDrawing.font(name: "Helvetica Neue", size: 11 * k, bold: false)
        let edge = max(10 * k, cornerInset(radius: c.radius, depth: band.height / 2) + 6 * k)
        let midY = band.midY
        var x = band.minX + edge
        let glyph = min(10 * k, band.height - 8 * k)
        if glyph >= 5 * k {
            drawBranchGlyph(ctx, x: x, midY: midY, size: glyph, color: p.statusText)
            x += glyph * 0.8 + 5 * k
        }
        drawText("main", font: font, color: p.statusText, x: x, midY: midY,
                 clip: CGRect(x: band.minX, y: band.minY, width: max(band.maxX - edge - band.minX, 0), height: band.height), in: ctx)
        let leftEnd = x + textWidth("main", font: font)

        let gap = 14 * k
        var items = ["Ln 1, Col 1", "Spaces: 4", "UTF-8", languageName(ext)]
        let dropOrder = ["Spaces: 4", languageName(ext), "UTF-8", "Ln 1, Col 1"]
        func total(_ list: [String]) -> CGFloat {
            list.reduce(0) { $0 + textWidth($1, font: font) } + CGFloat(max(list.count - 1, 0)) * gap
        }
        let available = band.maxX - edge - (leftEnd + 2 * gap)
        for victim in dropOrder where !items.isEmpty && total(items) > available {
            items.removeAll { $0 == victim }
        }
        var right = band.maxX - edge
        for item in items.reversed() {
            drawText(item, font: font, color: p.statusText, x: right, midY: midY, align: .right, in: ctx)
            right -= textWidth(item, font: font) + gap
        }
    }

    /// A version-control branch glyph: a trunk with two nodes and a merging side branch.
    private static func drawBranchGlyph(_ ctx: CGContext, x: CGFloat, midY: CGFloat, size s: CGFloat, color: CGColor) {
        let w = max(1, s * 0.12), r = s * 0.15
        let trunkX = x + r + w / 2
        let bottom = CGPoint(x: trunkX, y: midY - s / 2 + r + w / 2)
        let top = CGPoint(x: trunkX, y: midY + s / 2 - r - w / 2)
        let side = CGPoint(x: x + s * 0.8 - r - w / 2, y: top.y)
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        for p in [bottom, top, side] {
            ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        ctx.move(to: CGPoint(x: trunkX, y: bottom.y + r))
        ctx.addLine(to: CGPoint(x: trunkX, y: top.y - r))
        ctx.move(to: CGPoint(x: side.x, y: side.y - r))
        ctx.addQuadCurve(to: CGPoint(x: trunkX, y: bottom.y + r + s * 0.18), control: CGPoint(x: side.x, y: bottom.y + r + s * 0.18))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    private static func fileColor(_ ext: String) -> CGColor {
        switch ext {
        case "md", "markdown": return color("#519ABA")
        case "swift": return color("#F05138")
        case "js", "mjs", "jsx": return color("#E8C547")
        case "ts", "tsx": return color("#3178C6")
        case "py": return color("#4B8BBE")
        case "css", "scss": return color("#A86FD9")
        case "html", "htm": return color("#E44D26")
        case "json", "yml", "yaml", "toml": return color("#CBCB41")
        case "rs": return color("#DEA584")
        case "go": return color("#00ADD8")
        case "rb": return color("#CC342D")
        case "sh", "zsh", "bash": return color("#89E051")
        default: return color("#8E91A3")
        }
    }

    private static func languageName(_ ext: String) -> String {
        switch ext {
        case "md", "markdown": return "Markdown"
        case "swift": return "Swift"
        case "js", "mjs", "jsx": return "JavaScript"
        case "ts", "tsx": return "TypeScript"
        case "py": return "Python"
        case "css": return "CSS"
        case "scss": return "SCSS"
        case "html", "htm": return "HTML"
        case "json": return "JSON"
        case "yml", "yaml": return "YAML"
        case "toml": return "TOML"
        case "rs": return "Rust"
        case "go": return "Go"
        case "rb": return "Ruby"
        case "sh", "zsh", "bash": return "Shell"
        default: return "Plain Text"
        }
    }

    // MARK: Terminal

    static func drawTerminal(_ c: FrameCanvas) {
        let ctx = c.ctx, k = c.k, top = c.topBand
        let dark = c.dark
        ctx.setFillColor(terminalEdge(dark))
        ctx.addRect(c.card)
        ctx.addRect(c.screen)
        ctx.fillPath(using: .evenOdd)
        guard top.height > 0 else { return }
        if !dark {
            ctx.saveGState()
            ctx.clip(to: top)
            let colors = [color("#F2F2F4"), color("#E1E1E5")] as CFArray
            if let gradient = CGGradient(colorsSpace: ColorSpaces.sRGB, colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: top.minX, y: top.maxY), end: CGPoint(x: top.minX, y: top.minY), options: [])
            }
            ctx.restoreGState()
        }
        fill(CGRect(x: top.minX, y: top.minY, width: top.width, height: max(1, 0.5 * k)), color(dark ? "#000000" : "#C6C6CB"), in: ctx)

        let midY = top.midY
        let dotsEnd = drawWindowDots(c, midY: midY)
        let given = singleLine(c.title)
        let text = given.isEmpty ? "zsh — 80×24" : given
        let font = TextDrawing.font(name: "Menlo", size: 11.5 * k, bold: false)
        let icon = CGSize(width: 14 * k, height: 11 * k), iconGap = 7 * k
        let minX = dotsEnd + 12 * k
        let withIcon = barTitleLayout(text, font: font, prefix: icon.width + iconGap, c, bar: top, minX: minX)
        let plain = barTitleLayout(text, font: font, prefix: 0, c, bar: top, minX: minX)
        let showIcon = withIcon != nil && (withIcon?.label == text || plain?.label != text)
        guard let t = showIcon ? withIcon : plain else { return }
        let label = t.label
        var x = t.x
        if showIcon {
            let box = CGRect(x: x, y: midY - icon.height / 2, width: icon.width, height: icon.height)
            fillRounded(box, radius: 2.5 * k, color(dark ? "#3A3A40" : "#2C2C31"), in: ctx)
            ctx.saveGState()
            ctx.setStrokeColor(color(dark ? "#D8D8DE" : "#F2F2F4"))
            ctx.setLineWidth(max(1, 1.1 * k))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let gx = box.minX + 3.5 * k, gy = box.midY + 0.5 * k
            ctx.move(to: CGPoint(x: gx, y: gy + 2 * k))
            ctx.addLine(to: CGPoint(x: gx + 2.2 * k, y: gy))
            ctx.addLine(to: CGPoint(x: gx, y: gy - 2 * k))
            ctx.move(to: CGPoint(x: gx + 3.6 * k, y: gy - 2.4 * k))
            ctx.addLine(to: CGPoint(x: gx + 7 * k, y: gy - 2.4 * k))
            ctx.strokePath()
            ctx.restoreGState()
            x += icon.width + iconGap
        }
        drawText(label, font: font, color: color(dark ? "#A9A9B0" : "#55555C"), x: x, midY: midY, in: ctx)
    }

    private static func terminalEdge(_ dark: Bool) -> CGColor { color(dark ? "#1C1C1F" : "#E1E1E5") }

    /// Rounds the screen's bottom corners into the thin window edge so it follows the card's corners.
    static func drawTerminalOverlay(_ c: FrameCanvas) {
        let s = c.screen, k = c.k
        let edge = max(s.minX - c.card.minX, 0)
        guard edge > 0, s.width > 0, s.height > 0 else { return }
        let r = min(max(c.radius - edge, 0), 80 * k, min(s.width, s.height) / 2)
        guard r > 0 else { return }
        let path = CGMutablePath()
        path.addRect(s)
        path.move(to: CGPoint(x: s.minX, y: s.maxY))
        path.addLine(to: CGPoint(x: s.minX, y: s.minY + r))
        path.addArc(tangent1End: CGPoint(x: s.minX, y: s.minY), tangent2End: CGPoint(x: s.minX + r, y: s.minY), radius: r)
        path.addLine(to: CGPoint(x: s.maxX - r, y: s.minY))
        path.addArc(tangent1End: CGPoint(x: s.maxX, y: s.minY), tangent2End: CGPoint(x: s.maxX, y: s.minY + r), radius: r)
        path.addLine(to: CGPoint(x: s.maxX, y: s.maxY))
        path.closeSubpath()
        c.ctx.clip(to: s)
        c.ctx.setFillColor(terminalEdge(c.dark))
        c.ctx.addPath(path)
        c.ctx.fillPath(using: .evenOdd)
    }

    // MARK: Phone

    private struct PhonePalette {
        let bezel, rimTop, rimMid, rimBottom, rimInner, rimOuter, ink, inkDim, pill, lens, home, displayEdge: CGColor
        init(dark: Bool) {
            func c(_ hex: String) -> CGColor { FrameRenderer.color(hex) }
            if dark {
                bezel = c("#131316"); rimTop = c("#7A7A82"); rimMid = c("#38383E"); rimBottom = c("#56565D")
                rimInner = c("#000000"); rimOuter = c("#9A9AA3")
                ink = c("#F5F5F7"); inkDim = c("#F5F5F773"); pill = c("#000000"); lens = c("#1D2438")
                home = c("#F5F5F7C0"); displayEdge = c("#FFFFFF14")
            } else {
                bezel = c("#FAFAFC"); rimTop = c("#F4F4F7"); rimMid = c("#B9BAC2"); rimBottom = c("#D6D7DD")
                rimInner = c("#CDCED5"); rimOuter = c("#FFFFFF")
                ink = c("#1C1C1E"); inkDim = c("#1C1C1E66"); pill = c("#0A0A0C"); lens = c("#1D2438")
                home = c("#1C1C1EA0"); displayEdge = c("#0000001A")
            }
        }
    }

    static func drawPhone(_ c: FrameCanvas) {
        let ctx = c.ctx, k = c.k, card = c.card, screen = c.screen, p = PhonePalette(dark: c.dark)
        ctx.setFillColor(p.bezel)
        ctx.addRect(card)
        ctx.addRect(screen)
        ctx.fillPath(using: .evenOdd)

        // Metallic rim following the card's rounded shape.
        let rim = min(3 * k, max(screen.minX - card.minX, 0) / 3)
        if rim > 0 {
            let inner = card.insetBy(dx: rim, dy: rim)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: card, cornerWidth: c.radius, cornerHeight: c.radius, transform: nil))
            let ir = max(min(c.radius - rim, min(inner.width, inner.height) / 2), 0)
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: ir, cornerHeight: ir, transform: nil))
            ctx.clip(using: .evenOdd)
            let colors = [p.rimTop, p.rimMid, p.rimBottom] as CFArray
            if let gradient = CGGradient(colorsSpace: ColorSpaces.sRGB, colors: colors, locations: [0, 0.55, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: card.minX, y: card.maxY), end: CGPoint(x: card.minX, y: card.minY), options: [])
            }
            ctx.restoreGState()
            strokeRounded(card, radius: c.radius, width: max(1, 0.5 * k), p.rimOuter, in: ctx)
            strokeRounded(inner, radius: c.radius - rim, width: max(1, 0.5 * k), p.rimInner, in: ctx)
        }

        // Status bar: text, camera pill and connectivity glyphs.
        let row = CGRect(x: screen.minX, y: screen.maxY, width: screen.width, height: max(card.maxY - rim - screen.maxY, 0))
        if row.height >= 12 * k {
            let midY = row.midY
            var pill = CGRect.null
            let pw = min(90 * k, screen.width * 0.3), ph = min(24 * k, row.height - 14 * k)
            if pw >= 16 * k, ph >= 8 * k, pw < ph * 2.2 {
                let d = min(ph * 0.5, 11 * k)
                pill = CGRect(x: row.midX - d / 2, y: midY - d / 2, width: d, height: d)
                ctx.setFillColor(p.pill)
                ctx.fillEllipse(in: pill)
                ctx.setFillColor(p.lens)
                ctx.fillEllipse(in: pill.insetBy(dx: d * 0.22, dy: d * 0.22))
            } else if pw >= 16 * k, ph >= 8 * k {
                pill = CGRect(x: row.midX - pw / 2, y: midY - ph / 2, width: pw, height: ph)
                fillRounded(pill, radius: ph / 2, p.pill, in: ctx)
                let lens = ph * 0.42
                ctx.setFillColor(p.lens)
                ctx.fillEllipse(in: CGRect(x: pill.maxX - ph / 2 - lens / 2, y: midY - lens / 2, width: lens, height: lens))
                ctx.setFillColor(color("#FFFFFF33"))
                ctx.fillEllipse(in: CGRect(x: pill.maxX - ph / 2 - lens * 0.12, y: midY + lens * 0.02, width: lens * 0.26, height: lens * 0.26))
            }
            let gap = 8 * k
            let leftEar = CGRect(x: row.minX, y: row.minY, width: (pill.isNull ? row.midX : pill.minX - gap) - row.minX, height: row.height)
            let rightEar = CGRect(x: pill.isNull ? row.midX : pill.maxX + gap, y: row.minY,
                                  width: row.maxX - (pill.isNull ? row.midX : pill.maxX + gap), height: row.height)
            let given = singleLine(c.title)
            let text = given.isEmpty ? "12:30" : given
            let font = TextDrawing.font(name: "HelveticaNeue-Medium", size: 14 * k, bold: false)
            let label = truncated(text, font: font, maxWidth: leftEar.width - 12 * k)
            let tw = textWidth(label, font: font)
            if !label.isEmpty {
                let offset = min(max((leftEar.width - tw) / 2, 6 * k), 30 * k)
                drawText(label, font: font, color: p.ink, x: leftEar.minX + offset, midY: midY, in: ctx)
            }
            drawStatusIcons(ctx, ear: rightEar, midY: midY, k: k, p: p)
        }

        // Home indicator.
        let base = CGRect(x: screen.minX, y: card.minY + rim, width: screen.width, height: max(screen.minY - card.minY - rim, 0))
        let hw = min(130 * k, screen.width * 0.36), hh = 5 * k
        if base.height >= hh + 6 * k, hw >= 16 * k {
            fillRounded(CGRect(x: base.midX - hw / 2, y: base.midY - hh / 2, width: hw, height: hh), radius: hh / 2, p.home, in: ctx)
        }
    }

    private static func drawStatusIcons(_ ctx: CGContext, ear: CGRect, midY: CGFloat, k: CGFloat, p: PhonePalette) {
        let gap = 5 * k
        let signalW = 4 * 3 * k + 3 * 1.6 * k, wifiW = 15.5 * k, batteryW = 24.5 * k
        var widths = [signalW, wifiW, batteryW]
        while !widths.isEmpty {
            let total = widths.reduce(0, +) + CGFloat(widths.count - 1) * gap
            if total <= ear.width - 12 * k { break }
            widths.removeFirst()
        }
        guard !widths.isEmpty else { return }
        let total = widths.reduce(0, +) + CGFloat(widths.count - 1) * gap
        let offset = min(max((ear.width - total) / 2, 6 * k), 30 * k)
        var x = ear.maxX - offset - total
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if widths.count == 3 {
            let bw = 3 * k
            for i in 0..<4 {
                let h = (4 + CGFloat(i) * 2.2) * k
                fillRounded(CGRect(x: x, y: midY - 5 * k, width: bw, height: h), radius: 0.8 * k, p.ink, in: ctx)
                x += bw + 1.6 * k
            }
            x += gap - 1.6 * k
        }
        if widths.count >= 2 {
            let cx = x + wifiW / 2, cy = midY - 5.2 * k
            let bands: [(CGFloat, CGFloat)] = [(0, 3.4 * k), (5 * k, 7.6 * k), (9.2 * k, 11.8 * k)]
            ctx.setFillColor(p.ink)
            for (r0, r1) in bands {
                let a0 = CGFloat.pi / 4, a1 = CGFloat.pi * 3 / 4
                ctx.move(to: CGPoint(x: cx + r1 * cos(a0), y: cy + r1 * sin(a0)))
                ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
                if r0 > 0 {
                    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
                } else {
                    ctx.addLine(to: CGPoint(x: cx, y: cy))
                }
                ctx.closePath()
            }
            ctx.fillPath()
            x += wifiW + gap
        }
        let body = CGRect(x: x, y: midY - 5.5 * k, width: 22 * k, height: 11 * k)
        strokeRounded(body, radius: 3.2 * k, width: max(1, 1 * k), p.inkDim, in: ctx)
        let level = body.insetBy(dx: 2 * k, dy: 2 * k)
        fillRounded(CGRect(x: level.minX, y: level.minY, width: level.width * 0.8, height: level.height), radius: 1.6 * k, p.ink, in: ctx)
        fillRounded(CGRect(x: body.maxX + 1 * k, y: midY - 2 * k, width: 1.5 * k, height: 4 * k), radius: 0.7 * k, p.inkDim, in: ctx)
    }

    static func drawPhoneOverlay(_ c: FrameCanvas) {
        let ctx = c.ctx, k = c.k, s = c.screen, p = PhonePalette(dark: c.dark)
        guard s.width > 0, s.height > 0 else { return }
        let side = max(s.minX - c.card.minX, 0)
        // Points of the corner regions stay within 0.3 × r of an edge, so 80pt keeps them inside the 24pt margin.
        let r = min(max(c.radius - side, 8 * k), 80 * k, min(s.width, s.height) / 2)
        let display = CGPath(roundedRect: s, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.clip(to: s)
        ctx.setFillColor(p.bezel)
        ctx.addRect(s)
        ctx.addPath(display)
        ctx.fillPath(using: .evenOdd)
        let w = max(1, 0.5 * k)
        let edge = s.insetBy(dx: w / 2, dy: w / 2)
        ctx.setStrokeColor(p.displayEdge)
        ctx.setLineWidth(w)
        ctx.addPath(CGPath(roundedRect: edge, cornerWidth: max(r - w / 2, 0), cornerHeight: max(r - w / 2, 0), transform: nil))
        ctx.strokePath()
    }

    // MARK: Shared helpers

    /// Three window control dots at the top-left; returns the right edge of the last dot.
    @discardableResult
    private static func drawWindowDots(_ c: FrameCanvas, midY: CGFloat) -> CGFloat {
        let k = c.k, d = 12 * k
        let x0 = c.card.minX + max(14 * k, cornerInset(radius: c.radius, depth: c.card.maxY - midY) + 8 * k)
        for (i, hex) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
            c.ctx.setFillColor(color(hex))
            c.ctx.fillEllipse(in: CGRect(x: x0 + CGFloat(i) * 20 * k, y: midY - d / 2, width: d, height: d))
        }
        return x0 + 40 * k + d
    }

    /// Places a title (after an optional `prefix` such as an icon) centred in `bar`, shifted right of `minX`
    /// when needed and truncated to fit. Nil when too little of the text would show.
    private static func barTitleLayout(_ text: String, font: CTFont, prefix: CGFloat, _ c: FrameCanvas, bar: CGRect,
                                       minX: CGFloat) -> (x: CGFloat, label: String)? {
        let maxX = bar.maxX - max(12 * c.k, cornerInset(radius: c.radius, depth: c.card.maxY - bar.midY) + 8 * c.k)
        let label = truncated(text, font: font, maxWidth: maxX - minX - prefix)
        guard !label.isEmpty, label == text || label.count > min(text.count, 5) else { return nil }
        let w = prefix + textWidth(label, font: font)
        return (min(max(bar.midX - w / 2, minX), maxX - w), label)
    }

    /// How far a rounded card corner of radius `r` cuts in horizontally at `depth` from the card's top or bottom edge.
    private static func cornerInset(radius r: CGFloat, depth: CGFloat) -> CGFloat {
        guard r > 0, depth < r else { return 0 }
        let dy = r - max(depth, 0)
        return r - (r * r - dy * dy).squareRoot()
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// `text` shortened with an ellipsis to fit `maxWidth`; empty when not even one character fits.
    private static func truncated(_ text: String, font: CTFont, maxWidth: CGFloat) -> String {
        guard maxWidth > 0, !text.isEmpty else { return "" }
        if textWidth(text, font: font) <= maxWidth { return text }
        let chars = Array(text)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if textWidth(String(chars[..<mid]) + "…", font: font) <= maxWidth { lo = mid } else { hi = mid - 1 }
        }
        guard lo > 0 else { return "" }
        return String(chars[..<lo]).trimmingCharacters(in: .whitespaces) + "…"
    }
}
