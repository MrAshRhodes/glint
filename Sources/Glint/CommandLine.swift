import AppKit
import Foundation
import GlintCapture
import GlintCore

/// Headless command-line entry points. Returns an exit code, or nil to start the GUI.
@MainActor
enum CommandLine_ {
    static let usage = """
    Usage: Glint [options]
      --version                       Print the version and exit
      --diagnose                      Print capture permission, counts and status only, then exit
      --diagnose --timing [--timing-iterations N] [--timing-cold-runs N] [--allow-screen-capture]
                                      Print cold and warm capture-to-export timings as JSON, then exit.
                                      Display pixels are only grabbed with --allow-screen-capture
      --list-presets                  Print preset names and exit
      --render IN OUT [--preset NAME] [--scale N]
                                      Beautify IN into OUT without launching the UI
      --help                          Show this help
    """

    static func run(_ args: [String]) -> Int32? {
        guard let first = args.first(where: { $0.hasPrefix("-") }) else { return nil }
        switch first {
        case "--version", "-v":
            print("Glint \(AppInfo.version)")
            return 0
        case "--help", "-h":
            print(usage)
            return 0
        case "--list-presets":
            PresetStore().presets.forEach { print($0.name) }
            return 0
        case "--diagnose", "--timing", "--timing-probe", "--timing-iterations", "--timing-cold-runs",
             "--allow-screen-capture":
            return diagnose(args)
        case "--render":
            return render(args)
        default:
            return nil
        }
    }

    private static func diagnose(_ args: [String]) -> Int32 {
        // A rejected argument list never needs the main actor, so it must not wait on one: a caller that is
        // already running on the main actor, like a test, would never see the Task below start.
        if let message = CaptureTiming.argumentError(for: args) {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            return 2
        }
        var outcome: CaptureTiming.Outcome?
        Task { @MainActor in
            outcome = await CaptureTiming.run(arguments: args, glintVersion: AppInfo.version)
        }
        while outcome == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        guard let outcome else { return 1 }
        if !outcome.output.isEmpty { print(outcome.output) }
        if !outcome.errorOutput.isEmpty { FileHandle.standardError.write(Data((outcome.errorOutput + "\n").utf8)) }
        return outcome.exitCode
    }

    private static func render(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--render"), args.count > i + 2 else {
            FileHandle.standardError.write(Data("--render needs IN and OUT paths\n".utf8))
            return 2
        }
        let input = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        let output = URL(fileURLWithPath: (args[i + 2] as NSString).expandingTildeInPath)
        func value(_ flag: String) -> String? {
            guard let k = args.firstIndex(of: flag), args.count > k + 1 else { return nil }
            return args[k + 1]
        }
        let scale: CGFloat
        if args.contains("--scale") {
            guard let value = value("--scale"), let number = Double(value), number.isFinite, number > 0 else {
                FileHandle.standardError.write(Data("--scale needs a finite number greater than zero\n".utf8))
                return 2
            }
            scale = CGFloat(number)
        } else {
            scale = 1
        }
        guard let image = GlintImageIO.load(url: input) else {
            FileHandle.standardError.write(Data("cannot read image: \(input.path)\n".utf8))
            return 1
        }
        let store = PresetStore()
        var settings = store.defaultPreset?.settings ?? .default
        if let name = value("--preset") {
            guard let p = store.presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                FileHandle.standardError.write(Data("unknown preset: \(name)\n".utf8))
                return 1
            }
            settings = p.settings
        }
        var wallpaper: CGImage?
        if settings.usesDesktopWallpaper {
            switch DesktopWallpaper.current() {
            case .success(let image): wallpaper = image
            case .failure(let error):
                FileHandle.standardError.write(Data("warning: \(error.localizedDescription)\n".utf8))
            }
        }
        let result: CGImage
        do {
            result = try Compositor.render(image: image, settings: settings, backingScale: scale, wallpaper: wallpaper)
        } catch {
            FileHandle.standardError.write(Data("cannot render image: \(error.localizedDescription)\n".utf8))
            return 1
        }
        let format: ExportFormat
        switch output.pathExtension.lowercased() {
        case "jpg", "jpeg": format = .jpeg(quality: 0.9)
        case "heic": format = .heic(quality: 0.9)
        case "tif", "tiff": format = .tiff
        default: format = .plainPNG
        }
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Exporter.write(result, to: output, format: format, scale: .original, backingScale: scale)
            print("\(output.path) (\(result.width)x\(result.height))")
            return 0
        } catch {
            FileHandle.standardError.write(Data("export failed: \(error)\n".utf8))
            return 1
        }
    }
}
