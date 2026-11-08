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
            relayout()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
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
