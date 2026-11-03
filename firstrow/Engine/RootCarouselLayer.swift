import QuartzCore
import SwiftUI
#if os(macOS)
    import AppKit
#endif

/// The arc of section icons on the main menu (Movies, TV Shows, Music, ...), drawn with Core
/// Animation: the selected icon in front with its reflection, the next three getting smaller
/// and blurrier behind it. Moving the selection, entering a section (the selected icon flies up
/// beside the title while the rest slide away) and coming back are layer animations, so the
/// render server moves the icons instead of SwiftUI recomputing them every frame.
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
    var selectionDuration: Double
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
    }

    private var icons: [Icon] = []
    private var previous: RootCarouselConfiguration?

    func update(_ configuration: RootCarouselConfiguration, bounds: CGSize) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        if icons.count != configuration.images.count {
            for icon in icons { icon.container.removeFromSuperlayer() }
            icons = configuration.images.map { _ in makeIcon() }
            previous = nil
        }
        var from = previous
        if let old = previous, configuration.isReturningToRoot, !old.isReturningToRoot {
            // Coming back from a section: start from where the carousel was left (selected icon
            // up by the title, the rest off to the left), shown instantly, then fly home. SwiftUI
            // may deliver the whole change in one update, so the starting point is set here.
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
            let image = configuration.images[index]
            if icon.imageObject !== image {
                icon.imageObject = image
                withoutLayerActions {
                    icon.image.contents = LayerImageCache.cgImage(for: image)
                    icon.reflection.contents = CarouselReflectionCache.reflection(for: image)
                }
            }
            let target = state(for: index, configuration: configuration, bounds: bounds)
            let duration = target.position == 0 ? durations.selected : durations.background
            apply(target, to: icon, duration: icon.state == nil ? 0 : duration, bounds: bounds)
        }
        // Farther icons first; the selected one on top.
        let ordered = icons.sorted { ($0.state?.position ?? 0) > ($1.state?.position ?? 0) }.map(\.container)
        if rootLayer.sublayers?.elementsEqual(ordered, by: ===) != true {
            withoutLayerActions { rootLayer.sublayers = ordered }
        }
        previous = configuration
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

    /// Where icon `index` sits, ported from the SwiftUI layout: offsets are from the carousel's
    /// centre, 50 points above it (the icons' frames carried 100 points of bottom padding).
    private func state(for index: Int, configuration c: RootCarouselConfiguration, bounds: CGSize) -> IconState {
        let count = c.images.count
        var position = index - c.selectedIndex
        // The arc shows the selection and the six after it (wrapping round).
        if position < 0 { position += count }
        let angle = CGFloat(position) * .pi / 6
        let isLanded = position == 0 && c.isIconAnimated
        let scale = isLanded ? c.landedIconScale : 1 - CGFloat(abs(position)) * c.scaleReduction
        var x: CGFloat
        var y: CGFloat
        if isLanded {
            x = c.landedOffset.x
            y = c.landedOffset.y
        } else if position == 0 {
            x = -1.25 * c.arcRadius * sin(angle) * 1.5 + c.restingOffset.x
            y = c.restingOffset.y
        } else if position <= 3 {
            x = -1.25 * c.arcRadius * sin(angle) * 0.9 - 0.1 * c.iconSize
            y = -c.arcRadius * (1 - cos(angle)) * 0.025 + (position < 2 ? 0.2 * c.iconSize : 0.15 * c.iconSize)
        } else {
            x = -1920
            y = 1280
        }
        if c.isEnteringSubmenu, position != 0 {
            x -= max(c.sceneWidth * 1.15, c.iconSize * 3)
        }
        let baseOpacity: CGFloat = position == 0 ? 1 : (position <= 2 ? 1 : 1 - CGFloat(position) * 0.4)
        var opacity = c.isEnteringSubmenu && position != 0 ? max(0, baseOpacity - 0.95) : baseOpacity
        let isIncoming = position == 0 && !c.isIconAnimated
        let baseX = x + (isIncoming ? -c.entryOffset : 0)
        let baseY = y + (isIncoming ? c.entryOffset : 0)
        let adjustedSize = position == 1 || position == 2 ? c.iconSize : c.iconSize * c.selectedSizeMultiplier
        // Hidden while the section's own landed icon stands in, and in sections apart from the selected one.
        if c.showsSettledLandedIcon {
            opacity = 0
        } else if c.isInSubmenu, !c.isReturningToRoot, position != 0 {
            opacity = 0
        }
        // The reflection: under the icon normally; left behind, faint and soft, while the
        // selected icon flies up into a section or back down.
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
        // In SwiftUI the reflection was the image flipped below its own frame, offset, then
        // scaled about that frame's centre (the icon's centre).
        let reflectionCenter = CGPoint(
            x: reflectionOffset.x * reflectionScale,
            y: (adjustedSize + reflectionOffset.y) * reflectionScale,
        )
        return IconState(
            center: center,
            size: adjustedSize * scale,
            opacity: Float(opacity),
            blurRadius: position != 0 ? 10 : 0,
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
        let reflectionPosition: CGPoint = {
            #if os(macOS)
                CGPoint(x: target.reflectionCenter.x, y: -target.reflectionCenter.y)
            #else
                target.reflectionCenter
            #endif
        }()
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
        animate(icon.reflection, "opacity", to: NSNumber(value: target.showsReflection ? target.reflectionOpacity : 0), duration: target.showsReflection ? duration : 0)
        #if os(macOS)
            animate(icon.container, "filters.blur.inputRadius", to: NSNumber(value: Double(target.blurRadius)), duration: duration)
            animate(icon.reflection, "filters.blur.inputRadius", to: NSNumber(value: Double(target.reflectionBlur)), duration: duration)
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
        // Mid-flight: continue from what is on screen. Otherwise from the model value, which may
        // have been set an instant ago in this same update (the presentation layer lags behind).
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
    private static let cache = NSCache<NSImage, Box>()

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
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
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
        cache.setObject(Box(reflection), forKey: image)
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
