import AVFoundation
import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// Draws First Row's whole interface from `MenuView`'s state with Core Animation layers.
@MainActor
final class MenuSceneRenderer: TransactionRendering {
    let menu: MenuView
    /// Fills the window (origin top left).
    let rootLayer = SceneLayer()

    // The menu scene: a fixed-size canvas scaled to fit the screen.
    private let canvas = SceneLayer()
    private let sceneContent = SceneLayer()
    private let rootHeader = HeaderLayer()
    private let submenuHeader = HeaderLayer()
    private let carouselBox = SceneLayer()
    private let detailContent: GapContentLayer
    /// Undoes the scene's flipped geometry for the carousel, which lays itself out bottom-up on macOS.
    private let carouselSpace = SceneLayer()
    private let rootCarousel = RootCarouselLayerController()
    private var lastCarouselConfiguration: RootCarouselConfiguration?
    private let settledIcon = SceneLayer()
    private let menuArea = SceneLayer()
    /// The titles and lists together, which the modern look fades and slides as menus change.
    private let menuGroup = SceneLayer()
    private let rootList = MenuListLayer()
    private let submenuList = MenuListLayer()
    private let thirdList = MenuListLayer()
    private let sortPill = SceneLayer()
    private let resumePrompt = MovieResumePromptLayer()
    // The modern look's backdrop and card.
    private let modernBackground = ModernBackgroundLayer()
    private let modernCard = ModernCardLayer()
    /// YouTube's search screen: its field and keys, where the carousel or the card would be.
    private let youtubeSearchPad = YouTubeSearchPadLayer()
    private let textEntry = TextEntryLayer()

    // Full-screen layers, sized to the window.
    private let playback = MoviePlaybackLayers()
    private let fullscreenScene: FullscreenSceneLayer
    private let toast = ScreenSaverToastLayer()
    private let volumeOverlay = VolumeOverlayLayer()
    let touchControls = TouchControlsLayer()
    let onboarding = OnboardingLayer()
    private let folderSwapOverlay = SceneLayer()
    private let movieTransitionOverlay = SceneLayer()
    private let fullscreenTransitionOverlay = SceneLayer()
    private let startupOverlay = SceneLayer()

    private(set) var containerSize: CGSize = .zero
    private(set) var backingScale: CGFloat = 2
    private var canvasScale: CGFloat = 1
    private var isDirty = true
    /// Set when a pass skipped the carousel, which takes the run loop pass's changes together.
    private var carouselNeedsUpdate = true
    private var observation: Any?
    private var settingsObserver: NSObjectProtocol?
    private var flushObserver: RunLoopFlushObserver?
    private var memo = RenderMemo()
    private var lastCardUpdate: CFTimeInterval = 0
    private var isCardRefreshScheduled = false
    private var wasSweeping = false
    private var shownCardContent: ModernCardContent?
    private var glyphHoldStart: CFTimeInterval?
    private var isGlyphHoldRefreshScheduled = false
    private static let cardGlyphHold: CFTimeInterval = 0.7

    /// Values from the previous pass, for the parts that animate when one particular value changes.
    private struct RenderMemo {
        var headerOpacity: Double?
        var submenuTitleOpacity: Double?
        var hidesPodcastsChrome: Bool?
        var hidesSubmenuList: Bool?
        var hidesThirdList: Bool?
        var showsSortPill: Bool?
        var showsSubmenuHeader: Bool?
        var showsSubmenuList = false
        var showsThirdList = false
        var sortMode: MenuView.TVShowsSortMode?
        var theme: InterfaceTheme?
        var sortPillTheme: InterfaceTheme?
    }

    init(menu: MenuView) {
        self.menu = menu
        detailContent = GapContentLayer()
        fullscreenScene = FullscreenSceneLayer()
        buildLayerTree()
        observation = menu.objectWillChange.sink { [weak self] _ in
            self?.isDirty = true
        }
        settingsObserver = NotificationCenter.default.addObserver(forName: AppSettings.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible { self?.isDirty = true }
        }
        flushObserver = RunLoopFlushObserver { [weak self] in
            self?.renderAtEndOfRunLoopPass()
        }
        RenderScheduler.register(self)
        RenderWarmUp.start()
    }

    func invalidate() {
        flushObserver?.invalidate()
        flushObserver = nil
        RenderScheduler.unregister(self)
        fullscreenScene.tearDown()
        volumeOverlay.tearDown()
        detailContent.tearDown()
        rootCarousel.tearDown()
    }

    private func buildLayerTree() {
        rootLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        rootLayer.masksToBounds = true
        rootLayer.addSublayer(modernBackground.layer)
        rootLayer.addSublayer(canvas)
        canvas.addSublayer(sceneContent)
        sceneContent.addSublayer(carouselBox)
        sceneContent.addSublayer(modernCard.layer)
        modernCard.layer.isHidden = true
        sceneContent.addSublayer(youtubeSearchPad.layer)
        carouselBox.addSublayer(detailContent.layer)
        carouselBox.addSublayer(carouselSpace)
        #if os(macOS) || FIRSTROW_PORTABLE
            carouselSpace.isGeometryFlipped = true
        #endif
        carouselSpace.addSublayer(rootCarousel.rootLayer)
        settledIcon.contentsGravity = .resizeAspect
        settledIcon.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        carouselBox.addSublayer(settledIcon)
        sceneContent.addSublayer(menuGroup)
        menuGroup.addSublayer(rootHeader.layer)
        menuGroup.addSublayer(submenuHeader.layer)
        menuGroup.addSublayer(menuArea)
        menuArea.addSublayer(rootList.layer)
        menuArea.addSublayer(submenuList.layer)
        menuArea.addSublayer(thirdList.layer)
        menuArea.addSublayer(sortPill)
        sortPill.opacity = 0
        canvas.addSublayer(resumePrompt.layer)
        canvas.addSublayer(textEntry.layer)

        rootLayer.addSublayer(playback.group)
        rootLayer.addSublayer(fullscreenScene.layer)
        rootLayer.addSublayer(toast.layer)
        for overlay in [folderSwapOverlay, movieTransitionOverlay, fullscreenTransitionOverlay, startupOverlay] {
            overlay.backgroundColor = CGColor(gray: 0, alpha: 1)
            overlay.opacity = 0
            overlay.isHidden = true
            rootLayer.addSublayer(overlay)
        }
        rootLayer.addSublayer(onboarding.layer)
        rootLayer.addSublayer(touchControls.layer)
        rootLayer.addSublayer(volumeOverlay.layer)
    }

    /// The window changed size or moved to a screen with a different pixel density.
    func layout(containerSize: CGSize, backingScale: CGFloat) {
        guard containerSize.width > 0, containerSize.height > 0 else { return }
        self.containerSize = containerSize
        self.backingScale = backingScale
        modernBackground.layout(size: containerSize)
        layingOut {
            rootLayer.frame = CGRect(origin: .zero, size: containerSize)
            let virtualSize = menu.activeMenuVirtualSceneSize
            canvas.bounds = CGRect(origin: .zero, size: virtualSize)
            #if os(iOS)
                // The whole scene fits: by height on wide phones, by width on squarer screens.
                let scale = min(containerSize.height / virtualSize.height, containerSize.width / virtualSize.width)
                // Still upright (turning to landscape as it opens), it keeps its place for the
                // screen's landscape width. Otherwise it's the drawing's own: all of the screen, or
                // the top half of a half-folded one.
                let screenBounds = menu.activeWindowScreen?.bounds ?? .zero
                let deviceLandscapeWidth = max(screenBounds.width, screenBounds.height)
                let isTurning = menu.upright == nil && containerSize.width < containerSize.height
                let horizontalCompensation = isTurning ? max(0, (deviceLandscapeWidth - containerSize.width) * 0.5) : 0
                let fittedWidth = virtualSize.width * scale
                canvas.position = CGPoint(x: (containerSize.width - fittedWidth) * 0.5 - horizontalCompensation, y: (containerSize.height - virtualSize.height * scale) * 0.5)
            #else
                let fit = MenuVirtualSceneLayout(containerSize: containerSize, virtualSize: virtualSize)
                let scale = fit.scale
                canvas.position = CGPoint(x: fit.offset.width, y: fit.offset.height)
            #endif
            canvasScale = scale
            canvas.transform = CATransform3DMakeScale(scale, scale, 1)
            sceneContent.place(canvas.bounds)
        }
        isDirty = true
        render(Transaction.instant)
        // The carousel usually waits for the end of the run-loop pass, which is after a glide's.
        if LayoutGlide.isActive, !ModernTheme.isActive {
            CATransaction.begin()
            updateCarousel()
            CATransaction.commit()
        }
    }

    // MARK: - Drawing

    func render(_ transaction: Transaction) {
        guard isDirty, containerSize != .zero else { return }
        isDirty = false
        carouselNeedsUpdate = true
        CATransaction.begin()
        defer { CATransaction.commit() }
        update(RenderPass(transaction: transaction), includesCarousel: false)
    }

    /// Draws plain changes and updates the carousel, whose timings depend on what changed together.
    /// Each pass is one transaction so its changes reach the screen together.
    private func renderAtEndOfRunLoopPass() {
        guard containerSize != .zero else { return }
        CATransaction.begin()
        defer { CATransaction.commit() }
        if isDirty {
            isDirty = false
            update(RenderPass(transaction: Transaction()), includesCarousel: true)
            #if os(macOS)
                ProMotionPacer.shared.resumeIfNeeded()
            #endif
        } else if carouselNeedsUpdate, !ModernTheme.isActive {
            updateCarousel()
        }
        carouselNeedsUpdate = false
    }

    /// Redraws everything on the next pass.
    func setNeedsRender() {
        isDirty = true
    }

    /// The scale the cover decoder was last told of.
    private var notedArtworkScale: CGFloat = 0
    /// Whether the classic look's stand-in pictures have been unpacked ahead of use.
    private var hasUnpackedStandIns = false

    /// Pixels per scene point, rounded up to 0.01 so cached text is reused but never undersized.
    private var textScale: CGFloat {
        max(1, (canvasScale * backingScale * 100).rounded(.up) / 100)
    }

    #if DEBUG || FIRSTROW_HARNESS_BUILD
        /// `FIRSTROW_DEBUG_RENDER=1`: how long each pass takes, printed every second or so.
        private static let timesPasses = ProcessInfo.processInfo.environment["FIRSTROW_DEBUG_RENDER"] == "1"
        private var passTimes: [Double] = []
        private var sectionTimes: [String: Double] = [:]
        private var sectionStart: CFTimeInterval = 0
        private func lap(_ name: String) {
            guard Self.timesPasses else { return }
            let now = CACurrentMediaTime()
            sectionTimes[name, default: 0] += (now - sectionStart) * 1000
            sectionStart = now
        }
    #else
        @inline(__always) private func lap(_: String) {}
    #endif

    private func update(_ pass: RenderPass, includesCarousel: Bool) {
        #if DEBUG || FIRSTROW_HARNESS_BUILD
            let started = CACurrentMediaTime()
            sectionStart = started
            defer {
                if Self.timesPasses {
                    lap("rest")
                    passTimes.append((CACurrentMediaTime() - started) * 1000)
                    if passTimes.count >= 30 {
                        let sorted = passTimes.sorted()
                        let sections = sectionTimes.sorted { $0.key < $1.key }.map { String(format: "%@ %.2f", $0.key, $0.value / Double(sorted.count)) }.joined(separator: ", ")
                        let line = String(format: "[render] %d passes: median %.2f ms, worst %.2f ms (mean %@)", sorted.count, sorted[sorted.count / 2], sorted.last ?? 0, sections)
                        FileHandle.standardError.write(Data((line + "\n").utf8))
                        #if os(iOS)
                            FirstRowHarness.touchLog(line)
                        #endif
                        passTimes.removeAll()
                        sectionTimes.removeAll()
                    }
                }
            }
        #endif
        // Lettering first asked for in this pass is drawn on other threads meanwhile, and put
        // on its layers as the pass ends (before the pass's time is taken, above).
        LetteringInProgress.beginPass()
        defer { LetteringInProgress.endPass() }
        let menu = menu
        menu.keepMusicSubmenuSelectionOnItsRow()
        let sceneSize = menu.activeMenuVirtualSceneSize
        let frames = menu.sceneFrames(sceneSize: sceneSize)
        let scale = textScale
        if scale != notedArtworkScale {
            notedArtworkScale = scale
            DisplayArtworkSize.noteScale(scale)
        }
        let theme = AppSettings.theme
        let isModern = theme == .modern
        let themeChanged = memo.theme != nil && memo.theme != theme
        if !isModern, !hasUnpackedStandIns {
            // The classic look's stand-in covers and icons, which first show part way into
            // a menu: unpacked before then (on the Mac, once the screen's colours are known).
            #if os(macOS)
                let isReady = ScreenColorSpace.current != nil
            #else
                let isReady = true
            #endif
            if isReady {
                hasUnpackedStandIns = true
                LayerImageCache.unpackAhead(named: ["musicfallback", "moviesfallback", "Podcast", "TVShow", "AudioBook", "PhotoSettingsIcon"])
            }
        }
        memo.theme = theme
        sceneContent.setOpacity(menu.menuOpacityOnScreen, pass.animation)
        sceneContent.setTransform(Self.scale(isModern ? menu.menuSceneScale : 1, about: CGPoint(x: sceneSize.width * 0.5, y: sceneSize.height * 0.5)), pass.animation)
        menuGroup.place(CGRect(origin: .zero, size: sceneSize))
        menuGroup.setOpacity(isModern ? menu.modernSwapOpacity : 1, pass.animation)
        menuGroup.setTransform(CATransform3DMakeTranslation(isModern ? menu.modernSwapOffset : 0, 0, 0), pass.animation)

        lap("setup")
        updateHeaders(pass, sceneSize: sceneSize, frames: frames, scale: scale)
        lap("headers")

        // The carousel and the section's preview content, or in the modern look the card.
        // (YouTube's search screen has its keys where the card is. In the classic look the
        // preview makes way for them itself, and the section's icon stays by the title.)
        let showsSearchPad = menu.youtubeSearchPad != nil
        carouselBox.isHidden = isModern
        modernCard.layer.isHidden = !isModern || showsSearchPad
        youtubeSearchPad.update(menu: menu, pass: pass, sceneSize: sceneSize, menuLeft: frames.menuFrame.minX, scale: scale)
        modernBackground.layer.isHidden = !isModern
        if isModern {
            ModernTheme.preparePlaceholders()
            // While a held arrow or a sliding finger races through a list, the card and the
            // background follow once it pauses rather than for every row it passes.
            let now = CACurrentMediaTime()
            let sweeping = menu.activeDirectionalHoldKey != .none || menu.isTouchSelecting
            // The first row of a sweep (where a finger lands) shows at once.
            let sweepStarts = sweeping && !wasSweeping
            wasSweeping = sweeping
            if !sweeping || sweepStarts || now - lastCardUpdate > 0.25 || themeChanged {
                let layout = ModernTheme.layout(sceneSize: sceneSize, menuHeight: frames.menuFrame.height)
                var content = menu.modernCardContent(sceneSize: sceneSize, pass: pass)
                // A menu's own picture (a list's first cover, say) can take a moment to load.
                // Rather than flash the section's symbol meanwhile, the picture before stays a
                // little while for it.
                if case .glyph = content, menu.isInSubmenu, !menu.isReturningToRoot, let shown = shownCardContent, !shown.isGlyph {
                    let since = glyphHoldStart ?? now
                    glyphHoldStart = since
                    if now - since < Self.cardGlyphHold {
                        content = shown
                        if !isGlyphHoldRefreshScheduled {
                            isGlyphHoldRefreshScheduled = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + Self.cardGlyphHold + 0.02) { [weak self] in
                                MainActor.assumeIsolatedIfPossible {
                                    self?.isGlyphHoldRefreshScheduled = false
                                    self?.lastCardUpdate = 0
                                    self?.isDirty = true
                                }
                            }
                        }
                    }
                } else {
                    glyphHoldStart = nil
                }
                shownCardContent = content
                modernCard.layer.frame = CGRect(origin: .zero, size: sceneSize)
                // Always a crossfade, even when the menus change in an instant pass (going back
                // swaps the list in one), so the picture never just switches.
                let pane = menu.upright?.upperPane
                modernCard.update(content, frame: pane.map(ModernTheme.uprightCardFrame) ?? layout.cardFrame, pane: pane, scale: scale, animated: !themeChanged)
                let ambient = content.ambientImage
                modernBackground.setAmbient(ambient, key: ambient == nil ? nil : content.key)
                lastCardUpdate = now
            } else if !isCardRefreshScheduled {
                isCardRefreshScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    MainActor.assumeIsolatedIfPossible {
                        self?.isCardRefreshScheduled = false
                        self?.lastCardUpdate = 0
                        self?.isDirty = true
                    }
                }
            }
        } else if themeChanged {
            lastCarouselConfiguration = nil
        }
        // The box is drawn smaller on a screen standing upright, about its top left corner.
        let boxScale = max(frames.carouselScale, 0.0001)
        carouselBox.place(frames.carouselFrame)
        carouselBox.setTransform(CATransform3DMakeScale(boxScale, boxScale, 1), nil)
        let boxBounds = CGRect(origin: .zero, size: frames.carouselFrame.size)
        carouselSpace.frame = boxBounds
        rootCarousel.rootLayer.frame = boxBounds
        if !isModern, includesCarousel || lastCarouselConfiguration == nil {
            updateCarousel()
        }
        detailContent.layer.frame = boxBounds
        let hidesChrome = menu.shouldHidePodcastsSubmenuChromeUntilLoadCompletes
        detailContent.update(
            menu: menu,
            pass: pass,
            visible: menu.isInSubmenu && !isModern,
            opacity: menu.detailContentVisibilityOpacity,
            opacityAnimation: pass.animation(.easeInOut(duration: 0.22), when: memo.hidesPodcastsChrome != nil && memo.hidesPodcastsChrome != hidesChrome),
            // The scene as the box's own points see it.
            sceneSize: CGSize(width: sceneSize.width / boxScale, height: sceneSize.height / boxScale),
            boxFrame: CGRect(
                x: frames.carouselFrame.minX / boxScale,
                y: frames.carouselFrame.minY / boxScale,
                width: frames.carouselFrame.width,
                height: frames.carouselFrame.height,
            ),
            show: frames.show,
            scale: scale * boxScale,
        )

        lap("card")
        // The menu lists. One clicked into a player takes up its usual scroll once the player
        // covers it, not while it's still in view.
        if menu.pointer.clearsPinOnceCovered, menu.isPlayerCoveringMenus() {
            menu.pointer.clearPin()
        }
        menuArea.frame = frames.menuFrame
        updateLists(pass, sceneSize: sceneSize, frames: frames, scale: scale)
        lap("lists")

        // Movie resume prompt over the scene.
        resumePrompt.update(menu: menu, pass: pass, sceneSize: sceneSize, scale: scale)
        textEntry.update(menu: menu, pass: pass, sceneSize: sceneSize, scale: scale)

        // Full-screen layers.
        let fullBounds = CGRect(origin: .zero, size: fullscreenContainerSize)
        playback.update(menu: menu, pass: pass, bounds: fullBounds, scale: backingScale)
        fullscreenScene.update(menu: menu, pass: pass, bounds: fullBounds, scale: backingScale)
        toast.update(menu: menu, pass: pass, bounds: fullBounds, backingScale: backingScale)
        volumeOverlay.layout(screenSize: fullBounds.size, upright: menu.upright, backingScale: backingScale)
        onboarding.update(menu: menu, pass: pass, bounds: fullBounds, scale: backingScale)
        let canvasScale = fullscreenCanvas.scale
        touchControls.update(
            menu: menu,
            pass: pass,
            bounds: fullBounds,
            scale: backingScale,
            nowPlayingBar: fullscreenScene.nowPlayingBarPlace.map {
                CGRect(x: $0.minX * canvasScale, y: $0.minY * canvasScale, width: $0.width * canvasScale, height: $0.height * canvasScale)
            },
            nowPlayingScale: fullscreenScene.nowPlayingDetailsScale,
            nowPlayingSlide: fullscreenScene.nowPlayingDetailsSlide * canvasScale,
            movieOptionsPanel: playback.options.panelFrame.map {
                CGRect(x: $0.minX * canvasScale, y: $0.minY * canvasScale, width: $0.width * canvasScale, height: $0.height * canvasScale)
            },
            videoPanelBack: playback.panel.backPlace.map { CGPoint(x: $0.x * canvasScale, y: $0.y * canvasScale) },
        )
        for (overlay, opacity) in [
            (folderSwapOverlay, menu.menuFolderSwapOverlayOpacity),
            (movieTransitionOverlay, menu.movieTransitionOverlayOpacity),
            (fullscreenTransitionOverlay, menu.fullscreenTransitionOverlayOpacity),
            (startupOverlay, menu.startupMusicLibraryPreloadOverlayOpacity),
        ] {
            overlay.frame = fullBounds
            overlay.isHidden = false
            overlay.setOpacity(opacity, pass.animation)
        }
        memo.hidesPodcastsChrome = hidesChrome
    }

    /// The canvas the full-screen layers are laid out on.
    var fullscreenCanvas: FullscreenCanvas {
        FullscreenCanvas(screenSize: fullscreenContainerSize, upright: menu.upright)
    }

    private var fullscreenContainerSize: CGSize {
        #if os(iOS)
            // The screen's landscape size only while still upright, turning as it opens.
            let resolved = menu.activeFullscreenContainerSize
            if menu.upright == nil, containerSize.width < containerSize.height, resolved.width > 0, resolved.height > 0 { return resolved }
        #endif
        return containerSize
    }

    private func updateCarousel() {
        let sceneSize = menu.activeMenuVirtualSceneSize
        var configuration = menu.rootCarouselConfiguration(sceneSize: sceneSize)
        // On screens wider than the scene there is room left of it; icons leave past the screen's edge.
        let frames = menu.sceneFrames(sceneSize: sceneSize, classicLayout: true)
        configuration.boxOriginInScene.x += canvas.position.x / max(canvasScale * frames.carouselScale, 0.0001)
        let bounds = frames.carouselFrame.size
        if let last = lastCarouselConfiguration, last.isSameState(as: configuration) {
            return
        }
        lastCarouselConfiguration = configuration
        rootCarousel.update(configuration, bounds: bounds)
        // The section's own icon stands in for the carousel's once it has landed by the title.
        if menu.showsSettledLandedIcon, let rootID = menu.activeRootItemID, let image = menu.menuImage(forRootID: rootID) {
            let side = menu.iconSize * menu.selectedCarouselAdjustedSizeMultiplier
            settledIcon.isHidden = false
            settledIcon.contents = LayerImageCache.cgImage(for: image)
            settledIcon.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            settledIcon.position = CGPoint(
                x: bounds.width * 0.5 + configuration.landedOffset.x,
                y: side * 0.5 + configuration.landedOffset.y,
            )
            settledIcon.transform = CATransform3DMakeScale(configuration.landedIconScale, configuration.landedIconScale, 1)
        } else {
            settledIcon.isHidden = true
            settledIcon.contents = nil
        }
    }

    private func updateHeaders(_ pass: RenderPass, sceneSize: CGSize, frames: MenuSceneFrames, scale: CGFloat) {
        let showsSubmenuHeader = menu.isInSubmenu && menu.activeRootItemID != nil
        let switched = memo.showsSubmenuHeader != nil && memo.showsSubmenuHeader != showsSubmenuHeader
        let transition = switched ? pass.animation : nil
        let isModern = ModernTheme.isActive
        let graphic = isModern
            ? TextRenderer.render(TextSpec(text: menu.headerText, fontName: ModernTheme.boldFontName, size: ModernTheme.titleSize, color: ModernTheme.title, maxWidth: sceneSize.width - 240), scale: scale)
            : TextRenderer.render(TextSpec(text: menu.headerText, fontName: firstRowBoldFontName, size: 60, maxWidth: sceneSize.width), scale: scale)
        let hidesChrome = menu.shouldHidePodcastsSubmenuChromeUntilLoadCompletes

        // Main menu title, over the middle of the list's selection.
        rootHeader.setPresent(!showsSubmenuHeader, transition)
        if !showsSubmenuHeader {
            let centerX = sceneSize.width * 0.5 + menu.rootMenuHeaderOffsetX(sceneSize: sceneSize)
            rootHeader.show(graphic, centerX: centerX, top: frames.headerTop)
            let changed = memo.headerOpacity != nil && memo.headerOpacity != menu.headerOpacity
            rootHeader.content.setOpacity(menu.headerOpacity, pass.animation(.easeInOut(duration: 0.25), when: changed))
        }

        // Section title, beside the section's icon.
        submenuHeader.setPresent(showsSubmenuHeader, transition)
        if showsSubmenuHeader {
            // Beside the section's icon in the classic look; over the list in the modern one, which has no icon there.
            let centerX = isModern ? frames.menuFrame.midX : sceneSize.width * 0.5 + menu.firstRowHeaderOffsetX(sceneSize: sceneSize) + menu.landedIconWidth * 0.6
            submenuHeader.show(graphic, centerX: centerX, top: frames.headerTop)
            let titleChanged = memo.submenuTitleOpacity != nil && memo.submenuTitleOpacity != menu.submenuTitleOpacity
            let chromeChanged = memo.hidesPodcastsChrome != nil && memo.hidesPodcastsChrome != hidesChrome
            let animation = chromeChanged ? pass.animation(.easeInOut(duration: 0.22), when: true) : pass.animation(.easeInOut(duration: 0.25), when: titleChanged)
            submenuHeader.content.setOpacity(hidesChrome ? 0 : menu.submenuTitleOpacity, animation)
        }
        memo.showsSubmenuHeader = showsSubmenuHeader
        memo.headerOpacity = menu.headerOpacity
        memo.submenuTitleOpacity = menu.submenuTitleOpacity
    }

    private func updateLists(_ pass: RenderPass, sceneSize: CGSize, frames: MenuSceneFrames, scale: CGFloat) {
        let menu = menu
        let menuWidth = frames.menuFrame.width
        let arrow = menu.menuArrowAppearance
        let theme = AppSettings.theme

        rootList.layer.place(CGRect(x: 0, y: 0, width: menuWidth, height: menu.menuListLayoutHeight(for: menu.defaultVisibleMenuRowCount)))
        rootList.update(MenuListLayer.Configuration(
            items: menu.rootListItems(),
            selectedIndex: menu.selectedIndex,
            menuWidth: menuWidth,
            arrowAppearance: arrow,
            showsTopOverflowFade: true,
            visibleRowCount: menu.defaultVisibleMenuRowCount,
            theme: theme,
            hidesSelection: menu.touchHidesSelection,
            visibility: visibility(of: rootList, opacity: menu.rootMenuOpacity),
            rubberBand: menu.pointerActiveListLevel == .root ? menu.remoteRubberBand : 0,
        ), menu: menu, pass: pass, scale: scale)
        rootList.layer.setOpacity(menu.rootMenuOpacity, pass.animation)
        slide(rootList.layer, away: menu.rootMenuOpacity < 0.5, toLeft: true, theme: theme, pass.animation)

        // Section menu.
        let showsSubmenu = menu.isInSubmenu || menu.isEnteringSubmenu || menu.submenuOpacity > 0.001
        let hidesSubmenu = menu.shouldHideSubmenuListUntilLoadCompletes
        if showsSubmenu {
            let insertion = memo.showsSubmenuList ? pass.animation : nil
            let items = menu.submenuListItems()
            let isPhotos = menu.activeRootItemID == "photos"
            let topInset: CGFloat = (menu.activeRootItemID == "tv_shows" && (menu.isInSubmenu || menu.isEnteringSubmenu)) ? 91 : 0
            submenuList.layer.isHidden = false
            submenuList.layer.place(CGRect(x: 0, y: topInset, width: menuWidth, height: menu.menuListLayoutHeight(for: menu.defaultVisibleMenuRowCount)))
            submenuList.update(MenuListLayer.Configuration(
                items: items,
                selectedIndex: min(menu.selectedSubIndex, max(0, items.count - 1)),
                menuWidth: menuWidth,
                arrowAppearance: arrow,
                showsTopOverflowFade: true,
                visibleRowCount: menu.defaultVisibleMenuRowCount,
                selectionBoxWidthScale: isPhotos ? menu.photosSelectionBoxWidthScale : 1,
                selectionBoxHeightScale: isPhotos ? menu.photosSelectionBoxHeightScale : 1,
                theme: theme,
                hidesSelection: menu.touchHidesSelection,
                visibility: visibility(of: submenuList, opacity: hidesSubmenu ? 0 : menu.submenuOpacity),
                rubberBand: menu.pointerActiveListLevel == .submenu ? menu.remoteRubberBand : 0,
            ), menu: menu, pass: memo.showsSubmenuList ? pass : RenderPass(transaction: .instant), scale: scale)
            slide(submenuList.layer, away: menu.submenuOpacity < 0.5, toLeft: menu.isInThirdMenu, theme: theme, memo.showsSubmenuList ? pass.animation : nil)
            let hideChanged = memo.hidesSubmenuList != nil && memo.hidesSubmenuList != hidesSubmenu
            submenuList.layer.setOpacity(hidesSubmenu ? 0 : menu.submenuOpacity, hideChanged ? pass.animation(.easeInOut(duration: 0.18), when: true) : insertion ?? pass.animation)
        } else if memo.showsSubmenuList {
            submenuList.layer.isHidden = true
            submenuList.reset()
        }
        memo.showsSubmenuList = showsSubmenu
        memo.hidesSubmenuList = hidesSubmenu

        // Third-level menu.
        let showsThird = menu.isInThirdMenu || menu.thirdMenuOpacity > 0.001
        let hidesThird = menu.shouldHideThirdMenuListUntilLoadCompletes
        if showsThird {
            let items = menu.thirdMenuListItems()
            let isPhotosThird = menu.activeRootItemID == "photos" && menu.thirdMenuMode == .photosDateAlbums
            // A list of videos has tall rows in the classic look (see `MenuRowMedia`).
            let hasVideoRows = theme == .classic && menu.thirdMenuMode == .youtube && items.contains { $0.media != nil }
            thirdList.layer.isHidden = false
            // A tall row is centred on the room of an ordinary one, so the first of a list of
            // videos reached above the list's top edge and lost its top there: such a list
            // hangs that much lower, with that much room above its first row.
            let tallRowsInset = hasVideoRows ? ((menu.videoRowHeightScale - 1) * menu.selectionBoxHeight / 2).rounded() : 0
            thirdList.layer.place(CGRect(x: 0, y: tallRowsInset, width: menuWidth, height: menu.menuListLayoutHeight(for: menu.thirdLevelVisibleMenuRowCount)))
            thirdList.update(MenuListLayer.Configuration(
                items: items,
                selectedIndex: min(menu.selectedThirdIndex, max(0, items.count - 1)),
                menuWidth: menuWidth,
                arrowAppearance: arrow,
                showsTopOverflowFade: true,
                visibleRowCount: menu.thirdLevelVisibleMenuRowCount,
                selectionBoxWidthScale: isPhotosThird ? menu.photosSelectionBoxWidthScale : 1,
                selectionBoxHeightScale: isPhotosThird ? menu.photosSelectionBoxHeightScale : (hasVideoRows ? menu.videoRowHeightScale : 1),
                usesUniformRowLayout: menu.thirdMenuMode == .musicSongs,
                theme: theme,
                hidesSelection: menu.touchHidesSelection || menu.youtubeSearchPadHasFocus,
                visibility: visibility(of: thirdList, opacity: hidesThird ? 0 : menu.thirdMenuOpacity),
                rubberBand: menu.pointerActiveListLevel == .third ? menu.remoteRubberBand : 0,
                topRoom: tallRowsInset,
            ), menu: menu, pass: memo.showsThirdList ? pass : RenderPass(transaction: .instant), scale: scale)
            slide(thirdList.layer, away: menu.thirdMenuOpacity < 0.5, toLeft: false, theme: theme, memo.showsThirdList ? pass.animation : nil)
            let hideChanged = memo.hidesThirdList != nil && memo.hidesThirdList != hidesThird
            thirdList.layer.setOpacity(hidesThird ? 0 : menu.thirdMenuOpacity, hideChanged ? pass.animation(.easeInOut(duration: 0.18), when: true) : pass.animation)
        } else if memo.showsThirdList {
            thirdList.layer.isHidden = true
            thirdList.reset()
        }
        memo.showsThirdList = showsThird
        memo.hidesThirdList = hidesThird

        // TV Shows sort control.
        let showsPill = menu.shouldShowTVShowsSortPill
        let pillChanged = memo.showsSortPill != nil && memo.showsSortPill != showsPill
        if showsPill || sortPill.opacity > 0 {
            let isModern = theme == .modern
            if memo.sortMode != menu.tvShowsSortMode || sortPill.contentsScale != scale || sortPill.contents == nil || memo.sortPillTheme != theme {
                let graphic = isModern
                    ? TVShowsSortPillRenderer.renderModern(mode: menu.tvShowsSortMode, scale: scale)
                    : TVShowsSortPillRenderer.render(mode: menu.tvShowsSortMode, scale: scale)
                sortPill.contents = graphic.image
                sortPill.contentsScale = graphic.scale
                memo.sortMode = menu.tvShowsSortMode
                memo.sortPillTheme = theme
            }
            let size = isModern ? TVShowsSortPillRenderer.modernSize : TVShowsSortPillRenderer.size
            let padding = TVShowsSortPillRenderer.padding
            sortPill.frame = CGRect(x: (menuWidth - size.width) * 0.5 - padding, y: 6 - padding, width: size.width + padding * 2, height: size.height + padding * 2)
        }
        sortPill.setOpacity(showsPill ? 1 : 0, pass.animation(.easeInOut(duration: 0.2), when: pillChanged))
        memo.showsSortPill = showsPill
    }

    /// Whether a list is on screen, on its way off, or out of sight: from its own opacity, the
    /// scene's and the menu group's, and the black overlays over them, both as they are on
    /// screen now and as they are heading.
    private func visibility(of list: MenuListLayer, opacity: Double) -> MenuListLayer.Visibility {
        let menu = menu
        let isModern = ModernTheme.isActive
        let overlays: [(CALayer, Double)] = [
            (folderSwapOverlay, menu.menuFolderSwapOverlayOpacity),
            (movieTransitionOverlay, menu.movieTransitionOverlayOpacity),
            (fullscreenTransitionOverlay, menu.fullscreenTransitionOverlayOpacity),
        ]
        func onScreen(_ layer: CALayer) -> Double {
            Double(layer.presentation()?.opacity ?? layer.opacity)
        }
        var heading = opacity * menu.menuOpacityOnScreen * (isModern ? menu.modernSwapOpacity : 1)
        var showing = onScreen(list.layer) * onScreen(sceneContent) * onScreen(menuGroup)
        for (overlay, target) in overlays {
            heading *= 1 - target
            if !overlay.isHidden { showing *= 1 - onScreen(overlay) }
        }
        if showing < 0.01 { return .hidden }
        return heading < 0.5 ? .leaving : .visible
    }

    static func scale(_ factor: CGFloat, about center: CGPoint) -> CATransform3D {
        guard factor != 1 else { return CATransform3DIdentity }
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        return CATransform3DTranslate(transform, -center.x, -center.y, 0)
    }

    /// In the modern look a list slides out as it fades (left when the next level comes in,
    /// right when going back) and slides in from the other side.
    private func slide(_ layer: CALayer, away: Bool, toLeft: Bool, theme: InterfaceTheme, _ animation: Animation?) {
        let distance = ModernTheme.listSlideDistance
        let offset: CGFloat = theme == .modern && away ? (toLeft ? -distance : distance) : 0
        // Slides decelerate on a quadratic curve, taking at least a moment so they read as moves.
        let eased = animation.map { Animation.smooth(duration: max($0.duration, 0.36)) }
        layer.setTransform(CATransform3DMakeTranslation(offset, 0, 0), theme == .modern ? eased : nil)
    }
}

private extension RootCarouselConfiguration {
    func isSameState(as other: RootCarouselConfiguration) -> Bool {
        images.count == other.images.count &&
            zip(images, other.images).allSatisfy { $0 === $1 } &&
            selectedIndex == other.selectedIndex &&
            isIconAnimated == other.isIconAnimated &&
            isEnteringSubmenu == other.isEnteringSubmenu &&
            isReturningToRoot == other.isReturningToRoot &&
            isInSubmenu == other.isInSubmenu &&
            showsSettledLandedIcon == other.showsSettledLandedIcon &&
            landedOffset == other.landedOffset &&
            sceneWidth == other.sceneWidth &&
            selectionDuration == other.selectionDuration &&
            usesLinearSweep == other.usesLinearSweep
    }
}

/// A title line that fades in and out as a whole, with its own opacity inside.
@MainActor
final class HeaderLayer {
    let layer = SceneLayer()
    let content = SceneLayer()
    private var isPresent: Bool?

    init() {
        layer.addSublayer(content)
        layer.opacity = 0
    }

    func setPresent(_ present: Bool, _ transition: Animation?) {
        guard present != isPresent else { return }
        isPresent = present
        layer.setOpacity(present ? 1 : 0, transition)
    }

    func show(_ graphic: RenderedGraphic, centerX: CGFloat, top: CGFloat) {
        content.show(graphic, at: CGPoint(x: centerX - graphic.size.width * 0.5, y: top))
    }
}

/// The Date / Show switch above the TV Shows menu.
@MainActor
enum TVShowsSortPillRenderer {
    static let size = CGSize(width: 209, height: 28)
    static let padding: CGFloat = 2
    private static var cache: [String: RenderedGraphic] = [:]

    static func render(mode: MenuView.TVShowsSortMode, scale: CGFloat) -> RenderedGraphic {
        let key = "\(mode)|\(scale)"
        if let cached = cache[key] { return cached }
        let usesDate = mode == .date
        let width = size.width
        let height = size.height
        let segmentWidth = width * 0.5
        let graphic = TextRenderer.draw(size: size, padding: padding, scale: scale, shadows: []) { context in
            // Bitmap coordinates have y up; work in a top-left box instead.
            context.translateBy(x: padding, y: padding + height)
            context.scaleBy(x: 1, y: -1)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let capsule = CGPath(roundedRect: bounds, cornerWidth: height * 0.5, cornerHeight: height * 0.5, transform: nil)
            context.saveGState()
            context.addPath(capsule)
            context.clip()
            drawVerticalGradient(context, in: bounds, stops: [(RGBA(red: 30 / 255, green: 45 / 255, blue: 60 / 255), 0), (RGBA(red: 2 / 255, green: 6 / 255, blue: 8 / 255), 1)])
            drawGloss(context, in: bounds, stops: [(RGBA(white: 1, alpha: 0.30), 0), (RGBA(white: 1, alpha: 0.12), 0.34), (RGBA(white: 1, alpha: 0), 0.92)])

            // The selected half.
            let segment = CGRect(x: usesDate ? 0 : segmentWidth, y: 0, width: segmentWidth, height: height)
            let selection = selectionPath(in: segment, roundsLeft: usesDate, roundsRight: !usesDate)
            context.saveGState()
            context.addPath(selection)
            context.clip()
            drawVerticalGradient(context, in: segment, stops: [(RGBA(red: 70 / 255, green: 120 / 255, blue: 180 / 255), 0), (RGBA(red: 70 / 255, green: 112 / 255, blue: 165 / 255), 1)])
            drawGloss(context, in: segment, stops: [(RGBA(white: 1, alpha: 0.30), 0), (RGBA(white: 1, alpha: 0.12), 0.34), (RGBA(white: 1, alpha: 0), 0.9)])
            context.restoreGState()

            context.setFillColor(RGBA(white: 0, alpha: 0.34).cgColor)
            context.fill(CGRect(x: width * 0.5 - 0.5, y: 5, width: 1, height: height - 10))
            context.restoreGState()

            context.addPath(capsule)
            context.setStrokeColor(RGBA(red: 82 / 255, green: 147 / 255, blue: 221 / 255, alpha: 0.96).cgColor)
            context.setLineWidth(2)
            context.strokePath()

            // Labels (Core Text draws with y up, so flip back around each one).
            for (index, label) in ["Date", "Show"].enumerated() {
                let selected = (index == 0) == usesDate
                let font = FontMetrics.font("Lucida Grande", size: 20)
                let line = CTLineCreateWithAttributedString(FontMetrics.attributed(label, font: font, color: selected ? .white : RGBA(white: 1, alpha: 0.56)))
                let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let lineHeight = FontMetrics.lineHeight(font)
                let x = CGFloat(index) * segmentWidth + (segmentWidth - lineWidth) * 0.5
                let top = (height - lineHeight) * 0.5
                context.saveGState()
                context.translateBy(x: x, y: top + FontMetrics.baseline(font))
                context.scaleBy(x: 1, y: -1)
                context.textPosition = .zero
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }
        cache[key] = graphic
        return graphic
    }

    static let modernSize = CGSize(width: 300, height: 52)
    private static var modernCache: [String: RenderedGraphic] = [:]

    /// The modern look's switch: a translucent capsule with the chosen half in white.
    static func renderModern(mode: MenuView.TVShowsSortMode, scale: CGFloat) -> RenderedGraphic {
        let key = "\(mode)|\(scale)"
        if let cached = modernCache[key] { return cached }
        let usesDate = mode == .date
        let size = modernSize
        let half = size.width * 0.5
        let graphic = TextRenderer.draw(size: size, padding: padding, scale: scale, shadows: []) { context in
            context.translateBy(x: padding, y: padding + size.height)
            context.scaleBy(x: 1, y: -1)
            let bounds = CGRect(origin: .zero, size: size)
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: size.height * 0.5, cornerHeight: size.height * 0.5, transform: nil))
            context.setFillColor(ModernTheme.rowFill.cgColor)
            context.fillPath()
            let chosen = CGRect(x: usesDate ? 4 : half + 4, y: 4, width: half - 8, height: size.height - 8)
            context.addPath(CGPath(roundedRect: chosen, cornerWidth: chosen.height * 0.5, cornerHeight: chosen.height * 0.5, transform: nil))
            context.setFillColor(ModernTheme.focusFill.cgColor)
            context.fillPath()
            for (index, label) in ["Date", "Show"].enumerated() {
                let selected = (index == 0) == usesDate
                let font = FontMetrics.font(ModernTheme.mediumFontName, size: 26)
                let line = CTLineCreateWithAttributedString(FontMetrics.attributed(label, font: font, color: selected ? ModernTheme.focusedText : ModernTheme.text))
                let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let lineHeight = FontMetrics.lineHeight(font)
                context.saveGState()
                context.translateBy(x: CGFloat(index) * half + (half - lineWidth) * 0.5, y: (size.height - lineHeight) * 0.5 + FontMetrics.baseline(font))
                context.scaleBy(x: 1, y: -1)
                context.textPosition = .zero
                CTLineDraw(line, context)
                context.restoreGState()
            }
        }
        modernCache[key] = graphic
        return graphic
    }

    private static func drawVerticalGradient(_ context: CGContext, in rect: CGRect, stops: [(RGBA, CGFloat)]) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: stops.map(\.0.cgColor) as CFArray, locations: stops.map(\.1)) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// The shine over the upper half, inside a mask with curved lower corners.
    private static func drawGloss(_ context: CGContext, in rect: CGRect, stops: [(RGBA, CGFloat)]) {
        let sideCurveWidth = rect.width * 0.085
        let topEdgeY = rect.minY + rect.height * 0.03
        let sideBottomY = rect.minY + rect.height * 0.12
        let flatBottomY = rect.minY + rect.height * 0.57
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: topEdgeY))
        path.addLine(to: CGPoint(x: rect.maxX, y: topEdgeY))
        path.addLine(to: CGPoint(x: rect.maxX, y: sideBottomY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - sideCurveWidth, y: flatBottomY), control: CGPoint(x: rect.maxX - sideCurveWidth * 0.12, y: flatBottomY))
        path.addLine(to: CGPoint(x: rect.minX + sideCurveWidth, y: flatBottomY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: sideBottomY), control: CGPoint(x: rect.minX + sideCurveWidth * 0.12, y: flatBottomY))
        path.closeSubpath()
        context.saveGState()
        context.addPath(path)
        context.clip()
        drawVerticalGradient(context, in: rect, stops: stops)
        context.restoreGState()
    }

    private static func selectionPath(in rect: CGRect, roundsLeft: Bool, roundsRight: Bool) -> CGPath {
        let radius = min(rect.height * 0.5, rect.width * 0.5)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: roundsLeft ? rect.minX + radius : rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: roundsRight ? rect.maxX - radius : rect.maxX, y: rect.minY))
        if roundsRight {
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
            path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: roundsLeft ? rect.minX + radius : rect.minX, y: rect.maxY))
        if roundsLeft {
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
            path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

extension MenuSceneRenderer {
    /// The scene's live geometry, for working out what the pointer is over.
    /// The options row under a window point (-1 for the panel between rows), and whether
    /// the point is on the "‹" end of its value.
    func movieOptionsRow(at windowPoint: CGPoint) -> (index: Int, backward: Bool)? {
        guard let panel = playback.options.panelFrame else { return nil }
        let point = fullscreenCanvas.point(windowPoint)
        guard panel.contains(point) else { return nil }
        guard let index = playback.options.rowFrames.firstIndex(where: { $0.contains(point) }) else { return (-1, false) }
        let values = playback.options.valueFrames
        // (On the value's "‹", not anywhere to its left: a click on the row's name went back a
        // value too, which on a row at its first value did nothing.)
        let backward = values.indices.contains(index) && point.x >= values[index].minX - 18
            && point.x < values[index].minX + min(70, values[index].width * 0.35)
        return (index, backward)
    }

    func onboardingOption(at windowPoint: CGPoint) -> Int? {
        onboarding.option(atWindowPoint: windowPoint)
    }

    func movieOptionsButton(at windowPoint: CGPoint) -> MenuView.MovieOptionRow.Kind? {
        playback.options.button(at: fullscreenCanvas.point(windowPoint))
    }

    func youtubePanelRow(at windowPoint: CGPoint) -> (isOnPanel: Bool, index: Int?)? {
        guard let panel = playback.panel.panelFrame else { return nil }
        let point = fullscreenCanvas.point(windowPoint)
        guard panel.contains(point) else { return (false, nil) }
        return (true, playback.panel.row(at: point))
    }

    var youtubePanelScroll: YouTubePanelScroll? {
        guard playback.panel.panelFrame != nil else { return nil }
        return YouTubePanelScroll(
            offset: playback.panel.scrollOffset,
            limit: playback.panel.scrollLimit,
            canvasPerPoint: 1 / max(fullscreenCanvas.scale, 0.0001),
            shownRows: playback.panel.shownRows,
        )
    }

    var youtubePanelScale: CGFloat {
        max(fullscreenCanvas.scale, 0.0001)
    }

    func youtubePanelRoom(ofRow index: Int) -> (overflow: CGFloat, page: CGFloat) {
        playback.panel.room(ofRow: index)
    }

    var pointerScene: PointerScene {
        PointerScene(
            canvasOrigin: canvas.position,
            canvasScale: canvasScale,
            lists: [.root: rootList, .submenu: submenuList, .third: thirdList],
            carousel: rootCarousel,
            sortPillFrame: sortPill.frame,
            resumePrompt: resumePrompt,
            movieSeekTrack: ModernTheme.isActive ? playback.modernControls.seekTrack : playback.controls.seekTrack,
            fullscreenScene: fullscreenScene,
            fullscreenCanvas: fullscreenCanvas,
            fullscreenSize: fullscreenContainerSize,
        )
    }
}
