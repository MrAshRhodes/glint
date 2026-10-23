import CoreGraphics
import CoreText
import Foundation

// Retro monitor, pixel arcade and handheld console frames. Every motif is original and generic.
extension FrameRenderer {
    static let retroMetrics = FrameMetrics(insets: FrameInsets(top: 36, left: 40, bottom: 64, right: 40), corner: .atLeast(18),
                                           supportsScreenEffects: true)
    static let arcadeMetrics = FrameMetrics(insets: FrameInsets(top: 52, left: 24, bottom: 24, right: 24), corner: .fixed(0),
                                            supportsScreenEffects: true)
    static let handheldMetrics = FrameMetrics(insets: FrameInsets(top: 32, left: 128, bottom: 44, right: 128), corner: .atLeast(40))

    // MARK: Retro monitor

    static func drawRetro(_ c: FrameCanvas) {
        let ctx = c.ctx, k = c.k, card = c.card, screen = c.screen, dark = c.dark
        RetroFrameKit.excludeScreen(c)

        // Moulded case: light top-left edge, dark bottom-right edge, softly shaded face.
        let edge = max(1, (2.5 * k).rounded())
        fill(card, color(dark ? "#141416" : "#A39880"), in: ctx)
        fillRounded(card.offsetBy(dx: -edge, dy: edge), radius: c.radius, color(dark ? "#56565B" : "#F7F2E6"), in: ctx)
        RetroFrameKit.verticalGradient(card.insetBy(dx: edge, dy: edge), radius: max(c.radius - edge, 0),
                                       top: color(dark ? "#3A3A3E" : "#E3DBC8"), bottom: color(dark ? "#2B2B2E" : "#D3C9B3"), in: ctx)

        // Recessed opening: a chamfered well (shaded top/left, lit bottom/right) and a dark lip around the tube.
        let lip = max(2, (5 * k).rounded()), slope = max(2, (6 * k).rounded())
        let tube = screen.insetBy(dx: -lip, dy: -lip)
        let well = tube.insetBy(dx: -slope, dy: -slope)
        RetroFrameKit.chamfer(outer: well, inner: tube, radius: 10 * k,
                              top: color(dark ? "#1E1E21" : "#B2A78F"), left: color(dark ? "#232326" : "#BCB29A"),
                              bottom: color(dark ? "#4A4A4F" : "#F1EBDC"), right: color(dark ? "#3F3F44" : "#E8E1D0"), in: ctx)
        fillRounded(tube, radius: 6 * k, color(dark ? "#0B0B0C" : "#1F1D1A"), in: ctx)

        // Chin: brand label on the left, vents in the middle, knobs, LED and power button on the right.
        let floorY = card.minY + edge
        let midY = ((well.minY + floorY) / 2).rounded()
        let button = CGRect(x: well.maxX - 20 * k, y: midY - 5.5 * k, width: 20 * k, height: 11 * k)
        RetroFrameKit.powerButton(button, k: k, dark: dark, in: ctx)
        let led = CGPoint(x: button.minX - 9 * k, y: midY)
        RetroFrameKit.led(at: led, diameter: 5 * k, k: k, in: ctx)
        let knobD = 13 * k
        let knob1 = CGRect(x: led.x - 11 * k - knobD, y: midY - knobD / 2, width: knobD, height: knobD)
        let knob2 = knob1.offsetBy(dx: -(knobD + 7 * k), dy: 0)

        // The label wins over the knobs when the chin is narrow.
        let label = c.title.isEmpty ? "GLINT 2000" : c.title
        let font = RetroFrameKit.font("Futura-Bold", size: 12 * k)
        let labelX = well.minX + 2 * k
        let wanted = min(textWidth(label, font: font), 64 * k)
        let knobs = [knob1, knob2]
        var knobCount = 2
        func controlsMinX(_ n: Int) -> CGFloat { n == 0 ? led.x - 2.5 * k : knobs[n - 1].minX }
        while knobCount > 0, controlsMinX(knobCount) - 14 * k - labelX < wanted { knobCount -= 1 }
        for (i, angle) in [CGFloat.pi * 0.3, CGFloat.pi * 0.8].enumerated() where i < knobCount {
            RetroFrameKit.knob(knobs[i], angle: angle, k: k, dark: dark, in: ctx)
        }
        let leftmost = controlsMinX(knobCount)

        let labelClip = CGRect(x: labelX, y: floorY, width: max(leftmost - 14 * k - labelX, 0), height: well.minY - floorY)
        let shown = RetroFrameKit.fitted(label, font: font, maxWidth: labelClip.width)
        if !shown.isEmpty {
            if dark {
                drawText(shown, font: font, color: color("#141416"), x: labelX, midY: midY - max(1, k), clip: labelClip, in: ctx)
                drawText(shown, font: font, color: color("#A2A2A8"), x: labelX, midY: midY, clip: labelClip, in: ctx)
            } else {
                drawText(shown, font: font, color: color("#FBF8F0"), x: labelX, midY: midY - max(1, k), clip: labelClip, in: ctx)
                drawText(shown, font: font, color: color("#8C826C"), x: labelX, midY: midY, clip: labelClip, in: ctx)
            }
        }

        let ventW = max(1, (2.5 * k).rounded()), pitch = 6 * k, ventCount = 7
        let ventsW = CGFloat(ventCount - 1) * pitch + ventW
        let freeMin = labelX + (shown.isEmpty ? 0 : textWidth(shown, font: font) + 18 * k), freeMax = leftmost - 18 * k
        if freeMax - freeMin >= ventsW {
            let x0 = ((freeMin + freeMax - ventsW) / 2).rounded()
            for i in 0..<ventCount {
                let slot = CGRect(x: x0 + CGFloat(i) * pitch, y: midY - 7.5 * k, width: ventW, height: 15 * k)
                fillRounded(slot.offsetBy(dx: 0, dy: -max(1, k)), radius: ventW / 2, color(dark ? "#4A4A4F" : "#F4EFE3"), in: ctx)
                fillRounded(slot, radius: ventW / 2, color(dark ? "#151517" : "#9F957E"), in: ctx)
            }
        }
    }

    static func drawRetroOverlay(_ c: FrameCanvas) {
        guard c.frame.metrics.supportsScreenEffects, c.frame.screenEffects else { return }
        let ctx = c.ctx, screen = c.screen
        ctx.clip(to: screen)
        RetroFrameKit.scanlines(screen, k: c.k, in: ctx)
        RetroFrameKit.vignette(screen, in: ctx)
        // Faint glass glare across the top-left of the tube.
        if let glare = CGGradient(colorsSpace: ColorSpaces.sRGB, colors: [color("#FFFFFF14"), color("#FFFFFF00")] as CFArray,
                                  locations: [0, 1]) {
            let reach = min(screen.width, screen.height) * 0.45
            ctx.drawLinearGradient(glare, start: CGPoint(x: screen.minX, y: screen.maxY),
                                   end: CGPoint(x: screen.minX + reach, y: screen.maxY - reach), options: [])
        }
    }

    // MARK: Pixel arcade

    static func drawArcade(_ c: FrameCanvas) {
        let ctx = c.ctx, card = c.card, screen = c.screen
        let u = RetroFrameKit.pixelUnit(c.k)
        let pal = ArcadePalette(dark: c.dark)
        RetroFrameKit.excludeScreen(c)

        // Cabinet border: dark outline, highlight top/left, shadow bottom/right, stepped corners.
        fill(card, pal.outline, in: ctx)
        let body = card.insetBy(dx: u, dy: u)
        RetroFrameKit.pixelRect(body, u: u, pal.shadow, in: ctx)
        RetroFrameKit.pixelRect(CGRect(x: body.minX, y: body.minY + u, width: body.width - u, height: body.height - u), u: u, pal.light, in: ctx)
        RetroFrameKit.pixelRect(body.insetBy(dx: u, dy: u), u: u, pal.base, in: ctx)
        fill(CGRect(x: body.minX + 2 * u, y: body.maxY - u, width: 2 * u, height: u), pal.shine, in: ctx)
        fill(CGRect(x: body.minX, y: body.maxY - 4 * u, width: u, height: u), pal.shine, in: ctx)

        // One recessed opening holds the HUD panel and the screen.
        let panelTop = max(card.maxY - 6 * u, screen.maxY + 2 * u)
        let opening = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: panelTop - screen.minY)
        let rim = opening.insetBy(dx: -2 * u, dy: -2 * u)
        fill(rim, pal.light, in: ctx)
        fill(CGRect(x: rim.minX, y: rim.minY + u, width: rim.width - u, height: rim.height - u), pal.shadow, in: ctx)
        fill(opening.insetBy(dx: -u, dy: -u), pal.rimLine, in: ctx)
        fill(CGRect(x: screen.minX, y: screen.maxY, width: screen.width, height: u), pal.outline, in: ctx)
        let panel = CGRect(x: screen.minX, y: screen.maxY + u, width: screen.width, height: panelTop - screen.maxY - u)
        fill(panel, pal.panel, in: ctx)
        drawArcadeHUD(c, panel: panel, u: u, pal: pal)
    }

    private static func drawArcadeHUD(_ c: FrameCanvas, panel: CGRect, u: CGFloat, pal: ArcadePalette) {
        guard panel.height >= 8, panel.width >= 8 else { return }
        let ctx = c.ctx
        // One pixel size for the HUD text and hearts so they read as the same pixel art.
        let cell = max(1, min((panel.height / 11).rounded(), ((panel.height - 2) / 7).rounded(.down)))
        let area = panel.insetBy(dx: (1.5 * u).rounded(), dy: 0)
        let midY = panel.midY
        let textTop = (midY + 3.5 * cell).rounded()
        let gap = u * 2

        // The player name uses the pixel font when it can, otherwise a monospaced fallback.
        let player = PixelFont.normalized(c.title).isEmpty ? "PLAYER 1" : PixelFont.normalized(c.title)
        let pixelName = PixelFont.supports(player)
        let fallback = RetroFrameKit.font("Menlo-Bold", size: 9 * cell)
        func nameWidth(_ s: String) -> CGFloat { pixelName ? PixelFont.width(s.count, cell: cell) : textWidth(s, font: fallback) }
        let tagAdvance = 3 * PixelFont.advance(cell)
        // Hearts may squeeze the name to a few letters; the score only shows beside a full-length name.
        let heartsMinName = tagAdvance + min(nameWidth(player), nameWidth("PLAY"))
        let scoreMinName = tagAdvance + min(nameWidth(player), nameWidth("PLAYER 1"))

        // Hearts on the right.
        let heartW = 7 * cell, heartGap = 2 * cell
        let heartsW = 3 * heartW + 2 * heartGap
        var right = area.maxX
        if area.width >= heartsMinName + gap + heartsW {
            let top = (midY + 3 * cell).rounded()
            for i in 0..<3 {
                RetroFrameKit.pixelHeart(x: area.maxX - heartsW + CGFloat(i) * (heartW + heartGap), top: top, cell: cell,
                                         fill: pal.heart, shine: pal.heartShine, in: ctx)
            }
            right = area.maxX - heartsW - gap
        }

        // Score in the middle when it fits.
        var nameLimit = right
        let scoreW = PixelFont.width(12, cell: cell)
        let scoreX = (panel.midX - scoreW / 2).rounded()
        if scoreX - gap >= area.minX + scoreMinName, scoreX + scoreW + gap <= right {
            PixelFont.draw("SCORE", x: scoreX, top: textTop, cell: cell, color: pal.accent, in: ctx)
            PixelFont.draw("001337", x: scoreX + 6 * PixelFont.advance(cell), top: textTop, cell: cell, color: pal.text, in: ctx)
            nameLimit = scoreX - gap
        }

        let clip = CGRect(x: area.minX, y: panel.minY, width: max(nameLimit - area.minX, 0), height: panel.height)
        guard clip.width > 0 else { return }
        ctx.saveGState()
        ctx.clip(to: clip)
        PixelFont.draw("1P", x: area.minX, top: textTop, cell: cell, color: pal.tag, in: ctx)
        let room = clip.width - tagAdvance
        if pixelName {
            let fit = max(0, Int(((room + cell) / PixelFont.advance(cell)).rounded(.down)))
            let name = String(player.prefix(fit)).trimmingCharacters(in: .whitespaces)
            PixelFont.draw(name, x: area.minX + tagAdvance, top: textTop, cell: cell, color: pal.text, in: ctx)
        } else {
            let name = RetroFrameKit.fitted(player, font: fallback, maxWidth: room, suffix: "")
            drawText(name, font: fallback, color: pal.text, x: area.minX + tagAdvance, midY: midY, in: ctx)
        }
        ctx.restoreGState()
    }

    static func drawArcadeOverlay(_ c: FrameCanvas) {
        guard c.frame.metrics.supportsScreenEffects, c.frame.screenEffects else { return }
        c.ctx.clip(to: c.screen)
        RetroFrameKit.scanlines(c.screen, k: c.k, in: c.ctx)
    }

    // MARK: Handheld console

    static func drawHandheld(_ c: FrameCanvas) {
        let ctx = c.ctx, k = c.k, card = c.card, screen = c.screen, dark = c.dark
        RetroFrameKit.excludeScreen(c)

        // Body: soft plastic with a light top edge and a darker bottom edge.
        let edge = max(1, (2 * k).rounded())
        fill(card, color(dark ? "#15162A" : "#B6B1C6"), in: ctx)
        fillRounded(card.offsetBy(dx: 0, dy: edge), radius: c.radius, color(dark ? "#4A4D72" : "#FDFCFF"), in: ctx)
        RetroFrameKit.verticalGradient(card.insetBy(dx: edge, dy: edge), radius: max(c.radius - edge, 0),
                                       top: color(dark ? "#34375B" : "#EEEBF5"), bottom: color(dark ? "#272944" : "#DBD7E6"), in: ctx)

        // Screen bezel with a label and power LED in its chin.
        let side = (10 * k).rounded(), chin = (18 * k).rounded()
        let bezel = CGRect(x: screen.minX - side, y: screen.minY - chin, width: screen.width + 2 * side, height: screen.height + side + chin)
        fillRounded(bezel.offsetBy(dx: 0, dy: -max(1, k)), radius: 12 * k, color(dark ? "#4A4D72" : "#FFFFFF"), in: ctx)
        fillRounded(bezel, radius: 12 * k, color(dark ? "#121320" : "#474B5D"), in: ctx)
        let lipW = max(1, (1.5 * k).rounded())
        fill(screen.insetBy(dx: -lipW, dy: -lipW), color("#0A0A0F"), in: ctx)

        let chinY = screen.minY - chin / 2
        let ledD = 4.5 * k
        RetroFrameKit.led(at: CGPoint(x: bezel.minX + 11 * k, y: chinY), diameter: ledD, k: k, in: ctx)
        let label = c.title.isEmpty ? "GLINT POCKET" : c.title
        let font = RetroFrameKit.font("AvenirNext-HeavyItalic", size: 8.5 * k)
        let labelClip = CGRect(x: bezel.minX + 22 * k, y: bezel.minY, width: max(bezel.width - 44 * k, 0), height: chin)
        if labelClip.width > 0 {
            let shown = RetroFrameKit.fitted(label, font: font, maxWidth: labelClip.width)
            let x = max(labelClip.minX, bezel.midX - textWidth(shown, font: font) / 2)
            drawText(shown, font: font, color: color(dark ? "#8C8FB0" : "#C9CBD6"), x: x, midY: chinY, clip: labelClip, in: ctx)
        }

        // Controls scale with k but shrink to fit very short cards; they stay centred on the screen.
        let unit = min(k, max(card.height - 12 * k, 1) / 66)
        let cy = screen.midY
        let dpadCenter = CGPoint(x: c.leftBand.midX, y: cy)
        let dpadWell = RetroFrameKit.dpad(center: dpadCenter, size: 50 * unit, unit: unit, dark: dark, in: ctx)
        let abCenter = CGPoint(x: c.rightBand.midX, y: cy)
        let abWell = RetroFrameKit.faceButtons(center: abCenter, unit: unit, dark: dark, in: ctx)

        // Bottom row: a small round button, start/select pills and a speaker grille.
        let rowY = ((card.minY + bezel.minY) / 2).rounded()
        let pillW = 20 * k, pillH = 6.5 * k, pillGap = 12 * k
        if bezel.minY - card.minY >= pillH + 6 * k, bezel.width >= 2 * pillW + pillGap {
            for i in 0..<2 {
                let x = screen.midX + (i == 0 ? -pillGap / 2 - pillW : pillGap / 2)
                RetroFrameKit.pill(CGRect(x: x, y: rowY - pillH / 2, width: pillW, height: pillH), k: k, dark: dark, in: ctx)
            }
        }
        let homeD = 11 * k
        let home = CGRect(x: c.leftBand.midX - homeD / 2, y: rowY - homeD / 2, width: homeD, height: homeD)
        if home.maxY + 4 * k <= dpadWell.minY, home.minY >= card.minY + 4 * k {
            RetroFrameKit.roundButton(home, k: k, dark: dark, in: ctx)
        }
        let grille = RetroFrameKit.grilleRect(center: CGPoint(x: c.rightBand.midX, y: rowY), k: k)
        if grille.maxY + 4 * k <= abWell.minY, grille.minY >= card.minY + 4 * k {
            RetroFrameKit.grille(center: CGPoint(x: c.rightBand.midX, y: rowY), k: k, dark: dark, in: ctx)
        }
    }

    static func drawHandheldOverlay(_ c: FrameCanvas) {}
}

private struct ArcadePalette {
    let outline, light, base, shadow, shine, rimLine, panel, text, tag, accent, heart, heartShine: CGColor

    init(dark: Bool) {
        let c = FrameRenderer.color
        if dark {
            outline = c("#04050D"); light = c("#34408A"); shine = c("#8FA2FF"); base = c("#1C2456"); shadow = c("#0D1233")
            rimLine = c("#00E1FF"); panel = c("#070A1A"); text = c("#F2F4FF"); tag = c("#FFE45E")
            accent = c("#FF3AD6"); heart = c("#FF3B7A"); heartShine = c("#FFC2D6")
        } else {
            outline = c("#2A0E4D"); light = c("#C48BFF"); shine = c("#F3E6FF"); base = c("#8A3DF5"); shadow = c("#5B1EB5")
            rimLine = c("#2A0E4D"); panel = c("#1A0B38"); text = c("#FFFFFF"); tag = c("#FFD23F")
            accent = c("#3DF5FF"); heart = c("#FF4D8D"); heartShine = c("#FFD1E3")
        }
    }
}

/// A small original 5×7 pixel font for the arcade HUD (uppercase letters, digits and common punctuation).
private enum PixelFont {
    static let glyphs: [Character: [UInt8]] = [
        "A": [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11], "B": [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
        "C": [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E], "D": [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
        "E": [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F], "F": [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
        "G": [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F], "H": [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        "I": [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E], "J": [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C],
        "K": [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11], "L": [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
        "M": [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11], "N": [0x11, 0x11, 0x19, 0x15, 0x13, 0x11, 0x11],
        "O": [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E], "P": [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
        "Q": [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D], "R": [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
        "S": [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E], "T": [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
        "U": [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E], "V": [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
        "W": [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A], "X": [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
        "Y": [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04], "Z": [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
        "0": [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E], "1": [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
        "2": [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F], "3": [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
        "4": [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02], "5": [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
        "6": [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E], "7": [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        "8": [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E], "9": [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
        " ": [0, 0, 0, 0, 0, 0, 0], "-": [0, 0, 0, 0x0E, 0, 0, 0], ".": [0, 0, 0, 0, 0, 0x0C, 0x0C],
        ",": [0, 0, 0, 0, 0x0C, 0x04, 0x08], ":": [0, 0x0C, 0x0C, 0, 0x0C, 0x0C, 0], "!": [0x04, 0x04, 0x04, 0x04, 0x04, 0, 0x04],
        "?": [0x0E, 0x11, 0x01, 0x02, 0x04, 0, 0x04], "'": [0x04, 0x04, 0x08, 0, 0, 0, 0], "/": [0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10],
        "&": [0x0C, 0x12, 0x14, 0x08, 0x15, 0x12, 0x0D], "#": [0x0A, 0x0A, 0x1F, 0x0A, 0x1F, 0x0A, 0x0A],
        "+": [0, 0x04, 0x04, 0x1F, 0x04, 0x04, 0], "_": [0, 0, 0, 0, 0, 0, 0x1F], "(": [0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02],
        ")": [0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08], "*": [0, 0x04, 0x15, 0x0E, 0x15, 0x04, 0], "=": [0, 0, 0x1F, 0, 0x1F, 0, 0],
        "@": [0x0E, 0x11, 0x17, 0x15, 0x17, 0x10, 0x0E],
    ]

    /// Uppercased, diacritics folded, dashes and ellipses simplified, whitespace collapsed.
    static func normalized(_ text: String) -> String {
        let folded = text.uppercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\u{2014}", with: "-").replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2026}", with: "...").replacingOccurrences(of: "\u{2019}", with: "'")
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func supports(_ text: String) -> Bool { text.allSatisfy { glyphs[$0] != nil } }

    /// Glyphs are drawn twice, nudged sideways by this much, for a chunkier arcade weight.
    static func bold(_ cell: CGFloat) -> CGFloat { max(1, (cell / 2).rounded()) }
    static func advance(_ cell: CGFloat) -> CGFloat { 6 * cell + bold(cell) }
    static func width(_ count: Int, cell: CGFloat) -> CGFloat { count > 0 ? CGFloat(count) * advance(cell) - cell : 0 }

    static func draw(_ text: String, x: CGFloat, top: CGFloat, cell: CGFloat, color: CGColor, in ctx: CGContext) {
        var cells: [CGRect] = []
        for (i, ch) in text.enumerated() {
            guard let rows = glyphs[ch] else { continue }
            let gx = x + CGFloat(i) * advance(cell)
            for (row, bits) in rows.enumerated() {
                for col in 0..<5 where bits & (0x10 >> UInt8(col)) != 0 {
                    cells.append(CGRect(x: gx + CGFloat(col) * cell, y: top - CGFloat(row + 1) * cell, width: cell + bold(cell), height: cell))
                }
            }
        }
        guard !cells.isEmpty else { return }
        ctx.setFillColor(color)
        ctx.fill(cells)
    }
}

private enum RetroFrameKit {
    static func color(_ hex: String) -> CGColor { FrameRenderer.color(hex) }

    /// Restricts drawing to the chrome so nothing lands under (possibly transparent) screenshots.
    static func excludeScreen(_ c: FrameCanvas) {
        c.ctx.addRect(c.card)
        c.ctx.addRect(c.screen)
        c.ctx.clip(using: .evenOdd)
    }

    static func font(_ postScriptName: String, size: CGFloat) -> CTFont {
        CTFontCreateWithName(postScriptName as CFString, max(size, 1), nil)
    }

    /// Shortens `text` at character boundaries (adding `suffix`) so it fits `maxWidth`; "" when nothing fits.
    static func fitted(_ text: String, font: CTFont, maxWidth: CGFloat, suffix: String = "…") -> String {
        guard maxWidth > 0, !text.isEmpty else { return "" }
        if FrameRenderer.textWidth(text, font: font) <= maxWidth { return text }
        let chars = Array(text)
        func candidate(_ n: Int) -> String { String(chars.prefix(n)).trimmingCharacters(in: .whitespaces) + suffix }
        var lo = 0, hi = chars.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if FrameRenderer.textWidth(candidate(mid), font: font) <= maxWidth { lo = mid } else { hi = mid - 1 }
        }
        return lo == 0 ? "" : candidate(lo)
    }

    static func verticalGradient(_ rect: CGRect, radius: CGFloat, top: CGColor, bottom: CGColor, in ctx: CGContext) {
        guard rect.width > 0, rect.height > 0,
              let g = CGGradient(colorsSpace: ColorSpaces.sRGB, colors: [top, bottom] as CFArray, locations: [0, 1]) else { return }
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
    }

    static func fillPolygon(_ points: [CGPoint], _ color: CGColor, in ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.beginPath()
        ctx.move(to: first)
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    /// A bevelled ring between `outer` (rounded) and `inner`, one tone per side.
    static func chamfer(outer o: CGRect, inner i: CGRect, radius: CGFloat, top: CGColor, left: CGColor, bottom: CGColor,
                        right: CGColor, in ctx: CGContext) {
        guard o.width > 0, o.height > 0 else { return }
        let r = max(0, min(radius, min(o.width, o.height) / 2))
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: o, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
        fillPolygon([CGPoint(x: o.minX, y: o.minY), CGPoint(x: o.maxX, y: o.minY), CGPoint(x: i.maxX, y: i.minY),
                     CGPoint(x: i.minX, y: i.minY)], bottom, in: ctx)
        fillPolygon([CGPoint(x: o.maxX, y: o.minY), CGPoint(x: o.maxX, y: o.maxY), CGPoint(x: i.maxX, y: i.maxY),
                     CGPoint(x: i.maxX, y: i.minY)], right, in: ctx)
        fillPolygon([CGPoint(x: o.minX, y: o.minY), CGPoint(x: o.minX, y: o.maxY), CGPoint(x: i.minX, y: i.maxY),
                     CGPoint(x: i.minX, y: i.minY)], left, in: ctx)
        fillPolygon([CGPoint(x: o.minX, y: o.maxY), CGPoint(x: o.maxX, y: o.maxY), CGPoint(x: i.maxX, y: i.maxY),
                     CGPoint(x: i.minX, y: i.maxY)], top, in: ctx)
        ctx.restoreGState()
    }

    // MARK: Screen effects

    static func scanlines(_ rect: CGRect, k: CGFloat, in ctx: CGContext) {
        let period = max(2, (3 * k).rounded())
        let line = max(1, (period / 3).rounded())
        var rects: [CGRect] = []
        var y = rect.maxY - line
        while y > rect.minY - line {
            rects.append(CGRect(x: rect.minX, y: y, width: rect.width, height: line))
            y -= period
        }
        ctx.setFillColor(color("#00000012"))
        ctx.fill(rects)
    }

    static func vignette(_ rect: CGRect, in ctx: CGContext) {
        guard rect.width > 0, rect.height > 0,
              let g = CGGradient(colorsSpace: ColorSpaces.sRGB, colors: [color("#00000000"), color("#00000012")] as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: rect.width / 2, y: rect.height / 2)
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0.75, endCenter: .zero, endRadius: 1.45,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // MARK: Retro parts

    static func led(at p: CGPoint, diameter d: CGFloat, k: CGFloat, in ctx: CGContext) {
        let r = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 5 * k, color: color("#4BE36ECC"))
        ctx.setFillColor(color("#4BE36E"))
        ctx.fillEllipse(in: r)
        ctx.restoreGState()
        ctx.setFillColor(color("#D9FFE3"))
        ctx.fillEllipse(in: CGRect(x: r.minX + d * 0.22, y: r.minY + d * 0.5, width: d * 0.3, height: d * 0.3))
    }

    static func powerButton(_ r: CGRect, k: CGFloat, dark: Bool, in ctx: CGContext) {
        FrameRenderer.fillRounded(r.insetBy(dx: -1.5 * k, dy: -1.5 * k), radius: 4 * k, color(dark ? "#18181A" : "#A99E86"), in: ctx)
        verticalGradient(r, radius: 3 * k, top: color(dark ? "#4A4A4F" : "#EDE6D6"), bottom: color(dark ? "#303034" : "#CFC5AE"), in: ctx)
        FrameRenderer.fill(CGRect(x: r.minX + 3 * k, y: r.maxY - max(1, k), width: r.width - 6 * k, height: max(1, k)),
                           color(dark ? "#5E5E64" : "#FFFDF7"), in: ctx)
    }

    static func knob(_ r: CGRect, angle: CGFloat, k: CGFloat, dark: Bool, in ctx: CGContext) {
        ctx.setFillColor(color(dark ? "#00000066" : "#7A6F5A55"))
        ctx.fillEllipse(in: r.offsetBy(dx: 0.5 * k, dy: -1.2 * k))
        ctx.saveGState()
        ctx.addEllipse(in: r)
        ctx.clip()
        if let g = CGGradient(colorsSpace: ColorSpaces.sRGB,
                              colors: [color(dark ? "#55555B" : "#F3EDE0"), color(dark ? "#232326" : "#BBB099")] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
        }
        ctx.restoreGState()
        let inner = r.insetBy(dx: r.width * 0.18, dy: r.height * 0.18)
        ctx.setFillColor(color(dark ? "#3A3A3F" : "#E2DAC8"))
        ctx.fillEllipse(in: inner)
        let c = CGPoint(x: r.midX, y: r.midY), rad = r.width / 2
        ctx.setStrokeColor(color(dark ? "#B4B4BA" : "#6F6551"))
        ctx.setLineWidth(max(1, 1.4 * k))
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: c.x + cos(angle) * rad * 0.2, y: c.y + sin(angle) * rad * 0.2))
        ctx.addLine(to: CGPoint(x: c.x + cos(angle) * rad * 0.68, y: c.y + sin(angle) * rad * 0.68))
        ctx.strokePath()
    }

    // MARK: Pixel parts

    static func pixelUnit(_ k: CGFloat) -> CGFloat { max(1, (4 * k).rounded()) }

    /// A rectangle with its four corner cells knocked out (a one-step pixel-art rounded corner).
    static func pixelRect(_ r: CGRect, u: CGFloat, _ color: CGColor, in ctx: CGContext) {
        guard r.width > 0, r.height > 0 else { return }
        ctx.setFillColor(color)
        guard r.width > 2 * u, r.height > 2 * u else { ctx.fill(r); return }
        ctx.fill([CGRect(x: r.minX, y: r.minY + u, width: r.width, height: r.height - 2 * u),
                  CGRect(x: r.minX + u, y: r.minY, width: r.width - 2 * u, height: r.height)])
    }

    static let heartRows = [".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."]

    static func pixelHeart(x: CGFloat, top: CGFloat, cell: CGFloat, fill: CGColor, shine: CGColor, in ctx: CGContext) {
        var cells: [CGRect] = []
        for (row, line) in heartRows.enumerated() {
            for (col, ch) in line.enumerated() where ch == "#" {
                cells.append(CGRect(x: x + CGFloat(col) * cell, y: top - CGFloat(row + 1) * cell, width: cell, height: cell))
            }
        }
        ctx.setFillColor(fill)
        ctx.fill(cells)
        ctx.setFillColor(shine)
        ctx.fill(CGRect(x: x + cell, y: top - 2 * cell, width: cell, height: cell))
    }

    // MARK: Handheld parts

    /// Draws the D-pad and returns the bounds of its well.
    @discardableResult
    static func dpad(center p: CGPoint, size s: CGFloat, unit u: CGFloat, dark: Bool, in ctx: CGContext) -> CGRect {
        let wellD = s * 1.3
        let well = CGRect(x: p.x - wellD / 2, y: p.y - wellD / 2, width: wellD, height: wellD)
        ctx.setFillColor(color(dark ? "#3E4166" : "#F8F7FC"))
        ctx.fillEllipse(in: well.offsetBy(dx: 0, dy: -max(1, u)))
        ctx.setFillColor(color(dark ? "#212339" : "#D2CEDD"))
        ctx.fillEllipse(in: well)

        let arm = s * 0.34, rr = arm * 0.22
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: p.x - s / 2, y: p.y - arm / 2, width: s, height: arm), cornerWidth: rr, cornerHeight: rr)
        path.addRoundedRect(in: CGRect(x: p.x - arm / 2, y: p.y - s / 2, width: arm, height: s), cornerWidth: rr, cornerHeight: rr)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -2 * u)
        ctx.addPath(path)
        ctx.setFillColor(color("#00000050"))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setFillColor(color(dark ? "#15161F" : "#3A3E4D"))
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let g = CGGradient(colorsSpace: ColorSpaces.sRGB, colors: [color("#FFFFFF2A"), color("#FFFFFF00")] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: p.x, y: p.y + s / 2), end: CGPoint(x: p.x, y: p.y - s / 4), options: [])
        }
        ctx.restoreGState()

        let dimple = arm * 0.5
        ctx.setFillColor(color("#0000002E"))
        ctx.fillEllipse(in: CGRect(x: p.x - dimple / 2, y: p.y - dimple / 2, width: dimple, height: dimple))

        let tipInset = arm * 0.2, depth = arm * 0.3, half = arm * 0.2
        for (dx, dy) in [(0.0, 1.0), (0.0, -1.0), (-1.0, 0.0), (1.0, 0.0)] as [(CGFloat, CGFloat)] {
            let tip = CGPoint(x: p.x + dx * (s / 2 - tipInset), y: p.y + dy * (s / 2 - tipInset))
            let base = CGPoint(x: tip.x - dx * depth, y: tip.y - dy * depth)
            fillPolygon([tip, CGPoint(x: base.x - dy * half, y: base.y + dx * half), CGPoint(x: base.x + dy * half, y: base.y - dx * half)],
                        color("#FFFFFF33"), in: ctx)
        }
        return well
    }

    /// Draws two big round buttons on a tilted capsule and returns the capsule's bounding box.
    @discardableResult
    static func faceButtons(center p: CGPoint, unit u: CGFloat, dark: Bool, in ctx: CGContext) -> CGRect {
        let d = 24 * u, dx = 14 * u, dy = 8 * u
        let len = 2 * hypot(dx, dy) + d + 10 * u, h = d + 10 * u
        let angle = atan2(dy, dx)
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: angle)
        let capsule = CGRect(x: -len / 2, y: -h / 2, width: len, height: h)
        FrameRenderer.fillRounded(capsule.offsetBy(dx: 0, dy: -max(1, u)), radius: h / 2, color(dark ? "#3E4166" : "#F8F7FC"), in: ctx)
        FrameRenderer.fillRounded(capsule, radius: h / 2, color(dark ? "#212339" : "#D2CEDD"), in: ctx)
        ctx.restoreGState()

        let letterFont = font("AvenirNext-Bold", size: d * 0.42)
        for (offset, hex, letter) in [(CGPoint(x: -dx, y: -dy), "#2DB7A6", "B"), (CGPoint(x: dx, y: dy), "#FF6F61", "A")] {
            let r = CGRect(x: p.x + offset.x - d / 2, y: p.y + offset.y - d / 2, width: d, height: d)
            ctx.setFillColor(color("#00000048"))
            ctx.fillEllipse(in: r.offsetBy(dx: 0, dy: -2 * u))
            ctx.setFillColor(color(hex))
            ctx.fillEllipse(in: r)
            ctx.saveGState()
            ctx.addEllipse(in: r)
            ctx.clip()
            if let g = CGGradient(colorsSpace: ColorSpaces.sRGB, colors: [color("#FFFFFF55"), color("#FFFFFF00"), color("#0000002A")] as CFArray,
                                  locations: [0, 0.5, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
            }
            ctx.restoreGState()
            FrameRenderer.drawText(letter, font: letterFont, color: color("#FFFFFFD9"), x: r.midX, midY: r.midY, align: .center, in: ctx)
        }
        let corners = [CGPoint(x: -len / 2, y: -h / 2), CGPoint(x: len / 2, y: -h / 2), CGPoint(x: -len / 2, y: h / 2), CGPoint(x: len / 2, y: h / 2)]
            .map { CGPoint(x: p.x + $0.x * cos(angle) - $0.y * sin(angle), y: p.y + $0.x * sin(angle) + $0.y * cos(angle)) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    static func pill(_ r: CGRect, k: CGFloat, dark: Bool, in ctx: CGContext) {
        FrameRenderer.fillRounded(r.offsetBy(dx: 0, dy: -max(1, k)), radius: r.height / 2, color("#00000040"), in: ctx)
        FrameRenderer.fillRounded(r, radius: r.height / 2, color(dark ? "#4B4E75" : "#9D99AE"), in: ctx)
        FrameRenderer.fillRounded(CGRect(x: r.minX + r.height * 0.6, y: r.maxY - r.height * 0.42, width: r.width - r.height * 1.2,
                                         height: r.height * 0.22), radius: r.height * 0.11, color("#FFFFFF38"), in: ctx)
    }

    static func roundButton(_ r: CGRect, k: CGFloat, dark: Bool, in ctx: CGContext) {
        ctx.setFillColor(color("#00000040"))
        ctx.fillEllipse(in: r.offsetBy(dx: 0, dy: -max(1, k)))
        ctx.setFillColor(color(dark ? "#4B4E75" : "#9D99AE"))
        ctx.fillEllipse(in: r)
        ctx.setFillColor(color("#FFFFFF30"))
        ctx.fillEllipse(in: CGRect(x: r.minX + r.width * 0.25, y: r.midY, width: r.width * 0.5, height: r.height * 0.35))
    }

    static let grilleRows = 3, grilleCols = 5

    static func grilleRect(center p: CGPoint, k: CGFloat) -> CGRect {
        let pitch = 6 * k, hole = 2.8 * k
        let w = CGFloat(grilleCols - 1) * pitch + pitch / 2 + hole, h = CGFloat(grilleRows - 1) * pitch + hole
        return CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
    }

    static func grille(center p: CGPoint, k: CGFloat, dark: Bool, in ctx: CGContext) {
        let pitch = 6 * k, hole = 2.8 * k
        let box = grilleRect(center: p, k: k)
        for row in 0..<grilleRows {
            for col in 0..<grilleCols {
                let x = box.minX + CGFloat(col) * pitch + (row % 2 == 1 ? pitch / 2 : 0)
                let y = box.maxY - hole - CGFloat(row) * pitch
                let r = CGRect(x: x, y: y, width: hole, height: hole)
                ctx.setFillColor(color(dark ? "#3E4166" : "#FFFFFF"))
                ctx.fillEllipse(in: r.offsetBy(dx: 0, dy: -max(0.5, 0.6 * k)))
                ctx.setFillColor(color(dark ? "#10111C" : "#8E89A0"))
                ctx.fillEllipse(in: r)
            }
        }
    }
}
