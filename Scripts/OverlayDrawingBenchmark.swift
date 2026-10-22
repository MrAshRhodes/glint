import AppKit
import Foundation

private struct Sample: Codable {
    let scenario: String
    let round: Int
    let phase: String
    let frame: Int
    let drawMode: String
    let viewSetupMS: Double
    let updateMS: Double
    let drawMS: Double
    let elapsedMS: Double
    let dirtyRectCount: Int

    var updateAndDrawMS: Double { updateMS + drawMS }
}

@main
private enum OverlayDrawingBenchmark {
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func milliseconds(since start: UInt64) -> Double { Double(now() - start) / 1_000_000 }

    @MainActor
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2, args[0] == "--summarize" {
            try summarize(path: args[1])
            return
        }
        guard args.count == 4, ["area-cursor", "area-selection", "window-hover"].contains(args[0]),
              let frames = Int(args[1]), (1...1000).contains(frames),
              let round = Int(args[2]), (1...30).contains(round),
              ["full", "damage"].contains(args[3]) else {
            throw NSError(domain: "OverlayDrawingBenchmark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected scenario, warm frame count, round and draw mode."])
        }
        let scenario = args[0]
        let drawMode = args[3]
        let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "OverlayDrawingBenchmark", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to create offscreen bitmap context."])
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)

        // No NSApplication.run, panels, window enumeration, capture, or posted events.
        let started = now()
        let session = SelectionSession(mode: scenario == "window-hover" ? .window : .area, lastArea: nil)
        let view = OverlayView(frame: bounds, session: session, screenFrameCG: bounds, scale: scale)
        let viewSetupMS = milliseconds(since: started)
        var samples: [Sample] = []
        for frame in 0...frames {
            autoreleasepool {
                let updateStart = now()
                update(session, scenario: scenario, frame: frame)
                var damage = [bounds]
                #if OVERLAY_DAMAGE_TRACKING
                damage = view.refresh()
                #endif
                let updateMS = milliseconds(since: updateStart)
                let regions = drawMode == "full" || frame == 0 ? [bounds] : damage
                let drawStart = now()
                if !regions.isEmpty {
                    let dirtyBounds = regions.reduce(CGRect.null) { $0.union($1) }
                    context.cgContext.saveGState()
                    // Model one AppKit draw with a disjoint clip, not one draw per overlapping strip.
                    context.cgContext.clip(to: regions)
                    // Direct draw does not get AppKit's backing-store clearing.
                    context.cgContext.clear(dirtyBounds)
                    view.draw(dirtyBounds)
                    context.cgContext.restoreGState()
                }
                context.cgContext.flush()
                let drawMS = milliseconds(since: drawStart)
                samples.append(Sample(scenario: scenario, round: round,
                                      phase: frame == 0 ? "fresh-process-first-draw" : "warm-draw",
                                      frame: frame, drawMode: drawMode, viewSetupMS: viewSetupMS,
                                      updateMS: updateMS, drawMS: drawMS, elapsedMS: milliseconds(since: started),
                                      dirtyRectCount: regions.count))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for sample in samples {
            FileHandle.standardOutput.write(try encoder.encode(sample))
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }

    @MainActor
    private static func update(_ session: SelectionSession, scenario: String, frame: Int) {
        let x = CGFloat(300 + (frame * 7) % 1050)
        let y = CGFloat(250 + (frame * 5) % 600)
        session.cursor = CGPoint(x: x, y: y)
        if scenario == "area-selection" {
            session.selection = CGRect(x: 150, y: 120, width: x - 150, height: y - 120)
        } else if scenario == "window-hover" {
            let index = (frame / 12) % 3
            session.hoverWindow = WindowInfo(id: UInt32(index + 1), pid: 0, ownerName: "", title: "",
                                            frame: CGRect(x: 100 + index * 300, y: 140 + index * 120,
                                                          width: 700, height: 480), layer: 0)
        }
    }

    private static func distribution(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        return [
            "count": sorted.count, "p50_ms": percentile(0.50), "p95_ms": percentile(0.95),
            "max_ms": sorted.last!, "over_8_3ms": sorted.filter { $0 > 8.3 }.count,
            "over_16_7ms": sorted.filter { $0 > 16.7 }.count,
            "over_50ms": sorted.filter { $0 > 50 }.count
        ]
    }

    private static func summarize(path: String) throws {
        let decoder = JSONDecoder()
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        let samples = try lines.map { try decoder.decode(Sample.self, from: Data($0.utf8)) }
        guard !samples.isEmpty else {
            throw NSError(domain: "OverlayDrawingBenchmark", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No benchmark samples."])
        }
        var groups: [[String: Any]] = []
        for scenario in ["area-cursor", "area-selection", "window-hover"] {
            for phase in ["fresh-process-first-draw", "warm-draw"] {
                let subset = samples.filter { $0.scenario == scenario && $0.phase == phase }
                guard !subset.isEmpty else { continue }
                var group: [String: Any] = [
                    "scenario": scenario, "phase": phase, "draw_mode": subset[0].drawMode,
                    "update": distribution(subset.map(\.updateMS)),
                    "draw": distribution(subset.map(\.drawMS)),
                    "update_and_draw": distribution(subset.map(\.updateAndDrawMS)),
                    "cpu_stalls_over_50ms_within_first_2s":
                        subset.filter { $0.elapsedMS <= 2000 && $0.updateAndDrawMS > 50 }.count
                ]
                if phase == "fresh-process-first-draw" {
                    group["view_setup"] = distribution(subset.map(\.viewSetupMS))
                    group["setup_update_and_draw"] = distribution(subset.map { $0.viewSetupMS + $0.updateAndDrawMS })
                }
                groups.append(group)
            }
        }
        let output: [String: Any] = [
            "measurement": "offscreen synchronous CPU update/draw; NOT event-to-paint or frame presentation",
            "fresh_process": "one new process per scenario/round; no prior overlay draw; OS caches not reset",
            "excluded": ["process launch", "bitmap allocation", "window enumeration", "panel creation",
                         "real input dispatch", "AppKit display scheduling", "WindowServer", "GPU presentation"],
            "canvas_points": [1728, 1117], "scale": 2,
            "percentile_method": "nearest rank; warm samples pooled across fresh processes",
            "budget_note": "8.3/16.7ms counts are CPU reference thresholds, not refresh-budget acceptance",
            "groups": groups
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}
