import CoreGraphics
@testable import KontextVideoSDK
import Testing

/// The plane geometry under the viewability meter, on plain points.
@Suite
struct PolygonTests {
    private let square = Polygon.corners(of: CGRect(x: 0, y: 0, width: 10, height: 10))

    @Test func theAreaIgnoresTheWinding() {
        #expect(Polygon.area(square) == 100)
        #expect(Polygon.signedArea(square) == -Polygon.signedArea(square.reversed()))
        #expect(Polygon.area([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]) == 0, "fewer than three points have no area")
    }

    @Test func clippingKeepsTheOverlapWhateverTheClippersWinding() {
        let shifted = Polygon.corners(of: CGRect(x: 5, y: 5, width: 10, height: 10))
        #expect(Polygon.area(Polygon.clip(square, to: shifted)) == 25)
        #expect(Polygon.area(Polygon.clip(square, to: shifted.reversed())) == 25)
        let apart = Polygon.corners(of: CGRect(x: 20, y: 20, width: 5, height: 5))
        #expect(Polygon.clip(square, to: apart).isEmpty || Polygon.area(Polygon.clip(square, to: apart)) == 0)
        #expect(Polygon.clip(square, to: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]).isEmpty, "a degenerate clipper keeps nothing")
    }

    @Test func aRotatedSquareIsMeasuredByItsShapeNotItsBoundingBox() {
        // A diamond inside the square: half its area, though its bounding box is the whole square.
        let diamond = [CGPoint(x: 5, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 5, y: 10), CGPoint(x: 0, y: 5)]
        #expect(Polygon.area(Polygon.clip(square, to: diamond)) == 50)
    }

    @Test func segmentsCrossWhereTheLinesDo() {
        let point = Polygon.intersection(CGPoint(x: 0, y: 5), CGPoint(x: 10, y: 5), CGPoint(x: 3, y: 0), CGPoint(x: 3, y: 10))
        #expect(point == CGPoint(x: 3, y: 5))
        let parallel = Polygon.intersection(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 10, y: 1))
        #expect(parallel == CGPoint(x: 10, y: 0), "parallel lines: the segment's end")
    }
}
