import AppKit
import Foundation
import Testing
@testable import GlintCore
@testable import GlintEditor

@Suite("Tracked redactions in the editor")
@MainActor
struct TrackedRedactionEditorTests {
    private static let bounds = CGRect(x: 0, y: 0, width: 160, height: 90)

    /// Tracked for the first second only, so the rest of a two-second clip needs review.
    private static func halfTracked(_ rect: CGRect = CGRect(x: 10, y: 10, width: 20, height: 20)) -> Annotation {
        let track = RedactionTrack(keyframes: [RedactionKeyframe(time: 0, rect: rect, source: .tracked),
                                               RedactionKeyframe(time: 1, rect: rect.offsetBy(dx: 20, dy: 0),
                                                                 source: .tracked)],
                                   analyzedRange: AnnotationTiming(start: 0, end: 1), frameBounds: bounds)
        return Annotation(kind: .redact(rect), track: track)
    }

    private func recordingEditor(_ fixture: EditorFixture) -> EditorModel {
        let context = EditorContext(image: fixture.context.image, backingScale: 1, rawURL: nil, source: nil,
                                    isRecording: true)
        return EditorModel(context: context, preferences: fixture.preferences, presetStore: fixture.presets)
    }

    @Test func unresolvedTrackedFramesBlockEveryExportUntilTrimmedOut() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let video = try RecordingEditorFixture(); defer { video.cleanUp() }
        let recording = try await video.recording()
        var calls = 0
        var services = video.services()
        services.export = { _, _, _, directory, _, _ in
            calls += 1
            let url = directory.appendingPathComponent("clip.gif")
            try Data("tracked-test-payload".utf8).write(to: url)
            return url
        }
        let controller = RecordingEditorWindowController(recording: recording, services: services,
                                                         preferences: f.preferences, presetStore: f.presets)
        defer { controller.window?.close() }
        controller.editor.model.setAnnotations([Self.halfTracked()], actionName: nil)

        #expect(controller.model.unresolvedRedactionIntervals.count == 1)
        #expect(controller.model.hasBlockingRedactionIntervals)
        #expect(!controller.model.canExport)
        #expect(controller.model.prepareFile() == nil)
        controller.model.copy()
        controller.model.start(.save(video.directory.appendingPathComponent("out.gif")))
        await controller.model.waitForExport()
        #expect(calls == 0)
        #expect(controller.model.exportState == .idle)

        controller.model.setTrimEnd(1)
        #expect(!controller.model.hasBlockingRedactionIntervals, "the flagged second is trimmed out")
        #expect(controller.model.canExport)
        controller.model.setTrimEnd(2)
        #expect(!controller.model.canExport)

        // Accepting a fixed cover resolves the interval and export becomes possible again.
        let id = try #require(controller.editor.model.annotations.first?.id)
        #expect(controller.editor.model.resolveTrackedInterval(id, at: 1.5, as: .fixedCover,
                                                              sourceDuration: recording.duration))
        #expect(controller.model.unresolvedRedactionIntervals.isEmpty)
        #expect(controller.model.canExport)
        #expect(controller.editor.model.reopenTrackedInterval(id, at: 1.5))
        #expect(!controller.model.canExport, "reviewing again brings the requirement back")
    }

    @Test func theRendererRefusesFramesThatStillNeedReview() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = recordingEditor(f)
        editor.setAnnotations([Self.halfTracked()], actionName: nil)
        let render = editor.recordingFrameRenderer()
        _ = try render(f.context.image, 0.5)
        #expect(throws: RedactionGateError.unresolvedTracking) { _ = try render(f.context.image, 1.5) }
    }

    @Test func canvasEditsOfATrackedRedactionBecomeKeyframesAtTheCurrentTime() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = recordingEditor(f)
        let annotation = Self.halfTracked()
        editor.setAnnotations([annotation], actionName: nil)
        editor.updateRecordingFrame(f.context.image, at: 0.5)
        let shown = try #require(editor.editingView(annotation).redactionRect)
        #expect(shown == CGRect(x: 20, y: 10, width: 20, height: 20), "the canvas edits the tracked position")
        #expect(editor.hitTestAnnotations.first?.redactionRect == shown)

        editor.replace(editor.editingView(annotation).withRedactionRect(shown.offsetBy(dx: 5, dy: 3)))
        let track = try #require(editor.annotations.first?.track)
        let manual = try #require(track.keyframes.first { $0.source == .manual })
        #expect(manual.time == 0.5 && manual.rect == shown.offsetBy(dx: 5, dy: 3))
        #expect(track.keyframes.count == 3, "the tracked keyframes are kept")

        editor.selection = [annotation.id]
        editor.nudge(dx: 1, dy: 0)
        let nudged = try #require(editor.annotations.first?.track?.keyframes.first { $0.source == .manual })
        #expect(nudged.rect == shown.offsetBy(dx: 6, dy: 3))
        #expect(editor.annotations.first?.track?.keyframes.filter { $0.source == .manual }.count == 1)

        editor.removeTracking(annotation.id)
        #expect(editor.annotations.first?.track == nil)
        #expect(editor.annotations.first?.redactionRect == shown.offsetBy(dx: 6, dy: 3), "stays where it was shown")
    }

    /// Each drag event is built from the annotation as it was when the drag began, so its track is out of date.
    @Test func everyEventOfADragEditsTheSameKeyframe() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = recordingEditor(f)
        let annotation = Self.halfTracked()
        editor.setAnnotations([annotation], actionName: nil)
        editor.updateRecordingFrame(f.context.image, at: 0.5)
        let base = editor.editingView(annotation)
        let shown = try #require(base.redactionRect)

        for step in 1...4 { editor.replace(base.withRedactionRect(shown.offsetBy(dx: CGFloat(step), dy: 0))) }
        var manual = editor.annotations.first?.track?.keyframes.filter { $0.source == .manual } ?? []
        #expect(manual.count == 1)
        #expect(manual.first?.rect == shown.offsetBy(dx: 4, dy: 0))
        #expect(editor.annotations.first?.track?.keyframes.count == 3, "the tracked keyframes are kept")

        editor.selection = [annotation.id]
        editor.beginInteraction()
        let start = try #require(editor.annotations.first.map(editor.editingView))
        for step in 1...4 {
            editor.updateLive(AnnotationGeometry.moving(editor.annotations, from: [start.id: start], part: nil,
                                                        by: CGSize(width: 0, height: CGFloat(step) * 2)))
        }
        editor.endInteraction(actionName: "Move")
        manual = editor.annotations.first?.track?.keyframes.filter { $0.source == .manual } ?? []
        #expect(manual.count == 1)
        #expect(manual.first?.rect == shown.offsetBy(dx: 4, dy: 8))
        #expect(editor.editingView(try #require(editor.annotations.first)).redactionRect == shown.offsetBy(dx: 4, dy: 8))

        // A change that keeps the shown position, like a style edit, adds no keyframe.
        var restyled = editor.editingView(try #require(editor.annotations.first))
        restyled.style.color = .white
        editor.replace(restyled)
        #expect(editor.annotations.first?.track?.keyframes.filter { $0.source == .manual }.count == 1)
    }

    @Test func blurIsNeverAppliedToATrackedRedaction() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = recordingEditor(f)
        let tracked = Self.halfTracked()
        let fixed = Annotation(kind: .redact(CGRect(x: 50, y: 50, width: 10, height: 10)))
        editor.setAnnotations([tracked, fixed], actionName: nil)
        editor.selection = [tracked.id, fixed.id]
        #expect(editor.selectionHasTrackedRedaction)
        editor.setRedactStyle(.blur)
        #expect(editor.annotations.first { $0.id == tracked.id }?.isRedaction == true)
        #expect(editor.annotations.first { $0.id == fixed.id }?.isObfuscation == true)
        #expect(editor.statusMessage?.contains("Blur") == true)
        editor.setRedactStyle(.pixelate)
        #expect(editor.annotations.first { $0.id == tracked.id }?.track != nil, "pixelate keeps the track")
    }

    @Test func trackingAppliesTheResultAndReportsWhatNeedsReview() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = recordingEditor(f)
        let annotation = Annotation(kind: .pixelate(CGRect(x: 10, y: 10, width: 20, height: 20)))
        editor.setAnnotations([annotation], actionName: nil)
        editor.updateRecordingFrame(f.context.image, at: 0.4)
        let requests = RequestLog()
        let result = Self.halfTracked().track!
        let tracking = RedactionTrackingModel(url: URL(fileURLWithPath: "/nonexistent.mp4")) { request, progress in
            requests.record(request)
            progress(0.5)
            return result
        }
        tracking.track(annotation.id, editor: editor, sourceDuration: 2)
        #expect(tracking.isTracking)
        await waitUntil { !tracking.isTracking }
        #expect(requests.all.first?.anchorTime == 0.4)
        #expect(requests.all.first?.range == 0...2)
        #expect(editor.annotations.first?.track == result)
        #expect(tracking.message?.contains("1 interval") == true)
        editor.undoManager.undo()
        #expect(editor.annotations.first?.track == nil, "tracking is one undoable step")

        let blur = Annotation(kind: .blur(CGRect(x: 0, y: 0, width: 5, height: 5)))
        editor.setAnnotations([blur], actionName: nil)
        tracking.track(blur.id, editor: editor, sourceDuration: 2)
        #expect(!tracking.isTracking)
        #expect(requests.all.count == 1, "blur is refused before tracking starts")
    }

    @Test func cancellingTrackingLeavesTheRedactionUnchanged() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = recordingEditor(f)
        let annotation = Annotation(kind: .redact(CGRect(x: 10, y: 10, width: 20, height: 20)))
        editor.setAnnotations([annotation], actionName: nil)
        let late = Self.halfTracked().track!
        let tracking = RedactionTrackingModel(url: URL(fileURLWithPath: "/nonexistent.mp4")) { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return late
        }
        tracking.track(annotation.id, editor: editor, sourceDuration: 2)
        tracking.cancel()
        #expect(!tracking.isTracking)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(editor.annotations.first?.track == nil)
        #expect(tracking.message == "Tracking cancelled.")
    }

    @Test func cancellingTrackingStopsTheTracker() async throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let editor = recordingEditor(f)
        let annotation = Annotation(kind: .redact(CGRect(x: 10, y: 10, width: 20, height: 20)))
        editor.setAnnotations([annotation], actionName: nil)
        let state = WorkerState()
        let late = Self.halfTracked().track!
        let tracking = RedactionTrackingModel(url: URL(fileURLWithPath: "/nonexistent.mp4")) { _, _ in
            state.set(running: true)
            defer { state.set(running: false, stopped: true) }
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)
                if state.iterations > 1_000 { return late }
            }
        }
        tracking.track(annotation.id, editor: editor, sourceDuration: 2)
        await waitUntil(seconds: 5) { state.running }
        tracking.cancel()
        await waitUntil(seconds: 5) { state.stopped }
        #expect(state.stopped, "the tracker stops instead of decoding to the end")
        #expect(editor.annotations.first?.track == nil)
    }

    @Test func nextFlaggedWrapsAround() {
        let id = UUID()
        let intervals = [UnresolvedRedactionInterval(annotationID: id, start: 1, end: 2, reason: .uncertainTracking),
                         UnresolvedRedactionInterval(annotationID: id, start: 3, end: 4, reason: .uncertainTracking)]
        #expect(RedactionTrackingModel.nextFlagged(after: 0, in: intervals)?.start == 1)
        #expect(RedactionTrackingModel.nextFlagged(after: 1, in: intervals)?.start == 3)
        #expect(RedactionTrackingModel.nextFlagged(after: 3.5, in: intervals)?.start == 1)
        #expect(RedactionTrackingModel.nextFlagged(after: 0, in: []) == nil)
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RedactionTrackingRequest] = []

    func record(_ request: RedactionTrackingRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }

    var all: [RedactionTrackingRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

private final class WorkerState: @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = false, isStopped = false, count = 0

    func set(running: Bool, stopped: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        isRunning = running
        if stopped { isStopped = true }
    }

    var running: Bool { lock.lock(); defer { lock.unlock() }; return isRunning }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return isStopped }
    /// Counts each poll, so a worker that is never cancelled still finishes eventually.
    var iterations: Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
