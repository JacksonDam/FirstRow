import CPortable
import Foundation

public enum CGBlendMode: Int32, Sendable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight
    case difference, exclusion, hue, saturation, color, luminosity
    case clear, copy, sourceIn, sourceOut, sourceAtop, destinationOver, destinationIn, destinationOut, destinationAtop, xor
    case plusDarker, plusLighter

    var plutovgOperator: plutovg_operator_t {
        switch self {
        case .clear: PLUTOVG_OPERATOR_CLEAR
        case .copy: PLUTOVG_OPERATOR_SRC
        case .sourceIn: PLUTOVG_OPERATOR_SRC_IN
        case .sourceOut: PLUTOVG_OPERATOR_SRC_OUT
        case .sourceAtop: PLUTOVG_OPERATOR_SRC_ATOP
        case .destinationOver: PLUTOVG_OPERATOR_DST_OVER
        case .destinationIn: PLUTOVG_OPERATOR_DST_IN
        case .destinationOut: PLUTOVG_OPERATOR_DST_OUT
        case .destinationAtop: PLUTOVG_OPERATOR_DST_ATOP
        case .xor: PLUTOVG_OPERATOR_XOR
        default: PLUTOVG_OPERATOR_SRC_OVER
        }
    }
}

public enum CGTextDrawingMode: Int32, Sendable {
    case fill, stroke, fillStroke, invisible, fillClip, strokeClip, fillStrokeClip, clip
}

public struct CGGradientDrawingOptions: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let drawsBeforeStartLocation = CGGradientDrawingOptions(rawValue: 1)
    public static let drawsAfterEndLocation = CGGradientDrawingOptions(rawValue: 2)
}

public final class CGGradient: @unchecked Sendable {
    public struct Stop {
        public let location: CGFloat
        public let color: CGColor
    }

    public let stops: [Stop]

    public init?(colorsSpace _: CGColorSpace?, colors: CFArray, locations: [CGFloat]?) {
        let list = colors.compactMap { $0 as? CGColor }
        guard !list.isEmpty else { return nil }
        let positions = locations ?? list.indices.map { list.count > 1 ? CGFloat($0) / CGFloat(list.count - 1) : 0 }
        stops = zip(positions, list).map { Stop(location: $0, color: $1) }
    }

    public init?(colorSpace: CGColorSpace, colorComponents components: [CGFloat], locations: [CGFloat]?, count: Int) {
        let per = colorSpace.numberOfComponents + 1
        guard count > 0, components.count >= per * count else { return nil }
        var list: [CGColor] = []
        for index in 0 ..< count {
            let slice = Array(components[index * per ..< index * per + per])
            guard let color = CGColor(colorSpace: colorSpace, components: slice) else { return nil }
            list.append(color)
        }
        let positions = locations ?? (0 ..< count).map { count > 1 ? CGFloat($0) / CGFloat(count - 1) : 0 }
        stops = zip(positions, list).map { Stop(location: $0, color: $1) }
    }

    var plutovgStops: [plutovg_gradient_stop_t] {
        stops.map { stop in
            let (r, g, b, a) = stop.color.rgba
            return plutovg_gradient_stop_t(offset: Float(stop.location), color: plutovg_color_t(r: Float(r), g: Float(g), b: Float(b), a: Float(a)))
        }
    }
}

/// A plutovg surface and canvas over pixels we own.
final class DrawingTarget {
    let storage: PixelStorage
    let surface: OpaquePointer
    let canvas: OpaquePointer

    init(width: Int, height: Int, fill: UInt32 = 0) {
        storage = PixelStorage(width: width, height: height)
        if fill != 0 {
            let words = UnsafeMutableRawPointer(storage.bytes).bindMemory(to: UInt32.self, capacity: width * height)
            words.update(repeating: fill, count: width * height)
        }
        surface = plutovg_surface_create_for_data(storage.bytes, Int32(width), Int32(height), Int32(storage.bytesPerRow))
        canvas = plutovg_canvas_create(surface)
    }

    deinit {
        plutovg_canvas_destroy(canvas)
        plutovg_surface_destroy(surface)
    }
}

/// A bitmap drawing context: user space has y up, the pixels have their top row first.
public final class CGContext {
    struct Shadow {
        var offset: CGSize
        var blur: CGFloat
        var color: CGColor
    }

    struct GState {
        var ctm: CGAffineTransform
        var fill = CGColor(gray: 0, alpha: 1)
        var stroke = CGColor(gray: 0, alpha: 1)
        var lineWidth: CGFloat = 1
        var lineCap: CGLineCap = .butt
        var lineJoin: CGLineJoin = .miter
        var miterLimit: CGFloat = 10
        var dash: (phase: CGFloat, lengths: [CGFloat]) = (0, [])
        var alpha: CGFloat = 1
        var blend: CGBlendMode = .normal
        var shadow: Shadow?
        var mask: MaskBuffer?
        var interpolation: CGInterpolationQuality = .default
    }

    final class MaskBuffer {
        let width: Int
        let height: Int
        let bytes: UnsafeMutablePointer<UInt8>

        init(width: Int, height: Int, fill: UInt8) {
            self.width = width
            self.height = height
            bytes = .allocate(capacity: max(1, width * height))
            bytes.initialize(repeating: fill, count: max(1, width * height))
        }

        func copy() -> MaskBuffer {
            let copy = MaskBuffer(width: width, height: height, fill: 0)
            copy.bytes.update(from: bytes, count: width * height)
            return copy
        }

        deinit { bytes.deallocate() }
    }

    struct Layer {
        let target: DrawingTarget
        let outerState: GState
    }

    public let width: Int
    public let height: Int
    public let colorSpace: CGColorSpace?
    public let bitmapInfo: CGBitmapInfo
    public let alphaInfo: CGImageAlphaInfo
    public let bitsPerComponent = 8
    public let bitsPerPixel = 32
    let isGray: Bool
    let isOpaque: Bool
    let base: DrawingTarget
    var layers: [Layer] = []
    var state: GState
    var stack: [GState] = []
    /// The current path, already in device (pixel) space.
    var path: [PathElement] = []

    public var textPosition: CGPoint = .zero
    public var textMatrix: CGAffineTransform = .identity
    public var textDrawingMode: CGTextDrawingMode = .fill
    public var interpolationQuality: CGInterpolationQuality {
        get { state.interpolation }
        set { state.interpolation = newValue }
    }

    public init?(data: UnsafeMutableRawPointer?, width: Int, height: Int, bitsPerComponent: Int, bytesPerRow: Int, space: CGColorSpace, bitmapInfo: UInt32) {
        guard width > 0, height > 0, data == nil, bitsPerComponent == 8 else { return nil }
        _ = bytesPerRow
        self.width = width
        self.height = height
        colorSpace = space
        self.bitmapInfo = CGBitmapInfo(rawValue: bitmapInfo)
        let info = CGImageAlphaInfo(rawValue: bitmapInfo & CGBitmapInfo.alphaInfoMask.rawValue) ?? .premultipliedFirst
        alphaInfo = info
        isGray = space.model == .monochrome
        isOpaque = info == .none || info == .noneSkipFirst || info == .noneSkipLast
        // Opaque bitmaps start out black, transparent ones clear.
        base = DrawingTarget(width: width, height: height, fill: isOpaque ? 0xFF00_0000 : 0)
        state = GState(ctm: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
    }

    var target: DrawingTarget { layers.last?.target ?? base }
    public var bytesPerRow: Int { base.storage.bytesPerRow }
    public var ctm: CGAffineTransform { state.ctm.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))) }
    public var userSpaceToDeviceSpaceTransform: CGAffineTransform { state.ctm }

    // MARK: State

    public func saveGState() {
        stack.append(state)
        plutovg_canvas_save(target.canvas)
    }

    public func restoreGState() {
        guard let last = stack.popLast() else { return }
        state = last
        plutovg_canvas_restore(target.canvas)
    }

    public func scaleBy(x: CGFloat, y: CGFloat) { state.ctm = CGAffineTransform(scaleX: x, y: y).concatenating(state.ctm) }
    public func translateBy(x: CGFloat, y: CGFloat) { state.ctm = CGAffineTransform(translationX: x, y: y).concatenating(state.ctm) }
    public func rotate(by angle: CGFloat) { state.ctm = CGAffineTransform(rotationAngle: angle).concatenating(state.ctm) }
    public func concatenate(_ transform: CGAffineTransform) { state.ctm = transform.concatenating(state.ctm) }

    public func setFillColor(_ color: CGColor) { state.fill = color }
    public func setFillColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { state.fill = CGColor(red: red, green: green, blue: blue, alpha: alpha) }
    public func setFillColor(gray: CGFloat, alpha: CGFloat) { state.fill = CGColor(gray: gray, alpha: alpha) }
    public func setStrokeColor(_ color: CGColor) { state.stroke = color }
    public func setStrokeColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { state.stroke = CGColor(red: red, green: green, blue: blue, alpha: alpha) }
    public func setStrokeColor(gray: CGFloat, alpha: CGFloat) { state.stroke = CGColor(gray: gray, alpha: alpha) }
    public func setLineWidth(_ width: CGFloat) { state.lineWidth = width }
    public func setLineCap(_ cap: CGLineCap) { state.lineCap = cap }
    public func setLineJoin(_ join: CGLineJoin) { state.lineJoin = join }
    public func setMiterLimit(_ limit: CGFloat) { state.miterLimit = limit }
    public func setLineDash(phase: CGFloat, lengths: [CGFloat]) { state.dash = (phase, lengths) }
    public func setAlpha(_ alpha: CGFloat) { state.alpha = max(0, min(1, alpha)) }
    public func setBlendMode(_ mode: CGBlendMode) { state.blend = mode }

    public func setShadow(offset: CGSize, blur: CGFloat, color: CGColor?) {
        if let color, color.alpha > 0 {
            state.shadow = Shadow(offset: offset, blur: blur, color: color)
        } else {
            state.shadow = nil
        }
    }

    public func setShadow(offset: CGSize, blur: CGFloat) {
        setShadow(offset: offset, blur: blur, color: CGColor(gray: 0, alpha: 1.0 / 3.0))
    }

    // Text and edge smoothing flags: drawing is always antialiased and never subpixel-smoothed.
    public func setShouldAntialias(_: Bool) {}
    public func setAllowsAntialiasing(_: Bool) {}
    public func setShouldSmoothFonts(_: Bool) {}
    public func setAllowsFontSmoothing(_: Bool) {}
    public func setShouldSubpixelPositionFonts(_: Bool) {}
    public func setAllowsFontSubpixelPositioning(_: Bool) {}
    public func setShouldSubpixelQuantizeFonts(_: Bool) {}
    public func setAllowsFontSubpixelQuantization(_: Bool) {}
    public func setTextDrawingMode(_ mode: CGTextDrawingMode) { textDrawingMode = mode }
    public func setFlatness(_: CGFloat) {}
    public func flush() {}

    // MARK: Paths

    private var hasCurrentPoint: Bool {
        guard let last = path.last else { return false }
        if case .close = last { return false }
        return true
    }

    public func beginPath() { path.removeAll() }
    public func move(to point: CGPoint) { path.append(.move(point.applying(state.ctm))) }
    public func addLine(to point: CGPoint) {
        let p = point.applying(state.ctm)
        path.append(hasCurrentPoint ? .line(p) : .move(p))
    }

    public func addLines(between points: [CGPoint]) {
        for (index, point) in points.enumerated() {
            if index == 0 { move(to: point) } else { addLine(to: point) }
        }
    }

    public func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint) {
        path.append(.cubic(control1.applying(state.ctm), control2.applying(state.ctm), end.applying(state.ctm)))
    }

    public func addQuadCurve(to end: CGPoint, control: CGPoint) {
        path.append(.quad(control.applying(state.ctm), end.applying(state.ctm)))
    }

    public func addRect(_ rect: CGRect) { ArcBuilder.rectangle(rect, transform: state.ctm, into: &path) }
    public func addRects(_ rects: [CGRect]) { for rect in rects { addRect(rect) } }
    public func addEllipse(in rect: CGRect) { ArcBuilder.ellipse(in: rect, transform: state.ctm, into: &path) }

    public func addArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool) {
        ArcBuilder.arc(center: center, radius: radius, start: startAngle, end: endAngle, clockwise: clockwise, transform: state.ctm, into: &path, hasCurrentPoint: hasCurrentPoint)
    }

    public func addPath(_ newPath: CGPath) {
        path.append(contentsOf: newPath.elements.map { $0.applying(state.ctm) })
    }

    public func closePath() { path.append(.close) }

    public var isPathEmpty: Bool { path.isEmpty }

    public var boundingBoxOfPath: CGRect {
        CGPath(elements: path).boundingBox.applying(state.ctm.inverted())
    }

    // MARK: Drawing

    public func fillPath(using rule: CGPathFillRule = .winding) {
        let elements = path
        path.removeAll()
        fill(deviceElements: elements, rule: rule, color: state.fill)
    }

    public func eoFillPath() { fillPath(using: .evenOdd) }

    public func strokePath() {
        let elements = path
        path.removeAll()
        stroke(deviceElements: elements)
    }

    public func drawPath(using mode: CGPathDrawingMode) {
        let elements = path
        path.removeAll()
        switch mode {
        case .fill: fill(deviceElements: elements, rule: .winding, color: state.fill)
        case .eoFill: fill(deviceElements: elements, rule: .evenOdd, color: state.fill)
        case .stroke: stroke(deviceElements: elements)
        case .fillStroke:
            fill(deviceElements: elements, rule: .winding, color: state.fill)
            stroke(deviceElements: elements)
        case .eoFillStroke:
            fill(deviceElements: elements, rule: .evenOdd, color: state.fill)
            stroke(deviceElements: elements)
        }
    }

    public func fill(_ rect: CGRect) {
        var elements: [PathElement] = []
        ArcBuilder.rectangle(rect, transform: state.ctm, into: &elements)
        fill(deviceElements: elements, rule: .winding, color: state.fill)
    }

    public func fill(_ rects: [CGRect]) { for rect in rects { fill(rect) } }

    public func fillEllipse(in rect: CGRect) {
        var elements: [PathElement] = []
        ArcBuilder.ellipse(in: rect, transform: state.ctm, into: &elements)
        fill(deviceElements: elements, rule: .winding, color: state.fill)
    }

    public func stroke(_ rect: CGRect) {
        var elements: [PathElement] = []
        ArcBuilder.rectangle(rect, transform: state.ctm, into: &elements)
        stroke(deviceElements: elements)
    }

    public func stroke(_ rect: CGRect, width: CGFloat) {
        let saved = state.lineWidth
        state.lineWidth = width
        stroke(rect)
        state.lineWidth = saved
    }

    public func strokeEllipse(in rect: CGRect) {
        var elements: [PathElement] = []
        ArcBuilder.ellipse(in: rect, transform: state.ctm, into: &elements)
        stroke(deviceElements: elements)
    }

    public func clear(_ rect: CGRect) {
        var elements: [PathElement] = []
        ArcBuilder.rectangle(rect, transform: state.ctm, into: &elements)
        let canvas = target.canvas
        plutovg_canvas_save(canvas)
        plutovg_canvas_reset_matrix(canvas)
        plutovg_canvas_set_operator(canvas, PLUTOVG_OPERATOR_CLEAR)
        plutovg_canvas_set_opacity(canvas, 1)
        load(elements, into: canvas)
        plutovg_canvas_fill(canvas)
        plutovg_canvas_restore(canvas)
    }

    // MARK: Clipping

    public func clip(using rule: CGPathFillRule = .winding) {
        let elements = path
        path.removeAll()
        let canvas = target.canvas
        plutovg_canvas_reset_matrix(canvas)
        load(elements, into: canvas)
        plutovg_canvas_set_fill_rule(canvas, rule == .evenOdd ? PLUTOVG_FILL_RULE_EVEN_ODD : PLUTOVG_FILL_RULE_NON_ZERO)
        plutovg_canvas_clip(canvas)
        plutovg_canvas_set_fill_rule(canvas, PLUTOVG_FILL_RULE_NON_ZERO)
    }

    public func eoClip() { clip(using: .evenOdd) }

    public func clip(to rect: CGRect) {
        var elements: [PathElement] = []
        ArcBuilder.rectangle(rect, transform: state.ctm, into: &elements)
        let canvas = target.canvas
        plutovg_canvas_reset_matrix(canvas)
        load(elements, into: canvas)
        plutovg_canvas_clip(canvas)
    }

    public func clip(to rects: [CGRect]) {
        let canvas = target.canvas
        plutovg_canvas_reset_matrix(canvas)
        plutovg_canvas_new_path(canvas)
        for rect in rects {
            var elements: [PathElement] = []
            ArcBuilder.rectangle(rect, transform: state.ctm, into: &elements)
            append(elements, to: canvas)
        }
        plutovg_canvas_clip(canvas)
    }

    /// Clips to `mask` stretched over `rect`: by alpha, or by brightness for an opaque grey image.
    public func clip(to rect: CGRect, mask image: CGImage) {
        clip(to: rect)
        let scratch = DrawingTarget(width: width, height: height)
        paintImage(image, in: rect, onto: scratch.canvas, op: PLUTOVG_OPERATOR_SRC, opacity: 1)
        if let existing = state.mask {
            let combined = existing.copy()
            fr_extract_mask(scratch.storage.bytes, Int32(width), Int32(height), Int32(scratch.storage.bytesPerRow), image.isOpaqueGray ? 1 : 0, combined.bytes, Int32(width), 1)
            state.mask = combined
        } else {
            let mask = MaskBuffer(width: width, height: height, fill: 0)
            fr_extract_mask(scratch.storage.bytes, Int32(width), Int32(height), Int32(scratch.storage.bytesPerRow), image.isOpaqueGray ? 1 : 0, mask.bytes, Int32(width), 0)
            state.mask = mask
        }
    }

    // MARK: Images and gradients

    public func draw(_ image: CGImage, in rect: CGRect, byTiling _: Bool = false) {
        paint { canvas, op, opacity in
            self.paintImage(image, in: rect, onto: canvas, op: op, opacity: opacity)
        }
    }

    public func drawLinearGradient(_ gradient: CGGradient, start: CGPoint, end: CGPoint, options: CGGradientDrawingOptions) {
        let s = start.applying(state.ctm)
        let e = end.applying(state.ctm)
        let region = gradientRegion(start: s, end: e, options: options)
        let stops = gradient.plutovgStops
        paint { canvas, op, opacity in
            plutovg_canvas_save(canvas)
            plutovg_canvas_reset_matrix(canvas)
            stops.withUnsafeBufferPointer { buffer in
                plutovg_canvas_set_linear_gradient(canvas, Float(s.x), Float(s.y), Float(e.x), Float(e.y), PLUTOVG_SPREAD_METHOD_PAD, buffer.baseAddress, Int32(buffer.count), nil)
            }
            plutovg_canvas_set_operator(canvas, op)
            plutovg_canvas_set_opacity(canvas, opacity)
            self.load(region, into: canvas)
            plutovg_canvas_fill(canvas)
            plutovg_canvas_restore(canvas)
        }
    }

    public func drawRadialGradient(_ gradient: CGGradient, startCenter: CGPoint, startRadius: CGFloat, endCenter: CGPoint, endRadius: CGFloat, options: CGGradientDrawingOptions) {
        let s = startCenter.applying(state.ctm)
        let e = endCenter.applying(state.ctm)
        let scale = sqrt(abs(state.ctm.a * state.ctm.d - state.ctm.b * state.ctm.c))
        let stops = gradient.plutovgStops
        var region: [PathElement] = []
        if options.contains(.drawsAfterEndLocation) {
            ArcBuilder.rectangle(CGRect(x: 0, y: 0, width: width, height: height), transform: .identity, into: &region)
        } else {
            ArcBuilder.ellipse(in: CGRect(x: e.x - endRadius * scale, y: e.y - endRadius * scale, width: endRadius * scale * 2, height: endRadius * scale * 2), transform: .identity, into: &region)
        }
        paint { canvas, op, opacity in
            plutovg_canvas_save(canvas)
            plutovg_canvas_reset_matrix(canvas)
            stops.withUnsafeBufferPointer { buffer in
                plutovg_canvas_set_radial_gradient(canvas, Float(e.x), Float(e.y), Float(endRadius * scale), Float(s.x), Float(s.y), Float(startRadius * scale), PLUTOVG_SPREAD_METHOD_PAD, buffer.baseAddress, Int32(buffer.count), nil)
            }
            plutovg_canvas_set_operator(canvas, op)
            plutovg_canvas_set_opacity(canvas, opacity)
            self.load(region, into: canvas)
            plutovg_canvas_fill(canvas)
            plutovg_canvas_restore(canvas)
        }
    }

    /// The band a linear gradient paints: everything, or only between its end lines.
    private func gradientRegion(start: CGPoint, end: CGPoint, options: CGGradientDrawingOptions) -> [PathElement] {
        let far = CGFloat(max(width, height) * 4)
        var dx = end.x - start.x
        var dy = end.y - start.y
        let length = hypot(dx, dy)
        var elements: [PathElement] = []
        if length < 1e-6 || options.contains([.drawsBeforeStartLocation, .drawsAfterEndLocation]) {
            ArcBuilder.rectangle(CGRect(x: -far, y: -far, width: far * 2 + CGFloat(width), height: far * 2 + CGFloat(height)), transform: .identity, into: &elements)
            return elements
        }
        dx /= length
        dy /= length
        let nx = -dy * far, ny = dx * far
        let before = options.contains(.drawsBeforeStartLocation) ? far : 0
        let after = options.contains(.drawsAfterEndLocation) ? far : 0
        let a = CGPoint(x: start.x - dx * before, y: start.y - dy * before)
        let b = CGPoint(x: end.x + dx * after, y: end.y + dy * after)
        elements.append(.move(CGPoint(x: a.x + nx, y: a.y + ny)))
        elements.append(.line(CGPoint(x: b.x + nx, y: b.y + ny)))
        elements.append(.line(CGPoint(x: b.x - nx, y: b.y - ny)))
        elements.append(.line(CGPoint(x: a.x - nx, y: a.y - ny)))
        elements.append(.close)
        return elements
    }

    /// Draws `image` into `rect` (user space) on `canvas`, scaling it down first when that
    /// would otherwise skip pixels.
    private func paintImage(_ image: CGImage, in rect: CGRect, onto canvas: OpaquePointer, op: plutovg_operator_t, opacity: Float) {
        guard image.width > 0, image.height > 0, rect.width != 0, rect.height != 0 else { return }
        var source = image
        // Image pixels to user space: its top row sits at the rect's top (maxY).
        var toUser = CGAffineTransform(a: rect.width / CGFloat(image.width), b: 0, c: 0, d: -rect.height / CGFloat(image.height), tx: rect.minX, ty: rect.maxY)
        var toDevice = toUser.concatenating(state.ctm)
        let scaleX = hypot(toDevice.a, toDevice.b)
        let scaleY = hypot(toDevice.c, toDevice.d)
        if state.interpolation != .none, scaleX < 0.75 || scaleY < 0.75 {
            let newWidth = max(1, Int((CGFloat(image.width) * min(1, scaleX)).rounded()))
            let newHeight = max(1, Int((CGFloat(image.height) * min(1, scaleY)).rounded()))
            if let smaller = image.resized(width: newWidth, height: newHeight) {
                source = smaller
                toUser = CGAffineTransform(a: rect.width / CGFloat(newWidth), b: 0, c: 0, d: -rect.height / CGFloat(newHeight), tx: rect.minX, ty: rect.maxY)
                toDevice = toUser.concatenating(state.ctm)
            }
        }
        let surface = plutovg_surface_create_for_data(source.storage.bytes, Int32(source.width), Int32(source.height), Int32(source.bytesPerRow))
        defer { plutovg_surface_destroy(surface) }
        var matrix = plutovg_matrix_t(a: Float(toDevice.a), b: Float(toDevice.b), c: Float(toDevice.c), d: Float(toDevice.d), e: Float(toDevice.tx), f: Float(toDevice.ty))
        var quad: [PathElement] = []
        ArcBuilder.rectangle(rect, transform: state.ctm, into: &quad)
        plutovg_canvas_save(canvas)
        plutovg_canvas_reset_matrix(canvas)
        plutovg_canvas_set_texture(canvas, surface, PLUTOVG_TEXTURE_TYPE_PLAIN, 1, &matrix)
        plutovg_canvas_set_operator(canvas, op)
        plutovg_canvas_set_opacity(canvas, opacity)
        load(quad, into: canvas)
        plutovg_canvas_fill(canvas)
        plutovg_canvas_restore(canvas)
    }

    // MARK: Public hooks for text drawing

    /// Fills a path given in user space, for Core Text's glyphs.
    public func fillUserPath(_ elements: [PathElement], rule: CGPathFillRule = .winding, color: CGColor) {
        fill(deviceElements: elements.map { $0.applying(state.ctm) }, rule: rule, color: color)
    }

    public var fillColor: CGColor { state.fill }

    // MARK: Transparency layers

    public func beginTransparencyLayer(auxiliaryInfo _: CFDictionary?) {
        let layer = Layer(target: DrawingTarget(width: width, height: height), outerState: state)
        layers.append(layer)
        state.alpha = 1
        state.shadow = nil
        state.mask = nil
        state.blend = .normal
    }

    public func beginTransparencyLayer(in _: CGRect, auxiliaryInfo: CFDictionary?) {
        beginTransparencyLayer(auxiliaryInfo: auxiliaryInfo)
    }

    public func endTransparencyLayer() {
        // Like a save and restore around the layer: its state changes end with it.
        guard let layer = layers.popLast() else { return }
        state = layer.outerState
        composite(layer.target)
    }

    public func makeImage() -> CGImage? {
        let copy = PixelStorage(copying: base.storage.bytes, width: width, height: height, bytesPerRow: base.storage.bytesPerRow)
        return CGImage(storage: copy, colorSpace: colorSpace, alphaInfo: alphaInfo)
    }

    // MARK: Internals

    private func plutovgColor(_ color: CGColor) -> (Float, Float, Float, Float) {
        var (r, g, b, a) = color.rgba
        if isGray {
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            r = luminance
            g = luminance
            b = luminance
        }
        return (Float(r), Float(g), Float(b), Float(a))
    }

    private func fill(deviceElements elements: [PathElement], rule: CGPathFillRule, color: CGColor) {
        let (r, g, b, a) = plutovgColor(color)
        paint { canvas, op, opacity in
            plutovg_canvas_save(canvas)
            plutovg_canvas_reset_matrix(canvas)
            plutovg_canvas_set_rgba(canvas, r, g, b, a)
            plutovg_canvas_set_operator(canvas, op)
            plutovg_canvas_set_opacity(canvas, opacity)
            plutovg_canvas_set_fill_rule(canvas, rule == .evenOdd ? PLUTOVG_FILL_RULE_EVEN_ODD : PLUTOVG_FILL_RULE_NON_ZERO)
            self.load(elements, into: canvas)
            plutovg_canvas_fill(canvas)
            plutovg_canvas_restore(canvas)
        }
    }

    private func stroke(deviceElements elements: [PathElement]) {
        let (r, g, b, a) = plutovgColor(state.stroke)
        let t = state.ctm
        let scale = sqrt(abs(t.a * t.d - t.b * t.c))
        let width = Float(state.lineWidth * scale)
        let cap: plutovg_line_cap_t = switch state.lineCap {
        case .butt: PLUTOVG_LINE_CAP_BUTT
        case .round: PLUTOVG_LINE_CAP_ROUND
        case .square: PLUTOVG_LINE_CAP_SQUARE
        }
        let join: plutovg_line_join_t = switch state.lineJoin {
        case .miter: PLUTOVG_LINE_JOIN_MITER
        case .round: PLUTOVG_LINE_JOIN_ROUND
        case .bevel: PLUTOVG_LINE_JOIN_BEVEL
        }
        let miter = Float(state.miterLimit)
        let dashes = state.dash.lengths.map { Float($0 * scale) }
        let phase = Float(state.dash.phase * scale)
        paint { canvas, op, opacity in
            plutovg_canvas_save(canvas)
            plutovg_canvas_reset_matrix(canvas)
            plutovg_canvas_set_rgba(canvas, r, g, b, a)
            plutovg_canvas_set_operator(canvas, op)
            plutovg_canvas_set_opacity(canvas, opacity)
            plutovg_canvas_set_line_width(canvas, width)
            plutovg_canvas_set_line_cap(canvas, cap)
            plutovg_canvas_set_line_join(canvas, join)
            plutovg_canvas_set_miter_limit(canvas, miter)
            if !dashes.isEmpty {
                dashes.withUnsafeBufferPointer { plutovg_canvas_set_dash(canvas, phase, $0.baseAddress, Int32($0.count)) }
            }
            self.load(elements, into: canvas)
            plutovg_canvas_stroke(canvas)
            plutovg_canvas_restore(canvas)
        }
    }

    /// Runs one drawing operation, through a scratch bitmap when a shadow or mask applies.
    private func paint(_ body: (OpaquePointer, plutovg_operator_t, Float) -> Void) {
        if state.shadow == nil, state.mask == nil {
            body(target.canvas, state.blend.plutovgOperator, Float(state.alpha))
            return
        }
        let scratch = DrawingTarget(width: width, height: height)
        body(scratch.canvas, PLUTOVG_OPERATOR_SRC_OVER, 1)
        composite(scratch)
    }

    /// Composites a full-size scratch bitmap onto the target with the current shadow, mask,
    /// alpha, blend mode and clip.
    private func composite(_ scratch: DrawingTarget) {
        if let mask = state.mask {
            fr_apply_mask(scratch.storage.bytes, Int32(width), Int32(height), Int32(scratch.storage.bytesPerRow), mask.bytes, Int32(mask.width))
        }
        let canvas = target.canvas
        let op = state.blend.plutovgOperator
        let opacity = Float(state.alpha)
        if let shadow = state.shadow {
            let shadowTarget = DrawingTarget(width: width, height: height)
            shadowTarget.storage.bytes.update(from: scratch.storage.bytes, count: scratch.storage.byteCount)
            let (r, g, b, a) = plutovgColor(shadow.color)
            var color: [Float] = [b, g, r, a]
            fr_tint_bgra(shadowTarget.storage.bytes, Int32(width), Int32(height), Int32(shadowTarget.storage.bytesPerRow), &color)
            // Core Graphics' shadow blur is about twice the gaussian's standard deviation.
            fr_blur_bgra(shadowTarget.storage.bytes, Int32(width), Int32(height), Int32(shadowTarget.storage.bytesPerRow), Float(shadow.blur / 2))
            blit(shadowTarget, onto: canvas, dx: shadow.offset.width, dy: -shadow.offset.height, op: op, opacity: opacity)
        }
        blit(scratch, onto: canvas, dx: 0, dy: 0, op: op, opacity: opacity)
    }

    private func blit(_ source: DrawingTarget, onto canvas: OpaquePointer, dx: CGFloat, dy: CGFloat, op: plutovg_operator_t, opacity: Float) {
        var matrix = plutovg_matrix_t(a: 1, b: 0, c: 0, d: 1, e: Float(dx), f: Float(dy))
        plutovg_canvas_save(canvas)
        plutovg_canvas_reset_matrix(canvas)
        plutovg_canvas_set_texture(canvas, source.surface, PLUTOVG_TEXTURE_TYPE_PLAIN, 1, &matrix)
        plutovg_canvas_set_operator(canvas, op)
        plutovg_canvas_set_opacity(canvas, opacity)
        plutovg_canvas_new_path(canvas)
        plutovg_canvas_rect(canvas, Float(dx), Float(dy), Float(width), Float(height))
        plutovg_canvas_fill(canvas)
        plutovg_canvas_restore(canvas)
    }

    func load(_ elements: [PathElement], into canvas: OpaquePointer) {
        plutovg_canvas_new_path(canvas)
        append(elements, to: canvas)
    }

    private func append(_ elements: [PathElement], to canvas: OpaquePointer) {
        for element in elements {
            switch element {
            case let .move(p): plutovg_canvas_move_to(canvas, Float(p.x), Float(p.y))
            case let .line(p): plutovg_canvas_line_to(canvas, Float(p.x), Float(p.y))
            case let .quad(c, p): plutovg_canvas_quad_to(canvas, Float(c.x), Float(c.y), Float(p.x), Float(p.y))
            case let .cubic(c1, c2, p): plutovg_canvas_cubic_to(canvas, Float(c1.x), Float(c1.y), Float(c2.x), Float(c2.y), Float(p.x), Float(p.y))
            case .close: plutovg_canvas_close_path(canvas)
            }
        }
    }
}

public enum CGPathDrawingMode: Int32, Sendable {
    case fill, eoFill, stroke, fillStroke, eoFillStroke
}
