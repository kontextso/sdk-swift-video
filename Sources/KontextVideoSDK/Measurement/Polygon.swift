import CoreGraphics

/// Plane geometry over points, for what the viewability meter measures: a view's outline is the image of its
/// rectangle under its ancestors' transforms (a rotation, a scale), so the meter works on polygons, not
/// rectangles. No views here; `ViewExposure` turns views into these points.
enum Polygon {
    /// A rectangle's four corners, in order around it.
    static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    /// `subject` cut by the convex polygon `clipper` (Sutherland–Hodgman). Every outline here is the image
    /// of a rectangle under an affine transform, so the clipper is always convex.
    static func clip(_ subject: [CGPoint], to clipper: [CGPoint]) -> [CGPoint] {
        guard clipper.count >= 3 else { return [] }
        // The clipper's winding decides which side of each edge is inside.
        let sign: CGFloat = signedArea(clipper) >= 0 ? 1 : -1
        var output = subject
        for index in clipper.indices {
            guard !output.isEmpty else { break }
            let edgeStart = clipper[index], edgeEnd = clipper[(index + 1) % clipper.count]
            // Split into typed steps: one expression was too much for the Swift 6.1 type checker (Xcode 16.4).
            let edge = CGVector(dx: edgeEnd.x - edgeStart.x, dy: edgeEnd.y - edgeStart.y)
            let inside = { (point: CGPoint) -> Bool in
                let along: CGFloat = edge.dx * (point.y - edgeStart.y)
                let across: CGFloat = edge.dy * (point.x - edgeStart.x)
                return sign * (along - across) >= 0
            }
            let input = output
            output = []
            for pointIndex in input.indices {
                let current = input[pointIndex], previous = input[(pointIndex + input.count - 1) % input.count]
                if inside(current) {
                    if !inside(previous) { output.append(intersection(previous, current, edgeStart, edgeEnd)) }
                    output.append(current)
                } else if inside(previous) {
                    output.append(intersection(previous, current, edgeStart, edgeEnd))
                }
            }
        }
        return output
    }

    /// The area of a polygon (shoelace formula), its sign the winding: `abs` of it is the area, whatever the
    /// winding. 0 for fewer than three points.
    static func signedArea(_ polygon: [CGPoint]) -> CGFloat {
        var twice: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            twice += a.x * b.y - b.x * a.y
        }
        return twice / 2
    }

    /// The area of a polygon, whatever its winding.
    static func area(_ polygon: [CGPoint]) -> CGFloat {
        abs(signedArea(polygon))
    }

    /// Where segment `p1`–`p2` crosses the line through `q1`–`q2`.
    static func intersection(_ p1: CGPoint, _ p2: CGPoint, _ q1: CGPoint, _ q2: CGPoint) -> CGPoint {
        let d1 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y), d2 = CGPoint(x: q2.x - q1.x, y: q2.y - q1.y)
        let denominator = d1.x * d2.y - d1.y * d2.x
        guard abs(denominator) > .ulpOfOne else { return p2 }
        let t = ((q1.x - p1.x) * d2.y - (q1.y - p1.y) * d2.x) / denominator
        return CGPoint(x: p1.x + t * d1.x, y: p1.y + t * d1.y)
    }
}
