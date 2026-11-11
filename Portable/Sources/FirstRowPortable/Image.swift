@_exported import Combine
@_exported import CoreGraphics
@_exported import CoreImage
@_exported import CoreText
@_exported import ImageIO
@_exported import QuartzCore
import Foundation
#if canImport(FoundationXML)
    @_exported import FoundationXML
#endif
#if canImport(FoundationNetworking)
    @_exported import FoundationNetworking
#endif

/// Lets an initialiser hand back an object that already exists.
public protocol ExistingObjectInitializable {}

public extension ExistingObjectInitializable {
    init(existing: Self) { self = existing }
}

/// A picture, as AppKit's NSImage is used by First Row: loaded from the app's assets or a
/// file, and handed to layers as a CGImage.
public final class NSImage: LayerContentsProviding, ExistingObjectInitializable, @unchecked Sendable {
    /// The picture's pixels. One made from a file's bytes is decoded when they're first asked
    /// for, as AppKit's is, and may be decoded again later (see `DecodedPictures`).
    public var cgImage: CGImage? {
        if let pixels { return pixels }
        guard let encoded else { return nil }
        return DecodedPictures.shared.image(for: self) {
            CGImageSourceCreateWithData(encoded, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }
    }

    private let pixels: CGImage?
    private let encoded: Data?
    /// The size in points.
    public var size: CGSize

    public init(cgImage: CGImage, size: CGSize) {
        pixels = cgImage
        encoded = nil
        self.size = size == .zero ? CGSize(width: cgImage.width, height: cgImage.height) : size
    }

    /// A picture from a file's bytes. Only its size is read now: a music library has a cover
    /// in every song, and decoding each as it was found took gigabytes.
    public init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }
        // Turned on its side by its EXIF orientation, its width and height swap.
        let turned = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        pixels = nil
        encoded = data
        size = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    deinit {
        if encoded != nil { DecodedPictures.shared.forget(ObjectIdentifier(self)) }
    }

    public convenience init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    public convenience init?(contentsOfFile path: String) {
        self.init(contentsOf: URL(fileURLWithPath: path))
    }

    /// An image from the app's asset catalogue, by its set's name: the same object every time
    /// for the same name, as AppKit gives. First Row tells pictures apart by object, so a new
    /// one each time would have everything made from a picture (reflections, blurred copies,
    /// textures) made again on every pass.
    public convenience init?(named name: String) {
        Self.namedLock.lock()
        let known = Self.named[name]
        Self.namedLock.unlock()
        if let known {
            self.init(existing: known)
            return
        }
        guard let (image, scale) = AssetCatalog.image(named: name) else { return nil }
        let made = NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        Self.namedLock.lock()
        let kept = Self.named[name] ?? made
        Self.named[name] = kept
        Self.namedLock.unlock()
        self.init(existing: kept)
    }

    nonisolated(unsafe) private static var named: [String: NSImage] = [:]
    private static let namedLock = NSLock()

    public func cgImage(forProposedRect _: UnsafeMutablePointer<CGRect>?, context _: AnyObject?, hints _: [AnyHashable: Any]?) -> CGImage? {
        cgImage
    }

    public var layerContents: CGImage? { cgImage }

    /// PNG bytes of the picture.
    public func pngData() -> Data? {
        guard let cgImage else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("firstrow-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        guard cgImage.writePNG(to: url) else { return nil }
        return try? Data(contentsOf: url)
    }
}

/// The decoded pixels of pictures made from files' bytes. They're kept while they're in use
/// (whatever draws a picture asks for its pixels every frame) up to a budget, past which the
/// ones asked for longest ago are let go, to be decoded again if they're ever wanted.
final class DecodedPictures: @unchecked Sendable {
    static let shared = DecodedPictures()

    private struct Entry {
        let image: CGImage
        let bytes: Int
        var lastUse: UInt64
        var lastUseTime: CFTimeInterval
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    private let budget = 96 * 1024 * 1024

    func image(for picture: NSImage, decode: () -> CGImage?) -> CGImage? {
        let id = ObjectIdentifier(picture)
        lock.lock()
        clock += 1
        if entries[id] != nil {
            entries[id]!.lastUse = clock
            entries[id]!.lastUseTime = CACurrentMediaTime()
            let image = entries[id]!.image
            lock.unlock()
            return image
        }
        lock.unlock()
        // Decoding takes milliseconds: not under the lock.
        guard let image = decode() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let other = entries[id] { return other.image }
        let size = image.bytesPerRow * image.height
        let now = CACurrentMediaTime()
        entries[id] = Entry(image: image, bytes: size, lastUse: clock, lastUseTime: now)
        bytes += size
        // Past the budget the ones asked for longest ago go, but never one asked for in the last
        // few seconds: what's on screen is asked for every frame, and letting it go would have
        // it decoded again for the next.
        while bytes > budget, entries.count > 1, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }),
              oldest.key != id, now - oldest.value.lastUseTime > 3
        {
            bytes -= oldest.value.bytes
            entries[oldest.key] = nil
        }
        return image
    }

    func forget(_ id: ObjectIdentifier) {
        lock.lock()
        if let entry = entries.removeValue(forKey: id) { bytes -= entry.bytes }
        lock.unlock()
    }
}

/// Reads images straight out of Assets.xcassets, which is shipped next to the app.
public enum AssetCatalog {
    nonisolated(unsafe) private static var cache: [String: (CGImage, CGFloat)] = [:]
    private static let lock = NSLock()

    /// Decodes every picture in the catalogue on another thread, so that the main thread
    /// finds each one ready when it's first drawn. Started as First Row starts: the window
    /// and the first frame are some way off then, and a menu icon takes several milliseconds.
    public static func decodeAhead() {
        Thread.detachNewThread {
            guard let catalogue = AppResources.url("Assets.xcassets"),
                  let sets = try? FileManager.default.contentsOfDirectory(atPath: catalogue.path)
            else { return }
            for set in sets.sorted() where set.hasSuffix(".imageset") {
                _ = image(named: String(set.dropLast(".imageset".count)))
            }
        }
    }

    static func image(named name: String) -> (CGImage, CGFloat)? {
        lock.lock()
        let known = cache[name]
        lock.unlock()
        if let known { return known }
        // Decoded outside the lock, so the main thread never waits for another picture's turn.
        let set = AppResources.url("Assets.xcassets/\(name).imageset")
        guard let set,
              let json = try? Data(contentsOf: set.appendingPathComponent("Contents.json")),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let entries = object["images"] as? [[String: Any]]
        else { return nil }
        // The sharpest variant wins.
        let candidates = entries.compactMap { entry -> (String, CGFloat)? in
            guard let file = entry["filename"] as? String else { return nil }
            let scale = (entry["scale"] as? String).flatMap { Double($0.replacingOccurrences(of: "x", with: "")) } ?? 1
            return (file, CGFloat(scale))
        }.sorted { $0.1 > $1.1 }
        for (file, scale) in candidates {
            if let data = try? Data(contentsOf: set.appendingPathComponent(file)), let image = CGImage.decode(data) {
                lock.lock()
                defer { lock.unlock() }
                // (Another thread may have decoded it meanwhile: that one is the one in use.)
                if let other = cache[name] { return other }
                cache[name] = (image, scale)
                return (image, scale)
            }
        }
        return nil
    }
}

/// Finds the files the Mac app keeps in its bundle: next to the executable, in a Resources
/// folder, or (when run from a checkout) in the source tree.
public enum AppResources {
    nonisolated(unsafe) public static var overrideRoot: URL?

    public static var roots: [URL] {
        var roots: [URL] = []
        if let overrideRoot { roots.append(overrideRoot) }
        if let custom = ProcessInfo.processInfo.environment["FIRSTROW_RESOURCES"] {
            roots.append(URL(fileURLWithPath: custom, isDirectory: true))
        }
        let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let executable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().deletingLastPathComponent()
        roots.append(executable.appendingPathComponent("Resources", isDirectory: true))
        roots.append(executable)
        // A development build sits in .build/<config>/ inside the checkout.
        var parent = executable
        for _ in 0 ..< 5 {
            parent = parent.deletingLastPathComponent()
            roots.append(parent.appendingPathComponent("firstrow", isDirectory: true))
        }
        return roots
    }

    public static func url(_ relativePath: String) -> URL? {
        for root in roots {
            let candidate = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Like Bundle.main.url(forResource:withExtension:), searching the folders First Row ships.
    public static func url(forResource name: String?, withExtension ext: String?) -> URL? {
        guard let name else { return nil }
        let file = ext.map { "\(name).\($0)" } ?? name
        for folder in ["", "Sounds/", "Videos/", "Resources/"] {
            if let url = url(folder + file) { return url }
        }
        return nil
    }

    /// The folder holding bundled resources, for code that lists them.
    public static var resourceURL: URL? {
        roots.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Assets.xcassets").path) }
    }
}
