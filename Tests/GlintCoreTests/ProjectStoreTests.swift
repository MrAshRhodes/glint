import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

/// A scratch folder in the repository's ignored `.build` folder.
private struct ProjectScratch {
    let directory: URL

    init() throws {
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/TestFixtures/project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func member(_ project: URL, _ name: String) -> URL { project.appendingPathComponent(name) }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    var snapshots: URL { directory.appendingPathComponent("snapshots") }

    /// Reads with private copies kept in this scratch folder.
    func read(_ project: URL) throws -> GlintProject { try ProjectStore.read(from: project, snapshotRoot: snapshots) }

    func snapshotFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []).filter { !$0.hasPrefix(".") }
    }

    /// An opaque capture with a translucent corner, so alpha survives the round trip too.
    func capture(width: Int = 120, height: Int = 80) throws -> CGImage {
        let context = try #require(GlintBitmap.makeContext(width: width, height: height))
        context.setFillColor(RGBAColor(r: 0.2, g: 0.5, b: 0.8).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(RGBAColor(r: 0.9, g: 0.3, b: 0.1).cgColor)
        context.fill(CGRect(x: 10, y: 10, width: 40, height: 20))
        context.clear(CGRect(x: width - 12, y: height - 12, width: 12, height: 12))
        context.setFillColor(RGBAColor(r: 1, g: 1, b: 1, a: 0.37).cgColor)
        context.fill(CGRect(x: width - 12, y: height - 12, width: 12, height: 12))
        return try #require(context.makeImage())
    }

    /// Writes a PNG the settings can use as a background or watermark.
    func asset(_ name: String, color: RGBAColor) throws -> URL {
        let url = url(name)
        try Exporter.write(TestImages.solid(30, 20, color), to: url)
        return url
    }

    func writeJSON(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }
}

private func annotationsForEveryLayer() -> [Annotation] {
    var counterStyle = AnnotationStyle(color: RGBAColor(r: 0.1, g: 0.3, b: 0.9))
    counterStyle.fontSize = 24
    return [
        Annotation(z: 0, kind: .arrow(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 60, y: 40))),
        Annotation(z: 1, kind: .text(origin: CGPoint(x: 10, y: 50), string: "Typo", maxWidth: 0)),
        Annotation(z: 2, kind: .counter(center: CGPoint(x: 90, y: 20), number: 3), style: counterStyle),
        Annotation(z: 3, kind: .redact(CGRect(x: 70, y: 40, width: 30, height: 20))),
        Annotation(z: 4, kind: .pixelate(CGRect(x: 0, y: 60, width: 20, height: 20))),
        Annotation(z: 5, kind: .magnify(Magnifier(source: CGRect(x: 10, y: 10, width: 10, height: 10),
                                                   inset: CGRect(x: 40, y: 10, width: 30, height: 30)))),
    ]
}

private func styledSettings(background: URL, watermark: URL) -> RenderSettings {
    var settings = RenderSettings(padding: 24, inset: 0, cornerRadius: 9,
                                  background: .image(path: background.path, fit: .fill), aspectRatio: .r16x9,
                                  windowFrame: WindowFrameSettings(style: .macOS, dark: true, title: "Docs"),
                                  autoBalance: false)
    settings.watermark = WatermarkSettings(enabled: true, kind: .image, imagePath: watermark.path,
                                           position: .topLeft, opacity: 0.6, size: 10)
    return settings
}

@Suite("Editable projects")
struct ProjectStoreTests {
    // MARK: - Round trips

    @Test func screenshotRoundTripRendersIdenticalPixels() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let capture = try s.capture()
        let background = try s.asset("bg.png", color: RGBAColor(r: 0.1, g: 0.8, b: 0.3))
        let watermark = try s.asset("wm.png", color: .white)
        let settings = styledSettings(background: background, watermark: watermark)
        let annotations = annotationsForEveryLayer()
        let state = ScreenshotProjectState(settings: settings, annotations: annotations, backingScale: 2, source: "area")
        let expected = try Compositor.render(image: capture, settings: settings, annotations: annotations, backingScale: 2,
                                             backgroundImage: GlintImageIO.load(url: background))
        let url = s.url("Docs.glint")

        try ProjectStore.write(GlintProject(state: .screenshot(state), source: .image(capture)), to: url)
        // The originals can go away: the project carries its own copies.
        try FileManager.default.removeItem(at: background)
        try FileManager.default.removeItem(at: watermark)
        let opened = try s.read(url)

        guard case .screenshot(let restored) = opened.state, case .image(let image) = opened.source else {
            Issue.record("Expected a screenshot project")
            return
        }
        #expect(restored.annotations == annotations)
        #expect(restored.backingScale == 2 && restored.source == "area")
        let snapshot = try #require(opened.snapshotDirectory)
        #expect(snapshot.deletingLastPathComponent().standardizedFileURL == s.snapshots.standardizedFileURL)
        #expect(restored.settings.background == .image(path: snapshot.appendingPathComponent("background.png").path,
                                                       fit: .fill))
        #expect(restored.settings.watermark.imagePath == snapshot.appendingPathComponent("watermark.png").path)
        var comparable = restored.settings
        comparable.background = settings.background
        comparable.watermark.imagePath = settings.watermark.imagePath
        #expect(comparable == settings)
        try expectSamePixels(image, capture)
        let reopened = try Compositor.render(image: image, settings: restored.settings, annotations: restored.annotations,
                                             backingScale: CGFloat(restored.backingScale),
                                             backgroundImage: GlintImageIO.load(url: URL(fileURLWithPath: s.backgroundPath(restored))))
        try expectSamePixels(reopened, expected)
    }

    @Test func recordingRoundTripKeepsTheClipTrimAndExportSettings() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let clip = s.url("temp.mp4")
        try Data("clip bytes".utf8).write(to: clip)
        var trim = RecordingTrim(sourceDuration: 8)
        trim.setStart(1.5)
        trim.setEnd(6.25)
        var annotation = Annotation(kind: .redact(CGRect(x: 1, y: 2, width: 30, height: 10)))
        annotation.visibleRange = AnnotationTiming(start: 2, end: 4.5)
        var settings = RenderSettings(padding: 12, background: .solid(.black))
        settings.autoBalance = false
        let state = RecordingProjectState(settings: settings, annotations: [annotation], trim: trim,
                                          options: RecordingExportOptions(format: .mp4,
                                                                          gif: GIFExportOptions(framesPerSecond: 20, maxWidth: .w480)),
                                          duration: 8, pixelSize: CGSize(width: 160, height: 90))
        let url = s.url("Clip.glint")

        try ProjectStore.write(GlintProject(state: .recording(state), source: .video(clip)), to: url)
        let opened = try s.read(url)

        #expect(opened.state == .recording(state))
        guard case .video(let video) = opened.source else {
            Issue.record("Expected a recording project")
            return
        }
        #expect(video == opened.snapshotDirectory?.appendingPathComponent("recording.mp4"))
        #expect(try Data(contentsOf: video) == Data("clip bytes".utf8))
        #expect(FileManager.default.fileExists(atPath: clip.path), "Saving copies the clip; it never moves it")
    }

    @Test func savingOverAProjectReplacesItInOneStep() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let url = s.url("Steps.glint")
        let first = ScreenshotProjectState(settings: .default, annotations: [], backingScale: 1)
        try ProjectStore.write(GlintProject(state: .screenshot(first), source: .image(try s.capture())), to: url)
        let second = ScreenshotProjectState(settings: .default, annotations: annotationsForEveryLayer(), backingScale: 1)
        try ProjectStore.write(GlintProject(state: .screenshot(second), source: .image(try s.capture())), to: url)

        #expect(try s.read(url).state == .screenshot(second))
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.directory.path) == ["Steps.glint"])
    }

    @Test func aFailedSaveLeavesTheExistingProjectUntouched() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let url = s.url("Kept.glint")
        let state = ScreenshotProjectState(settings: .default, annotations: annotationsForEveryLayer(), backingScale: 2)
        try ProjectStore.write(GlintProject(state: .screenshot(state), source: .image(try s.capture())), to: url)
        var broken = state
        broken.settings.background = .image(path: s.url("missing.png").path, fit: .fill)

        #expect(throws: ProjectFormatError.unreadableAsset("background")) {
            try ProjectStore.write(GlintProject(state: .screenshot(broken), source: .image(try s.capture())), to: url)
        }
        #expect(throws: ProjectFormatError.mismatchedSource) {
            try ProjectStore.write(GlintProject(state: .screenshot(state), source: .video(s.url("x.mp4"))), to: url)
        }
        #expect(try s.read(url).state == .screenshot(state))
    }

    @Test func manifestDeclaresTheFormatAndNoUnknownFeatures() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let url = s.url("Plain.glint")
        let state = ScreenshotProjectState(settings: .default, annotations: [], backingScale: 1)
        try ProjectStore.write(GlintProject(state: .screenshot(state), source: .image(try s.capture())), to: url,
                               generator: "Glint 9.9.9")
        let manifest = try JSONDecoder().decode(ProjectManifest.self,
                                                from: Data(contentsOf: url.appendingPathComponent("manifest.json")))
        #expect(manifest == ProjectManifest(format: "io.github.mrashrhodes.glint.project", formatVersion: 1,
                                            requiredFeatures: [], generator: "Glint 9.9.9"))
        #expect(ProjectFeatures.required(by: .screenshot(state)).isEmpty)
        #expect(ProjectStore.isProject(url) && !ProjectStore.isProject(s.url("a.png")))
        #expect(ProjectStore.contentType.identifier == ProjectManifest.formatName)
        #expect(ProjectStore.defaultFileName(date: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
            == "Glint Project 1970-01-01 at 00.00.00.glint")
    }

    @Test func savedProjectsDoNotRecordTheUsersOwnFilePaths() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let background = try s.asset("private-folder-bg.png", color: .black)
        let watermark = try s.asset("private-folder-wm.png", color: .white)
        let state = ScreenshotProjectState(settings: styledSettings(background: background, watermark: watermark),
                                           annotations: [], backingScale: 1)
        let url = s.url("Paths.glint")
        try ProjectStore.write(GlintProject(state: .screenshot(state), source: .image(try s.capture())), to: url)
        let json = try String(contentsOf: url.appendingPathComponent("project.json"), encoding: .utf8)
        #expect(!json.contains("private-folder"))
        #expect(!json.contains(s.directory.path))
    }

    // MARK: - Versioning

    @Test func aNewerFormatVersionIsRefusedBeforeThePayloadIsRead() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let url = try savedScreenshot(in: s)
        try s.writeJSON(#"{"format":"io.github.mrashrhodes.glint.project","formatVersion":2,"somethingNew":true}"#,
                        to: url.appendingPathComponent("manifest.json"))
        try s.writeJSON(#"{"kind":"hologram"}"#, to: url.appendingPathComponent("project.json"))

        #expect(throws: ProjectFormatError.newerVersion(2)) { try s.read(url) }
        #expect(ProjectFormatError.newerVersion(2).localizedDescription
            == "This project was saved by a newer version of Glint. Update Glint to open it.")
    }

    @Test func anUnknownRequiredFeatureIsRefused() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let url = try savedScreenshot(in: s)
        try s.writeJSON(#"{"format":"io.github.mrashrhodes.glint.project","formatVersion":1,"#
                        + #""requiredFeatures":["timeTravel","holograms"]}"#,
                        to: url.appendingPathComponent("manifest.json"))

        #expect(throws: ProjectFormatError.unsupportedFeatures(["holograms", "timeTravel"])) {
            try s.read(url)
        }
        let known = ProjectManifest(requiredFeatures: ["timeTravel"])
        #expect(throws: Never.self) { try known.validate(supportedFeatures: ["timeTravel"]) }
    }

    @Test func aManifestWithoutOptionalFieldsStillOpens() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let url = try savedScreenshot(in: s)
        try s.writeJSON(#"{"format":"io.github.mrashrhodes.glint.project","formatVersion":1}"#,
                        to: url.appendingPathComponent("manifest.json"))
        #expect(throws: Never.self) { try s.read(url) }
    }

    @Test(arguments: [
        #"{"format":"com.example.other","formatVersion":1}"#,
        #"{"formatVersion":1}"#,
        "not json",
    ])
    func somethingThatIsNotAGlintManifestIsNotAProject(_ manifest: String) throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let url = try savedScreenshot(in: s)
        try s.writeJSON(manifest, to: url.appendingPathComponent("manifest.json"))
        #expect(throws: ProjectFormatError.notAProject) { try s.read(url) }
    }

    @Test func aFolderOrFileWithoutAManifestIsNotAProject() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let folder = s.url("Empty.glint")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = s.url("File.glint")
        try Data("x".utf8).write(to: file)
        #expect(throws: ProjectFormatError.notAProject) { try s.read(folder) }
        #expect(throws: ProjectFormatError.notAProject) { try s.read(file) }
    }

    @Test func aDamagedPayloadIsReportedNotGuessed() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let url = try savedScreenshot(in: s)
        try s.writeJSON(#"{"kind":"screenshot"}"#, to: url.appendingPathComponent("project.json"))
        #expect(throws: ProjectFormatError.damaged("project.json can't be read")) { try s.read(url) }
    }

    // MARK: - Opening safely

    @Test(arguments: ["manifest.json", "project.json", "source/capture.png", "source", "assets/background.png"])
    func symlinkedMembersAreRefused(_ member: String) throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let background = try s.asset("bg.png", color: .black)
        let url = try savedScreenshot(in: s, background: background)
        let target = s.url("elsewhere-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url.appendingPathComponent(member), to: target)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent(member), withDestinationURL: target)

        #expect(throws: ProjectFormatError.self) { try s.read(url) }
        do {
            _ = try s.read(url)
        } catch let error as ProjectFormatError {
            let expectedName = member == "source" ? "source/capture.png" : member
            #expect(error == .unsafeMember(expectedName) || (member == "manifest.json" && error == .notAProject),
                    "\(error)")
        }
    }

    @Test func aFolderWhereAFileShouldBeIsRefused() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let url = try savedScreenshot(in: s)
        let capture = url.appendingPathComponent("source/capture.png")
        try FileManager.default.removeItem(at: capture)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: false)
        #expect(throws: ProjectFormatError.unsafeMember("source/capture.png")) { try s.read(url) }
    }

    @Test func pathsInTheJSONAreNeverFollowed() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let outside = try s.asset("outside.png", color: .white)
        let url = try savedScreenshot(in: s)
        var state = ScreenshotProjectState(settings: .default, annotations: [], backingScale: 1)
        state.settings.background = .image(path: outside.path, fit: .fit)
        state.settings.watermark = WatermarkSettings(enabled: true, kind: .image, imagePath: outside.path)
        let json = try JSONEncoder().encode(ProjectState.screenshot(state))
        try json.write(to: url.appendingPathComponent("project.json"))

        #expect(throws: ProjectFormatError.missingMember("assets/background.png")) { try s.read(url) }

        state.settings.background = .solid(.black)
        try JSONEncoder().encode(ProjectState.screenshot(state)).write(to: url.appendingPathComponent("project.json"))
        #expect(throws: ProjectFormatError.missingMember("assets/watermark.png")) { try s.read(url) }

        // An unused watermark path is simply dropped rather than followed.
        state.settings.watermark.enabled = false
        try JSONEncoder().encode(ProjectState.screenshot(state)).write(to: url.appendingPathComponent("project.json"))
        guard case .screenshot(let opened) = try s.read(url).state else {
            Issue.record("Expected a screenshot project")
            return
        }
        #expect(opened.settings.watermark.imagePath == nil)
    }

    @Test func oversizedMembersAreRefused() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let url = try savedScreenshot(in: s)
        try Data(repeating: 0x20, count: ProjectStore.Limits.manifestBytes + 1)
            .write(to: url.appendingPathComponent("manifest.json"))
        #expect(throws: ProjectFormatError.memberTooLarge("manifest.json")) { try s.read(url) }
    }

    @Test func aCaptureThatIsNotAnImageIsReported() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let url = try savedScreenshot(in: s)
        try Data("nope".utf8).write(to: url.appendingPathComponent("source/capture.png"))
        #expect(throws: ProjectFormatError.damaged("source/capture.png isn't an image")) {
            try s.read(url)
        }
    }

    @Test func aRecordingProjectNeedsItsClip() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let clip = s.url("c.mp4")
        try Data("v".utf8).write(to: clip)
        let state = RecordingProjectState(settings: .default, annotations: [], trim: RecordingTrim(sourceDuration: 2),
                                          options: RecordingExportOptions(), duration: 2,
                                          pixelSize: CGSize(width: 10, height: 10))
        let url = s.url("Clip.glint")
        try ProjectStore.write(GlintProject(state: .recording(state), source: .video(clip)), to: url)
        try FileManager.default.removeItem(at: url.appendingPathComponent("source/recording.mp4"))
        #expect(throws: ProjectFormatError.missingMember("source/recording.mp4")) { try s.read(url) }
    }

    // MARK: - Private snapshots

    @Test func openedFilesAreCopiesThatLaterPackageChangesCannotReach() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let background = try s.asset("bg.png", color: RGBAColor(r: 0.1, g: 0.8, b: 0.3))
        let url = try savedScreenshot(in: s, background: background)
        let opened = try s.read(url)
        guard case .screenshot(let state) = opened.state else {
            Issue.record("Expected a screenshot project")
            return
        }
        let path = s.backgroundPath(state)
        #expect(!path.hasPrefix(url.standardizedFileURL.path))
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        // Another process swaps the package's asset for a symlink after the project was opened.
        let member = url.appendingPathComponent("assets/background.png")
        try FileManager.default.removeItem(at: member)
        try FileManager.default.createSymbolicLink(at: member, withDestinationURL: s.url("elsewhere.png"))

        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
        #expect(throws: ProjectFormatError.unsafeMember("assets/background.png")) { try s.read(url) }

        opened.discardSnapshot()
        #expect(s.snapshotFolders().isEmpty)
    }

    @Test func aFailedReadLeavesNoSnapshotBehind() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let background = try s.asset("bg.png", color: .black)
        let url = try savedScreenshot(in: s, background: background)
        // The background is copied before the broken capture is found.
        try Data("nope".utf8).write(to: url.appendingPathComponent("source/capture.png"))
        #expect(throws: ProjectFormatError.self) { try s.read(url) }
        #expect(s.snapshotFolders().isEmpty)
    }

    @Test func recordingClipsAreCopiedIntoTheSnapshot() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let clip = s.url("c.mp4")
        try Data("clip".utf8).write(to: clip)
        let state = RecordingProjectState(settings: .default, annotations: [], trim: RecordingTrim(sourceDuration: 2),
                                          options: RecordingExportOptions(), duration: 2,
                                          pixelSize: CGSize(width: 10, height: 10))
        let url = s.url("Clip.glint")
        try ProjectStore.write(GlintProject(state: .recording(state), source: .video(clip)), to: url)
        let opened = try s.read(url)
        guard case .video(let video) = opened.source else {
            Issue.record("Expected a recording project")
            return
        }
        try FileManager.default.removeItem(at: url)
        #expect(try Data(contentsOf: video) == Data("clip".utf8), "The open clip doesn't depend on the package")
        opened.discardSnapshot()
        #expect(!FileManager.default.fileExists(atPath: video.path))
    }

    @Test func removingAllSnapshotsClearsTheRoot() throws {
        let s = try ProjectScratch(); defer { s.cleanUp() }
        let url = try savedScreenshot(in: s, background: try s.asset("bg.png", color: .black))
        _ = try s.read(url)
        _ = try s.read(url)
        #expect(s.snapshotFolders().count == 2)
        ProjectStore.removeAllSnapshots(in: s.snapshots)
        #expect(s.snapshotFolders().isEmpty)
    }

    @Test(arguments: [("pixelSize", [1e20, 90] as [Double]), ("pixelSize", [160.5, 90]), ("pixelSize", [0, 90]),
                      ("duration", [86_401] as [Double])])
    func recordingStatesWithImpossibleSizesAreRefused(_ key: String, _ value: [Double]) throws {
        let state = RecordingProjectState(settings: .default, annotations: [], trim: RecordingTrim(sourceDuration: 8),
                                          options: RecordingExportOptions(), duration: 8,
                                          pixelSize: CGSize(width: 160, height: 90))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json[key] = key == "duration" ? value[0] : value as Any
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RecordingProjectState.self, from: data) }
    }

    // MARK: - Codable recording types

    @Test func trimDecodingRefusesRangesTheEditorCouldNotProduce() throws {
        var trim = RecordingTrim(sourceDuration: 10)
        trim.setStart(2)
        trim.setEnd(7)
        let data = try JSONEncoder().encode(trim)
        #expect(try JSONDecoder().decode(RecordingTrim.self, from: data) == trim)
        for bad in [#"{"sourceDuration":10,"start":5,"end":4}"#, #"{"sourceDuration":10,"start":-1,"end":4}"#,
                    #"{"sourceDuration":10,"start":0,"end":11}"#, #"{"sourceDuration":10,"start":1,"end":1.1}"#,
                    #"{"sourceDuration":-1,"start":0,"end":0}"#,
                    #"{"sourceDuration":0,"start":5e-10,"end":0}"#] {
            #expect(throws: DecodingError.self, "\(bad)") { try JSONDecoder().decode(RecordingTrim.self, from: Data(bad.utf8)) }
        }
    }

    @Test func exportOptionsDecodeMissingKeysAsDefaults() throws {
        #expect(try JSONDecoder().decode(RecordingExportOptions.self, from: Data("{}".utf8)) == RecordingExportOptions())
        let options = RecordingExportOptions(format: .mp4, gif: GIFExportOptions(framesPerSecond: 10, maxWidth: .original))
        #expect(try JSONDecoder().decode(RecordingExportOptions.self, from: JSONEncoder().encode(options)) == options)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GIFExportOptions.self, from: Data(#"{"framesPerSecond":7}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RecordingExportOptions.self, from: Data(#"{"format":"webm"}"#.utf8))
        }
    }

    // MARK: - Helpers

    private func savedScreenshot(in s: ProjectScratch, background: URL? = nil) throws -> URL {
        var settings = RenderSettings.default
        if let background { settings.background = .image(path: background.path, fit: .fill) }
        let state = ScreenshotProjectState(settings: settings, annotations: annotationsForEveryLayer(), backingScale: 2)
        let url = s.url("Saved-\(UUID().uuidString).glint")
        try ProjectStore.write(GlintProject(state: .screenshot(state), source: .image(try s.capture())), to: url)
        return url
    }
}

private extension ProjectScratch {
    func backgroundPath(_ state: ScreenshotProjectState) -> String {
        if case .image(let path, _) = state.settings.background { return path }
        return ""
    }
}
