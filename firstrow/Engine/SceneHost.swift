import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

extension MainActor {
    /// Runs main-actor work immediately from a callback the system makes on the main thread.
    static func runOnMainThread(_ body: @MainActor () -> Void) {
        precondition(Thread.isMainThread, "Expected to be on the main thread")
        typealias Unisolated = () -> Void
        withoutActuallyEscaping(body) { body in
            unsafeBitCast(body, to: Unisolated.self)()
        }
    }

    /// Like `runOnMainThread`, for callbacks that need to escape.
    static func assumeIsolatedIfPossible(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            runOnMainThread(body)
        } else {
            DispatchQueue.main.async { runOnMainThread(body) }
        }
    }
}

#if FIRSTROW_PORTABLE
    /// Calls `body` once per frame, just before layer changes are committed and drawn.
    @MainActor
    final class RunLoopFlushObserver {
        private var token: Int?

        init(_ body: @escaping @MainActor () -> Void) {
            token = FrameObservers.add(body)
        }

        func invalidate() {
            if let token { FrameObservers.remove(token) }
            token = nil
        }
    }
#else
/// Calls `body` once per run loop pass, just before Core Animation commits what was drawn.
@MainActor
final class RunLoopFlushObserver {
    private var observer: CFRunLoopObserver?

    init(_ body: @escaping @MainActor () -> Void) {
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        // Core Animation commits at order 2000000; run just before it.
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 1_999_000) { _, _ in
            MainActor.runOnMainThread(body)
        }
        if let observer {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    func invalidate() {
        if let observer {
            CFRunLoopObserverInvalidate(observer)
        }
        observer = nil
    }
}
#endif

#if os(macOS)
    /// Keeps a ProMotion screen at its fastest rate while something in First Row moves. Core
    /// Animation plays animations at whatever rate the screen is running, and macOS only raises a
    /// ProMotion screen above 60 Hz when something asks (a ProMotion MacBook ran First Row at 30-60
    /// fps unless the menu bar's own animation happened to lift it). A display link asking for the
    /// top rate does ask. It's paused whenever nothing moves, so the screen can slow down again.
    @MainActor
    final class ProMotionPacer: NSObject {
        static let shared = ProMotionPacer()

        /// An animation that never ends: it keeps the rate up while its layer is on screen.
        private struct Endless {
            weak var layer: CALayer?
            let key: String
            let animation: CAAnimation
        }

        private weak var view: NSView?
        /// The display link (a `CADisplayLink`, which the Mac has from macOS 14).
        private var link: AnyObject?
        /// When the last animation with an end finishes, on `CACurrentMediaTime()`'s clock.
        private var busyUntil: CFTimeInterval = 0
        private var endless: [Endless] = []

        /// Follows `view`'s screen (the scene's view, once it is in a window).
        func attach(to view: NSView) {
            guard self.view !== view else { return }
            self.view = view
            if #available(macOS 14.0, *) {
                (link as? CADisplayLink)?.invalidate()
                let link = view.displayLink(target: self, selector: #selector(tick(_:)))
                link.isPaused = true
                link.add(to: .main, forMode: .common)
                self.link = link
            }
        }

        /// Keeps the rate up for the next `seconds`.
        func hold(for seconds: Double) {
            busyUntil = max(busyUntil, CACurrentMediaTime() + seconds)
            resumeIfNeeded()
        }

        /// Keeps the rate up while the animation just added to `layer` for `key` plays.
        func didAdd(forKey key: String, to layer: CALayer) {
            guard let animation = layer.animation(forKey: key), animation.speed > 0 else { return }
            let once = (animation.duration > 0 ? animation.duration : 0.25) * (animation.autoreverses ? 2 : 1)
            let length = animation.repeatDuration > 0 ? animation.repeatDuration : once * Double(max(1, animation.repeatCount))
            guard length.isFinite, length < 3600 else {
                endless.removeAll { $0.layer == nil || ($0.layer === layer && $0.key == key) }
                endless.append(Endless(layer: layer, key: key, animation: animation))
                resumeIfNeeded()
                return
            }
            // A begin time of 0 means "when committed", which is about now.
            let begin = animation.beginTime > 0 ? layer.convertTime(animation.beginTime, to: nil) : CACurrentMediaTime()
            busyUntil = max(busyUntil, begin + length / Double(animation.speed))
            resumeIfNeeded()
        }

        /// Starts the link if anything is moving (an endless animation may be back on screen).
        func resumeIfNeeded() {
            guard #available(macOS 14.0, *), let link = link as? CADisplayLink, link.isPaused, isNeeded() else { return }
            let fastest = Float(max(60, view?.window?.screen?.maximumFramesPerSecond ?? 60))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, fastest), maximum: fastest, preferred: fastest)
            link.isPaused = false
        }

        @available(macOS 14.0, *)
        @objc private func tick(_ link: CADisplayLink) {
            if !isNeeded() {
                link.isPaused = true
            }
        }

        private func isNeeded() -> Bool {
            guard let view, let window = view.window, window.occlusionState.contains(.visible) else { return false }
            // Low Power Mode keeps the screen at 60 Hz anyway.
            if #available(macOS 12.0, *), ProcessInfo.processInfo.isLowPowerModeEnabled {
                return false
            }
            if CACurrentMediaTime() < busyUntil {
                return true
            }
            endless.removeAll { entry in
                guard let layer = entry.layer else { return true }
                return layer.animation(forKey: entry.key) !== entry.animation
            }
            return endless.contains { isShowing($0.layer, in: view.layer) }
        }

        private func isShowing(_ layer: CALayer?, in root: CALayer?) -> Bool {
            var current = layer
            while let shown = current {
                if shown === root { return true }
                if shown.isHidden || shown.opacity <= 0 { return false }
                current = shown.superlayer
            }
            return false
        }
    }

    /// The view First Row draws into: it hosts a layer tree (origin top left) and passes on
    /// key presses.
    final class SceneHostView: NSView {
        /// Fills the view; its geometry is flipped so the scene lays out from the top left.
        let sceneLayer = SceneLayer()
        var onLayout: ((CGSize, CGFloat) -> Void)?
        var onKeyDown: ((NSEvent) -> Void)?
        var onKeyUp: ((NSEvent) -> Void)?
        /// Mouse and trackpad events, in points from the top left.
        var onPointer: ((PointerEvent) -> Void)?
        private var lastLayout: (CGSize, CGFloat)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let host = CALayer()
            host.backgroundColor = CGColor(gray: 0, alpha: 1)
            host.masksToBounds = true
            layer = host
            wantsLayer = true
            layerContentsRedrawPolicy = .never
            sceneLayer.isGeometryFlipped = true
            host.addSublayer(sceneLayer)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool { true }
        override var isOpaque: Bool { true }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            relayout()
        }

        override func layout() {
            super.layout()
            relayout()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                ProMotionPacer.shared.attach(to: self)
            }
            relayout()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            relayout()
        }

        /// Lays out again now, whether or not the size changed (the stance may have).
        func layoutNow() {
            lastLayout = nil
            relayout()
        }

        private func relayout() {
            let size = bounds.size
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            withoutLayerActions {
                sceneLayer.frame = CGRect(origin: .zero, size: size)
            }
            if let lastLayout, lastLayout.0 == size, lastLayout.1 == scale { return }
            lastLayout = (size, scale)
            onLayout?(size, scale)
        }

        override func keyDown(with event: NSEvent) {
            onKeyDown?(event)
        }

        override func keyUp(with event: NSEvent) {
            onKeyUp?(event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.type == .keyDown, KeyCode(rawValue: event.keyCode) == .escape, event.modifierFlags.contains(.command) {
                onKeyDown?(event)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(convert(point, from: superview)) ? self : nil
        }

        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

        private func topLeftPoint(_ event: NSEvent) -> CGPoint {
            let point = convert(event.locationInWindow, from: nil)
            return CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
        }

        override func mouseMoved(with event: NSEvent) {
            onPointer?(.moved(topLeftPoint(event)))
        }

        override func mouseDragged(with event: NSEvent) {
            ProMotionPacer.shared.hold(for: 0.3)
            onPointer?(.moved(topLeftPoint(event)))
        }

        override func mouseDown(with event: NSEvent) {
            onPointer?(.pressed(.primary, topLeftPoint(event)))
        }

        override func mouseUp(with event: NSEvent) {
            onPointer?(.released(.primary, topLeftPoint(event)))
        }

        override func rightMouseDown(with event: NSEvent) {
            onPointer?(.pressed(.secondary, topLeftPoint(event)))
        }

        override func rightMouseUp(with event: NSEvent) {
            onPointer?(.released(.secondary, topLeftPoint(event)))
        }

        override func otherMouseDown(with event: NSEvent) {
            // Button 4 (number 3) is the side button that means back.
            guard event.buttonNumber == 3 else { return }
            onPointer?(.pressed(.back, topLeftPoint(event)))
        }

        override func scrollWheel(with event: NSEvent) {
            ProMotionPacer.shared.hold(for: 0.3)
            onPointer?(.scrolled(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas, at: topLeftPoint(event)))
        }
    }
#elseif FIRSTROW_PORTABLE
    /// What First Row draws into on Linux and Windows: a layer tree laid out like the Mac's
    /// view (origin bottom left), with the scene flipped to lay out from the top left.
    @MainActor
    final class SceneHostView {
        let hostLayer = CALayer()
        let sceneLayer = SceneLayer()
        var onLayout: ((CGSize, CGFloat) -> Void)?
        private(set) var bounds: CGRect
        private var lastLayout: (CGSize, CGFloat)?

        init(frame: CGRect) {
            bounds = CGRect(origin: .zero, size: frame.size)
            hostLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
            hostLayer.masksToBounds = true
            sceneLayer.isGeometryFlipped = true
            hostLayer.addSublayer(sceneLayer)
        }

        func layout(size: CGSize, scale: CGFloat) {
            bounds = CGRect(origin: .zero, size: size)
            withoutLayerActions {
                hostLayer.frame = bounds
                sceneLayer.frame = bounds
            }
            if let lastLayout, lastLayout.0 == size, lastLayout.1 == scale { return }
            lastLayout = (size, scale)
            onLayout?(size, scale)
        }

        /// Lays out again now, whether or not the size changed.
        func layoutNow() {
            guard let last = lastLayout else { return }
            lastLayout = nil
            layout(size: last.0, scale: last.1)
        }
    }
#else
    /// The view First Row draws into on iPhone, iPad and Apple TV.
    final class SceneHostView: UIView {
        let sceneLayer = SceneLayer()
        var onLayout: ((CGSize, CGFloat) -> Void)?
        private var lastLayout: (CGSize, CGFloat)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            clipsToBounds = true
            layer.addSublayer(sceneLayer)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            relayout()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            relayout()
        }

        /// Lays out again now, whether or not the size changed (the stance may have).
        func layoutNow() {
            lastLayout = nil
            relayout()
        }

        private func relayout() {
            let size = bounds.size
            let scale = window?.screen.scale ?? UIScreen.main.scale
            withoutLayerActions {
                sceneLayer.frame = CGRect(origin: .zero, size: size)
            }
            if let lastLayout, lastLayout.0 == size, lastLayout.1 == scale { return }
            lastLayout = (size, scale)
            onLayout?(size, scale)
        }
    }
#endif
