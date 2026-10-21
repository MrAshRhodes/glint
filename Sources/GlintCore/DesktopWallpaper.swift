import AppKit
import ImageIO

public enum DesktopWallpaperError: LocalizedError, Equatable {
    case unavailable
    case rotatingFolder
    case unreadable(String)

    public var errorDescription: String? {
        let reason: String
        switch self {
        case .unavailable:
            reason = "macOS did not provide a wallpaper image for the main display's current Space."
        case .rotatingFolder:
            reason = "macOS provided a rotating wallpaper folder, not the currently displayed image."
        case .unreadable(let name):
            reason = "Glint could not read the desktop wallpaper \"\(name)\"."
        }
        return "\(reason) Glint is using your other background instead."
    }
}

public enum DesktopWallpaper {
    /// The menu-bar display's current Space, independent of which app window has focus.
    @MainActor
    public static func current() -> Result<CGImage, DesktopWallpaperError> {
        guard let screen = NSScreen.screens.first else { return .failure(.unavailable) }
        return load(url: NSWorkspace.shared.desktopImageURL(for: screen))
    }

    /// Reads only the wallpaper file, never a capture of desktop windows or icons.
    public static func load(url: URL?) -> Result<CGImage, DesktopWallpaperError> {
        guard let url else { return .failure(.unavailable) }
        guard url.isFileURL else { return .failure(.unreadable(url.lastPathComponent)) }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .failure(.rotatingFolder)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = GlintImageIO.decode(source, index: CGImageSourceGetPrimaryImageIndex(source)) else {
            return .failure(.unreadable(url.lastPathComponent))
        }
        // Dynamic HEIC wallpapers use their primary still, not a guessed time-of-day frame.
        return .success(image)
    }
}
