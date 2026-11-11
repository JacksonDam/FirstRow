@_exported import CoreGraphics
@_exported import CoreImage
import Foundation

public struct CALayerContentsGravity: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let center = CALayerContentsGravity(rawValue: "center")
    public static let top = CALayerContentsGravity(rawValue: "top")
    public static let bottom = CALayerContentsGravity(rawValue: "bottom")
    public static let left = CALayerContentsGravity(rawValue: "left")
    public static let right = CALayerContentsGravity(rawValue: "right")
    public static let topLeft = CALayerContentsGravity(rawValue: "topLeft")
    public static let topRight = CALayerContentsGravity(rawValue: "topRight")
    public static let bottomLeft = CALayerContentsGravity(rawValue: "bottomLeft")
    public static let bottomRight = CALayerContentsGravity(rawValue: "bottomRight")
    public static let resize = CALayerContentsGravity(rawValue: "resize")
    public static let resizeAspect = CALayerContentsGravity(rawValue: "resizeAspect")
    public static let resizeAspectFill = CALayerContentsGravity(rawValue: "resizeAspectFill")
}

public struct CALayerContentsFilter: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let nearest = CALayerContentsFilter(rawValue: "nearest")
    public static let linear = CALayerContentsFilter(rawValue: "linear")
    public static let trilinear = CALayerContentsFilter(rawValue: "trilinear")
}

public struct CALayerCornerCurve: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let circular = CALayerCornerCurve(rawValue: "circular")
    public static let continuous = CALayerCornerCurve(rawValue: "continuous")
}

public protocol CALayerDelegate: AnyObject {
    func display(_ layer: CALayer)
    func draw(_ layer: CALayer, in ctx: CGContext)
    func layoutSublayers(of layer: CALayer)
    func action(for layer: CALayer, forKey event: String) -> CAAction?
}

public extension CALayerDelegate {
    func display(_: CALayer) {}
    func draw(_: CALayer, in _: CGContext) {}
    func layoutSublayers(of _: CALayer) {}
    func action(for _: CALayer, forKey _: String) -> CAAction? { nil }
}

/// A Core Animation layer: a model whose changes the compositor draws each frame.
open class CALayer: NSObject, CAMediaTiming {
    var modelState = LayerState()
    private(set) var animationList: [(key: String, animation: CAAnimation)] = []
    public private(set) weak var superlayer: CALayer?
    private var sublayerList: [CALayer] = []
    /// Set once the layer has been drawn, so later changes may animate implicitly.
    var hasBeenRendered = false
    /// The model as of the last frame, kept while checking for jumps (FIRSTROW_DEBUG_SNAPS).
    var lastDrawnModel: LayerState?
    private var needsLayoutFlag = false
    private var anonymousAnimationCount = 0

    public var name: String?
    public weak var delegate: CALayerDelegate?
    public var actions: [String: CAAction]?
    public var style: [AnyHashable: Any]?
    public var needsDisplayOnBoundsChange = false
    public var drawsAsynchronously = false
    public var shouldRasterize = false
    public var rasterizationScale: CGFloat = 1
    public var allowsGroupOpacity = true
    public var allowsEdgeAntialiasing = true
    public var isOpaque = false
    public var cornerCurve: CALayerCornerCurve = .circular

    public var mask: CALayer? {
        didSet {
            oldValue?.maskOwner = nil
            mask?.removeFromSuperlayer()
            mask?.maskOwner = self
            markChanged()
        }
    }

    weak var maskOwner: CALayer?

    // MARK: Media timing

    public var beginTime: CFTimeInterval = 0 { didSet { markChanged() } }
    public var duration: CFTimeInterval = 0
    public var speed: Float = 1 { didSet { markChanged() } }
    public var timeOffset: CFTimeInterval = 0 { didSet { markChanged() } }
    public var repeatCount: Float = 0
    public var repeatDuration: CFTimeInterval = 0
    public var autoreverses = false
    public var fillMode: CAMediaTimingFillMode = .removed

    override public init() {
        super.init()
    }

    public init(layer: Any) {
        super.init()
        if let other = layer as? CALayer {
            modelState = other.modelState
            name = other.name
            delegate = other.delegate
            actions = other.actions
            beginTime = other.beginTime
            speed = other.speed
            timeOffset = other.timeOffset
        }
    }

    public required init?(coder _: NSCoder) {
        super.init()
    }

    // MARK: Geometry

    public var bounds: CGRect {
        get { modelState.bounds }
        // Stored with a positive size, as Core Animation does.
        set {
            let rect = newValue.standardized
            change("bounds", modelState.bounds, rect) { $0.bounds = rect }
        }
    }

    public var position: CGPoint {
        get { modelState.position }
        set { change("position", modelState.position, newValue) { $0.position = newValue } }
    }

    public var zPosition: CGFloat {
        get { modelState.zPosition }
        set { change("zPosition", modelState.zPosition, newValue) { $0.zPosition = newValue } }
    }

    public var anchorPoint: CGPoint {
        get { modelState.anchorPoint }
        set { change("anchorPoint", modelState.anchorPoint, newValue) { $0.anchorPoint = newValue } }
    }

    public var anchorPointZ: CGFloat {
        get { modelState.anchorPointZ }
        set { change("anchorPointZ", modelState.anchorPointZ, newValue) { $0.anchorPointZ = newValue } }
    }

    public var transform: CATransform3D {
        get { modelState.transform }
        set { change("transform", modelState.transform, newValue) { $0.transform = newValue } }
    }

    public var sublayerTransform: CATransform3D {
        get { modelState.sublayerTransform }
        set { change("sublayerTransform", modelState.sublayerTransform, newValue) { $0.sublayerTransform = newValue } }
    }

    public func affineTransform() -> CGAffineTransform { CATransform3DGetAffineTransform(transform) }
    public func setAffineTransform(_ m: CGAffineTransform) { transform = CATransform3DMakeAffineTransform(m) }

    /// The frame in the superlayer's space, worked out from bounds, position, anchor and transform.
    public var frame: CGRect {
        get {
            let b = modelState.bounds
            let origin = CGPoint(x: modelState.position.x - b.width * modelState.anchorPoint.x, y: modelState.position.y - b.height * modelState.anchorPoint.y)
            if CATransform3DIsIdentity(modelState.transform) {
                return CGRect(origin: origin, size: b.size)
            }
            let t = layerToSuperTransform(modelState)
            let corners = [(b.minX, b.minY), (b.maxX, b.minY), (b.minX, b.maxY), (b.maxX, b.maxY)].map { corner -> CGPoint in
                let p = t.apply(x: corner.0, y: corner.1)
                return CGPoint(x: p.0 / (p.3 == 0 ? 1 : p.3), y: p.1 / (p.3 == 0 ? 1 : p.3))
            }
            let xs = corners.map(\.x)
            let ys = corners.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        set {
            let size = newValue.size
            let newBounds = CGRect(origin: modelState.bounds.origin, size: size)
            bounds = newBounds
            position = CGPoint(x: newValue.minX + size.width * modelState.anchorPoint.x, y: newValue.minY + size.height * modelState.anchorPoint.y)
        }
    }

    // MARK: Appearance

    public var isHidden: Bool {
        get { modelState.isHidden }
        set { change("hidden", modelState.isHidden, newValue, animatable: false) { $0.isHidden = newValue } }
    }

    public var opacity: Float {
        get { modelState.opacity }
        set { change("opacity", modelState.opacity, newValue) { $0.opacity = newValue } }
    }

    public var masksToBounds: Bool {
        get { modelState.masksToBounds }
        set { change("masksToBounds", modelState.masksToBounds, newValue, animatable: false) { $0.masksToBounds = newValue } }
    }

    public var isDoubleSided: Bool {
        get { modelState.isDoubleSided }
        set { change("doubleSided", modelState.isDoubleSided, newValue, animatable: false) { $0.isDoubleSided = newValue } }
    }

    public var isGeometryFlipped: Bool {
        get { modelState.isGeometryFlipped }
        set { change("geometryFlipped", modelState.isGeometryFlipped, newValue, animatable: false) { $0.isGeometryFlipped = newValue } }
    }

    public func contentsAreFlipped() -> Bool {
        var flipped = false
        var ancestor = superlayer
        while let layer = ancestor {
            if layer.isGeometryFlipped { flipped.toggle() }
            ancestor = layer.superlayer
        }
        return flipped
    }

    public var backgroundColor: CGColor? {
        get { modelState.backgroundColor }
        set { change("backgroundColor", modelState.backgroundColor, newValue) { $0.backgroundColor = newValue } }
    }

    public var cornerRadius: CGFloat {
        get { modelState.cornerRadius }
        set { change("cornerRadius", modelState.cornerRadius, newValue) { $0.cornerRadius = newValue } }
    }

    public var borderWidth: CGFloat {
        get { modelState.borderWidth }
        set { change("borderWidth", modelState.borderWidth, newValue) { $0.borderWidth = newValue } }
    }

    public var borderColor: CGColor? {
        get { modelState.borderColor }
        set { change("borderColor", modelState.borderColor, newValue) { $0.borderColor = newValue } }
    }

    public var contents: Any? {
        get { modelState.contents }
        set { change("contents", modelState.contents as AnyObject?, newValue as AnyObject?) { $0.contents = newValue } }
    }

    public var contentsRect: CGRect {
        get { modelState.contentsRect }
        set { change("contentsRect", modelState.contentsRect, newValue) { $0.contentsRect = newValue } }
    }

    public var contentsCenter: CGRect {
        get { modelState.contentsCenter }
        set { change("contentsCenter", modelState.contentsCenter, newValue) { $0.contentsCenter = newValue } }
    }

    public var contentsScale: CGFloat {
        get { modelState.contentsScale }
        set { change("contentsScale", modelState.contentsScale, newValue, animatable: false) { $0.contentsScale = newValue } }
    }

    public var contentsGravity: CALayerContentsGravity {
        get { modelState.contentsGravity }
        set { change("contentsGravity", modelState.contentsGravity, newValue, animatable: false) { $0.contentsGravity = newValue } }
    }

    public var minificationFilter: CALayerContentsFilter {
        get { modelState.minificationFilter }
        set { change("minificationFilter", modelState.minificationFilter, newValue, animatable: false) { $0.minificationFilter = newValue } }
    }

    public var magnificationFilter: CALayerContentsFilter {
        get { modelState.magnificationFilter }
        set { change("magnificationFilter", modelState.magnificationFilter, newValue, animatable: false) { $0.magnificationFilter = newValue } }
    }

    public var minificationFilterBias: Float = 0

    public var shadowColor: CGColor? {
        get { modelState.shadowColor }
        set { change("shadowColor", modelState.shadowColor, newValue) { $0.shadowColor = newValue } }
    }

    public var shadowOpacity: Float {
        get { modelState.shadowOpacity }
        set { change("shadowOpacity", modelState.shadowOpacity, newValue) { $0.shadowOpacity = newValue } }
    }

    public var shadowOffset: CGSize {
        get { modelState.shadowOffset }
        set { change("shadowOffset", modelState.shadowOffset, newValue) { $0.shadowOffset = newValue } }
    }

    public var shadowRadius: CGFloat {
        get { modelState.shadowRadius }
        set { change("shadowRadius", modelState.shadowRadius, newValue) { $0.shadowRadius = newValue } }
    }

    public var shadowPath: CGPath? {
        get { modelState.shadowPath }
        set { change("shadowPath", modelState.shadowPath, newValue, animatable: false) { $0.shadowPath = newValue } }
    }

    public var filters: [Any]? {
        get { modelState.filters }
        set {
            modelState.filters = newValue
            markChanged()
        }
    }

    public var backgroundFilters: [Any]?
    public var compositingFilter: Any?

    // MARK: Sublayers

    public var sublayers: [CALayer]? {
        get { sublayerList.isEmpty ? nil : sublayerList }
        set {
            for layer in sublayerList { layer.superlayer = nil }
            sublayerList = []
            for layer in newValue ?? [] { addSublayer(layer) }
            markChanged()
        }
    }

    var children: [CALayer] { sublayerList }

    public func addSublayer(_ layer: CALayer) {
        insertSublayer(layer, at: UInt32(sublayerList.count))
    }

    public func insertSublayer(_ layer: CALayer, at index: UInt32) {
        if layer === self { return }
        if layer.superlayer === self, let current = sublayerList.firstIndex(where: { $0 === layer }) {
            sublayerList.remove(at: current)
        } else {
            layer.removeFromSuperlayer()
        }
        let position = min(Int(index), sublayerList.count)
        sublayerList.insert(layer, at: position)
        layer.superlayer = self
        markChanged()
    }

    public func insertSublayer(_ layer: CALayer, below sibling: CALayer?) {
        guard let sibling, let index = sublayerList.firstIndex(where: { $0 === sibling }) else {
            insertSublayer(layer, at: 0)
            return
        }
        if layer.superlayer === self, let current = sublayerList.firstIndex(where: { $0 === layer }), current < index {
            insertSublayer(layer, at: UInt32(index - 1))
        } else {
            insertSublayer(layer, at: UInt32(index))
        }
    }

    public func insertSublayer(_ layer: CALayer, above sibling: CALayer?) {
        guard let sibling, let index = sublayerList.firstIndex(where: { $0 === sibling }) else {
            addSublayer(layer)
            return
        }
        if layer.superlayer === self, let current = sublayerList.firstIndex(where: { $0 === layer }), current <= index {
            insertSublayer(layer, at: UInt32(index))
        } else {
            insertSublayer(layer, at: UInt32(index + 1))
        }
    }

    public func replaceSublayer(_ oldLayer: CALayer, with newLayer: CALayer) {
        guard let index = sublayerList.firstIndex(where: { $0 === oldLayer }) else { return }
        oldLayer.removeFromSuperlayer()
        insertSublayer(newLayer, at: UInt32(index))
    }

    public func removeFromSuperlayer() {
        if let owner = maskOwner, owner.mask === self {
            owner.mask = nil
            return
        }
        guard let parent = superlayer else { return }
        parent.sublayerList.removeAll { $0 === self }
        superlayer = nil
        parent.markChanged()
    }

    // MARK: Animations

    public func add(_ anim: CAAnimation, forKey key: String?) {
        let copy = anim.copy() as! CAAnimation
        let snapCheck = SnapCheck(layer: self, animation: anim)
        defer { snapCheck?.finish(added: copy) }
        let name: String
        if let key {
            name = key
            removeAnimation(forKey: key, notify: true)
        } else {
            anonymousAnimationCount += 1
            name = "_anonymous\(anonymousAnimationCount)"
        }
        if let property = copy as? CAPropertyAnimation, let keyPath = property.keyPath, let animatable = AnimatableKey(keyPath) {
            // A nil endpoint starts from what was on screen when the animation was added.
            copy.capturedFrom = pendingImplicitFrom.removeValue(forKey: keyPath) ?? animatable.get(presentationState(at: CACurrentMediaTime(), excluding: name))
        }
        if copy.beginTime == 0 {
            copy.beginTime = convertTime(CACurrentMediaTime(), from: nil)
        }
        let record = CATransaction.currentRecord
        record.pendingAnimations += 1
        copy.transaction = record
        animationList.append((name, copy))
        markChanged()
    }

    public func animation(forKey key: String) -> CAAnimation? {
        animationList.last { $0.key == key }?.animation
    }

    public func animationKeys() -> [String]? {
        let keys = animationList.map(\.key).filter { !$0.hasPrefix("_anonymous") }
        return keys.isEmpty ? nil : keys
    }

    public func removeAnimation(forKey key: String) {
        removeAnimation(forKey: key, notify: true)
    }

    private func removeAnimation(forKey key: String, notify: Bool) {
        guard let index = animationList.firstIndex(where: { $0.key == key }) else { return }
        let removed = animationList.remove(at: index).animation
        if notify { ended(removed, finished: false) }
        markChanged()
    }

    public func removeAllAnimations() {
        let removed = animationList
        animationList.removeAll()
        for entry in removed { ended(entry.animation, finished: false) }
        markChanged()
    }

    private func ended(_ animation: CAAnimation, finished: Bool) {
        animation.delegate?.animationDidStop(animation, finished: finished)
        animation.transaction?.animationEnded()
        animation.transaction = nil
    }

    var hasAnimations: Bool { !animationList.isEmpty }

    /// Whether the layer may be drawn out of its place among its siblings: a z position, or an
    /// animation that could give it one.
    var mayHaveZPosition: Bool {
        if modelState.zPosition != 0 { return true }
        guard !animationList.isEmpty else { return false }
        return animationList.contains { entry in
            guard let property = entry.animation as? CAPropertyAnimation else { return true }
            return property.keyPath == "zPosition"
        }
    }

    /// The frame the compositor last drew this layer in (it skips hidden and clear ones).
    var lastDrawnFrame = 0

    /// Removes animations that finished by `time`, telling their delegates. The compositor
    /// calls this after each frame.
    func retireAnimations(at time: CFTimeInterval) {
        guard !animationList.isEmpty else { return }
        let local = convertTime(time, from: nil)
        var finished: [CAAnimation] = []
        animationList.removeAll { entry in
            let phase = entry.animation.phase(at: local)
            if !entry.animation.started, phase.active || phase.finished {
                entry.animation.started = true
                entry.animation.delegate?.animationDidStart(entry.animation)
            }
            if phase.finished, entry.animation.isRemovedOnCompletion {
                finished.append(entry.animation)
                return true
            }
            return false
        }
        for animation in finished { ended(animation, finished: true) }
    }

    /// True while some animation could still change what is drawn. An animation that never
    /// ends only counts on a layer that is being drawn: one on a hidden layer (a caret blinking
    /// in a text field that isn't up) would otherwise have every frame drawn for ever.
    func isAnimating(at time: CFTimeInterval, isDrawn: Bool) -> Bool {
        let local = convertTime(time, from: nil)
        return animationList.contains { entry in
            if !isDrawn, entry.animation.neverEnds { return false }
            let phase = entry.animation.phase(at: local)
            return !phase.finished || entry.animation.isRemovedOnCompletion
        }
    }

    /// The layer's state with its animations applied at `time` (host time).
    func presentationState(at time: CFTimeInterval, excluding excluded: String? = nil, model: LayerState? = nil,
                           animations: [(key: String, animation: CAAnimation)]? = nil) -> LayerState
    {
        let model = model ?? modelState
        let list = animations ?? animationList
        guard !list.isEmpty else { return model }
        let local = convertTime(time, from: nil)
        var state = model
        for entry in list where entry.key != excluded {
            _ = entry.animation.apply(to: &state, at: local, base: model)
        }
        return state
    }

    public func presentation() -> CALayer? {
        // With nothing animating it, what's on screen is what the layer is set to: it answers
        // for itself. (A copy for every question was a quarter of First Row's pass.)
        if animationList.isEmpty { return self }
        let copy = CALayer(layer: self)
        copy.modelState = presentationState(at: CACurrentMediaTime())
        return copy
    }

    public func model() -> CALayer { self }

    // MARK: Time

    /// Converts host time (or a time in `layer`'s space) into this layer's local time.
    public func convertTime(_ t: CFTimeInterval, from layer: CALayer?) -> CFTimeInterval {
        localTime(fromGlobal: layer.map { $0.globalTime(fromLocal: t) } ?? t)
    }

    /// Each layer's clock runs on its superlayer's, from the root down.
    private func localTime(fromGlobal global: CFTimeInterval) -> CFTimeInterval {
        let parentTime = (superlayer ?? maskOwner)?.localTime(fromGlobal: global) ?? global
        return (parentTime - beginTime) * Double(speed) + timeOffset
    }

    public func convertTime(_ t: CFTimeInterval, to layer: CALayer?) -> CFTimeInterval {
        let global = globalTime(fromLocal: t)
        return layer?.convertTime(global, from: nil) ?? global
    }

    private func globalTime(fromLocal t: CFTimeInterval) -> CFTimeInterval {
        var time = t
        var node: CALayer? = self
        while let current = node {
            let speed = Double(current.speed)
            time = speed == 0 ? current.beginTime : (time - current.timeOffset) / speed + current.beginTime
            node = current.superlayer ?? current.maskOwner
        }
        return time
    }

    // MARK: Coordinates

    public func convert(_ point: CGPoint, to layer: CALayer?) -> CGPoint {
        let toRoot = transformToRoot()
        let p = toRoot.apply(x: point.x, y: point.y)
        let rootPoint = CGPoint(x: p.0 / p.3, y: p.1 / p.3)
        guard let layer else { return rootPoint }
        let fromRoot = CATransform3DInvert(layer.transformToRoot())
        let q = fromRoot.apply(x: rootPoint.x, y: rootPoint.y)
        return CGPoint(x: q.0 / q.3, y: q.1 / q.3)
    }

    public func convert(_ point: CGPoint, from layer: CALayer?) -> CGPoint {
        guard let layer else {
            let fromRoot = CATransform3DInvert(transformToRoot())
            let q = fromRoot.apply(x: point.x, y: point.y)
            return CGPoint(x: q.0 / q.3, y: q.1 / q.3)
        }
        return layer.convert(point, to: self)
    }

    public func convert(_ rect: CGRect, to layer: CALayer?) -> CGRect {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].map { convert($0, to: layer) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    public func convert(_ rect: CGRect, from layer: CALayer?) -> CGRect {
        guard let layer else { return convert(rect, to: nil) }
        return layer.convert(rect, to: self)
    }

    /// Maps this layer's bounds space to the root layer's, flattening at each level.
    func transformToRoot() -> CATransform3D {
        var t = CATransform3DIdentity
        var node: CALayer = self
        while let parent = node.superlayer {
            t = t.then(layerToSuperTransform(node.modelState)).then(sublayerSpaceTransform(parent.modelState)).flattened
            node = parent
        }
        return t
    }

    public func contains(_ point: CGPoint) -> Bool { bounds.contains(point) }

    public func hitTest(_ point: CGPoint) -> CALayer? {
        guard !isHidden, opacity > 0 else { return nil }
        let local = convert(point, from: superlayer)
        guard contains(local) || !masksToBounds else { return nil }
        for layer in sublayerList.reversed() {
            if let hit = layer.hitTest(local) { return hit }
        }
        return contains(local) ? self : nil
    }

    // MARK: Actions

    /// Values recorded just before an implicit change, so its animation starts from them.
    private var pendingImplicitFrom: [String: AnimValue] = [:]

    open func action(forKey event: String) -> CAAction? {
        if let delegate {
            if let action = delegate.action(for: self, forKey: event) {
                return action is NSNull ? nil : action
            }
        }
        if let action = actions?[event] {
            return action is NSNull ? nil : action
        }
        return type(of: self).defaultAction(forKey: event)
    }

    open class func defaultAction(forKey event: String) -> CAAction? {
        guard AnimatableKey(event) != nil, event != "contents", event != "hidden" else { return nil }
        let animation = CABasicAnimation(keyPath: event)
        animation.duration = CATransaction.animationDuration()
        animation.timingFunction = CATransaction.animationTimingFunction() ?? CAMediaTimingFunction(name: .default)
        return animation
    }

    open class func defaultValue(forKey _: String) -> Any? { nil }

    open class func needsDisplay(forKey _: String) -> Bool { false }

    func change<T: Equatable>(_ key: String, _ old: T, _ new: T, animatable: Bool = true, apply: (inout LayerState) -> Void) {
        let changed = old != new
        if changed, animatable, hasBeenRendered, !CATransaction.disableActions(), superlayer != nil || maskOwner != nil,
           let animatableKey = AnimatableKey(key)
        {
            let before = animatableKey.get(presentationState(at: CACurrentMediaTime()))
            apply(&modelState)
            if let action = action(forKey: key) {
                pendingImplicitFrom[key] = before
                action.run(forKey: key, object: self, arguments: nil)
                pendingImplicitFrom.removeValue(forKey: key)
            }
        } else {
            apply(&modelState)
        }
        if changed {
            if key == "bounds", needsDisplayOnBoundsChange { setNeedsDisplay() }
            markChanged()
        }
    }

    func change(_ key: String, _ old: AnyObject?, _ new: AnyObject?, apply: (inout LayerState) -> Void) {
        apply(&modelState)
        if old !== new { markChanged() }
        _ = key
    }

    func change(_ key: String, _ old: CGColor?, _ new: CGColor?, apply: (inout LayerState) -> Void) {
        let same = CGColorEqualToColor(old, new)
        if !same, hasBeenRendered, !CATransaction.disableActions(), superlayer != nil, let animatableKey = AnimatableKey(key) {
            let before = animatableKey.get(presentationState(at: CACurrentMediaTime()))
            apply(&modelState)
            if let action = action(forKey: key) {
                pendingImplicitFrom[key] = before
                action.run(forKey: key, object: self, arguments: nil)
                pendingImplicitFrom.removeValue(forKey: key)
            }
        } else {
            apply(&modelState)
        }
        if !same { markChanged() }
    }

    func change(_ key: String, _ old: CGPath?, _ new: CGPath?, animatable _: Bool, apply: (inout LayerState) -> Void) {
        apply(&modelState)
        // The same shape in a new path object changes nothing on screen.
        if old !== new, old != new { markChanged() }
        _ = key
    }

    func markChanged() {
        CATransaction.onChange?()
    }

    // MARK: Display and layout

    public func setNeedsDisplay() { markChanged() }
    public func setNeedsDisplay(_: CGRect) { markChanged() }
    public func displayIfNeeded() {}
    public func needsDisplay() -> Bool { false }
    open func display() { delegate?.display(self) }
    open func draw(in ctx: CGContext) { delegate?.draw(self, in: ctx) }
    public func render(in _: CGContext) {}

    public func setNeedsLayout() {
        needsLayoutFlag = true
        markChanged()
    }

    public func needsLayout() -> Bool { needsLayoutFlag }

    public func layoutIfNeeded() {
        if needsLayoutFlag {
            needsLayoutFlag = false
            layoutSublayers()
        }
        for layer in sublayerList { layer.layoutIfNeeded() }
    }

    open func layoutSublayers() { delegate?.layoutSublayers(of: self) }
    open func preferredFrameSize() -> CGSize { bounds.size }

    // MARK: Key-value coding

    public func value(forKey key: String) -> Any? {
        value(forKeyPath: key)
    }

    public func setValue(_ value: Any?, forKey key: String) {
        setValue(value, forKeyPath: key)
    }

    public func value(forKeyPath keyPath: String) -> Any? {
        if let key = AnimatableKey(keyPath) {
            return key.get(modelState).boxed
        }
        switch keyPath {
        case "name": return name
        case "masksToBounds": return NSNumber(value: masksToBounds)
        default: return nil
        }
    }

    public func setValue(_ value: Any?, forKeyPath keyPath: String) {
        let parts = keyPath.split(separator: ".").map(String.init)
        if parts.count == 3, parts[0] == "filters" {
            for case let filter as CIFilter in filters ?? [] where filter.name == parts[1] {
                filter.setValue(value, forKey: parts[2])
            }
            modelState.filterValues.removeValue(forKey: parts[1] + "." + parts[2])
            markChanged()
            return
        }
        guard let key = AnimatableKey(keyPath), let value, let converted = key.kind.convert(value) else {
            if keyPath == "contents" { contents = value }
            return
        }
        switch keyPath {
        case "opacity": if case let .scalar(v) = converted { opacity = Float(v) }
        case "position": if case let .point(p) = converted { position = p }
        case "bounds": if case let .rect(r) = converted { bounds = r }
        case "transform": if case let .transform(t) = converted { transform = t }
        case "zPosition": if case let .scalar(v) = converted { zPosition = CGFloat(v) }
        case "backgroundColor": if case let .color(c) = converted { backgroundColor = c }
        default:
            key.set(&modelState, converted)
            markChanged()
        }
    }
}

/// From a layer's bounds space to its superlayer's sublayer space.
func layerToSuperTransform(_ s: LayerState) -> CATransform3D {
    let anchorX = s.bounds.minX + s.bounds.width * s.anchorPoint.x
    let anchorY = s.bounds.minY + s.bounds.height * s.anchorPoint.y
    if s.transform.isIdentity {
        // Most layers: one move, from the anchor to the position.
        return CATransform3DMakeTranslation(s.position.x - anchorX, s.position.y - anchorY, s.zPosition - s.anchorPointZ)
    }
    let t = CATransform3DMakeTranslation(-anchorX, -anchorY, -s.anchorPointZ).then(s.transform)
    return t.then(CATransform3DMakeTranslation(s.position.x, s.position.y, s.zPosition))
}

/// True when a layer's sublayers sit in its bounds space as they are (no flip, no transform).
func hasPlainSublayerSpace(_ s: LayerState) -> Bool {
    !s.isGeometryFlipped && s.sublayerTransform.isIdentity
}

/// From a layer's sublayer space to its own bounds space: geometry flip, then its
/// sublayer transform about its anchor.
func sublayerSpaceTransform(_ s: LayerState) -> CATransform3D {
    var t = CATransform3DIdentity
    if s.isGeometryFlipped {
        var flip = CATransform3DMakeScale(1, -1, 1)
        flip.m42 = s.bounds.minY + s.bounds.maxY
        t = flip
    }
    if !CATransform3DIsIdentity(s.sublayerTransform) {
        let anchorX = s.bounds.minX + s.bounds.width * s.anchorPoint.x
        let anchorY = s.bounds.minY + s.bounds.height * s.anchorPoint.y
        t = t.then(CATransform3DMakeTranslation(-anchorX, -anchorY, -s.anchorPointZ))
            .then(s.sublayerTransform)
            .then(CATransform3DMakeTranslation(anchorX, anchorY, s.anchorPointZ))
    }
    return t
}

/// With FIRSTROW_DEBUG_SNAPS=1, reports animations whose first frame doesn't continue from
/// what was on screen, which shows up as a jump.
struct SnapCheck {
    static let enabled = ProcessInfo.processInfo.environment["FIRSTROW_DEBUG_SNAPS"] == "1"

    let layer: CALayer
    let keyPath: String
    let key: AnimatableKey
    /// The last frame's model and the animations running then: the model may already hold
    /// the value being animated to.
    let model: LayerState
    let animations: [(key: String, animation: CAAnimation)]

    init?(layer: CALayer, animation: CAAnimation) {
        guard Self.enabled, let property = animation as? CAPropertyAnimation, !property.isAdditive,
              let keyPath = property.keyPath, let key = AnimatableKey(keyPath) else { return nil }
        self.layer = layer
        self.keyPath = keyPath
        self.key = key
        model = layer.lastDrawnModel ?? layer.modelState
        animations = layer.animationList
    }

    /// Compares old and new where the new animation begins, so a change of speed isn't
    /// mistaken for a jump.
    func finish(added: CAAnimation) {
        let time = max(layer.convertTime(added.beginTime, to: nil), CACurrentMediaTime() - 1) + 0.0001
        let before = key.get(layer.presentationState(at: time, model: model, animations: animations))
        let after = key.get(layer.presentationState(at: time))
        let jump = Self.distance(before, after)
        guard jump > 0.5 else { return }
        let label = layer.name ?? "\(type(of: layer))@\(String(UInt(bitPattern: ObjectIdentifier(layer).hashValue), radix: 16))"
        FileHandle.standardError.write(Data(String(format: "[snap] %.3f %@ %@ jumped %.2f: %@ -> %@\n", time, label, keyPath, jump, "\(before)", "\(after)").utf8))
        if ProcessInfo.processInfo.environment["FIRSTROW_DEBUG_SNAPS_STACK"] == "1" {
            let frames = Thread.callStackSymbols.dropFirst(2).prefix(10).joined(separator: "\n    ")
            FileHandle.standardError.write(Data("    \(frames)\n".utf8))
        }
    }

    static func distance(_ a: AnimValue, _ b: AnimValue) -> Double {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)): return abs(x - y) * (abs(x) <= 1 && abs(y) <= 1 ? 100 : 1)
        case let (.point(p), .point(q)): return Double(max(abs(p.x - q.x), abs(p.y - q.y)))
        case let (.size(p), .size(q)): return Double(max(abs(p.width - q.width), abs(p.height - q.height)))
        case let (.rect(p), .rect(q)):
            // Boxes with negative sizes draw the same as their normalized form.
            let a = p.standardized, b = q.standardized
            return Double([a.minX - b.minX, a.minY - b.minY, a.width - b.width, a.height - b.height].map(abs).max() ?? 0)
        default: return 0
        }
    }
}
