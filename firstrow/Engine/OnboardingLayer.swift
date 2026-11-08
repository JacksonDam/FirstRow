import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// The first-launch screens over everything: a title, a line under it, and two cards side by
/// side to pick from (pictures of the two looks, then the two ways of controlling), the one
/// picked out a little larger with a ring round it.
@MainActor
final class OnboardingLayer {
    let layer = SceneLayer()
    private let backdrop = SceneGradientLayer()
    private let content = SceneLayer()
    private let title = SceneLayer()
    private let subtitle = SceneLayer()

    private final class Card {
        let layer = SceneLayer()
        let ring = SceneLayer()
        let face = SceneLayer()
        let picture = SceneLayer()
        let label = SceneLayer()

        init() {
            face.masksToBounds = true
            face.addSublayer(picture)
            layer.addSublayer(ring)
            layer.addSublayer(face)
            layer.addSublayer(label)
            ring.borderColor = CGColor(gray: 1, alpha: 1)
            ring.borderWidth = 6
            face.backgroundColor = CGColor(gray: 0.1, alpha: 1)
            face.borderColor = CGColor(gray: 1, alpha: 0.14)
            face.borderWidth = 1.5
        }
    }

    private let cards = [Card(), Card()]
    private var builtKey = ""
    private var lastFocus: Int?
    /// The cards in canvas points, for the pointer and fingers.
    private(set) var cardFrames: [CGRect] = []
    private(set) var canvasScale: CGFloat = 1

    private static let cardSize = CGSize(width: 560, height: 315)

    init() {
        layer.isHidden = true
        layer.addSublayer(backdrop)
        layer.addSublayer(content)
        backdrop.colors = [CGColor(gray: 0.09, alpha: 1), CGColor(gray: 0.015, alpha: 1)]
        backdrop.startPoint = CGPoint(x: 0.5, y: 0)
        backdrop.endPoint = CGPoint(x: 0.5, y: 1)
        for sublayer in [title, subtitle] + cards.map(\.layer) {
            content.addSublayer(sublayer)
        }
    }

    func update(menu: MenuView, pass: RenderPass, bounds: CGRect, scale backingScale: CGFloat) {
        guard let step = menu.onboardingStep else {
            layer.isHidden = true
            builtKey = ""
            lastFocus = nil
            cardFrames = []
            return
        }
        layer.isHidden = false
        layer.frame = bounds
        backdrop.frame = CGRect(origin: .zero, size: bounds.size)
        layer.setOpacity(menu.onboardingOpacity, pass.animation)
        let canvas = FullscreenCanvas(screenSize: bounds.size)
        canvas.apply(to: content)
        canvasScale = canvas.scale
        content.setOpacity(menu.onboardingContentOpacity, pass.animation)
        let pixelScale = canvas.pixelScale(backingScale: backingScale)
        let size = canvas.size

        // Laid out once per screen and size.
        let card = Self.cardSize
        let gap: CGFloat = 90
        let blockHeight: CGFloat = 80 + 24 + 40 + 76 + card.height + 40 + 48
        let top = ((size.height - blockHeight) / 2).rounded()
        let cardsTop = top + 80 + 24 + 40 + 76
        let left = ((size.width - card.width * 2 - gap) / 2).rounded()
        cardFrames = (0 ..< 2).map { CGRect(x: left + CGFloat($0) * (card.width + gap), y: cardsTop, width: card.width, height: card.height) }
        let key = "\(step)|\(size.width)|\(size.height)|\(pixelScale)"
        if key != builtKey {
            builtKey = key
            lastFocus = nil
            let titleGraphic = TextRenderer.render(TextSpec(text: menu.onboardingTitle, fontName: ModernTheme.boldFontName, size: 66, color: .white), scale: pixelScale)
            title.show(titleGraphic, at: CGPoint(x: ((size.width - titleGraphic.size.width) / 2).rounded(), y: top))
            let subtitleGraphic = TextRenderer.render(TextSpec(
                text: menu.onboardingSubtitle,
                fontName: ModernTheme.regularFontName,
                size: 30,
                color: RGBA(white: 1, alpha: 0.6),
                maxWidth: min(size.width - 120, 1500),
                minimumScaleFactor: 0.7,
            ), scale: pixelScale)
            subtitle.show(subtitleGraphic, at: CGPoint(x: ((size.width - subtitleGraphic.size.width) / 2).rounded(), y: top + 80 + 24))
            for (index, option) in menu.onboardingOptions.enumerated() where index < cards.count {
                let entry = cards[index]
                let frame = cardFrames[index]
                entry.layer.place(frame)
                let local = CGRect(origin: .zero, size: frame.size)
                entry.face.frame = local
                entry.face.cornerRadius = 26
                entry.ring.frame = local.insetBy(dx: -11, dy: -11)
                entry.ring.cornerRadius = 26 + 11
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
                        ? Self.classicPreview(pixelScale: max(1, pixelScale * shrink * 1.1))
                        : Self.modernPreview(pixelScale: max(1, pixelScale * shrink * 1.1))
                    preview.transform = CATransform3DMakeScale(shrink, shrink, 1)
                    entry.picture.addSublayer(preview)
                }
                let labelGraphic = TextRenderer.render(TextSpec(text: option.title, fontName: ModernTheme.mediumFontName, size: 40, color: .white), scale: pixelScale)
                entry.label.show(labelGraphic, at: CGPoint(x: ((frame.width - labelGraphic.size.width) / 2).rounded(), y: frame.height + 40))
            }
        }

        // The option picked out: full size and bright, with its ring; the other a little
        // smaller and dimmer.
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
            entry.ring.setOpacity(focused ? 1 : 0, animation)
        }
    }

    /// The option at a window point.
    func option(atWindowPoint point: CGPoint) -> Int? {
        let canvasPoint = CGPoint(x: point.x / max(canvasScale, 0.0001), y: point.y / max(canvasScale, 0.0001))
        // The card and its name under it, with a little room round them.
        return cardFrames.firstIndex { CGRect(x: $0.minX - 24, y: $0.minY - 24, width: $0.width + 48, height: $0.height + 130).contains(canvasPoint) }
    }

    // MARK: - The two looks

    /// The classic main menu: the Movies icon over its reflection, and the list with the glossy
    /// selection bar on Movies.
    private static func classicPreview(pixelScale: CGFloat) -> SceneLayer {
        let root = SceneLayer()
        root.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        if let icon = LayerImageCache.cgImage(for: NSImage(named: "movies")) {
            let picture = SceneLayer()
            picture.contents = icon
            picture.contentsGravity = .resizeAspect
            picture.frame = CGRect(x: 230, y: 220, width: 560, height: 560)
            root.addSublayer(picture)
            let reflection = SceneLayer()
            reflection.contents = icon
            reflection.contentsGravity = .resizeAspect
            reflection.frame = CGRect(x: 230, y: 780, width: 560, height: 560)
            reflection.transform = CATransform3DMakeScale(1, -1, 1)
            reflection.opacity = 0.35
            let fade = SceneGradientLayer()
            fade.frame = reflection.bounds
            fade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)]
            fade.locations = [0, 0.6, 1]
            fade.startPoint = CGPoint(x: 0.5, y: 0)
            fade.endPoint = CGPoint(x: 0.5, y: 1)
            reflection.mask = fade
            root.addSublayer(reflection)
        }
        let listLeft: CGFloat = 990
        let listWidth: CGFloat = 740
        let rowHeight: CGFloat = 74
        let pitch: CGFloat = 84
        let firstTop: CGFloat = 250
        let heading = TextRenderer.render(TextSpec(text: "First Row", fontName: firstRowBoldFontName, size: 52, color: .white), scale: pixelScale)
        let headingLayer = SceneLayer()
        headingLayer.show(heading, at: CGPoint(x: (listLeft + (listWidth - heading.size.width) / 2).rounded(), y: 120))
        root.addSublayer(headingLayer)
        let selection = SelectionBoxLayer()
        let selected = CGRect(x: listLeft, y: firstTop, width: listWidth, height: rowHeight)
        let spill = rowHeight / 75
        selection.update(frame: selected.insetBy(dx: -40 * spill, dy: -29 * spill), selectionBoxHeight: rowHeight, animation: nil)
        root.addSublayer(selection.layer)
        let chevron = SymbolRenderer.render("chevron.right", pointSize: 30, weight: .bold, color: .white, scale: pixelScale)
        for (index, name) in ["Movies", "TV Shows", "Music", "Podcasts", "Photos", "Settings"].enumerated() {
            let top = firstTop + CGFloat(index) * pitch
            let text = TextRenderer.render(TextSpec(text: name, fontName: firstRowBoldFontName, size: 46, color: .white), scale: pixelScale)
            let label = SceneLayer()
            label.show(text, at: CGPoint(x: listLeft + 36, y: (top + (rowHeight - text.size.height) / 2).rounded()))
            root.addSublayer(label)
            let arrow = SceneLayer()
            arrow.show(chevron, at: CGPoint(x: listLeft + listWidth - 36 - chevron.size.width, y: (top + (rowHeight - chevron.size.height) / 2).rounded()))
            root.addSublayer(arrow)
        }
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
