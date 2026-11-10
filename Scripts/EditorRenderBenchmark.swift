import AppKit
import Foundation

// Offscreen CPU benchmark of the editor's render path. `Scripts/benchmark-editor-render.sh` compiles this file
// with the GlintCore sources of the variant under test into one module, so internal types are visible. It opens no
// window, captures nothing and reads no user data: every input is synthetic and written under the run directory.
// The numbers are CPU time of one process on one host, not input latency, frame pacing or presentation.

private struct Record: Codable {
    var scenario: String
    var round: Int
    var annotations: Int
    var source: String
    var size: String
    var cache: Bool
    var sourceNeedsConversion: Bool
    /// Warm per-frame milliseconds, in order, for the scenario's operation.
    var frames: [Double]
    /// Milliseconds of the first operation of the process, which includes one-off setup.
    var firstMS: Double
    /// Milliseconds by label (stage, background style, ...), each the median of its repeats.
    var labelled: [String: Double]
    var peakRSSMB: Double
    var footprintMB: Double
}

private struct Aggregate: Codable {
    var scenario: String
    var annotations: Int
    var source: String
    var size: String
    var cache: Bool
    var processes: Int
    var warmFrames: Int
    var warmMedianMS: Double?
    var warmP95MS: Double?
    var firstMedianMS: Double
    var labelledMedianMS: [String: Double]
    var peakRSSMedianMB: Double
    var peakRSSMaxMB: Double
    var footprintMedianMB: Double
}

private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
private func ms(since start: UInt64) -> Double { Double(now() - start) / 1_000_000 }

private func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = now()
    let value = try body()
    return (value, ms(since: start))
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded(.up)))]
}

private func memoryMB() -> (peak: Double, footprint: Double) {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return (Double(usage.ru_maxrss) / 1_048_576, Double(info.phys_footprint) / 1_048_576)
}

// MARK: Synthetic inputs

/// Looks like a screenshot: light window, dark title bar, sidebar, rows of text-like blocks, a colour chart.
private func makeCapture(width: Int, height: Int, displayP3: Bool) -> CGImage {
    let space = CGColorSpace(name: displayP3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB) ?? ColorSpaces.sRGB
    // BGRA premultiplied, the layout ScreenCaptureKit delivers.
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: info)!
    let w = CGFloat(width), h = CGFloat(height)
    ctx.setFillColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 1)
    ctx.fill(CGRect(x: 0, y: h - h * 0.05, width: w, height: h * 0.05))
    ctx.setFillColor(red: 0.88, green: 0.89, blue: 0.92, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w * 0.18, height: h * 0.95))
    var rng = SplitMix64(seed: 7)
    let row = max(h / 60, 8)
    var y = h * 0.92
    while y > row * 2 {
        var x = w * 0.2
        while x < w * 0.95 {
            let blockW = row * CGFloat(2 + Int(rng.next() % 9))
            let shade = 0.2 + CGFloat(rng.next() % 50) / 100
            ctx.setFillColor(red: shade, green: shade, blue: shade + 0.1, alpha: 1)
            ctx.fill(CGRect(x: x, y: y, width: min(blockW, w * 0.95 - x), height: row * 0.55))
            x += blockW + row
        }
        y -= row * 1.6
    }
    let colours: [(CGFloat, CGFloat, CGFloat)] = [(0.2, 0.5, 0.95), (0.95, 0.4, 0.3), (0.3, 0.8, 0.5), (0.95, 0.75, 0.2)]
    for (i, c) in colours.enumerated() {
        ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        ctx.fill(CGRect(x: w * (0.22 + 0.17 * CGFloat(i)), y: h * 0.08, width: w * 0.14, height: h * (0.12 + 0.05 * CGFloat(i))))
    }
    return ctx.makeImage()!
}

/// `magnifier` adds a lens whose snapshot is a full-size image, which the render cache deliberately does not keep.
private func makeAnnotations(_ count: Int, size: CGSize, magnifier: Bool = false) -> [Annotation] {
    var rng = SplitMix64(seed: 42)
    func unit() -> CGFloat { CGFloat(rng.next() % 1000) / 1000 }
    func rect(_ widthFraction: CGFloat, _ heightFraction: CGFloat) -> CGRect {
        let w = size.width * widthFraction, h = size.height * heightFraction
        return CGRect(x: (size.width - w) * unit(), y: (size.height - h) * unit(), width: w, height: h)
    }
    func point() -> CGPoint { CGPoint(x: size.width * unit(), y: size.height * unit()) }
    let scale = size.width / 2560
    var result: [Annotation] = []
    for i in 0..<count {
        var style = AnnotationStyle(strokeWidth: 6 * Double(scale), fontSize: 36 * Double(scale), intensity: 14 * Double(scale))
        let kind: AnnotationKind
        switch i % 9 {
        case 0: kind = .rectangle(rect(0.12, 0.08))
        case 1: kind = .arrow(from: point(), to: point())
        case 2: kind = .text(origin: point(), string: "Check value \(i)", maxWidth: 0)
        case 3: kind = .redact(rect(0.1, 0.03))
        case 4: kind = .blur(rect(0.1, 0.05))
        case 5: kind = .pixelate(rect(0.08, 0.04))
        case 6: kind = .ellipse(rect(0.07, 0.07))
        case 7: kind = .counter(center: point(), number: i)
        default:
            style.color = RGBAColor(r: 1, g: 0.85, b: 0.1, a: 1)
            kind = .highlighter([point(), point(), point()])
        }
        result.append(Annotation(z: i, kind: kind, style: style))
    }
    if magnifier {
        let source = CGRect(x: size.width * 0.3, y: size.height * 0.3, width: size.width * 0.05, height: size.width * 0.05)
        let inset = CGRect(x: size.width * 0.5, y: size.height * 0.45, width: size.width * 0.15, height: size.width * 0.15)
        result.append(Annotation(z: count, kind: .magnify(Magnifier(source: source, inset: inset)),
                                 style: AnnotationStyle(strokeWidth: 6 * Double(scale))))
    }
    return result
}

private func writeImage(_ image: CGImage, to url: URL, type: String, quality: Double) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(destination)
}

private struct Assets {
    var background: URL
    var wallpaper: URL
    var wallpaperType: String
}

/// A 5K picture for the image background and one for the desktop wallpaper (HEIC when this host can encode it).
private func prepareAssets(in directory: URL) throws -> Assets {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let background = directory.appendingPathComponent("background.jpg")
    let heic = directory.appendingPathComponent("wallpaper.heic")
    let jpeg = directory.appendingPathComponent("wallpaper.jpg")
    if !FileManager.default.fileExists(atPath: background.path) {
        guard writeImage(makeCapture(width: 5120, height: 2880, displayP3: false), to: background,
                         type: "public.jpeg", quality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
    }
    if !FileManager.default.fileExists(atPath: heic.path), !FileManager.default.fileExists(atPath: jpeg.path) {
        let picture = makeCapture(width: 5120, height: 2880, displayP3: true)
        if !writeImage(picture, to: heic, type: "public.heic", quality: 0.8),
           !writeImage(picture, to: jpeg, type: "public.jpeg", quality: 0.85) { throw CocoaError(.fileWriteUnknown) }
    }
    let useHEIC = FileManager.default.fileExists(atPath: heic.path)
    return Assets(background: background, wallpaper: useHEIC ? heic : jpeg, wallpaperType: useHEIC ? "heic" : "jpeg")
}

// MARK: Render

private struct Workload {
    var capture: CGImage
    var annotations: [Annotation]
    var settings: RenderSettings
    var backgroundImage: CGImage?
    var wallpaper: CGImage?
    var backingScale: CGFloat = 2
    #if RENDER_CACHE
    var cache: RenderCache?
    #endif

    /// The scale the editor renders its preview at: the canvas fitted into the default 1800 x 1200 target.
    func previewScale(for settings: RenderSettings) -> Double {
        let estimate = Compositor.layout(contentSize: capture.pixelSize, insetApplied: settings.inset >= 1,
                                         settings: settings, backingScale: backingScale)
        let fit = min(1800 / estimate.canvasSize.width, 1200 / estimate.canvasSize.height)
        return Double(max(0.05, min(1, fit)))
    }

    @discardableResult
    func render(_ settings: RenderSettings, annotations: [Annotation]? = nil, preview: Bool = true) throws -> CGImage {
        var s = settings
        if preview { s.outputScale = settings.outputScale * previewScale(for: settings) }
        let list = annotations ?? self.annotations
        #if RENDER_CACHE
        return try Compositor.renderDetailed(image: capture, settings: s, annotations: list, backingScale: backingScale,
                                             backgroundImage: backgroundImage, wallpaper: wallpaper, cache: cache).image
        #else
        return try Compositor.renderDetailed(image: capture, settings: s, annotations: list, backingScale: backingScale,
                                             backgroundImage: backgroundImage, wallpaper: wallpaper).image
        #endif
    }
}

private func grain() -> BackgroundStyle {
    BackgroundCatalog.preset(id: "pattern-noise")?.style ?? .transparent
}

private func backgrounds(imagePath: String) -> [(String, BackgroundStyle)] {
    [
        ("solid", .solid(RGBAColor(r: 0.12, g: 0.16, b: 0.24))),
        ("gradient", BackgroundCatalog.defaultStyle),
        ("mesh", BackgroundCatalog.preset(id: "mesh-nebula")?.style ?? .transparent),
        ("grain", grain()),
        ("image", .image(path: imagePath, fit: .fill)),
    ]
}

// MARK: Scenarios

@main
private enum EditorRenderBenchmark {
    static let scenarios = ["padding-drag", "shadow-drag", "annotation-drag", "padding-drag-magnifier",
                            "background-cycle", "export-after-preview", "stages"]

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2, args[0] == "--summarize" {
            try summarize(path: args[1])
            return
        }
        guard args.count == 7, scenarios.contains(args[0]), let round = Int(args[1]), let count = Int(args[2]),
              (0...200).contains(count), ["p3", "srgb"].contains(args[3]),
              let frames = Int(args[5]), (1...500).contains(frames) else {
            throw NSError(domain: "EditorRenderBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Expected: <scenario> <round> <annotations> <p3|srgb> <WxH> <frames> <asset-directory>"])
        }
        let dimensions = args[4].split(separator: "x").compactMap { Int($0) }
        guard dimensions.count == 2, dimensions.allSatisfy({ (64...16384).contains($0) }) else {
            throw NSError(domain: "EditorRenderBenchmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad size"])
        }
        let record = try run(scenario: args[0], round: round, annotations: count, source: args[3],
                             size: (dimensions[0], dimensions[1]), frames: frames,
                             assets: try prepareAssets(in: URL(fileURLWithPath: args[6])))
        FileHandle.standardOutput.write(try JSONEncoder().encode(record) + Data("\n".utf8))
    }

    static func run(scenario: String, round: Int, annotations count: Int, source: String, size: (Int, Int),
                    frames: Int, assets: Assets) throws -> Record {
        let capture = makeCapture(width: size.0, height: size.1, displayP3: source == "p3")
        let imageBackground = GlintImageIO.load(url: assets.background)
        var workload = Workload(capture: capture,
                                annotations: makeAnnotations(count, size: capture.pixelSize,
                                                             magnifier: scenario == "padding-drag-magnifier"),
                                settings: RenderSettings(), backgroundImage: imageBackground)
        #if RENDER_CACHE
        workload.cache = RenderCache()
        let cacheEnabled = true
        #else
        let cacheEnabled = false
        #endif
        var base = RenderSettings()
        base.padding = 48
        var record = Record(scenario: scenario, round: round, annotations: count, source: source,
                            size: "\(size.0)x\(size.1)", cache: cacheEnabled,
                            sourceNeedsConversion: capture.glintSRGB() !== capture, frames: [], firstMS: 0,
                            labelled: [:], peakRSSMB: 0, footprintMB: 0)

        switch scenario {
        case "padding-drag", "shadow-drag", "padding-drag-magnifier":
            for i in 0..<frames {
                var s = base
                if scenario == "shadow-drag" { s.shadow.strength = Double(20 + (i * 7) % 60) } else { s.padding = Double(24 + i % 24) }
                let (_, elapsed) = try timed { try workload.render(s) }
                if i == 0 { record.firstMS = elapsed } else { record.frames.append(elapsed) }
            }
        case "annotation-drag":
            var moved = workload.annotations
            for i in 0..<frames {
                if case .rectangle(let r)? = moved.first?.kind { moved[0].kind = .rectangle(r.offsetBy(dx: 3, dy: 0)) }
                else if !moved.isEmpty { moved[0].kind = .redact(CGRect(x: 200 + i * 3, y: 300, width: 400, height: 80)) }
                var s = base
                s.padding = Double(24 + i % 24)
                let (_, elapsed) = try timed { try workload.render(s, annotations: moved) }
                if i == 0 { record.firstMS = elapsed } else { record.frames.append(elapsed) }
            }
        case "background-cycle":
            var samples: [String: [Double]] = [:]
            for pass in 0..<max(frames / 5, 2) {
                for (name, style) in backgrounds(imagePath: assets.background.path) {
                    var s = base
                    s.background = style
                    let (_, elapsed) = try timed { try workload.render(s) }
                    if pass == 0 { record.firstMS = max(record.firstMS, elapsed) } else { samples[name, default: []].append(elapsed) }
                }
                var wallpaperSettings = base
                wallpaperSettings.usesDesktopWallpaper = true
                if workload.wallpaper == nil, case .success(let image) = DesktopWallpaper.load(url: assets.wallpaper) {
                    workload.wallpaper = image
                }
                let (_, elapsed) = try timed { try workload.render(wallpaperSettings) }
                if pass > 0 { samples["wallpaper", default: []].append(elapsed) }
            }
            record.labelled = samples.mapValues(median)
        case "export-after-preview":
            for i in 0..<frames {
                var s = base
                s.padding = Double(24 + i % 24)
                try workload.render(s)
                let (_, elapsed) = try timed { try workload.render(s, preview: false) }
                if i == 0 { record.firstMS = elapsed } else { record.frames.append(elapsed) }
            }
        default:
            record.labelled = try stages(workload: workload, base: base, assets: assets, repeats: max(frames / 5, 3))
        }
        (record.peakRSSMB, record.footprintMB) = memoryMB()
        return record
    }

    /// The preparation, annotation baking, composition and presentation proxies of one preview, measured separately.
    static func stages(workload: Workload, base: RenderSettings, assets: Assets, repeats: Int) throws -> [String: Double] {
        var labelled: [String: Double] = [:]
        func measure(_ label: String, _ body: () throws -> Void) {
            var samples: [Double] = []
            for _ in 0..<repeats { samples.append(timed { try? body() }.1) }
            labelled[label] = median(samples)
        }
        var plain = workload
        #if RENDER_CACHE
        plain.cache = nil
        #endif
        let capture = workload.capture
        measure("prepare: sRGB normalise") { _ = capture.glintSRGB() }
        let normalised = capture.glintSRGB()
        measure("annotation bake (full resolution)") {
            _ = AnnotationRenderer.bakeLayers(source: normalised, annotations: workload.annotations, region: nil, fill: .clear)
        }
        var preview: CGImage?
        measure("preview render, total") { preview = try plain.render(base) }
        var flat = plain
        flat.annotations = []
        measure("preview render, no annotations") { _ = try flat.render(base) }
        measure("full-resolution render, total") { _ = try plain.render(base, preview: false) }
        var grained = base
        grained.background = grain()
        measure("preview render, grain background") { _ = try plain.render(grained) }
        var solid = base
        solid.background = .solid(RGBAColor(r: 0.12, g: 0.16, b: 0.24))
        measure("preview render, solid background") { _ = try plain.render(solid) }
        measure("decode: image background (5K JPEG)") { _ = GlintImageIO.load(url: assets.background) }
        measure("decode: wallpaper (5K \(assets.wallpaperType.uppercased()))") { _ = DesktopWallpaper.load(url: assets.wallpaper) }
        measure("thumbnail: capture into 440 x 248") {
            guard let ctx = GlintBitmap.makeContext(width: 440, height: 248) else { return }
            ctx.interpolationQuality = .default
            ctx.draw(capture, in: CGRect(x: 0, y: 0, width: 440, height: 248))
            _ = ctx.makeImage()
        }
        if let preview {
            measure("present proxy: preview into a 1800 x 1200 bitmap") {
                guard let ctx = GlintBitmap.makeContext(width: 1800, height: 1200) else { return }
                ctx.draw(preview, in: CGRect(x: 0, y: 0, width: 1800, height: 1200))
                _ = ctx.makeImage()
            }
        }
        return labelled
    }

    // MARK: Summary

    static func summarize(path: String) throws {
        let decoder = JSONDecoder()
        let records = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
            .map { try decoder.decode(Record.self, from: Data($0.utf8)) }
        struct Key: Hashable { var scenario: String; var annotations: Int; var source: String; var size: String; var cache: Bool }
        let grouped = Dictionary(grouping: records) {
            Key(scenario: $0.scenario, annotations: $0.annotations, source: $0.source, size: $0.size, cache: $0.cache)
        }
        let aggregates = grouped.map { key, group -> Aggregate in
            let frames = group.flatMap(\.frames)
            var labels: [String: [Double]] = [:]
            for record in group { for (label, value) in record.labelled { labels[label, default: []].append(value) } }
            return Aggregate(scenario: key.scenario, annotations: key.annotations, source: key.source, size: key.size,
                             cache: key.cache, processes: group.count, warmFrames: frames.count,
                             warmMedianMS: frames.isEmpty ? nil : median(frames),
                             warmP95MS: frames.isEmpty ? nil : percentile(frames, 0.95),
                             firstMedianMS: median(group.map(\.firstMS)), labelledMedianMS: labels.mapValues(median),
                             peakRSSMedianMB: median(group.map(\.peakRSSMB)), peakRSSMaxMB: group.map(\.peakRSSMB).max() ?? 0,
                             footprintMedianMB: median(group.map(\.footprintMB)))
        }.sorted { ($0.scenario, $0.annotations) < ($1.scenario, $1.annotations) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(aggregates) + Data("\n".utf8))
    }
}
