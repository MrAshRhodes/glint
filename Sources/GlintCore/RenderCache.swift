import CoreGraphics
import Foundation

/// What rendering one capture repeats on every settings change: the sRGB copy of the source and the source with its
/// annotations burned in. A change to only the background, shadow, padding, frame or output scale reuses both, so the
/// preview just composes. An entry is replaced when the image, annotations, crop or fill change, the pixels held never
/// exceed `maxBytes`, and a render that fails stores nothing, so a failed bake still fails closed.
///
/// One cache serves one editor. Previews, copies and exports run on different threads, so it can be used from all of
/// them at once; results are computed outside the lock and two racing misses just both compute.
public final class RenderCache: @unchecked Sendable {
    public static let defaultMaxBytes = 256 << 20

    /// Budget for the two images this cache holds, in bytes of pixels.
    public let maxBytes: Int
    /// Background and watermark images read from disk, reused until their files change.
    public let images: ImageFileCache

    private struct Converted {
        var input: CGImage
        var output: CGImage
    }

    private struct Burned {
        var input: CGImage
        var annotations: [Annotation]
        var region: CGRect?
        var fill: RGBAColor
        var layers: AnnotationRenderer.BakedLayers
    }

    private let lock = NSLock()
    private var converted: Converted?
    private var burned: Burned?

    public init(maxBytes: Int = RenderCache.defaultMaxBytes, imageCapacity: Int = 3) {
        self.maxBytes = max(maxBytes, 0)
        images = ImageFileCache(capacity: imageCapacity, maxBytes: self.maxBytes)
    }

    /// Pixels held by the sRGB copy and the burned-in image.
    public var retainedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return heldBytes
    }

    private var heldBytes: Int { Self.bytes(converted?.output) + Self.bytes(burned?.layers.base) }

    public func removeAll() {
        lock.lock()
        converted = nil
        burned = nil
        lock.unlock()
        images.removeAll()
    }

    /// `image.glintSRGB()`, kept for the next call with the same image.
    func normalised(_ image: CGImage) -> CGImage {
        if image.isGlintSRGB { return image }
        lock.lock()
        if let held = converted, held.input === image {
            lock.unlock()
            return held.output
        }
        // Drop the old copy first so replacing a large capture never holds two.
        converted = nil
        lock.unlock()
        let output = image.glintSRGB()
        guard Self.bytes(output) <= maxBytes else { return output }
        lock.lock()
        converted = Converted(input: image, output: output)
        // Over budget together: the new copy stays and the burned-in image is made again when needed.
        if heldBytes > maxBytes { burned = nil }
        lock.unlock()
        return output
    }

    /// What `compute` returns for these inputs, kept for the next identical request. `image` is the capture as the
    /// caller received it, not its sRGB copy, so the entry outlives that copy being dropped and recreated. Only a
    /// bake without a foreground is kept: a magnifier's lens holds further source images.
    func baked(of image: CGImage, annotations: [Annotation], region: CGRect?, fill: RGBAColor,
               compute: () -> AnnotationRenderer.BakedLayers?) -> AnnotationRenderer.BakedLayers? {
        lock.lock()
        let held = burned
        lock.unlock()
        // Comparing annotations can take a while for large drawings, so it happens outside the lock.
        if let held, held.input === image, held.region == region, held.fill == fill, held.annotations == annotations {
            return held.layers
        }
        // Drop the old layers first so replacing them never holds both at once.
        if held != nil {
            lock.lock()
            burned = nil
            lock.unlock()
        }
        guard let layers = compute() else { return nil }
        guard layers.foreground == nil, Self.bytes(layers.base) <= maxBytes else { return layers }
        lock.lock()
        burned = Burned(input: image, annotations: annotations, region: region, fill: fill, layers: layers)
        if heldBytes > maxBytes { converted = nil }
        lock.unlock()
        return layers
    }

    private static func bytes(_ image: CGImage?) -> Int {
        image.map { $0.bytesPerRow * $0.height } ?? 0
    }
}
