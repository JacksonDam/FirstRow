import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// The buttons put on screen for the pointer and fingers, so nothing needs a gesture to find.
enum TouchControl: Equatable {
    case back
    /// Back at the head of a video's panel, out of a comment's replies. A button of its own,
    /// so that Back goes from the corner as this one comes, and the other way round.
    case panelBack
    case playPause
    case previous
    case next
    case skipBack
    case skipForward
    /// Now Playing's lyrics.
    case lyrics
}

/// Round buttons over everything else: Back at the top left wherever there's somewhere to go
/// back to, and the transport for Now Playing and movies. Shown while the pointer or a finger was
/// the last input. Buttons come and go by fading through a blurred copy of themselves, sharpening
/// as they appear; Now Playing's own buttons instead belong to it, scaling and fading with the
/// rest of it.
@MainActor
final class TouchControlsLayer {
    let layer = SceneLayer()
    /// Follows the full-screen scene's scale and opacity.
    private let sceneGroup = SceneLayer()
    /// Goes with Now Playing as it turns round every so often: in the classic look it turns
    /// with the panel, about the middle of the screen as the panel does; in the modern look
    /// it fades away and back with it.
    private let turnGroup = CALayer()
    private var lastTurnAway: CGFloat = 0
    /// Now Playing's buttons, which slide down off the screen while a song plays untouched,
    /// leaving a faint bar to pull them back up with.
    private let transportGroup = SceneLayer()
    private let transportHint = HintBarLayer()
    /// The bar along the right edge that pulls Now Playing's list out: the same bar as the
    /// transport's, turned on its side.
    private let queueHint = HintBarLayer()
    private var wasEnabled = false
    #if os(macOS)
        /// When the buttons were last laid out: nothing on screen has changed since.
        private var lastUpdate: CFTimeInterval = 0
        /// Makes the system's glass buttons ahead (see `NativeControls.makeAhead`), one at a
        /// time while nothing is happening.
        private var aheadTimer: Timer?
        private var hasMadeButtonsAhead = false
        /// The buttons most often wanted: Back, and Now Playing's.
        private static let usualButtons: [(control: TouchControl, inScene: Bool, symbol: String, pointSize: CGFloat, side: CGFloat)] = [
            (.back, false, "chevron.left", 19, 46),
            (.playPause, true, "pause.fill", 26, 64),
            (.previous, true, "backward.fill", 20, 52),
            (.next, true, "forward.fill", 20, 52),
            (.lyrics, true, "quote.bubble", 19, 46),
        ]
    #endif

    private final class Button {
        /// Positioned at the button's frame; fades and shrinks when pressed.
        let base = SceneLayer()
        /// The circle (or capsule) and what's on it.
        let sharp = SceneLayer()
        let glyph = SceneLayer()
        let label = SceneLayer()
        /// A soft, blurred copy of `sharp`, shown while the button fades in or out.
        let blurred = SceneLayer()
        var isShown = false
        /// Faded back while Now Playing sits untouched.
        var isDimmed = false
        var blurKey = ""
        /// Counts fades out, so a late one doesn't hide a button that came back meanwhile.
        var fadeGeneration = 0

        init() {
            base.addSublayer(sharp)
            sharp.addSublayer(glyph)
            sharp.addSublayer(label)
            base.addSublayer(blurred)
            blurred.contentsGravity = .resize
            base.isHidden = true
            base.opacity = 0
        }
    }

    private struct Wanted {
        let control: TouchControl
        var frame: CGRect
        let symbol: String
        let pointSize: CGFloat
        var label: RenderedGraphic?
        /// Part of the full-screen scene rather than laid over it.
        var inScene = false
    }

    private struct Key: Hashable {
        let control: TouchControl
        let inScene: Bool
    }

    private var buttons: [Key: Button] = [:]
    /// Each shown button's circle in window points, for touches.
    private(set) var frames: [TouchControl: CGRect] = [:]
    private var pressed: TouchControl?
    private var lastTransportHidden = false
    /// When the buttons' last slide ends, and how far down it was going.
    private var transportSlideEnds: CFTimeInterval = 0
    private var transportSlideDrop: CGFloat = 0
    /// Now Playing's scale and visibility, as last set (the native buttons follow them too).
    private var sceneTransform = CATransform3DIdentity
    private var sceneOpacity: Double = 1
    private static let appear = Animation.smooth(duration: 0.34)
    private static let disappear = Animation.smoothInOut(duration: 0.3)

    init() {
        layer.addSublayer(sceneGroup)
        turnGroup.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "opacity": NSNull()]
        sceneGroup.addSublayer(turnGroup)
        turnGroup.addSublayer(transportGroup)
        sceneGroup.addSublayer(transportHint.layer)
        sceneGroup.addSublayer(queueHint.layer)
    }

    func setPressed(_ control: TouchControl?) {
        guard control != pressed else { return }
        for (key, button) in buttons where key.control == pressed {
            button.base.setTransform(CATransform3DIdentity, .smooth(duration: 0.18))
        }
        pressed = control
        for (key, button) in buttons where key.control == control && button.isShown {
            let size = button.base.bounds.size
            var shrink = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
            shrink = CATransform3DScale(shrink, 0.9, 0.9, 1)
            button.base.setTransform(CATransform3DTranslate(shrink, -size.width / 2, -size.height / 2, 0), .smooth(duration: 0.1))
        }
    }

    /// Now Playing's progress bar in window points: the last one seen, while songs change over.
    private var nowPlayingBar: CGRect?
    /// How large Now Playing's details show against their full size (small with the list or
    /// the words out).
    private var nowPlayingScale: CGFloat = 1
    /// How far along that bar is from where it rests (sliding off the screen, or in), which its
    /// buttons follow whole.
    private var nowPlayingSlide: CGFloat = 0
    /// Where Now Playing's buttons start down from, when they're under its progress bar.
    private var transportTop: CGFloat?

    func update(menu: MenuView, pass: RenderPass, bounds: CGRect, scale: CGFloat, nowPlayingBar bar: CGRect? = nil, nowPlayingScale detailsScale: CGFloat? = nil, nowPlayingSlide slide: CGFloat? = nil, movieOptionsPanel: CGRect? = nil, videoPanelBack: CGPoint? = nil) {
        if let bar { nowPlayingBar = bar }
        if let detailsScale { nowPlayingScale = detailsScale }
        if let slide { nowPlayingSlide = slide }
        var wanted: [Wanted] = []
        // Shown for the pointer and fingers; a key or remote puts them straight away.
        let enabled = menu.showsOnScreenControls && menu.showsPointingHints && menu.onboardingStep == nil
        let putAwayForKeys = wasEnabled && !enabled
        wasEnabled = enabled
        #if os(macOS)
            lastUpdate = CACurrentMediaTime()
        #endif
        let isModern = ModernTheme.isActive
        // Laid out in the screen's own points, so the buttons are finger-sized on any screen,
        // and kept clear of the notch or Dynamic Island and of the screen's rounded corners.
        let size = bounds.size
        let insets = Self.safeAreaInsets
        let isNowPlaying = menu.activeFullscreenScene?.key == menu.musicNowPlayingFullscreenKey
        transportTop = nil
        let backFrame = CGRect(x: max(insets.left + 16, 38), y: max(insets.top + 10, 32), width: 46, height: 46)
        let back = Wanted(control: .back, frame: backFrame, symbol: "chevron.left", pointSize: 19)
        if let step = menu.onboardingStep {
            // The first-launch screens after the first have Back, whatever the input.
            if step != .theme, menu.onboardingOpacity > 0.5 { wanted = [back] }
        } else if enabled, menu.codeDisplay != nil {
            // A code on screen has nothing else to press.
            wanted = [back]
        } else if enabled, !menu.isMovieTransitioning, menu.textEntry == nil {
            if menu.isMoviePlaybackVisible {
                // With the movie's controls, coming and going together.
                // (Subtitles, audio and speed have buttons of their own, above the bar.)
                if menu.showsMovieControls, menu.shownMovieControlsOpacity > 0.01 {
                    // Over the middle of the picture; standing upright, under the fold.
                    let canvas = FullscreenCanvas(screenSize: size, upright: menu.upright)
                    let spot = canvas.upright.map { canvas.window($0.movieButtonsCenter) }
                    var middle = spot ?? CGPoint(x: size.width / 2, y: size.height / 2)
                    // A video's panel covers the right of the picture: the buttons keep to
                    // the middle of what is left of it, moving over as it comes.
                    middle.x -= YouTubePanelLayer.width(in: canvas.size) * canvas.scale * menu.youtubePanelSpread / 2
                    // Bent at the fold, the picture has the part above it to itself: Back goes
                    // to the top left of the part below, with the rest of the controls.
                    var back = back
                    let isBent = canvas.upright?.isBent == true
                    if let upright = canvas.upright, isBent {
                        let lower = canvas.window(upright.lowerPane)
                        back = Wanted(control: .back, frame: CGRect(x: backFrame.minX, y: lower.minY + 10, width: 46, height: 46), symbol: "chevron.left", pointSize: 19)
                    }
                    wanted = [
                        back,
                        Wanted(control: .skipBack, frame: CGRect(x: middle.x - 36 - 44 - 56, y: middle.y - 28, width: 56, height: 56), symbol: "gobackward.10", pointSize: 22),
                        Wanted(control: .playPause, frame: CGRect(x: middle.x - 36, y: middle.y - 36, width: 72, height: 72), symbol: menu.movieControlsGlyphState == .pause ? "play.fill" : "pause.fill", pointSize: 28),
                        Wanted(control: .skipForward, frame: CGRect(x: middle.x + 36 + 44, y: middle.y - 28, width: 56, height: 56), symbol: "goforward.10", pointSize: 22),
                    ]
                    // While the player waits for more of the movie its pinwheel turns over
                    // the middle of the picture, where the play button is: the button makes way
                    // for it. (Bent at the fold the buttons are under the picture.)
                    if menu.showsMovieBufferingPinwheel, !isBent {
                        wanted.removeAll { $0.control == .playPause }
                    }
                    // Where the panel of subtitles, sound and speed opens over these buttons
                    // (bent at the fold, and across a phone held sideways) they make way for it.
                    if menu.movieOptions != nil {
                        let panel = movieOptionsPanel?.insetBy(dx: -6, dy: -6)
                        if isBent || wanted.contains(where: { $0.control != .back && panel?.intersects($0.frame) == true }) {
                            wanted = [back]
                        }
                    }
                }
                // In a comment's replies Back is at the head of the panel (there whether or
                // not the movie's controls are up: the panel is).
                if let place = videoPanelBack {
                    wanted.removeAll { $0.control == .back }
                    wanted.append(Wanted(control: .panelBack, frame: CGRect(x: place.x - 23, y: place.y - 23, width: 46, height: 46), symbol: "chevron.left", pointSize: 19))
                }
            } else if isNowPlaying {
                let play: CGFloat = 64
                let side: CGFloat = 52
                // With the list or the words beside it, Now Playing moves aside and shrinks; the
                // buttons go with it (at their own size, for fingers).
                let canvas = FullscreenCanvas(screenSize: size, upright: menu.upright)
                let aside = NowPlayingSideLayout.shift(menu: menu, size: canvas.size)
                let (middle, centerY): (CGFloat, CGFloat) = {
                    let bottom = size.height - max(insets.bottom, 10) - 16 - play / 2
                    #if os(iOS)
                        let underBar = true
                    #else
                        // (Only a phone stands upright; the test build stands a window up.)
                        let underBar = canvas.upright != nil
                    #endif
                    if underBar {
                        // On a phone or an iPad, under the progress bar (and its times), clear of
                        // the cover, rather than along the bottom of the screen.
                        if let bar = nowPlayingBar {
                            let canvasScale = canvas.scale
                            // From the bar's middle: the modern bar swells while it's held.
                            let gap = (isModern ? 76 : 44) * canvasScale * nowPlayingScale
                            // With the words beside it, Now Playing is small: the buttons go
                            // along the bottom under it, and stop short of the words. (Standing
                            // upright the words are under the fold, and the buttons stay with
                            // the bar above it.)
                            let besideWords = menu.isNowPlayingLyricsVisible && canvas.upright == nil
                            let centerY = besideWords ? bottom : min(bar.midY + gap + play / 2, bottom)
                            // The whole row on the screen: Previous on the left, the words'
                            // button furthest right.
                            let leftReach = menu.canSwitchMusicNowPlayingTrack ? play / 2 + 36 + side : play / 2
                            var rightReach = menu.canSwitchMusicNowPlayingTrack ? play / 2 + 36 + side : play / 2
                            if menu.hasNowPlayingLyrics { rightReach += 40 + 46 }
                            var rightLimit = size.width - insets.right - 16
                            if besideWords { rightLimit = min(rightLimit, bar.maxX + 24) }
                            transportTop = centerY - play / 2
                            // Kept on the screen where the bar rests; with it all the way
                            // while it slides off or in.
                            let resting = max(min(bar.midX - nowPlayingSlide, rightLimit - rightReach), insets.left + 16 + leftReach)
                            return (resting + nowPlayingSlide, centerY)
                        }
                    }
                    return (size.width / 2 + aside.dx * canvas.scale, bottom)
                }()
                wanted = [
                    back,
                    Wanted(control: .playPause, frame: CGRect(x: middle - play / 2, y: centerY - play / 2, width: play, height: play), symbol: menu.isMusicPlaybackRunningOrStarting() ? "pause.fill" : "play.fill", pointSize: 26, inScene: true),
                ]
                var rightEdge = middle + play / 2
                // Only for something with songs either side (not a single preview).
                if menu.canSwitchMusicNowPlayingTrack {
                    wanted += [
                        Wanted(control: .previous, frame: CGRect(x: middle - play / 2 - 36 - side, y: centerY - side / 2, width: side, height: side), symbol: "backward.fill", pointSize: 20, inScene: true),
                        Wanted(control: .next, frame: CGRect(x: middle + play / 2 + 36, y: centerY - side / 2, width: side, height: side), symbol: "forward.fill", pointSize: 20, inScene: true),
                    ]
                    rightEdge += 36 + side
                }
                // The words, when the song has some.
                if menu.hasNowPlayingLyrics {
                    let small: CGFloat = 46
                    wanted.append(Wanted(control: .lyrics, frame: CGRect(x: rightEdge + 40, y: centerY - small / 2, width: small, height: small), symbol: menu.isNowPlayingLyricsVisible ? "quote.bubble.fill" : "quote.bubble", pointSize: 19, inScene: true))
                }
            } else if menu.activeFullscreenScene?.key == menu.photoSlideshowFullscreenKey {
                // Only for a few seconds after a tap, click or move: the pictures have the screen.
                if menu.areSlideshowControlsVisible, !menu.isFullscreenSceneTransitioning { wanted = [back] }
            } else if menu.activeFullscreenScene != nil, menu.activeFullscreenScene?.key != menu.screenSaverFullscreenKey {
                wanted = [back]
            } else if menu.activeFullscreenScene == nil, menu.isInSubmenu || menu.isMovieResumePromptVisible {
                wanted = [back]
            }
        }

        layer.place(bounds)
        // Now Playing's buttons move with it: they shrink and fade as it goes, and come in
        // with it, without a fade of their own.
        sceneGroup.place(CGRect(origin: .zero, size: size))
        if isNowPlaying {
            let depth = isModern ? menu.fullscreenSceneScale : 1
            sceneTransform = MenuSceneRenderer.scale(depth, about: CGPoint(x: size.width / 2, y: size.height / 2))
            sceneOpacity = menu.fullscreenSceneOpacity * (1 - menu.fullscreenTransitionOverlayOpacity)
            sceneGroup.setTransform(sceneTransform, pass.animation)
            sceneGroup.setOpacity(sceneOpacity, pass.animation)
        }
        // Turning round, Now Playing takes its buttons with it. The classic look's panel turns
        // edge on and back: so do they, about the same line and seen from as far away. The
        // modern look's fades out and back in the other way round: so do they, on its curve.
        let turn = isNowPlaying ? menu.musicNowPlayingFlipRotationDegrees : 0
        let turnAway = min(1, abs(CGFloat(turn)) / 90)
        let isTurning = turnAway != lastTurnAway
        lastTurnAway = turnAway
        let turnFade: Animation? = isTurning ? pass.animation.map { .smoothInOut(duration: $0.duration) } : nil
        let turnOpacity = isModern ? Double(1 - turnAway) : 1
        turnGroup.bounds = CGRect(origin: .zero, size: size)
        turnGroup.position = CGPoint(x: size.width / 2, y: size.height / 2)
        turnGroup.setTransform(isModern ? CATransform3DIdentity : yawTransform(degrees: turn, perspective: 0.9, viewSize: size), pass.animation)
        turnGroup.setOpacity(turnOpacity, turnFade)
        let sceneMoving = menu.isFullscreenSceneTransitioning || !isNowPlaying
        // Slid away, the buttons go below the bottom of the screen, and a bar stays behind.
        let isIdle = isNowPlaying && menu.areNowPlayingTouchControlsHidden
        let transportHidden = isIdle
        transportGroup.place(CGRect(origin: .zero, size: size))
        // From under the progress bar, far enough to leave the screen. A slide away under way
        // keeps to where it set out for: the bar moving meanwhile would cut it short.
        let now = CACurrentMediaTime()
        let drop = transportHidden && now < transportSlideEnds ? transportSlideDrop :
            max(64 + max(insets.bottom, 10) + 40, transportTop.map { size.height - $0 + 12 } ?? 0)
        // Their own slide, whatever else is moving.
        let slide: Animation? = transportHidden == lastTransportHidden ? pass.animation : (transportHidden ? .smoothInOut(duration: 0.45) : .smooth(duration: 0.4))
        if transportHidden != lastTransportHidden {
            transportSlideEnds = now + (slide?.duration ?? 0)
            transportSlideDrop = drop
        }
        lastTransportHidden = transportHidden
        transportGroup.setTransform(transportHidden ? CATransform3DMakeTranslation(0, drop, 0) : CATransform3DIdentity, slide)
        transportGroup.setOpacity(transportHidden ? 0 : 1, slide)
        transportHint.update(
            frame: CGRect(x: size.width / 2 - 40, y: size.height - max(insets.bottom, 8) - 16, width: 80, height: 5),
            shown: enabled && isIdle && menu.nowPlayingQueueReveal <= 0.001 && !menu.isFullscreenSceneTransitioning && menu.showsPointingHints,
            drift: CGSize(width: 0, height: -9),
            session: menu.nowPlayingSession,
        )
        // At the screen's edge, where the list comes out, half way down it (under the fold,
        // standing upright). Right at the edge whichever way round the phone is held: not in
        // from it by that side's safe area, which is wide on the side the sensor housing is
        // and put the bar over Now Playing.
        let queueHintY = menu.upright.map { FullscreenCanvas(screenSize: size, upright: $0).window($0.lowerPane).midY } ?? size.height / 2
        queueHint.update(
            frame: CGRect(x: size.width - 24, y: queueHintY - 40, width: 5, height: 80),
            shown: isNowPlaying && menu.canShowNowPlayingQueue && menu.nowPlayingQueueReveal <= 0.001 && !menu.isNowPlayingLyricsVisible && menu.nowPlayingWordsGlide == nil &&
                !menu.isFullscreenSceneTransitioning && menu.showsPointingHints && menu.onboardingStep == nil,
            drift: CGSize(width: -9, height: 0),
            session: menu.nowPlayingSession,
        )

        frames = [:]
        // The modern look on systems with Liquid Glass: the system's own glass buttons.
        #if os(iOS) || os(macOS) || os(tvOS)
            if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *), let native = NativeControls.shared {
                if isModern {
                    #if os(macOS)
                        makeButtonsAhead(size: size)
                    #endif
                    for (_, button) in buttons where button.isShown {
                        hide(button, instantly: true)
                    }
                    var items: [NativeControls.Item] = []
                    var instant: Set<NativeControls.Key> = []
                    for item in wanted {
                        #if os(iOS)
                            let dimmedAlpha: CGFloat = 0.3
                        #else
                            let dimmedAlpha: CGFloat = 0
                        #endif
                        items.append(NativeControls.Item(
                            control: item.control,
                            inScene: item.inScene,
                            frame: item.frame,
                            symbol: item.symbol,
                            pointSize: item.pointSize,
                            dimmed: item.control == .back && isIdle,
                            dimmedAlpha: dimmedAlpha,
                        ))
                        if !(item.inScene && transportHidden) { frames[item.control] = item.frame }
                    }
                    for key in buttons.keys.map({ NativeControls.Key(control: $0.control, inScene: $0.inScene) }) + wanted.map({ NativeControls.Key(control: $0.control, inScene: $0.inScene) })
                        where putAwayForKeys || (key.inScene && sceneMoving)
                    {
                        instant.insert(key)
                    }
                    native.update(
                        items: items,
                        size: size,
                        sceneTransform: sceneTransform,
                        sceneOpacity: sceneOpacity * turnOpacity,
                        sceneAnimation: isTurning ? turnFade : pass.animation,
                        transportHidden: transportHidden,
                        transportDrop: drop,
                        transportAnimation: slide,
                        appear: Self.appear,
                        disappear: Self.disappear,
                        instantly: instant,
                    )
                    return
                }
                native.hideAll(animation: nil)
            }
        #endif
        let shown = Set(wanted.map { Key(control: $0.control, inScene: $0.inScene) })
        for (key, button) in buttons where button.isShown && !shown.contains(key) {
            hide(button, instantly: putAwayForKeys || (key.inScene && sceneMoving))
        }
        for item in wanted {
            let key = Key(control: item.control, inScene: item.inScene)
            let button = buttons[key] ?? {
                let made = Button()
                (item.inScene ? transportGroup : layer).addSublayer(made.base)
                buttons[key] = made
                return made
            }()
            let frame = item.frame
            if button.base.frame != frame {
                // Following the progress bar as Now Playing moves aside for the words.
                if item.inScene, button.isShown, !sceneMoving {
                    button.base.setFrame(frame, pass.animation)
                } else {
                    button.base.place(frame)
                }
            }
            let local = CGRect(origin: .zero, size: frame.size)
            let radius = frame.height / 2
            let fill = isModern ? CGColor(gray: 0.2, alpha: 0.72) : CGColor(gray: 0, alpha: 0.6)
            button.sharp.frame = local
            button.sharp.cornerRadius = radius
            button.sharp.backgroundColor = fill
            button.sharp.borderWidth = isModern ? 0 : 1
            button.sharp.borderColor = CGColor(gray: 1, alpha: 0.35)
            button.sharp.shadowColor = CGColor(gray: 0, alpha: 1)
            button.sharp.shadowOpacity = 0.35
            button.sharp.shadowRadius = 10
            button.sharp.shadowPath = CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let graphic = SymbolRenderer.render(item.symbol, pointSize: item.pointSize, weight: .semibold, color: .white, scale: scale)
            var parts: [(RenderedGraphic, CGPoint)] = []
            if let label = item.label {
                // A capsule: the symbol, then the words.
                let glyphOrigin = CGPoint(x: 18 + (22 - graphic.size.width) / 2, y: ((frame.height - graphic.size.height) / 2).rounded())
                let labelOrigin = CGPoint(x: 18 + 22 + 8, y: ((frame.height - label.size.height) / 2).rounded())
                button.glyph.show(graphic, at: glyphOrigin)
                button.label.isHidden = false
                button.label.show(label, at: labelOrigin)
                parts = [(graphic, glyphOrigin), (label, labelOrigin)]
            } else {
                // Play's triangle looks centred a touch to the right of its box's middle.
                let nudge: CGFloat = item.symbol == "play.fill" ? item.pointSize * 0.06 : 0
                let glyphOrigin = CGPoint(x: (frame.width - graphic.size.width) / 2 + nudge, y: (frame.height - graphic.size.height) / 2)
                button.glyph.show(graphic, at: glyphOrigin)
                button.label.isHidden = true
                parts = [(graphic, glyphOrigin)]
            }
            let blurKey = "\(item.symbol)|\(frame.size.width)|\(frame.size.height)|\(isModern)|\(item.label.flatMap(\.identity).map(String.init(describing:)) ?? "")"
            if button.blurKey != blurKey {
                button.blurKey = blurKey
                button.blurred.frame = local.insetBy(dx: -Self.blurMargin, dy: -Self.blurMargin)
                // Made on another thread (out of the symbol, which may still be being drawn
                // there): the button is only starting to fade in when it comes.
                Self.blurredButton(size: frame.size, fill: fill, border: !isModern, parts: parts) { image in
                    guard button.blurKey == blurKey else { return }
                    withoutLayerActions { button.blurred.contents = image }
                }
            }
            // Slid away, they can't be pressed.
            if !(item.inScene && transportHidden) { frames[item.control] = frame }
            if !button.isShown { show(button, instantly: item.inScene && sceneMoving) }
            // Back stays while Now Playing sits untouched, faded back with the rest away (for
            // the mouse, all the way: the pointer moving brings it back).
            let dims = item.control == .back && isIdle
            if dims != button.isDimmed {
                button.isDimmed = dims
                #if os(iOS)
                    let dimmed: Double = 0.3
                #else
                    let dimmed: Double = 0
                #endif
                button.base.setOpacity(dims ? dimmed : 1, dims ? .smoothInOut(duration: 0.5) : .smooth(duration: 0.35))
            }
        }
    }

    #if os(macOS)
        /// Starts making the usual glass buttons ahead, if that hasn't been done: one every
        /// so often, at a moment when nothing on screen has changed for half a second.
        private func makeButtonsAhead(size: CGSize) {
            guard !hasMadeButtonsAhead, aheadTimer == nil else { return }
            aheadTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible {
                    guard let self, #available(macOS 26.0, *), let native = NativeControls.shared else { return }
                    guard CACurrentMediaTime() - self.lastUpdate > 0.5 else { return }
                    for button in Self.usualButtons {
                        let item = NativeControls.Item(
                            control: button.control, inScene: button.inScene, frame: CGRect(x: 0, y: 0, width: button.side, height: button.side),
                            symbol: button.symbol, pointSize: button.pointSize, dimmed: false, dimmedAlpha: 1,
                        )
                        // One a turn.
                        if native.makeAhead(item, size: size) { return }
                    }
                    self.hasMadeButtonsAhead = true
                    self.aheadTimer?.invalidate()
                    self.aheadTimer = nil
                }
            }
        }
    #endif

    /// Fades a button in from its blurred copy (or puts it straight up, when what it belongs
    /// to is fading in anyway).
    private func show(_ button: Button, instantly: Bool) {
        button.isShown = true
        button.isDimmed = false
        button.fadeGeneration += 1
        let fresh = button.base.isHidden || button.base.opacity < 0.01
        button.base.isHidden = false
        if instantly {
            button.base.setOpacity(1, nil)
            button.sharp.setOpacity(1, nil)
            button.blurred.setOpacity(0, nil)
            return
        }
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
    private func hide(_ button: Button, instantly: Bool) {
        button.isShown = false
        button.isDimmed = false
        button.fadeGeneration += 1
        if instantly {
            button.base.setOpacity(0, nil)
            button.base.isHidden = true
            return
        }
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

    private static var blurCache: [String: CGImage] = [:]
    private nonisolated static let blurSigma: CGFloat = 7
    /// The room round a button that its blurred copy spreads into.
    private nonisolated static let blurMargin = (blurSigma * 3).rounded(.up)

    /// The button drawn soft, as if out of focus: its circle and symbol under a near-Gaussian
    /// blur, with room around them (`blurMargin`) for the blur to spread into. Made on another
    /// thread, and handed to `show` on this one: at once when it has been made before.
    private static func blurredButton(size: CGSize, fill: CGColor, border: Bool, parts: [(RenderedGraphic, CGPoint)], then show: @escaping @MainActor (CGImage?) -> Void) {
        #if !FIRSTROW_PORTABLE
            let key = "\(size.width)|\(size.height)|\(border)|" + parts.map { "\($0.0.identity.map(String.init(describing:)) ?? "")@\($0.1.x),\($0.1.y)" }.joined(separator: "|")
            if let cached = blurCache[key] {
                show(cached)
                return
            }
            let margin = blurMargin
            LetteringInProgress.queue.async {
                let image = drawBlurredButton(size: size, fill: fill, border: border, parts: parts, margin: margin)
                DispatchQueue.main.async {
                    MainActor.assumeIsolatedIfPossible {
                        if blurCache.count > 40 { blurCache.removeAll() }
                        if let image { blurCache[key] = image }
                        show(image)
                    }
                }
            }
        #endif
    }

    #if !FIRSTROW_PORTABLE
        /// Draws and blurs the button (any thread: it waits for parts still being drawn).
        private nonisolated static func drawBlurredButton(size: CGSize, fill: CGColor, border: Bool, parts: [(RenderedGraphic, CGPoint)], margin: CGFloat) -> CGImage? {
            // Drawn at a point a pixel: blurred, it needs no more.
            let pixels: CGFloat = 1
            let sigma = blurSigma
            let width = Int((size.width + margin * 2) * pixels)
            let height = Int((size.height + margin * 2) * pixels)
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
            ) else { return nil }
            context.scaleBy(x: pixels, y: pixels)
            let shape = CGRect(x: margin, y: margin, width: size.width, height: size.height)
            let corner = size.height / 2
            context.setFillColor(fill)
            context.addPath(CGPath(roundedRect: shape, cornerWidth: corner, cornerHeight: corner, transform: nil))
            context.fillPath()
            if border {
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
                context.setLineWidth(1)
                let inner = shape.insetBy(dx: 0.5, dy: 0.5)
                context.addPath(CGPath(roundedRect: inner, cornerWidth: corner - 0.5, cornerHeight: corner - 0.5, transform: nil))
                context.strokePath()
            }
            for (graphic, origin) in parts {
                guard let image = graphic.image else { continue }
                // Bitmap y is up: flip the top-left placement.
                let box = graphic.imageFrame(at: origin)
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
            return context.makeImage()
        }

        /// Averages each pixel with `radius` on either side along a line of `count` pixels
        /// `stride` bytes apart (all four channels), treating what lies beyond as clear.
        private nonisolated static func boxBlur(_ start: UnsafeMutablePointer<UInt8>, count: Int, stride: Int, radius: Int) {
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

    #endif

    private static var safeAreaInsets: (left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
        #if os(iOS)
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }
            // The drawing's own: on the top half of a half-folded screen, the bottom edge's
            // inset is on the other half.
            let drawing = (window?.rootViewController as? FirstRowViewController)?.drawingView
            let insets = drawing?.safeAreaInsets ?? window?.safeAreaInsets ?? .zero
            return (insets.left, insets.top, insets.right, insets.bottom)
        #else
            return (0, 0, 0, 0)
        #endif
    }

    /// The button under a window point, with a little room around each for fingers.
    func control(at point: CGPoint) -> TouchControl? {
        frames.first { $0.value.insetBy(dx: -8, dy: -8).contains(point) }?.key
    }
}
