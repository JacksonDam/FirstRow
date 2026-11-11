import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

// Core Animation building blocks shared by First Row's layer-based views.

/// Something that owns a layer tree drawn inside the scene.
@MainActor
protocol LayerController: AnyObject {
    associatedtype Configuration
    init()
    var rootLayer: CALayer { get }
    /// Called when what it shows or its size changes.
    func update(_ configuration: Configuration, bounds: CGSize)
    /// Called when it leaves the screen.
    func tearDown()
}

extension LayerController {
    func tearDown() {}
}

/// Runs `body` with Core Animation's implicit animations turned off.
func withoutLayerActions(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

/// A layer whose property changes never animate implicitly (but takes part in a `LayoutGlide`).
class StillLayer: CALayer {
    override func action(forKey key: String) -> CAAction? { LayoutGlide.action(for: self, key: key) }
}

final class StillGradientLayer: CAGradientLayer {
    override func action(forKey key: String) -> CAAction? { LayoutGlide.action(for: self, key: key) }
}

/// BGRA premultiplied: Core Animation shows this layout without making a converted copy.
let layerBitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

/// The colour space of the screen First Row's window is on, for the pictures it makes itself.
///
/// On the Mac, Core Animation converts every picture it's handed to the colour space of the
/// window's screen as it commits, which is on the main thread, unless the picture is in that
/// space already: about 2.7 ms for each million pixels on a screen with a colour profile of
/// its own (a new cover and its reflection came to 4 ms, a list's lettering to several more).
/// A picture drawn in the screen's space to begin with is taken as it is, and where it's
/// drawn off the main thread, that's where its colours are converted too. A picture made for
/// one screen and shown on another is converted as before, so it looks the same either way.
enum ScreenColorSpace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var screenSpace: CGColorSpace?

    /// The screen's colour space, or nil where there's none to draw in (not a Mac, or no
    /// window yet): pictures are then drawn in the space they always were.
    static var current: CGColorSpace? {
        lock.lock()
        defer { lock.unlock() }
        return screenSpace
    }

    #if os(macOS)
        private static var observers: [NSObjectProtocol] = []
        private static weak var followed: NSWindow?

        /// Keeps to the screen `window` is on, as it moves between screens or the screen's
        /// profile changes.
        @MainActor
        static func follow(_ window: NSWindow?) {
            if let window, window !== followed {
                followed = window
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = [NSWindow.didChangeScreenNotification, NSWindow.didChangeScreenProfileNotification].map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                        MainActor.assumeIsolatedIfPossible { follow(followed) }
                    }
                }
            }
            var space = (window?.screen ?? NSScreen.main)?.colorSpace?.cgColorSpace
            // Only a space a bitmap of ours can be made in.
            if let candidate = space,
               candidate.model != .rgb || CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: candidate, bitmapInfo: layerBitmapInfo) == nil
            {
                space = nil
            }
            lock.lock()
            screenSpace = space
            lock.unlock()
        }
    #endif
}

/// What tells one picture from another in a cache's key.
struct PictureIdentity: Hashable {
    #if FIRSTROW_PORTABLE
        // Every picture there has a number that no other is ever given. A key that held the
        // picture would keep its pixels, and the texture made of them, for as long as the
        // cache remembered what was made from it.
        private let number: Int

        init(_ picture: CGImage) {
            number = picture.identifier
        }
    #else
        // The picture itself, kept: a new one at a freed one's address would match otherwise.
        private let picture: CGImage

        init(_ picture: CGImage) {
            self.picture = picture
        }

        static func == (a: PictureIdentity, b: PictureIdentity) -> Bool {
            a.picture === b.picture
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(picture))
        }
    #endif
}

/// CGImage per platform image, cached because converting can mean rasterising a PDF icon.
@MainActor
enum LayerImageCache {
    private static let cache: NSCache<AnyObject, CGImageBox> = {
        let cache = NSCache<AnyObject, CGImageBox>()
        cache.countLimit = 300
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    static func cgImage(for image: NSImage?) -> CGImage? {
        guard let image else { return nil }
        #if FIRSTROW_PORTABLE
            // There a picture keeps its own unpacked copy for as long as it's asked for, and
            // one kept here as well would never be let go: its pixels and a texture as large.
            return platformCGImage(image)
        #else
            if let cached = cache.object(forKey: image) {
                return cached.image
            }
            guard let cgImage = platformCGImage(image) else { return nil }
            cache.setObject(CGImageBox(cgImage), forKey: image, cost: cgImage.bytesPerRow * cgImage.height)
            return cgImage
        #endif
    }

    private static func platformCGImage(_ image: NSImage) -> CGImage? {
        #if os(macOS) || FIRSTROW_PORTABLE
            image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
            image.cgImage ?? renderedCGImage(image)
        #endif
    }

    /// Unpacks pictures from the asset catalogue on another thread, ahead of their first
    /// showing. They're kept compressed there, and Core Animation unpacks one on the main
    /// thread as it commits the first layer to show it: 3 to 5 ms for a 600-pixel stand-in
    /// cover, in the first frame of the screen it's on. The unpacked copy (in the screen's
    /// colours) takes the picture's place here, so layers are given that. One already asked
    /// for is left alone: it's on a layer, unpacked.
    static func unpackAhead(named names: [String]) {
        #if !FIRSTROW_PORTABLE
            let pictures: [(picture: NSImage, packed: CGImage)] = names.compactMap { name in
                guard let picture = NSImage(named: name), cache.object(forKey: picture) == nil, let packed = platformCGImage(picture) else { return nil }
                return (picture, packed)
            }
            guard !pictures.isEmpty else { return }
            DispatchQueue.global(qos: .utility).async {
                for entry in pictures {
                    let unpacked = decompressedArtworkCGImage(from: entry.packed)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolatedIfPossible {
                            guard cache.object(forKey: entry.picture) == nil else { return }
                            cache.setObject(CGImageBox(unpacked), forKey: entry.picture, cost: unpacked.bytesPerRow * unpacked.height)
                        }
                    }
                }
            }
        #endif
    }

    #if canImport(UIKit)
        private static func renderedCGImage(_ image: UIImage) -> CGImage? {
            let renderer = UIGraphicsImageRenderer(size: image.size)
            return renderer.image { _ in image.draw(at: .zero) }.cgImage
        }
    #endif
}

/// Perspective for a view of the given size, with depth set by its larger side.
func depthPerspectiveTransform(perspective: CGFloat, viewSize: CGSize) -> CATransform3D {
    var transform = CATransform3DIdentity
    let depth = max(viewSize.width, viewSize.height)
    if depth > 0, perspective != 0 {
        transform.m34 = -perspective / depth
    }
    return transform
}

/// A rotation about the vertical axis through the layer's anchor, with perspective.
func yawTransform(degrees: Double, perspective: CGFloat, viewSize: CGSize) -> CATransform3D {
    let rotation = CATransform3DMakeRotation(CGFloat(degrees * .pi / 180), 0, 1, 0)
    return CATransform3DConcat(rotation, depthPerspectiveTransform(perspective: perspective, viewSize: viewSize))
}

/// Where a rectangle of `size` centred on `center` shows once `transform` has turned it about its middle.
func turnedOutline(center: CGPoint, size: CGSize, transform: CATransform3D) -> CGRect {
    var low = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
    var high = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
    let corners: [(CGFloat, CGFloat)] = [(-0.5, -0.5), (0.5, -0.5), (-0.5, 0.5), (0.5, 0.5)]
    for (acrossShare, downShare) in corners {
        let x = size.width * acrossShare
        let y = size.height * downShare
        let depth = x * transform.m14 + y * transform.m24 + transform.m44
        guard depth > 0.0001 else { continue }
        let shownX = (x * transform.m11 + y * transform.m21 + transform.m41) / depth
        let shownY = (x * transform.m12 + y * transform.m22 + transform.m42) / depth
        low = CGPoint(x: min(low.x, shownX), y: min(low.y, shownY))
        high = CGPoint(x: max(high.x, shownX), y: max(high.y, shownY))
    }
    guard low.x <= high.x, low.y <= high.y else {
        return CGRect(x: center.x - size.width * 0.5, y: center.y - size.height * 0.5, width: size.width, height: size.height)
    }
    return CGRect(x: center.x + low.x, y: center.y + low.y, width: high.x - low.x, height: high.y - low.y)
}

extension NSValue {
    static func layerPoint(_ point: CGPoint) -> NSValue {
        #if os(macOS) || FIRSTROW_PORTABLE
            NSValue(point: point)
        #else
            NSValue(cgPoint: point)
        #endif
    }

    var layerPointValue: CGPoint {
        #if os(macOS) || FIRSTROW_PORTABLE
            pointValue
        #else
            cgPointValue
        #endif
    }

    var layerRectValue: CGRect {
        #if os(macOS) || FIRSTROW_PORTABLE
            rectValue
        #else
            cgRectValue
        #endif
    }
}

/// Converts top-left-origin, y-down coordinates to layer coordinates.
struct LayerSpace {
    let height: CGFloat

    func point(_ point: CGPoint) -> CGPoint {
        #if os(macOS) || FIRSTROW_PORTABLE
            CGPoint(x: point.x, y: height - point.y)
        #else
            point
        #endif
    }

    /// A top-left-origin frame, for a layer whose superlayer has `height`.
    func rect(_ rect: CGRect) -> CGRect {
        #if os(macOS) || FIRSTROW_PORTABLE
            CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        #else
            rect
        #endif
    }
}
