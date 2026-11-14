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
    /// Moving between the menus and a full-screen scene or a movie, what leaves shrinks to
    /// this and what arrives starts from `sceneNearScale`.
    static let sceneRecedeScale: CGFloat = 0.88
    static let sceneNearScale: CGFloat = 1.1

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

    /// Upright on a foldable, the card has the pane above the fold to itself.
    static func uprightCardFrame(in pane: CGRect) -> CGRect {
        let side = min(480, (pane.height * 0.66).rounded())
        return CGRect(x: (pane.midX - side / 2).rounded(), y: (pane.midY - side / 2).rounded(), width: side, height: side)
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
        case "dvd": "opticaldisc.fill"
        default: "play.rectangle.fill"
        }
    }

    private static let cardGlyphNames = ["film.fill", "tv.fill", "music.note", "mic.fill", "photo.fill", "gearshape.fill", "externaldrive.fill", "play.rectangle.fill", "opticaldisc.fill"]
    private static var preparedCardGlyphs: (pointSize: CGFloat, scale: CGFloat)?

    /// Has every section's card symbol drawn off the main thread, ready for when the card
    /// comes to it: one this large takes several milliseconds to draw the first time.
    @MainActor
    static func prepareCardGlyphs(pointSize: CGFloat, scale: CGFloat) {
        if let prepared = preparedCardGlyphs, prepared.pointSize == pointSize, prepared.scale == scale { return }
        preparedCardGlyphs = (pointSize, scale)
        SymbolRenderer.prepare(cardGlyphNames.map {
            SymbolRenderer.Request(name: $0, pointSize: pointSize, weight: .semibold, color: tileGlyph, scale: scale)
        })
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
        layingOut {
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
        guard let image else { return }
        // A wash that has to be made first comes in a moment later, unless the card has moved on.
        Self.ambient(for: image) { [weak self] blurred in
            guard let self, let blurred, ambientKey == key, ambient == nil else { return }
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

    private static var ambientCache: [ObjectIdentifier: (NSImage, CGImage)] = [:]

    private static let ambientQueue = DispatchQueue(label: "firstrow.ambient", qos: .userInitiated)

    /// `blurredAmbient` of a picture, remembered for the last few. One made before is handed
    /// over at once. A new one is made off the main thread (it reads the whole picture, which
    /// may still have to be decoded) and handed over when it's done.
    static func ambient(for image: NSImage, then use: @escaping @MainActor (CGImage?) -> Void) {
        if let hit = ambientCache[ObjectIdentifier(image)], hit.0 === image {
            use(hit.1)
            return
        }
        guard let source = LayerImageCache.cgImage(for: image) else {
            use(nil)
            return
        }
        ambientQueue.async {
            let blurred = autoreleasepool { blurredAmbient(source) }
            DispatchQueue.main.async {
                MainActor.assumeIsolatedIfPossible {
                    if let blurred {
                        if ambientCache.count >= 24 { ambientCache.removeAll() }
                        ambientCache[ObjectIdentifier(image)] = (image, blurred)
                    }
                    use(blurred)
                }
            }
        }
    }

    /// The picture's colours averaged into a 16 by 9 grid, darkened, and blurred into a soft
    /// wash. The blur is done here, at a size big enough to stretch over the screen smoothly:
    /// the grid itself stretched that far showed the straight seams between its pixels.
    nonisolated static func blurredAmbient(_ source: CGImage) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // The picture filling a small 16:9 frame, cropping its longer side.
        let sampleWidth = 128, sampleHeight = 72
        guard let sample = CGContext(
            data: nil, width: sampleWidth, height: sampleHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: layerBitmapInfo,
        ) else { return nil }
        sample.interpolationQuality = .high
        let aspect = CGFloat(source.width) / CGFloat(max(1, source.height))
        let frame = CGSize(width: sampleWidth, height: sampleHeight)
        let drawSize = aspect > 16.0 / 9.0 ? CGSize(width: frame.height * aspect, height: frame.height) : CGSize(width: frame.width, height: frame.width / aspect)
        sample.draw(source, in: CGRect(x: (frame.width - drawSize.width) / 2, y: (frame.height - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))

        // Averaged into the grid (8 by 8 pixels a cell), and darkened towards black.
        let gridWidth = 16, gridHeight = 9
        let cell = sampleWidth / gridWidth
        let darken: Float = 0.42
        var grid = [Float](repeating: 0, count: gridWidth * gridHeight * 3)
        let read = withPixels(of: sample) { bytes, bytesPerRow in
            for gy in 0 ..< gridHeight {
                for gx in 0 ..< gridWidth {
                    var sums: (Float, Float, Float) = (0, 0, 0)
                    for y in gy * cell ..< (gy + 1) * cell {
                        let row = bytes + y * bytesPerRow
                        for x in gx * cell ..< (gx + 1) * cell {
                            let pixel = row + x * 4
                            sums.0 += Float(pixel[0])
                            sums.1 += Float(pixel[1])
                            sums.2 += Float(pixel[2])
                        }
                    }
                    let scale = darken / Float(cell * cell)
                    let index = (gy * gridWidth + gx) * 3
                    grid[index] = sums.0 * scale
                    grid[index + 1] = sums.1 * scale
                    grid[index + 2] = sums.2 * scale
                }
            }
        }
        guard read else { return nil }

        // Spread over a bigger frame, then blurred by about a cell, so no seams are left.
        let width = 320, height = 180
        var plane = [Float](repeating: 0, count: width * height * 3)
        let stepX = Float(gridWidth) / Float(width)
        let stepY = Float(gridHeight) / Float(height)
        for y in 0 ..< height {
            let fy = max(0, min(Float(gridHeight - 1), (Float(y) + 0.5) * stepY - 0.5))
            let y0 = Int(fy), y1 = min(gridHeight - 1, y0 + 1)
            let ty = fy - Float(y0)
            for x in 0 ..< width {
                let fx = max(0, min(Float(gridWidth - 1), (Float(x) + 0.5) * stepX - 0.5))
                let x0 = Int(fx), x1 = min(gridWidth - 1, x0 + 1)
                let tx = fx - Float(x0)
                for channel in 0 ..< 3 {
                    let a = grid[(y0 * gridWidth + x0) * 3 + channel]
                    let b = grid[(y0 * gridWidth + x1) * 3 + channel]
                    let c = grid[(y1 * gridWidth + x0) * 3 + channel]
                    let d = grid[(y1 * gridWidth + x1) * 3 + channel]
                    let top = a + (b - a) * tx
                    let bottom = c + (d - c) * tx
                    plane[(y * width + x) * 3 + channel] = top + (bottom - top) * ty
                }
            }
        }
        // Three box blurs come close to a Gaussian one.
        let radius = width / gridWidth
        for _ in 0 ..< 3 {
            boxBlur(&plane, width: width, height: height, radius: radius, horizontal: true)
            boxBlur(&plane, width: width, height: height, radius: radius, horizontal: false)
        }

        // Back to 8 bits, with a touch of noise so dark gradients don't band. The noise comes
        // from a small generator of its own: the system's is a secure one, and asking it for
        // every pixel took longer than everything else here together.
        var noiseState: UInt32 = 0x9E37_79B9
        return makeOpaqueImage(width: width, height: height, space: space) { bytes, bytesPerRow in
            for y in 0 ..< height {
                let row = bytes + y * bytesPerRow
                for x in 0 ..< width {
                    let pixel = row + x * 4
                    let source = (y * width + x) * 3
                    noiseState ^= noiseState << 13
                    noiseState ^= noiseState >> 17
                    noiseState ^= noiseState << 5
                    let noise = Float(noiseState >> 24) / 255 - 0.5
                    for channel in 0 ..< 3 {
                        pixel[channel] = UInt8(max(0, min(255, (plane[source + channel] + noise).rounded())))
                    }
                    pixel[3] = 255
                }
            }
        }
    }

    /// Averages each value with `radius` neighbours either side along rows or columns of a
    /// three-channel plane, holding the edge values beyond the ends.
    private nonisolated static func boxBlur(_ plane: inout [Float], width: Int, height: Int, radius: Int, horizontal: Bool) {
        let count = horizontal ? width : height
        let lines = horizontal ? height : width
        let window = Float(radius * 2 + 1)
        var line = [Float](repeating: 0, count: count)
        for lineIndex in 0 ..< lines {
            for channel in 0 ..< 3 {
                func index(_ position: Int) -> Int {
                    (horizontal ? lineIndex * width + position : position * width + lineIndex) * 3 + channel
                }
                for position in 0 ..< count { line[position] = plane[index(position)] }
                var sum: Float = 0
                for offset in -radius ... radius { sum += line[max(0, min(count - 1, offset))] }
                for position in 0 ..< count {
                    plane[index(position)] = sum / window
                    sum += line[min(count - 1, position + radius + 1)] - line[max(0, position - radius)]
                }
            }
        }
    }

    /// Lets `body` read a bitmap context's pixels (four bytes each, alpha last, top row first).
    private nonisolated static func withPixels(of context: CGContext, _ body: (UnsafePointer<UInt8>, Int) -> Void) -> Bool {
        #if FIRSTROW_PORTABLE
            guard let image = context.makeImage() else { return false }
            body(UnsafePointer(image.storage.bytes), image.storage.bytesPerRow)
            return true
        #else
            guard let data = context.data else { return false }
            body(UnsafePointer(data.assumingMemoryBound(to: UInt8.self)), context.bytesPerRow)
            return true
        #endif
    }

    /// An opaque image whose pixels `fill` writes (four bytes each, alpha last, top row first).
    private nonisolated static func makeOpaqueImage(width: Int, height: Int, space: CGColorSpace, fill: (UnsafeMutablePointer<UInt8>, Int) -> Void) -> CGImage? {
        #if FIRSTROW_PORTABLE
            let storage = PixelStorage(width: width, height: height)
            fill(storage.bytes, storage.bytesPerRow)
            return CGImage(storage: storage, colorSpace: space, alphaInfo: .premultipliedFirst)
        #else
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: layerBitmapInfo,
            ), let data = context.data else { return nil }
            fill(data.assumingMemoryBound(to: UInt8.self), context.bytesPerRow)
            return context.makeImage()
        #endif
    }
}

// MARK: - Card

/// What the card on the left shows.
enum ModernCardContent {
    case glyph(rootID: String?)
    case artwork(NSImage, caption: ModernCardCaption?)
    case mosaic([NSImage])

    var isGlyph: Bool {
        if case .glyph = self { return true }
        return false
    }

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
    private var currentPane: CGRect?
    private var currentScale: CGFloat = 0
    /// Where the card's picture (or tile) is, to move the next one from when the layout changes.
    private var pictureRect: CGRect = .zero

    /// `pane` is the part of an upright scene the card has to itself: a picture and its caption
    /// share it, rather than hanging the caption below `frame`.
    func update(_ content: ModernCardContent, frame: CGRect, pane: CGRect? = nil, scale: CGFloat, animated: Bool) {
        let key = content.key
        guard key != currentKey || frame != currentFrame || pane != currentPane || scale != currentScale else { return }
        let contentChanged = key != currentKey
        let oldRect = pictureRect
        currentKey = key
        currentFrame = frame
        currentPane = pane
        currentScale = scale
        let (slot, rect) = makeSlot(content, frame: frame, pane: pane, scale: scale)
        pictureRect = rect
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
        } else if LayoutGlide.isActive, oldRect.width > 0, rect.width > 0, oldRect != rect {
            // The same card in a new place (the screen turned): it moves there from the old one.
            let factor = oldRect.width / rect.width
            var from = CATransform3DMakeTranslation(oldRect.midX, oldRect.midY, 0)
            from = CATransform3DScale(from, factor, factor, 1)
            from = CATransform3DTranslate(from, -rect.midX, -rect.midY, 0)
            LayoutGlide.bring(slot, "transform", from: NSValue(caTransform3D: from))
        }
    }

    private static func scale(_ factor: CGFloat, about center: CGPoint) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        return CATransform3DTranslate(transform, -center.x, -center.y, 0)
    }

    /// The card's layers, and where its picture (or tile) is among them.
    private func makeSlot(_ content: ModernCardContent, frame: CGRect, pane: CGRect?, scale: CGFloat) -> (SceneLayer, CGRect) {
        let slot = SceneLayer()
        slot.frame = layer.bounds
        let unit = frame.width / 540
        var pictureRect = frame
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
            ModernTheme.prepareCardGlyphs(pointSize: 180 * unit, scale: scale)
        case let .artwork(image, caption):
            let size = image.size
            let aspect = size.height > 0 ? size.width / size.height : 1
            let fitted: CGSize = aspect >= 1
                ? CGSize(width: frame.width, height: frame.width / aspect)
                : CGSize(width: frame.height * aspect, height: frame.height)
            if let pane {
                // Upright, the caption takes what it needs of the pane and the picture the rest
                // (a wide one may be wider than the card), the two together in the middle.
                let width = min(760, pane.width - 240)
                let lines = caption.map { captionLines($0, width: width, scale: scale, descriptionLimit: 150) } ?? []
                let captionHeight = lines.isEmpty ? 0 : lines.reduce(30) { $0 + $1.gap + $1.graphic.size.height }
                let room = CGSize(width: width, height: max(120, min(frame.height, pane.height - 80 - captionHeight)))
                let size = aspect >= room.width / room.height
                    ? CGSize(width: room.width, height: room.width / aspect)
                    : CGSize(width: room.height * aspect, height: room.height)
                let top = pane.minY + ((pane.height - size.height - captionHeight) / 2).rounded()
                let rect = CGRect(x: (pane.midX - size.width / 2).rounded(), y: top, width: size.width.rounded(), height: size.height.rounded())
                addPicture(LayerImageCache.cgImage(for: image), in: rect, radius: 22 * unit, to: slot)
                addCaption(lines, below: rect, to: slot)
                pictureRect = rect
                break
            }
            // Lift the picture when a caption needs room below it.
            let lift: CGFloat = caption == nil ? 0 : min(60 * unit, (frame.height - fitted.height) / 2 + 60 * unit)
            let rect = CGRect(x: frame.midX - fitted.width / 2, y: frame.midY - fitted.height / 2 - lift, width: fitted.width, height: fitted.height)
            addPicture(LayerImageCache.cgImage(for: image), in: rect, radius: 22 * unit, to: slot)
            if let caption {
                addCaption(captionLines(caption, width: max(frame.width, rect.width), scale: scale, descriptionLimit: 210), below: rect, to: slot)
            }
            pictureRect = rect
        case let .mosaic(images):
            let gap = 16 * unit
            let side = (frame.width - gap) / 2
            for (index, image) in images.prefix(4).enumerated() {
                let rect = CGRect(x: frame.minX + CGFloat(index % 2) * (side + gap), y: frame.minY + CGFloat(index / 2) * (side + gap), width: side, height: side)
                addPicture(LayerImageCache.cgImage(for: image), in: rect, radius: 16 * unit, to: slot)
            }
        }
        return (slot, pictureRect)
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

    /// A caption's lettering, each piece with the gap above it.
    private typealias CaptionLine = (graphic: RenderedGraphic, gap: CGFloat)

    private func captionLines(_ caption: ModernCardCaption, width: CGFloat, scale: CGFloat, descriptionLimit: Int) -> [CaptionLine] {
        var lines: [CaptionLine] = []
        lines.append((TextRenderer.render(TextSpec(text: caption.title, fontName: ModernTheme.semiboldFontName, size: 31, color: ModernTheme.text, maxWidth: width), scale: scale), 0))
        for text in caption.lines.prefix(3) {
            lines.append((TextRenderer.render(TextSpec(text: text, fontName: ModernTheme.regularFontName, size: 23, color: ModernTheme.secondaryText, maxWidth: width), scale: scale), 6))
        }
        if let description = caption.description, !description.isEmpty {
            let short = description.count > descriptionLimit ? String(description.prefix(descriptionLimit - 3)) + "…" : description
            lines.append((TextRenderer.render(TextSpec(text: short, fontName: ModernTheme.regularFontName, size: 22, color: ModernTheme.secondaryText, wrapWidth: width, alignment: .center, lineSpacing: 2), scale: scale), 10))
        }
        return lines
    }

    private func addCaption(_ lines: [CaptionLine], below rect: CGRect, to slot: CALayer) {
        var top = rect.maxY + 30
        for line in lines {
            top += line.gap
            let layer = SceneLayer()
            layer.show(line.graphic, at: CGPoint(x: rect.midX - line.graphic.size.width / 2, y: top))
            slot.addSublayer(layer)
            top += line.graphic.size.height
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
    /// Real covers only: a placeholder is passed over for the next cover along.
    @MainActor
    func firstArtworks(_ count: Int) -> [NSImage] {
        switch source {
        case let .images(images):
            return Array(images.compactMap { $0 }.filter { !ModernTheme.isPlaceholderArtwork($0) }.prefix(count))
        case let .dynamic(_, loaded, artwork, _, _):
            return Array((0 ..< min(loaded, count * 8)).compactMap { artwork($0) }.filter { !ModernTheme.isPlaceholderArtwork($0) }.prefix(count))
        }
    }
}

// MARK: - Placeholder artwork

extension ModernTheme {
    private static var placeholders: [String: NSImage] = [:]

    /// One of the stand-ins drawn for missing artwork (either look's).
    @MainActor
    static func isPlaceholderArtwork(_ image: NSImage) -> Bool {
        if placeholders.values.contains(where: { $0 === image }) { return true }
        return ["musicfallback", "moviesfallback"].contains { NSImage(named: $0) === image }
    }

    /// The symbol a row shows before its title in the modern look, in place of the classic
    /// look's own icons, or nil to keep the row's picture.
    static func rowSymbol(forItemID id: String, assetName: String?) -> String? {
        switch id {
        case "photos_library": "photo.fill.on.rectangle.fill"
        case "photos_last_12_months": "calendar"
        case "photos_last_import": "square.and.arrow.down.fill"
        default: assetName == "photos" ? "photo.fill" : nil
        }
    }

    /// A row's small picture: a grey tile with a white symbol, light enough for the row's
    /// own capsule and dark enough for the white focus.
    @MainActor
    static func rowIcon(symbol: String) -> NSImage? {
        let key = "row|\(symbol)"
        if let cached = placeholders[key] { return cached }
        guard let cgImage = drawRowIcon(symbol: symbol) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        placeholders[key] = image
        return image
    }

    private nonisolated static func drawRowIcon(symbol: String) -> CGImage? {
        let side = 192
        // (In the screen's colours on the Mac, like the covers: see `ScreenColorSpace`.)
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: ScreenColorSpace.current ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 42, cornerHeight: 42, transform: nil))
        context.clip()
        let colors = [CGColor(gray: 0.4, alpha: 1), CGColor(gray: 0.26, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1]) {
            // Lighter at the top (bitmap y is up).
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: .zero, options: [])
        }
        let glyph = SymbolRenderer.render(symbol, pointSize: CGFloat(side) * 0.48, weight: .semibold, color: RGBA(white: 1, alpha: 0.95), scale: 1)
        if let image = glyph.image {
            let box = glyph.imageFrame(at: CGPoint(x: (CGFloat(side) - glyph.size.width) / 2, y: (CGFloat(side) - glyph.size.height) / 2))
            context.draw(image, in: CGRect(x: box.minX, y: CGFloat(side) - box.maxY, width: box.width, height: box.height))
        }
        return context.makeImage()
    }

    /// Artwork for items without any, in the modern look: a quiet grey tile with a symbol.
    @MainActor
    static func placeholderArtwork(symbol: String, aspect: CGFloat = 1) -> NSImage? {
        let key = "\(symbol)|\(aspect)"
        if let cached = placeholders[key] { return cached }
        guard let cgImage = drawPlaceholderArtwork(symbol: symbol, aspect: aspect) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        placeholders[key] = image
        return image
    }

    private nonisolated static func drawPlaceholderArtwork(symbol: String, aspect: CGFloat) -> CGImage? {
        let height = 600
        let width = Int((CGFloat(height) * aspect).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ScreenColorSpace.current ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
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
        return context.makeImage()
    }

    private static var placeholdersPrepared = false

    /// Draws the stand-in artwork and the row symbols off the main thread, ahead of the first
    /// list that needs them: each has a large symbol to draw, which takes milliseconds.
    @MainActor
    static func preparePlaceholders() {
        guard !placeholdersPrepared else { return }
        placeholdersPrepared = true
        let artwork: [(symbol: String, aspect: CGFloat)] = [("music.note", 1), ("film.fill", 2.0 / 3.0), ("mic.fill", 1)]
        let rows = ["photo.fill.on.rectangle.fill", "calendar", "square.and.arrow.down.fill", "photo.fill"]
        DispatchQueue.global(qos: .utility).async {
            func keep(_ cgImage: CGImage?, as key: String) {
                guard let cgImage else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolatedIfPossible {
                        // One asked for meanwhile was drawn there and then, and stays the one in use.
                        guard placeholders[key] == nil else { return }
                        placeholders[key] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    }
                }
            }
            for item in artwork {
                autoreleasepool { keep(drawPlaceholderArtwork(symbol: item.symbol, aspect: item.aspect), as: "\(item.symbol)|\(item.aspect)") }
            }
            for symbol in rows {
                autoreleasepool { keep(drawRowIcon(symbol: symbol), as: "row|\(symbol)") }
            }
        }
    }
}
