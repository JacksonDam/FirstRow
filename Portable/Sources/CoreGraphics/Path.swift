import Foundation

public enum CGPathFillRule: Int, Sendable {
    case winding
    case evenOdd
}

public enum CGLineCap: Int32, Sendable {
    case butt
    case round
    case square
}

public enum CGLineJoin: Int32, Sendable {
    case miter
    case round
    case bevel
}

public enum CGPathElementType: Int32, Sendable {
    case moveToPoint
    case addLineToPoint
    case addQuadCurveToPoint
    case addCurveToPoint
    case closeSubpath
}

/// One path segment, with its points already in the path's own space.
public enum PathElement: Hashable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(CGPoint, CGPoint)
    case cubic(CGPoint, CGPoint, CGPoint)
    case close

    public func applying(_ t: CGAffineTransform) -> PathElement {
        switch self {
        case let .move(p): .move(p.applying(t))
        case let .line(p): .line(p.applying(t))
        case let .quad(c, p): .quad(c.applying(t), p.applying(t))
        case let .cubic(c1, c2, p): .cubic(c1.applying(t), c2.applying(t), p.applying(t))
        case .close: .close
        }
    }

    public func hash(into hasher: inout Hasher) {
        func add(_ p: CGPoint) {
            hasher.combine(Double(p.x))
            hasher.combine(Double(p.y))
        }
        switch self {
        case let .move(p): hasher.combine(0); add(p)
        case let .line(p): hasher.combine(1); add(p)
        case let .quad(c, p): hasher.combine(2); add(c); add(p)
        case let .cubic(c1, c2, p): hasher.combine(3); add(c1); add(c2); add(p)
        case .close: hasher.combine(4)
        }
    }
}

/// Circular arcs as cubic Béziers, the way Core Graphics approximates them.
enum ArcBuilder {
    /// Appends an arc from `start` to `end` radians; positive sweep turns from +x towards +y.
    static func arc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, clockwise: Bool, transform: CGAffineTransform, into elements: inout [PathElement], hasCurrentPoint: Bool) {
        var sweep = end - start
        // Core Graphics' "clockwise" is in a y-up space: clockwise means decreasing angles.
        if clockwise {
            if sweep > 0 { sweep -= 2 * .pi * ceil(sweep / (2 * .pi)) }
            if sweep == 0, start != end { sweep = -2 * .pi }
        } else {
            if sweep < 0 { sweep += 2 * .pi * ceil(-sweep / (2 * .pi)) }
            if sweep == 0, start != end { sweep = 2 * .pi }
        }
        sweep = max(-2 * .pi, min(2 * .pi, sweep))
        let first = CGPoint(x: center.x + radius * cos(start), y: center.y + radius * sin(start)).applying(transform)
        elements.append(hasCurrentPoint ? .line(first) : .move(first))
        let segments = max(1, Int(ceil(abs(sweep) / (.pi / 2) - 1e-9)))
        let step = sweep / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var angle = start
        for _ in 0 ..< segments {
            let next = angle + step
            let p0 = CGPoint(x: cos(angle), y: sin(angle))
            let p3 = CGPoint(x: cos(next), y: sin(next))
            let c1 = CGPoint(x: p0.x - k * p0.y, y: p0.y + k * p0.x)
            let c2 = CGPoint(x: p3.x + k * p3.y, y: p3.y - k * p3.x)
            func place(_ p: CGPoint) -> CGPoint {
                CGPoint(x: center.x + radius * p.x, y: center.y + radius * p.y).applying(transform)
            }
            elements.append(.cubic(place(c1), place(c2), place(p3)))
            angle = next
        }
    }

    static func ellipse(in rect: CGRect, transform: CGAffineTransform, into elements: inout [PathElement]) {
        let k: CGFloat = 0.5522847498
        let rx = rect.width / 2
        let ry = rect.height / 2
        let cx = rect.midX
        let cy = rect.midY
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(transform) }
        // Core Graphics starts ellipses at the right-hand point and runs counterclockwise.
        elements.append(.move(p(cx + rx, cy)))
        elements.append(.cubic(p(cx + rx, cy + ry * k), p(cx + rx * k, cy + ry), p(cx, cy + ry)))
        elements.append(.cubic(p(cx - rx * k, cy + ry), p(cx - rx, cy + ry * k), p(cx - rx, cy)))
        elements.append(.cubic(p(cx - rx, cy - ry * k), p(cx - rx * k, cy - ry), p(cx, cy - ry)))
        elements.append(.cubic(p(cx + rx * k, cy - ry), p(cx + rx, cy - ry * k), p(cx + rx, cy)))
        elements.append(.close)
    }

    static func roundedRect(_ rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat, transform: CGAffineTransform, into elements: inout [PathElement]) {
        let rx = min(max(0, cornerWidth), rect.width / 2)
        let ry = min(max(0, cornerHeight), rect.height / 2)
        if rx <= 0 || ry <= 0 {
            rectangle(rect, transform: transform, into: &elements)
            return
        }
        let k: CGFloat = 0.5522847498
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(transform) }
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        elements.append(.move(p(maxX, minY + ry)))
        elements.append(.line(p(maxX, maxY - ry)))
        elements.append(.cubic(p(maxX, maxY - ry + ry * k), p(maxX - rx + rx * k, maxY), p(maxX - rx, maxY)))
        elements.append(.line(p(minX + rx, maxY)))
        elements.append(.cubic(p(minX + rx - rx * k, maxY), p(minX, maxY - ry + ry * k), p(minX, maxY - ry)))
        elements.append(.line(p(minX, minY + ry)))
        elements.append(.cubic(p(minX, minY + ry - ry * k), p(minX + rx - rx * k, minY), p(minX + rx, minY)))
        elements.append(.line(p(maxX - rx, minY)))
        elements.append(.cubic(p(maxX - rx + rx * k, minY), p(maxX, minY + ry - ry * k), p(maxX, minY + ry)))
        elements.append(.close)
    }

    static func rectangle(_ rect: CGRect, transform: CGAffineTransform, into elements: inout [PathElement]) {
        let r = rect.standardized
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(transform) }
        elements.append(.move(p(r.minX, r.minY)))
        elements.append(.line(p(r.maxX, r.minY)))
        elements.append(.line(p(r.maxX, r.maxY)))
        elements.append(.line(p(r.minX, r.maxY)))
        elements.append(.close)
    }
}

public class CGPath: @unchecked Sendable, Equatable {
    public internal(set) var elements: [PathElement]

    public init(elements: [PathElement]) {
        self.elements = elements
    }

    public convenience init(rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        var elements: [PathElement] = []
        ArcBuilder.rectangle(rect, transform: transform?.pointee ?? .identity, into: &elements)
        self.init(elements: elements)
    }

    public convenience init(roundedRect rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat, transform: UnsafePointer<CGAffineTransform>?) {
        var elements: [PathElement] = []
        ArcBuilder.roundedRect(rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight, transform: transform?.pointee ?? .identity, into: &elements)
        self.init(elements: elements)
    }

    public convenience init(ellipseIn rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        var elements: [PathElement] = []
        ArcBuilder.ellipse(in: rect, transform: transform?.pointee ?? .identity, into: &elements)
        self.init(elements: elements)
    }

    public var isEmpty: Bool { elements.isEmpty }

    public var currentPoint: CGPoint {
        var start = CGPoint.zero
        var current = CGPoint.zero
        for element in elements {
            switch element {
            case let .move(p): start = p; current = p
            case let .line(p): current = p
            case let .quad(_, p): current = p
            case let .cubic(_, _, p): current = p
            case .close: current = start
            }
        }
        return current
    }

    /// Bounds of every point, control points included.
    public var boundingBox: CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        func add(_ p: CGPoint) {
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        for element in elements {
            switch element {
            case let .move(p), let .line(p): add(p)
            case let .quad(c, p): add(c); add(p)
            case let .cubic(c1, c2, p): add(c1); add(c2); add(p)
            case .close: break
            }
        }
        guard minX.isFinite else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public var boundingBoxOfPath: CGRect { boundingBox }

    public func copy() -> CGPath? { CGPath(elements: elements) }

    public func copy(using transform: UnsafePointer<CGAffineTransform>?) -> CGPath? {
        guard let t = transform?.pointee else { return copy() }
        return CGPath(elements: elements.map { $0.applying(t) })
    }

    public func mutableCopy() -> CGMutablePath? {
        let path = CGMutablePath()
        path.elements = elements
        return path
    }

    public func contains(_ point: CGPoint, using rule: CGPathFillRule = .winding, transform: CGAffineTransform = .identity) -> Bool {
        let polygon = PathFlattener.polygons(elements.map { $0.applying(transform) })
        var winding = 0
        var crossings = 0
        for ring in polygon where ring.count > 2 {
            for i in 0 ..< ring.count {
                let a = ring[i]
                let b = ring[(i + 1) % ring.count]
                if (a.y <= point.y) != (b.y <= point.y) {
                    let x = a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x)
                    if x > point.x {
                        crossings += 1
                        winding += b.y > a.y ? 1 : -1
                    }
                }
            }
        }
        return rule == .winding ? winding != 0 : crossings % 2 == 1
    }

    public static func == (lhs: CGPath, rhs: CGPath) -> Bool { lhs.elements == rhs.elements }
}

public final class CGMutablePath: CGPath, @unchecked Sendable {
    public init() {
        super.init(elements: [])
    }

    private var hasCurrentPoint: Bool {
        guard let last = elements.last else { return false }
        if case .close = last { return false }
        return true
    }

    public func move(to point: CGPoint, transform: CGAffineTransform = .identity) {
        elements.append(.move(point.applying(transform)))
    }

    public func addLine(to point: CGPoint, transform: CGAffineTransform = .identity) {
        elements.append(hasCurrentPoint ? .line(point.applying(transform)) : .move(point.applying(transform)))
    }

    public func addLines(between points: [CGPoint], transform: CGAffineTransform = .identity) {
        for (index, point) in points.enumerated() {
            if index == 0 { move(to: point, transform: transform) } else { addLine(to: point, transform: transform) }
        }
    }

    public func addQuadCurve(to end: CGPoint, control: CGPoint, transform: CGAffineTransform = .identity) {
        elements.append(.quad(control.applying(transform), end.applying(transform)))
    }

    public func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint, transform: CGAffineTransform = .identity) {
        elements.append(.cubic(control1.applying(transform), control2.applying(transform), end.applying(transform)))
    }

    public func addRect(_ rect: CGRect, transform: CGAffineTransform = .identity) {
        ArcBuilder.rectangle(rect, transform: transform, into: &elements)
    }

    public func addRects(_ rects: [CGRect], transform: CGAffineTransform = .identity) {
        for rect in rects { addRect(rect, transform: transform) }
    }

    public func addRoundedRect(in rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat, transform: CGAffineTransform = .identity) {
        ArcBuilder.roundedRect(rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight, transform: transform, into: &elements)
    }

    public func addEllipse(in rect: CGRect, transform: CGAffineTransform = .identity) {
        ArcBuilder.ellipse(in: rect, transform: transform, into: &elements)
    }

    public func addArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool, transform: CGAffineTransform = .identity) {
        ArcBuilder.arc(center: center, radius: radius, start: startAngle, end: endAngle, clockwise: clockwise, transform: transform, into: &elements, hasCurrentPoint: hasCurrentPoint)
    }

    public func addRelativeArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, delta: CGFloat, transform: CGAffineTransform = .identity) {
        addArc(center: center, radius: radius, startAngle: startAngle, endAngle: startAngle + delta, clockwise: delta < 0, transform: transform)
    }

    public func addArc(tangent1End p1: CGPoint, tangent2End p2: CGPoint, radius: CGFloat, transform: CGAffineTransform = .identity) {
        let p0 = currentPoint
        let v1 = CGPoint(x: p0.x - p1.x, y: p0.y - p1.y)
        let v2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
        let l1 = hypot(v1.x, v1.y)
        let l2 = hypot(v2.x, v2.y)
        guard l1 > 0, l2 > 0, radius > 0 else {
            addLine(to: p1, transform: transform)
            return
        }
        let cosine = (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)
        let angle = acos(max(-1, min(1, cosine)))
        guard angle > 1e-6, abs(angle - .pi) > 1e-6 else {
            addLine(to: p1, transform: transform)
            return
        }
        let distance = radius / tan(angle / 2)
        let start = CGPoint(x: p1.x + v1.x / l1 * distance, y: p1.y + v1.y / l1 * distance)
        let end = CGPoint(x: p1.x + v2.x / l2 * distance, y: p1.y + v2.y / l2 * distance)
        let bisector = CGPoint(x: v1.x / l1 + v2.x / l2, y: v1.y / l1 + v2.y / l2)
        let bisectorLength = hypot(bisector.x, bisector.y)
        let centerDistance = radius / sin(angle / 2)
        let center = CGPoint(x: p1.x + bisector.x / bisectorLength * centerDistance, y: p1.y + bisector.y / bisectorLength * centerDistance)
        let a0 = atan2(start.y - center.y, start.x - center.x)
        let a1 = atan2(end.y - center.y, end.x - center.x)
        let cross = v1.x * v2.y - v1.y * v2.x
        addLine(to: start, transform: transform)
        addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: cross < 0 ? false : true, transform: transform)
    }

    public func addPath(_ path: CGPath, transform: CGAffineTransform = .identity) {
        elements.append(contentsOf: path.elements.map { $0.applying(transform) })
    }

    public func closeSubpath() {
        elements.append(.close)
    }
}

/// Turns curves into polylines, for hit testing.
enum PathFlattener {
    static func polygons(_ elements: [PathElement]) -> [[CGPoint]] {
        var rings: [[CGPoint]] = []
        var ring: [CGPoint] = []
        var current = CGPoint.zero
        for element in elements {
            switch element {
            case let .move(p):
                if ring.count > 1 { rings.append(ring) }
                ring = [p]
                current = p
            case let .line(p):
                ring.append(p)
                current = p
            case let .quad(c, p):
                for i in 1 ... 8 {
                    let t = CGFloat(i) / 8
                    let u = 1 - t
                    ring.append(CGPoint(x: u * u * current.x + 2 * u * t * c.x + t * t * p.x, y: u * u * current.y + 2 * u * t * c.y + t * t * p.y))
                }
                current = p
            case let .cubic(c1, c2, p):
                for i in 1 ... 12 {
                    let t = CGFloat(i) / 12
                    let u = 1 - t
                    let x = u * u * u * current.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p.x
                    let y = u * u * u * current.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p.y
                    ring.append(CGPoint(x: x, y: y))
                }
                current = p
            case .close:
                if ring.count > 1 { rings.append(ring) }
                if let first = ring.first { current = first }
                ring = []
            }
        }
        if ring.count > 1 { rings.append(ring) }
        return rings
    }
}
