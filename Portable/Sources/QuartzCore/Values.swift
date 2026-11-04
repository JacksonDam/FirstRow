import CoreGraphics
import CoreImage
import Foundation

/// An animatable property value in a form that can be interpolated.
enum AnimValue {
    case scalar(Double)
    case point(CGPoint)
    case size(CGSize)
    case rect(CGRect)
    case transform(CATransform3D)
    case color(CGColor?)
    case colors([CGColor])
    case numbers([Double])
    case object(Any?)

    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    static func interpolate(_ a: AnimValue, _ b: AnimValue, _ t: Double) -> AnimValue {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)): return .scalar(mix(x, y, t))
        case let (.point(p), .point(q)):
            return .point(CGPoint(x: mix(Double(p.x), Double(q.x), t), y: mix(Double(p.y), Double(q.y), t)))
        case let (.size(p), .size(q)):
            return .size(CGSize(width: mix(Double(p.width), Double(q.width), t), height: mix(Double(p.height), Double(q.height), t)))
        case let (.rect(p), .rect(q)):
            return .rect(CGRect(x: mix(Double(p.minX), Double(q.minX), t), y: mix(Double(p.minY), Double(q.minY), t),
                                width: mix(Double(p.width), Double(q.width), t), height: mix(Double(p.height), Double(q.height), t)))
        case let (.transform(p), .transform(q)): return .transform(interpolateTransform(p, q, t))
        case let (.color(p), .color(q)): return .color(mixColor(p, q, t))
        case let (.colors(p), .colors(q)) where p.count == q.count:
            return .colors(zip(p, q).map { mixColor($0, $1, t) ?? $0 })
        case let (.numbers(p), .numbers(q)) where p.count == q.count:
            return .numbers(zip(p, q).map { mix($0, $1, t) })
        default:
            return t < 0.5 ? a : b
        }
    }

    static func mixColor(_ a: CGColor?, _ b: CGColor?, _ t: Double) -> CGColor? {
        let p = a?.rgba ?? (b?.rgba.0 ?? 0, b?.rgba.1 ?? 0, b?.rgba.2 ?? 0, 0)
        let q = b?.rgba ?? (p.0, p.1, p.2, 0)
        let tt = CGFloat(t)
        return CGColor(red: p.0 + (q.0 - p.0) * tt, green: p.1 + (q.1 - p.1) * tt, blue: p.2 + (q.2 - p.2) * tt, alpha: p.3 + (q.3 - p.3) * tt)
    }

    static func add(_ a: AnimValue, _ b: AnimValue) -> AnimValue {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)): .scalar(x + y)
        case let (.point(p), .point(q)): .point(CGPoint(x: p.x + q.x, y: p.y + q.y))
        case let (.size(p), .size(q)): .size(CGSize(width: p.width + q.width, height: p.height + q.height))
        case let (.rect(p), .rect(q)): .rect(CGRect(x: p.minX + q.minX, y: p.minY + q.minY, width: p.width + q.width, height: p.height + q.height))
        case let (.transform(p), .transform(q)): .transform(q.then(p))
        default: b
        }
    }

    static func subtract(_ a: AnimValue, _ b: AnimValue) -> AnimValue {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)): .scalar(x - y)
        case let (.point(p), .point(q)): .point(CGPoint(x: p.x - q.x, y: p.y - q.y))
        case let (.size(p), .size(q)): .size(CGSize(width: p.width - q.width, height: p.height - q.height))
        case let (.rect(p), .rect(q)): .rect(CGRect(x: p.minX - q.minX, y: p.minY - q.minY, width: p.width - q.width, height: p.height - q.height))
        case let (.transform(p), .transform(q)): .transform(CATransform3DInvert(q).then(p))
        default: a
        }
    }

    /// The value boxed as Core Animation hands it back from `value(forKeyPath:)`.
    var boxed: Any? {
        switch self {
        case let .scalar(v): NSNumber(value: v)
        case let .point(p): NSValue(point: p)
        case let .size(s): NSValue(size: s)
        case let .rect(r): NSValue(rect: r)
        case let .transform(t): CATransform3DValue(t)
        case let .color(c): c
        case let .colors(c): c
        case let .numbers(n): n.map { NSNumber(value: $0) }
        case let .object(o): o
        }
    }
}

enum ValueKind {
    case scalar, point, size, rect, transform, color, colors, numbers, object

    func convert(_ value: Any) -> AnimValue? {
        switch self {
        case .scalar:
            if let n = value as? NSNumber { return .scalar(n.doubleValue) }
            if let d = value as? Double { return .scalar(d) }
            if let f = value as? Float { return .scalar(Double(f)) }
            if let c = value as? CGFloat { return .scalar(Double(c)) }
            if let i = value as? Int { return .scalar(Double(i)) }
            if let b = value as? Bool { return .scalar(b ? 1 : 0) }
            return nil
        case .point:
            if let p = value as? CGPoint { return .point(p) }
            if let v = value as? NSValue, !(v is NSNumber) { return .point(v.pointValue) }
            return nil
        case .size:
            if let s = value as? CGSize { return .size(s) }
            if let v = value as? NSValue, !(v is NSNumber) { return .size(v.sizeValue) }
            return nil
        case .rect:
            if let r = value as? CGRect { return .rect(r) }
            if let v = value as? NSValue, !(v is NSNumber) { return .rect(v.rectValue) }
            return nil
        case .transform:
            if let t = value as? CATransform3D { return .transform(t) }
            if let v = value as? CATransform3DValue { return .transform(v.transform) }
            if let n = value as? NSNumber { return .transform(CATransform3DMakeScale(CGFloat(n.doubleValue), CGFloat(n.doubleValue), 1)) }
            return nil
        case .color:
            if value is NSNull { return .color(nil) }
            return .color(value as? CGColor)
        case .colors:
            if let list = value as? [Any] { return .colors(list.compactMap { $0 as? CGColor }) }
            return nil
        case .numbers:
            if let list = value as? [NSNumber] { return .numbers(list.map(\.doubleValue)) }
            if let list = value as? [Double] { return .numbers(list) }
            if let list = value as? [CGFloat] { return .numbers(list.map { Double($0) }) }
            return nil
        case .object:
            return .object(value)
        }
    }
}

/// Every property Core Animation can animate that First Row uses, with how to read and write it.
struct AnimatableKey {
    let kind: ValueKind
    let get: (LayerState) -> AnimValue
    let set: (inout LayerState, AnimValue) -> Void

    private static var cache: [String: AnimatableKey] = [:]
    private static let lock = NSLock()

    init(kind: ValueKind, get: @escaping (LayerState) -> AnimValue, set: @escaping (inout LayerState, AnimValue) -> Void) {
        self.kind = kind
        self.get = get
        self.set = set
    }

    init?(_ keyPath: String) {
        Self.lock.lock()
        if let cached = Self.cache[keyPath] {
            Self.lock.unlock()
            self = cached
            return
        }
        Self.lock.unlock()
        guard let made = Self.make(keyPath) else { return nil }
        Self.lock.lock()
        Self.cache[keyPath] = made
        Self.lock.unlock()
        self = made
    }

    private static func scalar(_ get: @escaping (LayerState) -> Double, _ set: @escaping (inout LayerState, Double) -> Void) -> AnimatableKey {
        AnimatableKey(kind: .scalar, get: { .scalar(get($0)) }, set: { state, value in
            if case let .scalar(v) = value { set(&state, v) }
        })
    }

    private static func point(_ get: @escaping (LayerState) -> CGPoint, _ set: @escaping (inout LayerState, CGPoint) -> Void) -> AnimatableKey {
        AnimatableKey(kind: .point, get: { .point(get($0)) }, set: { state, value in
            if case let .point(v) = value { set(&state, v) }
        })
    }

    private static func color(_ get: @escaping (LayerState) -> CGColor?, _ set: @escaping (inout LayerState, CGColor?) -> Void) -> AnimatableKey {
        AnimatableKey(kind: .color, get: { .color(get($0)) }, set: { state, value in
            if case let .color(v) = value { set(&state, v) }
        })
    }

    private static func transform(_ get: @escaping (LayerState) -> CATransform3D, _ set: @escaping (inout LayerState, CATransform3D) -> Void) -> AnimatableKey {
        AnimatableKey(kind: .transform, get: { .transform(get($0)) }, set: { state, value in
            if case let .transform(v) = value { set(&state, v) }
        })
    }

    private static func make(_ keyPath: String) -> AnimatableKey? {
        switch keyPath {
        case "opacity": return scalar({ Double($0.opacity) }, { $0.opacity = Float($1) })
        case "zPosition": return scalar({ Double($0.zPosition) }, { $0.zPosition = CGFloat($1) })
        case "anchorPointZ": return scalar({ Double($0.anchorPointZ) }, { $0.anchorPointZ = CGFloat($1) })
        case "cornerRadius": return scalar({ Double($0.cornerRadius) }, { $0.cornerRadius = CGFloat($1) })
        case "borderWidth": return scalar({ Double($0.borderWidth) }, { $0.borderWidth = CGFloat($1) })
        case "shadowOpacity": return scalar({ Double($0.shadowOpacity) }, { $0.shadowOpacity = Float($1) })
        case "shadowRadius": return scalar({ Double($0.shadowRadius) }, { $0.shadowRadius = CGFloat($1) })
        case "hidden", "isHidden": return scalar({ $0.isHidden ? 1 : 0 }, { $0.isHidden = $1 >= 0.5 })
        case "contentsScale": return scalar({ Double($0.contentsScale) }, { $0.contentsScale = CGFloat($1) })
        case "position": return point({ $0.position }, { $0.position = $1 })
        case "position.x": return scalar({ Double($0.position.x) }, { $0.position.x = CGFloat($1) })
        case "position.y": return scalar({ Double($0.position.y) }, { $0.position.y = CGFloat($1) })
        case "anchorPoint": return point({ $0.anchorPoint }, { $0.anchorPoint = $1 })
        case "bounds":
            return AnimatableKey(kind: .rect, get: { .rect($0.bounds) }, set: { state, value in
                if case let .rect(r) = value { state.bounds = r }
            })
        case "bounds.size":
            return AnimatableKey(kind: .size, get: { .size($0.bounds.size) }, set: { state, value in
                if case let .size(s) = value { state.bounds.size = s }
            })
        case "bounds.origin": return point({ $0.bounds.origin }, { $0.bounds.origin = $1 })
        case "bounds.size.width": return scalar({ Double($0.bounds.width) }, { $0.bounds.size.width = CGFloat($1) })
        case "bounds.size.height": return scalar({ Double($0.bounds.height) }, { $0.bounds.size.height = CGFloat($1) })
        case "shadowOffset":
            return AnimatableKey(kind: .size, get: { .size($0.shadowOffset) }, set: { state, value in
                if case let .size(s) = value { state.shadowOffset = s }
            })
        case "contentsRect":
            return AnimatableKey(kind: .rect, get: { .rect($0.contentsRect) }, set: { state, value in
                if case let .rect(r) = value { state.contentsRect = r }
            })
        case "contentsCenter":
            return AnimatableKey(kind: .rect, get: { .rect($0.contentsCenter) }, set: { state, value in
                if case let .rect(r) = value { state.contentsCenter = r }
            })
        case "transform": return transform({ $0.transform }, { $0.transform = $1 })
        case "sublayerTransform": return transform({ $0.sublayerTransform }, { $0.sublayerTransform = $1 })
        case "transform.scale":
            return scalar({ Double($0.transform.m11) }, { $0.transform = CATransform3DMakeScale(CGFloat($1), CGFloat($1), CGFloat($1)) })
        case "transform.scale.x": return scalar({ Double($0.transform.m11) }, { $0.transform.m11 = CGFloat($1) })
        case "transform.scale.y": return scalar({ Double($0.transform.m22) }, { $0.transform.m22 = CGFloat($1) })
        case "transform.translation.x": return scalar({ Double($0.transform.m41) }, { $0.transform.m41 = CGFloat($1) })
        case "transform.translation.y": return scalar({ Double($0.transform.m42) }, { $0.transform.m42 = CGFloat($1) })
        case "transform.rotation", "transform.rotation.z":
            return scalar({ atan2(Double($0.transform.m12), Double($0.transform.m11)) }, { $0.transform = CATransform3DMakeRotation(CGFloat($1), 0, 0, 1) })
        case "transform.rotation.y":
            return scalar({ atan2(-Double($0.transform.m13), Double($0.transform.m11)) }, { $0.transform = CATransform3DMakeRotation(CGFloat($1), 0, 1, 0) })
        case "transform.rotation.x":
            return scalar({ atan2(Double($0.transform.m23), Double($0.transform.m22)) }, { $0.transform = CATransform3DMakeRotation(CGFloat($1), 1, 0, 0) })
        case "backgroundColor": return color({ $0.backgroundColor }, { $0.backgroundColor = $1 })
        case "borderColor": return color({ $0.borderColor }, { $0.borderColor = $1 })
        case "shadowColor": return color({ $0.shadowColor }, { $0.shadowColor = $1 })
        case "fillColor": return color({ $0.fillColor }, { $0.fillColor = $1 })
        case "strokeColor": return color({ $0.strokeColor }, { $0.strokeColor = $1 })
        case "lineWidth": return scalar({ Double($0.lineWidth) }, { $0.lineWidth = CGFloat($1) })
        case "strokeStart": return scalar({ Double($0.strokeStart) }, { $0.strokeStart = CGFloat($1) })
        case "strokeEnd": return scalar({ Double($0.strokeEnd) }, { $0.strokeEnd = CGFloat($1) })
        case "colors":
            return AnimatableKey(kind: .colors, get: { .colors($0.gradientColors) }, set: { state, value in
                if case let .colors(c) = value { state.gradientColors = c }
            })
        case "locations":
            return AnimatableKey(kind: .numbers, get: { .numbers($0.gradientLocations ?? []) }, set: { state, value in
                if case let .numbers(n) = value { state.gradientLocations = n.isEmpty ? nil : n }
            })
        case "startPoint": return point({ $0.startPoint }, { $0.startPoint = $1 })
        case "endPoint": return point({ $0.endPoint }, { $0.endPoint = $1 })
        case "instanceDelay": return scalar({ $0.instanceDelay }, { $0.instanceDelay = $1 })
        case "contents":
            return AnimatableKey(kind: .object, get: { .object($0.contents) }, set: { state, value in
                if case let .object(o) = value { state.contents = o }
            })
        default:
            // filters.<name>.<parameter>
            let parts = keyPath.split(separator: ".").map(String.init)
            if parts.count == 3, parts[0] == "filters" {
                let key = parts[1] + "." + parts[2]
                return scalar({ $0.filterValues[key] ?? 0 }, { $0.filterValues[key] = $1 })
            }
            return nil
        }
    }
}

/// Everything about a layer that rendering reads, as a value so animations can be applied
/// to a copy.
struct LayerState {
    var bounds = CGRect.zero
    var position = CGPoint.zero
    var zPosition: CGFloat = 0
    var anchorPoint = CGPoint(x: 0.5, y: 0.5)
    var anchorPointZ: CGFloat = 0
    var transform = CATransform3DIdentity
    var sublayerTransform = CATransform3DIdentity
    var opacity: Float = 1
    var isHidden = false
    var masksToBounds = false
    var isDoubleSided = true
    var isGeometryFlipped = false
    var backgroundColor: CGColor?
    var cornerRadius: CGFloat = 0
    var borderWidth: CGFloat = 0
    var borderColor: CGColor? = CGColor(gray: 0, alpha: 1)
    var contents: Any?
    var contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
    var contentsScale: CGFloat = 1
    var contentsGravity: CALayerContentsGravity = .resize
    var shadowColor: CGColor? = CGColor(gray: 0, alpha: 1)
    var shadowOpacity: Float = 0
    var shadowOffset = CGSize(width: 0, height: -3)
    var shadowRadius: CGFloat = 3
    var shadowPath: CGPath?
    var filters: [Any]?
    /// Animated filter parameters, keyed "name.parameter".
    var filterValues: [String: Double] = [:]
    var minificationFilter: CALayerContentsFilter = .linear
    var magnificationFilter: CALayerContentsFilter = .linear

    // Gradient layers
    var gradientColors: [CGColor] = []
    var gradientLocations: [Double]?
    var startPoint = CGPoint(x: 0.5, y: 0)
    var endPoint = CGPoint(x: 0.5, y: 1)
    var gradientType: CAGradientLayerType = .axial

    // Shape layers
    var shapePath: CGPath?
    var fillColor: CGColor? = CGColor(gray: 0, alpha: 1)
    var strokeColor: CGColor?
    var lineWidth: CGFloat = 1
    var strokeStart: CGFloat = 0
    var strokeEnd: CGFloat = 1
    var fillRule: CAShapeLayerFillRule = .nonZero
    var lineCap: CAShapeLayerLineCap = .butt
    var lineJoin: CAShapeLayerLineJoin = .miter
    var lineDashPattern: [NSNumber]?
    var lineDashPhase: CGFloat = 0

    // Replicator layers
    var instanceCount = 1
    var instanceTransform = CATransform3DIdentity
    var instanceDelay: Double = 0
    var instanceColor: CGColor?
    var instanceAlphaOffset: Float = 0

    /// The blur radius of a named Gaussian blur filter, animated or not.
    func blurRadius() -> CGFloat {
        guard let filters else { return 0 }
        var radius: CGFloat = 0
        for case let filter as CIFilter in filters where filter.filterName == "CIGaussianBlur" {
            let key = "\(filter.name).inputRadius"
            if let animated = filterValues[key] {
                radius = max(radius, CGFloat(animated))
            } else if let value = filter.value(forKey: kCIInputRadiusKey) {
                radius = max(radius, CGFloat((value as? NSNumber)?.doubleValue ?? (value as? Double) ?? 0))
            }
        }
        return radius
    }
}
