@_exported import CoreGraphics
import Foundation

// Image decoding with the bundled codecs, behind the ImageIO calls First Row makes.

public let kCGImageSourceShouldCache: CFString = "kCGImageSourceShouldCache"
public let kCGImageSourceShouldCacheImmediately: CFString = "kCGImageSourceShouldCacheImmediately"
public let kCGImageSourceThumbnailMaxPixelSize: CFString = "kCGImageSourceThumbnailMaxPixelSize"
public let kCGImageSourceCreateThumbnailWithTransform: CFString = "kCGImageSourceCreateThumbnailWithTransform"
public let kCGImageSourceCreateThumbnailFromImageAlways: CFString = "kCGImageSourceCreateThumbnailFromImageAlways"
public let kCGImageSourceCreateThumbnailFromImageIfAbsent: CFString = "kCGImageSourceCreateThumbnailFromImageIfAbsent"
public let kCGImagePropertyPixelWidth: CFString = "PixelWidth"
public let kCGImagePropertyPixelHeight: CFString = "PixelHeight"
public let kCGImagePropertyOrientation: CFString = "Orientation"

public final class CGImageSource: @unchecked Sendable {
    let data: Data
    private var decoded: CGImage?
    private let lock = NSLock()

    init(data: Data) {
        self.data = data
    }

    func image() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let decoded { return decoded }
        guard var image = CGImage.decode(data) else { return nil }
        let orientation = ExifOrientation.read(data)
        if orientation > 1, let rotated = ExifOrientation.apply(orientation, to: image) {
            image = rotated
        }
        decoded = image
        return image
    }
}

public func CGImageSourceCreateWithURL(_ url: CFURL, _: CFDictionary?) -> CGImageSource? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return nil }
    return CGImageSource(data: data)
}

public func CGImageSourceCreateWithData(_ data: CFData, _: CFDictionary?) -> CGImageSource? {
    guard !data.isEmpty else { return nil }
    return CGImageSource(data: data)
}

public func CGImageSourceGetCount(_ source: CGImageSource) -> Int {
    CGImage.pixelSize(of: source.data) == nil ? 0 : 1
}

public func CGImageSourceCreateImageAtIndex(_ source: CGImageSource, _ index: Int, _: CFDictionary?) -> CGImage? {
    guard index == 0 else { return nil }
    return source.image()
}

public func CGImageSourceCreateThumbnailAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
    guard index == 0, let image = source.image() else { return nil }
    let maxPixels = (options?[kCGImageSourceThumbnailMaxPixelSize] as? NSNumber)?.intValue
        ?? (options?[kCGImageSourceThumbnailMaxPixelSize] as? Int)
        ?? (options?[kCGImageSourceThumbnailMaxPixelSize] as? CGFloat).map { Int($0) }
    guard let maxPixels, maxPixels > 0, max(image.width, image.height) > maxPixels else { return image }
    let scale = CGFloat(maxPixels) / CGFloat(max(image.width, image.height))
    return image.resized(width: max(1, Int((CGFloat(image.width) * scale).rounded())), height: max(1, Int((CGFloat(image.height) * scale).rounded())))
}

public func CGImageSourceCopyPropertiesAtIndex(_ source: CGImageSource, _: Int, _: CFDictionary?) -> CFDictionary? {
    guard let size = CGImage.pixelSize(of: source.data) else { return nil }
    return [
        kCGImagePropertyPixelWidth: NSNumber(value: Int(size.width)),
        kCGImagePropertyPixelHeight: NSNumber(value: Int(size.height)),
        kCGImagePropertyOrientation: NSNumber(value: ExifOrientation.read(source.data)),
    ]
}

/// Reads the EXIF orientation of a JPEG, and turns pixels upright.
enum ExifOrientation {
    static func read(_ data: Data) -> Int {
        let bytes = [UInt8](data.prefix(65536))
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return 1 }
        var index = 2
        while index + 4 < bytes.count {
            guard bytes[index] == 0xFF else { return 1 }
            let marker = bytes[index + 1]
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if marker == 0xE1, index + 10 < bytes.count, bytes[index + 4 ..< index + 8].elementsEqual([0x45, 0x78, 0x69, 0x66]) {
                return parseTIFF(bytes, start: index + 10, end: min(bytes.count, index + 2 + length))
            }
            if marker == 0xDA { return 1 }
            index += 2 + length
        }
        return 1
    }

    private static func parseTIFF(_ b: [UInt8], start: Int, end: Int) -> Int {
        guard start + 8 <= end else { return 1 }
        let little = b[start] == 0x49
        func u16(_ i: Int) -> Int {
            guard i + 1 < end else { return 0 }
            return little ? Int(b[i]) | Int(b[i + 1]) << 8 : Int(b[i]) << 8 | Int(b[i + 1])
        }
        func u32(_ i: Int) -> Int {
            guard i + 3 < end else { return 0 }
            return little
                ? Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
                : Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        }
        let ifd = start + u32(start + 4)
        let count = u16(ifd)
        for entry in 0 ..< count {
            let at = ifd + 2 + entry * 12
            if u16(at) == 0x0112 {
                let value = u16(at + 8)
                return (1 ... 8).contains(value) ? value : 1
            }
        }
        return 1
    }

    static func apply(_ orientation: Int, to image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        let swaps = orientation >= 5
        let outWidth = swaps ? h : w
        let outHeight = swaps ? w : h
        let output = PixelStorage(width: outWidth, height: outHeight)
        let src = image.storage.bytes
        let dst = output.bytes
        for y in 0 ..< h {
            for x in 0 ..< w {
                let (nx, ny): (Int, Int) = switch orientation {
                case 2: (w - 1 - x, y)
                case 3: (w - 1 - x, h - 1 - y)
                case 4: (x, h - 1 - y)
                case 5: (y, x)
                case 6: (h - 1 - y, x)
                case 7: (h - 1 - y, w - 1 - x)
                case 8: (y, w - 1 - x)
                default: (x, y)
                }
                let s = src + y * image.bytesPerRow + x * 4
                let d = dst + ny * output.bytesPerRow + nx * 4
                d.update(from: s, count: 4)
            }
        }
        return CGImage(storage: output, colorSpace: image.colorSpace, alphaInfo: image.alphaInfo)
    }
}
