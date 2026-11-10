import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// Fills the space left of a section's menu: its icon, a preview, details or a stream of covers.
@MainActor
final class GapContentLayer {
    let layer = SceneLayer()
    /// Holds the pieces to the screen, and upright to the room above the fold.
    private let clip = SceneLayer()
    /// Upright, a piece or its reflection sinks into the dark above the fold instead of being cut off along it.
    private let foot = SceneGradientLayer()
    private var items: [String: GapItemLayer] = [:]
    private var order: [String] = []
    private var memo = GapContentMemo()
    private var isShowing = false

    init() {
        clip.masksToBounds = true
        layer.addSublayer(clip)
        foot.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.75), CGColor(gray: 0, alpha: 1)]
        foot.locations = [0, 0.6, 1]
        foot.startPoint = CGPoint(x: 0.5, y: 0)
        foot.endPoint = CGPoint(x: 0.5, y: 1)
        foot.opacity = 0
        foot.zPosition = 1000
        clip.addSublayer(foot)
    }

    func tearDown() {
        for item in items.values {
            item.tearDown()
            item.layer.removeFromSuperlayer()
        }
        items.removeAll()
        order.removeAll()
    }

    func update(
        menu: MenuView,
        pass: RenderPass,
        visible: Bool,
        opacity: Double,
        opacityAnimation: Animation?,
        sceneSize: CGSize,
        boxFrame: CGRect,
        show: UprightShow? = nil,
        scale: CGFloat,
    ) {
        guard visible else {
            if isShowing {
                isShowing = false
                tearDown()
                memo = GapContentMemo()
                layer.opacity = 0
            }
            return
        }
        let appearing = !isShowing
        isShowing = true
        layer.setOpacity(opacity, appearing ? nil : opacityAnimation)
        let context = GapItemContext(
            boxSize: boxFrame.size,
            boxFrame: boxFrame,
            sceneSize: sceneSize,
            show: show,
            scale: scale,
            pass: appearing ? RenderPass(transaction: .instant) : pass,
        )
        // The clip's own space is the box's, so the pieces sit in it as they would in the box.
        let screen = CGRect(x: -boxFrame.minX, y: -boxFrame.minY, width: sceneSize.width, height: sceneSize.height)
        let window = show?.pane ?? screen
        if clip.bounds != window {
            clip.bounds = window
            clip.position = window.origin
        }
        let footHeight: CGFloat = 120
        foot.place(CGRect(x: window.minX, y: window.maxY - footHeight, width: window.width, height: footHeight))
        foot.setOpacity(show == nil ? 0 : 1, nil)
        let specs = menu.gapContentItems(sceneSize: sceneSize, pass: context.pass, memo: &memo)
        let wantedKeys = Set(specs.map(\.key))

        // Pieces that went away fade out (when their transition says so) and are removed.
        for key in order where !wantedKeys.contains(key) {
            guard let item = items[key] else { continue }
            items[key] = nil
            let fade = appearing || context.pass.transaction.disablesAnimations ? nil : item.removalAnimation
            if let fade {
                item.layer.setOpacity(0, fade)
                let layerToRemove = item.layer
                DispatchQueue.main.asyncAfter(deadline: .now() + fade.duration + fade.delay + 0.05) {
                    item.tearDown()
                    layerToRemove.removeFromSuperlayer()
                }
            } else {
                item.tearDown()
                item.layer.removeFromSuperlayer()
            }
        }

        // Pieces that stay are updated in place, and new ones fade in as their transition says.
        var newOrder: [String] = []
        for spec in specs {
            let item: GapItemLayer
            if let existing = items[spec.key], existing.accepts(spec.kind) {
                item = existing
                item.update(spec.kind, context: context)
                item.layer.setOpacity(spec.opacity, spec.animation)
            } else {
                if let stale = items[spec.key] {
                    stale.tearDown()
                    stale.layer.removeFromSuperlayer()
                }
                item = GapItemLayer.make(for: spec.kind)
                item.layer.place(CGRect(origin: .zero, size: boxFrame.size))
                item.update(spec.kind, context: context)
                let fadeIn = appearing ? nil : spec.transition
                item.layer.opacity = fadeIn == nil ? Float(spec.opacity) : 0
                item.layer.setOpacity(spec.opacity, fadeIn)
                items[spec.key] = item
            }
            item.removalAnimation = spec.fade
            item.layer.place(CGRect(origin: .zero, size: boxFrame.size))
            newOrder.append(spec.key)
        }
        order = newOrder
        // Later pieces stack on top, and leaving pieces stay behind them.
        let ordered = newOrder.compactMap { items[$0]?.layer }
        for (index, sublayer) in ordered.enumerated() {
            if sublayer.superlayer !== clip {
                clip.addSublayer(sublayer)
            }
            sublayer.zPosition = CGFloat(index + 1)
        }
    }
}

/// Values remembered between passes to tell which animations a change gets.
struct GapContentMemo {
    var moviePreviewKey: String?
    var episodePreviewKey: String?
    var hidesMusicRootIcon: Bool?
    var hidesPhotosRootIcon: Bool?
    var hidesPodcastsRootIcon: Bool?
    var jellyfinPreviewKey: String?
}

struct GapItemContext {
    let boxSize: CGSize
    let boxFrame: CGRect
    let sceneSize: CGSize
    /// Standing upright: the room above the fold, which the pieces fit themselves to.
    var show: UprightShow?
    let scale: CGFloat
    let pass: RenderPass

    /// Centre of a piece in the box, with 100 pt of padding below it, then offset.
    func center(offsetX: CGFloat, offsetY: CGFloat) -> CGPoint {
        CGPoint(x: boxSize.width * 0.5 + offsetX, y: (boxSize.height - 100) * 0.5 + offsetY)
    }

    /// The transform for a layer covering the box that draws `rect` on a sideways screen:
    /// upright, the one that brings it to the middle of the room above the fold.
    func settled(_ rect: CGRect) -> CATransform3D {
        show?.fit(rect) ?? CATransform3DIdentity
    }
}

struct GapItemSpec {
    let key: String
    let kind: GapItemKind
    var opacity: Double = 1
    /// For changes to a piece that stays.
    var animation: Animation?
    /// Fade used when the piece appears in this pass (nil: it just appears).
    var transition: Animation?
    /// Fade used whenever the piece goes away (nil: it just vanishes).
    var fade: Animation?
}

enum GapItemKind {
    case icon(image: NSImage, reflected: Bool)
    case moviePreview(MoviePreviewSpec)
    case movieSlideshow(descriptors: [MenuView.MovieGapPreviewDescriptor], template: MoviePreviewSpec)
    case musicPreview(image: NSImage?, offsetX: CGFloat, offsetY: CGFloat)
    case metadata(MetadataPreviewSpec)
    case coverCarousel(CoverCarouselConfiguration, exitOverlayOpacity: Double)
}

struct MoviePreviewSpec {
    var image: NSImage
    var aspectRatio: CGFloat
    var sizeScale: CGFloat
    var baseIconSize: CGFloat
    var offsetX: CGFloat
    var offsetY: CGFloat
    var previewYaw: Double = 36
    var reflectionYaw: Double = 35.8
}

struct MetadataPreviewSpec {
    struct Line: Equatable {
        let label: String
        let value: String
    }

    var image: NSImage
    var aspectRatio: CGFloat
    var forcedPreviewAspectRatio: CGFloat?
    var sizeScale: CGFloat
    var title: String
    var description: String?
    var lines: [Line] = []
    var baseIconSize: CGFloat
    var offsetX: CGFloat
    var offsetY: CGFloat
    var identity: String
    var transitionDelay: Double = 3
    var animatesTransition = true
}

// MARK: - Pieces

@MainActor
class GapItemLayer {
    let layer = SceneLayer()
    var removalAnimation: Animation?

    static func make(for kind: GapItemKind) -> GapItemLayer {
        switch kind {
        case .icon: GapIconLayer()
        case .moviePreview: MoviePreviewLayer()
        case .movieSlideshow: MovieSlideshowLayer()
        case .musicPreview: MusicPreviewLayer()
        case .metadata: MetadataPreviewLayer()
        case .coverCarousel: CoverCarouselItemLayer()
        }
    }

    func accepts(_: GapItemKind) -> Bool { false }
    func update(_: GapItemKind, context _: GapItemContext) {}
    func tearDown() {}
}

/// The section's icon, with its reflection unless it's plain.
final class GapIconLayer: GapItemLayer {
    private let reflection = SceneLayer()
    private let image = SceneLayer()
    private var current: (NSImage, Bool, CGSize)?

    override init() {
        super.init()
        image.contentsGravity = .resizeAspect
        reflection.opacity = 0.34
        layer.addSublayer(reflection)
        layer.addSublayer(image)
    }

    override func accepts(_ kind: GapItemKind) -> Bool {
        if case .icon = kind { return true }
        return false
    }

    override func update(_ kind: GapItemKind, context: GapItemContext) {
        guard case let .icon(icon, reflected) = kind else { return }
        if let current, current.0 === icon, current.1 == reflected, current.2 == context.boxSize { return }
        current = (icon, reflected, context.boxSize)
        let side: CGFloat = 400 * 1.65
        let center = context.center(offsetX: 0, offsetY: 0.85 * (-40 + 300))
        image.contents = LayerImageCache.cgImage(for: icon)
        image.frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        reflection.isHidden = !reflected
        if reflected {
            // Flipped below the icon, raised a little, fading out over 60% of its height.
            reflection.contents = ReflectionRenderer.reflection(of: icon, size: CGSize(width: side, height: side), fill: false, stops: [(1, 0), (0, 0.6)])
            reflection.frame = CGRect(x: center.x - side / 2, y: center.y + side / 2 - side * 0.215, width: side, height: side)
        }
    }
}

/// A movie poster or still turned towards the menu, with its reflection.
final class MoviePreviewLayer: GapItemLayer {
    private let reflection = CALayer()
    private let reflectionImage = SceneLayer()
    private let preview = CALayer()
    private var key: String?
    /// Where the turned picture shows in the box.
    private var extent: CGRect = .zero

    override init() {
        super.init()
        for sublayer in [reflection, preview] {
            sublayer.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "contents": NSNull(), "opacity": NSNull()]
            layer.addSublayer(sublayer)
        }
        preview.contentsGravity = .resizeAspectFill
        preview.masksToBounds = true
        reflection.addSublayer(reflectionImage)
        reflection.opacity = 0.44
    }

    override func accepts(_ kind: GapItemKind) -> Bool {
        if case .moviePreview = kind { return true }
        return false
    }

    override func update(_ kind: GapItemKind, context: GapItemContext) {
        guard case let .moviePreview(spec) = kind else { return }
        apply(spec, context: context)
    }

    /// Upright, the preview is brought to the middle of the room above the fold.
    func settle(in context: GapItemContext) {
        layer.setTransform(context.settled(extent), nil)
    }

    func apply(_ spec: MoviePreviewSpec, context: GapItemContext) {
        let width = spec.baseIconSize * 1.74 * max(0.05, spec.sizeScale)
        let height = width / max(0.4, min(3.0, spec.aspectRatio))
        let size = CGSize(width: width, height: height)
        let center = context.center(offsetX: spec.offsetX, offsetY: spec.offsetY)
        let turn = yawTransform(degrees: spec.previewYaw, perspective: 0.75, viewSize: size)
        extent = turnedOutline(center: center, size: size, transform: turn)
        settle(in: context)
        let key = "\(ObjectIdentifier(spec.image))|\(width)|\(height)|\(spec.offsetX)|\(spec.offsetY)|\(spec.previewYaw)|\(context.boxSize)"
        guard key != self.key else { return }
        self.key = key
        preview.bounds = CGRect(origin: .zero, size: size)
        preview.position = center
        preview.contents = LayerImageCache.cgImage(for: spec.image)
        preview.transform = turn
        // The reflection turns about the preview's frame, with its picture hanging below it.
        reflection.bounds = CGRect(origin: .zero, size: size)
        reflection.position = center
        reflection.transform = yawTransform(degrees: spec.reflectionYaw, perspective: 0.75, viewSize: size)
        reflectionImage.frame = CGRect(x: 0, y: height, width: width, height: height)
        reflectionImage.contents = ReflectionRenderer.reflection(
            of: spec.image,
            size: size,
            fill: true,
            stops: [(1, 0), (0.68, 0.05), (0.26, 0.12), (0.08, 0.17), (0, 0.22)],
        )
    }
}

/// The Movies Folder item's preview: each movie in turn, crossfading every few seconds.
final class MovieSlideshowLayer: GapItemLayer {
    private var previews: [MoviePreviewLayer] = []
    private var identity: String?
    private var timer: Timer?
    private var currentIndex = 0
    private var descriptors: [MenuView.MovieGapPreviewDescriptor] = []
    private var template: MoviePreviewSpec?
    private var context: GapItemContext?
    private static let cycle: Double = 3
    private static let crossfade: Double = 0.55

    override func accepts(_ kind: GapItemKind) -> Bool {
        if case .movieSlideshow = kind { return true }
        return false
    }

    override func update(_ kind: GapItemKind, context: GapItemContext) {
        guard case let .movieSlideshow(descriptors, template) = kind else { return }
        self.context = context
        self.template = template
        for preview in previews { preview.settle(in: context) }
        let identity = descriptors.map(\.id).joined(separator: "|")
        guard identity != self.identity else { return }
        self.identity = identity
        self.descriptors = descriptors
        restart()
    }

    override func tearDown() {
        timer?.invalidate()
        timer = nil
    }

    private func restart() {
        timer?.invalidate()
        timer = nil
        for preview in previews { preview.layer.removeFromSuperlayer() }
        previews = []
        currentIndex = 0
        guard !descriptors.isEmpty else { return }
        let first = makePreview(descriptors[0])
        first.layer.opacity = 1
        previews = [first]
        guard descriptors.count > 1 else { return }
        scheduleNext()
    }

    private func makePreview(_ descriptor: MenuView.MovieGapPreviewDescriptor) -> MoviePreviewLayer {
        let preview = MoviePreviewLayer()
        preview.layer.place(layer.bounds)
        if var spec = template, let context {
            spec.image = descriptor.image
            spec.aspectRatio = descriptor.aspectRatio
            spec.sizeScale = descriptor.sizeScale
            preview.apply(spec, context: context)
        }
        layer.addSublayer(preview.layer)
        return preview
    }

    private func scheduleNext() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.cycle - Self.crossfade, repeats: false) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible { self?.crossfadeToNext() }
        }
    }

    private func crossfadeToNext() {
        guard descriptors.count > 1, let current = previews.last else { return }
        currentIndex = (currentIndex + 1) % descriptors.count
        let next = makePreview(descriptors[currentIndex])
        next.layer.opacity = 0
        let fade = Animation.linear(duration: Self.crossfade)
        next.layer.setOpacity(1, fade)
        current.layer.setOpacity(0, fade)
        previews = [current, next]
        timer = Timer.scheduledTimer(withTimeInterval: Self.crossfade, repeats: false) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible {
                guard let self else { return }
                current.layer.removeFromSuperlayer()
                self.previews = [next]
                self.scheduleNext()
            }
        }
    }
}

/// A song's artwork turned towards the menu, with its reflection.
final class MusicPreviewLayer: GapItemLayer {
    private let reflection = CALayer()
    private let reflectionImage = SceneLayer()
    private let preview = CALayer()
    private var key: String?

    override init() {
        super.init()
        for sublayer in [reflection, preview] {
            sublayer.actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "contents": NSNull()]
            layer.addSublayer(sublayer)
        }
        preview.contentsGravity = .resizeAspectFill
        preview.masksToBounds = true
        preview.backgroundColor = CGColor(gray: 0, alpha: 1)
        reflection.addSublayer(reflectionImage)
        reflection.opacity = 0.44
    }

    override func accepts(_ kind: GapItemKind) -> Bool {
        if case .musicPreview = kind { return true }
        return false
    }

    override func update(_ kind: GapItemKind, context: GapItemContext) {
        guard case let .musicPreview(image, offsetX, offsetY) = kind else { return }
        let side: CGFloat = 400 * 1.2
        let size = CGSize(width: side, height: side)
        let center = context.center(offsetX: offsetX, offsetY: offsetY)
        let turn = yawTransform(degrees: 24, perspective: 0.75, viewSize: size)
        layer.setTransform(context.settled(turnedOutline(center: center, size: size, transform: turn)), nil)
        let key = "\(image.map { "\(ObjectIdentifier($0))" } ?? "none")|\(offsetX)|\(offsetY)|\(context.boxSize)"
        guard key != self.key else { return }
        self.key = key
        let artwork = LayerImageCache.cgImage(for: image) ?? CoverArtPlaceholder.image(side: side)
        preview.bounds = CGRect(origin: .zero, size: size)
        preview.position = center
        preview.contents = artwork
        preview.transform = turn
        reflection.bounds = CGRect(origin: .zero, size: size)
        reflection.position = center
        reflection.transform = yawTransform(degrees: 23.8, perspective: 0.75, viewSize: size)
        reflectionImage.frame = CGRect(x: 0, y: side, width: side, height: side)
        reflectionImage.contents = artwork.flatMap { ReflectionRenderer.reflection(of: $0, size: size, fill: true, stops: [(1, 0), (0, 0.25)]) }
    }
}

/// The album covers drifting across the gap (Music, iTunes Top and photo albums).
final class CoverCarouselItemLayer: GapItemLayer {
    private let stage = SceneLayer()
    private let space = SceneLayer()
    private let controller = CoverCarouselLayerController()
    private let exitOverlay = SceneLayer()

    override init() {
        super.init()
        #if os(macOS) || FIRSTROW_PORTABLE
            space.isGeometryFlipped = true
        #endif
        layer.addSublayer(stage)
        stage.addSublayer(space)
        space.addSublayer(controller.rootLayer)
        exitOverlay.backgroundColor = CGColor(gray: 0, alpha: 1)
        exitOverlay.opacity = 0
        stage.addSublayer(exitOverlay)
    }

    override func accepts(_ kind: GapItemKind) -> Bool {
        if case .coverCarousel = kind { return true }
        return false
    }

    override func update(_ kind: GapItemKind, context: GapItemContext) {
        guard case let .coverCarousel(configuration, exitOverlayOpacity) = kind else { return }
        stage.place(CGRect(origin: .zero, size: context.boxSize))
        // The covers keep the path they have on a sideways screen, leaving past the left edge.
        stage.setTransform(context.show?.sidewaysFit() ?? CATransform3DIdentity, nil)
        let side = configuration.baseIconSize * 1.2
        let size = CGSize(width: side, height: side + 100)
        let spaceFrame = CGRect(x: (context.boxSize.width - size.width) * 0.5, y: (context.boxSize.height - size.height) * 0.5, width: size.width, height: size.height)
        space.frame = spaceFrame
        controller.rootLayer.frame = CGRect(origin: .zero, size: size)
        var arranged = configuration
        if let show = context.show {
            // The path was drawn to leave the menu its side of the screen. Upright the menu is
            // below, so the path is stretched from the screen's left edge to turn back near the right.
            let left = show.sidewaysScreen.minX - spaceFrame.minX
            let turn = size.width * 0.5 + configuration.horizontalOffset + CoverCarouselLayerController.turningPoint(baseIconSize: configuration.baseIconSize) - left
            let fit = show.pane.height / max(show.sidewaysScreen.height, 1)
            if turn > 0 {
                arranged.spread = CoverCarouselConfiguration.Spread(about: left, factor: max(1, show.pane.width * 0.78 / (turn * fit)))
            }
        }
        controller.update(arranged, bounds: size)
        let overlaySize = CGSize(width: max(configuration.baseIconSize * 3.75, 1500), height: max(configuration.baseIconSize * 4, 1200))
        exitOverlay.frame = CGRect(
            x: (context.boxSize.width - overlaySize.width) * 0.5 + configuration.horizontalOffset,
            y: (context.boxSize.height - overlaySize.height) * 0.5 + configuration.verticalOffset,
            width: overlaySize.width,
            height: overlaySize.height,
        )
        exitOverlay.setOpacity(exitOverlayOpacity, context.pass.animation)
    }

    override func tearDown() {
        controller.tearDown()
    }
}

// MARK: - Reflections

/// Upside-down copies of pictures that fade out downwards, for the reflections under previews.
@MainActor
enum ReflectionRenderer {
    private final class Key: NSObject {
        let source: CGImage
        let width: Int
        let height: Int
        let fill: Bool
        let stops: [CGFloat]

        init(source: CGImage, width: Int, height: Int, fill: Bool, stops: [CGFloat]) {
            self.source = source
            self.width = width
            self.height = height
            self.fill = fill
            self.stops = stops
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return other.source === source && other.width == width && other.height == height && other.fill == fill && other.stops == stops
        }

        override var hash: Int {
            ObjectIdentifier(source).hashValue ^ (width &* 31) ^ (height &* 1009) ^ (fill ? 7 : 0)
        }
    }

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<Key, Box> = {
        let cache = NSCache<Key, Box>()
        cache.countLimit = 80
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func reflection(of image: NSImage, size: CGSize, fill: Bool, stops: [(alpha: CGFloat, location: CGFloat)]) -> CGImage? {
        guard let source = LayerImageCache.cgImage(for: image) else { return nil }
        return reflection(of: source, size: size, fill: fill, stops: stops)
    }

    /// `stops` give the reflection's opacity by distance from its top edge (the mirror line).
    static func reflection(of source: CGImage, size: CGSize, fill: Bool, stops: [(alpha: CGFloat, location: CGFloat)]) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        // Reflections are faint, so a modest bitmap is plenty.
        let pixelScale = min(1.0, 640 / max(size.width, size.height))
        let width = max(1, Int(size.width * pixelScale))
        let height = max(1, Int(size.height * pixelScale))
        let key = Key(source: source, width: width, height: height, fill: fill, stops: stops.flatMap { [$0.alpha, $0.location] })
        if let cached = cache.object(forKey: key) {
            return cached.image
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: layerBitmapInfo,
        ), let mask = alphaMask(width: width, height: height, stops: stops) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clip(to: rect, mask: mask)
        // Flipped: the picture's bottom row ends up at the top of the reflection.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .medium
        if fill {
            ReflectionImageCache.drawAspectFill(source, in: rect, context: context)
        } else {
            let aspect = CGFloat(source.width) / CGFloat(max(1, source.height))
            var drawRect = rect
            if aspect > 1 {
                drawRect.size.height = rect.width / aspect
                drawRect.origin.y = rect.midY - drawRect.height / 2
            } else {
                drawRect.size.width = rect.height * aspect
                drawRect.origin.x = rect.midX - drawRect.width / 2
            }
            context.draw(source, in: drawRect)
        }
        guard let reflection = context.makeImage() else { return nil }
        cache.setObject(Box(reflection), forKey: key, cost: reflection.bytesPerRow * reflection.height)
        return reflection
    }

    private static func alphaMask(width: Int, height: Int, stops: [(alpha: CGFloat, location: CGFloat)]) -> CGImage? {
        guard let mask = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
        ) else { return nil }
        let colors = stops.map { CGColor(gray: $0.alpha, alpha: 1) } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: stops.map(\.location)) else { return nil }
        let top = CGFloat(height)
        mask.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: 0), options: [.drawsAfterEndLocation])
        return mask.makeImage()
    }
}
