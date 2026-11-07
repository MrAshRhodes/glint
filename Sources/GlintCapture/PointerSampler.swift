import AppKit
import GlintCore

/// Where the pointer is and which buttons are down, in global CG coordinates (top-left origin).
struct PointerReading: Equatable, Sendable {
    var location: CGPoint
    var left: Bool
    var right: Bool
}

/// Reads the pointer; tests substitute a scripted one.
@MainActor
protocol PointerSource: AnyObject {
    func read() -> PointerReading
}

/// The real pointer. Polling needs no Accessibility or Input Monitoring permission, unlike an event tap.
@MainActor
final class LivePointerSource: PointerSource {
    func read() -> PointerReading {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let buttons = NSEvent.pressedMouseButtons
        return PointerReading(location: CaptureGeometry.appKitToCG(NSEvent.mouseLocation, primaryHeight: primaryHeight),
                              left: buttons & 1 != 0, right: buttons & 2 != 0)
    }
}

/// Samples the pointer while a recording runs, for click highlights, cursor emphasis and an editable pointer.
/// Positions are video pixels; times are host seconds until `capture(firstFrameTime:pointerIsBaked:)` makes
/// them relative to the first frame.
@MainActor
final class PointerSampler {
    static let interval: TimeInterval = 1.0 / 60

    private let geometry: RecordingGeometry
    private let source: any PointerSource
    private let now: @MainActor () -> TimeInterval
    private var timer: Timer?
    private var track = PointerTrack()
    private var clicks: [ClickEvent] = []
    private var wasDown = (left: false, right: false)
    private var lastTick = -TimeInterval.infinity
    private(set) var startedAt: TimeInterval?

    init(geometry: RecordingGeometry, source: any PointerSource, now: @escaping @MainActor () -> TimeInterval) {
        self.geometry = geometry
        self.source = source
        self.now = now
    }

    func start() {
        guard timer == nil else { return }
        let time = now()
        startedAt = startedAt ?? time
        let reading = source.read()
        // A button already held when recording starts is not a click.
        wasDown = (reading.left, reading.right)
        tick(at: time, reading: reading)
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() { tick(at: now(), reading: source.read()) }

    func tick(at time: TimeInterval, reading: PointerReading) {
        guard time > lastTick else { return }
        lastTick = time
        let position = geometry.videoPoint(forGlobal: reading.location)
        track.append(PointerSample(time: time, position: position))
        let bounds = CGRect(origin: .zero, size: geometry.outputSize)
        if reading.left, !wasDown.left, bounds.contains(position) {
            clicks.append(ClickEvent(time: time, position: position, button: .left))
        }
        if reading.right, !wasDown.right, bounds.contains(position) {
            clicks.append(ClickEvent(time: time, position: position, button: .right))
        }
        wasDown = (reading.left, reading.right)
    }

    /// Everything recorded so far, with times relative to `firstFrameTime` (host seconds), or to `start()`
    /// when the engine cannot tell.
    func capture(firstFrameTime: TimeInterval?, pointerIsBaked: Bool) -> PresentationCapture {
        let origin = firstFrameTime ?? startedAt ?? 0
        var shifted = PointerTrack()
        for sample in track.samples {
            shifted.append(PointerSample(time: sample.time - origin, position: sample.position))
        }
        return PresentationCapture(
            pointer: shifted,
            clicks: clicks.map { ClickEvent(id: $0.id, time: $0.time - origin, position: $0.position, button: $0.button) },
            pointerIsBaked: pointerIsBaked,
            pointerScale: Double(geometry.videoPixelsPerPoint))
    }
}
