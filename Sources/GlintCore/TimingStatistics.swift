import Foundation

/// Distribution of one stage's timings, in milliseconds rounded to 0.01.
public struct TimingSummary: Codable, Equatable, Sendable {
    public let count: Int
    public let minMs: Double
    public let p50Ms: Double
    public let p95Ms: Double
    public let maxMs: Double
    /// False below `TimingStatistics.reliableP95Count` samples, where p95 is effectively the maximum.
    public let p95Reliable: Bool

    enum CodingKeys: String, CodingKey {
        case count
        case minMs = "min_ms"
        case p50Ms = "p50_ms"
        case p95Ms = "p95_ms"
        case maxMs = "max_ms"
        case p95Reliable = "p95_reliable"
    }
}

public enum TimingStatistics {
    /// Fewer samples than this make p95 the maximum, so reports flag it instead of presenting it as a tail estimate.
    public static let reliableP95Count = 20

    /// Nearest-rank percentiles, the method `Scripts/benchmark-overlay.sh` uses too. Non-finite samples are dropped;
    /// nil when none remain.
    public static func summarize(_ samplesMs: [Double]) -> TimingSummary? {
        let sorted = samplesMs.filter(\.isFinite).sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        // Integer arithmetic keeps ceil(percent × count / 100) exact.
        func percentile(_ percent: Int) -> Double {
            let rank = min(max((percent * sorted.count + 99) / 100, 1), sorted.count)
            return rounded(sorted[rank - 1])
        }
        return TimingSummary(count: sorted.count, minMs: rounded(first), p50Ms: percentile(50), p95Ms: percentile(95),
                             maxMs: rounded(last), p95Reliable: sorted.count >= reliableP95Count)
    }

    public static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
