import CPortable
import Foundation

public enum CGImageAlphaInfo: UInt32, Sendable {
    case none = 0
    case premultipliedLast = 1
    case premultipliedFirst = 2
    case last = 3
    case first = 4
    case noneSkipLast = 5
    case noneSkipFirst = 6
    case alphaOnly = 7
}

public struct CGBitmapInfo: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let alphaInfoMask = CGBitmapInfo(rawValue: 0x1F)
    public static let floatInfoMask = CGBitmapInfo(rawValue: 0xF00)
    public static let floatComponents = CGBitmapInfo(rawValue: 1 << 8)
    public static let byteOrderMask = CGBitmapInfo(rawValue: 0x7000)
    public static let byteOrderDefault = CGBitmapInfo([])
    public static let byteOrder16Little = CGBitmapInfo(rawValue: 1 << 12)
    public static let byteOrder32Little = CGBitmapInfo(rawValue: 2 << 12)
    public static let byteOrder16Big = CGBitmapInfo(rawValue: 3 << 12)
    public static let byteOrder32Big = CGBitmapInfo(rawValue: 4 << 12)

    public init(alphaInfo: CGImageAlphaInfo) {
        rawValue = alphaInfo.rawValue
    }
}

public enum CGInterpolationQuality: Int32, Sendable {
    case `default` = 0
    case none = 1
    case low = 2
    case medium = 4
    case high = 3
}

/// Pixels owned by an image or a context: premultiplied BGRA, top row first.
public final class PixelStorage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let bytes: UnsafeMutablePointer<UInt8>

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        bytesPerRow = self.width * 4
        let count = max(1, bytesPerRow * self.height)
        // Memory the system hands over already cleared: clearing it here as well touched
        // every byte of every bitmap before anything was drawn in it.
        bytes = calloc(count, 1)!.assumingMemoryBound(to: UInt8.self)
    }

    public init(copying source: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow sourceStride: Int) {
        self.width = width
        self.height = height
        bytesPerRow = width * 4
        let count = max(1, bytesPerRow * height)
        bytes = malloc(count)!.assumingMemoryBound(to: UInt8.self)
        for row in 0 ..< height {
            (bytes + row * bytesPerRow).update(from: source + row * sourceStride, count: bytesPerRow)
        }
    }

    deinit {
        free(bytes)
    }

    public var byteCount: Int { bytesPerRow * height }
}

/// Lets a renderer attach a GPU copy to an image and hear when the image goes away.
public protocol CGImageRendererResource: AnyObject {}

public final class CGImage: @unchecked Sendable, Hashable {
    public let storage: PixelStorage
    public let colorSpace: CGColorSpace?
    public let alphaInfo: CGImageAlphaInfo
    /// A grey image without alpha masks by brightness; anything else masks by alpha.
    public let isOpaqueGray: Bool
    public let identifier: Int
    /// Set by the compositor; dropped with the image.
    public var rendererResource: CGImageRendererResource?

    private static let counter = Counter()

    public init(storage: PixelStorage, colorSpace: CGColorSpace?, alphaInfo: CGImageAlphaInfo) {
        self.storage = storage
        self.colorSpace = colorSpace
        self.alphaInfo = alphaInfo
        isOpaqueGray = colorSpace?.model == .monochrome && (alphaInfo == .none || alphaInfo == .noneSkipLast || alphaInfo == .noneSkipFirst)
        identifier = Self.counter.next()
    }

    public var width: Int { storage.width }
    public var height: Int { storage.height }
    public var bytesPerRow: Int { storage.bytesPerRow }
    public var bitsPerComponent: Int { 8 }
    public var bitsPerPixel: Int { 32 }
    public var bitmapInfo: CGBitmapInfo { CGBitmapInfo(rawValue: alphaInfo.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) }
    public var isMask: Bool { false }
    public var shouldInterpolate: Bool { true }

    public func cropping(to rect: CGRect) -> CGImage? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        let x = Int(r.minX), y = Int(r.minY)
        let cropped = PixelStorage(copying: storage.bytes + y * storage.bytesPerRow + x * 4, width: Int(r.width), height: Int(r.height), bytesPerRow: storage.bytesPerRow)
        return CGImage(storage: cropped, colorSpace: colorSpace, alphaInfo: alphaInfo)
    }

    public func copy() -> CGImage? { self }

    /// Decodes PNG, JPEG, GIF, BMP and similar files.
    public static func decode(_ data: Data) -> CGImage? {
        data.withUnsafeBytes { raw -> CGImage? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var width: Int32 = 0
            var height: Int32 = 0
            guard let rgba = fr_image_decode(base, Int32(raw.count), &width, &height) else { return nil }
            defer { fr_image_free(rgba) }
            let storage = PixelStorage(width: Int(width), height: Int(height))
            fr_rgba_to_premultiplied_bgra(rgba, storage.bytes, width, height, width * 4, Int32(storage.bytesPerRow))
            return CGImage(storage: storage, colorSpace: CGColorSpace(name: CGColorSpace.sRGB), alphaInfo: .premultipliedFirst)
        }
    }

    public static func pixelSize(of data: Data) -> CGSize? {
        data.withUnsafeBytes { raw -> CGSize? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var width: Int32 = 0
            var height: Int32 = 0
            guard fr_image_info(base, Int32(raw.count), &width, &height) != 0 else { return nil }
            return CGSize(width: Int(width), height: Int(height))
        }
    }

    /// A copy scaled to `width` by `height` pixels with a box filter.
    public func resized(width newWidth: Int, height newHeight: Int) -> CGImage? {
        guard newWidth > 0, newHeight > 0 else { return nil }
        if newWidth == width, newHeight == height { return self }
        let output = PixelStorage(width: newWidth, height: newHeight)
        fr_resize_bgra(storage.bytes, Int32(width), Int32(height), Int32(bytesPerRow), output.bytes, Int32(newWidth), Int32(newHeight), Int32(output.bytesPerRow))
        return CGImage(storage: output, colorSpace: colorSpace, alphaInfo: alphaInfo)
    }

    /// Writes the image as a PNG, for screenshots and tests.
    @discardableResult
    public func writePNG(to url: URL) -> Bool {
        let rgba = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, width * height * 4))
        defer { rgba.deallocate() }
        for y in 0 ..< height {
            let source = storage.bytes + y * bytesPerRow
            let target = rgba + y * width * 4
            for x in 0 ..< width {
                let b = source[x * 4], g = source[x * 4 + 1], r = source[x * 4 + 2], a = source[x * 4 + 3]
                func unpremultiply(_ c: UInt8) -> UInt8 {
                    a == 0 ? 0 : UInt8(min(255, (Int(c) * 255 + Int(a) / 2) / Int(a)))
                }
                target[x * 4] = unpremultiply(r)
                target[x * 4 + 1] = unpremultiply(g)
                target[x * 4 + 2] = unpremultiply(b)
                target[x * 4 + 3] = a
            }
        }
        return fr_png_write(url.path, rgba, Int32(width), Int32(height), Int32(width * 4)) != 0
    }

    public static func == (lhs: CGImage, rhs: CGImage) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
