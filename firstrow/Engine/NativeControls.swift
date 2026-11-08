#if os(iOS) || os(macOS)
    import QuartzCore
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    // The on-screen buttons as the system's own Liquid Glass controls (iOS 26 and macOS 26 and
    // later, the modern look only). They sit in views over the scene, in containers that take on
    // the scene's moves: Now Playing's buttons scale with it, and its transport slides away.
    // Glass can't be faded part way on iPhone and iPad (it ignores opacity), so there it comes
    // and goes the system's way, by materialising, while its symbol fades; on the Mac it fades.

    extension Animation {
        /// The curve's two control points, for the system's own animations.
        var controlPoints: (CGPoint, CGPoint) {
            var first: [Float] = [0, 0]
            var second: [Float] = [0, 0]
            timingFunction.getControlPoint(at: 1, values: &first)
            timingFunction.getControlPoint(at: 2, values: &second)
            return (CGPoint(x: CGFloat(first[0]), y: CGFloat(first[1])), CGPoint(x: CGFloat(second[0]), y: CGFloat(second[1])))
        }
    }

    /// Runs `changes` to native views with an animation of First Row's (or at once with nil).
    @MainActor
    private func animateViews(_ animation: Animation?, _ changes: @escaping () -> Void, completion: (() -> Void)? = nil) {
        guard let animation, animation.duration > 0 else {
            #if os(macOS)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    changes()
                }
            #else
                UIView.performWithoutAnimation(changes)
            #endif
            completion?()
            return
        }
        #if os(macOS)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = animation.duration
                context.timingFunction = animation.timingFunction
                context.allowsImplicitAnimation = true
                changes()
            }, completionHandler: { MainActor.assumeIsolatedIfPossible { completion?() } })
        #else
            let points = animation.controlPoints
            let animator = UIViewPropertyAnimator(duration: animation.duration, controlPoint1: points.0, controlPoint2: points.1, animations: changes)
            animator.addCompletion { _ in completion?() }
            animator.startAnimation(afterDelay: animation.delay)
        #endif
    }

    #if os(macOS)
        typealias NativeView = NSView

        /// Lets clicks through to the scene except on its buttons; lays out from the top left.
        final class NativePassthroughView: NSView {
            override var isFlipped: Bool { true }

            override init(frame: NSRect) {
                super.init(frame: frame)
                wantsLayer = true
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

            override func hitTest(_ point: NSPoint) -> NSView? {
                let hit = super.hitTest(point)
                return hit === self ? nil : hit
            }
        }

        /// Glass that's only for show: clicks go through it to the scene, which hit-tests them.
        @available(macOS 26.0, *)
        final class NativePassiveGlass: NSGlassEffectView {
            override func hitTest(_: NSPoint) -> NSView? { nil }
        }
    #else
        typealias NativeView = UIView

        /// Lets touches through to the scene except on its buttons.
        final class NativePassthroughView: UIView {
            override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
                let hit = super.hitTest(point, with: event)
                return hit === self ? nil : hit
            }
        }
    #endif

    /// A symbol as the system draws it, white.
    @available(macOS 26.0, iOS 26.0, *)
    @MainActor
    private func nativeSymbol(_ name: String, pointSize: CGFloat) -> NativeImage? {
        #if os(macOS)
            let fallbackName = name == "gauge.with.dots.needle.67percent" ? "speedometer" : name
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(systemSymbolName: fallbackName, accessibilityDescription: nil) else { return nil }
            return base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        #else
            return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold))
        #endif
    }

    #if os(macOS)
        typealias NativeImage = NSImage
    #else
        typealias NativeImage = UIImage
    #endif

    /// One round (or capsule) glass button with a symbol on it.
    @available(macOS 26.0, iOS 26.0, *)
    @MainActor
    final class NativeGlassButton: NativeView {
        var onPress: (() -> Void)?
        private(set) var isShownState = false
        private var generation = 0
        private var symbolName = ""
        private var symbolSize: CGFloat = 0
        #if os(macOS)
            private let glass = NSGlassEffectView()
            private let icon = NSImageView()
            private var isPressing = false
        #else
            private let glass = UIVisualEffectView(effect: nil)
            private let icon = UIImageView()
            private let effect: UIGlassEffect = {
                let effect = UIGlassEffect(style: .regular)
                effect.isInteractive = true
                return effect
            }()
        #endif

        init() {
            super.init(frame: .zero)
            #if os(macOS)
                wantsLayer = true
                glass.style = .regular
                let holder = NSView()
                holder.addSubview(icon)
                glass.contentView = holder
                icon.contentTintColor = .white
                icon.imageScaling = .scaleNone
                addSubview(glass)
                alphaValue = 0
                isHidden = true
            #else
                glass.cornerConfiguration = .capsule()
                icon.tintColor = .white
                icon.contentMode = .center
                glass.contentView.addSubview(icon)
                addSubview(glass)
                icon.alpha = 0
                isHidden = true
                let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
                glass.addGestureRecognizer(tap)
            #endif
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

        #if os(macOS)
            override var isFlipped: Bool { true }
        #else
            @objc private func tapped() {
                guard isShownState else { return }
                onPress?()
            }
        #endif

        /// Places it (in its container's points) with `symbol` on it, nudged right by `nudge`.
        func place(_ frame: CGRect, symbol: String, pointSize: CGFloat, nudge: CGFloat) {
            if self.frame != frame { self.frame = frame }
            let local = CGRect(origin: .zero, size: frame.size)
            if glass.frame != local { glass.frame = local }
            #if os(macOS)
                glass.cornerRadius = frame.height / 2
                glass.contentView?.frame = local
            #endif
            if symbol != symbolName || pointSize != symbolSize, let image = nativeSymbol(symbol, pointSize: pointSize) {
                let changes = !symbolName.isEmpty
                symbolName = symbol
                symbolSize = pointSize
                if changes {
                    icon.setSymbolImage(image, contentTransition: .replace)
                } else {
                    icon.image = image
                }
            }
            let iconFrame = local.offsetBy(dx: nudge, dy: 0)
            if icon.frame != iconFrame { icon.frame = iconFrame }
        }

        /// Shown, dimmed (to `dimmedAlpha` of its symbol, without its glass on iPhone), or away.
        func setState(shown: Bool, dimmed: Bool, dimmedAlpha: CGFloat, animation: Animation?) {
            let wasShown = isShownState
            isShownState = shown
            generation += 1
            let current = generation
            if shown { isHidden = false }
            #if os(macOS)
                let alpha: CGFloat = shown ? (dimmed ? dimmedAlpha : 1) : 0
                animateViews(animation, { self.animator().alphaValue = alpha }, completion: {
                    guard self.generation == current, !self.isShownState else { return }
                    self.isHidden = true
                })
            #else
                let glassOn = shown && !dimmed
                let iconAlpha: CGFloat = shown ? (dimmed ? dimmedAlpha : 1) : 0
                glass.isUserInteractionEnabled = shown
                if !wasShown, shown, animation != nil {
                    // From nothing: the glass materialises as the symbol comes in.
                    UIView.performWithoutAnimation {
                        self.glass.effect = nil
                        self.icon.alpha = 0
                    }
                }
                animateViews(animation, {
                    self.glass.effect = glassOn ? self.effect : nil
                    self.icon.alpha = iconAlpha
                }, completion: {
                    guard self.generation == current, !self.isShownState else { return }
                    self.isHidden = true
                })
            #endif
        }

        #if os(macOS)
            override func hitTest(_ point: NSPoint) -> NSView? {
                guard isShownState, !isHidden, alphaValue > 0.05 else { return nil }
                return frame.contains(point) ? self : nil
            }

            override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

            override func mouseDown(with _: NSEvent) {
                isPressing = true
                setPressedLook(true)
            }

            override func mouseDragged(with event: NSEvent) {
                setPressedLook(bounds.contains(convert(event.locationInWindow, from: nil)))
            }

            override func mouseUp(with event: NSEvent) {
                let inside = bounds.contains(convert(event.locationInWindow, from: nil))
                isPressing = false
                setPressedLook(false)
                if inside, isShownState { onPress?() }
            }

            private func setPressedLook(_ pressed: Bool) {
                guard let layer else { return }
                let size = bounds.size
                var transform = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
                transform = CATransform3DScale(transform, pressed ? 0.9 : 1, pressed ? 0.9 : 1, 1)
                transform = CATransform3DTranslate(transform, -size.width / 2, -size.height / 2, 0)
                layer.setTransform(transform, .smooth(duration: pressed ? 0.1 : 0.18))
            }
        #endif
    }

    /// The glass under a movie's option buttons and its options panel: only for show (taps and
    /// clicks go through to the scene, which knows where the buttons and rows are). The panel's
    /// rows are First Row's own layers, hosted inside the glass.
    @available(macOS 26.0, iOS 26.0, *)
    @MainActor
    final class NativeOptionsGlass {
        #if os(macOS)
            private let cluster = NativePassiveGlass()
            private let panel = NativePassiveGlass()
            private let clusterContent = NSView()
            private let panelHost: NSView = {
                let view = NSView()
                view.wantsLayer = true
                return view
            }()
            /// Holds First Row's own panel layers, laid out from the top left (the view's own
            /// layer is AppKit's, laid out from the bottom left).
            let panelLayerHost: CALayer = {
                let layer = CALayer()
                layer.isGeometryFlipped = true
                return layer
            }()
        #else
            private let cluster = UIVisualEffectView(effect: nil)
            private let panel = UIVisualEffectView(effect: nil)
            private var clusterContent: UIView { cluster.contentView }
            private let panelHost = UIView()
            var panelLayerHost: CALayer { panelHost.layer }
        #endif
        private var icons: [MenuView.MovieOptionRow.Kind: NativeView] = [:]
        private var iconsKey = ""
        private let highlight = NativeView()
        private var clusterShown = false
        private var panelShown = false
        private var clusterGeneration = 0
        private var panelGeneration = 0

        init(in container: NativeView) {
            #if os(macOS)
                for glass in [cluster, panel] {
                    glass.style = .regular
                    glass.alphaValue = 0
                    glass.isHidden = true
                    container.addSubview(glass)
                }
                cluster.contentView = clusterContent
                clusterContent.wantsLayer = true
                panel.contentView = panelHost
                panelHost.layer?.addSublayer(panelLayerHost)
                highlight.wantsLayer = true
                highlight.layer?.backgroundColor = CGColor(gray: 1, alpha: 0.26)
                highlight.alphaValue = 0
            #else
                for glass in [cluster, panel] {
                    glass.isUserInteractionEnabled = false
                    glass.isHidden = true
                    container.addSubview(glass)
                }
                cluster.cornerConfiguration = .capsule()
                panel.contentView.addSubview(panelHost)
                highlight.backgroundColor = UIColor(white: 1, alpha: 0.26)
                highlight.alpha = 0
            #endif
            clusterContent.addSubview(highlight)
        }

        /// The buttons above the bar (window points): one icon per kind, the focused one with
        /// a soft circle; nil while the controls are away.
        func updateCluster(frame: CGRect?, kinds: [MenuView.MovieOptionRow.Kind], slotWidth: CGFloat, focused: MenuView.MovieOptionRow.Kind?, iconSize: CGFloat, animation: Animation?) {
            if let frame {
                cluster.frame = frame
                #if os(macOS)
                    cluster.cornerRadius = frame.height / 2
                    clusterContent.frame = CGRect(origin: .zero, size: frame.size)
                #endif
                let key = "\(kinds)|\(iconSize)|\(frame.size.width)|\(frame.size.height)"
                if key != iconsKey {
                    iconsKey = key
                    for icon in icons.values { icon.removeFromSuperview() }
                    icons = [:]
                    for (index, kind) in kinds.enumerated() {
                        let slot = CGRect(x: frame.height * 0.08 + slotWidth * CGFloat(index), y: 0, width: slotWidth, height: frame.height)
                        #if os(macOS)
                            let icon = NSImageView(frame: slot)
                            icon.image = nativeSymbol(MovieOptionsLayer.symbol(for: kind), pointSize: iconSize)
                            icon.contentTintColor = .white
                            icon.imageScaling = .scaleNone
                        #else
                            let icon = UIImageView(frame: slot)
                            icon.image = nativeSymbol(MovieOptionsLayer.symbol(for: kind), pointSize: iconSize)
                            icon.tintColor = .white
                            icon.contentMode = .center
                        #endif
                        clusterContent.addSubview(icon)
                        icons[kind] = icon
                    }
                }
                if let focused, let index = kinds.firstIndex(of: focused) {
                    let side = frame.height * 0.8
                    let circle = CGRect(x: frame.height * 0.08 + slotWidth * (CGFloat(index) + 0.5) - side / 2, y: (frame.height - side) / 2, width: side, height: side)
                    #if os(macOS)
                        highlight.layer?.cornerRadius = side / 2
                        let moves = highlight.alphaValue > 0.01
                        animateViews(moves ? .smooth(duration: 0.22) : nil, { self.highlight.animator().frame = circle })
                        animateViews(.smooth(duration: 0.2), { self.highlight.animator().alphaValue = 1 })
                    #else
                        highlight.layer.cornerRadius = side / 2
                        let moves = highlight.alpha > 0.01
                        animateViews(moves ? .smooth(duration: 0.22) : nil, { self.highlight.frame = circle })
                        animateViews(.smooth(duration: 0.2), { self.highlight.alpha = 1 })
                    #endif
                } else {
                    #if os(macOS)
                        animateViews(.smooth(duration: 0.2), { self.highlight.animator().alphaValue = 0 })
                    #else
                        animateViews(.smooth(duration: 0.2), { self.highlight.alpha = 0 })
                    #endif
                }
            }
            setShown(frame != nil, glass: cluster, shown: &clusterShown, generation: &clusterGeneration, content: clusterContent, animation: animation)
        }

        /// The panel (window points), open or gone back into the buttons; `collapsed` is the
        /// transform that shrinks it into them, about its own top left.
        func updatePanel(frame: CGRect, open: Bool, collapsed: CATransform3D, animation: Animation?) {
            if panel.bounds.size != frame.size || panel.frame.origin != frame.origin {
                setViewFrame(panel, frame)
                panelHost.frame = CGRect(origin: .zero, size: frame.size)
                #if os(macOS)
                    withoutLayerActions { panelLayerHost.frame = CGRect(origin: .zero, size: frame.size) }
                #endif
                #if os(macOS)
                    panel.cornerRadius = 34 * (frame.width / 760)
                #else
                    panel.cornerConfiguration = .uniformCorners(radius: .fixed(34 * (frame.width / 760)))
                #endif
            }
            let opening = open && !panelShown
            #if os(macOS)
                if opening, panel.alphaValue < 0.02 { panel.layer?.setTransform(collapsed, nil) }
                panel.layer?.setTransform(open ? CATransform3DIdentity : collapsed, animation)
            #else
                if opening, panel.isHidden { panel.layer.setTransform(collapsed, nil) }
                panel.layer.setTransform(open ? CATransform3DIdentity : collapsed, animation)
            #endif
            setShown(open, glass: panel, shown: &panelShown, generation: &panelGeneration, content: panelHost, animation: animation)
        }

        func hideAll() {
            updateCluster(frame: nil, kinds: [], slotWidth: 0, focused: nil, iconSize: 0, animation: nil)
            setShown(false, glass: panel, shown: &panelShown, generation: &panelGeneration, content: panelHost, animation: nil)
        }

        private func setViewFrame(_ view: NativeView, _ frame: CGRect) {
            // Placed by bounds and position, so a transform part way doesn't move it.
            #if os(macOS)
                view.setFrameOrigin(frame.origin)
                view.setFrameSize(frame.size)
            #else
                view.bounds = CGRect(origin: .zero, size: frame.size)
                view.center = CGPoint(x: frame.midX, y: frame.midY)
            #endif
        }

        #if os(macOS)
            private func setShown(_ shown: Bool, glass: NSGlassEffectView, shown state: inout Bool, generation: inout Int, content _: NSView, animation: Animation?) {
                guard shown != state else { return }
                state = shown
                generation += 1
                let current = generation
                let isCluster = glass === cluster
                if shown { glass.isHidden = false }
                animateViews(animation, { glass.animator().alphaValue = shown ? 1 : 0 }, completion: { [weak self] in
                    guard let self else { return }
                    let still = isCluster ? self.clusterGeneration == current && !self.clusterShown : self.panelGeneration == current && !self.panelShown
                    if still { glass.isHidden = true }
                })
            }
        #else
            private func setShown(_ shown: Bool, glass: UIVisualEffectView, shown state: inout Bool, generation: inout Int, content: UIView, animation: Animation?) {
                guard shown != state else { return }
                state = shown
                generation += 1
                let current = generation
                let isCluster = glass === cluster
                if shown {
                    glass.isHidden = false
                    UIView.performWithoutAnimation { content.alpha = 0 }
                }
                animateViews(animation, {
                    glass.effect = shown ? UIGlassEffect(style: .regular) : nil
                    content.alpha = shown ? 1 : 0
                }, completion: { [weak self] in
                    guard let self else { return }
                    let still = isCluster ? self.clusterGeneration == current && !self.clusterShown : self.panelGeneration == current && !self.panelShown
                    if still { glass.isHidden = true }
                })
            }
        #endif
    }

    /// The native buttons and glass over the scene.
    @available(macOS 26.0, iOS 26.0, *)
    @MainActor
    final class NativeControls {
        /// Made when the system has Liquid Glass; nil before macOS 26 and iOS 26.
        static var shared: NativeControls?

        static func makeIfSupported() -> NativeControls? {
            let controls = NativeControls()
            shared = controls
            return controls
        }

        /// Goes over the scene in the window.
        let view = NativePassthroughView()
        private let sceneView = NativePassthroughView()
        private let transportView = NativePassthroughView()
        private let optionsView = NativePassthroughView()
        private(set) lazy var options = NativeOptionsGlass(in: optionsView)
        var onPress: ((TouchControl) -> Void)?

        struct Key: Hashable {
            let control: TouchControl
            let inScene: Bool
        }

        struct Item {
            let control: TouchControl
            let inScene: Bool
            let frame: CGRect
            let symbol: String
            let pointSize: CGFloat
            let dimmed: Bool
            let dimmedAlpha: CGFloat
        }

        private var buttons: [Key: NativeGlassButton] = [:]
        private var sceneAway = false
        private var transportDown = false

        private init() {
            view.addSubview(optionsView)
            view.addSubview(sceneView)
            sceneView.addSubview(transportView)
            #if os(macOS)
                view.appearance = NSAppearance(named: .darkAqua)
            #else
                view.overrideUserInterfaceStyle = .dark
            #endif
        }

        /// Lays the buttons out. `scene` is how Now Playing is scaled and how visible it is;
        /// `transport` whether its buttons have slid down out of the way, and by how far.
        func update(
            items: [Item],
            size: CGSize,
            sceneTransform: CATransform3D,
            sceneOpacity: Double,
            sceneAnimation: Animation?,
            transportHidden: Bool,
            transportDrop: CGFloat,
            transportAnimation: Animation?,
            appear: Animation,
            disappear: Animation,
            instantly: Set<Key>,
        ) {
            let bounds = CGRect(origin: .zero, size: size)
            for container in [view, sceneView, optionsView] where container.frame != bounds {
                container.frame = bounds
            }
            #if os(macOS)
                sceneView.layer?.setTransform(sceneTransform, sceneAnimation)
                if abs(Double(sceneView.alphaValue) - sceneOpacity) > 0.001 {
                    animateViews(sceneAnimation, { self.sceneView.animator().alphaValue = CGFloat(sceneOpacity) })
                }
                let transportFrame = bounds.offsetBy(dx: 0, dy: transportHidden ? transportDrop : 0)
                if transportView.frame != transportFrame || transportHidden != transportDown {
                    let moving = transportHidden != transportDown
                    transportDown = transportHidden
                    animateViews(moving ? transportAnimation : nil, {
                        self.transportView.animator().frame = transportFrame
                        self.transportView.animator().alphaValue = transportHidden ? 0 : 1
                    })
                }
            #else
                if transportView.bounds.size != size {
                    transportView.bounds = bounds
                    transportView.center = CGPoint(x: bounds.midX, y: bounds.midY)
                }
                sceneView.layer.setTransform(sceneTransform, sceneAnimation)
                transportDown = transportHidden
                transportView.layer.setTransform(transportHidden ? CATransform3DMakeTranslation(0, transportDrop, 0) : CATransform3DIdentity, transportAnimation)
                // Glass can't be faded part way here: Now Playing's buttons materialise and
                // dematerialise with it instead.
                let away = sceneOpacity < 0.5
                let sceneChanged = away != sceneAway
                sceneAway = away
            #endif

            let wanted = Set(items.map { Key(control: $0.control, inScene: $0.inScene) })
            for (key, button) in buttons where button.isShownState && !wanted.contains(key) {
                button.setState(shown: false, dimmed: false, dimmedAlpha: 1, animation: instantly.contains(key) ? nil : disappear)
            }
            for item in items {
                let key = Key(control: item.control, inScene: item.inScene)
                let button = buttons[key] ?? {
                    let made = NativeGlassButton()
                    made.onPress = { [weak self] in self?.onPress?(item.control) }
                    (item.inScene ? transportView : view).addSubview(made)
                    buttons[key] = made
                    return made
                }()
                let nudge: CGFloat = item.symbol == "play.fill" ? item.pointSize * 0.06 : 0
                // Following the progress bar as Now Playing moves aside for the words.
                if item.inScene, button.isShownState, button.frame != item.frame, !instantly.contains(key), let sceneAnimation {
                    let target = item.frame
                    animateViews(sceneAnimation, { button.frame = target })
                }
                button.place(item.frame, symbol: item.symbol, pointSize: item.pointSize, nudge: nudge)
                #if os(macOS)
                    let shown = true
                    let animation: Animation? = instantly.contains(key) ? nil : (button.isShownState ? .smooth(duration: 0.35) : appear)
                #else
                    let shown = !(item.inScene && sceneAway)
                    let animation: Animation? = item.inScene && sceneChanged ? sceneAnimation : (instantly.contains(key) ? nil : (button.isShownState ? .smooth(duration: 0.35) : appear))
                #endif
                button.setState(shown: shown, dimmed: item.dimmed, dimmedAlpha: item.dimmedAlpha, animation: animation)
            }
        }

        /// Everything away (quitting, or the classic look).
        func hideAll(animation: Animation?) {
            for button in buttons.values where button.isShownState {
                button.setState(shown: false, dimmed: false, dimmedAlpha: 1, animation: animation)
            }
            options.hideAll()
        }
    }
#endif
