import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import GlintCore

@Suite("Export & preferences")
struct ExportAndPrefsTests {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("glint-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    let utc = TimeZone(identifier: "UTC")!
    // 2026-10-21 15:04:05 UTC
    var date: Date { DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                    year: 2026, month: 10, day: 21, hour: 15, minute: 4, second: 5).date! }

    @Test func fileNames() {
        #expect(FileNaming.fileName(template: "Glint-{datetime}", date: date, timeZone: utc) == "Glint-2026-10-21-15.04.05")
        let id = UUID()
        #expect(FileNaming.fileName(template: "{datetime}-{uuid}", date: date, uuid: id, timeZone: utc) == "2026-10-21-15.04.05-\(id.uuidString)")
        #expect(FileNaming.fileName(template: "  ", date: date, timeZone: utc) == "Glint-2026-10-21-15.04.05")
        #expect(FileNaming.fileName(template: "a/b:c", date: date, timeZone: utc) == "a-b-c")
    }

    @Test func outputPathsAndCollisions() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let paths = OutputPaths(historyDirectory: dir.appendingPathComponent("history"), saveDirectory: dir.appendingPathComponent("Desktop"), timeZone: utc)
        let id = UUID()
        let raw = try #require(paths.rawURL(date: date, uuid: id))
        #expect(raw.deletingLastPathComponent().lastPathComponent == "Raw")
        #expect(raw.lastPathComponent == "Glint-2026-10-21-15.04.05-\(id.uuidString).png")

        let out1 = try #require(paths.outputURL(date: date))
        #expect(out1.path.hasSuffix("history/Output/Glint-2026-10-21-15.04.05.png"))
        try Data([1]).write(to: out1)
        let out2 = try #require(paths.outputURL(date: date))
        #expect(out2.lastPathComponent == "Glint-2026-10-21-15.04.05-2.png")
        try Data([1]).write(to: out2)
        #expect(try #require(paths.outputURL(date: date)).lastPathComponent == "Glint-2026-10-21-15.04.05-3.png")

        let save = paths.saveURL(date: date, format: .jpeg(quality: 0.8))
        #expect(save.lastPathComponent == "Glint-2026-10-21-15.04.05.jpg")
        #expect(FileManager.default.fileExists(atPath: save.deletingLastPathComponent().path))

        let noHistory = OutputPaths(historyDirectory: nil, saveDirectory: dir)
        #expect(noHistory.rawURL() == nil && noHistory.outputURL() == nil)
    }

    @Test func formatsEncodeAndDecode() throws {
        let img = TestImages.framed(width: 64, height: 48, margins: EdgeMargins(top: 4, left: 4, bottom: 4, right: 4))
        for format in [ExportFormat.plainPNG, .png(interlaced: true), .jpeg(quality: 0.7), .tiff] {
            let data = try Exporter.data(for: img, format: format)
            let back = try #require(GlintImageIO.load(data: data), "\(format)")
            #expect(back.width == 64 && back.height == 48)
        }
        let png = try Exporter.data(for: img, format: .plainPNG)
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        let jpg = try Exporter.data(for: img, format: .jpeg(quality: 0.7))
        #expect(Array(jpg.prefix(2)) == [0xFF, 0xD8])
        #expect(try Exporter.data(for: img, format: .jpeg(quality: 0.2)).count < Exporter.data(for: img, format: .jpeg(quality: 0.95)).count)
    }

    @Test func jpegFlattensTransparencyOntoWhite() throws {
        let clear = TestImages.solid(10, 10, .clear)
        let back = try #require(GlintImageIO.load(data: Exporter.data(for: clear, format: .jpeg(quality: 0.9))))
        #expect(TestImages.pixel(back, 5, 5).r > 240)
    }

    @Test func scaleOptions() throws {
        let img = TestImages.solid(200, 100, .white) // captured at 2×
        func size(_ s: ExportScale) throws -> (Int, Int) {
            let b = try #require(GlintImageIO.load(data: Exporter.data(for: img, scale: s, backingScale: 2)))
            return (b.width, b.height)
        }
        #expect(try size(.original) == (200, 100))
        #expect(try size(.x1) == (100, 50))
        #expect(try size(.x2) == (200, 100))
    }

    @Test func heicEncodesWhenAvailable() throws {
        let img = TestImages.solid(64, 64, RGBAColor(hex: "#336699")!)
        if let data = try? Exporter.data(for: img, format: .heic(quality: 0.8)) {
            #expect(data.count > 20)
        }
    }

    @Test func writeCreatesFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sub/out.png")
        try Exporter.write(TestImages.solid(8, 8, .red), to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(GlintImageIO.load(url: url)?.width == 8)
    }

    @Test func clipboardRoundTrip() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("glint.test.\(UUID().uuidString)"))
        #expect(Exporter.copyToClipboard(TestImages.solid(12, 9, .red), pasteboard: pb))
        let data = try #require(pb.data(forType: .png))
        #expect(GlintImageIO.load(data: data)?.height == 9)
        pb.releaseGlobally()
    }

    @Test func preferencesDefaultsAndRoundTrip() throws {
        let suite = "glint.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = AppPreferences(defaults: defaults)
        #expect(p.saveDirectory.lastPathComponent == "Desktop")
        #expect(p.autoBalance && p.saveHistory && p.openEditorAfterCapture && !p.copyToClipboardAfterCapture)
        #expect(p.fileNameTemplate == "Glint-{datetime}")
        #expect(p.theme == .system && p.exportFormat == .plainPNG && p.exportScale == .original)

        p.autoBalance = false
        p.fileNameTemplate = "Shot-{datetime}"
        p.saveDirectory = URL(fileURLWithPath: "/tmp/x")
        p.theme = .dark
        p.exportFormat = .jpeg(quality: 0.5)
        p.autoRedactOptions = SensitiveInfoOptions(categories: [.email], customWords: ["foo"])
        var rs = RenderSettings(); rs.padding = 99
        p.lastRenderSettings = rs
        let q = AppPreferences(defaults: defaults)
        #expect(!q.autoBalance && q.fileNameTemplate == "Shot-{datetime}" && q.saveDirectory.path == "/tmp/x" && q.theme == .dark)
        #expect(q.exportFormat == .jpeg(quality: 0.5))
        #expect(q.autoRedactOptions.customWords == ["foo"] && q.autoRedactOptions.categories == [.email])
        #expect(q.lastRenderSettings?.padding == 99)
        #expect(q.outputPaths.fileNameTemplate == "Shot-{datetime}")
        q.saveHistory = false
        #expect(q.outputPaths.historyDirectory == nil)

        q.resetToDefaults()
        #expect(q.autoBalance && q.theme == .system)
    }

    @Test func resetClearsLegacyRedactionStyle() throws {
        let suite = "glint.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("blur", forKey: AppPreferences.Key.redactStyle)
        AppPreferences(defaults: defaults).resetToDefaults()
        #expect(defaults.object(forKey: AppPreferences.Key.redactStyle) == nil)
    }

    @Test func hotkeys() throws {
        let combo = HotkeyAction.captureArea.defaultCombo
        #expect(combo.displayString == "⌃⌥⌘4")
        #expect(HotkeyAction.captureAreaToClipboard.defaultCombo.displayString == "⌃⌥⌘5")
        #expect(combo.carbonModifiers == 0x1000 | 0x800 | 0x100)
        #expect(Set(HotkeyAction.allCases.map { $0.defaultCombo }).count == HotkeyAction.allCases.count)

        let suite = "glint.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = AppPreferences(defaults: defaults)
        #expect(p.hotkey(for: .captureWindow) == HotkeyAction.captureWindow.defaultCombo)
        let custom = KeyCombo(keyCode: 0, modifiers: [.command, .shift])
        p.setHotkey(custom, for: .captureArea)
        #expect(AppPreferences(defaults: defaults).hotkey(for: .captureArea) == custom)
        #expect(custom.displayString == "⇧⌘A")
        #expect(AppPreferences(defaults: defaults).hotkey(for: .repeatLast) == HotkeyAction.repeatLast.defaultCombo)
    }
}
