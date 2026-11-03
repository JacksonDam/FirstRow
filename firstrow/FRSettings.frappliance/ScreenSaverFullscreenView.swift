import QuartzCore
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The floating photos screen saver, drawn with Core Animation. Every photo rises at a steady
/// speed and wraps round, and once a minute the whole stream spins round its vertical axis.
/// All of it runs as repeating layer animations, so the app does no work per frame (the
/// SwiftUI version re-projected every photo 144 times a second).
@MainActor
final class ScreenSaverLayerController: LayerController {
    struct Configuration {
        var photos: [ScreenSaverPhotoEntry]
    }

    let rootLayer: CALayer = StillLayer()
    private let sceneLayer = StillLayer()
    private var installedKey: String?
    private var startTime: CFTimeInterval?

    private static let initialEmptyDuration: Double = 3
    private static let spinCycle: Double = 60
    private static let spinDuration: Double = 3
    private static let cameraDistance: CGFloat = 760

    init() {
        rootLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        rootLayer.masksToBounds = true
        rootLayer.addSublayer(sceneLayer)
    }

    func update(_ configuration: Configuration, bounds: CGSize) {
        guard bounds.width > 0, bounds.height > 0, !configuration.photos.isEmpty else { return }
        let key = "\(configuration.photos.count)|\(Int(bounds.width))x\(Int(bounds.height))"
        guard key != installedKey else { return }
        installedKey = key
        let now = CACurrentMediaTime()
        if startTime == nil {
            startTime = now
        }
        install(configuration.photos, size: bounds, elapsedAtInstall: now - (startTime ?? now))
    }

    // MARK: - Spin cycle

    private struct Spin {
        var orbitRadians: Double = 0
        var cardDegrees: Double = 0
        var zoomOut: CGFloat = 0
    }

    /// The spin a minute into each cycle: three seconds round the vertical axis, zooming out and back in.
    private static func spin(atCycleTime cycleTime: Double) -> Spin {
        guard cycleTime < spinDuration else { return Spin() }
        let progress = cycleTime / spinDuration
        let eased = easeInOutQuad(progress)
        let zoom = progress < 0.75
            ? CGFloat(easeInOutQuad(progress / 0.75))
            : CGFloat(1 - easeInOutQuad((progress - 0.75) / 0.25))
        return Spin(orbitRadians: 2 * .pi * eased, cardDegrees: 360 * eased, zoomOut: zoom)
    }

    private static func easeInOutQuad(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }

    /// Times within the minute-long cycle at which the spin is sampled: densely through the
    /// spin, then once at the end (nothing moves for the rest of the minute).
    private static let cycleSampleTimes: [Double] = {
        let samples = 120
        return (0 ... samples).map { spinDuration * Double($0) / Double(samples) } + [spinCycle]
    }()

    // MARK: - Layers

    private func install(_ photos: [ScreenSaverPhotoEntry], size: CGSize, elapsedAtInstall: Double) {
        let width = size.width
        let height = size.height
        let space = LayerSpace(height: height)
        let center = CGPoint(x: width / 2, y: height / 2)
        let streamHeight = height * 2.25
        let baseStartY = -height * 0.9
        let lowerY = baseStartY - streamHeight
        let upperY = height * 1.2
        let wrapSpan = max(1, upperY - lowerY)
        let keyTimes = Self.cycleSampleTimes.map { NSNumber(value: $0 / Self.spinCycle) }
        let spins = Self.cycleSampleTimes.map { Self.spin(atCycleTime: $0) }
        // Spins start a minute in; the animations below run in "cycle time" from that point.
        let firstSpinIn = Self.spinCycle - elapsedAtInstall
        let motionStartsIn = max(0, Self.initialEmptyDuration - elapsedAtInstall)
        let motionElapsed = max(0, elapsedAtInstall - Self.initialEmptyDuration)

        withoutLayerActions {
            sceneLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            sceneLayer.removeAllAnimations()
            sceneLayer.bounds = CGRect(origin: .zero, size: size)
            sceneLayer.position = space.point(center)
        }
        sceneLayer.add(
            cycleAnimation("transform", spins.map { spin in
                let scale = 1 - 0.08 * spin.zoomOut
                return NSValue(caTransform3D: CATransform3DMakeScale(scale, scale, 1))
            }, keyTimes, startsIn: firstSpinIn),
            forKey: "zoom",
        )

        for photo in photos {
            guard let image = LayerImageCache.cgImage(for: photo.image) else { continue }
            let worldX = (photo.normalizedX - 0.5) * width * 1.25
            let worldZ = (photo.normalizedZ - 0.5) * 620
            func perspective(orbit: Double) -> CGFloat {
                let rotatedZ = worldZ * CGFloat(cos(orbit)) - worldX * CGFloat(sin(orbit))
                return Self.cameraDistance / max(180, Self.cameraDistance - rotatedZ)
            }
            func rotatedX(orbit: Double) -> CGFloat {
                worldX * CGFloat(cos(orbit)) + worldZ * CGFloat(sin(orbit))
            }
            let restingPerspective = perspective(orbit: 0)
            // Size at rest, with the same minimum and screen-size limits as before; the holder's
            // perspective scale grows or shrinks it from there during a spin.
            var restingWidth = max(70, photo.imageSize.width * 0.34 * restingPerspective * photo.sizeMultiplier)
            var restingHeight = max(70, photo.imageSize.height * 0.34 * restingPerspective * photo.sizeMultiplier)
            let clamp = min(1, width * 0.9 / restingWidth, height * 0.95 / restingHeight)
            restingWidth *= clamp
            restingHeight *= clamp
            let cardSize = CGSize(width: restingWidth / restingPerspective, height: restingHeight / restingPerspective)

            // The holder scales its card by the perspective about the screen centre; it has no 3D
            // transform of its own, so cards are painted in order rather than depth-tested.
            let holder = StillLayer()
            let card = StillLayer()
            withoutLayerActions {
                holder.bounds = CGRect(origin: .zero, size: size)
                holder.position = space.point(center)
                holder.transform = CATransform3DMakeScale(restingPerspective, restingPerspective, 1)
                card.bounds = CGRect(origin: .zero, size: cardSize)
                card.contents = image
                card.contentsGravity = .resize
                card.isDoubleSided = true
                card.shadowColor = CGColor(gray: 0, alpha: 1)
                card.shadowOpacity = 0.55
                card.shadowRadius = min(26, max(8, restingWidth * 0.03)) / restingPerspective
                let shadowDrop = min(16, max(4, restingHeight * 0.025)) / restingPerspective
                #if os(macOS)
                    card.shadowOffset = CGSize(width: 0, height: -shadowDrop)
                #else
                    card.shadowOffset = CGSize(width: 0, height: shadowDrop)
                #endif
                card.shadowPath = CGPath(rect: card.bounds, transform: nil)
            }
            holder.addSublayer(card)
            sceneLayer.addSublayer(holder)

            // Rising: world y climbs steadily from lowerY to upperY, then wraps.
            let baseY = baseStartY - photo.normalizedY * streamHeight
            let startWorldY = lowerY + positiveModulo(baseY - lowerY, wrapSpan)
            let currentWorldY = lowerY + positiveModulo(baseY + photo.riseSpeed * CGFloat(motionElapsed) - lowerY, wrapSpan)
            let wrapDuration = Double(wrapSpan / photo.riseSpeed)
            let restingX = space.point(CGPoint(x: center.x + rotatedX(orbit: 0), y: center.y)).x
            let yAtLower = space.point(CGPoint(x: 0, y: center.y - lowerY)).y
            let yAtUpper = space.point(CGPoint(x: 0, y: center.y - upperY)).y
            withoutLayerActions {
                card.position = CGPoint(x: restingX, y: space.point(CGPoint(x: 0, y: center.y - currentWorldY)).y)
            }
            let rise = CABasicAnimation(keyPath: "position.y")
            rise.fromValue = yAtLower
            rise.toValue = yAtUpper
            rise.duration = wrapDuration
            rise.repeatCount = .infinity
            rise.timeOffset = Double((currentWorldY - lowerY) / photo.riseSpeed)
            rise.beginTime = motionStartsIn > 0 ? card.convertTime(CACurrentMediaTime(), from: nil) + motionStartsIn : 0
            rise.fillMode = .backwards
            card.add(rise, forKey: "rise")

            // The spin: perspective scale on the holder, sideways swing and card turn on the card.
            holder.add(cycleAnimation("transform", spins.map { spin in
                let scale = perspective(orbit: spin.orbitRadians)
                return NSValue(caTransform3D: CATransform3DMakeScale(scale, scale, 1))
            }, keyTimes, startsIn: firstSpinIn), forKey: "spin")
            card.add(cycleAnimation("position.x", spins.map { spin in
                NSNumber(value: Double(space.point(CGPoint(x: center.x + rotatedX(orbit: spin.orbitRadians), y: 0)).x))
            }, keyTimes, startsIn: firstSpinIn), forKey: "swing")
            card.add(cycleAnimation("transform", spins.map { spin in
                NSValue(caTransform3D: CATransform3DMakeRotation(CGFloat(spin.cardDegrees * .pi / 180), 0, 1, 0))
            }, keyTimes, startsIn: firstSpinIn), forKey: "turn")

            // Startup: an empty screen for three seconds, and photos that start out on screen
            // stay hidden until they first come round from below (no popping in mid-screen).
            let initialProjectedY = center.y - startWorldY * restingPerspective
            let revealAt: Double
            if initialProjectedY >= height {
                revealAt = Self.initialEmptyDuration
            } else {
                revealAt = Self.initialEmptyDuration + Double((upperY - startWorldY) / photo.riseSpeed)
            }
            let revealIn = revealAt - elapsedAtInstall
            if revealIn > 0 {
                let reveal = CAKeyframeAnimation(keyPath: "opacity")
                reveal.values = [0, 1]
                reveal.keyTimes = [0, 1]
                reveal.calculationMode = .discrete
                reveal.duration = revealIn
                reveal.beginTime = 0
                reveal.isRemovedOnCompletion = true
                card.add(reveal, forKey: "reveal")
            }
        }
    }

    /// A keyframe animation over the minute-long spin cycle, repeating forever, whose first
    /// spin is `startsIn` seconds away (or already under way when negative).
    private func cycleAnimation(_ keyPath: String, _ values: [Any], _ keyTimes: [NSNumber], startsIn: Double) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.calculationMode = .linear
        animation.duration = Self.spinCycle
        animation.repeatCount = .infinity
        if startsIn > 0 {
            animation.beginTime = rootLayer.convertTime(CACurrentMediaTime(), from: nil) + startsIn
        } else {
            animation.beginTime = 0
            animation.timeOffset = positiveModulo(CGFloat(-startsIn), CGFloat(Self.spinCycle)).doubleValue
        }
        return animation
    }

    private func positiveModulo(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder < 0 ? remainder + modulus : remainder
    }
}

private extension CGFloat {
    var doubleValue: Double { Double(self) }
}

struct ScreenSaverPhotoEntry: Identifiable {
    let id: Int
    let image: NSImage
    let imageSize: CGSize
    let sizeMultiplier: CGFloat
    let normalizedX: CGFloat
    let normalizedY: CGFloat
    let normalizedZ: CGFloat
    let riseSpeed: CGFloat
}

/// The screen saver's photos: the bundled set, each placed twice or more in the stream.
@MainActor
enum ScreenSaverPhotoStream {
    private static var cached: [ScreenSaverPhotoEntry]?

    static func photos() -> [ScreenSaverPhotoEntry] {
        if let cached { return cached }
        let made = makePhotos()
        cached = made
        return made
    }

    private static func makePhotos() -> [ScreenSaverPhotoEntry] {
        let imageURLs = loadScreenSaverImageURLs()
        let loadedImages = imageURLs.compactMap { url -> NSImage? in
            guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
                return nil
            }
            return image
        }
        guard !loadedImages.isEmpty else {
            return []
        }
        var rng = SystemRandomNumberGenerator()

        let total = max(loadedImages.count * 2, 48)
        let bandCount = 2
        let slotsPerBand = max(1, total / bandCount)

        let halfWrapOffsetInStreamUnits: CGFloat = 0.9666666667
        return (0 ..< total).map { index in
            let image = loadedImages[index % loadedImages.count]
            let band = index % bandCount
            let slot = index / bandCount

            let laneProgress = (CGFloat(slot) + 0.5) / CGFloat(slotsPerBand)
            let laneJitter = CGFloat.random(in: -0.02 ... 0.02, using: &rng) / CGFloat(slotsPerBand)
            let verticalPhase = laneProgress + laneJitter + (CGFloat(band) * halfWrapOffsetInStreamUnits)

            let xPhase = fractional(CGFloat(index) * 0.61803398875 + 0.17)
            let zPhase = fractional(CGFloat(index) * 0.75487766625 + 0.41)
            let isHero = index % 11 == 0
            return ScreenSaverPhotoEntry(
                id: index,
                image: image,
                imageSize: image.size,
                sizeMultiplier: isHero
                    ? CGFloat.random(in: 2.0 ... 2.9, using: &rng)
                    : CGFloat.random(in: 1.2 ... 1.9, using: &rng),
                normalizedX: 0.06 + (xPhase * 0.88),
                normalizedY: verticalPhase,
                normalizedZ: isHero
                    ? (0.72 + (zPhase * 0.26))
                    : (0.24 + (zPhase * 0.68)),

                riseSpeed: 62,
            )
        }
    }

    private static func fractional(_ value: CGFloat) -> CGFloat {
        value - floor(value)
    }

    private static func loadScreenSaverImageURLs() -> [URL] {
        let fileManager = FileManager.default
        let fullImageExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp"])
        let fallbackRootExtensions = Set(["jpg", "jpeg", "heic", "heif"])
        func images(in directory: URL?, extensions: Set<String>) -> [URL] {
            guard let directory else { return [] }
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
            ) else {
                return []
            }
            return urls.filter { url in
                extensions.contains(url.pathExtension.lowercased())
            }
        }
        var urls: [URL] = []
        if let bundledFolder = Bundle.main.resourceURL?.appendingPathComponent("ScreenSaverDefaultPhotos", isDirectory: true) {
            urls.append(contentsOf: images(in: bundledFolder, extensions: fullImageExtensions))
        }
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let localFolders = [
            currentDirectory.appendingPathComponent("ScreenSaverDefaultPhotos", isDirectory: true),
            currentDirectory.appendingPathComponent("firstRow/ScreenSaverDefaultPhotos", isDirectory: true),
        ]
        for folder in localFolders {
            urls.append(contentsOf: images(in: folder, extensions: fullImageExtensions))
        }
        if urls.isEmpty {
            urls.append(contentsOf: images(in: Bundle.main.resourceURL, extensions: fallbackRootExtensions))
        }
        var seen: Set<String> = []
        let deduped = urls.filter { url in
            let key = url.standardizedFileURL.path
            if seen.contains(key) {
                return false
            }
            seen.insert(key)
            return true
        }
        return deduped.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}
