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
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
                  let image = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: nsWeight))
            else { return nil }
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
            guard let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: uiWeight)) else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = oversample
            let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.withTintColor(.white, renderingMode: .alwaysOriginal).draw(at: .zero)
            }
            guard let cgImage = rendered.cgImage else { return nil }
            return Symbol(image: cgImage, size: image.size, pixelSize: CGSize(width: cgImage.width, height: cgImage.height))
        #endif
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
        if contents as AnyObject? !== graphic.image {
            contents = graphic.image
        }
        contentsScale = graphic.scale
        let frame = graphic.imageFrame(at: origin)
        bounds = CGRect(origin: .zero, size: frame.size)
        position = CGPoint(x: frame.minX + frame.width * anchorPoint.x, y: frame.minY + frame.height * anchorPoint.y)
    }
}

/// Hand-drawn stand-ins for the SF Symbols First Row uses, for macOS 10.15.
enum SymbolFallback {
    static func symbol(_ name: String, pointSize: CGFloat, weight: SymbolRenderer.Weight, oversample: CGFloat) -> (image: CGImage, size: CGSize)? {
        let stroke: CGFloat = switch weight {
        case .regular: 0.09
        case .semibold: 0.11
        case .bold: 0.13
        case .heavy: 0.16
        }
        let p = pointSize
        let size: CGSize = switch name {
        case "chevron.right": CGSize(width: p * 0.55, height: p * 0.9)
        case "play.fill": CGSize(width: p * 0.8, height: p * 0.92)
        case "pause.fill": CGSize(width: p * 0.72, height: p * 0.9)
        case "shuffle": CGSize(width: p * 1.15, height: p * 0.82)
        case "speaker.wave.3.fill": CGSize(width: p * 1.4, height: p * 0.92)
        case "music.note": CGSize(width: p * 0.62, height: p * 0.98)
        default: .zero
        }
        guard size != .zero else { return nil }
        let width = Int(ceil(size.width * oversample))
        let height = Int(ceil(size.height * oversample))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
        ) else { return nil }
        // Draw in points with the origin at the top left.
        context.scaleBy(x: oversample, y: oversample)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let w = size.width
        let h = size.height
        let line = p * stroke
        switch name {
        case "chevron.right":
            context.setLineWidth(line)
            context.move(to: CGPoint(x: line, y: line))
            context.addLine(to: CGPoint(x: w - line, y: h * 0.5))
            context.addLine(to: CGPoint(x: line, y: h - line))
            context.strokePath()
        case "play.fill":
            context.move(to: CGPoint(x: 0, y: 0))
            context.addLine(to: CGPoint(x: w, y: h * 0.5))
            context.addLine(to: CGPoint(x: 0, y: h))
            context.closePath()
            context.fillPath()
        case "pause.fill":
            let bar = w * 0.36
            context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: bar, height: h), cornerWidth: bar * 0.2, cornerHeight: bar * 0.2, transform: nil))
            context.addPath(CGPath(roundedRect: CGRect(x: w - bar, y: 0, width: bar, height: h), cornerWidth: bar * 0.2, cornerHeight: bar * 0.2, transform: nil))
            context.fillPath()
        case "shuffle":
            context.setLineWidth(line)
            let head = h * 0.22
            // Two crossing paths ending in arrowheads on the right.
            context.move(to: CGPoint(x: 0, y: h * 0.22))
            context.addCurve(to: CGPoint(x: w - head, y: h * 0.78), control1: CGPoint(x: w * 0.45, y: h * 0.22), control2: CGPoint(x: w * 0.45, y: h * 0.78))
            context.move(to: CGPoint(x: 0, y: h * 0.78))
            context.addCurve(to: CGPoint(x: w - head, y: h * 0.22), control1: CGPoint(x: w * 0.45, y: h * 0.78), control2: CGPoint(x: w * 0.45, y: h * 0.22))
            context.strokePath()
            for y in [h * 0.22, h * 0.78] {
                context.move(to: CGPoint(x: w, y: y))
                context.addLine(to: CGPoint(x: w - head * 1.3, y: y - head))
                context.addLine(to: CGPoint(x: w - head * 1.3, y: y + head))
                context.closePath()
                context.fillPath()
            }
        case "speaker.wave.3.fill":
            let body = h * 0.62
            context.move(to: CGPoint(x: 0, y: h * 0.32))
            context.addLine(to: CGPoint(x: body * 0.38, y: h * 0.32))
            context.addLine(to: CGPoint(x: body, y: 0))
            context.addLine(to: CGPoint(x: body, y: h))
            context.addLine(to: CGPoint(x: body * 0.38, y: h * 0.68))
            context.addLine(to: CGPoint(x: 0, y: h * 0.68))
            context.closePath()
            context.fillPath()
            context.setLineWidth(line * 0.8)
            for (index, radius) in [h * 0.2, h * 0.34, h * 0.48].enumerated() {
                let center = CGPoint(x: body + h * 0.02, y: h * 0.5)
                let spread = CGFloat.pi / (index == 2 ? 3.2 : 3.6)
                context.addArc(center: center, radius: radius, startAngle: -spread, endAngle: spread, clockwise: false)
                context.strokePath()
            }
        case "music.note":
            let headRadius = w * 0.34
            context.addEllipse(in: CGRect(x: 0, y: h - headRadius * 1.6, width: headRadius * 2, height: headRadius * 1.6))
            context.fillPath()
            context.setLineWidth(line)
            context.move(to: CGPoint(x: headRadius * 2 - line * 0.5, y: h - headRadius * 0.8))
            context.addLine(to: CGPoint(x: headRadius * 2 - line * 0.5, y: line * 0.5))
            context.addLine(to: CGPoint(x: w - line * 0.5, y: h * 0.22))
            context.strokePath()
        default:
            break
        }
        guard let image = context.makeImage() else { return nil }
        return (image, size)
    }
}
