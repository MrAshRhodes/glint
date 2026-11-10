import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

@Suite("Redaction analysis")
struct RedactionAnalysisTests {
    private let defaults = RedactionAnalysis.Settings(detector: .default)
    private let everything = RedactionAnalysis.Settings(detector: .all)
    private let found = RedactionAnalysis.Findings(count: 1, byCategory: [.email: 1])

    // MARK: Lifecycle

    @Test func onlyAFinishedAnswerForTheSameSettingsIsReusable() {
        #expect(RedactionAnalysis.noMatches(defaults).isReusable(for: defaults))
        #expect(RedactionAnalysis.matches(found, defaults).isReusable(for: defaults))

        #expect(!RedactionAnalysis.noMatches(defaults).isReusable(for: everything), "Other categories need another look")
        #expect(!RedactionAnalysis.matches(found, defaults).isReusable(for: everything))
        var french = defaults
        french.recognizer.languages = ["fr-FR"]
        #expect(!RedactionAnalysis.noMatches(defaults).isReusable(for: french), "Other recognition options read other text")

        for unfinished: RedactionAnalysis in [.notRequested, .pending, .failed("Text recognition failed."), .cancelled] {
            #expect(!unfinished.isReusable(for: defaults), "\(unfinished) is not an answer")
        }
    }

    @Test func theStatesSayWhetherAnAnswerExists() {
        #expect(RedactionAnalysis.pending.isPending)
        #expect(!RedactionAnalysis.cancelled.isPending && !RedactionAnalysis.notRequested.isPending)

        #expect(RedactionAnalysis.noMatches(defaults).isCompleted && RedactionAnalysis.matches(found, defaults).isCompleted)
        for other: RedactionAnalysis in [.notRequested, .pending, .failed("x"), .cancelled] {
            #expect(!other.isCompleted && other.settings == nil)
        }
        #expect(RedactionAnalysis.matches(found, everything).settings == everything)
    }

    @Test func theSummaryIsWhatTheEditorTellsTheUser() {
        #expect(RedactionAnalysis.noMatches(defaults).summary == "No sensitive information found.")
        let several = RedactionAnalysis.Findings(count: 3, byCategory: [.email: 2, .apiKey: 1])
        #expect(RedactionAnalysis.matches(several, defaults).summary
                == "Redacted 3: API keys & tokens ×1, Email addresses ×2")
        #expect(RedactionAnalysis.failed("Text recognition failed.").summary == "Text recognition failed.")
        for silent: RedactionAnalysis in [.notRequested, .pending, .cancelled] { #expect(silent.summary == nil) }
    }

    @Test func settingsIgnoreHowACoverIsDrawn() {
        let a = AutoRedactOptions(detector: .default, color: .red, backingScale: 1)
        let b = AutoRedactOptions(detector: .default, color: .black, backingScale: 3)
        #expect(a.settings == b.settings, "Colour and padding change the cover, not what is found")
        #expect(a.settings == defaults)
        #expect(AutoRedactOptions(detector: .all, backingScale: 1).settings == everything)
    }

    // MARK: One analysis per pass

    private func line(_ text: String, _ box: CGRect) -> RecognizedLine { RecognizedLine(text: text, box: box) }

    @Test func aPassRecordsWhatItCovered() {
        let lines = [line("test@example.com", CGRect(x: 10, y: 10, width: 80, height: 20)),
                     line("123-45-6789", CGRect(x: 10, y: 40, width: 60, height: 20)),
                     line("nothing to see", CGRect(x: 10, y: 70, width: 60, height: 20))]
        let options = AutoRedactOptions(detector: .default, color: .black, backingScale: 1)
        let outcome = AutoRedact.analyse(lines, options: options, imageSize: CGSize(width: 200, height: 100))

        #expect(outcome.annotations.count == 2)
        #expect(outcome.analysis == .matches(.init(count: 2, byCategory: [.email: 1, .ssn: 1]), defaults))
        #expect(outcome.annotations.allSatisfy { $0.isRedaction })
    }

    @Test func aPassWithNothingToCoverIsAFinishedAnswer() {
        let options = AutoRedactOptions(detector: .default, color: .black, backingScale: 2)
        let size = CGSize(width: 200, height: 100)
        let quiet = AutoRedact.analyse([line("hello", CGRect(x: 10, y: 10, width: 40, height: 20))],
                                       options: options, imageSize: size)
        #expect(quiet.annotations.isEmpty && quiet.analysis == .noMatches(defaults))
        #expect(quiet.analysis.isReusable(for: defaults), "No match is still an answer, so it is not asked for again")

        let none = AutoRedact.analyse([], options: options, imageSize: size)
        #expect(none.annotations.isEmpty && none.analysis == .noMatches(defaults))

        // Text wholly outside the image leaves nothing to cover, so it is not counted as covered.
        let outside = AutoRedact.analyse([line("test@example.com", CGRect(x: 500, y: 10, width: 80, height: 20))],
                                         options: options, imageSize: size)
        #expect(outside.annotations.isEmpty && outside.analysis == .noMatches(defaults))
    }

    @Test func theCountsAddUpToTheCoversDrawn() {
        let lines = (0..<4).map { line("user\($0)@example.com", CGRect(x: 10, y: 10 + 22 * $0, width: 120, height: 20)) }
        let outcome = AutoRedact.analyse(lines, options: AutoRedactOptions(backingScale: 1),
                                         imageSize: CGSize(width: 200, height: 100))
        guard case .matches(let findings, _) = outcome.analysis else { Issue.record("Expected matches"); return }
        #expect(findings.count == outcome.annotations.count && findings.byCategory.values.reduce(0, +) == findings.count)
    }

    // MARK: One policy at every scale

    @Test func paddingIsTheSameLogicalMarginAtEveryScale() {
        #expect(RedactionPolicy.paddingPoints == 3)
        #expect(RedactionPolicy.padding(backingScale: 1) == 3)
        #expect(RedactionPolicy.padding(backingScale: 2) == 6)
        #expect(RedactionPolicy.padding(backingScale: 3) == 9)
        #expect(RedactionPolicy.padding(backingScale: 0.5) == 3, "A scale below 1 counts as 1")
        #expect(RedactionPolicy.padding(backingScale: 0) == 3)
        #expect(AutoRedactOptions(backingScale: 2).padding == 6)
        #expect(AutoRedactOptions().padding == 3, "The padding initialiser still defaults to three pixels")
    }

    /// The covers `analyse` makes for text laid out in points, on a capture taken at `scale`, in points again.
    private func coverage(scale: CGFloat, boxes: [(text: String, rect: CGRect)], size: CGSize) -> [CGRect] {
        let lines = boxes.map { text, rect in
            line(text, CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale,
                              height: rect.height * scale))
        }
        let options = AutoRedactOptions(detector: .default, color: .black, backingScale: scale)
        let outcome = AutoRedact.analyse(lines, options: options,
                                         imageSize: CGSize(width: size.width * scale, height: size.height * scale))
        return outcome.annotations.compactMap { annotation -> CGRect? in
            guard case .redact(let rect) = annotation.kind else { return nil }
            return CGRect(x: rect.minX / scale, y: rect.minY / scale, width: rect.width / scale,
                          height: rect.height / scale)
        }
    }

    @Test(arguments: [
        // Inside the image, against the left and top edges, against the right and bottom edges, and off the image.
        [("test@example.com", CGRect(x: 20, y: 30, width: 100, height: 16))],
        [("test@example.com", CGRect(x: 0, y: 1, width: 100, height: 16))],
        [("test@example.com", CGRect(x: 100, y: 64, width: 100, height: 16))],
        [("test@example.com", CGRect(x: 150, y: 70, width: 100, height: 16))],
        [("test@example.com", CGRect(x: 20, y: 10, width: 100, height: 16)),
         ("123-45-6789", CGRect(x: 0, y: 0, width: 70, height: 12))],
    ] as [[(String, CGRect)]])
    func aCaptureAtOneAndTwoTimesIsCoveredByTheSameLogicalRegion(_ boxes: [(String, CGRect)]) {
        let size = CGSize(width: 200, height: 80)
        let labelled = boxes.map { (text: $0.0, rect: $0.1) }
        let one = coverage(scale: 1, boxes: labelled, size: size)
        let two = coverage(scale: 2, boxes: labelled, size: size)
        #expect(one.count == two.count)
        for (a, b) in zip(one, two) {
            #expect(abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9
                        && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9,
                    "\(a) at 1× is not \(b) at 2×")
        }
    }

    @Test func aMatchAtAnEdgeIsCoveredUpToTheEdge() {
        let covers = coverage(scale: 2, boxes: [(text: "test@example.com", rect: CGRect(x: 0, y: 1, width: 100, height: 16))],
                              size: CGSize(width: 200, height: 80))
        #expect(covers == [CGRect(x: 0, y: 0, width: 103, height: 20)], "Grown by 3 points, clipped at the left and top")
    }

    // MARK: Recognition statistics

    private func blank(width: Int, height: Int) throws -> CGImage {
        let context = try #require(GlintBitmap.makeContext(width: width, height: height))
        context.setFillColor(RGBAColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func aCounterTotalsPassesFailuresAndTime() {
        let counter = TextRecognizer.Counter()
        #expect(counter.statistics == TextRecognizer.Statistics())

        let first = counter.begin()
        let second = counter.begin()
        #expect(counter.statistics.passes == 2 && counter.statistics.inFlight == 2)

        counter.end(startedAt: first, failed: false)
        #expect(counter.statistics.inFlight == 1 && counter.statistics.failures == 0)
        counter.end(startedAt: second, failed: true)
        let totals = counter.statistics
        #expect(totals.passes == 2 && totals.failures == 1 && totals.inFlight == 0)
        #expect(totals.seconds > 0)
    }

    @Test func aTallImageReadInBandsIsOnePass() throws {
        let counter = TextRecognizer.Counter()
        let tall = try blank(width: 40, height: TextRecognizer.maximumBandHeight + 600)
        #expect(TextRecognizer.bands(height: tall.height).count == 2)

        // Vision may be unavailable headlessly; a pass is counted whether it reads text or fails.
        _ = try? TextRecognizer.recognizeSync(in: tall, options: .init(), counter: counter)
        let statistics = counter.statistics
        #expect(statistics.passes == 1 && statistics.inFlight == 0, "Two bands are still one pass")
        #expect(statistics.seconds > 0)
    }

    @Test func theProcessWideStatisticsGrowWithEveryPass() throws {
        let before = TextRecognizer.statistics
        _ = try? TextRecognizer.recognizeSync(in: try blank(width: 40, height: 40))
        let after = TextRecognizer.statistics
        // Other tests may be reading text too, so only growth can be asserted.
        #expect(after.passes >= before.passes + 1)
        #expect(after.seconds > before.seconds)
    }
}
