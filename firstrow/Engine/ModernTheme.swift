import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// The modern look: flat capsules and a large card on a black blurred background, in the
/// system font, as on today's Apple TV.
enum ModernTheme {
    static var isActive: Bool {
        AppSettings.theme == .modern
    }

    // MARK: - Fonts

    static let regularFontName = "FirstRowModern Regular"
    static let mediumFontName = "FirstRowModern Medium"
    static let semiboldFontName = "FirstRowModern Semi"
    static let boldFontName = "FirstRowModern Heavy"

    #if os(macOS)
        static func systemFontWeight(for name: String) -> NSFont.Weight? {
            guard name.hasPrefix("FirstRowModern") else { return nil }
            switch name {
            case mediumFontName: return .medium
            case semiboldFontName: return .semibold
            case boldFontName: return .bold
            default: return .regular
            }
        }
    #elseif canImport(UIKit)
        static func systemFontWeight(for name: String) -> UIFont.Weight? {
            guard name.hasPrefix("FirstRowModern") else { return nil }
            switch name {
            case mediumFontName: return .medium
            case semiboldFontName: return .semibold
            case boldFontName: return .bold
            default: return .regular
            }
        }
    #endif

    // MARK: - Colours

    static let rowFill = RGBA(white: 1, alpha: 0.11)
    static let text = RGBA(white: 1, alpha: 0.94)
    static let secondaryText = RGBA(white: 1, alpha: 0.46)
    static let focusedText = RGBA(white: 0.04)
    static let focusedSecondaryText = RGBA(white: 0.04, alpha: 0.55)
    static let title = RGBA(white: 1, alpha: 0.5)
    static let focusFill = RGBA(white: 1)
    static let tileFill = RGBA(white: 1, alpha: 0.18)
    static let tileGlyph = RGBA(white: 0, alpha: 0.7)

    // MARK: - Sizes (scene points)

    static let titleSize: CGFloat = 54
    static let rowTitleSize: CGFloat = 37
    static let trailingTextSize: CGFloat = 32
    /// Space between a capsule's ends and its text.
    static let rowTextInset: CGFloat = 36
    /// How much shorter a row's capsule is than the row.
    static let rowCapsuleInset: CGFloat = 9
    /// How far the focused capsule grows past its row on each side.
    static let focusGrowth = CGSize(width: 5, height: 4)
    static let focusedContentScale: CGFloat = 1.03
    static let focusDuration: Double = 0.34
    /// Lists slide this far as they come and go.
    static let listSlideDistance: CGFloat = 70

    /// Where the card and the list sit in a scene of this size.
    struct SceneLayout {
        let cardFrame: CGRect
        let menuFrame: CGRect
    }

    static func layout(sceneSize: CGSize, menuHeight: CGFloat) -> SceneLayout {
        let width = sceneSize.width
        let listWidth = min(780, (width * 0.406).rounded())
        let cardSide = min(540, (width * 0.281).rounded())
        let gap = (width * 0.11).rounded()
        // The card and the list together sit in the middle of the screen.
        let left = ((width - cardSide - gap - listWidth) * 0.5).rounded()
        let cardCenterY = (sceneSize.height * 0.47).rounded()
        return SceneLayout(
            cardFrame: CGRect(x: left, y: cardCenterY - cardSide / 2, width: cardSide, height: cardSide),
            menuFrame: CGRect(x: left + cardSide + gap, y: (sceneSize.height * 0.209).rounded(), width: listWidth, height: menuHeight),
        )
    }

    // MARK: - Glyphs

    /// The symbol a section's card shows when there's nothing more particular to show.
    static func glyphName(forRootID rootID: String?) -> String {
        switch rootID {
        case "movies": "film.fill"
        case "tv_shows": "tv.fill"
        case "music": "music.note"
        case "podcasts": "mic.fill"
        case "photos": "photo.fill"
        case "settings": "gearshape.fill"
        case "sources": "externaldrive.fill"
        default: "play.rectangle.fill"
        }
    }
}

// MARK: - Background

/// A black, softly blurred backdrop, tinted faintly by whatever the card is showing.
@MainActor
final class ModernBackgroundLayer {
    let layer = SceneLayer()
    private let base = SceneLayer()
    private var ambient: SceneLayer?
    private var ambientKey: String?

    init() {
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.masksToBounds = true
        base.contentsGravity = .resize
        base.magnificationFilter = .linear
        base.contents = Self.baseImage
        layer.addSublayer(base)
        layer.isHidden = true
    }

    func layout(size: CGSize) {
        withoutLayerActions {
            layer.frame = CGRect(origin: .zero, size: size)
            base.frame = layer.bounds
            ambient?.frame = layer.bounds
        }
    }

    /// Tints the backdrop with a heavily blurred, darkened copy of `image` (nil for plain black).
    func setAmbient(_ image: NSImage?, key: String?) {
        guard key != ambientKey else { return }
        ambientKey = key
        let fade = Animation.smoothInOut(duration: 0.7)
        if let old = ambient {
            old.setOpacity(0, fade)
            DispatchQueue.main.asyncAfter(deadline: .now() + fade.duration + 0.05) { old.removeFromSuperlayer() }
            ambient = nil
        }
        guard let image, let blurred = Self.blurredAmbient(image) else { return }
        let next = SceneLayer()
        next.contents = blurred
        next.contentsGravity = .resizeAspectFill
        next.magnificationFilter = .linear
        next.frame = layer.bounds
        next.opacity = 0
        layer.addSublayer(next)
        next.setOpacity(0.55, fade)
        ambient = next
    }

    /// Near black, with two broad soft glows so it reads as blurred rather than flat.
    private static let baseImage: CGImage? = {
        let size = CGSize(width: 320, height: 180)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0.012, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func glow(_ center: CGPoint, radius: CGFloat, white: CGFloat, alpha: CGFloat) {
            let colors = [CGColor(gray: white, alpha: alpha), CGColor(gray: white, alpha: 0)] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        // Bitmap y is up: the brighter glow sits upper left, behind the card.
        glow(CGPoint(x: size.width * 0.27, y: size.height * 0.62), radius: size.width * 0.42, white: 0.55, alpha: 0.075)
        glow(CGPoint(x: size.width * 0.78, y: size.height * 0.18), radius: size.width * 0.5, white: 0.5, alpha: 0.05)
        return context.makeImage()
    }()

    /// The picture shrunk to a few pixels and darkened. Shown stretched over the screen, the
    /// layer's smooth scaling turns it into a very soft blur.
    static func blurredAmbient(_ image: NSImage) -> CGImage? {
        guard let source = LayerImageCache.cgImage(for: image),
              let tiny = CGContext(
                  data: nil, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
              )
        else { return nil }
        tiny.interpolationQuality = .high
        // Fill the frame, cropping the picture's longer side.
        let aspect = CGFloat(source.width) / CGFloat(max(1, source.height))
        let drawSize = aspect > 16.0 / 9.0 ? CGSize(width: 9 * aspect, height: 9) : CGSize(width: 16, height: 16 / aspect)
        tiny.draw(source, in: CGRect(x: (16 - drawSize.width) / 2, y: (9 - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
        // Darken towards black, keeping a little of the colour.
        tiny.setFillColor(CGColor(gray: 0, alpha: 0.58))
        tiny.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        return tiny.makeImage()
    }
}

// MARK: - Card

/// What the card on the left shows.
enum ModernCardContent {
    case glyph(rootID: String?)
    case artwork(NSImage, caption: ModernCardCaption?)
    case mosaic([NSImage])

    var key: String {
        switch self {
        case let .glyph(rootID): "glyph:\(rootID ?? "")"
        case let .artwork(image, caption): "art:\(ObjectIdentifier(image).hashValue):\(caption?.title ?? "")"
        case let .mosaic(images): "mosaic:" + images.map { "\(ObjectIdentifier($0).hashValue)" }.joined(separator: ",")
        }
    }

    var ambientImage: NSImage? {
        switch self {
        case .glyph: nil
        case let .artwork(image, _): image
        case let .mosaic(images): images.first
        }
    }
}

struct ModernCardCaption {
    var title: String
    var lines: [String] = []
    var description: String?
}

/// The large card left of the list: a section's symbol on a tile, or the selected item's
/// artwork. A change crossfades with a small settle in size.
@MainActor
final class ModernCardLayer {
    let layer = SceneLayer()
    private var current: SceneLayer?
    private var currentKey: String?
    private var currentFrame: CGRect = .zero
    private var currentScale: CGFloat = 0

    func update(_ content: ModernCardContent, frame: CGRect, scale: CGFloat, animated: Bool) {
        let key = content.key
        guard key != currentKey || frame != currentFrame || scale != currentScale else { return }
        let contentChanged = key != currentKey
        currentKey = key
        currentFrame = frame
        currentScale = scale
        let slot = makeSlot(content, frame: frame, scale: scale)
        let fade = Animation.smoothInOut(duration: 0.3)
        if let old = current {
            if animated, contentChanged {
                old.setOpacity(0, fade)
                DispatchQueue.main.asyncAfter(deadline: .now() + fade.duration + 0.05) { old.removeFromSuperlayer() }
            } else {
                old.removeFromSuperlayer()
            }
        }
        layer.addSublayer(slot)
        current = slot
        if animated, contentChanged {
            slot.opacity = 0
            slot.setOpacity(1, fade)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            slot.transform = Self.scale(0.965, about: center)
            slot.setTransform(CATransform3DIdentity, .smooth(duration: 0.42))
        }
    }

    private static func scale(_ factor: CGFloat, about center: CGPoint) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        return CATransform3DTranslate(transform, -center.x, -center.y, 0)
    }

    private func makeSlot(_ content: ModernCardContent, frame: CGRect, scale: CGFloat) -> SceneLayer {
        let slot = SceneLayer()
        slot.frame = layer.bounds
        let unit = frame.width / 540
        switch content {
        case let .glyph(rootID):
            let tile = SceneLayer()
            tile.frame = frame
            tile.backgroundColor = ModernTheme.tileFill.cgColor
            tile.cornerRadius = 115 * unit
            if #available(macOS 10.15, iOS 13.0, tvOS 13.0, *) { tile.cornerCurve = .continuous }
            slot.addSublayer(tile)
            let glyph = SceneLayer()
            let graphic = SymbolRenderer.render(ModernTheme.glyphName(forRootID: rootID), pointSize: 180 * unit, weight: .semibold, color: ModernTheme.tileGlyph, scale: scale)
            glyph.show(graphic, at: CGPoint(x: frame.midX - graphic.size.width / 2, y: frame.midY - graphic.size.height / 2))
            slot.addSublayer(glyph)
        case let .artwork(image, caption):
            let size = image.size
            let aspect = size.height > 0 ? size.width / size.height : 1
            let fitted: CGSize = aspect >= 1
                ? CGSize(width: frame.width, height: frame.width / aspect)
                : CGSize(width: frame.height * aspect, height: frame.height)
            // Lift the picture when a caption needs room below it.
            let lift: CGFloat = caption == nil ? 0 : min(60 * unit, (frame.height - fitted.height) / 2 + 60 * unit)
            let rect = CGRect(x: frame.midX - fitted.width / 2, y: frame.midY - fitted.height / 2 - lift, width: fitted.width, height: fitted.height)
            addPicture(LayerImageCache.cgImage(for: image), in: rect, radius: 22 * unit, to: slot)
            if let caption {
                addCaption(caption, below: rect, width: max(frame.width, rect.width), scale: scale, to: slot)
            }
        case let .mosaic(images):
            let gap = 16 * unit
            let side = (frame.width - gap) / 2
            for (index, image) in images.prefix(4).enumerated() {
                let rect = CGRect(x: frame.minX + CGFloat(index % 2) * (side + gap), y: frame.minY + CGFloat(index / 2) * (side + gap), width: side, height: side)
                addPicture(LayerImageCache.cgImage(for: image), in: rect, radius: 16 * unit, to: slot)
            }
        }
        return slot
    }

    private func addPicture(_ image: CGImage?, in rect: CGRect, radius: CGFloat, to slot: CALayer) {
        let shadow = SceneLayer()
        shadow.frame = rect
        shadow.shadowColor = CGColor(gray: 0, alpha: 1)
        shadow.shadowOpacity = 0.55
        shadow.shadowRadius = 22
        shadow.shadowOffset = CGSize(width: 0, height: 14)
        shadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: radius, cornerHeight: radius, transform: nil)
        slot.addSublayer(shadow)
        let picture = SceneLayer()
        picture.frame = rect
        picture.contents = image
        picture.contentsGravity = .resizeAspectFill
        picture.masksToBounds = true
        picture.cornerRadius = radius
        picture.backgroundColor = CGColor(gray: 0.12, alpha: 1)
        slot.addSublayer(picture)
    }

    private func addCaption(_ caption: ModernCardCaption, below rect: CGRect, width: CGFloat, scale: CGFloat, to slot: CALayer) {
        var top = rect.maxY + 30
        let centerX = rect.midX
        func place(_ graphic: RenderedGraphic) {
            let line = SceneLayer()
            line.show(graphic, at: CGPoint(x: centerX - graphic.size.width / 2, y: top))
            slot.addSublayer(line)
            top += graphic.size.height + 6
        }
        place(TextRenderer.render(TextSpec(text: caption.title, fontName: ModernTheme.semiboldFontName, size: 31, color: ModernTheme.text, maxWidth: width), scale: scale))
        for text in caption.lines.prefix(3) {
            place(TextRenderer.render(TextSpec(text: text, fontName: ModernTheme.regularFontName, size: 23, color: ModernTheme.secondaryText, maxWidth: width), scale: scale))
        }
        if let description = caption.description, !description.isEmpty {
            let short = description.count > 210 ? String(description.prefix(207)) + "…" : description
            top += 4
            place(TextRenderer.render(TextSpec(text: short, fontName: ModernTheme.regularFontName, size: 22, color: ModernTheme.secondaryText, wrapWidth: width, alignment: .center, lineSpacing: 2), scale: scale))
        }
    }
}

extension MenuView {
    /// What the modern card shows for the current menu, from the same choices the classic
    /// preview area makes.
    func modernCardContent(sceneSize: CGSize, pass: RenderPass) -> ModernCardContent {
        guard isInSubmenu, !isReturningToRoot, let rootID = activeRootItemID else {
            let rootID = (isEnteringSubmenu || isReturningToRoot) ? (activeRootItemID ?? selectedRootItemID) : selectedRootItemID
            return .glyph(rootID: rootID)
        }
        var memo = GapContentMemo()
        let specs = gapContentItems(sceneSize: sceneSize, pass: pass, memo: &memo)
        for spec in specs.reversed() where spec.opacity > 0.01 {
            switch spec.kind {
            case .icon:
                continue
            case let .moviePreview(preview):
                return .artwork(preview.image, caption: nil)
            case let .movieSlideshow(_, template):
                return .artwork(template.image, caption: nil)
            case let .musicPreview(image, _, _):
                guard let image else { continue }
                return .artwork(image, caption: nil)
            case let .metadata(metadata):
                return .artwork(metadata.image, caption: ModernCardCaption(
                    title: metadata.title,
                    lines: metadata.lines.map { "\($0.label): \($0.value)" },
                    description: metadata.description,
                ))
            case let .coverCarousel(configuration, _):
                let images = configuration.firstArtworks(4)
                if images.count == 4 { return .mosaic(images) }
                continue
            }
        }
        return .glyph(rootID: rootID)
    }

    private var selectedRootItemID: String? {
        menuItems.indices.contains(selectedIndex) ? menuItems[selectedIndex].id : nil
    }
}

extension CoverCarouselConfiguration {
    /// The first few covers that have loaded.
    func firstArtworks(_ count: Int) -> [NSImage] {
        switch source {
        case let .images(images):
            return Array(images.compactMap { $0 }.prefix(count))
        case let .dynamic(_, loaded, artwork, _, _):
            return Array((0 ..< min(loaded, count * 3)).compactMap { artwork($0) }.prefix(count))
        }
    }
}

// MARK: - Placeholder artwork

extension ModernTheme {
    private static var placeholders: [String: NSImage] = [:]

    /// Artwork for items without any, in the modern look: a quiet grey tile with a symbol.
    @MainActor
    static func placeholderArtwork(symbol: String, aspect: CGFloat = 1) -> NSImage? {
        let key = "\(symbol)|\(aspect)"
        if let cached = placeholders[key] { return cached }
        let height = 600
        let width = Int((CGFloat(height) * aspect).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let colors = [CGColor(gray: 0.27, alpha: 1), CGColor(gray: 0.17, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1]) {
            // Lighter at the top (bitmap y is up).
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: .zero, options: [])
        }
        let glyph = SymbolRenderer.render(symbol, pointSize: CGFloat(min(width, height)) * 0.34, weight: .regular, color: RGBA(white: 1, alpha: 0.42), scale: 1)
        if let image = glyph.image {
            let box = glyph.imageFrame(at: CGPoint(x: (CGFloat(width) - glyph.size.width) / 2, y: (CGFloat(height) - glyph.size.height) / 2))
            context.draw(image, in: box)
        }
        guard let cgImage = context.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        placeholders[key] = image
        return image
    }
}
