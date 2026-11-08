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
/// back to, and the transport for Now Playing and movies. Shown only in touch mode.
@MainActor
final class TouchControlsLayer {
    let layer = SceneLayer()
    private var buttons: [TouchControl: (base: SceneLayer, glyph: SceneLayer)] = [:]
    /// Each shown button's circle in window points, for touches.
    private(set) var frames: [TouchControl: CGRect] = [:]
    private var pressed: TouchControl?

    init() {
        layer.isHidden = true
    }

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
        var opacity: Double = 1
        #if os(iOS)
            let enabled = AppSettings.isTouchEnabled
        #else
            let enabled = false
        #endif
        // Laid out in the screen's own points, so the buttons are finger-sized on any screen,
        // and kept clear of the notch or Dynamic Island.
        let size = bounds.size
        let insets = Self.safeAreaInsets
        if enabled, !menu.isMovieTransitioning, menu.textEntry == nil, menu.codeDisplay == nil {
            let backFrame = CGRect(x: insets.left + 14, y: max(insets.top, 10) + 6, width: 46, height: 46)
            if menu.isMoviePlaybackVisible {
                // With the movie's controls, which fade together.
                opacity = menu.areMovieControlsVisible ? menu.movieControlsOpacity : 0
                let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                wanted = [
                    (.back, backFrame, "chevron.left", 19),
                    (.skipBack, CGRect(x: middle.x - 36 - 44 - 56, y: middle.y - 28, width: 56, height: 56), "gobackward.10", 22),
                    (.playPause, CGRect(x: middle.x - 36, y: middle.y - 36, width: 72, height: 72), menu.movieControlsGlyphState == .pause ? "play.fill" : "pause.fill", 28),
                    (.skipForward, CGRect(x: middle.x + 36 + 44, y: middle.y - 28, width: 56, height: 56), "goforward.10", 22),
                ]
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
        layer.isHidden = wanted.isEmpty
        frames = [:]
        let shown = Set(wanted.map(\.0))
        for (control, button) in buttons where !shown.contains(control) {
            button.base.isHidden = true
        }
        guard !wanted.isEmpty else { return }
        layer.place(bounds)
        let isModern = ModernTheme.isActive
        let pixelScale = scale
        for (control, frame, symbol, pointSize) in wanted {
            let button = buttons[control] ?? {
                let base = SceneLayer()
                let glyph = SceneLayer()
                base.addSublayer(glyph)
                layer.addSublayer(base)
                let made = (base, glyph)
                buttons[control] = made
                return made
            }()
            button.base.isHidden = false
            button.base.place(frame)
            button.base.cornerRadius = frame.width / 2
            button.base.backgroundColor = isModern ? CGColor(gray: 0.2, alpha: 0.72) : CGColor(gray: 0, alpha: 0.6)
            button.base.borderWidth = isModern ? 0 : 1
            button.base.borderColor = CGColor(gray: 1, alpha: 0.35)
            button.base.shadowColor = CGColor(gray: 0, alpha: 1)
            button.base.shadowOpacity = 0.35
            button.base.shadowRadius = 10
            button.base.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: frame.size), transform: nil)
            let graphic = SymbolRenderer.render(symbol, pointSize: pointSize, weight: .semibold, color: .white, scale: pixelScale)
            // Play's triangle looks centred a touch to the right of its box's middle.
            let nudge: CGFloat = symbol == "play.fill" ? pointSize * 0.06 : 0
            button.glyph.show(graphic, at: CGPoint(x: (frame.width - graphic.size.width) / 2 + nudge, y: (frame.height - graphic.size.height) / 2))
            frames[control] = frame
        }
        layer.setOpacity(opacity, pass.animation)
    }

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
        guard !layer.isHidden, layer.opacity > 0.05 else { return nil }
        return frames.first { $0.value.insetBy(dx: -8, dy: -8).contains(point) }?.key
    }
}
