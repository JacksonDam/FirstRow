import QuartzCore
import SwiftUI

/// The endless stream of album covers drifting across the left of the Music menu (and the
/// iTunes Top carousels), drawn with Core Animation.
///
/// Four lanes cycle through the same path, a quarter of a cycle apart. Each lane's motion is
/// a keyframe animation that repeats forever, so the render server moves the covers and the
/// app only wakes up when a lane wraps round to show its next cover (every few seconds).
struct CoverCarouselConfiguration {
    enum Source {
        case images([NSImage?])
        case dynamic(
            resolvedArtworkCount: Int?,
            loadedArtworkCount: Int,
            artworkForGlobalIndex: (Int) -> NSImage?,
            prefetchIfNeededForSerial: (Int) -> Void,
            phaseResetKey: String,
        )
    }

    var source: Source
    var baseIconSize: CGFloat
    var horizontalOffset: CGFloat
    var verticalOffset: CGFloat
    var preserveArtworkAspectRatio: Bool
}

@MainActor
final class CoverCarouselLayerController: LayerController {
    let rootLayer: CALayer = StillLayer()

    private static let laneCount = 4
    private static let coversPerSecond: Double = 0.075
    private static var cycleDuration: Double { 1 / coversPerSecond }
    private static let keyframeCount = 240
    private static let reflectionOpacity: Float = 0.30
    private static let reflectionFadeEnd: CGFloat = 0.44

    private final class Lane {
        /// Untransformed parent that flattens the artwork into its own plane, so covers are
        /// painted back to front like SwiftUI does, instead of being depth-tested against each
        /// other in 3D (which let a cover's near edge poke through a bigger cover in front).
        let plane = StillLayer()
        let preview = StillLayer()
        /// Shares the artwork's position and rotation; its picture sits just below the artwork.
        let reflection = StillLayer()
        let reflectionImage = StillLayer()
        var serial: Int?
        var image: NSImage?
        var size: CGSize = .zero
    }

    private let lanes: [Lane] = (0 ..< laneCount).map { _ in Lane() }
    /// Reflections are faint, so they all sit behind every cover.
    private let reflectionContainer = StillLayer()
    private let previewContainer = StillLayer()
    private var configuration: CoverCarouselConfiguration?
    private var phaseOrigin: CFTimeInterval = 0
    private var phaseKey: String?
    private var animatedGeometryKey: String?
    private var wrapTimer: Timer?
    private var lastPrefetchSerial: Int?

    init() {
        rootLayer.masksToBounds = false
        rootLayer.addSublayer(reflectionContainer)
        rootLayer.addSublayer(previewContainer)
        for lane in lanes {
            lane.preview.masksToBounds = true
            lane.preview.backgroundColor = CGColor(gray: 0, alpha: 1)
            lane.preview.contentsGravity = .resizeAspectFill
            lane.reflection.opacity = Self.reflectionOpacity
            lane.reflectionImage.contentsGravity = .resize
            lane.reflection.addSublayer(lane.reflectionImage)
            reflectionContainer.addSublayer(lane.reflection)
            lane.plane.addSublayer(lane.preview)
            previewContainer.addSublayer(lane.plane)
        }
    }

    func update(_ configuration: CoverCarouselConfiguration, bounds: CGSize) {
        withoutLayerActions {
            reflectionContainer.frame = CGRect(origin: .zero, size: bounds)
            previewContainer.frame = CGRect(origin: .zero, size: bounds)
            for lane in lanes {
                lane.plane.frame = CGRect(origin: .zero, size: bounds)
            }
        }
        self.configuration = configuration
        let newPhaseKey = phaseIdentityKey(for: configuration.source)
        let geometryKey = "\(configuration.baseIconSize)|\(configuration.horizontalOffset)|\(configuration.verticalOffset)|\(bounds.width)x\(bounds.height)"
        if newPhaseKey != phaseKey {
            phaseKey = newPhaseKey
            phaseOrigin = CACurrentMediaTime()
            lastPrefetchSerial = nil
            for lane in lanes { lane.serial = nil }
            animatedGeometryKey = nil
        }
        refreshLaneImages()
        if animatedGeometryKey != geometryKey {
            animatedGeometryKey = geometryKey
            // Outside SwiftUI's update transaction, so its animation context can't touch ours.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.animatedGeometryKey == geometryKey else { return }
                self.installAnimations(bounds: bounds)
            }
        }
        scheduleWrapTimer()
    }

    func tearDown() {
        wrapTimer?.invalidate()
        wrapTimer = nil
    }

    // MARK: - Lanes and images

    /// Which cover a lane shows at a given time since the phase began. Lanes start a quarter of a
    /// cycle apart; the offset keeps the first four covers distinct instead of all showing cover 0.
    private func serial(forLane slot: Int, elapsed: Double) -> Int {
        let lanePosition = elapsed * Self.coversPerSecond - Double(slot) / Double(Self.laneCount)
        let wrapCount = Int(floor(lanePosition))
        return wrapCount * Self.laneCount + slot + (Self.laneCount - 1)
    }

    private func refreshLaneImages() {
        guard let configuration else { return }
        let elapsed = max(0, CACurrentMediaTime() - phaseOrigin)
        var maxSerial = 0
        var sizesChanged = false
        withoutLayerActions {
            for (slot, lane) in lanes.enumerated() {
                let serial = serial(forLane: slot, elapsed: elapsed)
                maxSerial = max(maxSerial, serial)
                let image = artworkImage(forSerial: serial, source: configuration.source)
                guard lane.serial != serial || lane.image !== image else { continue }
                lane.serial = serial
                lane.image = image
                let size = previewSize(for: image, configuration: configuration)
                if size != lane.size {
                    lane.size = size
                    sizesChanged = true
                }
                lane.preview.bounds = CGRect(origin: .zero, size: size)
                lane.reflection.bounds = CGRect(origin: .zero, size: size)
                // Directly below the artwork.
                lane.reflectionImage.frame = LayerSpace(height: size.height).rect(
                    CGRect(x: 0, y: size.height, width: size.width, height: size.height),
                )
                lane.preview.contents = LayerImageCache.cgImage(for: image) ?? CoverArtPlaceholder.image(side: configuration.baseIconSize * 1.2)
                lane.reflectionImage.contents = ReflectionImageCache.reflection(
                    for: image,
                    size: size,
                    fadeEnd: Self.reflectionFadeEnd,
                    placeholderSide: configuration.baseIconSize * 1.2,
                )
            }
        }
        if sizesChanged {
            animatedGeometryKey = nil
        }
        applyDepthOrder(elapsed: elapsed)
        if case let .dynamic(_, _, _, prefetch, _) = configuration.source, lastPrefetchSerial != maxSerial {
            lastPrefetchSerial = maxSerial
            prefetch(maxSerial)
        }
    }

    private func artworkImage(forSerial serial: Int, source: CoverCarouselConfiguration.Source) -> NSImage? {
        switch source {
        case let .images(images):
            guard !images.isEmpty else { return nil }
            if images.count == 2 {
                let repeatingTriplet = [0, 0, 1]
                return images[repeatingTriplet[wrapped(serial, count: 3)]]
            }
            return images[wrapped(serial, count: images.count)]
        case let .dynamic(resolvedCount, _, artworkForGlobalIndex, _, _):
            if let resolvedCount, resolvedCount > 0 {
                return artworkForGlobalIndex(wrapped(serial, count: resolvedCount))
            }
            return artworkForGlobalIndex(max(0, serial))
        }
    }

    private func wrapped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remainder = index % count
        return remainder >= 0 ? remainder : remainder + count
    }

    private func phaseIdentityKey(for source: CoverCarouselConfiguration.Source) -> String {
        switch source {
        case let .images(images):
            images.enumerated().map { index, image in
                image.map { "\(index):\(ObjectIdentifier($0).hashValue)" } ?? "\(index):nil"
            }.joined(separator: "|")
        case let .dynamic(_, _, _, _, phaseResetKey):
            phaseResetKey
        }
    }

    private func previewSize(for image: NSImage?, configuration: CoverCarouselConfiguration) -> CGSize {
        let side = configuration.baseIconSize * 1.2
        var aspect: CGFloat = 1
        if configuration.preserveArtworkAspectRatio, let image, image.size.width > 1, image.size.height > 1 {
            aspect = image.size.width / image.size.height
        }
        aspect = max(0.4, min(3.0, aspect))
        return aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
    }

    // MARK: - Motion

    private struct CoverState {
        let x: CGFloat
        let y: CGFloat
        let scale: CGFloat
        let yawDegrees: Double
        let depth: Double
    }

    private func coverState(progress: Double, baseIconSize: CGFloat) -> CoverState {
        let u = min(max(progress, 0), 1)
        let side = baseIconSize * 1.12
        let xHidden = side * 0.40
        let xPeak = side * 1.24
        let xExit = -side * 1.18
        let x: CGFloat
        if u < 0.30 {
            let t = u / 0.30
            x = xHidden + (xPeak - xHidden) * CGFloat(1 - pow(1 - t, 2))
        } else {
            let t = (u - 0.30) / 0.70
            x = xPeak + (xExit - xPeak) * CGFloat(t * t)
        }
        let scale = (0.34 + CGFloat(pow(u, 1.85)) * 1.72) * 1.4
        return CoverState(x: x, y: side * 0.12, scale: scale, yawDegrees: -20 + 90 * u, depth: u)
    }

    private func installAnimations(bounds: CGSize) {
        guard let configuration else { return }
        let center = CGPoint(x: bounds.width * 0.5, y: bounds.height * 0.5)
        let count = Self.keyframeCount
        let keyTimes = (0 ... count).map { NSNumber(value: Double($0) / Double(count)) }
        let states = (0 ... count).map { coverState(progress: Double($0) / Double(count), baseIconSize: configuration.baseIconSize) }
        // Each cover is laid out in a frame 100 points taller than the artwork (SwiftUI padding), so
        // scaling about that frame's centre moves the artwork up by 50 points times the scale.
        let space = LayerSpace(height: bounds.height)
        let positions = states.map { state in
            NSValue.layerPoint(space.point(CGPoint(
                x: center.x + configuration.horizontalOffset + state.x,
                y: center.y + configuration.verticalOffset + state.y - 50 * state.scale,
            )))
        }
        let elapsed = max(0, CACurrentMediaTime() - phaseOrigin)
        for (slot, lane) in lanes.enumerated() {
            let size = lane.size == .zero ? CGSize(width: configuration.baseIconSize * 1.2, height: configuration.baseIconSize * 1.2) : lane.size
            let transforms = states.map { state in
                NSValue(caTransform3D: CATransform3DConcat(
                    yawTransform(degrees: state.yawDegrees, perspective: 0.75, viewSize: size),
                    CATransform3DMakeScale(state.scale, state.scale, 1),
                ))
            }
            let lanePosition = elapsed * Self.coversPerSecond - Double(slot) / Double(Self.laneCount)
            let progress = lanePosition - floor(lanePosition)
            for layer in [lane.reflection, lane.preview] {
                layer.removeAllAnimations()
                let group = CAAnimationGroup()
                group.animations = [
                    keyframes("position", positions, keyTimes),
                    keyframes("transform", transforms, keyTimes),
                ]
                group.duration = Self.cycleDuration
                group.repeatCount = .infinity
                // beginTime 0: the animation starts when Core Animation commits it, in whatever
                // time space the layer ends up in; the phase comes from timeOffset alone.
                group.beginTime = 0
                group.timeOffset = progress * Self.cycleDuration
                group.isRemovedOnCompletion = false
                layer.add(group, forKey: "carousel")
                // The model values match the animation's starting frame, in case it is ever removed.
                let index = min(count, max(0, Int((progress * Double(count)).rounded())))
                withoutLayerActions {
                    layer.position = positions[index].layerPointValue
                    layer.transform = transforms[index].caTransform3DValue
                }
            }
        }
    }

    /// Covers further through their cycle are nearer the viewer. The order only changes when a
    /// lane wraps round, which is when this runs.
    private func applyDepthOrder(elapsed: Double) {
        let ordered = lanes.enumerated().map { slot, lane -> (progress: Double, layer: CALayer) in
            let lanePosition = elapsed * Self.coversPerSecond - Double(slot) / Double(Self.laneCount)
            return (lanePosition - floor(lanePosition), lane.plane)
        }.sorted { $0.progress < $1.progress }.map(\.layer)
        guard previewContainer.sublayers?.elementsEqual(ordered, by: ===) != true else { return }
        withoutLayerActions {
            previewContainer.sublayers = ordered
        }
    }

    private func keyframes(_ keyPath: String, _ values: [Any], _ keyTimes: [NSNumber]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.calculationMode = .linear
        return animation
    }

    /// Wakes up just after the next lane wraps round, to give it its next cover.
    private func scheduleWrapTimer() {
        wrapTimer?.invalidate()
        let elapsed = max(0, CACurrentMediaTime() - phaseOrigin)
        let quarter = Self.cycleDuration / Double(Self.laneCount)
        let nextWrap = (floor(elapsed / quarter) + 1) * quarter
        let delay = max(0.01, nextWrap - elapsed) + 0.03
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLaneImages()
                self?.scheduleWrapTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wrapTimer = timer
    }
}

/// Upside-down copies of artwork with the reflection's fade baked into the alpha channel, so
/// the reflection layer needs no mask (masks cost an offscreen render pass every frame).
@MainActor
enum ReflectionImageCache {
    private static let cache: NSCache<NSString, ReflectionBox> = {
        let cache = NSCache<NSString, ReflectionBox>()
        cache.countLimit = 200
        return cache
    }()

    private final class ReflectionBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    static func reflection(for image: NSImage?, size: CGSize, fadeEnd: CGFloat, placeholderSide: CGFloat) -> CGImage? {
        let source = LayerImageCache.cgImage(for: image) ?? CoverArtPlaceholder.image(side: placeholderSide)
        guard let source, size.width > 0, size.height > 0 else { return nil }
        let key = "\(ObjectIdentifier(source).hashValue)|\(Int(size.width))x\(Int(size.height))|\(fadeEnd)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.image
        }
        // Reflections are faint and soft, so a modest bitmap is plenty.
        let pixelScale = min(1.0, 512 / max(size.width, size.height))
        let width = max(1, Int(size.width * pixelScale))
        let height = max(1, Int(size.height * pixelScale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        // Fade: opaque at the top (next to the artwork), clear at `fadeEnd` of the height.
        let fadeColors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: fadeColors, locations: [0, 1]) {
            context.saveGState()
            context.clip(to: rect, mask: alphaMask(width: width, height: height, gradient: gradient, fadeEnd: fadeEnd) ?? source)
            // Flipped: the image's bottom row ends up at the top of the reflection.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(rect)
            drawAspectFill(source, in: rect, context: context)
            context.restoreGState()
        }
        guard let reflection = context.makeImage() else { return nil }
        cache.setObject(ReflectionBox(reflection), forKey: key)
        return reflection
    }

    private static func alphaMask(width: Int, height: Int, gradient: CGGradient, fadeEnd: CGFloat) -> CGImage? {
        guard let mask = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
        ) else { return nil }
        let top = CGFloat(height)
        let fadeBottom = top - CGFloat(height) * fadeEnd
        // White (shown) at the top edge, black (hidden) from `fadeEnd` down.
        mask.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: fadeBottom), options: [])
        return mask.makeImage()
    }

    static func drawAspectFill(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let imageAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        let rectAspect = rect.width / max(1, rect.height)
        var drawRect = rect
        if imageAspect > rectAspect {
            drawRect.size.width = rect.height * imageAspect
            drawRect.origin.x = rect.midX - drawRect.width / 2
        } else {
            drawRect.size.height = rect.width / imageAspect
            drawRect.origin.y = rect.midY - drawRect.height / 2
        }
        context.saveGState()
        context.clip(to: rect)
        context.interpolationQuality = .medium
        context.draw(image, in: drawRect)
        context.restoreGState()
    }
}

/// The dark tile with a music note shown for songs without artwork.
@MainActor
enum CoverArtPlaceholder {
    private static var cache: [Int: CGImage] = [:]

    static func image(side: CGFloat) -> CGImage? {
        let pixelSide = max(64, Int(side.rounded()))
        if let cached = cache[pixelSide] {
            return cached
        }
        guard let context = CGContext(
            data: nil, width: pixelSide, height: pixelSide, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: pixelSide, height: pixelSide)
        let colors = [
            CGColor(red: 0.12, green: 0.13, blue: 0.17, alpha: 1),
            CGColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: rect.maxX, y: 0), options: [])
        }
        #if os(macOS)
            if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: CGFloat(pixelSide) * 0.26, weight: .regular)),
                let noteImage = note.cgImage(forProposedRect: nil, context: nil, hints: nil)
            {
                let noteRect = CGRect(
                    x: (CGFloat(pixelSide) - CGFloat(noteImage.width)) / 2,
                    y: (CGFloat(pixelSide) - CGFloat(noteImage.height)) / 2,
                    width: CGFloat(noteImage.width),
                    height: CGFloat(noteImage.height),
                )
                context.saveGState()
                context.clip(to: noteRect, mask: noteImage)
                context.setFillColor(CGColor(gray: 1, alpha: 0.72))
                context.fill(noteRect)
                context.restoreGState()
            }
        #else
            if let note = UIImage(systemName: "music.note", withConfiguration: UIImage.SymbolConfiguration(pointSize: CGFloat(pixelSide) * 0.26, weight: .regular))?.cgImage {
                let noteRect = CGRect(
                    x: (CGFloat(pixelSide) - CGFloat(note.width)) / 2,
                    y: (CGFloat(pixelSide) - CGFloat(note.height)) / 2,
                    width: CGFloat(note.width),
                    height: CGFloat(note.height),
                )
                context.saveGState()
                context.clip(to: noteRect, mask: note)
                context.setFillColor(CGColor(gray: 1, alpha: 0.72))
                context.fill(noteRect)
                context.restoreGState()
            }
        #endif
        let image = context.makeImage()
        cache[pixelSide] = image
        return image
    }
}
