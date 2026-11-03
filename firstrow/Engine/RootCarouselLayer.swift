import QuartzCore
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif
#if os(macOS)
    import AppKit
#endif

/// The main menu's arc of section icons, the selected one in front with its reflection.
struct RootCarouselConfiguration {
    var images: [NSImage?]
    var selectedIndex: Int
    var isIconAnimated: Bool
    var isEnteringSubmenu: Bool
    var isReturningToRoot: Bool
    var isInSubmenu: Bool
    var showsSettledLandedIcon: Bool
    var iconSize: CGFloat
    var scaleReduction: CGFloat
    var landedIconScale: CGFloat
    var selectedSizeMultiplier: CGFloat
    var arcRadius: CGFloat
    var restingOffset: CGPoint
    var landedOffset: CGPoint
    var entryOffset: CGFloat
    var sceneWidth: CGFloat
    /// Where the carousel's box sits in the scene, so an icon can leave just past the screen's edge.
    var boxOriginInScene: CGPoint = .zero
    var selectionDuration: Double
    /// Holding an arrow key sweeps at a steady speed rather than easing in and out of every step.
    var usesLinearSweep: Bool
    var iconFlightDuration: Double
    var backgroundTransitionDuration: Double
    var backgroundReturnDuration: Double
}

@MainActor
final class RootCarouselLayerController: LayerController {
    let rootLayer: CALayer = StillLayer()

    private final class Icon {
        let container = StillLayer()
        let image = StillLayer()
        let reflection = StillLayer()
        // iOS and tvOS layers have no filters, so blur is a pre-blurred copy faded in over the icon.
        let blurredImage = StillLayer()
        let blurredReflection = StillLayer()
        var blurMargin: CGFloat = 0
        var reflectionBlurMargin: CGFloat = 0
        var state: IconState?
        var imageObject: NSImage?
    }

    private struct IconState: Equatable {
        var center: CGPoint
        var size: CGFloat
        var opacity: Float
        var blurRadius: CGFloat
        var position: Int
        var reflectionCenter: CGPoint
        var reflectionSize: CGFloat
        var reflectionOpacity: Float
        var reflectionBlur: CGFloat
        var showsReflection: Bool

        static func interpolate(_ a: IconState, _ b: IconState, _ t: Double) -> IconState {
            func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(t) }
            func mix(_ x: Float, _ y: Float) -> Float { x + (y - x) * Float(t) }
            return IconState(
                center: CGPoint(x: mix(a.center.x, b.center.x), y: mix(a.center.y, b.center.y)),
                size: mix(a.size, b.size),
                opacity: mix(a.opacity, b.opacity),
                blurRadius: mix(a.blurRadius, b.blurRadius),
                position: t < 0.5 ? a.position : b.position,
                reflectionCenter: CGPoint(x: mix(a.reflectionCenter.x, b.reflectionCenter.x), y: mix(a.reflectionCenter.y, b.reflectionCenter.y)),
                reflectionSize: mix(a.reflectionSize, b.reflectionSize),
                reflectionOpacity: mix(a.reflectionOpacity, b.reflectionOpacity),
                reflectionBlur: mix(a.reflectionBlur, b.reflectionBlur),
                showsReflection: t < 0.5 ? a.showsReflection : b.showsReflection,
            )
        }
    }

    private var icons: [Icon] = []
    private var previous: RootCarouselConfiguration?

    // The selection as a continuous value, so icons stay on the arc however fast arrows are pressed.
    private var phaseFrom: Double = 0
    private var phaseTo: Double = 0
    private var phaseStart: CFTimeInterval = 0
    private var phaseDuration: Double = 0
    private var phaseCurve = TimingCurve.easeInEaseOut

    func update(_ configuration: RootCarouselConfiguration, bounds: CGSize) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if icons.count != configuration.images.count {
            for icon in icons { icon.container.removeFromSuperlayer() }
            icons = configuration.images.map { _ in makeIcon() }
            previous = nil
        }
        updateImages(configuration)
        if let old = previous, Self.onlySelectionChanged(old, configuration) {
            animateSelection(to: configuration, from: old, bounds: bounds)
            previous = configuration
            return
        }
        phaseFrom = Double(configuration.selectedIndex)
        phaseTo = phaseFrom
        phaseDuration = 0
        var from = previous
        if let old = previous, configuration.isReturningToRoot, !old.isReturningToRoot {
            // Back from a section: the change can arrive in one update, so set the start layout here.
            var start = configuration
            start.isEnteringSubmenu = true
            start.isIconAnimated = true
            start.isInSubmenu = true
            start.showsSettledLandedIcon = false
            for (index, icon) in icons.enumerated() {
                apply(state(for: index, configuration: start, bounds: bounds), to: icon, duration: 0, bounds: bounds)
            }
            from = start
        }
        let durations = transitionDurations(from: from, to: configuration)
        for (index, icon) in icons.enumerated() {
            let target = state(for: index, configuration: configuration, bounds: bounds)
            let duration = target.position == 0 ? durations.selected : durations.background
            apply(target, to: icon, duration: icon.state == nil ? 0 : duration, bounds: bounds)
        }
        applyStackingOrder(configuration)
        previous = configuration
    }

    private func updateImages(_ configuration: RootCarouselConfiguration) {
        for (index, icon) in icons.enumerated() {
            let image = configuration.images[index]
            guard icon.imageObject !== image else { continue }
            icon.imageObject = image
            withoutLayerActions {
                icon.image.contents = LayerImageCache.cgImage(for: image)
                icon.reflection.contents = CarouselReflectionCache.reflection(for: image)
                #if !os(macOS)
                    let blurred = (icon.image.contents as! CGImage?).flatMap(BlurredPictureCache.blurred)
                    icon.blurredImage.contents = blurred?.image
                    icon.blurMargin = blurred?.margin ?? 0
                    let blurredReflection = (icon.reflection.contents as! CGImage?).flatMap(BlurredPictureCache.blurred)
                    icon.blurredReflection.contents = blurredReflection?.image
                    icon.reflectionBlurMargin = blurredReflection?.margin ?? 0
                #endif
            }
        }
    }

    private static func onlySelectionChanged(_ old: RootCarouselConfiguration, _ new: RootCarouselConfiguration) -> Bool {
        old.selectedIndex != new.selectedIndex &&
            old.isIconAnimated == new.isIconAnimated &&
            old.isEnteringSubmenu == new.isEnteringSubmenu &&
            old.isReturningToRoot == new.isReturningToRoot &&
            old.isInSubmenu == new.isInSubmenu &&
            old.showsSettledLandedIcon == new.showsSettledLandedIcon
    }

    /// Orders the icons back to front around the selection.
    private func applyStackingOrder(_ c: RootCarouselConfiguration) {
        let count = icons.count
        guard count > 0 else { return }
        let drawOrder = (0 ..< count).map { (c.selectedIndex + $0 + count) % count }.reversed()
        let ordered = drawOrder.enumerated().sorted { lhs, rhs in
            let left = zIndex(position: lhs.element - c.selectedIndex, c)
            let right = zIndex(position: rhs.element - c.selectedIndex, c)
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map { icons[$0.element].container }
        if rootLayer.sublayers?.elementsEqual(ordered, by: ===) != true {
            withoutLayerActions { rootLayer.sublayers = ordered }
        }
    }

    private func zIndex(position: Int, _ c: RootCarouselConfiguration) -> Int {
        if position == 0 { return c.isIconAnimated ? 1000 : 1 }
        return (1 ... 3).contains(position) ? 0 : 1000
    }

    // MARK: - Turning the carousel

    private func presentedPhase(at time: CFTimeInterval) -> Double {
        guard phaseDuration > 0 else { return phaseTo }
        let t = min(1, max(0, (time - phaseStart) / phaseDuration))
        return phaseFrom + (phaseTo - phaseFrom) * phaseCurve.value(at: t)
    }

    /// How fast the selection is turning (slots per second).
    private func phaseVelocity(at time: CFTimeInterval) -> Double {
        guard phaseDuration > 0 else { return 0 }
        let t = (time - phaseStart) / phaseDuration
        return (phaseTo - phaseFrom) * phaseCurve.slope(at: t) / phaseDuration
    }

    /// Core Animation's ease-in-ease-out timing (cubic Bézier with control points 0.42,0 and 0.58,1).
    static func easeInEaseOut(_ x: Double) -> Double {
        TimingCurve.easeInEaseOut.value(at: x)
    }

    /// Where icon `index` is at `phase`, part way along the straight line between two slots.
    private func state(for index: Int, phase: Double, configuration c: RootCarouselConfiguration, bounds: CGSize) -> IconState {
        let position = Double(index) - phase
        let lower = floor(position)
        let fraction = position - lower
        let a = slotState(position: Int(lower), configuration: c, bounds: bounds)
        guard fraction > 0.0001 else { return a }
        let b = slotState(position: Int(lower) + 1, configuration: c, bounds: bounds)
        return IconState.interpolate(a, b, fraction)
    }

    private func animateSelection(to c: RootCarouselConfiguration, from old: RootCarouselConfiguration, bounds: CGSize) {
        let now = CACurrentMediaTime()
        let start = phaseDuration > 0 ? presentedPhase(at: now) : Double(old.selectedIndex)
        let target = Double(c.selectedIndex)
        let duration = c.selectionDuration * 0.85
        // A press while the carousel is still turning carries on at the speed it was going.
        var curve = c.usesLinearSweep ? TimingCurve.linear : TimingCurve.easeInEaseOut
        if !c.usesLinearSweep, target != start {
            let slope = phaseVelocity(at: now) * duration / (target - start)
            curve = .easeInOut(startingSlope: slope)
        }
        phaseFrom = start
        phaseTo = target
        phaseStart = now
        phaseDuration = duration
        phaseCurve = curve
        // Key frames wherever an icon passes through a slot, so the path between them is exact.
        var phases = [start]
        if target > start {
            var slot = floor(start) + 1
            while slot < target { phases.append(slot); slot += 1 }
        } else {
            var slot = ceil(start) - 1
            while slot > target { phases.append(slot); slot -= 1 }
        }
        phases.append(target)
        let span = abs(target - start)
        let keyTimes = phases.map { NSNumber(value: span > 0 ? abs($0 - start) / span : 1) }
        let timing = curve.function
        let space = LayerSpace(height: bounds.height)
        for (index, icon) in icons.enumerated() {
            let states = phases.map { state(for: index, phase: $0, configuration: c, bounds: bounds) }
            guard let final = states.last else { continue }
            func run(_ layer: CALayer, _ keyPath: String, _ values: [Any]) {
                guard let last = values.last else { return }
                let animation = CAKeyframeAnimation(keyPath: keyPath)
                animation.values = values
                animation.keyTimes = keyTimes
                animation.calculationMode = .linear
                animation.timingFunction = timing
                animation.duration = duration
                // Begin when the start was computed, so later work in this pass can't delay it.
                animation.beginTime = layer.convertTime(now, from: nil)
                withoutLayerActions { layer.setValue(last, forKeyPath: keyPath) }
                layer.add(animation, forKey: keyPath)
            }
            run(icon.container, "position", states.map { NSValue.layerPoint(space.point($0.center)) })
            run(icon.container, "opacity", states.map { NSNumber(value: $0.opacity) })
            run(icon.image, "bounds", states.map { NSValue.layerRect(CGRect(x: 0, y: 0, width: $0.size, height: $0.size)) })
            run(icon.reflection, "bounds", states.map { NSValue.layerRect(CGRect(x: 0, y: 0, width: $0.reflectionSize, height: $0.reflectionSize)) })
            run(icon.reflection, "position", states.map { NSValue.layerPoint(Self.reflectionPosition($0)) })
            #if os(macOS)
                run(icon.reflection, "opacity", states.map { NSNumber(value: $0.showsReflection ? $0.reflectionOpacity : 0) })
                run(icon.container, "filters.blur.inputRadius", states.map { NSNumber(value: Double($0.blurRadius)) })
                run(icon.reflection, "filters.blur.inputRadius", states.map { NSNumber(value: Double($0.reflectionBlur)) })
            #else
                let blurs = states.map(Self.blurAmount)
                let reflections = states.map { Float($0.showsReflection ? $0.reflectionOpacity : 0) }
                run(icon.image, "opacity", blurs.map { NSNumber(value: 1 - $0) })
                run(icon.blurredImage, "opacity", blurs.map { NSNumber(value: $0) })
                run(icon.blurredImage, "bounds", states.map { NSValue.layerRect(Self.blurredBounds($0.size, margin: icon.blurMargin)) })
                run(icon.reflection, "opacity", zip(reflections, blurs).map { NSNumber(value: $0 * (1 - $1)) })
                run(icon.blurredReflection, "opacity", zip(reflections, blurs).map { NSNumber(value: $0 * $1) })
                run(icon.blurredReflection, "bounds", states.map { NSValue.layerRect(Self.blurredBounds($0.reflectionSize, margin: icon.reflectionBlurMargin)) })
                run(icon.blurredReflection, "position", states.map { NSValue.layerPoint(Self.reflectionPosition($0)) })
            #endif
            icon.state = final
        }
        applyStackingOrder(c)
    }

    private static func reflectionPosition(_ state: IconState) -> CGPoint {
        // Relative to the icon's centre (the container's origin).
        #if os(macOS)
            CGPoint(x: state.reflectionCenter.x, y: -state.reflectionCenter.y)
        #else
            state.reflectionCenter
        #endif
    }

    /// How far into the blurred copy an icon is (0 sharp, 1 as blurred as the arc's icons).
    private static func blurAmount(_ state: IconState) -> Float {
        Float(min(1, max(0, state.blurRadius / 10)))
    }

    /// The blurred copy's box: the picture's box grown by the blur's margin on every side.
    private static func blurredBounds(_ side: CGFloat, margin: CGFloat) -> CGRect {
        let grown = side * (1 + margin * 2)
        return CGRect(x: 0, y: 0, width: grown, height: grown)
    }

    private func makeIcon() -> Icon {
        let icon = Icon()
        icon.image.contentsGravity = .resizeAspect
        icon.reflection.contentsGravity = .resizeAspect
        icon.container.addSublayer(icon.reflection)
        icon.container.addSublayer(icon.image)
        #if os(macOS)
            icon.container.masksToBounds = false
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.name = "blur"
                blur.setValue(0, forKey: kCIInputRadiusKey)
                icon.container.filters = [blur]
            }
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.name = "blur"
                blur.setValue(0, forKey: kCIInputRadiusKey)
                icon.reflection.filters = [blur]
            }
        #else
            for layer in [icon.blurredImage, icon.blurredReflection] {
                layer.contentsGravity = .resizeAspect
                layer.opacity = 0
            }
            icon.container.insertSublayer(icon.blurredReflection, above: icon.reflection)
            icon.container.addSublayer(icon.blurredImage)
        #endif
        return icon
    }

    /// Which change is under way decides how long icons take to get where they are going.
    private func transitionDurations(
        from old: RootCarouselConfiguration?,
        to new: RootCarouselConfiguration,
    ) -> (selected: Double, background: Double) {
        guard let old else { return (0, 0) }
        if old.showsSettledLandedIcon != new.showsSettledLandedIcon {
            return (0, 0)
        }
        var selected: Double = 0
        var background: Double = 0
        if old.selectedIndex != new.selectedIndex {
            selected = new.selectionDuration * 0.85
            background = new.selectionDuration * 0.85
        }
        if old.isIconAnimated != new.isIconAnimated {
            selected = new.iconFlightDuration
        }
        if old.isEnteringSubmenu != new.isEnteringSubmenu {
            background = new.isReturningToRoot ? new.backgroundReturnDuration : new.backgroundTransitionDuration
        }
        return (selected, background)
    }

    /// Where icon `index` sits. Offsets are from 50 points above the carousel's centre.
    private func state(for index: Int, configuration c: RootCarouselConfiguration, bounds: CGSize) -> IconState {
        slotState(position: index - c.selectedIndex, configuration: c, bounds: bounds)
    }

    /// The icon `position` places after the selection (negative: before it).
    /// Only the selection and the three after it sit on the arc, and positions never wrap round.
    private func slotState(position: Int, configuration c: RootCarouselConfiguration, bounds: CGSize) -> IconState {
        let angle = CGFloat(position) * .pi / 6
        let isLanded = position == 0 && c.isIconAnimated
        // Slot -1 is just off the left edge at front size, so the outgoing icon slides off in view.
        let isExitSlot = position == -1
        let scale = isLanded ? c.landedIconScale : (isExitSlot ? 1 : 1 - CGFloat(abs(position)) * c.scaleReduction)
        var x: CGFloat
        var y: CGFloat
        if isLanded {
            x = c.landedOffset.x
            y = c.landedOffset.y
        } else if position == 0 {
            x = -1.25 * c.arcRadius * sin(angle) * 1.5 + c.restingOffset.x
            y = c.restingOffset.y
        } else if (1 ... 3).contains(position) {
            x = -1.25 * c.arcRadius * sin(angle) * 0.9 - 0.1 * c.iconSize
            y = -c.arcRadius * (1 - cos(angle)) * 0.025 + (position < 2 ? 0.2 * c.iconSize : 0.15 * c.iconSize)
        } else if isExitSlot {
            let frontSize = c.iconSize * c.selectedSizeMultiplier
            let front = CGPoint(x: c.restingOffset.x - c.entryOffset, y: c.restingOffset.y + c.entryOffset)
            x = -frontSize * 0.5 - 24 - c.boxOriginInScene.x - bounds.width / 2
            // Down and to the left, in the direction the far slot lies.
            y = front.y + (front.x - x) * ((1280 - front.y) / (front.x + 1920))
        } else {
            x = -1920
            y = 1280
        }
        if c.isEnteringSubmenu, position != 0 {
            x -= max(c.sceneWidth * 1.15, c.iconSize * 3)
        }
        let baseOpacity: CGFloat = position == 0 ? 1 : (abs(position) <= 2 ? 1 : max(0, 1 - CGFloat(abs(position)) * 0.4))
        var opacity = c.isEnteringSubmenu && position != 0 ? max(0, baseOpacity - 0.95) : baseOpacity
        let isIncoming = position == 0 && !c.isIconAnimated
        let baseX = x + (isIncoming ? -c.entryOffset : 0)
        let baseY = y + (isIncoming ? c.entryOffset : 0)
        let adjustedSize = !isExitSlot && (abs(position) == 1 || abs(position) == 2) ? c.iconSize : c.iconSize * c.selectedSizeMultiplier
        // Hidden while the section's own landed icon stands in, and in sections apart from the selected one.
        if c.showsSettledLandedIcon {
            opacity = 0
        } else if c.isInSubmenu, !c.isReturningToRoot, position != 0 {
            opacity = 0
        }
        // The reflection stays behind, faint and soft, while the selected icon flies to or from a section.
        let animateReflection = position == 0 && (!c.isInSubmenu || c.isEnteringSubmenu || c.isReturningToRoot)
        let detached = animateReflection &&
            ((c.isEnteringSubmenu && !c.isReturningToRoot) || (c.isReturningToRoot && c.isIconAnimated))
        let compensation = position == 0 && (c.isIconAnimated || c.isEnteringSubmenu)
            ? CGPoint(x: x - c.restingOffset.x, y: y - c.restingOffset.y)
            : .zero
        let reflectionOffset = detached
            ? CGPoint(x: 90 - compensation.x, y: 920 - compensation.y)
            : CGPoint(x: 0, y: -(adjustedSize * 0.215))
        let reflectionScale = detached ? 1 : scale
        let showsReflection = !(position == 0 && c.isInSubmenu && !c.isEnteringSubmenu && !c.isReturningToRoot)
        let center = CGPoint(x: bounds.width / 2 + baseX, y: bounds.height / 2 - 50 + baseY)
        // The reflection sits below the icon's frame, offset, then scaled about the icon's centre.
        let reflectionCenter = CGPoint(
            x: reflectionOffset.x * reflectionScale,
            y: (adjustedSize + reflectionOffset.y) * reflectionScale,
        )
        return IconState(
            center: center,
            size: adjustedSize * scale,
            opacity: Float(opacity),
            blurRadius: position != 0 && !isExitSlot ? 10 : 0,
            position: position,
            reflectionCenter: reflectionCenter,
            reflectionSize: adjustedSize * reflectionScale,
            reflectionOpacity: detached ? 0.22 : 0.34,
            reflectionBlur: detached ? 3 : 0,
            showsReflection: showsReflection,
        )
    }

    private func apply(_ target: IconState, to icon: Icon, duration: Double, bounds: CGSize) {
        guard icon.state != target else { return }
        icon.state = target
        let space = LayerSpace(height: bounds.height)
        let size = CGSize(width: target.size, height: target.size)
        let reflectionSize = CGSize(width: target.reflectionSize, height: target.reflectionSize)
        // Positions inside the container are relative to the icon's centre (the container's origin).
        let reflectionPosition = Self.reflectionPosition(target)
        CATransaction.begin()
        CATransaction.setDisableActions(duration <= 0)
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        }
        animate(icon.container, "position", to: NSValue.layerPoint(space.point(target.center)), duration: duration)
        animate(icon.container, "opacity", to: NSNumber(value: target.opacity), duration: duration)
        animate(icon.image, "bounds", to: NSValue.layerRect(CGRect(origin: .zero, size: size)), duration: duration)
        animate(icon.reflection, "bounds", to: NSValue.layerRect(CGRect(origin: .zero, size: reflectionSize)), duration: duration)
        animate(icon.reflection, "position", to: NSValue.layerPoint(reflectionPosition), duration: duration)
        let reflectionDuration = target.showsReflection ? duration : 0
        #if os(macOS)
            animate(icon.reflection, "opacity", to: NSNumber(value: target.showsReflection ? target.reflectionOpacity : 0), duration: reflectionDuration)
            animate(icon.container, "filters.blur.inputRadius", to: NSNumber(value: Double(target.blurRadius)), duration: duration)
            animate(icon.reflection, "filters.blur.inputRadius", to: NSNumber(value: Double(target.reflectionBlur)), duration: duration)
        #else
            let blur = Self.blurAmount(target)
            let reflectionOpacity = target.showsReflection ? target.reflectionOpacity : 0
            animate(icon.image, "opacity", to: NSNumber(value: 1 - blur), duration: duration)
            animate(icon.blurredImage, "opacity", to: NSNumber(value: blur), duration: duration)
            animate(icon.blurredImage, "bounds", to: NSValue.layerRect(Self.blurredBounds(target.size, margin: icon.blurMargin)), duration: duration)
            animate(icon.reflection, "opacity", to: NSNumber(value: reflectionOpacity * (1 - blur)), duration: reflectionDuration)
            animate(icon.blurredReflection, "opacity", to: NSNumber(value: reflectionOpacity * blur), duration: reflectionDuration)
            animate(icon.blurredReflection, "bounds", to: NSValue.layerRect(Self.blurredBounds(target.reflectionSize, margin: icon.reflectionBlurMargin)), duration: duration)
            animate(icon.blurredReflection, "position", to: NSValue.layerPoint(reflectionPosition), duration: duration)
        #endif
        CATransaction.commit()
    }

    /// Animates from what is on screen now (mid-flight if an animation is running) to `value`.
    private func animate(_ layer: CALayer, _ keyPath: String, to value: Any, duration: Double) {
        guard duration > 0 else {
            layer.removeAnimation(forKey: keyPath)
            layer.setValue(value, forKeyPath: keyPath)
            return
        }
        let animation = CABasicAnimation(keyPath: keyPath)
        // Use the model value unless mid-flight: the presentation layer lags a value set this update.
        let source: CALayer = layer.animation(forKey: keyPath) != nil ? (layer.presentation() ?? layer) : layer
        animation.fromValue = source.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.setValue(value, forKeyPath: keyPath)
        layer.add(animation, forKey: keyPath)
    }
}

/// Icon reflections: the icon flipped, fading from 100% at its base to nothing 60% of the way down.
@MainActor
enum CarouselReflectionCache {
    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// Keyed by the image object itself (kept alive by the cache), never by its address.
    private static let cache: NSCache<NSImage, Box> = {
        let cache = NSCache<NSImage, Box>()
        cache.countLimit = 24
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func reflection(for image: NSImage?) -> CGImage? {
        guard let image else { return nil }
        if let cached = cache.object(forKey: image) {
            return cached.image
        }
        guard let source = LayerImageCache.cgImage(for: image) else { return nil }
        let width = source.width
        let height = source.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: layerBitmapInfo,
        ), let mask = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue,
        ) else { return nil }
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) else { return nil }
        // White at the top of the reflection (next to the icon), black from 60% of the way down.
        mask.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: 0, y: CGFloat(height) * 0.4), options: [.drawsAfterEndLocation])
        guard let maskImage = mask.makeImage() else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clip(to: rect, mask: maskImage)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(source, in: rect)
        guard let reflection = context.makeImage() else { return nil }
        cache.setObject(Box(reflection), forKey: image, cost: reflection.bytesPerRow * reflection.height)
        return reflection
    }
}

extension NSValue {
    static func layerRect(_ rect: CGRect) -> NSValue {
        #if os(macOS)
            NSValue(rect: rect)
        #else
            NSValue(cgRect: rect)
        #endif
    }
}

#if !os(macOS)
    import CoreImage

    /// Small blurred copies of pictures, for platforms whose layers have no filters.
    /// `margin` is the clear border the blur spreads into, as a share of the picture's side.
    @MainActor
    enum BlurredPictureCache {
        private final class Box {
            let image: CGImage
            let margin: CGFloat
            init(_ image: CGImage, margin: CGFloat) {
                self.image = image
                self.margin = margin
            }
        }

        private static let cache: NSCache<AnyObject, Box> = {
            let cache = NSCache<AnyObject, Box>()
            cache.countLimit = 40
            return cache
        }()

        private static let context = CIContext(options: [.cacheIntermediates: false])

        static func blurred(_ source: CGImage) -> (image: CGImage, margin: CGFloat)? {
            if let cached = cache.object(forKey: source) {
                return (cached.image, cached.margin)
            }
            let longest = CGFloat(max(source.width, source.height))
            guard longest > 0 else { return nil }
            let shrink = min(1, 192 / longest)
            let input = CIImage(cgImage: source).transformed(by: CGAffineTransform(scaleX: shrink, y: shrink))
            let side = max(input.extent.width, input.extent.height)
            // Same blur as on the Mac: 10 points on an icon about 280 points across.
            let sigma = Double(side) * 10 / 280
            let margin = CGFloat(ceil(sigma * 3))
            let output = input.applyingGaussianBlur(sigma: sigma)
            guard let image = context.createCGImage(
                output,
                from: input.extent.insetBy(dx: -margin, dy: -margin),
                format: .BGRA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB),
            ) else { return nil }
            let box = Box(image, margin: margin / side)
            cache.setObject(box, forKey: source)
            return (box.image, box.margin)
        }
    }
#endif
