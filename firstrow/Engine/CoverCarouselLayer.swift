import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// Album covers drifting across the Music menu and iTunes Top, in four lanes a quarter cycle apart.
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
    /// The part of a cover's trip over which it fades in at the back.
    private static let spawnFadeFraction: Double = 0.03

    private final class Lane {
        /// Untransformed parent so covers paint back to front rather than depth-test in 3D.
        let plane = StillLayer()
        let preview = StillLayer()
        /// Follows the artwork's position and rotation, with its picture just below the artwork.
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
            // The covers go where they are in their trip straight away: the frame or two before
            // the motion starts would otherwise show them piled up, full size, in the corner.
            placeAtCurrentPhase(bounds: bounds)
            // Deferred out of the render pass's transaction so its animations can't touch these.
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

    /// The cover a lane shows at `elapsed`. The offset keeps the first four covers distinct.
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
            // Deferred: prefetching changes menu state, so it must not run during a render pass.
            DispatchQueue.main.async { prefetch(maxSerial) }
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

    /// Where a cover is (in the carousel's own layer space) and how it's turned and sized.
    private func pose(_ state: CoverState, size: CGSize, bounds: CGSize, configuration: CoverCarouselConfiguration) -> (position: CGPoint, transform: CATransform3D) {
        // Scaling about a frame 100 pt taller than the artwork lifts it by 50 pt times the scale.
        let position = LayerSpace(height: bounds.height).point(CGPoint(
            x: bounds.width * 0.5 + configuration.horizontalOffset + state.x,
            y: bounds.height * 0.5 + configuration.verticalOffset + state.y - 50 * state.scale,
        ))
        let transform = CATransform3DConcat(
            yawTransform(degrees: state.yawDegrees, perspective: 0.75, viewSize: size),
            CATransform3DMakeScale(state.scale, state.scale, 1),
        )
        return (position, transform)
    }

    private func laneProgress(slot: Int, elapsed: Double) -> Double {
        let lanePosition = elapsed * Self.coversPerSecond - Double(slot) / Double(Self.laneCount)
        return lanePosition - floor(lanePosition)
    }

    /// Each cover's still pose for now, held until the motion is installed.
    private func placeAtCurrentPhase(bounds: CGSize) {
        guard let configuration else { return }
        let elapsed = max(0, CACurrentMediaTime() - phaseOrigin)
        withoutLayerActions {
            for (slot, lane) in lanes.enumerated() {
                let progress = laneProgress(slot: slot, elapsed: elapsed)
                let size = lane.size == .zero ? CGSize(width: configuration.baseIconSize * 1.2, height: configuration.baseIconSize * 1.2) : lane.size
                let pose = pose(coverState(progress: progress, baseIconSize: configuration.baseIconSize), size: size, bounds: bounds, configuration: configuration)
                for layer in [lane.reflection, lane.preview] {
                    // Only the first look: running motion overrides these.
                    guard layer.animation(forKey: "carousel") == nil else { continue }
                    layer.position = pose.position
                    layer.transform = pose.transform
                }
            }
        }
    }

    private func installAnimations(bounds: CGSize) {
        guard let configuration else { return }
        let count = Self.keyframeCount
        let keyTimes = (0 ... count).map { NSNumber(value: Double($0) / Double(count)) }
        let states = (0 ... count).map { coverState(progress: Double($0) / Double(count), baseIconSize: configuration.baseIconSize) }
        let elapsed = max(0, CACurrentMediaTime() - phaseOrigin)
        for (slot, lane) in lanes.enumerated() {
            let size = lane.size == .zero ? CGSize(width: configuration.baseIconSize * 1.2, height: configuration.baseIconSize * 1.2) : lane.size
            let poses = states.map { pose($0, size: size, bounds: bounds, configuration: configuration) }
            let positions = poses.map { NSValue.layerPoint($0.position) }
            let transforms = poses.map { NSValue(caTransform3D: $0.transform) }
            let progress = laneProgress(slot: slot, elapsed: elapsed)
            // Animated depth puts a cover that just wrapped behind the others from its first frame.
            lane.plane.removeAllAnimations()
            let depth = CAKeyframeAnimation(keyPath: "zPosition").preferringProMotion()
            depth.values = [0, 1]
            depth.keyTimes = [0, 1]
            depth.duration = Self.cycleDuration
            depth.repeatCount = .infinity
            depth.beginTime = 0
            depth.timeOffset = progress * Self.cycleDuration
            depth.isRemovedOnCompletion = false
            lane.plane.add(depth, forKey: "depth")
            for layer in [lane.reflection, lane.preview] {
                layer.removeAllAnimations()
                // The fade-in at the back also hides the switch to the next picture.
                let peakOpacity = layer === lane.reflection ? Double(Self.reflectionOpacity) : 1
                let fades = keyTimes.map { NSNumber(value: peakOpacity * min(1, $0.doubleValue / Self.spawnFadeFraction)) }
                let group = CAAnimationGroup().preferringProMotion()
                group.animations = [
                    keyframes("position", positions, keyTimes),
                    keyframes("transform", transforms, keyTimes),
                    keyframes("opacity", fades, keyTimes),
                ]
                group.duration = Self.cycleDuration
                group.repeatCount = .infinity
                // beginTime 0 starts on commit, so the phase comes from timeOffset alone.
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

    /// Puts covers further through their cycle nearer the viewer. Runs when a lane wraps.
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
        let animation = CAKeyframeAnimation(keyPath: keyPath).preferringProMotion()
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
        let timer = Timer(after: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible {
                // One transaction, so the new pictures, sizes and order reach the screen together.
                CATransaction.begin()
                self?.refreshLaneImages()
                CATransaction.commit()
                self?.scheduleWrapTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wrapTimer = timer
    }
}

/// Flipped artwork with the fade baked into alpha, so reflections need no offscreen mask pass.
@MainActor
enum ReflectionImageCache {
    private static let cache: NSCache<ReflectionKey, ReflectionBox> = {
        let cache = NSCache<ReflectionKey, ReflectionBox>()
        cache.countLimit = 120
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    private final class ReflectionBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// Retains the source so a new image at a freed one's address can't match a stale reflection.
    private final class ReflectionKey: NSObject {
        let source: CGImage
        let width: Int
        let height: Int
        let fadeEnd: CGFloat

        init(source: CGImage, width: Int, height: Int, fadeEnd: CGFloat) {
            self.source = source
            self.width = width
            self.height = height
            self.fadeEnd = fadeEnd
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? ReflectionKey else { return false }
            return other.source === source && other.width == width && other.height == height && other.fadeEnd == fadeEnd
        }

        override var hash: Int {
            ObjectIdentifier(source).hashValue ^ (width &* 31) ^ (height &* 1009)
        }
    }

    static func reflection(for image: NSImage?, size: CGSize, fadeEnd: CGFloat, placeholderSide: CGFloat) -> CGImage? {
        let source = LayerImageCache.cgImage(for: image) ?? CoverArtPlaceholder.image(side: placeholderSide)
        guard let source, size.width > 0, size.height > 0 else { return nil }
        let key = ReflectionKey(source: source, width: Int(size.width), height: Int(size.height), fadeEnd: fadeEnd)
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
            bitmapInfo: layerBitmapInfo,
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
        // The key keeps its source picture alive too, so that counts towards the limit.
        cache.setObject(ReflectionBox(reflection), forKey: key, cost: reflection.bytesPerRow * reflection.height + source.bytesPerRow * source.height)
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
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: layerBitmapInfo,
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
            if #available(macOS 11.0, *), let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
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
            } else if let note = SymbolFallback.symbol("music.note", pointSize: CGFloat(pixelSide) * 0.26, weight: .regular, oversample: 1) {
                let noteRect = CGRect(
                    x: (CGFloat(pixelSide) - note.size.width) / 2,
                    y: (CGFloat(pixelSide) - note.size.height) / 2,
                    width: note.size.width,
                    height: note.size.height,
                )
                context.saveGState()
                context.setAlpha(0.72)
                context.draw(note.image, in: noteRect)
                context.restoreGState()
            }
        #elseif FIRSTROW_PORTABLE
            if let note = SymbolFallback.symbol("music.note", pointSize: CGFloat(pixelSide) * 0.26, weight: .regular, oversample: 1) {
                let noteRect = CGRect(
                    x: (CGFloat(pixelSide) - note.size.width) / 2,
                    y: (CGFloat(pixelSide) - note.size.height) / 2,
                    width: note.size.width,
                    height: note.size.height,
                )
                context.saveGState()
                context.setAlpha(0.72)
                context.draw(note.image, in: noteRect)
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
