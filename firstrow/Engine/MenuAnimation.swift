import QuartzCore

// How state changes reach the screen.
//
// The menus change state the same way they always have: plainly, or inside `withAnimation`
// and `withTransaction`. Instead of SwiftUI re-evaluating views, `MenuSceneRenderer` compares
// the new state with what it last drew and moves Core Animation layers. A plain change is
// drawn at the end of the current run loop pass; a change inside `withAnimation` is drawn
// immediately afterwards with that animation, so only the properties it touched animate.

/// A timing curve and duration for a state change, in the vocabulary the menus were written in.
struct Animation: Equatable {
    enum Curve: Equatable {
        case easeInOut
        case easeIn
        case easeOut
        case linear
    }

    var curve: Curve
    var duration: Double
    var delay: Double = 0
    var repeatsForever = false

    static func easeInOut(duration: Double) -> Animation { Animation(curve: .easeInOut, duration: duration) }
    static func easeIn(duration: Double) -> Animation { Animation(curve: .easeIn, duration: duration) }
    static func easeOut(duration: Double) -> Animation { Animation(curve: .easeOut, duration: duration) }
    static func linear(duration: Double) -> Animation { Animation(curve: .linear, duration: duration) }
    static let easeInOut = Animation(curve: .easeInOut, duration: 0.35)
    static let `default` = Animation.easeInOut

    func delay(_ seconds: Double) -> Animation {
        var copy = self
        copy.delay = seconds
        return copy
    }

    func repeatForever(autoreverses _: Bool = false) -> Animation {
        var copy = self
        copy.repeatsForever = true
        return copy
    }

    var timingFunction: CAMediaTimingFunction {
        switch curve {
        case .easeInOut: CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
        case .easeIn: CAMediaTimingFunction(controlPoints: 0.42, 0, 1, 1)
        case .easeOut: CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
        case .linear: CAMediaTimingFunction(name: .linear)
        }
    }
}

/// The context of a state change: its animation, or none at all.
struct Transaction {
    var animation: Animation?
    /// Also turns off the animations views attach to particular values.
    var disablesAnimations = false

    init(animation: Animation? = nil) {
        self.animation = animation
    }

    static var instant: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }
}

/// Something that draws state and wants to know how each change should animate.
@MainActor
protocol TransactionRendering: AnyObject {
    /// Draws any state changes not yet drawn, animating them as `transaction` says.
    func render(_ transaction: Transaction)
}

@MainActor
enum RenderScheduler {
    private final class WeakRenderer {
        weak var renderer: TransactionRendering?
        init(_ renderer: TransactionRendering) { self.renderer = renderer }
    }

    private static var renderers: [WeakRenderer] = []
    /// The transactions of the `withTransaction` calls currently running, innermost last.
    private(set) static var transactionStack: [Transaction] = []

    static func register(_ renderer: TransactionRendering) {
        renderers.removeAll { $0.renderer == nil || $0.renderer === renderer }
        renderers.append(WeakRenderer(renderer))
    }

    static func unregister(_ renderer: TransactionRendering) {
        renderers.removeAll { $0.renderer == nil || $0.renderer === renderer }
    }

    fileprivate static func render(_ transaction: Transaction) {
        for entry in renderers {
            entry.renderer?.render(transaction)
        }
    }

    fileprivate static func push(_ transaction: Transaction) {
        transactionStack.append(transaction)
    }

    fileprivate static func pop() {
        transactionStack.removeLast()
    }

    /// The transaction that changes made right now belong to.
    static var currentTransaction: Transaction {
        transactionStack.last ?? Transaction()
    }
}

/// Runs `body` and animates the state changes it makes.
@MainActor
@discardableResult
func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try withTransaction(Transaction(animation: animation), body)
}

/// Runs `body` and draws the state changes it makes as `transaction` says.
@MainActor
@discardableResult
func withTransaction<Result>(_ transaction: Transaction, _ body: () throws -> Result) rethrows -> Result {
    // Changes made before this call belong to whatever was going on before it.
    RenderScheduler.render(RenderScheduler.currentTransaction)
    RenderScheduler.push(transaction)
    defer {
        RenderScheduler.pop()
        RenderScheduler.render(transaction)
    }
    return try body()
}

/// One drawing pass: the transaction its changes belong to.
struct RenderPass {
    let transaction: Transaction

    /// The animation for properties that follow the transaction.
    var animation: Animation? {
        transaction.disablesAnimations ? nil : transaction.animation
    }

    /// The animation for a property with its own animation for when `valueChanged`, like a
    /// SwiftUI view with `.animation(_:value:)`; otherwise it follows the transaction.
    func animation(_ own: Animation?, when valueChanged: Bool) -> Animation? {
        if transaction.disablesAnimations { return nil }
        return valueChanged ? own : transaction.animation
    }
}

/// A cubic Bézier timing curve from (0, 0) to (1, 1), evaluated the way Core Animation does,
/// so code can tell where an animation has got to and how fast it is going.
struct TimingCurve: Equatable {
    var c1: CGPoint
    var c2: CGPoint

    static let easeInEaseOut = TimingCurve(c1: CGPoint(x: 0.42, y: 0), c2: CGPoint(x: 0.58, y: 1))
    static let linear = TimingCurve(c1: .zero, c2: CGPoint(x: 1, y: 1))

    init(c1: CGPoint, c2: CGPoint) {
        self.c1 = c1
        self.c2 = c2
    }

    init(_ function: CAMediaTimingFunction) {
        var first: [Float] = [0, 0]
        var second: [Float] = [0, 0]
        function.getControlPoint(at: 1, values: &first)
        function.getControlPoint(at: 2, values: &second)
        c1 = CGPoint(x: CGFloat(first[0]), y: CGFloat(first[1]))
        c2 = CGPoint(x: CGFloat(second[0]), y: CGFloat(second[1]))
    }

    var function: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(c1.x), Float(c1.y), Float(c2.x), Float(c2.y))
    }

    /// An ease in and out that starts at `slope` (progress per unit of time, 1 being the
    /// average speed) instead of from a standstill, so a move that takes over from another
    /// carries on at the speed things were already going.
    static func easeInOut(startingSlope slope: Double) -> TimingCurve {
        guard slope > 0.001 else { return .easeInEaseOut }
        // The first handle's direction sets the starting speed (rise over run).
        let x1 = min(0.42, 1 / slope)
        return TimingCurve(c1: CGPoint(x: x1, y: CGFloat(slope) * x1), c2: CGPoint(x: 0.58, y: 1))
    }

    private static func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    private static func derivative(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }

    private func parameter(forTime x: Double) -> Double {
        var low = 0.0
        var high = 1.0
        for _ in 0 ..< 32 {
            let mid = (low + high) / 2
            if Self.bezier(mid, Double(c1.x), Double(c2.x)) < x { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// Progress (0 to 1) at time fraction `x`.
    func value(at x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return Self.bezier(parameter(forTime: x), Double(c1.y), Double(c2.y))
    }

    /// Rate of progress at time fraction `x` (1 is the average rate).
    func slope(at x: Double) -> Double {
        guard x >= 0, x < 1 else { return 0 }
        let t = parameter(forTime: x)
        let dx = Self.derivative(t, Double(c1.x), Double(c2.x))
        let dy = Self.derivative(t, Double(c1.y), Double(c2.y))
        return dx > 1e-6 ? dy / dx : 0
    }
}

/// Where a running basic animation is and how fast it is moving, worked out from the
/// animation itself rather than read back from the screen.
private struct AnimationMotion {
    let value: [Double]
    let velocity: [Double]

    init?(_ animation: CABasicAnimation, at time: CFTimeInterval) {
        guard animation.beginTime > 0, animation.duration > 0, animation.repeatCount == 0,
              animation.speed == 1, animation.timeOffset == 0,
              let from = animation.fromValue.flatMap(Self.components),
              let to = animation.toValue.flatMap(Self.components), from.count == to.count
        else { return nil }
        let curve = TimingCurve(animation.timingFunction ?? CAMediaTimingFunction(name: .linear))
        let x = (time - animation.beginTime) / animation.duration
        let progress = curve.value(at: x)
        let rate = curve.slope(at: x) / animation.duration
        value = zip(from, to).map { $0 + ($1 - $0) * progress }
        velocity = zip(from, to).map { ($1 - $0) * rate }
    }

    /// How fast, as a curve's starting slope, a move to `target` taking `duration` would have
    /// to start to keep this motion's speed along its own direction.
    func startingSlope(toward target: [Double], duration: Double) -> Double? {
        guard target.count == value.count else { return nil }
        let delta = zip(value, target).map { $1 - $0 }
        let distance = delta.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard distance > 1e-6 else { return nil }
        let along = zip(velocity, delta).reduce(0) { $0 + $1.0 * $1.1 } / distance
        let slope = along * duration / distance
        return slope > 0.01 ? slope : nil
    }

    static func components(_ value: Any) -> [Double]? {
        if let number = value as? NSNumber {
            return [number.doubleValue]
        }
        guard let boxed = value as? NSValue else { return nil }
        let type = String(cString: boxed.objCType)
        if type.hasPrefix("{CGPoint") || type.hasPrefix("{_NSPoint") {
            let point = boxed.layerPointValue
            return [Double(point.x), Double(point.y)]
        }
        if type.hasPrefix("{CGRect") || type.hasPrefix("{_NSRect") {
            let rect = boxed.layerRectValue
            return [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
        }
        return nil
    }

    /// The motion's current value, boxed like `template`.
    func boxed(like template: Any) -> Any? {
        if template is NSNumber, value.count == 1 {
            return NSNumber(value: value[0])
        }
        guard let boxed = template as? NSValue else { return nil }
        let type = String(cString: boxed.objCType)
        if value.count == 2, type.hasPrefix("{CGPoint") || type.hasPrefix("{_NSPoint") {
            return NSValue.layerPoint(CGPoint(x: value[0], y: value[1]))
        }
        if value.count == 4, type.hasPrefix("{CGRect") || type.hasPrefix("{_NSRect") {
            return NSValue.layerRect(CGRect(x: value[0], y: value[1], width: value[2], height: value[3]))
        }
        return nil
    }
}

extension CALayer {
    /// Sets a property, animating from what is on screen now when `animation` is given.
    ///
    /// A move that takes over from one still running starts where that one has got to and,
    /// for ease-in-out moves, at the speed it was going, the way SwiftUI blended interrupted
    /// animations (starting again from a standstill made quick presses stutter). Every move
    /// starts at the moment it is set, so work later in the same pass can't hold it back and
    /// make the first frame land behind where the previous move had already reached.
    func set(_ keyPath: String, to newValue: Any, unchanged: Bool, animation: Animation?) {
        if unchanged {
            return
        }
        guard let animation, animation.duration > 0 else {
            removeAnimation(forKey: keyPath)
            setValue(newValue, forKeyPath: keyPath)
            return
        }
        let now = convertTime(CACurrentMediaTime(), from: nil)
        var fromValue = value(forKeyPath: keyPath)
        var curve = TimingCurve(animation.timingFunction)
        if let running = self.animation(forKey: keyPath) {
            if let basic = running as? CABasicAnimation, let motion = AnimationMotion(basic, at: now),
               let current = motion.boxed(like: newValue)
            {
                fromValue = current
                if animation.curve == .easeInOut, animation.delay == 0, !animation.repeatsForever,
                   let target = AnimationMotion.components(newValue),
                   let slope = motion.startingSlope(toward: target, duration: animation.duration)
                {
                    curve = .easeInOut(startingSlope: slope)
                }
            } else {
                fromValue = presentation()?.value(forKeyPath: keyPath) ?? fromValue
            }
        }
        setValue(newValue, forKeyPath: keyPath)
        let basic = CABasicAnimation(keyPath: keyPath)
        basic.fromValue = fromValue
        basic.toValue = newValue
        basic.duration = animation.duration
        basic.timingFunction = curve.function
        basic.beginTime = now + animation.delay
        if animation.delay > 0 {
            basic.fillMode = .backwards
        }
        if animation.repeatsForever {
            basic.repeatCount = .infinity
        }
        add(basic, forKey: keyPath)
    }

    func setOpacity(_ value: Double, _ animation: Animation?) {
        let target = Float(max(0, min(1, value)))
        set("opacity", to: target, unchanged: opacity == target, animation: animation)
    }

    /// Positions the layer by its anchor point.
    func setPosition(_ point: CGPoint, _ animation: Animation?) {
        set("position", to: NSValue.layerPoint(point), unchanged: position == point, animation: animation)
    }

    func setBoundsSize(_ size: CGSize, _ animation: Animation?) {
        let rect = CGRect(origin: bounds.origin, size: size)
        set("bounds", to: NSValue.layerRect(rect), unchanged: bounds.size == size, animation: animation)
    }

    /// Places a layer whose anchor point is its top-left corner (in a top-left-origin space).
    func setFrame(_ frame: CGRect, _ animation: Animation?) {
        setBoundsSize(frame.size, animation)
        setPosition(CGPoint(x: frame.minX + frame.width * anchorPoint.x, y: frame.minY + frame.height * anchorPoint.y), animation)
    }

    func setTransform(_ value: CATransform3D, _ animation: Animation?) {
        set("transform", to: NSValue(caTransform3D: value), unchanged: CATransform3DEqualToTransform(transform, value), animation: animation)
    }

    func setHiddenIfTransparent() {
        isHidden = opacity <= 0.0001 && animation(forKey: "opacity") == nil
    }
}

/// A layer laid out from its top-left corner that never animates implicitly.
class SceneLayer: CALayer {
    override init() {
        super.init()
        anchorPoint = .zero
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func action(forKey _: String) -> CAAction? { nil }
}

final class SceneGradientLayer: CAGradientLayer {
    override init() {
        super.init()
        anchorPoint = .zero
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func action(forKey _: String) -> CAAction? { nil }
}

final class SceneShapeLayer: CAShapeLayer {
    override init() {
        super.init()
        anchorPoint = .zero
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func action(forKey _: String) -> CAAction? { nil }
}
