import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// The buttons touch mode puts on screen, so nothing needs a gesture to find.
enum TouchControl: Equatable {
    case back
    case playPause
    case previous
    case next
    case skipBack
    case skipForward
}

/// Round buttons over everything else: Back at the top left wherever there's somewhere to go
/// back to, and the transport for Now Playing and movies. Shown only in touch mode. Buttons
/// come and go by fading through a blurred copy of themselves, sharpening as they appear.
@MainActor
final class TouchControlsLayer {
    let layer = SceneLayer()

    private final class Button {
        /// Positioned at the button's frame; fades and shrinks when pressed.
        let base = SceneLayer()
        /// The circle and its symbol.
        let sharp = SceneLayer()
        let glyph = SceneLayer()
        /// A soft, blurred copy of `sharp`, shown while the button fades in or out.
        let blurred = SceneLayer()
        var isShown = false
        var blurKey = ""
        /// Counts fades out, so a late one doesn't hide a button that came back meanwhile.
        var fadeGeneration = 0

        init() {
            base.addSublayer(sharp)
            sharp.addSublayer(glyph)
            base.addSublayer(blurred)
            blurred.contentsGravity = .resize
            base.isHidden = true
            base.opacity = 0
        }
    }

    private var buttons: [TouchControl: Button] = [:]
    /// Each shown button's circle in window points, for touches.
    private(set) var frames: [TouchControl: CGRect] = [:]
    private var pressed: TouchControl?
    private static let appear = Animation.smooth(duration: 0.34)
    private static let disappear = Animation.smoothInOut(duration: 0.3)

    func setPressed(_ control: TouchControl?) {
        guard control != pressed else { return }
        if let old = pressed, let button = buttons[old] { button.base.setTransform(CATransform3DIdentity, .smooth(duration: 0.18)) }
        pressed = control
        if let control, let button = buttons[control] {
            let size = button.base.bounds.size
            var shrink = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
            shrink = CATransform3DScale(shrink, 0.9, 0.9, 1)
            button.base.setTransform(CATransform3DTranslate(shrink, -size.width / 2, -size.height / 2, 0), .smooth(duration: 0.1))
        }
    }

    func update(menu: MenuView, pass: RenderPass, bounds: CGRect, scale: CGFloat) {
        var wanted: [(TouchControl, CGRect, String, CGFloat)] = []
        #if os(iOS)
            let enabled = AppSettings.isTouchEnabled
        #else
            let enabled = false
        #endif
        // Laid out in the screen's own points, so the buttons are finger-sized on any screen,
        // and kept clear of the notch or Dynamic Island and of the screen's rounded corners.
        let size = bounds.size
        let insets = Self.safeAreaInsets
        if enabled, !menu.isMovieTransitioning, menu.textEntry == nil, menu.codeDisplay == nil {
            let backFrame = CGRect(x: max(insets.left + 16, 38), y: max(insets.top + 10, 32), width: 46, height: 46)
            if menu.isMoviePlaybackVisible {
                // With the movie's controls, coming and going together.
                if menu.areMovieControlsVisible, menu.movieControlsOpacity > 0.01 {
                    let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                    wanted = [
                        (.back, backFrame, "chevron.left", 19),
                        (.skipBack, CGRect(x: middle.x - 36 - 44 - 56, y: middle.y - 28, width: 56, height: 56), "gobackward.10", 22),
                        (.playPause, CGRect(x: middle.x - 36, y: middle.y - 36, width: 72, height: 72), menu.movieControlsGlyphState == .pause ? "play.fill" : "pause.fill", 28),
                        (.skipForward, CGRect(x: middle.x + 36 + 44, y: middle.y - 28, width: 56, height: 56), "goforward.10", 22),
                    ]
                }
            } else if menu.activeFullscreenScene?.key == menu.musicNowPlayingFullscreenKey {
                let middle = size.width / 2
                let play: CGFloat = 64
                let side: CGFloat = 52
                let centerY = size.height - max(insets.bottom, 10) - 16 - play / 2
                wanted = [
                    (.back, backFrame, "chevron.left", 19),
                    (.previous, CGRect(x: middle - play / 2 - 36 - side, y: centerY - side / 2, width: side, height: side), "backward.fill", 20),
                    (.playPause, CGRect(x: middle - play / 2, y: centerY - play / 2, width: play, height: play), menu.isMusicPlaybackRunning() ? "pause.fill" : "play.fill", 26),
                    (.next, CGRect(x: middle + play / 2 + 36, y: centerY - side / 2, width: side, height: side), "forward.fill", 20),
                ]
            } else if menu.activeFullscreenScene != nil, menu.activeFullscreenScene?.key != menu.screenSaverFullscreenKey {
                wanted = [(.back, backFrame, "chevron.left", 19)]
            } else if menu.activeFullscreenScene == nil, menu.isInSubmenu || menu.isMovieResumePromptVisible {
                wanted = [(.back, backFrame, "chevron.left", 19)]
            }
        }
        frames = [:]
        let shown = Set(wanted.map(\.0))
        for (control, button) in buttons where button.isShown && !shown.contains(control) {
            hide(button)
        }
        layer.place(bounds)
        let isModern = ModernTheme.isActive
        for (control, frame, symbol, pointSize) in wanted {
            let button = buttons[control] ?? {
                let made = Button()
                layer.addSublayer(made.base)
                buttons[control] = made
                return made
            }()
            if button.base.frame != frame { button.base.place(frame) }
            let local = CGRect(origin: .zero, size: frame.size)
            let fill = isModern ? CGColor(gray: 0.2, alpha: 0.72) : CGColor(gray: 0, alpha: 0.6)
            button.sharp.frame = local
            button.sharp.cornerRadius = frame.width / 2
            button.sharp.backgroundColor = fill
            button.sharp.borderWidth = isModern ? 0 : 1
            button.sharp.borderColor = CGColor(gray: 1, alpha: 0.35)
            button.sharp.shadowColor = CGColor(gray: 0, alpha: 1)
            button.sharp.shadowOpacity = 0.35
            button.sharp.shadowRadius = 10
            button.sharp.shadowPath = CGPath(ellipseIn: local, transform: nil)
            let graphic = SymbolRenderer.render(symbol, pointSize: pointSize, weight: .semibold, color: .white, scale: scale)
            // Play's triangle looks centred a touch to the right of its box's middle.
            let nudge: CGFloat = symbol == "play.fill" ? pointSize * 0.06 : 0
            let glyphOrigin = CGPoint(x: (frame.width - graphic.size.width) / 2 + nudge, y: (frame.height - graphic.size.height) / 2)
            button.glyph.show(graphic, at: glyphOrigin)
            let blurKey = "\(symbol)|\(frame.size.width)|\(isModern)"
            if button.blurKey != blurKey {
                button.blurKey = blurKey
                let blur = Self.blurredButton(size: frame.size, fill: fill, border: !isModern, graphic: graphic, glyphOrigin: glyphOrigin)
                button.blurred.contents = blur?.image
                button.blurred.frame = local.insetBy(dx: -(blur?.margin ?? 0), dy: -(blur?.margin ?? 0))
            }
            frames[control] = frame
            if !button.isShown { show(button) }
        }
    }

    /// Fades a button in from its blurred copy.
    private func show(_ button: Button) {
        button.isShown = true
        button.fadeGeneration += 1
        let fresh = button.base.isHidden || button.base.opacity < 0.01
        button.base.isHidden = false
        if fresh {
            button.base.opacity = 0
            button.sharp.opacity = 0
            button.blurred.opacity = 1
        }
        button.base.setOpacity(1, Self.appear)
        button.sharp.setOpacity(1, Self.appear)
        button.blurred.setOpacity(0, Self.appear)
    }

    /// Fades a button out through its blurred copy, then hides it.
    private func hide(_ button: Button) {
        button.isShown = false
        button.fadeGeneration += 1
        let generation = button.fadeGeneration
        button.base.setOpacity(0, Self.disappear)
        button.sharp.setOpacity(0, Self.disappear)
        button.blurred.setOpacity(1, Self.disappear)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.disappear.duration + 0.05) {
            MainActor.assumeIsolatedIfPossible {
                guard button.fadeGeneration == generation, !button.isShown else { return }
                button.base.isHidden = true
            }
        }
    }

    private static var blurCache: [String: (image: CGImage, margin: CGFloat)] = [:]

    /// The button drawn soft, as if out of focus: its circle and symbol under a near-Gaussian
    /// blur, with room around them for the blur to spread into. Small enough to make at once.
    private static func blurredButton(size: CGSize, fill: CGColor, border: Bool, graphic: RenderedGraphic, glyphOrigin: CGPoint) -> (image: CGImage, margin: CGFloat)? {
        #if os(iOS)
            let key = "\(size.width)|\(border)|\(ObjectIdentifier(graphic.image ?? Self.emptyImage))"
            if let cached = blurCache[key] { return cached }
            #if DEBUG || FIRSTROW_HARNESS_BUILD
                let started = CACurrentMediaTime()
                defer { FirstRowHarness.touchLog(String(format: "[touch] blurred a button in %.1f ms", (CACurrentMediaTime() - started) * 1000)) }
            #endif
            // Drawn at a point a pixel: blurred, it needs no more.
            let pixels: CGFloat = 1
            let sigma: CGFloat = 7
            let margin = (sigma * 3).rounded(.up)
            let width = Int((size.width + margin * 2) * pixels)
            let height = Int((size.height + margin * 2) * pixels)
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
            ) else { return nil }
            context.scaleBy(x: pixels, y: pixels)
            let circle = CGRect(x: margin, y: margin, width: size.width, height: size.height)
            context.setFillColor(fill)
            context.fillEllipse(in: circle)
            if border {
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
                context.setLineWidth(1)
                context.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))
            }
            if let image = graphic.image {
                // Bitmap y is up: flip the glyph's top-left placement.
                let box = graphic.imageFrame(at: glyphOrigin)
                context.draw(image, in: CGRect(x: margin + box.minX, y: margin + size.height - box.maxY, width: box.width, height: box.height))
            }
            guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            // Three box blurs come close to a Gaussian one.
            let radius = Int((sigma * pixels * 0.97).rounded())
            for _ in 0 ..< 3 {
                for y in 0 ..< height {
                    boxBlur(data + y * context.bytesPerRow, count: width, stride: 4, radius: radius)
                }
                for x in 0 ..< width {
                    boxBlur(data + x * 4, count: height, stride: context.bytesPerRow, radius: radius)
                }
            }
            guard let blurred = context.makeImage() else { return nil }
            if blurCache.count > 40 { blurCache.removeAll() }
            blurCache[key] = (blurred, margin)
            return (blurred, margin)
        #else
            return nil
        #endif
    }

    #if os(iOS)
        /// Averages each pixel with `radius` on either side along a line of `count` pixels
        /// `stride` bytes apart (all four channels), treating what lies beyond as clear.
        private static func boxBlur(_ start: UnsafeMutablePointer<UInt8>, count: Int, stride: Int, radius: Int) {
            let window = Int32(2 * radius + 1)
            let values = UnsafeMutablePointer<Int32>.allocate(capacity: count)
            defer { values.deallocate() }
            for channel in 0 ..< 4 {
                var pixel = start + channel
                for index in 0 ..< count {
                    values[index] = Int32(pixel.pointee)
                    pixel += stride
                }
                var sum: Int32 = 0
                for index in 0 ..< min(radius, count) { sum += values[index] }
                pixel = start + channel
                for index in 0 ..< count {
                    if index + radius < count { sum += values[index + radius] }
                    if index - radius - 1 >= 0 { sum -= values[index - radius - 1] }
                    pixel.pointee = UInt8(truncatingIfNeeded: min(255, sum / window))
                    pixel += stride
                }
            }
        }

        private static let emptyImage: CGImage = {
            let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo)!
            return context.makeImage()!
        }()
    #endif

    private static var safeAreaInsets: (left: CGFloat, top: CGFloat, bottom: CGFloat) {
        #if os(iOS)
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }
            let insets = window?.safeAreaInsets ?? .zero
            return (insets.left, insets.top, insets.bottom)
        #else
            return (0, 0, 0)
        #endif
    }

    /// The button under a window point, with a little room around each for fingers.
    func control(at point: CGPoint) -> TouchControl? {
        frames.first { $0.value.insetBy(dx: -8, dy: -8).contains(point) }?.key
    }
}
