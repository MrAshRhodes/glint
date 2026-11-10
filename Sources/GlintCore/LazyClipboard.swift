import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// The image on the clipboard, whose PNG and TIFF are made after the clipboard changes instead of while the copy waits.
///
/// The pasteboard keeps this object and calls `pasteboard(_:item:provideDataForType:)` when an app pastes. The PNG is
/// encoded on a background queue as soon as the image is published, so a paste normally finds it ready, and a saved
/// copy of the same image reuses its bytes (`Exporter.data` asks `sharedPNG`). The TIFF is uncompressed and only legacy
/// apps ask for it, so it is made when requested, from the PNG: the image itself is released as soon as the PNG
/// exists, which leaves the compressed PNG, not the pixels or an uncompressed TIFF, in memory while the image stays on
/// the clipboard. The pasteboard calls `pasteboardFinishedWithDataProvider` once the clipboard is replaced or every
/// representation has been taken, and everything is released then.
final class LazyImageClipboard: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    typealias Encoder = @Sendable (CGImage, ExportScale, CGFloat) throws -> Data

    let scale: ExportScale
    let backingScale: CGFloat
    private let encoder: Encoder
    /// Tells whether a given image is the one published. An image never changes, so the same object means the same
    /// pixels, and a released one cannot be mistaken for a new image that reuses its address.
    private weak var source: CGImage?

    private enum State {
        case pending(CGImage)
        case encoding
        case ready(Data)
        case failed
        case finished
    }

    private let condition = NSCondition()
    private var state: State
    private weak var pasteboard: NSPasteboard?
    private var changeCount = 0

    static let defaultEncoder: Encoder = { image, scale, backingScale in
        try Exporter.encode(image, format: .plainPNG, scale: scale, backingScale: backingScale)
    }

    init(image: CGImage, scale: ExportScale, backingScale: CGFloat, encoder: @escaping Encoder = LazyImageClipboard.defaultEncoder) {
        self.scale = scale
        self.backingScale = backingScale
        self.encoder = encoder
        self.source = image
        self.state = .pending(image)
        super.init()
    }

    // MARK: Publishing

    /// Replaces the contents of `pasteboard` with `image` and starts encoding it. False when the pasteboard refuses it.
    @discardableResult
    static func publish(_ image: CGImage, scale: ExportScale, backingScale: CGFloat, on pasteboard: NSPasteboard,
                        encoder: @escaping Encoder = LazyImageClipboard.defaultEncoder) -> Bool {
        let provider = LazyImageClipboard(image: image, scale: scale, backingScale: backingScale, encoder: encoder)
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: [.png, .tiff]) else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        provider.pasteboard = pasteboard
        provider.changeCount = pasteboard.changeCount
        register(provider)
        DispatchQueue.global(qos: .userInitiated).async { _ = provider.pngData() }
        return true
    }

    // MARK: NSPasteboardItemDataProvider

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let data: Data?
        switch type {
        case .png: data = pngData()
        case .tiff: data = tiffData()
        default: data = nil
        }
        if let data { item.setData(data, forType: type) }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        condition.lock()
        state = .finished
        condition.broadcast()
        condition.unlock()
        Self.unregister(self)
    }

    // MARK: Representations

    /// The PNG, encoded by whoever asks first while everyone else waits for it. Nil once the pasteboard has finished
    /// with this image or when encoding failed.
    func pngData() -> Data? {
        switch claimOrWait() {
        case .done(let data): return data
        case .encode(let image):
            let png = try? encoder(image, scale, backingScale)
            condition.lock()
            if case .finished = state {} else { state = png.map { .ready($0) } ?? .failed }
            condition.broadcast()
            condition.unlock()
            return png
        }
    }

    /// The TIFF, made from the PNG so that no second copy of the pixels has to stay around and both
    /// representations carry the same pixels, size and density.
    func tiffData() -> Data? {
        guard let png = pngData(), let source = CGImageSourceCreateWithData(png as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let density = Exporter.densityFactor(scale: scale, backingScale: backingScale)
        return try? Exporter.encode(decoded, format: .tiff, scale: .original, backingScale: density)
    }

    private enum Claim {
        case encode(CGImage)
        case done(Data?)
    }

    private func claimOrWait() -> Claim {
        condition.lock()
        defer { condition.unlock() }
        while true {
            switch state {
            case .pending(let image):
                state = .encoding
                return .encode(image)
            case .encoding: condition.wait()
            case .ready(let png): return .done(png)
            case .failed, .finished: return .done(nil)
            }
        }
    }

    private var isFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        if case .finished = state { return true }
        return false
    }

    private func matches(_ image: CGImage, scale: ExportScale, backingScale: CGFloat) -> Bool {
        source === image && self.scale == scale && self.backingScale == backingScale
    }

    // MARK: Live images

    private struct Weak { weak var provider: LazyImageClipboard? }
    private static let registryLock = NSLock()
    private static var registry: [Weak] = []

    private static func register(_ provider: LazyImageClipboard) {
        registryLock.withLock {
            registry.removeAll { $0.provider == nil }
            registry.append(Weak(provider: provider))
        }
    }

    private static func unregister(_ provider: LazyImageClipboard) {
        registryLock.withLock { registry.removeAll { $0.provider == nil || $0.provider === provider } }
    }

    private static var live: [LazyImageClipboard] {
        registryLock.withLock { registry.compactMap(\.provider) }
    }

    /// The live image on `pasteboard`, which has not been replaced since it was published.
    static func current(on pasteboard: NSPasteboard) -> LazyImageClipboard? {
        live.first { $0.pasteboard === pasteboard && $0.changeCount == pasteboard.changeCount && !$0.isFinished }
    }

    /// The PNG already made, or being made, for exactly this image at this scale and density.
    static func sharedPNG(for image: CGImage, scale: ExportScale, backingScale: CGFloat) -> Data? {
        for provider in live where provider.matches(image, scale: scale, backingScale: backingScale) {
            if let png = provider.pngData() { return png }
        }
        return nil
    }

    /// Hands every representation that is still only promised to the pasteboard, so it stays pasteable after this
    /// process exits.
    static func flushPending() {
        for provider in live {
            guard let pasteboard = provider.pasteboard, pasteboard.changeCount == provider.changeCount,
                  !provider.isFinished else { continue }
            _ = pasteboard.data(forType: .png)
            _ = pasteboard.data(forType: .tiff)
        }
    }
}
