import Foundation
import QuartzCore

func tigerMix(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
    start + (end - start) * progress
}

func tigerUnit(_ value: CGFloat) -> CGFloat {
    min(max(value, 0), 1)
}

func tigerSmoothStep(_ value: CGFloat) -> CGFloat {
    let t = tigerUnit(value)
    return t * t * (3 - 2 * t)
}

/// A number that moves from where it is to a new value over a time, on a timing curve: the
/// ring's turn, how far a section has opened. Layers are placed from it as it will be at each
/// moment of the move (see `TigerKeyframes`), so one move can drive any number of them.
struct TigerMovingValue {
    private var from: Double
    private(set) var target: Double
    private var start: CFTimeInterval = 0
    private var duration: Double = 0
    private var curve = TimingCurve.easeInEaseOut
    /// Counts the moves, for whoever follows the value to tell a new one.
    private(set) var revision = 0

    init(_ value: Double) {
        from = value
        target = value
    }

    func value(at time: CFTimeInterval) -> Double {
        guard duration > 0 else { return target }
        let elapsed = time - start
        if elapsed >= duration { return target }
        if elapsed <= 0 { return from }
        return from + (target - from) * curve.value(at: elapsed / duration)
    }

    /// When the move under way ends (now or earlier, at rest).
    var endTime: CFTimeInterval {
        duration > 0 ? start + duration : 0
    }

    mutating func set(_ value: Double) {
        from = value
        target = value
        duration = 0
        revision &+= 1
    }

    /// Moves on from wherever it is now.
    mutating func move(to value: Double, duration: Double, curve: TimingCurve = .easeInEaseOut, delay: Double = 0) {
        let now = CACurrentMediaTime()
        from = self.value(at: now)
        target = value
        start = now + delay
        self.duration = duration
        self.curve = curve
        revision &+= 1
    }
}

/// Animations made by working a layer's place out at each moment of a move.
enum TigerKeyframes {
    static let step: Double = 1.0 / 90

    /// The moments from now to `end`, and now alone when nothing is moving.
    static func times(until end: CFTimeInterval) -> [CFTimeInterval] {
        let now = CACurrentMediaTime()
        guard end > now + 0.004 else { return [now] }
        let count = max(2, Int(((end - now) / step).rounded(.up)) + 1)
        return (0 ..< count).map { now + (end - now) * Double($0) / Double(count - 1) }
    }

    /// Puts `layer`'s property through `values` (one for each of `times`), and leaves it at the last.
    static func run(_ layer: CALayer, _ keyPath: String, _ values: [Any], times: [CFTimeInterval]) {
        guard let last = values.last else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(last, forKeyPath: keyPath)
        CATransaction.commit()
        guard values.count > 1, let first = times.first, let end = times.last, end > first else {
            layer.removeAnimation(forKey: "tiger." + keyPath)
            return
        }
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.calculationMode = .linear
        animation.duration = end - first
        animation.beginTime = layer.convertTime(first, from: nil)
        animation.isRemovedOnCompletion = true
        layer.addAtFullRate(animation, forKey: "tiger." + keyPath)
    }

    static func run(_ layer: CALayer, position points: [CGPoint], times: [CFTimeInterval]) {
        run(layer, "position", points.map { NSValue.layerPoint($0) }, times: times)
    }

    static func run(_ layer: CALayer, scale factors: [CGFloat], times: [CFTimeInterval]) {
        run(layer, "transform", factors.map { NSValue(caTransform3D: CATransform3DMakeScale($0, $0, 1)) }, times: times)
    }

    static func run(_ layer: CALayer, transform transforms: [CATransform3D], times: [CFTimeInterval]) {
        run(layer, "transform", transforms.map { NSValue(caTransform3D: $0) }, times: times)
    }

    static func run(_ layer: CALayer, opacity values: [CGFloat], times: [CFTimeInterval]) {
        run(layer, "opacity", values.map { NSNumber(value: Float(tigerUnit($0))) }, times: times)
    }

    static func run(_ layer: CALayer, zPosition values: [CGFloat], times: [CFTimeInterval]) {
        run(layer, "zPosition", values.map { NSNumber(value: Double($0)) }, times: times)
    }
}
