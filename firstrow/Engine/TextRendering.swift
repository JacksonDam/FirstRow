import CoreText
import QuartzCore
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

// Text and SF Symbols for the layer-drawn interface.
//
// Strings are typeset with Core Text into bitmaps (cached by content and size) that layers
// show as their contents, so text costs nothing to draw again until it changes. Line boxes
// follow AppKit's text metrics (ascent and descent each rounded), which is what the menus
// were laid out against.

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

/// A drop shadow or glow, as SwiftUI's `.shadow(color:radius:x:y:)` drew it.
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
    /// Single line: the widest the line may be before it shrinks (down to
    /// `minimumScaleFactor`) and then truncates with an ellipsis.
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

/// A rendered string or symbol. `size` is its layout box; the bitmap can extend past the box
/// (shadows, glows), by `imageInsets` on each side.
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

    static func width(_ text: String, fontName: String, size: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed(text, font: font(fontName, size: size), color: .white))
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
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
        cache.countLimit = 1500
        cache.totalCostLimit = 64 * 1024 * 1024
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
            // Shrink first, like SwiftUI's minimumScaleFactor, then cut the end off.
            if spec.minimumScaleFactor < 1 {
                let fittingSize = max(spec.size * spec.minimumScaleFactor, spec.size * (maxWidth / width))
                font = FontMetrics.font(spec.fontName, size: fittingSize)
                line = CTLineCreateWithAttributedString(FontMetrics.attributed(spec.text, font: font, color: spec.color))
                width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                // Keep the shrunken line centred on the original line box.
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

    /// Draws into a transparent bitmap of `size` (plus `padding` all round) at `scale`, with
    /// the shadows applied to whatever `body` draws. `body` works in points with y up.
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
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
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
        // Each shadow applies to everything drawn so far, like stacked SwiftUI `.shadow`s.
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
            guard #available(macOS 11.0, *) else { return nil }
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
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
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
