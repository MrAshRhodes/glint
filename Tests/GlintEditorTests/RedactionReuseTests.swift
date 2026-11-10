import AppKit
@testable import GlintCore
import Testing
@testable import GlintEditor

private struct RecognitionFailure: Error {}

private let email = RecognizedLine(text: "test@example.com", box: CGRect(x: 10, y: 20, width: 80, height: 40))
private let link = RecognizedLine(text: "https://example.com/private", box: CGRect(x: 10, y: 66, width: 80, height: 12))

/// A text recogniser that counts what it is asked and answers when the test says so, standing in for Vision.
@MainActor
private final class CountingRecognizer {
    private var waiting: [Int: CheckedContinuation<[RecognizedLine], Error>] = [:]
    private var immediate: Result<[RecognizedLine], Error>?
    private(set) var calls = 0

    init(answering immediate: Result<[RecognizedLine], Error>? = nil) { self.immediate = immediate }

    func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        calls += 1
        if let immediate { return try immediate.get() }
        let call = calls
        return try await withCheckedThrowingContinuation { waiting[call] = $0 }
    }

    /// Answers the call that has number `call` (the first by default), which must still be waiting.
    func respond(_ result: Result<[RecognizedLine], Error>, call: Int = 1) {
        waiting.removeValue(forKey: call)?.resume(with: result)
    }

    /// Answers every later call at once.
    func answerAtOnce(_ result: Result<[RecognizedLine], Error>) { immediate = result }
}

@MainActor
private func eventually(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}

@Suite("Redaction reuse")
@MainActor
struct RedactionReuseTests {
    /// What a pipeline answer can be that the editor must not take as its own.
    enum NotAnAnswer: String, CaseIterable, Sendable {
        case notRequested, pending, failed, cancelled, otherCategories, otherRecognition

        func analysis(for settings: RedactionAnalysis.Settings) -> RedactionAnalysis {
            var other = settings
            switch self {
            case .notRequested: return .notRequested
            case .pending: return .pending
            case .failed: return .failed("Text recognition failed.")
            case .cancelled: return .cancelled
            case .otherCategories:
                other.detector = .all
                return .noMatches(other)
            case .otherRecognition:
                other.recognizer.languages = ["fr-FR"]
                return .noMatches(other)
            }
        }
    }

    private func settings(_ f: EditorFixture) -> RedactionAnalysis.Settings {
        RedactionAnalysis.Settings(detector: f.preferences.autoRedactOptions)
    }

    private func makeModel(_ f: EditorFixture, analysis: RedactionAnalysis = .notRequested,
                           recognizer: CountingRecognizer) -> EditorModel {
        let context = EditorContext(image: f.context.image, backingScale: f.context.backingScale, rawURL: nil,
                                    source: "test", redaction: analysis)
        return EditorModel(context: context, preferences: f.preferences, presetStore: f.presets,
                           recognizeText: { try await recognizer.recognize($0) })
    }

    // MARK: A finished answer is reused

    @Test(arguments: [false, true])
    func aFinishedAnalysisIsReusedInsteadOfReadingTheCaptureAgain(withMatches: Bool) async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let found = RedactionAnalysis.Findings(count: 1, byCategory: [.email: 1])
        let analysis: RedactionAnalysis = withMatches ? .matches(found, settings(f)) : .noMatches(settings(f))
        let recognizer = CountingRecognizer()
        let model = makeModel(f, analysis: analysis, recognizer: recognizer)

        #expect(!model.awaitsRedaction, "The capture is not held back")
        #expect(model.redactionAnalysis == analysis)
        #expect(model.lastRedactSummary == analysis.summary)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(recognizer.calls == 0, "The capture was read once already")
        #expect(model.annotations.isEmpty, "Its covers are already part of the image")
        #expect(model.redactionAnalysis == analysis)
        _ = try model.renderFinal()
    }

    @Test(arguments: NotAnAnswer.allCases)
    func anythingButAFinishedAnswerForTheSameSettingsIsReadAgain(_ given: NotAnAnswer) async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let recognizer = CountingRecognizer()
        let model = makeModel(f, analysis: given.analysis(for: settings(f)), recognizer: recognizer)

        #expect(model.awaitsRedaction && model.redactionAnalysis == .pending)
        #expect(model.lastRedactSummary == nil)
        #expect(await eventually { recognizer.calls == 1 })
        recognizer.respond(.success([email]))
        #expect(await eventually { !model.awaitsRedaction })
        #expect(recognizer.calls == 1)
        #expect(model.annotations.count == 1)
        #expect(model.redactionAnalysis == .matches(.init(count: 1, byCategory: [.email: 1]), settings(f)))
    }

    @Test func anAnalysisIsNotInventedForAnEditorThatDoesNotRedact() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let recognizer = CountingRecognizer()
        let pending = makeModel(f, analysis: .pending, recognizer: recognizer)
        #expect(!f.preferences.autoRedact && !pending.awaitsRedaction)
        #expect(pending.redactionAnalysis == .notRequested, "Nothing here would ever finish a pending analysis")

        let found = RedactionAnalysis.Findings(count: 1, byCategory: [.email: 1])
        let finished = makeModel(f, analysis: .matches(found, settings(f)), recognizer: recognizer)
        #expect(finished.redactionAnalysis == .matches(found, settings(f)))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(recognizer.calls == 0)
    }

    // MARK: The editor's own passes

    @Test func aPassIsPendingUntilItsAnswerArrives() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let recognizer = CountingRecognizer()
        let model = makeModel(f, recognizer: recognizer)

        #expect(model.redactionAnalysis == .pending && model.awaitsRedaction)
        #expect(await eventually { recognizer.calls == 1 })
        #expect(model.redactionAnalysis == .pending)
        recognizer.respond(.success([]))
        #expect(await eventually { !model.awaitsRedaction })
        #expect(model.redactionAnalysis == .noMatches(settings(f)))
        #expect(model.lastRedactSummary == "No sensitive information found.")
    }

    @Test func aFailedPassIsExplicitAndCanBeRunAgain() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let recognizer = CountingRecognizer()
        let model = makeModel(f, recognizer: recognizer)
        #expect(await eventually { recognizer.calls == 1 })

        recognizer.respond(.failure(RecognitionFailure()))
        #expect(await eventually { !model.awaitsRedaction })
        #expect(model.redactionAnalysis == .failed("Text recognition failed."))
        #expect(model.lastRedactSummary == "Text recognition failed.")
        #expect(model.annotations.isEmpty && !model.isBusy)

        recognizer.answerAtOnce(.success([email]))
        await model.runAutoRedact(announce: false)
        #expect(recognizer.calls == 2, "A failed read is not remembered")
        #expect(model.annotations.count == 1)
        #expect(model.redactionAnalysis == .matches(.init(count: 1, byCategory: [.email: 1]), settings(f)))
    }

    @Test func redactingAgainWithOtherCategoriesDoesNotReadTheCaptureAgain() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let recognizer = CountingRecognizer()
        let model = makeModel(f, recognizer: recognizer)
        #expect(await eventually { recognizer.calls == 1 })
        recognizer.respond(.success([email, link]))
        #expect(await eventually { !model.awaitsRedaction })
        #expect(model.annotations.count == 1, "Web addresses are not covered until their category is on")

        model.redactOptions.categories.insert(.url)
        await model.runAutoRedact(announce: false)
        #expect(recognizer.calls == 1, "The text is read again from memory, not from the pixels")
        #expect(model.annotations.count == 2)
        #expect(model.redactionAnalysis
                == .matches(.init(count: 2, byCategory: [.email: 1, .url: 1]), .init(detector: model.redactOptions)))
        #expect(model.lastRedactSummary == "Redacted 2: Email addresses ×1, URLs ×1")
    }

    @Test func aPassTheUserStartsOnAReusedAnswerDoesNotHoldTheCaptureBack() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let recognizer = CountingRecognizer()
        let model = makeModel(f, analysis: .noMatches(settings(f)), recognizer: recognizer)
        #expect(!model.awaitsRedaction)

        let manual = Task { await model.runAutoRedact(announce: false) }
        #expect(await eventually { recognizer.calls == 1 })
        #expect(model.redactionAnalysis == .pending && model.isBusy)
        #expect(!model.awaitsRedaction, "The capture is already redacted, so it stays on screen")
        _ = try model.renderFinal()

        recognizer.respond(.success([email]))
        await manual.value
        #expect(model.annotations.count == 1 && !model.isBusy)
        #expect(model.redactionAnalysis == .matches(.init(count: 1, byCategory: [.email: 1]), settings(f)))
    }

    @Test func detectTextUsesTheTextTheRedactionPassRead() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let recognizer = CountingRecognizer()
        let model = makeModel(f, recognizer: recognizer)
        #expect(await eventually { recognizer.calls == 1 })
        recognizer.respond(.success([email]))
        #expect(await eventually { !model.awaitsRedaction })

        await model.detectText()
        #expect(recognizer.calls == 1)
        #expect(model.ocrLines == [email] && model.statusMessage == "Detected 1 lines.")
    }

    @Test func detectTextReadsACaptureOnce() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let recognizer = CountingRecognizer(answering: .success([email]))
        let model = makeModel(f, recognizer: recognizer)

        await model.detectText()
        await model.detectText()
        #expect(recognizer.calls == 1)
        #expect(model.ocrLines == [email])
    }

    @Test func detectTextDoesNotRememberAFailedRead() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let recognizer = CountingRecognizer(answering: .failure(RecognitionFailure()))
        let model = makeModel(f, recognizer: recognizer)
        await model.detectText()
        #expect(model.statusMessage == "No text detected.")

        recognizer.answerAtOnce(.success([email]))
        await model.detectText()
        #expect(recognizer.calls == 2 && model.ocrLines == [email])
    }

    // MARK: A closed editor and a newer pass

    @Test func aPassThatFinishesAfterTheEditorClosedIsNotApplied() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let closed = CountingRecognizer(), other = CountingRecognizer()
        let first = makeModel(f, recognizer: closed)
        let second = makeModel(f, recognizer: other)
        #expect(await eventually { closed.calls == 1 && other.calls == 1 })

        first.close()
        #expect(first.redactionAnalysis == .cancelled && !first.isBusy)
        #expect(first.awaitsRedaction, "Closing does not release a capture that was never redacted")

        closed.respond(.success([email]))
        other.respond(.success([email]))
        #expect(await eventually { !second.awaitsRedaction })
        #expect(second.annotations.count == 1, "Another editor's pass is not disturbed")
        #expect(second.redactionAnalysis == .matches(.init(count: 1, byCategory: [.email: 1]), settings(f)))

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(first.annotations.isEmpty, "The late answer is not applied to the editor that closed")
        #expect(first.redactionAnalysis == .cancelled && first.lastRedactSummary == nil)
        #expect(first.awaitsRedaction)
        #expect(throws: EditorError.redactionPending) { try first.renderFinal() }
        closed.answerAtOnce(.success([email]))
        await first.runAutoRedact(announce: false)
        #expect(closed.calls == 1 && first.annotations.isEmpty, "A closed editor starts nothing new")
    }

    @Test func closingAfterThePassFinishedKeepsItsAnswer() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let recognizer = CountingRecognizer(answering: .success([email]))
        let model = makeModel(f, recognizer: recognizer)
        #expect(await eventually { !model.awaitsRedaction })
        let answer = model.redactionAnalysis

        model.close()
        model.close()
        #expect(answer.isCompleted && model.redactionAnalysis == answer)
        #expect(model.annotations.count == 1)
    }

    @Test func closingTheWindowCancelsThePassOfItsEditor() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let controller = f.controller(services: EditorExportServices())
        let model = controller.model
        #expect(model.awaitsRedaction && model.redactionAnalysis == .pending)

        controller.window?.close()
        #expect(model.redactionAnalysis == .cancelled)
        #expect(model.awaitsRedaction && model.annotations.isEmpty)
    }

    @Test func aNewerPassSupersedesAnOlderOne() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let recognizer = CountingRecognizer()
        let model = makeModel(f, recognizer: recognizer)
        #expect(await eventually { recognizer.calls == 1 })

        let newer = Task { await model.runAutoRedact(announce: false) }
        #expect(await eventually { recognizer.calls == 2 })
        recognizer.respond(.success([email]), call: 2)
        await newer.value
        #expect(!model.awaitsRedaction, "The newer pass finished, so nothing is left to wait for")
        let covers = model.annotations.map(\.id)
        #expect(covers.count == 1 && model.redactionAnalysis.isCompleted)

        recognizer.respond(.success([email]), call: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(model.annotations.map(\.id) == covers, "The older answer is dropped, not applied a second time")
        #expect(!model.isBusy)
    }

    // MARK: Nothing is published before the first pass is done

    @Test func nothingIsExportedWhileTheFirstPassIsPending() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let recognizer = CountingRecognizer()
        let model = makeModel(f, recognizer: recognizer)
        #expect(await eventually { recognizer.calls == 1 })
        #expect(throws: EditorError.redactionPending) { try model.renderFinal() }
        #expect(EditorError.redactionPending.errorDescription?.contains("still checking") == true)

        recognizer.respond(.success([email]))
        #expect(await eventually { !model.awaitsRedaction })
        let output = try model.renderFinal()
        #expect(try #require(PixelBuffer(output)).pixel(50, 40) == (0, 0, 0, 255), "The output carries the cover")
    }

    @Test func anExportAskedForTooEarlyIsRefusedAndCanBeRetried() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        var services = EditorExportServices()
        var copies = 0, beeps = 0
        services.copy = { _, _, _ in copies += 1; return true }
        services.beep = { beeps += 1 }
        let controller = f.controller(services: services)
        defer { controller.window?.close() }
        let model = controller.model

        #expect(await controller.copyToClipboard() == false)
        #expect(copies == 0 && beeps == 1)
        #expect(model.statusMessage == "Copy failed: \(EditorError.redactionPending.localizedDescription)")
        let retry = try #require(controller.actions.retryExport)

        #expect(await eventually { !model.awaitsRedaction })
        retry()
        await controller.finishExports()
        #expect(copies == 1 && controller.actions.retryExport == nil)
    }

    // MARK: Headless rendering

    @Test func headlessRenderingRefusesPixelsItCouldNotRedact() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        #expect(throws: RecognitionFailure.self) {
            _ = try EditorHeadless.render(context: f.context, preferences: f.preferences,
                                          recognizeText: { _ in throw RecognitionFailure() })
        }
    }

    @Test(arguments: [false, true])
    func headlessRenderingReadsTheCaptureOnlyWhenNoFinishedAnalysisCameWithIt(finished: Bool) throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        f.preferences.autoRedact = true
        let analysis: RedactionAnalysis = finished ? .noMatches(settings(f)) : .notRequested
        let context = EditorContext(image: f.context.image, backingScale: 2, rawURL: nil, source: "test",
                                    redaction: analysis)
        var reads = 0
        let output = try EditorHeadless.render(context: context, preferences: f.preferences, recognizeText: { _ in
            reads += 1
            return [email]
        })
        #expect(reads == (finished ? 0 : 1))
        let covered = try #require(PixelBuffer(output)).pixel(50, 40) == (0, 0, 0, 255)
        #expect(covered != finished, "A capture that came already redacted is not covered a second time")
    }
}
