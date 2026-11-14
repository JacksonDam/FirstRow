import AVFoundation
import QuartzCore
#if os(macOS)
    import AppKit
#endif

/// Draws the Tiger look's menus from `MenuView`'s state: the ring of icons, the title under
/// it, and a section's pages under their title bar.
@MainActor
final class TigerSceneLayer {
    let layer = SceneLayer()

    private let backdrop = SceneGradientLayer()
    private let resumeBackdrop = SceneLayer()
    private let introBackdrop = SceneLayer()
    private let introImage = StillLayer()
    private let introReflection = StillLayer()
    private let introReflectionMask = StillGradientLayer()
    private let introReflectionBox = SceneLayer()

    private let stage = StillLayer()
    private let reflections = SceneLayer()
    private let icons = SceneLayer()
    private var iconLayers: [StillLayer] = []
    private var reflectionLayers: [StillLayer] = []
    private var iconIDs: [String] = []

    private let pages = SceneLayer()
    private let divider = SceneLayer()
    private var livePage: TigerPageLayer?
    private var outgoingPages: [TigerPageLayer] = []
    private var slide = TigerMovingValue(1)
    private var slidesForward = true

    private let flight = SceneLayer()
    private let flightDivider = SceneLayer()
    private let flightReflection = StillLayer()
    private let flightIcon = StillLayer()
    private let flightLabel = StillLayer()
    private let rootLabel = StillLayer()

    private var sceneSize: CGSize = .zero
    private var ringMemo: RingMemo?
    private var flightMemo: FlightMemo?
    private var introMemo: IntroMemo?
    private var contentMemo: ContentMemo?
    private var shownResumeBackdrop: NSImage?

    private struct RingMemo: Equatable {
        var ring, intro, section, selected, count: Int
        var isAtRestInSection, showsFlight, isLeaving, isOpening: Bool
        var size: CGSize
    }

    private struct FlightMemo: Equatable {
        var flight, section, ring, selected: Int
        var shows: Bool
        var title: String
        var size: CGSize
        var scale: CGFloat
    }

    private struct IntroMemo: Equatable {
        var revision: Int
        var shows: Bool
        var size: CGSize
    }

    private struct ContentMemo: Equatable {
        var section: Int
        var shows: Bool
        var page: ObjectIdentifier?
        var size: CGSize
    }

    init() {
        layer.masksToBounds = true
        // Black down to the middle, then up to grey at the foot: the floor the ring stands on.
        // (Halfway up the rise the grey is the one that looks half as light, which is darker
        // than half the numbers.)
        backdrop.colors = [
            CGColor(gray: 0, alpha: 1),
            CGColor(gray: 0, alpha: 1),
            CGColor(srgbRed: 33.9 / 255, green: 33.9 / 255, blue: 32.2 / 255, alpha: 1),
            CGColor(srgbRed: 100 / 255, green: 100 / 255, blue: 96 / 255, alpha: 1),
        ]
        backdrop.locations = [0, 0.5, 0.75, 1]
        backdrop.startPoint = CGPoint(x: 0.5, y: 0)
        backdrop.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(backdrop)
        resumeBackdrop.contentsGravity = .resize
        resumeBackdrop.masksToBounds = true
        resumeBackdrop.opacity = 0
        layer.addSublayer(resumeBackdrop)

        introBackdrop.masksToBounds = true
        introBackdrop.isHidden = true
        introImage.contentsGravity = .resizeAspectFill
        introImage.masksToBounds = true
        introReflection.contentsGravity = .resizeAspectFill
        introReflection.masksToBounds = true
        introReflectionMask.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        introReflectionMask.locations = [0, 0.8, 1]
        introReflectionMask.startPoint = CGPoint(x: 0.5, y: 0)
        introReflectionMask.endPoint = CGPoint(x: 0.5, y: 1)
        introReflectionBox.mask = introReflectionMask
        introReflectionBox.addSublayer(introReflection)
        introBackdrop.addSublayer(introImage)
        introBackdrop.addSublayer(introReflectionBox)
        layer.addSublayer(introBackdrop)

        stage.anchorPoint = CGPoint(x: 0.5, y: 1)
        stage.addSublayer(reflections)
        stage.addSublayer(icons)
        layer.addSublayer(stage)

        divider.backgroundColor = CGColor(gray: 1, alpha: 0.96)
        divider.isHidden = true
        pages.addSublayer(divider)
        pages.isHidden = true
        layer.addSublayer(pages)

        flightDivider.backgroundColor = CGColor(gray: 1, alpha: 0.96)
        flightReflection.contentsGravity = .resizeAspect
        flightIcon.contentsGravity = .resizeAspect
        flight.addSublayer(flightDivider)
        flight.addSublayer(flightReflection)
        flight.addSublayer(flightIcon)
        flight.addSublayer(flightLabel)
        flight.isHidden = true
        layer.addSublayer(flight)

        rootLabel.opacity = 0
        layer.addSublayer(rootLabel)
    }

    func tearDown() {
        TigerMoviePreviewLayer.shared.tearDown()
        livePage?.tearDown()
        outgoingPages.forEach { $0.tearDown() }
    }

    func update(menu: MenuView, pass: RenderPass, sceneSize: CGSize, scale: CGFloat) {
        let sizeChanged = sceneSize != self.sceneSize
        if sizeChanged {
            self.sceneSize = sceneSize
            let bounds = CGRect(origin: .zero, size: sceneSize)
            layingOut {
                layer.place(bounds)
                backdrop.place(bounds)
                resumeBackdrop.place(bounds)
                introBackdrop.place(bounds)
                introReflectionBox.place(bounds)
                introReflectionMask.frame = bounds
                stage.bounds = bounds
                reflections.place(bounds)
                icons.place(bounds)
                pages.place(bounds)
                flight.place(bounds)
            }
        }
        updateResumeBackdrop(menu: menu, pass: pass)
        updateIntroBackdrop(menu: menu)
        updateRing(menu: menu)
        updateFlight(menu: menu, scale: scale)
        updatePages(menu: menu, pass: pass, scale: scale)
        updateRootLabel(menu: menu, pass: pass, scale: scale)
    }

    // MARK: - The picture behind the question about where to start a movie

    private func updateResumeBackdrop(menu: MenuView, pass: RenderPass) {
        let image = menu.isMovieResumePromptVisible ? menu.movieResumePromptBackdropImage : nil
        if let image, image !== shownResumeBackdrop {
            shownResumeBackdrop = image
            resumeBackdrop.contents = TigerPictures.softened(image, sceneSize: sceneSize)
        }
        let shows = menu.tiger.showsResumeBackdrop && image != nil
        resumeBackdrop.setOpacity(shows ? 1 : 0, pass.animation)
        // (Kept while it fades away, after the question has gone.)
        if !shows, shownResumeBackdrop != nil, resumeBackdrop.opacity == 0, resumeBackdrop.animation(forKey: "opacity") == nil {
            shownResumeBackdrop = nil
            resumeBackdrop.contents = nil
        }
    }

    // MARK: - The desktop drawing back

    private func updateIntroBackdrop(menu: MenuView) {
        let state = menu.tiger
        // (Only while First Row opens or leaves: at rest the desktop's picture is far off and
        // clear, and no layer need hold it.)
        let shows = state.introBackdropImage != nil && (state.isIntroRunning || !state.hasStartedIntro)
        let memo = IntroMemo(revision: state.introBackdrop.revision, shows: shows, size: sceneSize)
        guard memo != introMemo else { return }
        introMemo = memo
        introBackdrop.isHidden = !shows
        guard shows, let image = LayerImageCache.cgImage(for: state.introBackdropImage) else {
            introImage.contents = nil
            introReflection.contents = nil
            return
        }
        let size = sceneSize
        withoutLayerActions {
            introImage.contents = image
            introReflection.contents = image
            introImage.bounds = CGRect(origin: .zero, size: size)
            introReflection.bounds = CGRect(origin: .zero, size: size)
        }
        let times = TigerKeyframes.times(until: state.introBackdrop.endTime)
        var imagePlaces: [CGPoint] = [], reflectionPlaces: [CGPoint] = []
        var imageTurns: [CATransform3D] = [], reflectionTurns: [CATransform3D] = []
        var opacities: [CGFloat] = [], reflectionOpacities: [CGFloat] = []
        for time in times {
            let progress = tigerUnit(CGFloat(state.introBackdrop.value(at: time)))
            let factor = tigerMix(1, TigerTheme.introBackdropMinimumScale, progress)
            let yOffset = tigerMix(0, TigerTheme.introBackdropFinalYOffset, progress)
            // (It fades all the way through the move, as steadily as it shrinks.)
            let opacity = 1 - progress
            imagePlaces.append(CGPoint(x: size.width * 0.5, y: size.height * 0.5 + yOffset))
            imageTurns.append(CATransform3DMakeScale(factor, factor, 1))
            opacities.append(opacity)
            // The floor's reflection of it hangs from its foot.
            reflectionPlaces.append(CGPoint(x: size.width * 0.5, y: size.height * 0.5 + yOffset + size.height * factor))
            reflectionTurns.append(CATransform3DMakeScale(factor, -factor, 1))
            reflectionOpacities.append(opacity * 0.5)
        }
        TigerKeyframes.run(introImage, position: imagePlaces, times: times)
        TigerKeyframes.run(introImage, transform: imageTurns, times: times)
        TigerKeyframes.run(introImage, opacity: opacities, times: times)
        TigerKeyframes.run(introReflection, position: reflectionPlaces, times: times)
        TigerKeyframes.run(introReflection, transform: reflectionTurns, times: times)
        TigerKeyframes.run(introReflection, opacity: reflectionOpacities, times: times)
    }

    // MARK: - The ring

    private func updateRing(menu: MenuView) {
        let state = menu.tiger
        let items = menu.menuItems
        let ids = items.map(\.id)
        if ids != iconIDs {
            iconIDs = ids
            (iconLayers + reflectionLayers).forEach { $0.removeFromSuperlayer() }
            iconLayers = []
            reflectionLayers = []
            let side = TigerRing.iconSide
            for id in ids {
                let picture = LayerImageCache.cgImage(for: NSImage(named: TigerTheme.iconAssetName(forRootID: id)))
                let icon = StillLayer()
                icon.contentsGravity = .resizeAspect
                icon.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                icon.contents = picture
                icons.addSublayer(icon)
                iconLayers.append(icon)
                let reflection = StillLayer()
                reflection.contentsGravity = .resizeAspect
                reflection.bounds = icon.bounds
                reflection.contents = picture.flatMap { TigerRing.reflectionImage(forRootID: id, of: $0) }
                reflections.addSublayer(reflection)
                reflectionLayers.append(reflection)
            }
            ringMemo = nil
        }
        let isAtRestInSection = menu.isInSubmenu && !menu.isEnteringSubmenu && !menu.isReturningToRoot
        let showsFlight = menu.activeRootItemID != nil && (menu.isEnteringSubmenu || menu.isReturningToRoot)
        let memo = RingMemo(
            ring: state.ring.revision, intro: state.intro.revision, section: state.section.revision, selected: menu.selectedIndex, count: items.count,
            isAtRestInSection: isAtRestInSection, showsFlight: showsFlight, isLeaving: state.isExitRunning, isOpening: state.isIntroRunning, size: sceneSize,
        )
        guard memo != ringMemo else { return }
        ringMemo = memo
        let size = sceneSize
        let center = TigerRing.stageCenter(sceneSize: size)
        let times = TigerKeyframes.times(until: max(state.ring.endTime, state.intro.endTime, state.section.endTime))
        let count = items.count
        let selected = menu.selectedIndex

        var stagePlaces: [CGPoint] = [], stageScales: [CGFloat] = []
        var places = Array(repeating: [CGPoint](), count: count), scales = Array(repeating: [CGFloat](), count: count)
        var depths = Array(repeating: [CGFloat](), count: count), opacities = Array(repeating: [CGFloat](), count: count)
        var reflectionPlaces = Array(repeating: [CGPoint](), count: count), reflectionTurns = Array(repeating: [CATransform3D](), count: count)
        // As First Row opens the ring is at its full width from the first moment (and as it
        // leaves, at its widest); what each icon is out of place by at that moment, where it
        // then stands on the ring, dies away over the move.
        let isMoving = state.isIntroRunning
        let radius = isMoving && state.isExitRunning ? TigerTheme.ringExitEndRadius : TigerTheme.ringRadius
        let radiusBefore = state.isExitRunning ? TigerTheme.ringRadius : TigerTheme.ringIntroStartRadius
        let firstTurn = state.ring.origin
        let outOfPlace: [TigerRing.Placement] = (0 ..< count).map { index in
            let after = TigerRing.placement(index: index, selection: firstTurn, count: count, radius: radius)
            let before = TigerRing.placement(index: index, selection: firstTurn, count: count, radius: isMoving ? radiusBefore : radius)
            return TigerRing.Placement(x: after.x - before.x, y: after.y - before.y, depth: 0, scale: after.scale - before.scale)
        }
        // The whole ring is enlarged as it rises, the more so that the icon to be in front
        // starts no smaller than it ends up.
        var stageStartScale = TigerTheme.introStageStartScale
        if isMoving, !state.isExitRunning, count > 0 {
            let first = TigerRing.placement(index: selected, selection: firstTurn, count: count, radius: radiusBefore)
            let settled = TigerRing.placement(index: selected, selection: Double(selected), count: count, radius: TigerTheme.ringRadius)
            stageStartScale *= max(1, settled.scale / max(0.001, first.scale))
        }
        for time in times {
            let turn = state.ring.value(at: time)
            let intro = CGFloat(state.intro.value(at: time))
            let opened = tigerSmoothStep(CGFloat(state.section.value(at: time)))
            let left = isMoving ? (state.isExitRunning ? tigerUnit(intro) : 1 - tigerUnit(intro)) : 0
            stagePlaces.append(CGPoint(x: size.width * 0.5, y: size.height + TigerRing.stageYOffset(intro: intro, sceneHeight: size.height)))
            stageScales.append(tigerMix(stageStartScale, 1, tigerUnit(intro)))
            for index in 0 ..< count {
                var placement = TigerRing.placement(index: index, selection: turn, count: count, radius: radius)
                placement.x -= outOfPlace[index].x * left
                placement.y -= outOfPlace[index].y * left
                placement.scale -= outOfPlace[index].scale * left
                var factor = placement.scale
                var place = CGPoint(x: center.x + placement.x, y: center.y + placement.y)
                var opacity: CGFloat = 1
                if index == selected {
                    // (The icon in front is drawn by the flight to the title bar while a section opens.)
                    if showsFlight || isAtRestInSection { opacity = 0 }
                } else {
                    // The others draw back and up, out of the way.
                    let depthScale = 1000 / (1000 + TigerTheme.backgroundZDepth * opened)
                    factor *= depthScale
                    place = CGPoint(x: center.x + placement.x * depthScale, y: center.y + placement.y * depthScale + TigerTheme.backgroundGroupLift * opened)
                    opacity = isAtRestInSection ? 0 : tigerMix(1, 0.18, opened)
                }
                places[index].append(place)
                scales[index].append(factor)
                depths[index].append(placement.depth)
                opacities[index].append(opacity)
                let foot = TigerRing.iconSide * 0.5 - 38 + TigerTheme.iconOpticalYOffset(forRootID: ids[index])
                reflectionPlaces[index].append(CGPoint(x: place.x, y: place.y + factor * (foot + TigerRing.iconSide * 0.5)))
                reflectionTurns[index].append(CATransform3DMakeScale(factor, -factor, 1))
            }
        }
        TigerKeyframes.run(stage, position: stagePlaces, times: times)
        TigerKeyframes.run(stage, scale: stageScales, times: times)
        for index in 0 ..< count {
            TigerKeyframes.run(iconLayers[index], position: places[index], times: times)
            TigerKeyframes.run(iconLayers[index], scale: scales[index], times: times)
            TigerKeyframes.run(iconLayers[index], zPosition: depths[index], times: times)
            TigerKeyframes.run(iconLayers[index], opacity: opacities[index], times: times)
            TigerKeyframes.run(reflectionLayers[index], position: reflectionPlaces[index], times: times)
            TigerKeyframes.run(reflectionLayers[index], transform: reflectionTurns[index], times: times)
            TigerKeyframes.run(reflectionLayers[index], zPosition: depths[index], times: times)
            TigerKeyframes.run(reflectionLayers[index], opacity: opacities[index], times: times)
        }
    }

    // MARK: - A section's icon flying to the title bar

    private func updateFlight(menu: MenuView, scale: CGFloat) {
        let state = menu.tiger
        let shows = menu.activeRootItemID != nil && (menu.isEnteringSubmenu || menu.isReturningToRoot)
        let title = state.rootLabelText
        let memo = FlightMemo(flight: state.flight.revision, section: state.section.revision, ring: state.ring.revision, selected: menu.selectedIndex, shows: shows, title: title, size: sceneSize, scale: scale)
        guard memo != flightMemo else { return }
        flightMemo = memo
        flight.isHidden = !shows
        guard shows, let rootID = menu.activeRootItemID, menu.menuItems.indices.contains(menu.selectedIndex) else { return }
        let size = sceneSize
        let center = TigerRing.stageCenter(sceneSize: size)
        let count = menu.menuItems.count
        let optical = TigerTheme.iconOpticalYOffset(forRootID: rootID)
        let landed = TigerRing.landedIconCenter(rootID: rootID, title: title, sceneSize: size)
        let landedTitle = TigerRing.landedTitleCenter(rootID: rootID, title: title, sceneSize: size)
        let rootLabelCenter = TigerRing.rootLabelCenter(sceneSize: size)
        let picture = LayerImageCache.cgImage(for: NSImage(named: TigerTheme.iconAssetName(forRootID: rootID)))
        let side = TigerRing.iconSide
        withoutLayerActions {
            flightIcon.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            flightIcon.contents = picture
            flightReflection.bounds = flightIcon.bounds
            flightReflection.contents = picture.flatMap { TigerRing.reflectionImage(forRootID: rootID, of: $0) }
            let graphic = TextRenderer.render(TextSpec(text: title, fontName: firstRowBoldFontName, size: TigerTheme.titleSize, maxWidth: size.width, minimumScaleFactor: 0.7, shadows: TigerTheme.textShadow), scale: scale)
            flightLabel.show(graphic, at: .zero)
        }
        let times = TigerKeyframes.times(until: max(state.flight.endTime, state.section.endTime, state.ring.endTime))
        var iconPlaces: [CGPoint] = [], iconScales: [CGFloat] = []
        var reflectionPlaces: [CGPoint] = [], reflectionTurns: [CATransform3D] = [], reflectionOpacities: [CGFloat] = []
        var labelPlaces: [CGPoint] = [], dividerPlaces: [CGPoint] = []
        let stageY = TigerTheme.stageRestingYOffset
        let flightSide = TigerRing.flightSide
        // (The icon lands a little above where the settled one stands, by the ring's own offset.)
        let landedOffset = CGPoint(x: landed.x - center.x, y: landed.y - center.y - stageY - TigerTheme.headerIconOpticalYOffset)
        // Each of these goes straight from what it is on the ring to what it is in the title
        // bar, at the pace of the move itself.
        let placement = TigerRing.placement(index: menu.selectedIndex, selection: state.ring.target, count: count, radius: TigerTheme.ringRadius)
        let ringScale = placement.scale * TigerTheme.ringBaseSizeMultiplier / TigerTheme.selectedIconSizeMultiplier
        let ringFoot = optical + (-38 + optical) * (placement.scale - 1)
        for time in times {
            let flown = tigerUnit(CGFloat(state.flight.value(at: time)))
            let opened = tigerUnit(CGFloat(state.section.value(at: time)))
            let iconScale = tigerMix(ringScale, TigerTheme.landedIconScale, flown)
            let across = tigerMix(placement.x, landedOffset.x, flown)
            let down = tigerMix(placement.y, landedOffset.y + TigerTheme.headerIconOpticalYOffset, flown)
            iconPlaces.append(CGPoint(x: center.x + across, y: center.y + stageY + down))
            iconScales.append(iconScale * flightSide / side)
            // Its reflection lets go of it and sinks away under the floor.
            let reflectionAcross = tigerMix(placement.x, TigerTheme.detachedReflectionXOffset - size.width * 0.05, flown)
            let reflectionDown = tigerMix(placement.y, TigerTheme.detachedReflectionYOffset, flown)
            let foot = tigerMix(ringFoot, optical * TigerTheme.landedIconScale, flown)
            reflectionPlaces.append(CGPoint(x: center.x + reflectionAcross, y: center.y + stageY + reflectionDown + iconScale * flightSide - 38 + foot))
            let reflectionScale = iconScale * flightSide / side
            reflectionTurns.append(CATransform3DMakeScale(reflectionScale, -reflectionScale, 1))
            reflectionOpacities.append(max(0, 1 - flown * 1.2))
            labelPlaces.append(CGPoint(x: tigerMix(rootLabelCenter.x, landedTitle.x, opened), y: tigerMix(rootLabelCenter.y, landedTitle.y, opened)))
            dividerPlaces.append(CGPoint(x: 0, y: tigerMix(size.height, TigerTheme.dividerTopInset, opened)))
        }
        withoutLayerActions {
            flightDivider.bounds = CGRect(x: 0, y: 0, width: size.width, height: TigerTheme.dividerThickness)
        }
        TigerKeyframes.run(flightIcon, position: iconPlaces, times: times)
        TigerKeyframes.run(flightIcon, scale: iconScales, times: times)
        TigerKeyframes.run(flightReflection, position: reflectionPlaces, times: times)
        TigerKeyframes.run(flightReflection, transform: reflectionTurns, times: times)
        TigerKeyframes.run(flightReflection, opacity: reflectionOpacities, times: times)
        TigerKeyframes.run(flightLabel, position: labelPlaces, times: times)
        TigerKeyframes.run(flightDivider, position: dividerPlaces, times: times)
    }

    // MARK: - The title under the ring

    private func updateRootLabel(menu: MenuView, pass: RenderPass, scale: CGFloat) {
        let state = menu.tiger
        let showsFlight = menu.activeRootItemID != nil && (menu.isEnteringSubmenu || menu.isReturningToRoot)
        let shows = !menu.isInSubmenu && !showsFlight && (state.isRootLabelVisible || !state.isIntroRunning)
        rootLabel.isHidden = !shows
        guard shows else { return }
        let graphic = TextRenderer.render(TextSpec(text: state.rootLabelText, fontName: firstRowBoldFontName, size: TigerTheme.titleSize, maxWidth: sceneSize.width, minimumScaleFactor: 0.7, shadows: TigerTheme.textShadow), scale: scale)
        let center = TigerRing.rootLabelCenter(sceneSize: sceneSize)
        withoutLayerActions {
            rootLabel.show(graphic, at: .zero)
            rootLabel.position = center
        }
        rootLabel.setOpacity(state.rootLabelOpacity, pass.animation)
    }

    // MARK: - Pages

    private func updatePages(menu: MenuView, pass: RenderPass, scale: CGFloat) {
        let state = menu.tiger
        let size = sceneSize
        TigerMoviePreviewLayer.shared.follow(menu: menu)
        guard let page = menu.tigerCurrentPage() else {
            if livePage != nil || !outgoingPages.isEmpty {
                livePage?.remove()
                livePage = nil
                outgoingPages.forEach { $0.remove() }
                outgoingPages = []
            }
            pages.isHidden = true
            contentMemo = nil
            return
        }
        pages.isHidden = false
        pages.setOpacity(menu.menuOpacityOnScreen, pass.animation)
        let showsFlight = menu.activeRootItemID != nil && (menu.isEnteringSubmenu || menu.isReturningToRoot)
        withoutLayerActions {
            divider.isHidden = !(menu.isInSubmenu && !showsFlight)
            divider.place(CGRect(x: 0, y: TigerTheme.dividerTopInset, width: size.width, height: TigerTheme.dividerThickness))
        }

        if state.holdsPage, let livePage {
            // The page stays as it was while the next one gets ready; only its busy row turns.
            livePage.updateBusyRow(menu: menu)
        } else {
            if let current = livePage, current.key != page.key {
                let isCovered = menu.menuFolderSwapOverlayOpacity > 0.99 || menu.movieTransitionOverlayOpacity > 0.99
                    || menu.fullscreenTransitionOverlayOpacity > 0.99 || menu.menuOpacityOnScreen < 0.01
                if menu.isInSubmenu, !showsFlight, !isCovered {
                    beginSlide(from: current, toDepth: page.depth, menu: menu)
                } else {
                    current.remove()
                }
                livePage = nil
            }
            let live: TigerPageLayer
            if let livePage {
                live = livePage
            } else {
                live = TigerPageLayer(key: page.key, depth: page.depth)
                pages.addSublayer(live.layer)
                livePage = live
                contentMemo = nil
                placeSlidingPages()
            }
            live.update(page, menu: menu, pass: pass, sceneSize: size, scale: scale, showsHeader: !showsFlight)
        }

        // While its section opens from the ring (or closes), the page rides up with the title bar's line.
        if let live = livePage {
            let memo = ContentMemo(section: state.section.revision, shows: showsFlight, page: ObjectIdentifier(live), size: size)
            if memo != contentMemo {
                contentMemo = memo
                let times = TigerKeyframes.times(until: state.section.endTime)
                let rises = times.map { time -> CGPoint in
                    let opened = tigerUnit(CGFloat(state.section.value(at: time)))
                    return CGPoint(x: 0, y: (size.height - TigerTheme.dividerTopInset) * (1 - opened))
                }
                TigerKeyframes.run(live.content, position: rises, times: times)
            }
        }
    }

    /// The page on screen slides off as the next slides on: leftwards going deeper, back the
    /// other way.
    private func beginSlide(from page: TigerPageLayer, toDepth depth: Int, menu: MenuView) {
        // (A page still on its way out when the next change comes goes at once.)
        outgoingPages.forEach { $0.remove() }
        outgoingPages = [page]
        slidesForward = depth >= page.depth
        slide.set(0)
        slide.move(to: 1, duration: TigerTheme.pageSlideDuration)
        page.freeze()
        TigerMoviePreviewLayer.shared.pageWillLeave(menu: menu)
        menu.tiger.pageSlideEnd = CACurrentMediaTime() + TigerTheme.pageSlideDuration
        let leaving = page
        DispatchQueue.main.asyncAfter(deadline: .now() + TigerTheme.pageSlideDuration + 0.05) { [weak self] in
            MainActor.assumeIsolatedIfPossible {
                guard let self, let index = self.outgoingPages.firstIndex(where: { $0 === leaving }) else { return }
                self.outgoingPages.remove(at: index)
                leaving.remove()
            }
        }
    }

    private func placeSlidingPages() {
        guard let live = livePage else { return }
        let width = sceneSize.width
        let times = TigerKeyframes.times(until: slide.endTime)
        let sign: CGFloat = slidesForward ? 1 : -1
        var arriving: [CGPoint] = [], leaving: [CGPoint] = []
        for time in times {
            let progress = tigerUnit(CGFloat(slide.value(at: time)))
            arriving.append(CGPoint(x: sign * width * (1 - progress), y: 0))
            leaving.append(CGPoint(x: -sign * width * progress, y: 0))
        }
        TigerKeyframes.run(live.layer, position: outgoingPages.isEmpty ? [.zero] : arriving, times: outgoingPages.isEmpty ? [CACurrentMediaTime()] : times)
        for page in outgoingPages {
            TigerKeyframes.run(page.layer, position: leaving, times: times)
        }
    }
}

/// Pictures the Tiger look makes from others.
@MainActor
enum TigerPictures {
    /// A movie's picture as it stands behind the question about where to start it: filling
    /// the scene, well blurred, a little greyer and darker. Its edges fade out as a blur's do.
    static func softened(_ image: NSImage, sceneSize: CGSize) -> CGImage? {
        guard let source = LayerImageCache.cgImage(for: image), sceneSize.width > 0, sceneSize.height > 0 else { return nil }
        // Worked on at a quarter of the scene's size, where the blur is a quarter as wide.
        let width = 480, height = max(1, Int((480 * sceneSize.height / sceneSize.width).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: ScreenColorSpace.current ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
        ), let data = context.data else { return source }
        context.interpolationQuality = .high
        let aspect = CGFloat(source.width) / CGFloat(max(1, source.height))
        let frame = CGSize(width: width, height: height)
        let drawn = aspect > frame.width / frame.height ? CGSize(width: frame.height * aspect, height: frame.height) : CGSize(width: frame.width, height: frame.width / aspect)
        context.draw(source, in: CGRect(x: (frame.width - drawn.width) / 2, y: (frame.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var plane = [Float](repeating: 0, count: width * height * 4)
        for index in 0 ..< width * height * 4 {
            plane[index] = Float(bytes[index])
        }
        // Three box blurs come close to a Gaussian one (of 28 points at the scene's size).
        var scratch = plane
        for _ in 0 ..< 3 {
            boxBlur(&plane, &scratch, width: width, height: height, radius: 7, horizontal: true)
            boxBlur(&plane, &scratch, width: width, height: height, radius: 7, horizontal: false)
        }
        // (Blue, green, red, alpha; the colours already multiplied by the alpha.)
        for pixel in 0 ..< width * height {
            let at = pixel * 4
            let blue = plane[at], green = plane[at + 1], red = plane[at + 2]
            let grey = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            for (offset, value) in [(0, blue), (1, green), (2, red)] {
                let muted = grey + (value - grey) * 0.92
                bytes[at + offset] = UInt8(max(0, min(255, muted * 0.67)))
            }
            bytes[at + 3] = UInt8(max(0, min(255, plane[at + 3])))
        }
        return context.makeImage() ?? source
    }

    /// A blur along rows or columns: each value becomes the mean of those within `radius` of
    /// it, counting what lies past the picture's edge as clear.
    private static func boxBlur(_ plane: inout [Float], _ scratch: inout [Float], width: Int, height: Int, radius: Int, horizontal: Bool) {
        let span = Float(radius * 2 + 1)
        let lines = horizontal ? height : width
        let length = horizontal ? width : height
        let step = horizontal ? 4 : width * 4
        for line in 0 ..< lines {
            let start = horizontal ? line * width * 4 : line * 4
            for channel in 0 ..< 4 {
                var sum: Float = 0
                for index in 0 ... min(radius, length - 1) {
                    sum += plane[start + index * step + channel]
                }
                for index in 0 ..< length {
                    scratch[start + index * step + channel] = sum / span
                    let entering = index + radius + 1, leaving = index - radius
                    if entering < length { sum += plane[start + entering * step + channel] }
                    if leaving >= 0 { sum -= plane[start + leaving * step + channel] }
                }
            }
        }
        swap(&plane, &scratch)
    }
}
