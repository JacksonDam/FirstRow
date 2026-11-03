import QuartzCore
#if os(macOS)
    import AppKit
#else
    import UIKit
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

/// A layer whose property changes never animate implicitly.
class StillLayer: CALayer {
    override func action(forKey _: String) -> CAAction? { nil }
}

final class StillGradientLayer: CAGradientLayer {
    override func action(forKey _: String) -> CAAction? { nil }
}

/// BGRA premultiplied: Core Animation shows this layout without making a converted copy.
let layerBitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

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
        if let cached = cache.object(forKey: image) {
            return cached.image
        }
        #if os(macOS)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
            guard let cgImage = image.cgImage ?? renderedCGImage(image) else { return nil }
        #endif
        cache.setObject(CGImageBox(cgImage), forKey: image, cost: cgImage.bytesPerRow * cgImage.height)
        return cgImage
    }

    #if !os(macOS)
        private static func renderedCGImage(_ image: UIImage) -> CGImage? {
            let renderer = UIGraphicsImageRenderer(size: image.size)
            return renderer.image { _ in image.draw(at: .zero) }.cgImage
        }
    #endif
}

/// Perspective for a view of the given size, with depth set by its larger side.
func swiftUIPerspectiveTransform(perspective: CGFloat, viewSize: CGSize) -> CATransform3D {
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
    return CATransform3DConcat(rotation, swiftUIPerspectiveTransform(perspective: perspective, viewSize: viewSize))
}

extension NSValue {
    static func layerPoint(_ point: CGPoint) -> NSValue {
        #if os(macOS)
            NSValue(point: point)
        #else
            NSValue(cgPoint: point)
        #endif
    }

    var layerPointValue: CGPoint {
        #if os(macOS)
            pointValue
        #else
            cgPointValue
        #endif
    }

    var layerRectValue: CGRect {
        #if os(macOS)
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
        #if os(macOS)
            CGPoint(x: point.x, y: height - point.y)
        #else
            point
        #endif
    }

    /// A top-left-origin frame, for a layer whose superlayer has `height`.
    func rect(_ rect: CGRect) -> CGRect {
        #if os(macOS)
            CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        #else
            rect
        #endif
    }
}
