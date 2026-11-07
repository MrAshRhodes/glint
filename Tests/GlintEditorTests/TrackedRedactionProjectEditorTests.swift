import AppKit
import Foundation
import Testing
@testable import GlintCore
@testable import GlintEditor

/// A recording whose redactions follow moving content is saved as a project, closed and opened again. The tracked
/// positions, the time flagged for review and the export gate must all come back as they were: none of it may live
/// only in memory.
@Suite("Tracked redactions in reopened recording projects")
@MainActor
struct TrackedRedactionProjectEditorTests {
    private static let frame = CGRect(x: 0, y: 0, width: 160, height: 90)
    /// The editor re-reads the clip's length from the file; fixing it keeps the flagged second exact.
    private static let clipDuration: TimeInterval = 2
    private static let look = RenderSettings(
        padding: 8, cornerRadius: 0, shadow: .none, background: .solid(RGBAColor(r: 0.2, g: 0.4, b: 0.8)),
        autoBalance: false)
    /// On and between keyframes, and before, inside and after the lost second.
    private static let times: [TimeInterval] = [0, 0.1, 0.3, 0.45, 0.6, 0.9, 0.95, 1, 1.5, 1.99]

    private static func box(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 30, width: 24, height: 16) }

    /// Never tracked: it sits still in every frame.
    private static func fixedRedaction() -> Annotation {
        Annotation(z: 0, kind: .redact(CGRect(x: 4, y: 4, width: 30, height: 10)))
    }

    /// Followed for the first second of the two-second clip and lost after that, so the second second needs review.
    private static func lostAfterOneSecond() -> Annotation {
        let track = RedactionTrack(
            keyframes: [RedactionKeyframe(time: 0, rect: box(10), source: .tracked),
                        RedactionKeyframe(time: 0.3, rect: box(30), source: .tracked),
                        RedactionKeyframe(time: 0.6, rect: box(50), source: .tracked),
                        RedactionKeyframe(time: 0.9, rect: box(70), source: .tracked)],
            uncertainIntervals: [RedactionUncertainInterval(start: 1, end: 2, anchorTime: 0.9, anchorRect: box(70))],
            analyzedRange: AnnotationTiming(start: 0, end: 2), frameBounds: frame)
        return Annotation(z: 1, kind: .redact(box(10)), track: track)
    }

    /// Followed through the whole clip, so it never needs review.
    private static func followedThroughout() -> Annotation {
        func spot(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 60, width: 30, height: 20) }
        let track = RedactionTrack(
            keyframes: [RedactionKeyframe(time: 0, rect: spot(100), source: .tracked),
                        RedactionKeyframe(time: 0.5, rect: spot(90), source: .tracked),
                        RedactionKeyframe(time: 1, rect: spot(80), source: .tracked),
                        RedactionKeyframe(time: 1.5, rect: spot(70), source: .tracked),
                        RedactionKeyframe(time: 2, rect: spot(60), source: .tracked)],
            analyzedRange: AnnotationTiming(start: 0, end: 2), frameBounds: frame)
        return Annotation(z: 2, kind: .pixelate(spot(100)), track: track)
    }

    /// A frame as large as the clip with a different colour in every column, so any redaction changes pixels.
    private static func sampleFrame() throws -> CGImage {
        let bitmap = try #require(GlintBitmap.makeContext(width: 160, height: 90))
        for column in 0..<160 {
            bitmap.setFillColor(RGBAColor(r: Double(column) / 160, g: 0.5, b: 1 - Double(column) / 160).cgColor)
            bitmap.fill(CGRect(x: column, y: 0, width: 1, height: 90))
        }
        return try #require(bitmap.makeImage())
    }

    private static func flag(_ annotation: Annotation, _ start: TimeInterval, _ end: TimeInterval,
                             _ reason: UnresolvedRedactionInterval.Reason = .uncertainTracking)
        -> UnresolvedRedactionInterval {
        UnresolvedRedactionInterval(annotationID: annotation.id, start: start, end: end, reason: reason)
    }

    /// Real clips, isolated preferences, and editor services whose exports only note that they ran.
    @MainActor
    private final class Workbench {
        struct Reopened {
            let controller: RecordingEditorWindowController
            /// What the package holds, before the editor touched it.
            let state: RecordingProjectState
        }

        let editorFixture: EditorFixture
        let video: RecordingEditorFixture
        /// One entry for every export that actually started.
        let exports = EventLog()
        private var services = RecordingEditorServices()
        private var controllers: [RecordingEditorWindowController] = []
        private var projects: [GlintProject] = []

        init() throws {
            editorFixture = try EditorFixture()
            video = try RecordingEditorFixture()
            services = video.services()
            services.readDuration = { _ in TrackedRedactionProjectEditorTests.clipDuration }
            let log = exports
            services.export = { _, range, _, directory, _, renderer in
                log.add("\(range.lowerBound)...\(range.upperBound)")
                // The first and the last frame the exporter would render, so the review decisions reach the
                // renderer an export really uses.
                let frame = try TrackedRedactionProjectEditorTests.sampleFrame()
                for time in [range.lowerBound, range.upperBound - 0.05] { _ = try renderer?(frame, time) }
                let url = directory.appendingPathComponent("clip.gif")
                try Data("tracked-test-payload".utf8).write(to: url)
                return url
            }
        }

        /// A new editor on a fresh two-second clip, with `annotations` on its canvas and a known look.
        func open(annotations: [Annotation]) async throws -> RecordingEditorWindowController {
            let recorded = try await video.recording()
            // The test owns the file, like the clip inside a saved project, so closing a window never deletes it.
            let clip = RecordedVideo(url: recorded.url, duration: recorded.duration, pixelSize: recorded.pixelSize,
                                     deletesFileOnClose: false)
            let controller = RecordingEditorWindowController(
                recording: clip, services: services, preferences: editorFixture.preferences,
                presetStore: editorFixture.presets)
            controllers.append(controller)
            controller.editor.model.settings = TrackedRedactionProjectEditorTests.look
            controller.editor.model.setAnnotations(annotations, actionName: nil)
            return controller
        }

        /// Writes the editor's state as a `.glint` package, the way Save as Project… does.
        func save(_ controller: RecordingEditorWindowController, as name: String) throws -> URL {
            let project = try #require(controller.editor.makeProject?())
            let package = video.directory.appendingPathComponent("\(name).glint")
            try ProjectStore.write(project, to: package)
            return package
        }

        func requiredFeatures(of package: URL) throws -> [String] {
            let manifest = try Data(contentsOf: package.appendingPathComponent(ProjectStore.Member.manifest))
            return try JSONDecoder().decode(ProjectManifest.self, from: manifest).requiredFeatures
        }

        /// Opens a package the way the app does: read it into a private snapshot, then build the editor from it.
        func reopen(_ package: URL) throws -> Reopened {
            let project = try ProjectStore.read(from: package,
                                                snapshotRoot: video.directory.appendingPathComponent("Snapshots"))
            projects.append(project)
            guard case .recording(let state) = project.state, case .video(let url) = project.source else {
                throw ProjectFormatError.mismatchedSource
            }
            let clip = RecordedVideo(url: url, duration: state.duration, pixelSize: state.pixelSize,
                                     deletesFileOnClose: false)
            let controller = try RecordingEditorWindowController(
                recording: clip, services: services, preferences: editorFixture.preferences,
                presetStore: editorFixture.presets, project: state, projectName: "Demo")
            controllers.append(controller)
            return Reopened(controller: controller, state: state)
        }

        func cleanUp() {
            for controller in controllers { controller.window?.close() }
            for project in projects { project.discardSnapshot() }
            video.cleanUp()
            editorFixture.cleanUp()
        }
    }

    private func annotation(_ id: UUID, in controller: RecordingEditorWindowController) throws -> Annotation {
        try #require(controller.editor.model.annotations.first { $0.id == id })
    }

    // MARK: - Reopening

    @Test func aReopenedProjectKeepsItsTrackedRedactionsAndStaysBlocked() async throws {
        let bench = try Workbench(); defer { bench.cleanUp() }
        let fixed = Self.fixedRedaction(), lost = Self.lostAfterOneSecond(), followed = Self.followedThroughout()
        let first = try await bench.open(annotations: [fixed, lost, followed])
        let saved = first.editor.model.annotations
        #expect(saved == [fixed, lost, followed])
        #expect(first.model.unresolvedRedactionIntervals == [Self.flag(lost, 1, 2)])
        let sample = try Self.sampleFrame()
        let framePainted = try first.editor.model.recordingFrameRenderer()(sample, 0.45)

        let package = try bench.save(first, as: "Tracked")
        first.window?.close()
        #expect(try bench.requiredFeatures(of: package) == [ProjectFeatures.redactionTracks])

        let reopened = try bench.reopen(package)
        let second = reopened.controller
        #expect(reopened.state.annotations == saved, "the file holds every track")
        #expect(second.editor.model.annotations == saved)
        #expect(second.editor.model.settings == Self.look)
        #expect(try annotation(lost.id, in: second).track == lost.track)
        #expect(try annotation(followed.id, in: second).track == followed.track)
        #expect(try annotation(fixed.id, in: second).track == nil)

        // The orange marks on the timeline and the Next flagged button read these.
        let flagged = [Self.flag(lost, 1, 2)]
        #expect(second.model.unresolvedRedactionIntervals == flagged)
        #expect(RedactionTrackingModel.nextFlagged(after: 0, in: second.model.unresolvedRedactionIntervals)?.start == 1)

        // Every way of getting the clip out is blocked, and nothing is started behind the user's back.
        #expect(second.model.hasBlockingRedactionIntervals && !second.model.canExport)
        #expect(second.model.prepareFile() == nil)
        second.model.copy()
        second.model.start(.save(bench.video.directory.appendingPathComponent("Blocked.gif")))
        await second.model.waitForExport()
        #expect(bench.exports.events.isEmpty && second.model.exportState == .idle)

        // The renderer behind the preview and every export agrees with the original, and refuses flagged frames.
        let render = second.editor.model.recordingFrameRenderer()
        try expectSamePixels(try render(sample, 0.45), framePainted)
        #expect(throws: RedactionGateError.unresolvedTracking) { _ = try render(sample, 1.5) }
        #expect(throws: RedactionGateError.unresolvedTracking) { _ = try render(sample, 1.0) }

        // Each frame gets the rect it had before saving; flagged frames get the fail-safe cover around the last
        // position the tracker was sure of.
        for time in Self.times {
            #expect(second.editor.model.annotations.map { $0.editingView(at: time) }
                == saved.map { $0.editingView(at: time) }, "tracked position at \(time)")
            #expect(second.editor.model.annotations.map { $0.resolved(at: time) }
                == saved.map { $0.resolved(at: time) }, "rendered cover at \(time)")
        }
        let reopenedLost = try annotation(lost.id, in: second)
        for (time, box) in [(0.0, 10), (0.3, 30), (0.6, 50), (0.9, 70), (1.5, 70)] as [(TimeInterval, CGFloat)] {
            #expect(reopenedLost.editingView(at: time).redactionRect == Self.box(box), "position at \(time)")
        }
        let cover = try #require(reopenedLost.resolved(at: 1.5).redactionRect)
        #expect(cover == FailSafeCover.rect(anchor: Self.box(70), elapsed: abs(1.5 - 0.9), bounds: Self.frame))
        #expect(cover.contains(Self.box(70)) && cover.width > Self.box(70).width)
    }

    @Test func aProjectWithoutTracksNeedsNoFeatureAndStaysExportable() async throws {
        let bench = try Workbench(); defer { bench.cleanUp() }
        let fixed = Self.fixedRedaction()
        let first = try await bench.open(annotations: [fixed])
        let package = try bench.save(first, as: "Plain")
        #expect(try bench.requiredFeatures(of: package).isEmpty)

        let second = try bench.reopen(package).controller
        #expect(second.editor.model.annotations == [fixed])
        #expect(second.model.unresolvedRedactionIntervals.isEmpty && second.model.canExport)
    }

    // MARK: - Reviewing after reopening

    enum Review: String, CaseIterable, Sendable {
        case fixedCover, keyframes, trim
    }

    @Test(arguments: Review.allCases)
    func reviewingTheFlaggedTimeAfterReopeningUnblocksExportAndIsKept(_ review: Review) async throws {
        let bench = try Workbench(); defer { bench.cleanUp() }
        let lost = Self.lostAfterOneSecond()
        let first = try await bench.open(annotations: [lost, Self.followedThroughout()])
        let package = try bench.save(first, as: "Tracked")
        first.window?.close()
        let second = try bench.reopen(package).controller
        let flagged = [Self.flag(lost, 1, 2)]
        #expect(second.model.unresolvedRedactionIntervals == flagged && !second.model.canExport)

        let editor = second.editor.model
        switch review {
        case .fixedCover:
            #expect(editor.resolveTrackedInterval(lost.id, at: 1.5, as: .fixedCover, sourceDuration: 2))
        case .keyframes:
            #expect(!editor.resolveTrackedInterval(lost.id, at: 1.5, as: .keyframes, sourceDuration: 2),
                    "a lost track can't be waved through before the redaction is placed by hand")
            #expect(!second.model.canExport)
            editor.updateRecordingFrame(try Self.sampleFrame(), at: 1.5)
            let current = try annotation(lost.id, in: second)
            let placed = try #require(editor.editingView(current).redactionRect).offsetBy(dx: 5, dy: 3)
            editor.replace(editor.editingView(current).withRedactionRect(placed))
            let manual = try annotation(lost.id, in: second).track?.keyframes.filter { $0.source == .manual }
            #expect(manual == [RedactionKeyframe(time: 1.5, rect: placed, source: .manual)])
            #expect(editor.resolveTrackedInterval(lost.id, at: 1.5, as: .keyframes, sourceDuration: 2))
        case .trim:
            second.model.setTrimEnd(1)
        }
        #expect(second.model.canExport)
        // Trimming hides the flagged second without resolving it; the other reviews resolve it.
        #expect(second.model.unresolvedRedactionIntervals == (review == .trim ? flagged : []))

        second.model.start(.save(bench.video.directory.appendingPathComponent("Reviewed.gif")))
        await second.model.waitForExport()
        #expect(second.model.exportState == .done("Saved Reviewed.gif"))
        #expect(bench.exports.events.count == 1)

        // The review is part of the project: saving again and reopening keeps it.
        let reviewed = editor.annotations
        let trim = second.model.trim
        let intervals = second.model.unresolvedRedactionIntervals
        let package2 = try bench.save(second, as: "Reviewed")
        second.window?.close()
        #expect(try bench.requiredFeatures(of: package2) == [ProjectFeatures.redactionTracks])
        let reopened = try bench.reopen(package2)
        let third = reopened.controller
        #expect(reopened.state.annotations == reviewed && third.editor.model.annotations == reviewed)
        #expect(third.model.trim == trim && third.model.unresolvedRedactionIntervals == intervals)
        #expect(third.model.canExport)
        if review == .trim {
            third.model.setTrimEnd(2)
            #expect(!third.model.canExport, "trimming only hid the flagged time; widening the trim brings it back")
        }
    }

    // MARK: - Tracks that can't be trusted

    enum Damage: String, CaseIterable, Sendable {
        case noKeyframes, overlappingIntervals, noFrameBounds
    }

    /// A track that parses but can't place the redaction is kept and blocks every export; it is never dropped
    /// (which would uncover the content) and never trusted.
    @Test(arguments: Damage.allCases)
    func aTrackThatCantBeTrustedIsKeptAndBlocksExport(_ damage: Damage) async throws {
        let bench = try Workbench(); defer { bench.cleanUp() }
        let keyframes = [RedactionKeyframe(time: 0, rect: Self.box(10), source: .tracked)]
        let overlapping = [RedactionUncertainInterval(start: 0.5, end: 1.5, anchorTime: 0, anchorRect: Self.box(10)),
                           RedactionUncertainInterval(start: 1, end: 2, anchorTime: 0, anchorRect: Self.box(10))]
        let range = AnnotationTiming(start: 0, end: 2)
        let track: RedactionTrack
        switch damage {
        case .noKeyframes:
            track = RedactionTrack(keyframes: [], analyzedRange: range, frameBounds: Self.frame)
        case .overlappingIntervals:
            track = RedactionTrack(keyframes: keyframes, uncertainIntervals: overlapping, analyzedRange: range,
                                   frameBounds: Self.frame)
        case .noFrameBounds:
            track = RedactionTrack(keyframes: keyframes, analyzedRange: range, frameBounds: .null)
        }
        #expect(!track.isValid)
        let damaged = Annotation(kind: .redact(Self.box(10)), track: track)
        let first = try await bench.open(annotations: [damaged])
        let package = try bench.save(first, as: "Damaged")
        first.window?.close()
        #expect(try bench.requiredFeatures(of: package) == [ProjectFeatures.redactionTracks])

        let second = try bench.reopen(package).controller
        #expect(second.editor.model.annotations == [damaged])
        #expect(second.model.unresolvedRedactionIntervals == [Self.flag(damaged, 0, 2, .invalidTrack)])
        #expect(!second.model.canExport && second.model.prepareFile() == nil)
        second.model.start(.save(bench.video.directory.appendingPathComponent("Damaged.gif")))
        await second.model.waitForExport()
        #expect(bench.exports.events.isEmpty)
        let render = second.editor.model.recordingFrameRenderer()
        #expect(throws: RedactionGateError.unresolvedTracking) { _ = try render(try Self.sampleFrame(), 0.5) }
        if damage != .noFrameBounds {
            #expect(try annotation(damaged.id, in: second).resolved(at: 0.5).redactionRect == Self.frame,
                    "an untrusted track covers the whole frame")
        }
    }

    // MARK: - Screenshots

    @Test func aReopenedScreenshotKeepsATrackedRedactionToo() throws {
        let f = try EditorFixture(); defer { f.cleanUp() }
        let tracked = Self.lostAfterOneSecond()
        let restored = EditorRestoreState(settings: Self.look, annotations: [tracked], projectName: "Shot")
        let context = EditorContext(image: f.context.image, backingScale: 2, rawURL: nil, source: "test",
                                    restored: restored)
        let model = EditorModel(context: context, preferences: f.preferences, presetStore: f.presets)
        #expect(model.annotations == [tracked])

        let state = model.screenshotProjectState()
        #expect(state.annotations == [tracked])
        try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
        let package = f.directory.appendingPathComponent("Shot.glint")
        try ProjectStore.write(GlintProject(state: .screenshot(state), source: .image(model.image)), to: package)
        let manifest = try Data(contentsOf: package.appendingPathComponent(ProjectStore.Member.manifest))
        #expect(try JSONDecoder().decode(ProjectManifest.self, from: manifest).requiredFeatures
            == [ProjectFeatures.redactionTracks])

        let snapshots = f.directory.appendingPathComponent("Snapshots")
        let project = try ProjectStore.read(from: package, snapshotRoot: snapshots)
        defer { project.discardSnapshot() }
        #expect(project.state.annotations == [tracked])
    }
}
