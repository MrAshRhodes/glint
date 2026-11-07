import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

/// A scratch folder in the repository's ignored `.build` folder.
private struct TrackedProjectScratch {
    let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestFixtures/tracked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var snapshots: URL { directory.appendingPathComponent("snapshots") }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func read(_ package: URL) throws -> GlintProject { try ProjectStore.read(from: package, snapshotRoot: snapshots) }

    func snapshotFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// Saves a recording project around a stand-in clip.
    func saveRecording(_ state: RecordingProjectState) throws -> URL {
        let clip = directory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        try Data("clip".utf8).write(to: clip)
        let package = directory.appendingPathComponent("Recording-\(UUID().uuidString).glint")
        try ProjectStore.write(GlintProject(state: .recording(state), source: .video(clip)), to: package)
        return package
    }

    func saveScreenshot(_ state: ScreenshotProjectState) throws -> URL {
        let package = directory.appendingPathComponent("Screenshot-\(UUID().uuidString).glint")
        let capture = TestImages.solid(40, 30, .white)
        try ProjectStore.write(GlintProject(state: .screenshot(state), source: .image(capture)), to: package)
        return package
    }

    func manifest(of package: URL) throws -> ProjectManifest {
        try JSONDecoder().decode(ProjectManifest.self,
                                 from: Data(contentsOf: package.appendingPathComponent(ProjectStore.Member.manifest)))
    }

    func projectJSON(of package: URL) throws -> String {
        try String(contentsOf: package.appendingPathComponent(ProjectStore.Member.project), encoding: .utf8)
    }
}

private let frame = CGRect(x: 0, y: 0, width: 160, height: 90)

private func box(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 20, width: 24, height: 12) }

/// Every kind of track data, for a 2 s clip: tracker and manual keyframes, a reviewed and an unreviewed flagged
/// interval inside the analysed range, and an analysed range that ends a second before the clip does.
private func fullTrack() -> RedactionTrack {
    RedactionTrack(
        keyframes: [RedactionKeyframe(time: 0, rect: box(10), source: .tracked),
                    RedactionKeyframe(time: 0.2, rect: box(18), source: .tracked),
                    RedactionKeyframe(time: 0.4, rect: box(26), source: .tracked),
                    RedactionKeyframe(time: 0.6, rect: box(60), source: .manual)],
        uncertainIntervals: [RedactionUncertainInterval(start: 0.4, end: 0.8, anchorTime: 0.4, anchorRect: box(26),
                                                        resolution: .keyframes),
                             RedactionUncertainInterval(start: 0.8, end: 1, anchorTime: 0.6, anchorRect: box(60))],
        analyzedRange: AnnotationTiming(start: 0, end: 1), frameBounds: frame)
}

private func recordingState(_ annotations: [Annotation]) -> RecordingProjectState {
    RecordingProjectState(settings: .default, annotations: annotations, trim: RecordingTrim(sourceDuration: 2),
                          options: RecordingExportOptions(), duration: 2, pixelSize: CGSize(width: 160, height: 90))
}

private func screenshotState(_ annotations: [Annotation]) -> ScreenshotProjectState {
    ScreenshotProjectState(settings: .default, annotations: annotations, backingScale: 2)
}

@Suite("Tracked redactions in editable projects")
struct TrackedRedactionProjectTests {
    // MARK: - The feature string

    @Test func theFeatureHasAStableNameThisBuildSupports() {
        #expect(ProjectFeatures.redactionTracks == "redactionTracks", "a released feature string is never renamed")
        #expect(ProjectFeatures.supported == ["redactionTracks"])
    }

    @Test func aProjectRequiresTheFeatureExactlyWhenSomeAnnotationIsTracked() {
        let plain = [Annotation(z: 0, kind: .redact(box(10))), Annotation(z: 1, kind: .pixelate(box(60)))]
        let tracked = Annotation(z: 2, kind: .redact(box(100)), track: fullTrack())
        for annotations in [[], plain] {
            #expect(ProjectFeatures.required(by: .screenshot(screenshotState(annotations))).isEmpty)
            #expect(ProjectFeatures.required(by: .recording(recordingState(annotations))).isEmpty)
        }
        for annotations in [[tracked], plain + [tracked]] {
            #expect(ProjectFeatures.required(by: .screenshot(screenshotState(annotations))) == ["redactionTracks"])
            #expect(ProjectFeatures.required(by: .recording(recordingState(annotations))) == ["redactionTracks"])
        }
    }

    @Test func theSavedManifestNamesTheFeatureOnlyForTrackedProjects() throws {
        let s = try TrackedProjectScratch(); defer { s.cleanUp() }
        let plain = [Annotation(kind: .redact(box(10)))]
        let tracked = plain + [Annotation(kind: .pixelate(box(60)), track: fullTrack())]

        #expect(try s.manifest(of: s.saveRecording(recordingState(plain))).requiredFeatures.isEmpty)
        #expect(try s.manifest(of: s.saveScreenshot(screenshotState(plain))).requiredFeatures.isEmpty)
        #expect(try s.manifest(of: s.saveRecording(recordingState(tracked))).requiredFeatures == ["redactionTracks"])
        #expect(try s.manifest(of: s.saveScreenshot(screenshotState(tracked))).requiredFeatures == ["redactionTracks"])
    }

    @Test func aBuildWithoutTheFeatureRefusesTrackedProjectsButStillOpensOthers() throws {
        let s = try TrackedProjectScratch(); defer { s.cleanUp() }
        let tracked = try s.manifest(of: s.saveRecording(recordingState([
            Annotation(kind: .redact(box(10)), track: fullTrack()),
        ])))
        let plain = try s.manifest(of: s.saveRecording(recordingState([Annotation(kind: .redact(box(10)))])))

        // Builds from before the feature existed support none, which is what an empty set stands for.
        #expect(throws: ProjectFormatError.unsupportedFeatures(["redactionTracks"])) {
            try tracked.validate(supportedFeatures: [])
        }
        #expect(throws: Never.self) { try plain.validate(supportedFeatures: []) }
        #expect(throws: Never.self) { try tracked.validate() }
        #expect(ProjectFormatError.unsupportedFeatures(["redactionTracks"]).localizedDescription
            == "This project uses features this version of Glint doesn't support (redactionTracks). "
            + "Update Glint to open it.")
    }

    // MARK: - Round trips

    @Test func projectsWithoutTracksKeepTheirOldEncodingAndDecodeUntracked() throws {
        let s = try TrackedProjectScratch(); defer { s.cleanUp() }
        var timed = Annotation(kind: .redact(box(10)))
        timed.visibleRange = AnnotationTiming(start: 0.5, end: 1.5)
        let state = recordingState([timed, Annotation(kind: .pixelate(box(60)))])
        let package = try s.saveRecording(state)

        #expect(try !s.projectJSON(of: package).contains("\"track\""), "an untracked annotation writes no track key")
        let opened = try s.read(package)
        defer { opened.discardSnapshot() }
        #expect(opened.state == .recording(state))
        #expect(opened.state.annotations.allSatisfy { $0.track == nil })
        #expect(ProjectFeatures.required(by: opened.state).isEmpty)
    }

    @Test func aRecordingKeepsEveryDetailOfItsTracks() throws {
        let s = try TrackedProjectScratch(); defer { s.cleanUp() }
        let track = fullTrack()
        let tracked = Annotation(z: 1, kind: .redact(box(10)), visibleRange: AnnotationTiming(start: 0.1, end: 1.9),
                                 track: track)
        let manual = RedactionTrack(keyframes: [RedactionKeyframe(time: 1, rect: box(80), source: .manual)],
                                    uncertainIntervals: [RedactionUncertainInterval(start: 1, end: 2, anchorTime: 1,
                                                                                    anchorRect: box(80),
                                                                                    resolution: .fixedCover)],
                                    analyzedRange: AnnotationTiming(start: 0, end: 2), frameBounds: frame)
        let state = recordingState([Annotation(z: 0, kind: .redact(box(100))), tracked,
                                    Annotation(z: 2, kind: .pixelate(box(80)), track: manual)])
        let package = try s.saveRecording(state)

        let opened = try s.read(package)
        defer { opened.discardSnapshot() }
        #expect(opened.state == .recording(state))
        let reopened = try #require(opened.state.annotations.first { $0.id == tracked.id })
        let restored = try #require(reopened.track)
        #expect(restored == track && restored.isValid)
        #expect(restored.keyframes.map(\.source) == [.tracked, .tracked, .tracked, .manual])
        #expect(restored.uncertainIntervals.map(\.resolution) == [.keyframes, nil])
        #expect(restored.analyzedRange == AnnotationTiming(start: 0, end: 1) && restored.frameBounds == frame)
        // The reopened track places the redaction exactly where the saved one did, frame by frame.
        for time in stride(from: 0.0, through: 2.0, by: 1.0 / 30) {
            #expect(reopened.resolved(at: time) == tracked.resolved(at: time), "t = \(time)")
            #expect(reopened.editingView(at: time) == tracked.editingView(at: time), "t = \(time)")
        }
        let visible = AnnotationTiming(start: 0.1, end: 1.9)
        #expect(restored.unresolvedIntervals(visibleRange: visible, sourceDuration: 2)
            == track.unresolvedIntervals(visibleRange: visible, sourceDuration: 2))
        #expect(RedactionGate.unresolvedIntervals(in: opened.state.annotations, sourceDuration: 2)
            == RedactionGate.unresolvedIntervals(in: state.annotations, sourceDuration: 2))
    }

    @Test func aScreenshotProjectNeverLosesATrackItWasHanded() throws {
        let s = try TrackedProjectScratch(); defer { s.cleanUp() }
        let state = screenshotState([Annotation(kind: .pixelate(box(10)), track: fullTrack())])
        let opened = try s.read(s.saveScreenshot(state))
        defer { opened.discardSnapshot() }
        #expect(opened.state == .screenshot(state))
        #expect(opened.state.annotations.first?.track == fullTrack())
    }

    @Test func aSecondSaveOfAReopenedProjectKeepsTheTracksToo() throws {
        let s = try TrackedProjectScratch(); defer { s.cleanUp() }
        let state = recordingState([Annotation(kind: .redact(box(10)), track: fullTrack())])
        let first = try s.read(s.saveRecording(state))
        defer { first.discardSnapshot() }
        let again = s.directory.appendingPathComponent("Again.glint")
        try ProjectStore.write(first, to: again)

        let second = try s.read(again)
        defer { second.discardSnapshot() }
        #expect(second.state == .recording(state))
        #expect(try s.manifest(of: again).requiredFeatures == ["redactionTracks"])
    }

    // MARK: - Corrupt and oversized tracks

    @Test func tracksThatCannotBeTrustedAreKeptAsTheyAreAndStayBlocked() throws {
        let s = try TrackedProjectScratch(); defer { s.cleanUp() }
        let overlapping = RedactionTrack(
            keyframes: [RedactionKeyframe(time: 0, rect: box(10), source: .tracked)],
            uncertainIntervals: [RedactionUncertainInterval(start: 0, end: 1, anchorTime: 0, anchorRect: box(10),
                                                            resolution: .fixedCover),
                                 RedactionUncertainInterval(start: 0.5, end: 1.5, anchorTime: 0, anchorRect: box(10),
                                                            resolution: .fixedCover)],
            analyzedRange: AnnotationTiming(start: 0, end: 2), frameBounds: frame)
        let empty = RedactionTrack(keyframes: [], analyzedRange: AnnotationTiming(start: 0, end: 2), frameBounds: frame)
        // No frame bounds: the decoder falls back to `.null`, which JSON can't hold, so saving it again must not throw.
        let boundlessJSON = #"{"analyzedRange":{"start":0,"end":2},"keyframes":[{"time":0.5,"rect":[[10,10],[5,5]]}]}"#
        let boundless = try JSONDecoder().decode(RedactionTrack.self, from: Data(boundlessJSON.utf8))
        #expect(try !String(decoding: JSONEncoder().encode(boundless), as: UTF8.self).contains("frameBounds"))

        for track in [overlapping, empty, boundless] {
            #expect(!track.isValid)
            let annotation = Annotation(kind: .redact(box(10)), track: track)
            let opened = try s.read(s.saveRecording(recordingState([annotation])))
            defer { opened.discardSnapshot() }
            let restored = try #require(opened.state.annotations.first)
            #expect(restored.track == track, "nothing is repaired, dropped or trusted")
            let gate = RedactionGate.unresolvedIntervals(in: [restored], sourceDuration: 2)
            #expect(gate.map(\.reason) == [.invalidTrack])
            #expect(RedactionGate.blocksExport(gate, range: 0...2))
            #expect(throws: RedactionGateError.unresolvedTracking) { try RedactionGate.validate([restored], at: 1) }
        }
    }

    @Test func aTrackHoldingMoreThanAnyRealRecordingCouldProduceIsRefused() throws {
        func json(keyframes: Int, intervals: Int) -> Data {
            let keyframe = #"{"time":0,"rect":[[0,0],[1,1]],"source":"tracked"}"#
            let interval = #"{"start":0,"end":1,"anchorTime":0,"anchorRect":[[0,0],[1,1]]}"#
            return Data((#"{"analyzedRange":{"start":0,"end":1},"frameBounds":[[0,0],[160,90]],"keyframes":["#
                + Array(repeating: keyframe, count: keyframes).joined(separator: ",")
                + #"],"uncertainIntervals":["#
                + Array(repeating: interval, count: intervals).joined(separator: ",") + "]}").utf8)
        }
        let maxIntervals = RedactionTrack.maxUncertainIntervals, maxKeyframes = RedactionTrack.maxKeyframes
        let full = try JSONDecoder().decode(RedactionTrack.self, from: json(keyframes: 1, intervals: maxIntervals))
        #expect(full.uncertainIntervals.count == maxIntervals)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RedactionTrack.self, from: json(keyframes: 1, intervals: maxIntervals + 1))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RedactionTrack.self, from: json(keyframes: maxKeyframes + 1, intervals: 0))
        }
        // A 10-minute recording at 30 fps is far below the cap.
        #expect(RedactionTrack.maxKeyframes >= 10 * 60 * 30 * 4)
    }

    @Test func aPackageWithAnOversizedTrackIsRefusedAndLeavesNothingBehind() throws {
        let s = try TrackedProjectScratch(); defer { s.cleanUp() }
        let flagged = (0...RedactionTrack.maxUncertainIntervals).map {
            RedactionUncertainInterval(start: Double($0), end: Double($0) + 0.5, anchorTime: 0, anchorRect: box(10))
        }
        let swollen = RedactionTrack(keyframes: [RedactionKeyframe(time: 0, rect: box(10), source: .tracked)],
                                     uncertainIntervals: flagged,
                                     analyzedRange: AnnotationTiming(start: 0, end: 2), frameBounds: frame)
        let package = try s.saveRecording(recordingState([Annotation(kind: .redact(box(10)), track: swollen)]))

        #expect(throws: ProjectFormatError.damaged("project.json can't be read")) { try s.read(package) }
        #expect(s.snapshotFolders().isEmpty)
    }

    @Test func aProjectTooBigToReopenIsNotSaved() throws {
        let state = ProjectState.recording(recordingState([Annotation(kind: .redact(box(10)), track: fullTrack())]))
        let size = try ProjectStore.encodeProject(state).count

        let refusal = ProjectFormatError.writeFailed("the project holds more annotation data than Glint can reopen.")
        #expect(throws: Never.self) { try ProjectStore.encodeProject(state, limit: size) }
        #expect(throws: refusal) { try ProjectStore.encodeProject(state, limit: size - 1) }
    }
}
