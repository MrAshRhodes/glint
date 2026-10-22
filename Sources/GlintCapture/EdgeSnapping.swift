import CoreGraphics

/// All values are global, top-left-origin display points, never backing pixels.
struct SnapEdge: Equatable {
    enum Axis { case x, y }
    let axis: Axis
    let coordinate: CGFloat
    let lower: CGFloat
    let upper: CGFloat
    /// Nil denotes a display boundary; otherwise the front-to-back window index.
    let windowIndex: Int?
}

struct SnapWindow {
    let frame: CGRect
    var isTarget = true
}

enum SnapTargets {
    static func visibleEdges(in display: CGRect, windows: [SnapWindow]) -> [SnapEdge] {
        guard valid(display) else { return [] }
        var edges = segments(of: display, clippedTo: display, windowIndex: nil)
        var occluders: [CGRect] = []
        for (index, window) in windows.enumerated() where valid(window.frame) {
            if window.isTarget {
                for edge in segments(of: window.frame, clippedTo: display, windowIndex: index) {
                    var pieces = [edge]
                    for cover in occluders {
                        pieces = pieces.flatMap { subtract(cover, from: $0) }
                        if pieces.isEmpty { break }
                    }
                    edges.append(contentsOf: pieces)
                }
            }
            let clipped = window.frame.intersection(display)
            if !clipped.isNull && !clipped.isEmpty { occluders.append(clipped) }
        }
        return edges
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }

    private static func segments(of rect: CGRect, clippedTo display: CGRect, windowIndex: Int?) -> [SnapEdge] {
        var edges: [SnapEdge] = []
        // Clip the original segments, not the rectangle: clipping must never invent window edges.
        for x in [rect.minX, rect.maxX] where x >= display.minX && x <= display.maxX {
            let lower = max(rect.minY, display.minY), upper = min(rect.maxY, display.maxY)
            if lower < upper {
                edges.append(SnapEdge(axis: .x, coordinate: x, lower: lower, upper: upper, windowIndex: windowIndex))
            }
        }
        for y in [rect.minY, rect.maxY] where y >= display.minY && y <= display.maxY {
            let lower = max(rect.minX, display.minX), upper = min(rect.maxX, display.maxX)
            if lower < upper {
                edges.append(SnapEdge(axis: .y, coordinate: y, lower: lower, upper: upper, windowIndex: windowIndex))
            }
        }
        return edges
    }

    private static func subtract(_ cover: CGRect, from edge: SnapEdge) -> [SnapEdge] {
        let across = edge.axis == .x ? cover.minX...cover.maxX : cover.minY...cover.maxY
        guard across.contains(edge.coordinate) else { return [edge] }
        let lower = max(edge.lower, edge.axis == .x ? cover.minY : cover.minX)
        let upper = min(edge.upper, edge.axis == .x ? cover.maxY : cover.maxX)
        guard lower < upper else { return [edge] }
        var pieces: [SnapEdge] = []
        if edge.lower < lower {
            pieces.append(SnapEdge(axis: edge.axis, coordinate: edge.coordinate, lower: edge.lower,
                                   upper: lower, windowIndex: edge.windowIndex))
        }
        if upper < edge.upper {
            pieces.append(SnapEdge(axis: edge.axis, coordinate: edge.coordinate, lower: upper,
                                   upper: edge.upper, windowIndex: edge.windowIndex))
        }
        return pieces
    }
}

/// A drag keeps its original geometry independent of the magnetic preview.
/// Mouse/modifier changes share a solver; explicit keyboard translation bypasses magnets.
struct SnappingSelection {
    static let acquireDistance: CGFloat = 6
    static let releaseDistance: CGFloat = 10
    static let minimumSize: CGFloat = 3

    let bounds: CGRect
    let snapToEdges: Bool
    private(set) var rawAnchor: CGPoint
    private(set) var rawCursor: CGPoint
    private(set) var shift = false
    private(set) var command = false
    private(set) var rectangle: CGRect
    private(set) var guides: [SnapEdge] = []

    var snappingEnabled: Bool { snapToEdges != command }
    var isValid: Bool { rectangle.width >= Self.minimumSize && rectangle.height >= Self.minimumSize }

    private enum Handle: CaseIterable {
        case anchorX, anchorY, cursorX, cursorY
        var axis: SnapEdge.Axis { self == .anchorX || self == .cursorX ? .x : .y }
        var isAnchor: Bool { self == .anchorX || self == .anchorY }
    }

    private struct Geometry {
        var anchor: CGPoint
        var cursor: CGPoint
        var rect: CGRect { CaptureGeometry.rect(from: anchor, to: cursor, square: false) }
        func coordinate(for handle: Handle) -> CGFloat {
            let point = handle.isAnchor ? anchor : cursor
            return handle.axis == .x ? point.x : point.y
        }
    }

    private let xTargets: [SnapEdge]
    private let yTargets: [SnapEdge]
    private var held: [Handle: SnapEdge] = [:]

    init(anchor: CGPoint, bounds: CGRect, targets: [SnapEdge], snapToEdges: Bool) {
        self.bounds = bounds
        self.snapToEdges = snapToEdges
        rawAnchor = CaptureGeometry.clamp(anchor, to: bounds)
        rawCursor = rawAnchor
        rectangle = CGRect(origin: rawAnchor, size: .zero)
        xTargets = targets.filter { $0.axis == .x }
        yTargets = targets.filter { $0.axis == .y }
    }

    mutating func move(to cursor: CGPoint) {
        rawCursor = CaptureGeometry.clamp(cursor, to: bounds)
        recompute()
    }

    mutating func setModifiers(shift: Bool, command: Bool) {
        guard self.shift != shift || self.command != command else { return }
        self.shift = shift
        self.command = command
        recompute()
    }

    mutating func nudge(dx: CGFloat, dy: CGFloat) {
        let x = min(max(dx, bounds.minX - rectangle.minX), bounds.maxX - rectangle.maxX)
        let y = min(max(dy, bounds.minY - rectangle.minY), bounds.maxY - rectangle.maxY)
        rawAnchor = CaptureGeometry.clamp(CGPoint(x: rawAnchor.x + x, y: rawAnchor.y + y), to: bounds)
        rawCursor = CaptureGeometry.clamp(CGPoint(x: rawCursor.x + x, y: rawCursor.y + y), to: bounds)
        // Keys deliberately translate the visible rectangle. Do not let magnets consume the step;
        // mouse movement or an actual modifier transition resumes solving from the independent raw points.
        rectangle = rectangle.offsetBy(dx: x, dy: y)
        held.removeAll()
        guides.removeAll()
    }

    private var xDirection: CGFloat { rawCursor.x < rawAnchor.x ? -1 : 1 }
    private var yDirection: CGFloat { rawCursor.y < rawAnchor.y ? -1 : 1 }
    private var dominantAxis: SnapEdge.Axis {
        abs(rawCursor.x - rawAnchor.x) >= abs(rawCursor.y - rawAnchor.y) ? .x : .y
    }

    private func square(anchor: CGPoint, side: CGFloat? = nil) -> Geometry {
        let availableX = xDirection > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let availableY = yDirection > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        let desired = side ?? max(abs(rawCursor.x - anchor.x), abs(rawCursor.y - anchor.y))
        let length = max(0, min(desired, availableX, availableY))
        return Geometry(anchor: anchor, cursor: CGPoint(x: anchor.x + length * xDirection,
                                                       y: anchor.y + length * yDirection))
    }

    private mutating func recompute() {
        var geometry = shift ? square(anchor: rawAnchor) : Geometry(anchor: rawAnchor, cursor: rawCursor)
        guard snappingEnabled else {
            held.removeAll()
            guides.removeAll()
            rectangle = geometry.rect
            return
        }
        let previous = held
        held.removeAll(keepingCapacity: true)
        for handle in Handle.allCases {
            if shift && !handle.isAnchor && handle.axis != dominantAxis { continue }
            let rawCoordinate = geometry.coordinate(for: handle)
            func proposal(_ edge: SnapEdge) -> Geometry? {
                var next = geometry
                if handle.isAnchor {
                    if handle.axis == .x { next.anchor.x = edge.coordinate } else { next.anchor.y = edge.coordinate }
                    if shift { next = square(anchor: next.anchor) }
                } else if shift {
                    let origin = handle.axis == .x ? next.anchor.x : next.anchor.y
                    let direction = handle.axis == .x ? xDirection : yDirection
                    next = square(anchor: next.anchor, side: (edge.coordinate - origin) * direction)
                } else {
                    if handle.axis == .x { next.cursor.x = edge.coordinate } else { next.cursor.y = edge.coordinate }
                }
                guard next.rect.width >= Self.minimumSize, next.rect.height >= Self.minimumSize,
                      (next.cursor.x - next.anchor.x) * xDirection > 0,
                      (next.cursor.y - next.anchor.y) * yDirection > 0,
                      next.rect.minX >= bounds.minX, next.rect.maxX <= bounds.maxX,
                      next.rect.minY >= bounds.minY, next.rect.maxY <= bounds.maxY,
                      matches(edge, handle: handle, geometry: next),
                      held.allSatisfy({ matches($0.value, handle: $0.key, geometry: next) }) else { return nil }
                return next
            }
            if let edge = previous[handle], abs(edge.coordinate - rawCoordinate) <= Self.releaseDistance,
               let next = proposal(edge) {
                held[handle] = edge
                geometry = next
                continue
            }
            var best: (edge: SnapEdge, geometry: Geometry, distance: CGFloat)?
            for edge in handle.axis == .x ? xTargets : yTargets {
                let distance = abs(edge.coordinate - rawCoordinate)
                guard distance <= Self.acquireDistance,
                      best == nil || distance < best!.distance,
                      let next = proposal(edge) else { continue }
                best = (edge, next, distance)
            }
            // Stable target order breaks ties: display boundaries, then front-to-back window segments.
            if let best {
                held[handle] = best.edge
                geometry = best.geometry
            }
        }
        rectangle = geometry.rect
        guides = Handle.allCases.compactMap { held[$0] }
    }

    private func matches(_ edge: SnapEdge, handle: Handle, geometry: Geometry) -> Bool {
        guard geometry.coordinate(for: handle) == edge.coordinate else { return false }
        let rect = geometry.rect
        let lower = edge.axis == .x ? rect.minY : rect.minX
        let upper = edge.axis == .x ? rect.maxY : rect.maxX
        return max(lower, edge.lower) < min(upper, edge.upper)
    }
}
