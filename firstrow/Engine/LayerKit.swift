import QuartzCore
import SwiftUI
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

// Core Animation building blocks shared by First Row's layer-based views.
//
// Animated parts of the interface are drawn with CALayers and CAAnimations instead of
// SwiftUI views redrawn every frame: the system render server runs the animations, so
// the app itself does almost no work while they play.

/// Hosts a layer tree in a view. Layer geometry is the platform's own: origin top left on
/// iOS and tvOS, bottom left on macOS (a flipped layer geometry would draw every image upside
/// down and confuse depth sorting). Controllers lay out in SwiftUI's top-left coordinates and
/// convert with `LayerSpace`.
final class FlippedLayerView: PlatformView {
    /// Called whenever the view's size settles, so the layer tree can follow it.
    var onLayout: ((CGSize) -> Void)?
    private var lastLaidOutSize: CGSize?
    /// The layer tree drawn in this view. AppKit can replace a view's backing layer (for example
    /// when it moves into a window), so the tree is re-attached whenever that happens.
    var contentLayer: CALayer? {
        didSet {
            if oldValue !== contentLayer {
                oldValue?.removeFromSuperlayer()
            }
            attachContentLayerIfNeeded()
        }
    }

    private func attachContentLayerIfNeeded() {
        #if os(macOS)
            guard let host = layer else { return }
        #else
            let host = layer
        #endif
        guard let contentLayer, contentLayer.superlayer !== host else { return }
        host.addSublayer(contentLayer)
    }

    #if os(macOS)
        // AppKit can hand the view a new backing layer at any time; follow it every time.
        override var layer: CALayer? {
            didSet { attachContentLayerIfNeeded() }
        }

        override func layout() {
            super.layout()
            notifyLayoutIfNeeded()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            notifyLayoutIfNeeded()
        }

        init() {
            super.init(frame: .zero)
            // Layer-backed (AppKit owns the view's layer); our layer tree is a sublayer of it.
            wantsLayer = true
            layer?.masksToBounds = false
            layerContentsRedrawPolicy = .never
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachContentLayerIfNeeded()
        }

        override func hitTest(_: NSPoint) -> NSView? { nil }
    #else
        override func layoutSubviews() {
            super.layoutSubviews()
            notifyLayoutIfNeeded()
        }

        init() {
            super.init(frame: .zero)
            clipsToBounds = false
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
    #endif

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private func notifyLayoutIfNeeded() {
        attachContentLayerIfNeeded()
        let size = bounds.size
        guard size != lastLaidOutSize else { return }
        lastLaidOutSize = size
        onLayout?(size)
    }

    var hostLayer: CALayer {
        #if os(macOS)
            return layer!
        #else
            return layer
        #endif
    }
}

#if os(macOS)
    typealias PlatformView = NSView
#else
    typealias PlatformView = UIView
#endif

/// Something that owns a layer tree drawn inside a SwiftUI view.
@MainActor
protocol LayerController: AnyObject {
    associatedtype Configuration
    init()
    var rootLayer: CALayer { get }
    /// Called whenever SwiftUI updates the view; `bounds` is the view's size.
    func update(_ configuration: Configuration, bounds: CGSize)
    /// Called when SwiftUI removes the view.
    func tearDown()
}

extension LayerController {
    func tearDown() {}
}

/// Hosts a `LayerController` inside SwiftUI.
struct LayerHost<Controller: LayerController>: View {
    let configuration: Controller.Configuration

    var body: some View {
        LayerHostRepresentable<Controller>(configuration: configuration)
    }
}

#if os(macOS)
    private struct LayerHostRepresentable<Controller: LayerController>: NSViewRepresentable {
        let configuration: Controller.Configuration

        func makeCoordinator() -> Controller { Controller() }

        func makeNSView(context: Context) -> FlippedLayerView {
            let view = FlippedLayerView()
            view.contentLayer = context.coordinator.rootLayer
            return view
        }

        func updateNSView(_ view: FlippedLayerView, context: Context) {
            let controller = context.coordinator
            let configuration = configuration
            view.onLayout = { [weak controller] size in
                guard let controller else { return }
                withoutLayerActions {
                    controller.rootLayer.frame = CGRect(origin: .zero, size: size)
                }
                controller.update(configuration, bounds: size)
            }
            view.contentLayer = controller.rootLayer
            withoutLayerActions {
                controller.rootLayer.frame = view.bounds
            }
            controller.update(configuration, bounds: view.bounds.size)
        }

        static func dismantleNSView(_: FlippedLayerView, coordinator: Controller) {
            coordinator.tearDown()
        }
    }
#else
    private struct LayerHostRepresentable<Controller: LayerController>: UIViewRepresentable {
        let configuration: Controller.Configuration

        func makeCoordinator() -> Controller { Controller() }

        func makeUIView(context: Context) -> FlippedLayerView {
            let view = FlippedLayerView()
            view.contentLayer = context.coordinator.rootLayer
            return view
        }

        func updateUIView(_ view: FlippedLayerView, context: Context) {
            let controller = context.coordinator
            let configuration = configuration
            view.onLayout = { [weak controller] size in
                guard let controller else { return }
                withoutLayerActions {
                    controller.rootLayer.frame = CGRect(origin: .zero, size: size)
                }
                controller.update(configuration, bounds: size)
            }
            view.contentLayer = controller.rootLayer
            withoutLayerActions {
                controller.rootLayer.frame = view.bounds
            }
            controller.update(configuration, bounds: view.bounds.size)
        }

        static func dismantleUIView(_: FlippedLayerView, coordinator: Controller) {
            coordinator.tearDown()
        }
    }
#endif

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

/// Bitmap for a platform image, cached per image object.
@MainActor
enum LayerImageCache {
    private static let cache: NSCache<AnyObject, CGImageBox> = {
        let cache = NSCache<AnyObject, CGImageBox>()
        cache.countLimit = 400
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
        cache.setObject(CGImageBox(cgImage), forKey: image)
        return cgImage
    }

    #if !os(macOS)
        private static func renderedCGImage(_ image: UIImage) -> CGImage? {
            let renderer = UIGraphicsImageRenderer(size: image.size)
            return renderer.image { _ in image.draw(at: .zero) }.cgImage
        }
    #endif
}

/// Perspective used by SwiftUI's `rotation3DEffect` for a view of the given size.
func swiftUIPerspectiveTransform(perspective: CGFloat, viewSize: CGSize) -> CATransform3D {
    var transform = CATransform3DIdentity
    let depth = max(viewSize.width, viewSize.height)
    if depth > 0, perspective != 0 {
        transform.m34 = -perspective / depth
    }
    return transform
}

/// A rotation about the vertical axis, with SwiftUI's perspective, about the layer's anchor.
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
}

/// Converts SwiftUI-style coordinates (origin top left, y down) to layer coordinates.
struct LayerSpace {
    let height: CGFloat

    func point(_ point: CGPoint) -> CGPoint {
        #if os(macOS)
            CGPoint(x: point.x, y: height - point.y)
        #else
            point
        #endif
    }

    /// A frame given in SwiftUI coordinates, for a layer whose superlayer has `height`.
    func rect(_ rect: CGRect) -> CGRect {
        #if os(macOS)
            CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        #else
            rect
        #endif
    }
}
