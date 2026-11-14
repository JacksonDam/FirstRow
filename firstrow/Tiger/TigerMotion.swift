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

/// A number that moves to a new value over a time, on a timing curve: the ring's turn, how
/// far a section has opened. Layers are placed from it as it will be at each moment of the
/// move (see `TigerKeyframes`), so one move can drive any number of them. A move begun while
/// another is under way is added to it, so the value keeps its speed: an arrow held down
/// turns the ring without a stop between its steps.
struct TigerMovingValue {
    /// One move: how far it was from its goal when it began, dying away along its curve.
    private struct Leg {
        var distance: Double
        var start: CFTimeInterval
        var duration: Double
        var curve: TimingCurve
    }

    private var legs: [Leg] = []
    private(set) var target: Double
    /// Where the latest move set out from.
    private(set) var origin: Double
    /// Counts the moves, for whoever follows the value to tell a new one.
    private(set) var revision = 0

    init(_ value: Double) {
        target = value
        origin = value
    }

    func value(at time: CFTimeInterval) -> Double {
        var value = target
        for leg in legs {
            let elapsed = time - leg.start
            if elapsed >= leg.duration { continue }
            let progress = elapsed <= 0 ? 0 : leg.curve.value(at: elapsed / leg.duration)
            value -= leg.distance * (1 - progress)
        }
        return value
    }

    /// When the last of the moves under way ends (0 at rest).
    var endTime: CFTimeInterval {
        legs.map { $0.start + $0.duration }.max() ?? 0
    }

    mutating func set(_ value: Double) {
        legs = []
        target = value
        origin = value
        revision &+= 1
    }

    mutating func move(to value: Double, duration: Double, curve: TimingCurve = .easeInEaseOut, delay: Double = 0) {
        let now = CACurrentMediaTime()
        origin = self.value(at: now)
        legs.removeAll { now >= $0.start + $0.duration }
        legs.append(Leg(distance: value - target, start: now + delay, duration: duration, curve: curve))
        target = value
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
