@_exported import CoreGraphics
import CPortable
import Foundation

// The filters First Row uses: a Gaussian blur on layers, and the blurred, slightly desaturated
// backdrop behind the movie resume prompt. Images are processed eagerly on the CPU.

public let kCIInputRadiusKey = "inputRadius"
public let kCIInputSaturationKey = "inputSaturation"
public let kCIInputBrightnessKey = "inputBrightness"
public let kCIInputContrastKey = "inputContrast"
public let kCIInputImageKey = "inputImage"

public final class CIFilter: NSObject, @unchecked Sendable {
    public let filterName: String
    /// The name a layer's key paths use for it, as in "filters.blur.inputRadius".
    public var name: String
    private var parameters: [String: Any] = [:]

    public init?(name: String) {
        filterName = name
        self.name = name
        super.init()
    }

    public init?(name: String, parameters: [String: Any]?) {
        filterName = name
        self.name = name
        super.init()
        if let parameters { self.parameters = parameters }
    }

    public func setValue(_ value: Any?, forKey key: String) {
        parameters[key] = value
    }

    public func value(forKey key: String) -> Any? {
        parameters[key]
    }
}

public struct CIFormat: Sendable {
    public static let BGRA8 = CIFormat()
    public static let RGBA8 = CIFormat()
}

public struct CIContextOption: Hashable, Sendable {
    public let rawValue: String
    public static let cacheIntermediates = CIContextOption(rawValue: "cacheIntermediates")
    public static let useSoftwareRenderer = CIContextOption(rawValue: "useSoftwareRenderer")
}

/// A picture with an extent in Core Image's y-up space.
public final class CIImage: @unchecked Sendable {
    let pixels: CGImage?
    /// Where the pixels sit; empty for an image with no content.
    public let extent: CGRect

    public init(cgImage: CGImage) {
        pixels = cgImage
        extent = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
    }

    init(pixels: CGImage?, extent: CGRect) {
        self.pixels = pixels
        self.extent = extent
    }

    /// Scales (and moves) the image, resampling it now.
    public func transformed(by transform: CGAffineTransform) -> CIImage {
        guard let pixels else { return self }
        let target = extent.applying(transform)
        let width = max(1, Int(target.width.rounded()))
        let height = max(1, Int(target.height.rounded()))
        guard let resized = pixels.resized(width: width, height: height) else { return self }
        return CIImage(pixels: resized, extent: CGRect(x: target.minX, y: target.minY, width: CGFloat(width), height: CGFloat(height)))
    }

    public func cropped(to rect: CGRect) -> CIImage {
        guard let pixels else { return self }
        let clipped = extent.intersection(rect).integral
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return CIImage(pixels: nil, extent: .zero) }
        // Pixel rows run top down; extent runs bottom up.
        let crop = CGRect(x: clipped.minX - extent.minX, y: extent.maxY - clipped.maxY, width: clipped.width, height: clipped.height)
        return CIImage(pixels: pixels.cropping(to: crop), extent: clipped)
    }

    /// Blurs with transparent pixels beyond the edges, growing the extent by three sigmas.
    public func applyingGaussianBlur(sigma: Double) -> CIImage {
        guard let pixels, sigma > 0 else { return self }
        let margin = Int(ceil(sigma * 3))
        let width = pixels.width + margin * 2
        let height = pixels.height + margin * 2
        let storage = PixelStorage(width: width, height: height)
        for row in 0 ..< pixels.height {
            (storage.bytes + (row + margin) * storage.bytesPerRow + margin * 4).update(from: pixels.storage.bytes + row * pixels.bytesPerRow, count: pixels.bytesPerRow)
        }
        fr_blur_bgra(storage.bytes, Int32(width), Int32(height), Int32(storage.bytesPerRow), Float(sigma))
        let image = CGImage(storage: storage, colorSpace: pixels.colorSpace, alphaInfo: .premultipliedFirst)
        return CIImage(pixels: image, extent: extent.insetBy(dx: -CGFloat(margin), dy: -CGFloat(margin)))
    }

    public func applyingFilter(_ name: String, parameters: [String: Any] = [:]) -> CIImage {
        guard let pixels else { return self }
        switch name {
        case "CIColorControls":
            let saturation = (parameters[kCIInputSaturationKey] as? NSNumber)?.doubleValue ?? (parameters[kCIInputSaturationKey] as? Double) ?? 1
            let brightness = (parameters[kCIInputBrightnessKey] as? NSNumber)?.doubleValue ?? (parameters[kCIInputBrightnessKey] as? Double) ?? 0
            let contrast = (parameters[kCIInputContrastKey] as? NSNumber)?.doubleValue ?? (parameters[kCIInputContrastKey] as? Double) ?? 1
            let storage = PixelStorage(copying: pixels.storage.bytes, width: pixels.width, height: pixels.height, bytesPerRow: pixels.bytesPerRow)
            let count = pixels.width * pixels.height
            let bytes = storage.bytes
            for index in 0 ..< count {
                let p = bytes + index * 4
                let a = Double(p[3]) / 255
                guard a > 0 else { continue }
                var b = Double(p[0]) / 255 / a, g = Double(p[1]) / 255 / a, r = Double(p[2]) / 255 / a
                let luma = 0.2125 * r + 0.7154 * g + 0.0721 * b
                r = luma + (r - luma) * saturation
                g = luma + (g - luma) * saturation
                b = luma + (b - luma) * saturation
                r = (r - 0.5) * contrast + 0.5 + brightness
                g = (g - 0.5) * contrast + 0.5 + brightness
                b = (b - 0.5) * contrast + 0.5 + brightness
                p[0] = UInt8(max(0, min(1, b)) * a * 255 + 0.5)
                p[1] = UInt8(max(0, min(1, g)) * a * 255 + 0.5)
                p[2] = UInt8(max(0, min(1, r)) * a * 255 + 0.5)
            }
            return CIImage(pixels: CGImage(storage: storage, colorSpace: pixels.colorSpace, alphaInfo: pixels.alphaInfo), extent: extent)
        case "CIGaussianBlur":
            let radius = (parameters[kCIInputRadiusKey] as? NSNumber)?.doubleValue ?? (parameters[kCIInputRadiusKey] as? Double) ?? 10
            return applyingGaussianBlur(sigma: radius)
        default:
            return self
        }
    }
}

public final class CIContext: @unchecked Sendable {
    public init(options _: [CIContextOption: Any]? = nil) {}

    public func createCGImage(_ image: CIImage, from rect: CGRect) -> CGImage? {
        createCGImage(image, from: rect, format: .BGRA8, colorSpace: nil)
    }

    public func createCGImage(_ image: CIImage, from rect: CGRect, format _: CIFormat, colorSpace _: CGColorSpace?) -> CGImage? {
        let width = max(1, Int(rect.width.rounded()))
        let height = max(1, Int(rect.height.rounded()))
        let storage = PixelStorage(width: width, height: height)
        if let pixels = image.pixels {
            // Copy the overlap; anything outside the image's extent stays clear.
            let source = image.extent
            for row in 0 ..< height {
                let y = rect.maxY - CGFloat(row) - 1
                let sourceRow = Int((source.maxY - 1 - y).rounded())
                guard sourceRow >= 0, sourceRow < pixels.height else { continue }
                for column in 0 ..< width {
                    let sourceColumn = Int((rect.minX + CGFloat(column) - source.minX).rounded())
                    guard sourceColumn >= 0, sourceColumn < pixels.width else { continue }
                    (storage.bytes + row * storage.bytesPerRow + column * 4).update(from: pixels.storage.bytes + sourceRow * pixels.bytesPerRow + sourceColumn * 4, count: 4)
                }
            }
        }
        return CGImage(storage: storage, colorSpace: CGColorSpace(name: CGColorSpace.sRGB), alphaInfo: .premultipliedFirst)
    }
}
