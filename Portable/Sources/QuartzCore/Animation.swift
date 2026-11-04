import CoreGraphics
import Foundation

public protocol CAAction {
    func run(forKey event: String, object anObject: Any, arguments dict: [AnyHashable: Any]?)
}

extension NSNull: CAAction {
    public func run(forKey _: String, object _: Any, arguments _: [AnyHashable: Any]?) {}
}

public protocol CAAnimationDelegate: AnyObject {
    func animationDidStart(_ anim: CAAnimation)
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool)
}

public extension CAAnimationDelegate {
    func animationDidStart(_: CAAnimation) {}
    func animationDidStop(_: CAAnimation, finished _: Bool) {}
}

public struct CAAnimationCalculationMode: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let linear = CAAnimationCalculationMode(rawValue: "linear")
    public static let discrete = CAAnimationCalculationMode(rawValue: "discrete")
    public static let paced = CAAnimationCalculationMode(rawValue: "paced")
    public static let cubic = CAAnimationCalculationMode(rawValue: "cubic")
    public static let cubicPaced = CAAnimationCalculationMode(rawValue: "cubicPaced")
}

open class CAAnimation: NSObject, CAMediaTiming, CAAction, NSCopying {
    public var beginTime: CFTimeInterval = 0
    public var duration: CFTimeInterval = 0
    public var speed: Float = 1
    public var timeOffset: CFTimeInterval = 0
    public var repeatCount: Float = 0
    public var repeatDuration: CFTimeInterval = 0
    public var autoreverses = false
    public var fillMode: CAMediaTimingFillMode = .removed
    public var timingFunction: CAMediaTimingFunction?
    public var isRemovedOnCompletion = true
    public var delegate: CAAnimationDelegate? {
        get { strongDelegate }
        set { strongDelegate = newValue }
    }

    // Core Animation keeps its delegate alive.
    private var strongDelegate: CAAnimationDelegate?

    /// Set when the animation was added to a layer: the value its nil endpoints start from.
    var capturedFrom: AnimValue?
    var started = false
    weak var transaction: TransactionRecord?

    override public required init() {
        super.init()
    }

    public func copy(with _: NSZone? = nil) -> Any {
        let copy = type(of: self).init()
        copyAttributes(to: copy)
        return copy
    }

    func copyAttributes(to copy: CAAnimation) {
        copy.beginTime = beginTime
        copy.duration = duration
        copy.speed = speed
        copy.timeOffset = timeOffset
        copy.repeatCount = repeatCount
        copy.repeatDuration = repeatDuration
        copy.autoreverses = autoreverses
        copy.fillMode = fillMode
        copy.timingFunction = timingFunction
        copy.isRemovedOnCompletion = isRemovedOnCompletion
        copy.strongDelegate = strongDelegate
    }

    open class func defaultValue(forKey _: String) -> Any? { nil }

    public func run(forKey event: String, object anObject: Any, arguments _: [AnyHashable: Any]?) {
        (anObject as? CALayer)?.add(self, forKey: event)
    }

    /// Set on an animation inside a group: a duration of 0 then means the group's.
    var inheritedDuration: Double?

    func phase(at layerTime: Double) -> TimingPhase {
        TimingModel.phase(parentTime: layerTime, beginTime: beginTime, duration: effectiveDuration, speed: speed, timeOffset: timeOffset,
                          repeatCount: repeatCount, repeatDuration: repeatDuration, autoreverses: autoreverses, fillMode: fillMode)
    }

    var effectiveDuration: Double { duration > 0 ? duration : (inheritedDuration ?? 0.25) }

    /// Applies the animation to `state` at `layerTime` and says whether it has finished.
    func apply(to _: inout LayerState, at _: Double, base _: LayerState) -> Bool { true }
}

open class CAPropertyAnimation: CAAnimation {
    public var keyPath: String?
    public var isAdditive = false
    public var isCumulative = false

    public convenience init(keyPath path: String?) {
        self.init()
        keyPath = path
    }

    override func copyAttributes(to copy: CAAnimation) {
        super.copyAttributes(to: copy)
        if let copy = copy as? CAPropertyAnimation {
            copy.keyPath = keyPath
            copy.isAdditive = isAdditive
            copy.isCumulative = isCumulative
        }
    }

    /// The value at `progress` (0...1 after timing), or nil when there is nothing to show.
    func value(at _: Double, base _: AnimValue) -> AnimValue? { nil }

    override func apply(to state: inout LayerState, at layerTime: Double, base: LayerState) -> Bool {
        guard let keyPath, let key = AnimatableKey(keyPath) else { return true }
        let phase = phase(at: layerTime)
        guard phase.active else { return phase.finished }
        var fraction = phase.local / effectiveDuration
        if let timingFunction { fraction = timingFunction.value(at: fraction) }
        let baseValue = key.get(base)
        guard var value = value(at: fraction, base: capturedFrom ?? baseValue) else { return phase.finished }
        if isAdditive {
            value = AnimValue.add(key.get(state), value)
        }
        key.set(&state, value)
        return phase.finished
    }
}

open class CABasicAnimation: CAPropertyAnimation {
    public var fromValue: Any?
    public var toValue: Any?
    public var byValue: Any?

    override func copyAttributes(to copy: CAAnimation) {
        super.copyAttributes(to: copy)
        if let copy = copy as? CABasicAnimation {
            copy.fromValue = fromValue
            copy.toValue = toValue
            copy.byValue = byValue
        }
    }

    override func value(at progress: Double, base: AnimValue) -> AnimValue? {
        guard let keyPath, let key = AnimatableKey(keyPath) else { return nil }
        let from = fromValue.flatMap { key.kind.convert($0) }
        let to = toValue.flatMap { key.kind.convert($0) }
        let by = byValue.flatMap { key.kind.convert($0) }
        let start: AnimValue
        let end: AnimValue
        switch (from, to, by) {
        case let (f?, t?, _): start = f; end = t
        case let (f?, nil, b?): start = f; end = AnimValue.add(f, b)
        case let (nil, t?, b?): start = AnimValue.subtract(t, b); end = t
        case let (f?, nil, nil): start = f; end = base
        case let (nil, t?, nil): start = capturedFrom ?? base; end = t
        case let (nil, nil, b?): start = base; end = AnimValue.add(base, b)
        case (nil, nil, nil): start = capturedFrom ?? base; end = base
        }
        return AnimValue.interpolate(start, end, progress)
    }
}

open class CAKeyframeAnimation: CAPropertyAnimation {
    public var values: [Any]?
    public var keyTimes: [NSNumber]?
    public var timingFunctions: [CAMediaTimingFunction]?
    public var calculationMode: CAAnimationCalculationMode = .linear
    public var path: CGPath?
    public var tensionValues: [NSNumber]?
    public var continuityValues: [NSNumber]?
    public var biasValues: [NSNumber]?

    override func copyAttributes(to copy: CAAnimation) {
        super.copyAttributes(to: copy)
        if let copy = copy as? CAKeyframeAnimation {
            copy.values = values
            copy.keyTimes = keyTimes
            copy.timingFunctions = timingFunctions
            copy.calculationMode = calculationMode
            copy.path = path
        }
    }

    private var convertedCache: (String, [AnimValue])?

    override func value(at progress: Double, base _: AnimValue) -> AnimValue? {
        guard let keyPath, let key = AnimatableKey(keyPath), let values, !values.isEmpty else { return nil }
        let converted: [AnimValue]
        if let cache = convertedCache, cache.0 == keyPath {
            converted = cache.1
        } else {
            converted = values.compactMap { key.kind.convert($0) }
            convertedCache = (keyPath, converted)
        }
        guard !converted.isEmpty else { return nil }
        if converted.count == 1 { return converted[0] }
        let times: [Double]
        if let keyTimes, keyTimes.count == converted.count {
            times = keyTimes.map(\.doubleValue)
        } else if calculationMode == .discrete {
            times = (0 ..< converted.count).map { Double($0) / Double(converted.count) }
        } else {
            times = (0 ..< converted.count).map { Double($0) / Double(converted.count - 1) }
        }
        if calculationMode == .discrete {
            var index = 0
            for (i, time) in times.enumerated() where progress >= time { index = i }
            return converted[min(index, converted.count - 1)]
        }
        if progress <= times[0] { return converted[0] }
        if progress >= times[times.count - 1] { return converted[converted.count - 1] }
        var segment = 0
        while segment < times.count - 2, progress >= times[segment + 1] { segment += 1 }
        let span = times[segment + 1] - times[segment]
        var local = span > 0 ? (progress - times[segment]) / span : 1
        if let timingFunctions, !timingFunctions.isEmpty {
            local = timingFunctions[min(segment, timingFunctions.count - 1)].value(at: local)
        }
        return AnimValue.interpolate(converted[segment], converted[segment + 1], local)
    }
}

open class CAAnimationGroup: CAAnimation {
    public var animations: [CAAnimation]?

    override func copyAttributes(to copy: CAAnimation) {
        super.copyAttributes(to: copy)
        (copy as? CAAnimationGroup)?.animations = animations?.map { $0.copy() as! CAAnimation }
    }

    override func apply(to state: inout LayerState, at layerTime: Double, base: LayerState) -> Bool {
        let phase = phase(at: layerTime)
        guard phase.active else { return phase.finished }
        var local = phase.local
        if let timingFunction {
            local = timingFunction.value(at: local / effectiveDuration) * effectiveDuration
        }
        // Children run on the group's clock and are cut off at its duration.
        for child in animations ?? [] {
            child.inheritedDuration = effectiveDuration
            let childPhase = child.phase(at: local)
            if childPhase.active || child.fillMode.fillsForwards || child.fillMode.fillsBackwards {
                child.capturedFrom = child.capturedFrom ?? capturedFrom
                _ = child.apply(to: &state, at: local, base: base)
            }
        }
        return phase.finished
    }
}

public struct CATransitionType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fade = CATransitionType(rawValue: "fade")
    public static let moveIn = CATransitionType(rawValue: "moveIn")
    public static let push = CATransitionType(rawValue: "push")
    public static let reveal = CATransitionType(rawValue: "reveal")
}

public struct CATransitionSubtype: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fromRight = CATransitionSubtype(rawValue: "fromRight")
    public static let fromLeft = CATransitionSubtype(rawValue: "fromLeft")
    public static let fromTop = CATransitionSubtype(rawValue: "fromTop")
    public static let fromBottom = CATransitionSubtype(rawValue: "fromBottom")
}

/// Transitions are accepted but shown as an immediate change.
open class CATransition: CAAnimation {
    public var type: CATransitionType = .fade
    public var subtype: CATransitionSubtype?
}

public final class CASpringAnimation: CABasicAnimation {
    public var mass: CGFloat = 1
    public var stiffness: CGFloat = 100
    public var damping: CGFloat = 10
    public var initialVelocity: CGFloat = 0
    public var settlingDuration: CFTimeInterval { duration }
}
