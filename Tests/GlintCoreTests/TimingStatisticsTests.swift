import Foundation
import Testing
@testable import GlintCore

@Suite("Timing statistics")
struct TimingStatisticsTests {
    @Test func nothingToSummarizeWithoutFiniteSamples() {
        #expect(TimingStatistics.summarize([]) == nil)
        #expect(TimingStatistics.summarize([.nan, .infinity, -.infinity]) == nil)
    }

    @Test func oneSampleIsEveryPercentile() throws {
        let summary = try #require(TimingStatistics.summarize([12.5]))
        #expect(summary == TimingSummary(count: 1, minMs: 12.5, p50Ms: 12.5, p95Ms: 12.5, maxMs: 12.5, p95Reliable: false))
    }

    @Test func nonFiniteSamplesAreDropped() throws {
        let summary = try #require(TimingStatistics.summarize([3, .nan, 1, .infinity, 2]))
        #expect(summary.count == 3)
        #expect(summary.minMs == 1 && summary.p50Ms == 2 && summary.maxMs == 3)
    }

    @Test func nearestRankPercentilesIgnoreInputOrder() throws {
        let hundred = try #require(TimingStatistics.summarize((1...100).map(Double.init).shuffled()))
        #expect(hundred.count == 100)
        #expect(hundred.minMs == 1 && hundred.p50Ms == 50 && hundred.p95Ms == 95 && hundred.maxMs == 100)

        // ceil(0.5 × 10) = 5th and ceil(0.95 × 10) = 10th smallest.
        let ten = try #require(TimingStatistics.summarize((1...10).map(Double.init)))
        #expect(ten.p50Ms == 5 && ten.p95Ms == 10)

        // ceil(0.5 × 3) = 2nd smallest.
        let three = try #require(TimingStatistics.summarize([30, 10, 20]))
        #expect(three.p50Ms == 20 && three.p95Ms == 30)
    }

    @Test(arguments: [(1, false), (19, false), (20, true), (21, true)])
    func p95IsFlaggedUnreliableBelowTwentySamples(count: Int, reliable: Bool) throws {
        let summary = try #require(TimingStatistics.summarize((1...count).map(Double.init)))
        #expect(summary.p95Reliable == reliable)
        #expect(TimingStatistics.reliableP95Count == 20)
    }

    @Test func valuesRoundToAHundredthOfAMillisecond() throws {
        let summary = try #require(TimingStatistics.summarize([1.2349, 1.2351, 7.0049]))
        #expect(summary.minMs == 1.23 && summary.p50Ms == 1.24 && summary.maxMs == 7)
    }

    @Test func durationsConvertToMilliseconds() {
        #expect(TimingStatistics.milliseconds(.zero) == 0)
        #expect(TimingStatistics.milliseconds(.milliseconds(1500)) == 1500)
        #expect(TimingStatistics.milliseconds(.seconds(2) + .microseconds(500)) == 2000.5)
        #expect(TimingStatistics.milliseconds(.nanoseconds(250_000)) == 0.25)
    }

    @Test func summaryEncodesStableSnakeCaseKeys() throws {
        let summary = try #require(TimingStatistics.summarize([1, 2, 3]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try #require(String(data: encoder.encode(summary), encoding: .utf8))
        #expect(json == #"{"count":3,"max_ms":3,"min_ms":1,"p50_ms":2,"p95_ms":3,"p95_reliable":false}"#)
        #expect(try JSONDecoder().decode(TimingSummary.self, from: Data(json.utf8)) == summary)
    }
}
