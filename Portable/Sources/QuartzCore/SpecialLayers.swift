import CoreGraphics
import Foundation

public struct CAGradientLayerType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let axial = CAGradientLayerType(rawValue: "axial")
    public static let radial = CAGradientLayerType(rawValue: "radial")
    public static let conic = CAGradientLayerType(rawValue: "conic")
}

open class CAGradientLayer: CALayer {
    override public init() { super.init() }
    override public init(layer: Any) { super.init(layer: layer) }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    /// CGColors, as on Apple platforms.
    public var colors: [Any]? {
        get { modelState.gradientColors.isEmpty ? nil : modelState.gradientColors }
        set {
            let list = (newValue ?? []).compactMap { $0 as? CGColor }
            change("colors", modelState.gradientColors, list) { $0.gradientColors = list }
        }
    }

    public var locations: [NSNumber]? {
        get { modelState.gradientLocations?.map { NSNumber(value: $0) } }
        set {
            let list = newValue?.map(\.doubleValue)
            change("locations", modelState.gradientLocations ?? [], list ?? []) { $0.gradientLocations = list }
        }
    }

    public var startPoint: CGPoint {
        get { modelState.startPoint }
        set { change("startPoint", modelState.startPoint, newValue) { $0.startPoint = newValue } }
    }

    public var endPoint: CGPoint {
        get { modelState.endPoint }
        set { change("endPoint", modelState.endPoint, newValue) { $0.endPoint = newValue } }
    }

    public var type: CAGradientLayerType {
        get { modelState.gradientType }
        set { change("type", modelState.gradientType, newValue, animatable: false) { $0.gradientType = newValue } }
    }
}

public struct CAShapeLayerFillRule: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let nonZero = CAShapeLayerFillRule(rawValue: "non-zero")
    public static let evenOdd = CAShapeLayerFillRule(rawValue: "even-odd")
}

public struct CAShapeLayerLineCap: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let butt = CAShapeLayerLineCap(rawValue: "butt")
    public static let round = CAShapeLayerLineCap(rawValue: "round")
    public static let square = CAShapeLayerLineCap(rawValue: "square")
}

public struct CAShapeLayerLineJoin: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let miter = CAShapeLayerLineJoin(rawValue: "miter")
    public static let round = CAShapeLayerLineJoin(rawValue: "round")
    public static let bevel = CAShapeLayerLineJoin(rawValue: "bevel")
}

open class CAShapeLayer: CALayer {
    override public init() { super.init() }
    override public init(layer: Any) { super.init(layer: layer) }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    public var path: CGPath? {
        get { modelState.shapePath }
        set { change("path", modelState.shapePath, newValue, animatable: false) { $0.shapePath = newValue } }
    }

    public var fillColor: CGColor? {
        get { modelState.fillColor }
        set { change("fillColor", modelState.fillColor, newValue) { $0.fillColor = newValue } }
    }

    public var strokeColor: CGColor? {
        get { modelState.strokeColor }
        set { change("strokeColor", modelState.strokeColor, newValue) { $0.strokeColor = newValue } }
    }

    public var lineWidth: CGFloat {
        get { modelState.lineWidth }
        set { change("lineWidth", modelState.lineWidth, newValue) { $0.lineWidth = newValue } }
    }

    public var strokeStart: CGFloat {
        get { modelState.strokeStart }
        set { change("strokeStart", modelState.strokeStart, newValue) { $0.strokeStart = newValue } }
    }

    public var strokeEnd: CGFloat {
        get { modelState.strokeEnd }
        set { change("strokeEnd", modelState.strokeEnd, newValue) { $0.strokeEnd = newValue } }
    }

    public var fillRule: CAShapeLayerFillRule {
        get { modelState.fillRule }
        set { change("fillRule", modelState.fillRule, newValue, animatable: false) { $0.fillRule = newValue } }
    }

    public var lineCap: CAShapeLayerLineCap {
        get { modelState.lineCap }
        set { change("lineCap", modelState.lineCap, newValue, animatable: false) { $0.lineCap = newValue } }
    }

    public var lineJoin: CAShapeLayerLineJoin {
        get { modelState.lineJoin }
        set { change("lineJoin", modelState.lineJoin, newValue, animatable: false) { $0.lineJoin = newValue } }
    }

    public var lineDashPattern: [NSNumber]? {
        get { modelState.lineDashPattern }
        set {
            modelState.lineDashPattern = newValue
            markChanged()
        }
    }

    public var lineDashPhase: CGFloat {
        get { modelState.lineDashPhase }
        set { change("lineDashPhase", modelState.lineDashPhase, newValue, animatable: false) { $0.lineDashPhase = newValue } }
    }

    public var miterLimit: CGFloat = 10
}

open class CAReplicatorLayer: CALayer {
    override public init() { super.init() }
    override public init(layer: Any) { super.init(layer: layer) }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    public var instanceCount: Int {
        get { modelState.instanceCount }
        set { change("instanceCount", modelState.instanceCount, newValue, animatable: false) { $0.instanceCount = newValue } }
    }

    public var instanceTransform: CATransform3D {
        get { modelState.instanceTransform }
        set { change("instanceTransform", modelState.instanceTransform, newValue) { $0.instanceTransform = newValue } }
    }

    public var instanceDelay: CFTimeInterval {
        get { modelState.instanceDelay }
        set { change("instanceDelay", modelState.instanceDelay, newValue) { $0.instanceDelay = newValue } }
    }

    public var instanceColor: CGColor? {
        get { modelState.instanceColor }
        set { change("instanceColor", modelState.instanceColor, newValue) { $0.instanceColor = newValue } }
    }

    public var instanceAlphaOffset: Float {
        get { modelState.instanceAlphaOffset }
        set { change("instanceAlphaOffset", modelState.instanceAlphaOffset, newValue, animatable: false) { $0.instanceAlphaOffset = newValue } }
    }

    public var preservesDepth = false
}

open class CATransformLayer: CALayer {}
