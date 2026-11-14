import Foundation

public enum CGColorSpaceModel: Int32, Sendable {
    case unknown = -1
    case monochrome = 0
    case rgb = 1
}

/// Colour spaces are tags here: everything is drawn as 8-bit sRGB, as First Row's bitmaps are.
public final class CGColorSpace: @unchecked Sendable {
    public let name: CFString?
    public let model: CGColorSpaceModel

    public static let sRGB: CFString = "kCGColorSpaceSRGB"
    public static let genericRGBLinear: CFString = "kCGColorSpaceGenericRGBLinear"
    public static let linearSRGB: CFString = "kCGColorSpaceLinearSRGB"
    public static let extendedSRGB: CFString = "kCGColorSpaceExtendedSRGB"
    public static let displayP3: CFString = "kCGColorSpaceDisplayP3"
    public static let genericGrayGamma2_2: CFString = "kCGColorSpaceGenericGrayGamma2_2"
    public static let linearGray: CFString = "kCGColorSpaceLinearGray"
    public static let extendedGray: CFString = "kCGColorSpaceExtendedGray"
    public static let genericRGB: CFString = "kCGColorSpaceGenericRGB"
    public static let genericGray: CFString = "kCGColorSpaceGenericGray"

    public init?(name: CFString) {
        self.name = name
        model = name.localizedCaseInsensitiveContains("gray") ? .monochrome : .rgb
    }

    init(model: CGColorSpaceModel) {
        name = model == .monochrome ? Self.genericGrayGamma2_2 : Self.sRGB
        self.model = model
    }

    public var numberOfComponents: Int { model == .monochrome ? 1 : 3 }

    static let rgb = CGColorSpace(model: .rgb)
    static let gray = CGColorSpace(model: .monochrome)
}

public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace { .rgb }
public func CGColorSpaceCreateDeviceGray() -> CGColorSpace { .gray }

public final class CGColor: @unchecked Sendable, Equatable, Hashable {
    /// Red, green, blue and alpha, straight (not premultiplied).
    public let rgba: (CGFloat, CGFloat, CGFloat, CGFloat)
    public let colorSpace: CGColorSpace?
    private let storedComponents: [CGFloat]

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        rgba = (red, green, blue, alpha)
        colorSpace = .rgb
        storedComponents = [red, green, blue, alpha]
    }

    public convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    public init(gray: CGFloat, alpha: CGFloat) {
        rgba = (gray, gray, gray, alpha)
        colorSpace = .gray
        storedComponents = [gray, alpha]
    }

    public convenience init(genericGrayGamma2_2Gray gray: CGFloat, alpha: CGFloat) {
        self.init(gray: gray, alpha: alpha)
    }

    private init?(colorSpace: CGColorSpace, values: [CGFloat]) {
        guard values.count >= colorSpace.numberOfComponents + 1 else { return nil }
        self.colorSpace = colorSpace
        storedComponents = values
        if colorSpace.model == .monochrome {
            rgba = (values[0], values[0], values[0], values[1])
        } else {
            rgba = (values[0], values[1], values[2], values[3])
        }
    }

    public convenience init?(colorSpace: CGColorSpace, components: UnsafePointer<CGFloat>) {
        let count = colorSpace.numberOfComponents + 1
        self.init(colorSpace: colorSpace, values: Array(UnsafeBufferPointer(start: components, count: count)))
    }

    public convenience init?(colorSpace: CGColorSpace, components: [CGFloat]) {
        self.init(colorSpace: colorSpace, values: components)
    }

    public var components: [CGFloat]? { storedComponents }
    public var numberOfComponents: Int { storedComponents.count }
    public var alpha: CGFloat { rgba.3 }

    public func copy(alpha: CGFloat) -> CGColor? {
        CGColor(red: rgba.0, green: rgba.1, blue: rgba.2, alpha: alpha)
    }

    public func converted(to _: CGColorSpace, intent _: CGColorRenderingIntent, options _: CFDictionary?) -> CGColor? {
        CGColor(red: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3)
    }

    public static let black = CGColor(gray: 0, alpha: 1)
    public static let white = CGColor(gray: 1, alpha: 1)
    public static let clear = CGColor(gray: 0, alpha: 0)

    public static func == (lhs: CGColor, rhs: CGColor) -> Bool {
        lhs.rgba.0 == rhs.rgba.0 && lhs.rgba.1 == rhs.rgba.1 && lhs.rgba.2 == rhs.rgba.2 && lhs.rgba.3 == rhs.rgba.3
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rgba.0)
        hasher.combine(rgba.1)
        hasher.combine(rgba.2)
        hasher.combine(rgba.3)
    }

    /// Premultiplied, clamped to 0...1.
    public var premultiplied: (Float, Float, Float, Float) {
        let a = Float(max(0, min(1, rgba.3)))
        return (Float(max(0, min(1, rgba.0))) * a, Float(max(0, min(1, rgba.1))) * a, Float(max(0, min(1, rgba.2))) * a, a)
    }
}

public enum CGColorRenderingIntent: Int32, Sendable {
    case defaultIntent
    case absoluteColorimetric
    case relativeColorimetric
    case perceptual
    case saturation
}

public func CGColorEqualToColor(_ a: CGColor?, _ b: CGColor?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case let (a?, b?): a == b
    default: false
    }
}
