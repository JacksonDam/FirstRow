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

extension CALayer {
    /// Sets a property, animating from what is on screen now when `animation` is given.
    func set(_ keyPath: String, to newValue: Any, unchanged: Bool, animation: Animation?) {
        if unchanged {
            return
        }
        guard let animation, animation.duration > 0 else {
            removeAnimation(forKey: keyPath)
            setValue(newValue, forKeyPath: keyPath)
            return
        }
        let isAnimating = self.animation(forKey: keyPath) != nil
        let fromValue = isAnimating
            ? (presentation()?.value(forKeyPath: keyPath) ?? value(forKeyPath: keyPath))
            : value(forKeyPath: keyPath)
        setValue(newValue, forKeyPath: keyPath)
        let basic = CABasicAnimation(keyPath: keyPath)
        basic.fromValue = fromValue
        basic.toValue = newValue
        basic.duration = animation.duration
        basic.timingFunction = animation.timingFunction
        if animation.delay > 0 {
            basic.beginTime = CACurrentMediaTime() + animation.delay
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
