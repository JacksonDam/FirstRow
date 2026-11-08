import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// The first-launch screens over everything: a title, a line under it, and either two cards side
/// by side to pick from (pictures of the two looks, then the two ways of controlling; the one
/// picked out a little larger with a ring round it) or the controls for the way chosen, with
/// Get Started. Everything is drawn in both looks and crossfades to the one being worn, which on
/// the first screen is the one picked out.
@MainActor
final class OnboardingLayer {
    let layer = SceneLayer()
    private let content = SceneLayer()

    /// What's drawn differently in each look.
    @MainActor
    private final class Chrome {
        let layer = SceneLayer()
        let backdrop = SceneGradientLayer()
        /// The words and controls, which fade a little apart from the backdrop.
        let ink = SceneLayer()
        let title = SceneLayer()
        let subtitle = SceneLayer()
        let labels = [SceneLayer(), SceneLayer()]
        let tips = SceneLayer()
        let button = SceneLayer()
        let buttonFill = SceneLayer()
        let buttonSelection = SelectionBoxLayer()
        let buttonLabel = SceneLayer()

        init() {
            layer.addSublayer(backdrop)
            layer.addSublayer(ink)
            for sublayer in [title, subtitle, labels[0], labels[1], tips, button] {
                ink.addSublayer(sublayer)
            }
            button.addSublayer(buttonFill)
            button.addSublayer(buttonSelection.layer)
            button.addSublayer(buttonLabel)
            backdrop.startPoint = CGPoint(x: 0.5, y: 0)
            backdrop.endPoint = CGPoint(x: 0.5, y: 1)
        }
    }

    @MainActor
    private final class Card {
        let layer = SceneLayer()
        let face = SceneLayer()
        let picture = SceneLayer()
        /// The ring round the one picked out, in each look.
        let rings: [InterfaceTheme: SceneLayer] = [.classic: SceneLayer(), .modern: SceneLayer()]

        init() {
            face.masksToBounds = true
            face.addSublayer(picture)
            for look in [InterfaceTheme.classic, .modern] {
                if let ring = rings[look] { layer.addSublayer(ring) }
            }
            layer.addSublayer(face)
            face.borderColor = CGColor(gray: 1, alpha: 0.14)
            face.borderWidth = 1.5
            // Modern: a white ring. Classic: the menus' blue glow.
            rings[.modern]?.borderColor = CGColor(gray: 1, alpha: 1)
            rings[.modern]?.borderWidth = 6
            rings[.classic]?.borderColor = CGColor(red: 0.42, green: 0.72, blue: 1, alpha: 1)
            rings[.classic]?.borderWidth = 4
            rings[.classic]?.shadowColor = CGColor(red: 0.2, green: 0.55, blue: 1, alpha: 1)
            rings[.classic]?.shadowOpacity = 1
            rings[.classic]?.shadowRadius = 14
            rings[.classic]?.shadowOffset = .zero
        }
    }

    private let chromes: [InterfaceTheme: Chrome] = [.classic: Chrome(), .modern: Chrome()]
    private let cardsLayer = SceneLayer()
    private let cards = [Card(), Card()]
    private var builtKey = ""
    private var lastFocus: Int?
    private var lastLook: InterfaceTheme?
    /// The cards (or Get Started) in canvas points, for the pointer and fingers.
    private(set) var cardFrames: [CGRect] = []
    private(set) var canvasScale: CGFloat = 1

    private static let cardSize = CGSize(width: 560, height: 315)
    private static let looks: [InterfaceTheme] = [.classic, .modern]

    init() {
        layer.isHidden = true
        // Solid underneath, so nothing behind shows while the looks crossfade.
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        for look in Self.looks {
            if let chrome = chromes[look] { content.addSublayer(chrome.layer) }
        }
        content.addSublayer(cardsLayer)
        for card in cards { cardsLayer.addSublayer(card.layer) }
        layer.addSublayer(content)
    }

    private static func fonts(_ look: InterfaceTheme) -> (bold: String, medium: String, regular: String) {
        look == .modern
            ? (ModernTheme.boldFontName, ModernTheme.mediumFontName, ModernTheme.regularFontName)
            : (firstRowBoldFontName, firstRowBoldFontName, firstRowRegularFontName)
    }

    func update(menu: MenuView, pass: RenderPass, bounds: CGRect, scale backingScale: CGFloat) {
        guard let step = menu.onboardingStep else {
            layer.isHidden = true
            builtKey = ""
            lastFocus = nil
            lastLook = nil
            cardFrames = []
            return
        }
        layer.isHidden = false
        layer.frame = bounds
        layer.setOpacity(menu.onboardingOpacity, pass.animation)
        let canvas = FullscreenCanvas(screenSize: bounds.size)
        canvas.apply(to: content)
        canvasScale = canvas.scale
        let pixelScale = canvas.pixelScale(backingScale: backingScale)
        let size = canvas.size
        let look = menu.onboardingLook

        // The look being worn: the backdrops crossfade, and the words of the last look go a
        // moment before the new one's come, so the two never sit on top of each other.
        let lookChanged = lastLook != nil && lastLook != look
        let lookAnimation: Animation? = lookChanged ? .smoothInOut(duration: 0.45) : nil
        lastLook = look
        for candidate in Self.looks {
            guard let chrome = chromes[candidate] else { continue }
            let wearing = candidate == look
            chrome.layer.frame = CGRect(origin: .zero, size: size)
            chrome.ink.frame = CGRect(origin: .zero, size: size)
            chrome.backdrop.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            chrome.backdrop.setOpacity(wearing ? 1 : 0, lookAnimation)
            chrome.ink.setOpacity(wearing ? 1 : 0, lookChanged ? (wearing ? .smooth(duration: 0.26).delay(0.16) : .smoothInOut(duration: 0.18)) : nil)
        }
        // The screen's contents fade between screens; the backdrop stays.
        for candidate in Self.looks {
            guard let chrome = chromes[candidate] else { continue }
            for sublayer in [chrome.title, chrome.subtitle, chrome.labels[0], chrome.labels[1], chrome.tips, chrome.button] {
                sublayer.setOpacity(menu.onboardingContentOpacity, pass.animation)
            }
        }
        cardsLayer.setOpacity(menu.onboardingContentOpacity, pass.animation)

        let tips = menu.onboardingTips
        let isGuide = step == .guide
        let card = Self.cardSize
        let gap: CGFloat = 90
        let tipPitch: CGFloat = 70
        let buttonSize = CGSize(width: 440, height: 86)
        let middleHeight = isGuide ? CGFloat(tips.count) * tipPitch + 50 + buttonSize.height : card.height + 40 + 48
        let blockHeight: CGFloat = 80 + 24 + 40 + 76 + middleHeight
        let top = ((size.height - blockHeight) / 2).rounded()
        let middleTop = top + 80 + 24 + 40 + 76
        let left = ((size.width - card.width * 2 - gap) / 2).rounded()
        let buttonFrame = CGRect(x: ((size.width - buttonSize.width) / 2).rounded(), y: middleTop + CGFloat(tips.count) * tipPitch + 50, width: buttonSize.width, height: buttonSize.height)
        cardFrames = isGuide
            ? [buttonFrame]
            : (0 ..< 2).map { CGRect(x: left + CGFloat($0) * (card.width + gap), y: middleTop, width: card.width, height: card.height) }

        let key = "\(step)|\(size.width)|\(size.height)|\(pixelScale)|\(menu.onboardingSubtitle)|\(tips.map(\.text))"
        if key != builtKey {
            builtKey = key
            lastFocus = nil
            for candidate in Self.looks {
                guard let chrome = chromes[candidate] else { continue }
                build(chrome, look: candidate, menu: menu, step: step, size: size, top: top, middleTop: middleTop, tipPitch: tipPitch, buttonFrame: buttonFrame, pixelScale: pixelScale)
            }
            cardsLayer.isHidden = isGuide
            if !isGuide { buildCards(menu: menu, pixelScale: pixelScale) }
        }

        // The option picked out: full size and bright, with its ring; the other a little
        // smaller and dimmer.
        guard !isGuide else { return }
        let focus = menu.onboardingFocus
        let animation: Animation? = lastFocus == nil ? nil : pass.animation
        lastFocus = focus
        for (index, entry) in cards.enumerated() {
            let focused = index == focus
            let frame = cardFrames[index]
            let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
            var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
            let factor: CGFloat = focused ? 1.04 : 0.95
            transform = CATransform3DScale(transform, factor, factor, 1)
            transform = CATransform3DTranslate(transform, -center.x, -center.y, 0)
            entry.layer.setTransform(transform, animation)
            entry.layer.setOpacity(focused ? 1 : 0.5, animation)
            for candidate in Self.looks {
                entry.rings[candidate]?.setOpacity(focused && candidate == look ? 1 : 0, animation ?? lookAnimation)
            }
            for candidate in Self.looks {
                chromes[candidate]?.labels[index].setOpacity((focused ? 1 : 0.5) * menu.onboardingContentOpacity, animation)
            }
        }
    }

    /// One look's words and the controls screen's list and button.
    private func build(_ chrome: Chrome, look: InterfaceTheme, menu: MenuView, step: OnboardingStep, size: CGSize, top: CGFloat, middleTop: CGFloat, tipPitch: CGFloat, buttonFrame: CGRect, pixelScale: CGFloat) {
        let fonts = Self.fonts(look)
        let isModern = look == .modern
        chrome.backdrop.colors = isModern
            ? [CGColor(gray: 0.09, alpha: 1), CGColor(gray: 0.015, alpha: 1)]
            : [CGColor(gray: 0, alpha: 1), CGColor(red: 0.01, green: 0.02, blue: 0.05, alpha: 1)]
        let titleGraphic = TextRenderer.render(TextSpec(text: menu.onboardingTitle, fontName: fonts.bold, size: 66, color: .white), scale: pixelScale)
        chrome.title.show(titleGraphic, at: CGPoint(x: ((size.width - titleGraphic.size.width) / 2).rounded(), y: top))
        let subtitleGraphic = TextRenderer.render(TextSpec(
            text: menu.onboardingSubtitle,
            fontName: fonts.regular,
            size: 30,
            color: RGBA(white: 1, alpha: 0.6),
            maxWidth: min(size.width - 120, 1500),
            minimumScaleFactor: 0.7,
        ), scale: pixelScale)
        chrome.subtitle.show(subtitleGraphic, at: CGPoint(x: ((size.width - subtitleGraphic.size.width) / 2).rounded(), y: top + 80 + 24))

        // The two cards' names.
        let options = menu.onboardingOptions
        for index in 0 ..< 2 {
            let label = chrome.labels[index]
            guard step != .guide, options.indices.contains(index), cardFrames.indices.contains(index) else {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            let frame = cardFrames[index]
            let graphic = TextRenderer.render(TextSpec(text: options[index].title, fontName: fonts.medium, size: 40, color: .white), scale: pixelScale)
            label.show(graphic, at: CGPoint(x: (frame.midX - graphic.size.width / 2).rounded(), y: frame.maxY + 40))
        }

        // The controls: a symbol and a line for each, then Get Started.
        chrome.tips.sublayers?.forEach { $0.removeFromSuperlayer() }
        chrome.button.isHidden = step != .guide
        guard step == .guide else { return }
        let tips = menu.onboardingTips
        let rendered = tips.map { TextRenderer.render(TextSpec(text: $0.text, fontName: fonts.regular, size: 32, color: RGBA(white: 1, alpha: 0.92), maxWidth: 1100), scale: pixelScale) }
        let columnWidth = 76 + (rendered.map(\.size.width).max() ?? 0)
        let columnLeft = ((size.width - columnWidth) / 2).rounded()
        for (index, tip) in tips.enumerated() {
            let rowTop = middleTop + CGFloat(index) * tipPitch
            let symbol = SymbolRenderer.render(tip.symbol, pointSize: 30, weight: .semibold, color: isModern ? .white : RGBA(red: 0.55, green: 0.78, blue: 1), scale: pixelScale)
            let icon = SceneLayer()
            icon.show(symbol, at: CGPoint(x: (columnLeft + (44 - symbol.size.width) / 2).rounded(), y: (rowTop + (tipPitch - symbol.size.height) / 2).rounded()))
            chrome.tips.addSublayer(icon)
            let text = SceneLayer()
            text.show(rendered[index], at: CGPoint(x: columnLeft + 76, y: (rowTop + (tipPitch - rendered[index].size.height) / 2).rounded()))
            chrome.tips.addSublayer(text)
        }
        // Get Started, picked out in the look's way: a white capsule, or the glossy bar.
        chrome.button.frame = buttonFrame
        let local = CGRect(origin: .zero, size: buttonFrame.size)
        chrome.buttonFill.isHidden = !isModern
        chrome.buttonSelection.layer.isHidden = isModern
        if isModern {
            chrome.buttonFill.frame = local
            chrome.buttonFill.cornerRadius = local.height / 2
            chrome.buttonFill.backgroundColor = ModernTheme.focusFill.cgColor
        } else {
            let spill = local.height / 75
            chrome.buttonSelection.update(frame: local.insetBy(dx: -40 * spill, dy: -29 * spill), selectionBoxHeight: local.height, animation: nil)
        }
        let labelGraphic = TextRenderer.render(TextSpec(text: "Get Started", fontName: fonts.medium, size: 38, color: isModern ? ModernTheme.focusedText : .white), scale: pixelScale)
        chrome.buttonLabel.show(labelGraphic, at: CGPoint(x: ((local.width - labelGraphic.size.width) / 2).rounded(), y: ((local.height - labelGraphic.size.height) / 2).rounded()))
    }

    /// The cards' pictures: the two looks, or a symbol for each way of controlling.
    private func buildCards(menu: MenuView, pixelScale: CGFloat) {
        for (index, option) in menu.onboardingOptions.enumerated() where index < cards.count {
            let entry = cards[index]
            let frame = cardFrames[index]
            entry.layer.place(frame)
            let local = CGRect(origin: .zero, size: frame.size)
            entry.face.frame = local
            entry.face.cornerRadius = 26
            for ring in entry.rings.values {
                ring.frame = local.insetBy(dx: -11, dy: -11)
                ring.cornerRadius = 26 + 11
            }
            entry.picture.sublayers?.forEach { $0.removeFromSuperlayer() }
            entry.picture.contents = nil
            entry.picture.frame = local
            if let symbol = option.symbol {
                entry.face.backgroundColor = CGColor(gray: 0.16, alpha: 1)
                let glyph = SymbolRenderer.render(symbol, pointSize: 120, weight: .regular, color: RGBA(white: 1, alpha: 0.92), scale: pixelScale)
                let holder = SceneLayer()
                holder.show(glyph, at: CGPoint(x: ((local.width - glyph.size.width) / 2).rounded(), y: ((local.height - glyph.size.height) / 2).rounded()))
                entry.picture.addSublayer(holder)
            } else {
                entry.face.backgroundColor = CGColor(gray: 0, alpha: 1)
                // A picture of the look, drawn at full scene size and shrunk onto the card.
                let shrink = local.width / 1920
                let preview = index == 0
                    ? classicPreview(menu: menu, pixelScale: max(1, pixelScale * shrink * 1.1))
                    : Self.modernPreview(pixelScale: max(1, pixelScale * shrink * 1.1))
                preview.transform = CATransform3DMakeScale(shrink, shrink, 1)
                entry.picture.addSublayer(preview)
            }
        }
    }

    /// The option at a window point (a card, or Get Started).
    func option(atWindowPoint point: CGPoint) -> Int? {
        let canvasPoint = CGPoint(x: point.x / max(canvasScale, 0.0001), y: point.y / max(canvasScale, 0.0001))
        // A card and its name under it, with a little room round them.
        if cardFrames.count == 1 {
            return cardFrames[0].insetBy(dx: -16, dy: -16).contains(canvasPoint) ? 0 : nil
        }
        return cardFrames.firstIndex { CGRect(x: $0.minX - 24, y: $0.minY - 24, width: $0.width + 48, height: $0.height + 130).contains(canvasPoint) }
    }

    // MARK: - The two looks

    /// The classic main menu, made of the menus' own parts: the icon carousel (Movies at the
    /// front, the others round the arc behind it, with their reflections), the title, and the
    /// list with the glossy selection bar on Movies.
    private var previewCarousel: RootCarouselLayerController?
    private var previewList: MenuListLayer?

    private func classicPreview(menu: MenuView, pixelScale: CGFloat) -> SceneLayer {
        let sceneSize = MenuVirtualScenePreset.widescreen
        let frames = menu.sceneFrames(sceneSize: sceneSize, classicLayout: true)
        let root = SceneLayer()
        root.frame = CGRect(origin: .zero, size: sceneSize)
        root.backgroundColor = CGColor(gray: 0, alpha: 1)

        let carousel = previewCarousel ?? RootCarouselLayerController()
        previewCarousel = carousel
        var configuration = menu.rootCarouselConfiguration(sceneSize: sceneSize)
        configuration.selectedIndex = 0
        configuration.isIconAnimated = false
        configuration.isEnteringSubmenu = false
        configuration.isReturningToRoot = false
        configuration.isInSubmenu = false
        configuration.showsSettledLandedIcon = false
        configuration.boxOriginInScene = frames.carouselFrame.origin
        carousel.rootLayer.removeFromSuperlayer()
        // Set up as the menus' own carousel is: a box, and a space inside it laid out as the
        // carousel expects.
        let box = SceneLayer()
        box.frame = frames.carouselFrame
        let space = SceneLayer()
        space.frame = CGRect(origin: .zero, size: frames.carouselFrame.size)
        #if os(macOS) || FIRSTROW_PORTABLE
            space.isGeometryFlipped = true
        #endif
        box.addSublayer(space)
        carousel.rootLayer.frame = space.bounds
        space.addSublayer(carousel.rootLayer)
        carousel.update(configuration, bounds: frames.carouselFrame.size)
        root.addSublayer(box)

        let heading = TextRenderer.render(TextSpec(text: "First Row", fontName: firstRowBoldFontName, size: 60, maxWidth: sceneSize.width), scale: pixelScale)
        let headingLayer = SceneLayer()
        let centerX = sceneSize.width * 0.5 + menu.rootMenuHeaderOffsetX(sceneSize: sceneSize)
        headingLayer.show(heading, at: CGPoint(x: (centerX - heading.size.width / 2).rounded(), y: frames.headerTop))
        root.addSublayer(headingLayer)

        let list = previewList ?? MenuListLayer()
        previewList = list
        list.reset()
        list.layer.removeFromSuperlayer()
        let menuArea = SceneLayer()
        menuArea.frame = frames.menuFrame
        root.addSublayer(menuArea)
        list.layer.place(CGRect(x: 0, y: 0, width: frames.menuFrame.width, height: menu.menuListLayoutHeight(for: menu.defaultVisibleMenuRowCount)))
        list.update(MenuListLayer.Configuration(
            items: menu.rootListItems(),
            selectedIndex: 0,
            menuWidth: frames.menuFrame.width,
            arrowAppearance: menu.menuArrowAppearance,
            showsTopOverflowFade: false,
            visibleRowCount: menu.defaultVisibleMenuRowCount,
            theme: .classic,
        ), menu: menu, pass: RenderPass(transaction: .instant), scale: pixelScale)
        menuArea.addSublayer(list.layer)
        return root
    }

    /// The modern main menu: the section's card on the left and the list of capsules, Movies
    /// picked out in white.
    private static func modernPreview(pixelScale: CGFloat) -> SceneLayer {
        let root = SceneLayer()
        root.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let shade = SceneGradientLayer()
        shade.frame = root.bounds
        shade.colors = [CGColor(gray: 0.12, alpha: 1), CGColor(gray: 0.035, alpha: 1)]
        shade.startPoint = CGPoint(x: 0.3, y: 0)
        shade.endPoint = CGPoint(x: 0.7, y: 1)
        root.addSublayer(shade)
        let card = SceneLayer()
        card.frame = CGRect(x: 195, y: 238, width: 540, height: 540)
        card.cornerRadius = 70
        card.backgroundColor = CGColor(gray: 0.23, alpha: 1)
        root.addSublayer(card)
        let film = SymbolRenderer.render("film.fill", pointSize: 190, weight: .regular, color: RGBA(white: 0.07, alpha: 1), scale: pixelScale)
        let filmLayer = SceneLayer()
        filmLayer.show(film, at: CGPoint(x: ((540 - film.size.width) / 2).rounded(), y: ((540 - film.size.height) / 2).rounded()))
        card.addSublayer(filmLayer)
        let listLeft: CGFloat = 945
        let listWidth: CGFloat = 780
        let capsuleHeight: CGFloat = 66
        let pitch: CGFloat = 80
        let firstTop: CGFloat = 231
        let heading = TextRenderer.render(TextSpec(text: "First Row", fontName: ModernTheme.boldFontName, size: 56, color: RGBA(white: 1, alpha: 0.5)), scale: pixelScale)
        let headingLayer = SceneLayer()
        headingLayer.show(heading, at: CGPoint(x: (listLeft + (listWidth - heading.size.width) / 2).rounded(), y: 118))
        root.addSublayer(headingLayer)
        for (index, name) in ["Movies", "TV Shows", "Music", "Podcasts", "Photos", "Settings", "Sources"].enumerated() {
            let focused = index == 0
            let top = firstTop + CGFloat(index) * pitch
            var frame = CGRect(x: listLeft, y: top, width: listWidth, height: capsuleHeight)
            if focused { frame = frame.insetBy(dx: -ModernTheme.focusGrowth.width, dy: -ModernTheme.focusGrowth.height) }
            let capsule = SceneLayer()
            capsule.frame = frame
            capsule.cornerRadius = frame.height / 2
            capsule.backgroundColor = (focused ? ModernTheme.focusFill : ModernTheme.rowFill).cgColor
            root.addSublayer(capsule)
            let color = focused ? ModernTheme.focusedText : ModernTheme.text
            let text = TextRenderer.render(TextSpec(text: name, fontName: ModernTheme.mediumFontName, size: ModernTheme.rowTitleSize, color: color), scale: pixelScale)
            let label = SceneLayer()
            label.show(text, at: CGPoint(x: listLeft + ModernTheme.rowTextInset, y: (top + (capsuleHeight - text.size.height) / 2).rounded()))
            root.addSublayer(label)
            let chevron = SymbolRenderer.render("chevron.right", pointSize: 25, weight: .semibold, color: focused ? ModernTheme.focusedSecondaryText : ModernTheme.secondaryText, scale: pixelScale)
            let arrow = SceneLayer()
            arrow.show(chevron, at: CGPoint(x: listLeft + listWidth - ModernTheme.rowTextInset + 6 - chevron.size.width, y: (top + (capsuleHeight - chevron.size.height) / 2).rounded()))
            root.addSublayer(arrow)
        }
        return root
    }
}
