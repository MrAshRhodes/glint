import CoreGraphics
import GlintCore
import Testing
@testable import GlintEditor

@Suite("Editor geometry")
struct AnnotationGeometryTests {
    @Test func mapperRoundTripsCroppedAndExtendedImageRegions() {
        for region in [CGRect(x: 20, y: 30, width: 200, height: 100), CGRect(x: -20, y: -10, width: 200, height: 100)] {
            let mapper = CanvasMapper(region: region, contentRect: CGRect(x: 40, y: 50, width: 100, height: 75))
            #expect(mapper.toCanvas(region.origin) == mapper.contentRect.origin)
            let point = CGPoint(x: 80, y: 60)
            let result = mapper.toImage(mapper.toCanvas(point))
            #expect(abs(result.x - point.x) < 0.0001 && abs(result.y - point.y) < 0.0001)
        }
    }

    @Test func resizeAcrossOppositeCornerKeepsPositiveDimensionsAndIdentity() {
        let annotation = Annotation(kind: .redact(CGRect(x: 10, y: 20, width: 40, height: 30)))
        let result = AnnotationGeometry.resized(annotation, handle: .tl, to: CGPoint(x: 80, y: 70), constrain: false)
        #expect(result.id == annotation.id && result.style == annotation.style)
        #expect(result.kind == .redact(CGRect(x: 50, y: 50, width: 30, height: 20)))
        let square = AnnotationGeometry.resized(annotation, handle: .br, to: CGPoint(x: 70, y: 40), constrain: true)
        #expect(square.kind == .redact(CGRect(x: 10, y: 20, width: 60, height: 60)))
    }

    @Test func lineResizeSnapsTo45DegreesWithoutMovingOtherEndpoint() {
        let origin = CGPoint(x: 10, y: 10)
        let annotation = Annotation(kind: .line(from: origin, to: CGPoint(x: 30, y: 10)))
        let result = AnnotationGeometry.resized(annotation, handle: .p1, to: CGPoint(x: 30, y: 26), constrain: true)
        guard case .line(let start, let end) = result.kind else { Issue.record("Expected a line"); return }
        #expect(start == origin)
        #expect(abs((end.x - origin.x) - (end.y - origin.y)) < 0.0001)
        #expect(abs(hypot(end.x - origin.x, end.y - origin.y) - hypot(20, 16)) < 0.0001)
    }

    @Test func hitTestingDistinguishesOutlinesFromFilledShapes() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        var annotation = Annotation(kind: .rectangle(rect), style: AnnotationStyle(strokeWidth: 4))
        #expect(AnnotationGeometry.hit(annotation, at: CGPoint(x: 1, y: 50), tol: 1))
        #expect(!AnnotationGeometry.hit(annotation, at: CGPoint(x: 50, y: 50), tol: 1))
        annotation.style.fill = .red
        #expect(AnnotationGeometry.hit(annotation, at: CGPoint(x: 50, y: 50), tol: 1))
        #expect(!AnnotationGeometry.hit(annotation, at: CGPoint(x: 110, y: 50), tol: 1))
        #expect(!AnnotationGeometry.hit(Annotation(kind: .pen([])), at: .zero, tol: 1))
    }

    @Test func distanceUsesSegmentEndpointsAndHandlesZeroLength() {
        #expect(AnnotationGeometry.distance(CGPoint(x: 3, y: 4), toSegment: .zero, .zero) == 5)
        #expect(AnnotationGeometry.distance(CGPoint(x: 14, y: 3), toSegment: .zero, CGPoint(x: 10, y: 0)) == 5)
        #expect(AnnotationGeometry.distance(CGPoint(x: 5, y: 3), toSegment: .zero, CGPoint(x: 10, y: 0)) == 3)
    }
}
