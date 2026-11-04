import CoreGraphics
import Foundation

/// Seconds on a monotonic clock, as Core Animation measures time.
public func CACurrentMediaTime() -> CFTimeInterval {
    ProcessInfo.processInfo.systemUptime
}

public struct CAMediaTimingFunctionName: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let linear = CAMediaTimingFunctionName(rawValue: "linear")
    public static let easeIn = CAMediaTimingFunctionName(rawValue: "easeIn")
    public static let easeOut = CAMediaTimingFunctionName(rawValue: "easeOut")
    public static let easeInEaseOut = CAMediaTimingFunctionName(rawValue: "easeInEaseOut")
    public static let `default` = CAMediaTimingFunctionName(rawValue: "default")
}

public final class CAMediaTimingFunction: NSObject, @unchecked Sendable {
    let c1: (Double, Double)
    let c2: (Double, Double)

    public init(controlPoints c1x: Float, _ c1y: Float, _ c2x: Float, _ c2y: Float) {
        c1 = (Double(c1x), Double(c1y))
        c2 = (Double(c2x), Double(c2y))
        super.init()
    }

    public convenience init(name: CAMediaTimingFunctionName) {
        switch name {
        case .easeIn: self.init(controlPoints: 0.42, 0, 1, 1)
        case .easeOut: self.init(controlPoints: 0, 0, 0.58, 1)
        case .easeInEaseOut: self.init(controlPoints: 0.42, 0, 0.58, 1)
        case .default: self.init(controlPoints: 0.25, 0.1, 0.25, 1)
        default: self.init(controlPoints: 0, 0, 1, 1)
        }
    }

    public func getControlPoint(at index: Int, values: UnsafeMutablePointer<Float>) {
        let point: (Double, Double) = switch index {
        case 0: (0, 0)
        case 1: c1
        case 2: c2
        default: (1, 1)
        }
        values[0] = Float(point.0)
        values[1] = Float(point.1)
    }

    private static func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    /// Progress at time fraction `x`, solved the way Core Animation does it.
    func value(at x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        if c1.0 == c1.1, c2.0 == c2.1 { return x }
        var low = 0.0
        var high = 1.0
        var t = x
        for _ in 0 ..< 40 {
            t = (low + high) / 2
            if Self.bezier(t, c1.0, c2.0) < x { low = t } else { high = t }
        }
        return Self.bezier((low + high) / 2, c1.1, c2.1)
    }

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CAMediaTimingFunction else { return false }
        return other.c1 == c1 && other.c2 == c2
    }
}

public struct CAMediaTimingFillMode: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let forwards = CAMediaTimingFillMode(rawValue: "forwards")
    public static let backwards = CAMediaTimingFillMode(rawValue: "backwards")
    public static let both = CAMediaTimingFillMode(rawValue: "both")
    public static let removed = CAMediaTimingFillMode(rawValue: "removed")

    var fillsForwards: Bool { self == .forwards || self == .both }
    var fillsBackwards: Bool { self == .backwards || self == .both }
}

public protocol CAMediaTiming: AnyObject {
    var beginTime: CFTimeInterval { get set }
    var duration: CFTimeInterval { get set }
    var speed: Float { get set }
    var timeOffset: CFTimeInterval { get set }
    var repeatCount: Float { get set }
    var repeatDuration: CFTimeInterval { get set }
    var autoreverses: Bool { get set }
    var fillMode: CAMediaTimingFillMode { get set }
}

/// Where a timed object is within its active period.
struct TimingPhase {
    /// Local time within the simple duration, after repeats and reversals.
    let local: Double
    /// True once the active period is over.
    let finished: Bool
    /// False when the object has no effect at this time.
    let active: Bool
}

enum TimingModel {
    /// Maps a parent time to local time for an object with Core Animation's timing rules.
    static func phase(parentTime: Double, beginTime: Double, duration rawDuration: Double, speed: Float, timeOffset: Double,
                      repeatCount: Float, repeatDuration: Double, autoreverses: Bool, fillMode: CAMediaTimingFillMode) -> TimingPhase
    {
        let duration = rawDuration > 0 ? rawDuration : 0.25
        let elapsed = (parentTime - beginTime) * Double(speed)
        var t = elapsed + timeOffset
        let cycle = autoreverses ? duration * 2 : duration
        let total: Double
        if repeatDuration > 0 {
            total = repeatDuration
        } else if repeatCount.isInfinite {
            total = .infinity
        } else if repeatCount > 0 {
            total = cycle * Double(repeatCount)
        } else {
            total = cycle
        }
        if elapsed < 0 {
            // Not started yet: shows its first frame only when it fills backwards.
            guard fillMode.fillsBackwards else { return TimingPhase(local: 0, finished: false, active: false) }
            t = timeOffset
        }
        var finished = false
        if t >= total {
            finished = true
            if !fillMode.fillsForwards {
                return TimingPhase(local: 0, finished: true, active: false)
            }
            t = total
        }
        var local: Double
        if t >= total, total.isFinite {
            // Hold the value the last cycle ended on.
            let cycles = total / cycle
            let fraction = cycles - floor(cycles)
            local = fraction == 0 ? cycle : fraction * cycle
        } else {
            local = t.truncatingRemainder(dividingBy: cycle)
            if local < 0 { local += cycle }
        }
        if autoreverses, local > duration {
            local = cycle - local
        }
        return TimingPhase(local: min(duration, max(0, local)), finished: finished, active: true)
    }
}
