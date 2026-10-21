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
      --diagnose                      Print capture diagnostics and exit
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
        case "--diagnose":
            var done = false
            Task { @MainActor in
                print(await CaptureDiagnostics.run())
                done = true
            }
            while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
            return 0
        case "--render":
            return render(args)
        default:
            return nil
        }
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
        let result = Compositor.render(image: image, settings: settings, backingScale: scale, wallpaper: wallpaper)
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
