import CoreGraphics
import CoreText
import Foundation

// Comic panel, film strip and photo print frames.
extension FrameRenderer {
    static let comicMetrics = FrameMetrics(insets: FrameInsets(top: 56, left: 18, bottom: 18, right: 18), corner: .fixed(0))
    static let filmStripMetrics = FrameMetrics(insets: FrameInsets(top: 40, left: 12, bottom: 40, right: 12), corner: .fixed(2))
    static let photoMetrics = FrameMetrics(insets: FrameInsets(top: 20, left: 20, bottom: 72, right: 20), corner: .fixed(3))

    // MARK: Comic panel

    static func drawComic(_ c: FrameCanvas) {
        let ctx = c.ctx, k = c.k, dark = c.dark
        let ink = color(dark ? "#F4EAD2" : "#121212")
        let inkW = 5 * k
        // Hard, offset "misprint" shadows under the caption and burst.
        let shade = dark ? color("#000000") : ink

        ctx.saveGState()
        clipOutside(c.screen, of: c)
        fill(c.card, color(dark ? "#171B2E" : "#FFFDF4"), in: ctx)
        ctx.saveGState()
        clipOutside(c.screen.insetBy(dx: -(inkW + 2 * k), dy: -(inkW + 2 * k)), of: c)
        halftone(c, color: color(dark ? "#A9BCFF2E" : "#3DB8E266"), spacing: 9 * k)
        ctx.restoreGState()
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(inkW)
        ctx.setLineJoin(.miter)
        ctx.stroke(c.screen.insetBy(dx: -inkW / 2, dy: -inkW / 2))
        ctx.restoreGState()

        // Caption box and burst live in the paper above the panel.
        let band = CGRect(x: c.card.minX, y: c.screen.maxY + inkW, width: c.card.width, height: c.card.maxY - c.screen.maxY - inkW)
        guard band.height > 8 * k else { return }
        let left = c.screen.minX - inkW, right = c.screen.maxX + inkW
        let shadow = 3 * k
        let burstR = min(21 * k, band.height / 2 - 3 * k)
        let burstW = burstR * 2.5
        let showBurst = right - left >= burstW + 120 * k
        let boxMaxW = (showBurst ? right - burstW - 10 * k : right) - left - shadow
        let font = TextDrawing.font(name: "Chalkboard SE", size: 13 * k, bold: true)
        let pad = 10 * k
        let text = truncated(c.title.isEmpty ? "MEANWHILE…" : c.title.uppercased(), font: font, maxWidth: boxMaxW - 2 * pad)
        let boxH = min(26 * k, band.height - 2 * shadow - 4 * k)
        let boxW = min(textWidth(text, font: font) + 2 * pad, boxMaxW)
        let box = CGRect(x: left, y: band.midY - boxH / 2 + shadow / 2, width: boxW, height: boxH)
        if boxW > 2 * pad {
            fill(box.offsetBy(dx: shadow, dy: -shadow), shade, in: ctx)
            fill(box, color("#FFF1A8"), in: ctx)
            ctx.setStrokeColor(color("#121212"))
            ctx.setLineWidth(2 * k)
            ctx.stroke(box.insetBy(dx: k, dy: k))
            drawText(text, font: font, color: color("#141414"), x: box.minX + pad, midY: box.midY,
                     clip: box.insetBy(dx: 3 * k, dy: 0), in: ctx)
        }
        if showBurst {
            let center = CGPoint(x: right - burstW / 2, y: band.midY)
            let path = burstPath(center: center, rx: burstW / 2, ry: burstR, spikes: 13)
            ctx.addPath(path.copy(using: [CGAffineTransform(translationX: shadow * 0.8, y: -shadow * 0.8)]) ?? path)
            ctx.setFillColor(shade)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setFillColor(color("#F2453D"))
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(color("#121212"))
            ctx.setLineWidth(1.6 * k)
            ctx.setLineJoin(.miter)
            ctx.strokePath()
            let pow = TextDrawing.font(name: "Chalkboard SE", size: 12 * k, bold: true)
            drawText("POW!", font: pow, color: color("#121212"), x: center.x + 0.8 * k, midY: center.y - 0.8 * k, align: .center, in: ctx)
            drawText("POW!", font: pow, color: color("#FFE45C"), x: center.x, midY: center.y, align: .center, in: ctx)
        }
    }

    static func drawComicOverlay(_ c: FrameCanvas) {}

    // MARK: Film strip

    static func drawFilmStrip(_ c: FrameCanvas) {
        let ctx = c.ctx, k = c.k, dark = c.dark, card = c.card, screen = c.screen
        let hole = color(dark ? "#ECE7DD" : "#FCF6EA")
        let mark = color(dark ? "#E9A646" : "#3A1C06")

        ctx.saveGState()
        clipOutside(screen, of: c)
        fill(card, color(dark ? "#131211" : "#C46F28"), in: ctx)

        let holeW = 15 * k, holeH = 10 * k, pitch = 26 * k, edge = 6 * k
        let n = max(Int(floor((card.width - 2 * edge + (pitch - holeW)) / pitch)), 0)
        let start = card.midX - (CGFloat(n) * pitch - (pitch - holeW)) / 2
        // Perforations sit a touch nearer the picture, leaving the outer edge for markings.
        let shift = 2 * k
        for (band, dy) in [(c.topBand, -shift), (c.bottomBand, shift)] where band.height >= holeH + 4 * k {
            let y = band.midY - holeH / 2 + dy
            for i in 0..<n {
                fillRounded(CGRect(x: start + CGFloat(i) * pitch, y: y, width: holeW, height: holeH), radius: 2.2 * k, hole, in: ctx)
            }
        }

        let lw = max(k, 1)
        ctx.setStrokeColor(color(dark ? "#45403A" : "#8A4615"))
        ctx.setLineWidth(lw)
        ctx.stroke(screen.insetBy(dx: -lw / 2, dy: -lw / 2))

        // A short coded track along the top edge, like the bar code printed on film stock.
        let top = c.topBand
        let topStrip = CGRect(x: card.minX, y: top.midY - shift + holeH / 2, width: card.width, height: 0)
        let trackH = 4 * k, cell = 1.3 * k
        let gaps: [CGFloat] = [1, 2, 1, 1, 3, 1, 2, 2, 1, 1, 3, 1, 1, 2, 1, 3, 2, 1, 1, 2]
        let trackW = gaps.reduce(0) { $0 + (1 + $1) * cell }
        let trackY = (topStrip.minY + card.maxY) / 2 - trackH / 2
        if card.maxY - topStrip.minY > trackH + 4 * k, screen.width > trackW + 40 * k {
            ctx.setFillColor(mark.copy(alpha: 0.7) ?? mark)
            var x = screen.minX + 2 * k
            for gap in gaps {
                ctx.fill(CGRect(x: x, y: trackY, width: cell, height: trackH))
                x += (1 + gap) * cell
            }
        }

        // Edge markings run along the outer strip of the bottom band.
        let bottom = c.bottomBand
        let strip = CGRect(x: card.minX, y: bottom.minY, width: card.width, height: bottom.height / 2 + shift - holeH / 2)
        if strip.height > 5 * k {
            let font = TextDrawing.font(name: "Menlo", size: 7.5 * k, bold: true)
            let midY = strip.midY
            let gap = 14 * k
            let x0 = screen.minX + 2 * k, x1 = screen.maxX - 2 * k
            let rightText = "12A ▸"
            let rightW = textWidth(rightText, font: font)
            let label = c.title.isEmpty ? "GLINT 400" : c.title.uppercased()
            var avail = x1 - x0
            let showRight = avail > rightW + gap + 60 * k
            if showRight { avail -= rightW + gap }
            let title = truncated("▸ " + label, font: font, maxWidth: avail)
            drawText(title, font: font, color: mark, x: x0, midY: midY, clip: strip, in: ctx)
            if showRight {
                drawText(rightText, font: font, color: mark, x: x1, midY: midY, align: .right, clip: strip, in: ctx)
                let num = "12"
                let numW = textWidth(num, font: font)
                let titleEnd = x0 + textWidth(title, font: font)
                let mid = (titleEnd + (x1 - rightW)) / 2
                if mid - numW / 2 > titleEnd + gap, mid + numW / 2 < x1 - rightW - gap {
                    drawText(num, font: font, color: mark, x: mid, midY: midY, align: .center, clip: strip, in: ctx)
                }
            }
        }
        ctx.restoreGState()
    }

    static func drawFilmStripOverlay(_ c: FrameCanvas) {}

    // MARK: Photo print

    static func drawPhoto(_ c: FrameCanvas) {
        let ctx = c.ctx, k = c.k, dark = c.dark, card = c.card, screen = c.screen

        ctx.saveGState()
        clipOutside(screen, of: c)
        let colors = (dark ? ["#222224", "#151516"] : ["#FDFCF8", "#F3F0E7"]).map { color($0) }
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: card.minX, y: card.maxY), end: CGPoint(x: card.maxX, y: card.minY), options: [])
        }
        // A faint recess where the photo meets the border.
        let lw = max(k, 1)
        ctx.setStrokeColor(color(dark ? "#00000099" : "#00000024"))
        ctx.setLineWidth(lw)
        ctx.stroke(screen.insetBy(dx: -lw / 2, dy: -lw / 2))
        ctx.setStrokeColor(color(dark ? "#FFFFFF10" : "#0000000C"))
        ctx.stroke(screen.insetBy(dx: -lw * 1.5, dy: -lw * 1.5))
        ctx.restoreGState()

        let bottom = c.bottomBand
        if !c.title.isEmpty, bottom.height > 12 * k {
            let font = TextDrawing.font(name: "MarkerFelt-Thin", size: min(22 * k, bottom.height * 0.4), bold: false)
            let inner = bottom.insetBy(dx: 14 * k, dy: 2 * k)
            let text = truncated(c.title, font: font, maxWidth: inner.width - 6 * k)
            ctx.saveGState()
            ctx.clip(to: inner)
            ctx.translateBy(x: bottom.midX, y: bottom.midY + 2 * k)
            ctx.rotate(by: 1.2 * .pi / 180)
            drawText(text, font: font, color: color(dark ? "#E6E3DC" : "#3A3A40"), x: 0, midY: 0, align: .center, in: ctx)
            ctx.restoreGState()
        }

        // A strip of translucent tape holds the print at the top.
        let top = c.topBand
        let tapeW = min(62 * k, card.width * 0.35), tapeH = min(13 * k, top.height - 4 * k)
        if tapeH > 4 * k, tapeW > 16 * k {
            ctx.saveGState()
            ctx.clip(to: top)
            ctx.translateBy(x: top.midX, y: top.midY)
            ctx.rotate(by: -2 * .pi / 180)
            let path = tapePath(width: tapeW, height: tapeH, k: k)
            ctx.addPath(path)
            ctx.setFillColor(color(dark ? "#CFC5A08C" : "#E4D6A3B3"))
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    static func drawPhotoOverlay(_ c: FrameCanvas) {}

    // MARK: Helpers

    /// Clips to the card minus `rect`, so nothing lands inside it.
    private static func clipOutside(_ rect: CGRect, of c: FrameCanvas) {
        let path = CGMutablePath()
        path.addRect(c.card)
        path.addRect(rect)
        c.ctx.addPath(path)
        c.ctx.clip(using: .evenOdd)
    }

    /// Shortens `text` with an ellipsis until it fits `maxWidth`.
    private static func truncated(_ text: String, font: CTFont, maxWidth: CGFloat) -> String {
        guard maxWidth > 0 else { return "" }
        if textWidth(text, font: font) <= maxWidth { return text }
        let chars = Array(text)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if textWidth(clipped(chars, mid), font: font) <= maxWidth { lo = mid } else { hi = mid - 1 }
        }
        return lo == 0 ? "" : clipped(chars, lo)
    }

    private static func clipped(_ chars: [Character], _ count: Int) -> String {
        String(chars[..<count]).trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// Ben-Day style dots on a 45° grid across the chrome bands, larger towards the top right.
    private static func halftone(_ c: FrameCanvas, color dotColor: CGColor, spacing s: CGFloat) {
        guard s > 0 else { return }
        let card = c.card, row = s / 2
        let path = CGMutablePath()
        let maxR = s * 0.3, minR = s * 0.1
        for band in [c.topBand, c.bottomBand, c.leftBand, c.rightBand] where band.width > 0 && band.height > 0 {
            let j0 = Int(floor((band.minY - card.minY) / row)), j1 = Int(ceil((band.maxY - card.minY) / row))
            for j in j0...j1 {
                let y = card.minY + CGFloat(j) * row
                let offset = j.isMultiple(of: 2) ? 0 : s / 2
                let i0 = Int(floor((band.minX - card.minX - offset) / s)), i1 = Int(ceil((band.maxX - card.minX - offset) / s))
                for i in i0...i1 {
                    let x = card.minX + offset + CGFloat(i) * s
                    guard band.contains(CGPoint(x: x, y: y)) else { continue }
                    let t = ((x - card.minX) / max(card.width, 1) + (y - card.minY) / max(card.height, 1)) / 2
                    let r = minR + (maxR - minR) * min(max(t, 0), 1)
                    path.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                }
            }
        }
        c.ctx.addPath(path)
        c.ctx.setFillColor(dotColor)
        c.ctx.fillPath()
    }

    /// A jagged comic "burst" balloon.
    private static func burstPath(center: CGPoint, rx: CGFloat, ry: CGFloat, spikes: Int) -> CGPath {
        let reach: [CGFloat] = [1.0, 0.88, 0.97, 0.84, 0.93, 1.0, 0.86, 0.95, 0.9, 0.98, 0.83, 0.94, 0.89]
        let path = CGMutablePath()
        for i in 0..<(spikes * 2) {
            let a = CGFloat(i) * .pi / CGFloat(spikes) + 0.2
            let r: CGFloat = i.isMultiple(of: 2) ? reach[(i / 2) % reach.count] : 0.66
            let p = CGPoint(x: center.x + cos(a) * rx * r, y: center.y + sin(a) * ry * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// A piece of tape centred on the origin with torn, zig-zag ends.
    private static func tapePath(width: CGFloat, height: CGFloat, k: CGFloat) -> CGPath {
        let teeth = 5, depth = min(2 * k, width / 8)
        let x0 = -width / 2, x1 = width / 2, y0 = -height / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: y0))
        path.addLine(to: CGPoint(x: x1, y: y0))
        for t in 1...(teeth * 2) {
            let y = y0 + height * CGFloat(t) / CGFloat(teeth * 2)
            path.addLine(to: CGPoint(x: x1 - (t.isMultiple(of: 2) ? 0 : depth), y: y))
        }
        path.addLine(to: CGPoint(x: x0, y: -y0))
        for t in 1...(teeth * 2) {
            let y = -y0 - height * CGFloat(t) / CGFloat(teeth * 2)
            path.addLine(to: CGPoint(x: x0 + (t.isMultiple(of: 2) ? 0 : depth), y: y))
        }
        path.closeSubpath()
        return path
    }
}
