import CoreText
import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

// Text and SF Symbols rendered into cached bitmaps, with line boxes measured as AppKit does.

struct RGBA: Hashable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat = 1

    static let white = RGBA(red: 1, green: 1, blue: 1)
    static let black = RGBA(red: 0, green: 0, blue: 0)
    static let clear = RGBA(red: 0, green: 0, blue: 0, alpha: 0)

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(white: CGFloat, alpha: CGFloat = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    func opacity(_ value: CGFloat) -> RGBA {
        var copy = self
        copy.alpha *= value
        return copy
    }

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
    }
}

/// A drop shadow or glow, with a Core Graphics blur of twice `radius`.
struct TextShadow: Hashable {
    var color: RGBA
    var radius: CGFloat
    var offset: CGSize = .zero

    func hash(into hasher: inout Hasher) {
        hasher.combine(color)
        hasher.combine(radius)
        hasher.combine(offset.width)
        hasher.combine(offset.height)
    }
}

enum TextAlignment: Hashable {
    case leading
    case center
    case trailing
}

struct TextSpec: Hashable {
    var text: String
    var fontName: String
    var size: CGFloat
    var color: RGBA = .white
    /// Widest a single line may be before it shrinks to `minimumScaleFactor`, then truncates.
    var maxWidth: CGFloat?
    var minimumScaleFactor: CGFloat = 1
    /// Wraps onto as many lines as needed at this width instead of staying on one line.
    var wrapWidth: CGFloat?
    var alignment: TextAlignment = .leading
    var lineSpacing: CGFloat = 0
    /// Applied in order: each shadow is cast by everything drawn before it.
    var shadows: [TextShadow] = []

    func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(fontName)
        hasher.combine(size)
        hasher.combine(color)
        hasher.combine(maxWidth)
        hasher.combine(minimumScaleFactor)
        hasher.combine(wrapWidth)
        hasher.combine(alignment)
        hasher.combine(lineSpacing)
        hasher.combine(shadows)
    }
}

/// A rendered string or symbol. The bitmap extends `padding` past the `size` box for glows.
struct RenderedGraphic {
    let image: CGImage?
    let size: CGSize
    let padding: CGFloat
    let scale: CGFloat

    static let empty = RenderedGraphic(image: nil, size: .zero, padding: 0, scale: 1)

    /// The frame of the bitmap for a layout box placed at `origin`.
    func imageFrame(at origin: CGPoint) -> CGRect {
        CGRect(x: origin.x - padding, y: origin.y - padding, width: size.width + padding * 2, height: size.height + padding * 2)
    }
}

enum FontMetrics {
    static func font(_ name: String, size: CGFloat) -> CTFont {
        #if !FIRSTROW_PORTABLE
            if let weight = ModernTheme.systemFontWeight(for: name) {
                #if os(macOS)
                    return NSFont.systemFont(ofSize: size, weight: weight) as CTFont
                #else
                    return UIFont.systemFont(ofSize: size, weight: weight) as CTFont
                #endif
            }
        #endif
        #if os(macOS)
            if let font = NSFont(name: name, size: size) { return font as CTFont }
            return NSFont.systemFont(ofSize: size) as CTFont
        #elseif FIRSTROW_PORTABLE
            return CTFontCreateWithName(name as CFString, size, nil)
        #else
            if let font = UIFont(name: name, size: size) { return font as CTFont }
            return UIFont.systemFont(ofSize: size) as CTFont
        #endif
    }

    /// Height of one line of text, as AppKit lays it out.
    static func lineHeight(_ font: CTFont) -> CGFloat {
        CTFontGetAscent(font).rounded() + CTFontGetDescent(font).rounded() + CTFontGetLeading(font).rounded()
    }

    static func baseline(_ font: CTFont) -> CGFloat {
        CTFontGetAscent(font).rounded()
    }

    static func lineHeight(fontName: String, size: CGFloat) -> CGFloat {
        lineHeight(font(fontName, size: size))
    }

    private static let widthCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 5000
        return cache
    }()

    static func width(_ text: String, fontName: String, size: CGFloat) -> CGFloat {
        let key = "\(fontName)|\(size)|\(text)" as NSString
        if let cached = widthCache.object(forKey: key) {
            return CGFloat(cached.doubleValue)
        }
        let line = CTLineCreateWithAttributedString(attributed(text, font: font(fontName, size: size), color: .white))
        let width = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        widthCache.setObject(NSNumber(value: Double(width)), forKey: key)
        return width
    }

    static func attributed(_ text: String, font: CTFont, color: RGBA) -> CFAttributedString {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor,
        ]
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
    }
}

@MainActor
enum TextRenderer {
    private final class Key: NSObject {
        let spec: TextSpec
        let scale: CGFloat
        init(_ spec: TextSpec, _ scale: CGFloat) {
            self.spec = spec
            self.scale = scale
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(spec)
            hasher.combine(scale)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return other.spec == spec && other.scale == scale
        }
    }

    private final class Box {
        let graphic: RenderedGraphic
        init(_ graphic: RenderedGraphic) { self.graphic = graphic }
    }

    private static let cache: NSCache<Key, Box> = {
        let cache = NSCache<Key, Box>()
        // Each image Core Animation has shown holds shared memory, so keep only recent text.
        cache.countLimit = 400
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    private struct Line {
        let line: CTLine
        let width: CGFloat
    }

    private struct Layout {
        let lines: [Line]
        let font: CTFont
        let size: CGSize
        let lineHeight: CGFloat
        let baseline: CGFloat
    }

    /// The layout box of `spec` without drawing it.
    static func measure(_ spec: TextSpec) -> CGSize {
        layout(spec).size
    }

    static func render(_ spec: TextSpec, scale: CGFloat) -> RenderedGraphic {
        guard !spec.text.isEmpty else { return .empty }
        let key = Key(spec, scale)
        if let cached = cache.object(forKey: key) {
            return cached.graphic
        }
        let layout = layout(spec)
        let padding = ceil(spec.shadows.map { $0.radius * 2.5 + max(abs($0.offset.width), abs($0.offset.height)) }.max() ?? 0) + 2
        let graphic = draw(size: layout.size, padding: padding, scale: scale, shadows: spec.shadows) { context in
            for (index, line) in layout.lines.enumerated() {
                let x: CGFloat = switch spec.alignment {
                case .leading: 0
                case .center: ((layout.size.width - line.width) * 0.5).rounded()
                case .trailing: layout.size.width - line.width
                }
                let lineTop = CGFloat(index) * (layout.lineHeight + spec.lineSpacing)
                // Bitmap coordinates have y up; lines are placed from the top.
                context.textPosition = CGPoint(x: padding + x, y: layout.size.height + padding - lineTop - layout.baseline)
                CTLineDraw(line.line, context)
            }
        }
        cache.setObject(Box(graphic), forKey: key, cost: graphic.image.map { $0.bytesPerRow * $0.height } ?? 0)
        return graphic
    }

    private static func layout(_ spec: TextSpec) -> Layout {
        var font = FontMetrics.font(spec.fontName, size: spec.size)
        let lineHeight = FontMetrics.lineHeight(font)
        var baseline = FontMetrics.baseline(font)
        if let wrapWidth = spec.wrapWidth {
            let attributed = FontMetrics.attributed(spec.text, font: font, color: spec.color)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let length = CFAttributedStringGetLength(attributed)
            var lines: [Line] = []
            var start = 0
            while start < length {
                let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, wrapWidth)))
                guard count > 0 else { break }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
                lines.append(Line(line: line, width: ceil(width)))
                start += count
            }
            let width = lines.map(\.width).max() ?? 0
            let height = lines.isEmpty ? 0 : CGFloat(lines.count) * lineHeight + CGFloat(lines.count - 1) * spec.lineSpacing
            return Layout(lines: lines, font: font, size: CGSize(width: min(width, ceil(wrapWidth)), height: height), lineHeight: lineHeight, baseline: baseline)
        }

        var line = CTLineCreateWithAttributedString(FontMetrics.attributed(spec.text, font: font, color: spec.color))
        var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if let maxWidth = spec.maxWidth, width > maxWidth {
            // Shrink first, down to minimumScaleFactor, then cut the end off.
            if spec.minimumScaleFactor < 1 {
                let fittingSize = max(spec.size * spec.minimumScaleFactor, spec.size * (maxWidth / width))
                font = FontMetrics.font(spec.fontName, size: fittingSize)
                line = CTLineCreateWithAttributedString(FontMetrics.attributed(spec.text, font: font, color: spec.color))
                width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                // Keep the shrunken line centred on the full-size line box.
                let shrunkHeight = FontMetrics.lineHeight(font)
                baseline = ((lineHeight - shrunkHeight) * 0.5) + FontMetrics.baseline(font)
            }
            if width > maxWidth {
                let ellipsis = CTLineCreateWithAttributedString(FontMetrics.attributed("\u{2026}", font: font, color: spec.color))
                if let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) {
                    line = truncated
                    width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                }
            }
        }
        let boxWidth = min(ceil(width), spec.maxWidth.map { ceil($0) } ?? .greatestFiniteMagnitude)
        return Layout(lines: [Line(line: line, width: ceil(width))], font: font, size: CGSize(width: boxWidth, height: lineHeight), lineHeight: lineHeight, baseline: baseline)
    }

    /// Draws `body` with `shadows` into a padded bitmap. `body` works in points with y up.
    static func draw(size: CGSize, padding: CGFloat, scale: CGFloat, shadows: [TextShadow], body: (CGContext) -> Void) -> RenderedGraphic {
        let pointWidth = size.width + padding * 2
        let pointHeight = size.height + padding * 2
        let pixelWidth = max(1, Int(ceil(pointWidth * scale)))
        let pixelHeight = max(1, Int(ceil(pointHeight * scale)))
        guard size.width > 0, size.height > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: layerBitmapInfo,
              )
        else {
            return RenderedGraphic(image: nil, size: size, padding: padding, scale: scale)
        }
        context.scaleBy(x: scale, y: scale)
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSmoothing(false)
        context.setShouldSubpixelPositionFonts(true)
        context.setShouldSubpixelQuantizeFonts(false)
        context.interpolationQuality = .high
        // Each shadow is cast by the drawing plus the shadows before it.
        for shadow in shadows.reversed() {
            context.setShadow(
                offset: CGSize(width: shadow.offset.width * scale, height: -shadow.offset.height * scale),
                blur: shadow.radius * 2 * scale,
                color: shadow.color.cgColor,
            )
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setShadow(offset: .zero, blur: 0, color: nil)
        }
        body(context)
        for _ in shadows {
            context.endTransparencyLayer()
        }
        return RenderedGraphic(image: context.makeImage(), size: size, padding: padding, scale: scale)
    }
}

/// SF Symbols, tinted, as bitmaps.
@MainActor
enum SymbolRenderer {
    enum Weight: Hashable {
        case regular
        case semibold
        case bold
        case heavy
    }

    private struct Key: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: Weight
        let color: RGBA
        let shadows: [TextShadow]
        let scale: CGFloat
    }

    private static var cache: [Key: RenderedGraphic] = [:]

    static func render(_ name: String, pointSize: CGFloat, weight: Weight, color: RGBA = .white, shadows: [TextShadow] = [], scale: CGFloat) -> RenderedGraphic {
        let key = Key(name: name, pointSize: pointSize, weight: weight, color: color, shadows: shadows, scale: scale)
        if let cached = cache[key] {
            return cached
        }
        guard let symbol = symbolImage(name, pointSize: pointSize, weight: weight) else { return .empty }
        let size = symbol.size
        let padding = ceil(shadows.map { $0.radius * 2.5 + max(abs($0.offset.width), abs($0.offset.height)) }.max() ?? 0) + 2
        let tinted = tintedImage(symbol.image, pixelSize: symbol.pixelSize, color: color)
        let graphic = TextRenderer.draw(size: size, padding: padding, scale: scale, shadows: shadows) { context in
            if let tinted {
                context.draw(tinted, in: CGRect(x: padding, y: padding, width: size.width, height: size.height))
            }
        }
        if cache.count > 400 { cache.removeAll() }
        cache[key] = graphic
        return graphic
    }

    private struct Symbol {
        let image: CGImage
        let size: CGSize
        let pixelSize: CGSize
    }

    /// The symbol drawn at 4x, with the point size of its alignment box.
    private static func symbolImage(_ name: String, pointSize: CGFloat, weight: Weight) -> Symbol? {
        let oversample: CGFloat = 4
        #if os(macOS)
            guard #available(macOS 11.0, *) else {
                return SymbolFallback.symbol(name, pointSize: pointSize, weight: weight, oversample: oversample).map {
                    Symbol(image: $0.image, size: $0.size, pixelSize: CGSize(width: $0.image.width, height: $0.image.height))
                }
            }
            let nsWeight: NSFont.Weight = switch weight {
            case .regular: .regular
            case .semibold: .semibold
            case .bold: .bold
            case .heavy: .heavy
            }
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? olderName(name).flatMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil) }),
                  let image = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: nsWeight))
            else {
                // A symbol newer than this Mac's: the drawn stand-in.
                return SymbolFallback.symbol(name, pointSize: pointSize, weight: weight, oversample: oversample).map {
                    Symbol(image: $0.image, size: $0.size, pixelSize: CGSize(width: $0.image.width, height: $0.image.height))
                }
            }
            let size = image.size
            var rect = CGRect(x: 0, y: 0, width: size.width * oversample, height: size.height * oversample)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
            return Symbol(image: cgImage, size: size, pixelSize: CGSize(width: cgImage.width, height: cgImage.height))
        #elseif FIRSTROW_PORTABLE
            // SF Symbols are Apple's alone, so these are the hand-drawn stand-ins macOS 10.15 uses.
            return SymbolFallback.symbol(name, pointSize: pointSize, weight: weight, oversample: oversample).map {
                Symbol(image: $0.image, size: $0.size, pixelSize: CGSize(width: $0.image.width, height: $0.image.height))
            }
        #else
            let uiWeight: UIImage.SymbolWeight = switch weight {
            case .regular: .regular
            case .semibold: .semibold
            case .bold: .bold
            case .heavy: .heavy
            }
            let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: uiWeight)
            guard let image = UIImage(systemName: name, withConfiguration: configuration)
                ?? olderName(name).flatMap({ UIImage(systemName: $0, withConfiguration: configuration) })
            else {
                return SymbolFallback.symbol(name, pointSize: pointSize, weight: weight, oversample: oversample).map {
                    Symbol(image: $0.image, size: $0.size, pixelSize: CGSize(width: $0.image.width, height: $0.image.height))
                }
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = oversample
            let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.withTintColor(.white, renderingMode: .alwaysOriginal).draw(at: .zero)
            }
            guard let cgImage = rendered.cgImage else { return nil }
            return Symbol(image: cgImage, size: image.size, pixelSize: CGSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    /// An older symbol that stands in for a newer one on systems without it.
    private static func olderName(_ name: String) -> String? {
        switch name {
        case "gauge.with.dots.needle.67percent": "speedometer"
        default: nil
        }
    }

    private static func tintedImage(_ image: CGImage, pixelSize: CGSize, color: RGBA) -> CGImage? {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(color.cgColor)
        context.fill(rect)
        return context.makeImage()
    }
}

extension CALayer {
    /// Shows a rendered string or symbol with its layout box at `origin`.
    func show(_ graphic: RenderedGraphic, at origin: CGPoint) {
        let redrawn = contents as AnyObject? !== graphic.image
        if redrawn {
            contents = graphic.image
        }
        contentsScale = graphic.scale
        let frame = graphic.imageFrame(at: origin)
        let box = CGRect(origin: .zero, size: frame.size)
        if redrawn, LayoutGlide.isActive {
            // New lettering takes its size at once even in a layout glide; only its place glides.
            withoutLayerActions { bounds = box }
        } else {
            bounds = box
        }
        position = CGPoint(x: frame.minX + frame.width * anchorPoint.x, y: frame.minY + frame.height * anchorPoint.y)
    }
}

/// Hand-drawn stand-ins for the SF Symbols First Row uses, for macOS 10.15, Linux and Windows.
/// Each one keeps the symbol's box, margins and stroke as measured at the size First Row draws
/// it, so whatever is laid out around it lands in the same place.
enum SymbolFallback {
    private struct Shape {
        /// The point size the measurements below are for.
        let referenceSize: CGFloat
        let box: CGSize
        let draw: (CGContext) -> Void
    }

    static func symbol(_ name: String, pointSize: CGFloat, weight: SymbolRenderer.Weight, oversample: CGFloat) -> (image: CGImage, size: CGSize)? {
        guard let shape = shape(name, weight: weight) else { return nil }
        let scale = pointSize / shape.referenceSize
        let size = CGSize(width: shape.box.width * scale, height: shape.box.height * scale)
        let width = Int(ceil(size.width * oversample))
        let height = Int(ceil(size.height * oversample))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
        ) else { return nil }
        // Draw in the reference size's points with the origin at the top left.
        context.scaleBy(x: oversample, y: oversample)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        shape.draw(context)
        guard let image = context.makeImage() else { return nil }
        return (image, size)
    }

    private static func shape(_ name: String, weight: SymbolRenderer.Weight) -> Shape? {
        switch name {
        case "play.fill":
            return Shape(referenceSize: 23, box: CGSize(width: 22, height: 25)) { context in
                context.addPath(roundedPolygon([(3, 0.44, 2.2), (24.04, 12.56, 2.2), (3, 24.68, 2.2)]))
                context.fillPath()
            }
        case "pause.fill":
            return Shape(referenceSize: 23, box: CGSize(width: 22, height: 25)) { context in
                for x: CGFloat in [3, 12.38] {
                    context.addPath(CGPath(roundedRect: CGRect(x: x, y: 2, width: 6.62, height: 21), cornerWidth: 1.6, cornerHeight: 1.6, transform: nil))
                }
                context.fillPath()
            }
        case "chevron.right":
            // The arms run from round caps in the ink's left corners to a round join at its right.
            let (box, ink, stroke): (CGSize, CGRect, CGFloat) = switch weight {
            case .regular: (CGSize(width: 23, height: 32), CGRect(x: 6, y: 3.125, width: 15, height: 25.875), 2.8)
            case .semibold: (CGSize(width: 24, height: 33), CGRect(x: 6, y: 3.125, width: 16, height: 26.875), 4.09)
            case .bold: (CGSize(width: 24, height: 33), CGRect(x: 6, y: 3, width: 15.875, height: 27), 4.61)
            case .heavy: (CGSize(width: 25, height: 34), CGRect(x: 6, y: 3.125, width: 16.875, height: 27.875), 5.74)
            }
            return Shape(referenceSize: 30, box: box) { context in
                let half = stroke / 2
                context.setLineWidth(stroke)
                context.move(to: CGPoint(x: ink.minX + half, y: ink.minY + half))
                context.addLine(to: CGPoint(x: ink.maxX - half, y: ink.midY))
                context.addLine(to: CGPoint(x: ink.minX + half, y: ink.maxY - half))
                context.strokePath()
            }
        case "shuffle":
            if weight == .regular {
                return shuffle(referenceSize: 25, box: CGSize(width: 35, height: 27), stroke: 2.2, strands: (6.7, 20.3),
                               leadIn: 4.1, curve: (8, 10.4, 19.1, 21.5), arrowBase: 25.4, arrowTip: 32.1, arrowHalf: 4.8, arrowRadius: 0.7)
            }
            return shuffle(referenceSize: 34, box: CGSize(width: 49, height: 39), stroke: 3.9, strands: (10.3, 28.7),
                           leadIn: 5.95, curve: (11.1, 14.5, 26.8, 30.2), arrowBase: 35.6, arrowTip: 45.4, arrowHalf: 7.5, arrowRadius: 0.9)
        case "speaker.wave.3.fill":
            return Shape(referenceSize: 34, box: CGSize(width: 58, height: 41)) { context in
                // The box and the cone flaring out of it, then three arcs about a point left of them.
                context.addPath(roundedPolygon([(5, 13.1, 2.8), (13.87, 13.1, 1), (25.75, 1.79, 2.2), (25.75, 39.21, 2.2), (13.87, 27.9, 1), (5, 27.9, 2.8)]))
                context.fillPath()
                context.setLineWidth(3.6)
                for (center, radius, degrees) in [(20.94, 13.56, 27.0), (19.13, 23.68, 25.5), (20.74, 30.39, 29.5)] as [(CGFloat, CGFloat, CGFloat)] {
                    let spread = degrees * .pi / 180
                    context.addArc(center: CGPoint(x: center, y: 20.5), radius: radius, startAngle: -spread, endAngle: spread, clockwise: false)
                    context.strokePath()
                }
            }
        case "film.fill":
            return Shape(referenceSize: 100, box: CGSize(width: 120, height: 100)) { context in
                context.addPath(CGPath(roundedRect: CGRect(x: 6, y: 12, width: 108, height: 76), cornerWidth: 10, cornerHeight: 10, transform: nil))
                for column: CGFloat in [14, 98] {
                    for row in 0 ..< 4 {
                        context.addPath(CGPath(roundedRect: CGRect(x: column, y: 21 + CGFloat(row) * 16, width: 8, height: 9), cornerWidth: 2, cornerHeight: 2, transform: nil))
                    }
                }
                context.addPath(CGPath(roundedRect: CGRect(x: 32, y: 47, width: 56, height: 6), cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.fillPath(using: .evenOdd)
            }
        case "tv.fill":
            return Shape(referenceSize: 100, box: CGSize(width: 120, height: 100)) { context in
                context.addPath(CGPath(roundedRect: CGRect(x: 4, y: 8, width: 112, height: 72), cornerWidth: 10, cornerHeight: 10, transform: nil))
                context.addPath(CGPath(roundedRect: CGRect(x: 36, y: 87, width: 48, height: 7), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
                context.fillPath()
            }
        case "mic.fill":
            return Shape(referenceSize: 100, box: CGSize(width: 100, height: 100)) { context in
                context.addPath(CGPath(roundedRect: CGRect(x: 36, y: 4, width: 28, height: 60), cornerWidth: 14, cornerHeight: 14, transform: nil))
                context.addPath(CGPath(roundedRect: CGRect(x: 47, y: 72, width: 6, height: 16), cornerWidth: 2, cornerHeight: 2, transform: nil))
                context.addPath(CGPath(roundedRect: CGRect(x: 32, y: 86, width: 36, height: 7), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
                context.fillPath()
                context.setLineWidth(6)
                context.addArc(center: CGPoint(x: 50, y: 46), radius: 27, startAngle: 0, endAngle: .pi, clockwise: false)
                context.strokePath()
            }
        case "photo.fill":
            return Shape(referenceSize: 100, box: CGSize(width: 120, height: 100)) { context in
                context.addPath(CGPath(roundedRect: CGRect(x: 4, y: 10, width: 112, height: 80), cornerWidth: 10, cornerHeight: 10, transform: nil))
                context.addEllipse(in: CGRect(x: 76, y: 22, width: 18, height: 18))
                context.addPath(roundedPolygon([(16, 80, 3), (44, 42, 4), (64, 66, 3), (76, 54, 3), (104, 80, 3)]))
                context.fillPath(using: .evenOdd)
            }
        case "photo.fill.on.rectangle.fill":
            return Shape(referenceSize: 100, box: CGSize(width: 124, height: 100)) { context in
                // The frame behind, then a gap, then the photo in front.
                context.addPath(CGPath(roundedRect: CGRect(x: 26, y: 6, width: 94, height: 68), cornerWidth: 10, cornerHeight: 10, transform: nil))
                context.fillPath()
                context.setBlendMode(.clear)
                context.addPath(CGPath(roundedRect: CGRect(x: -2, y: 18, width: 106, height: 80), cornerWidth: 14, cornerHeight: 14, transform: nil))
                context.fillPath()
                context.setBlendMode(.normal)
                context.addPath(CGPath(roundedRect: CGRect(x: 4, y: 24, width: 94, height: 68), cornerWidth: 10, cornerHeight: 10, transform: nil))
                context.addEllipse(in: CGRect(x: 66, y: 34, width: 15, height: 15))
                context.addPath(roundedPolygon([(14, 84, 3), (38, 52, 4), (56, 72, 3), (66, 62, 3), (88, 84, 3)]))
                context.fillPath(using: .evenOdd)
            }
        case "calendar":
            return Shape(referenceSize: 100, box: CGSize(width: 100, height: 100)) { context in
                context.setLineWidth(7)
                context.addPath(CGPath(roundedRect: CGRect(x: 8, y: 14, width: 84, height: 78), cornerWidth: 14, cornerHeight: 14, transform: nil))
                context.strokePath()
                context.addPath(CGPath(roundedRect: CGRect(x: 8, y: 14, width: 84, height: 22), cornerWidth: 10, cornerHeight: 10, transform: nil))
                context.addRect(CGRect(x: 8, y: 26, width: 84, height: 10))
                for x in [28.0, 72.0] as [CGFloat] {
                    context.addPath(CGPath(roundedRect: CGRect(x: x - 4.5, y: 4, width: 9, height: 20), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
                }
                for row in 0 ..< 3 {
                    for column in 0 ..< 4 where !(row == 2 && column == 3) {
                        context.addPath(CGPath(roundedRect: CGRect(x: 21 + CGFloat(column) * 16, y: 45 + CGFloat(row) * 14, width: 10, height: 9), cornerWidth: 2, cornerHeight: 2, transform: nil))
                    }
                }
                context.fillPath()
            }
        case "square.and.arrow.down.fill":
            return Shape(referenceSize: 100, box: CGSize(width: 100, height: 108)) { context in
                // A box with an arrow going down into it, a gap around the arrow.
                context.addPath(CGPath(roundedRect: CGRect(x: 10, y: 38, width: 80, height: 66), cornerWidth: 13, cornerHeight: 13, transform: nil))
                context.fillPath()
                context.setBlendMode(.clear)
                context.setLineWidth(10)
                context.addPath(CGPath(roundedRect: CGRect(x: 44.5, y: 0, width: 11, height: 74), cornerWidth: 5.5, cornerHeight: 5.5, transform: nil))
                context.addPath(roundedPolygon([(26, 52, 4), (74, 52, 4), (50, 84, 4)]))
                context.drawPath(using: .fillStroke)
                context.setBlendMode(.normal)
                context.addPath(CGPath(roundedRect: CGRect(x: 45.5, y: 2, width: 9, height: 64), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
                context.addPath(roundedPolygon([(31, 55, 3), (69, 55, 3), (50, 79, 3)]))
                context.fillPath()
            }
        case "gearshape.fill":
            return Shape(referenceSize: 100, box: CGSize(width: 100, height: 100)) { context in
                let center = CGPoint(x: 50, y: 50)
                var corners: [(x: CGFloat, y: CGFloat, radius: CGFloat)] = []
                let teeth = 8
                for tooth in 0 ..< teeth {
                    let base = CGFloat(tooth) * 2 * .pi / CGFloat(teeth)
                    for (offset, radius) in [(-0.2, 36.0), (-0.11, 46.0), (0.11, 46.0), (0.2, 36.0)] as [(CGFloat, CGFloat)] {
                        let angle = base + offset
                        corners.append((center.x + cos(angle) * radius, center.y + sin(angle) * radius, 2))
                    }
                }
                context.addPath(roundedPolygon(corners))
                context.addEllipse(in: CGRect(x: 36, y: 36, width: 28, height: 28))
                context.fillPath(using: .evenOdd)
            }
        case "externaldrive.fill":
            return Shape(referenceSize: 100, box: CGSize(width: 120, height: 100)) { context in
                context.addPath(CGPath(roundedRect: CGRect(x: 4, y: 28, width: 112, height: 46), cornerWidth: 12, cornerHeight: 12, transform: nil))
                context.addEllipse(in: CGRect(x: 92, y: 45, width: 11, height: 11))
                context.addPath(CGPath(roundedRect: CGRect(x: 18, y: 48, width: 40, height: 6), cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.fillPath(using: .evenOdd)
            }
        case "play.rectangle.fill":
            return Shape(referenceSize: 100, box: CGSize(width: 120, height: 100)) { context in
                context.addPath(CGPath(roundedRect: CGRect(x: 4, y: 10, width: 112, height: 80), cornerWidth: 12, cornerHeight: 12, transform: nil))
                context.addPath(roundedPolygon([(48, 32, 3), (78, 50, 3), (48, 68, 3)]))
                context.fillPath(using: .evenOdd)
            }
        case "exclamationmark.triangle.fill":
            return Shape(referenceSize: 100, box: CGSize(width: 112, height: 100)) { context in
                context.addPath(roundedPolygon([(56, 6, 10), (108, 94, 8), (4, 94, 8)]))
                context.addPath(CGPath(roundedRect: CGRect(x: 51, y: 34, width: 10, height: 34), cornerWidth: 5, cornerHeight: 5, transform: nil))
                context.addEllipse(in: CGRect(x: 50, y: 73, width: 12, height: 12))
                context.fillPath(using: .evenOdd)
            }
        case "checkmark":
            return Shape(referenceSize: 34, box: CGSize(width: 35, height: 33)) { context in
                context.setLineWidth(weight == .regular ? 3 : 4.3)
                context.move(to: CGPoint(x: 6.5, y: 18.5))
                context.addLine(to: CGPoint(x: 13.6, y: 26.4))
                context.addLine(to: CGPoint(x: 28.5, y: 6))
                context.strokePath()
            }
        case "chevron.left":
            // chevron.right turned round.
            return Shape(referenceSize: 30, box: CGSize(width: 24, height: 33)) { context in
                let stroke: CGFloat = weight == .regular ? 2.8 : 4.09
                let ink = CGRect(x: 2, y: 3.125, width: 16, height: 26.875)
                let half = stroke / 2
                context.setLineWidth(stroke)
                context.move(to: CGPoint(x: ink.maxX - half, y: ink.minY + half))
                context.addLine(to: CGPoint(x: ink.minX + half, y: ink.midY))
                context.addLine(to: CGPoint(x: ink.maxX - half, y: ink.maxY - half))
                context.strokePath()
            }
        case "forward.fill", "backward.fill":
            let forward = name == "forward.fill"
            return Shape(referenceSize: 20, box: CGSize(width: 30, height: 18)) { context in
                for start: CGFloat in [2, 15] {
                    let points: [(CGFloat, CGFloat, CGFloat)] = [(start, 1.5, 1.6), (start + 13, 9, 1.6), (start, 16.5, 1.6)]
                    context.addPath(roundedPolygon(points.map { (forward ? $0.0 : 30 - $0.0, $0.1, $0.2) }))
                }
                context.fillPath()
            }
        case "goforward.10", "gobackward.10":
            let forward = name == "goforward.10"
            return Shape(referenceSize: 22, box: CGSize(width: 24, height: 26)) { context in
                func x(_ value: CGFloat) -> CGFloat { forward ? value : 24 - value }
                let center = CGPoint(x: 12, y: 14)
                let radius: CGFloat = 9.4
                context.setLineWidth(2)
                // Round from the top, the long way, leaving a gap before it where the arrow points.
                let steps = 48
                for step in 0 ... steps {
                    let angle = -CGFloat.pi / 2 - CGFloat(step) / CGFloat(steps) * (CGFloat.pi * 1.68)
                    let point = CGPoint(x: x(center.x + radius * cos(angle)), y: center.y + radius * sin(angle))
                    if step == 0 { context.move(to: point) } else { context.addLine(to: point) }
                }
                context.strokePath()
                context.addPath(roundedPolygon([(x(11), 0.8, 0.8), (x(17), 4.6, 0.8), (x(11), 8.4, 0.8)]))
                context.fillPath()
                // "10".
                context.setLineWidth(1.7)
                context.move(to: CGPoint(x: 8.4, y: 11.2))
                context.addLine(to: CGPoint(x: 9.6, y: 10.4))
                context.addLine(to: CGPoint(x: 9.6, y: 17.8))
                context.strokePath()
                context.addEllipse(in: CGRect(x: 12, y: 10.4, width: 4.4, height: 7.4))
                context.strokePath()
            }
        case "quote.bubble", "quote.bubble.fill", "captions.bubble":
            return Shape(referenceSize: 20, box: CGSize(width: 26, height: 24)) { context in
                let bubble = CGMutablePath()
                bubble.addRoundedRect(in: CGRect(x: 2, y: 2, width: 22, height: 16), cornerWidth: 5, cornerHeight: 5)
                bubble.move(to: CGPoint(x: 6, y: 17))
                bubble.addLine(to: CGPoint(x: 5, y: 22.5))
                bubble.addLine(to: CGPoint(x: 11.5, y: 17))
                if name == "quote.bubble.fill" {
                    context.addPath(bubble)
                    for left: CGFloat in [8.2, 14.2] {
                        context.addEllipse(in: CGRect(x: left, y: 7, width: 3.6, height: 3.6))
                        context.addRect(CGRect(x: left + 2, y: 9, width: 1.6, height: 3.4))
                    }
                    context.fillPath(using: .evenOdd)
                    return
                }
                context.setLineWidth(1.9)
                context.addPath(bubble)
                context.strokePath()
                if name == "captions.bubble" {
                    // Two lines of words.
                    context.setLineWidth(1.8)
                    for (from, to, y) in [(7, 12.5, 8.4), (14.5, 19, 8.4), (7, 10.5, 12.2), (12.5, 19, 12.2)] as [(CGFloat, CGFloat, CGFloat)] {
                        context.move(to: CGPoint(x: from, y: y))
                        context.addLine(to: CGPoint(x: to, y: y))
                    }
                    context.strokePath()
                } else {
                    for left: CGFloat in [8.2, 14.2] {
                        context.addEllipse(in: CGRect(x: left, y: 7, width: 3.6, height: 3.6))
                        context.addRect(CGRect(x: left + 2, y: 9, width: 1.6, height: 3.4))
                    }
                    context.fillPath()
                }
            }
        case "waveform":
            return Shape(referenceSize: 20, box: CGSize(width: 26, height: 22)) { context in
                context.setLineWidth(2.1)
                for (x, height) in [(3, 5), (7, 11), (11, 18), (15, 9), (19, 14), (23, 6)] as [(CGFloat, CGFloat)] {
                    context.move(to: CGPoint(x: x, y: 11 - height / 2))
                    context.addLine(to: CGPoint(x: x, y: 11 + height / 2))
                }
                context.strokePath()
            }
        case "gauge.with.dots.needle.67percent", "speedometer":
            return Shape(referenceSize: 20, box: CGSize(width: 24, height: 22)) { context in
                let center = CGPoint(x: 12, y: 12.5)
                context.setLineWidth(2)
                context.addEllipse(in: CGRect(x: center.x - 9.5, y: center.y - 9.5, width: 19, height: 19))
                context.strokePath()
                // Dots round the dial, and the needle two-thirds of the way.
                for degrees: CGFloat in [150, 195, 240, 285] {
                    let angle = degrees * .pi / 180
                    let point = CGPoint(x: center.x + 6.4 * cos(angle), y: center.y + 6.4 * sin(angle))
                    context.addEllipse(in: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2))
                }
                context.fillPath()
                context.setLineWidth(2)
                let needle = -25 * CGFloat.pi / 180
                context.move(to: center)
                context.addLine(to: CGPoint(x: center.x + 6.8 * cos(needle), y: center.y + 6.8 * sin(needle)))
                context.strokePath()
                context.addEllipse(in: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
                context.fillPath()
            }
        case "ellipsis":
            return Shape(referenceSize: 20, box: CGSize(width: 24, height: 22)) { context in
                for x: CGFloat in [4.5, 12, 19.5] {
                    context.addEllipse(in: CGRect(x: x - 2.3, y: 11 - 2.3, width: 4.6, height: 4.6))
                }
                context.fillPath()
            }
        case "xmark":
            return Shape(referenceSize: 20, box: CGSize(width: 22, height: 22)) { context in
                context.setLineWidth(2.4)
                context.move(to: CGPoint(x: 5, y: 5))
                context.addLine(to: CGPoint(x: 17, y: 17))
                context.move(to: CGPoint(x: 17, y: 5))
                context.addLine(to: CGPoint(x: 5, y: 17))
                context.strokePath()
            }
        case "arrow.up.and.down", "arrow.left.and.right":
            let vertical = name == "arrow.up.and.down"
            return Shape(referenceSize: 20, box: CGSize(width: 24, height: 24)) { context in
                func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
                    vertical ? CGPoint(x: 12 + across, y: along) : CGPoint(x: along, y: 12 + across)
                }
                context.setLineWidth(2.2)
                context.move(to: point(4, 0))
                context.addLine(to: point(20, 0))
                for (tip, back) in [(CGFloat(3), CGFloat(8.5)), (21, 15.5)] {
                    context.move(to: point(back, -5))
                    context.addLine(to: point(tip, 0))
                    context.addLine(to: point(back, 5))
                }
                context.strokePath()
            }
        case "cursorarrow":
            return Shape(referenceSize: 20, box: CGSize(width: 20, height: 24)) { context in
                context.addPath(roundedPolygon([(4, 2.5, 0.8), (17, 15, 0.8), (10.6, 15.4, 0.6), (14, 21.5, 0.8), (11.4, 22.6, 0.8), (8.2, 16.6, 0.6), (4, 20.6, 0.8)]))
                context.fillPath()
            }
        case "music.note.list":
            return Shape(referenceSize: 20, box: CGSize(width: 26, height: 22)) { context in
                context.setLineWidth(2)
                for y: CGFloat in [5, 10, 15] {
                    context.move(to: CGPoint(x: 2, y: y))
                    context.addLine(to: CGPoint(x: y == 15 ? 9 : 13, y: y))
                }
                context.strokePath()
                context.addEllipse(in: CGRect(x: 12.5, y: 14, width: 6.5, height: 6))
                context.addRect(CGRect(x: 17.6, y: 3, width: 1.6, height: 14))
                context.addPath(roundedPolygon([(17.6, 3, 0.4), (24, 1.5, 0.6), (24, 6, 0.6), (17.6, 7.5, 0.4)]))
                context.fillPath()
            }
        case "playpause.fill":
            return Shape(referenceSize: 20, box: CGSize(width: 28, height: 20)) { context in
                context.addPath(roundedPolygon([(2, 3, 1.2), (14, 10, 1.2), (2, 17, 1.2)]))
                context.addPath(CGPath(roundedRect: CGRect(x: 16.5, y: 3.5, width: 3.6, height: 13), cornerWidth: 1, cornerHeight: 1, transform: nil))
                context.addPath(CGPath(roundedRect: CGRect(x: 22.5, y: 3.5, width: 3.6, height: 13), cornerWidth: 1, cornerHeight: 1, transform: nil))
                context.fillPath()
            }
        case "keyboard":
            return Shape(referenceSize: 20, box: CGSize(width: 30, height: 20)) { context in
                context.setLineWidth(1.8)
                context.addPath(CGPath(roundedRect: CGRect(x: 2, y: 2.5, width: 26, height: 15), cornerWidth: 3, cornerHeight: 3, transform: nil))
                context.strokePath()
                // Two rows of keys, and the space bar.
                for row in 0 ..< 2 {
                    for column in 0 ..< 6 {
                        context.addRect(CGRect(x: 5.4 + CGFloat(column) * 3.5, y: 5.6 + CGFloat(row) * 3.3, width: 2, height: 1.9))
                    }
                }
                context.addRect(CGRect(x: 9, y: 12.6, width: 12, height: 1.9))
                context.fillPath()
            }
        case "computermouse.fill", "computermouse":
            return Shape(referenceSize: 20, box: CGSize(width: 18, height: 26)) { context in
                let body = CGPath(roundedRect: CGRect(x: 2.5, y: 1.5, width: 13, height: 23), cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)
                context.addPath(body)
                if name == "computermouse.fill" {
                    // The buttons' parting line and the wheel, cut out.
                    context.addRect(CGRect(x: 2.5, y: 9.6, width: 13, height: 1.2))
                    context.addRect(CGRect(x: 8.4, y: 1.5, width: 1.2, height: 8.5))
                    context.fillPath(using: .evenOdd)
                } else {
                    context.setLineWidth(1.8)
                    context.strokePath()
                    context.move(to: CGPoint(x: 9, y: 4))
                    context.addLine(to: CGPoint(x: 9, y: 8))
                    context.strokePath()
                }
            }
        case "music.note":
            return Shape(referenceSize: 40, box: CGSize(width: 34, height: 46)) { context in
                context.addEllipse(in: CGRect(x: 5, y: 31.2, width: 12.7, height: 12))
                context.addPath(CGPath(roundedRect: CGRect(x: 15.12, y: 5.5, width: 2.63, height: 31.5), cornerWidth: 0.6, cornerHeight: 0.6, transform: nil))
                context.addPath(roundedPolygon([(15.12, 6.3, 0.8), (29, 3.1, 1.3), (29, 12.9, 1.3), (16, 16.1, 0.8)]))
                context.fillPath()
            }
        default:
            return nil
        }
    }

    /// Two strands that cross between straight ends, with an arrowhead on each right end.
    private static func shuffle(
        referenceSize: CGFloat, box: CGSize, stroke: CGFloat, strands: (top: CGFloat, bottom: CGFloat), leadIn: CGFloat,
        curve: (start: CGFloat, control1: CGFloat, control2: CGFloat, end: CGFloat),
        arrowBase: CGFloat, arrowTip: CGFloat, arrowHalf: CGFloat, arrowRadius: CGFloat,
    ) -> Shape {
        Shape(referenceSize: referenceSize, box: box) { context in
            context.setLineWidth(stroke)
            for (from, to) in [(strands.top, strands.bottom), (strands.bottom, strands.top)] {
                context.move(to: CGPoint(x: leadIn, y: from))
                context.addLine(to: CGPoint(x: curve.start, y: from))
                context.addCurve(to: CGPoint(x: curve.end, y: to), control1: CGPoint(x: curve.control1, y: from), control2: CGPoint(x: curve.control2, y: to))
                context.addLine(to: CGPoint(x: arrowBase + stroke, y: to))
                context.strokePath()
            }
            for y in [strands.top, strands.bottom] {
                context.addPath(roundedPolygon([(arrowBase, y - arrowHalf, arrowRadius), (arrowTip, y, arrowRadius), (arrowBase, y + arrowHalf, arrowRadius)]))
            }
            context.fillPath()
        }
    }

    /// A closed polygon whose corners are rounded with their own radii.
    private static func roundedPolygon(_ corners: [(x: CGFloat, y: CGFloat, radius: CGFloat)]) -> CGPath {
        let path = CGMutablePath()
        guard let last = corners.last, let first = corners.first else { return path }
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for (index, corner) in corners.enumerated() {
            let next = corners[(index + 1) % corners.count]
            path.addArc(tangent1End: CGPoint(x: corner.x, y: corner.y), tangent2End: CGPoint(x: next.x, y: next.y), radius: corner.radius)
        }
        path.closeSubpath()
        return path
    }
}
