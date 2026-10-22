// Offline feasibility probe, deliberately not linked into Glint.
// Uses synthetic grayscale images only: no screen capture, permissions, files or network.
import Foundation

struct Segment: Equatable {
    var vertical: Bool
    var coordinate: Int
    var start: Int
    var end: Int
}

struct Fixture {
    var name: String
    var pixels = [UInt8](repeating: 20, count: 512 * 320)
    var expected: [Segment] = []

    mutating func rectangle(x: Int, y: Int, width: Int, height: Int, value: UInt8, target: Bool = true) {
        for row in y..<(y + height) {
            for column in x..<(x + width) { pixels[row * 512 + column] = value }
        }
        if target {
            expected += [
                Segment(vertical: true, coordinate: x, start: y, end: y + height),
                Segment(vertical: true, coordinate: x + width, start: y, end: y + height),
                Segment(vertical: false, coordinate: y, start: x, end: x + width),
                Segment(vertical: false, coordinate: y + height, start: x, end: x + width),
            ]
        }
    }
}

// A deliberately narrow baseline: long, axis-aligned, high-contrast runs.
// Samples are already bounded to 512 x 320; at most 64 candidates are retained.
func detect(_ pixels: [UInt8]) -> [Segment] {
    precondition(pixels.count == 512 * 320)
    var result: [Segment] = []
    for vertical in [true, false] {
        let across = vertical ? 512 : 320
        let along = vertical ? 320 : 512
        for coordinate in 1..<across {
            var start: Int?
            for position in 0...along {
                var edge = false
                if position < along {
                    let index = vertical ? position * 512 + coordinate : coordinate * 512 + position
                    let previous = index - (vertical ? 1 : 512)
                    edge = abs(Int(pixels[index]) - Int(pixels[previous])) >= 40
                }
                if edge {
                    if start == nil { start = position }
                } else if let beginning = start {
                    if position - beginning >= 48 {
                        result.append(Segment(vertical: vertical, coordinate: coordinate,
                                              start: beginning, end: position))
                        if result.count == 64 { return result }
                    }
                    start = nil
                }
            }
        }
    }
    return result
}

func counts(detected: [Segment], expected: [Segment]) -> (truePositive: Int, falsePositive: Int, missed: Int) {
    var unmatched = expected
    var matched = 0
    for segment in detected {
        if let index = unmatched.firstIndex(where: {
            $0.vertical == segment.vertical && abs($0.coordinate - segment.coordinate) <= 1
                && abs($0.start - segment.start) <= 1 && abs($0.end - segment.end) <= 1
        }) {
            unmatched.remove(at: index)
            matched += 1
        }
    }
    return (matched, detected.count - matched, unmatched.count)
}

var card = Fixture(name: "high-contrast card")
card.rectangle(x: 80, y: 60, width: 300, height: 180, value: 220)
var lowContrast = Fixture(name: "low-contrast card")
lowContrast.rectangle(x: 80, y: 60, width: 300, height: 180, value: 45)
var stripes = Fixture(name: "decorative stripes (no targets)")
for x in stride(from: 16, to: 496, by: 24) {
    stripes.rectangle(x: x, y: 20, width: 8, height: 280, value: 220, target: false)
}
var text = Fixture(name: "text-like short strokes (no targets)")
for y in stride(from: 24, to: 280, by: 28) {
    for x in stride(from: 24, to: 470, by: 16) {
        text.rectangle(x: x, y: y, width: 8, height: 12, value: 220, target: false)
    }
}
var longText = Fixture(name: "long rules/underlines (no targets)")
for y in stride(from: 24, to: 280, by: 28) {
    longText.rectangle(x: 40, y: y, width: 420, height: 2, value: 220, target: false)
}
var moved = Fixture(name: "card moved between snapshots")
moved.rectangle(x: 105, y: 75, width: 300, height: 180, value: 220)
var thin = Fixture(name: "small control below minimum length")
thin.rectangle(x: 80, y: 60, width: 32, height: 24, value: 220)
let fixtures = [card, lowContrast, Fixture(name: "uniform (no targets)"), stripes, text, longText, moved, thin]

print("Synthetic content-edge probe: 512x320 grayscale, contrast >=40/255, length >=48, cap 64")
print("One-to-one matching, endpoint/coordinate tolerance 1 sample pixel. Not desktop accuracy.")
print("fixture | TP | FP | FN | precision | recall | first ms | warm median ms")
var totalTP = 0
var totalFP = 0
var totalFN = 0
for fixture in fixtures {
    let firstStart = DispatchTime.now().uptimeNanoseconds
    let detected = detect(fixture.pixels)
    let firstMS = Double(DispatchTime.now().uptimeNanoseconds - firstStart) / 1_000_000
    let score = counts(detected: detected, expected: fixture.expected)
    var times: [Double] = []
    for _ in 0..<25 {
        let start = DispatchTime.now().uptimeNanoseconds
        let repeated = detect(fixture.pixels)
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        precondition(repeated == detected, "Detector must be deterministic")
    }
    totalTP += score.truePositive
    totalFP += score.falsePositive
    totalFN += score.missed
    let precision = detected.isEmpty ? "n/a" : String(format: "%.2f", Double(score.truePositive) / Double(detected.count))
    let recall = fixture.expected.isEmpty ? "n/a" : String(format: "%.2f", Double(score.truePositive) / Double(fixture.expected.count))
    print("\(fixture.name) | \(score.truePositive) | \(score.falsePositive) | \(score.missed) | \(precision) | \(recall) | "
          + String(format: "%.3f | %.3f", firstMS, times.sorted()[times.count / 2]))
}
precondition(counts(detected: detect(card.pixels), expected: card.expected).truePositive == 4)
precondition(detect(fixtures[2].pixels).isEmpty)
precondition(detect(card.pixels) != detect(moved.pixels), "Moving content changes target positions")
print("Aggregate TP=\(totalTP) FP=\(totalFP) FN=\(totalFN). Content detection remains disabled in Glint.")
