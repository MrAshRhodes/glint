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
    /// The file behind the menu-bar display's current Space wallpaper, found without decoding it so the decode can
    /// run off the main thread.
    @MainActor
    public static func currentURL() -> URL? {
        guard let screen = NSScreen.screens.first else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    /// The menu-bar display's current Space, independent of which app window has focus.
    @MainActor
    public static func current() -> Result<CGImage, DesktopWallpaperError> {
        load(url: currentURL())
    }

    /// `load(url:)`, kept in `cache` until the wallpaper file changes. Failures are not kept. The primary image is
    /// decoded here, so it is kept apart from a plain load of the same file, which reads the first image.
    public static func load(url: URL?, using cache: ImageFileCache) -> Result<CGImage, DesktopWallpaperError> {
        guard let url, url.isFileURL else { return load(url: url) }
        var failure: DesktopWallpaperError?
        let image = cache.image(at: url, variant: "wallpaper") { file in
            switch load(url: file) {
            case .success(let image): return image
            case .failure(let error): failure = error; return nil
            }
        }
        if let image { return .success(image) }
        return .failure(failure ?? .unreadable(url.lastPathComponent))
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
