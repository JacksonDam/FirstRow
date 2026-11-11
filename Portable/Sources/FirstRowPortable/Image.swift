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
        guard encoded != nil || readAgain != nil else { return nil }
        return DecodedPictures.shared.image(for: self) {
            guard let bytes = encoded ?? readAgain?(), let source = CGImageSourceCreateWithData(bytes, nil) else { return nil }
            guard let longestSide else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
            let options: [CFString: Any] = [kCGImageSourceThumbnailMaxPixelSize: longestSide]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
    }

    private let pixels: CGImage?
    private let encoded: Data?
    /// Fetches the file's bytes, for a picture that doesn't keep them.
    private let readAgain: (@Sendable () -> Data?)?
    /// The most pixels across or down that it's decoded at; nil for as many as the file has.
    private let longestSide: Int?
    /// The size in points.
    public var size: CGSize

    public init(cgImage: CGImage, size: CGSize) {
        pixels = cgImage
        encoded = nil
        readAgain = nil
        longestSide = nil
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
        readAgain = nil
        longestSide = nil
        size = turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// A picture from a file's bytes that doesn't keep them: `readAgain` fetches them whenever
    /// its pixels are wanted, and they're decoded no larger than `longestSide` pixels. For the
    /// covers of a music library: each is in its songs' files, often a megabyte and
    /// thousands of pixels across, and kept in memory there's one for every album.
    public init?(data: Data, longestSide: Int, readAgain: @escaping @Sendable () -> Data?) {
        guard let source = CGImageSourceCreateWithData(data, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, longestSide > 0
        else { return nil }
        let turned = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        // (As it will be decoded: scaled down to that size if it's larger, upright.)
        let scale = min(1, CGFloat(longestSide) / CGFloat(max(width, height)))
        let across = max(1, Int((CGFloat(turned ? height : width) * scale).rounded()))
        let down = max(1, Int((CGFloat(turned ? width : height) * scale).rounded()))
        pixels = nil
        encoded = nil
        self.readAgain = readAgain
        self.longestSide = longestSide
        size = CGSize(width: across, height: down)
    }

    deinit {
        if pixels == nil { DecodedPictures.shared.forget(ObjectIdentifier(self)) }
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

/// The decoded pixels of pictures made from files' bytes. They're kept while they're asked
/// for, up to a budget, past which the ones asked for longest ago are let go; and one not
/// asked for in a while is let go whatever the budget. A picture let go of is decoded again
/// if it's wanted again, unless something (a layer showing it) has kept it meanwhile: then
/// that same one is handed back.
final class DecodedPictures: @unchecked Sendable {
    static let shared = DecodedPictures()

    private struct Entry {
        let image: CGImage
        let bytes: Int
        var lastUse: UInt64
        var lastUseTime: CFTimeInterval
    }

    /// A picture let go of: there for as long as something else holds it.
    private struct LetGo {
        weak var image: CGImage?
        let bytes: Int
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var letGo: [ObjectIdentifier: LetGo] = [:]
    private var clock: UInt64 = 0
    private var bytes = 0
    private let budget = 96 * 1024 * 1024
    /// Past this much, the pictures nothing has asked for in a while are let go. (Under it
    /// they stay: one shown again is there at once, where decoding it again would take the
    /// main thread some milliseconds.)
    private let restingBudget = 32 * 1024 * 1024

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
        if let past = letGo.removeValue(forKey: id), let image = past.image {
            // Still on a layer somewhere: the same pixels, and the texture made of them.
            entries[id] = Entry(image: image, bytes: past.bytes, lastUse: clock, lastUseTime: CACurrentMediaTime())
            bytes += past.bytes
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
            letGo[oldest.key] = LetGo(image: oldest.value.image, bytes: oldest.value.bytes)
            entries[oldest.key] = nil
        }
        return image
    }

    func forget(_ id: ObjectIdentifier) {
        lock.lock()
        if let entry = entries.removeValue(forKey: id) { bytes -= entry.bytes }
        letGo[id] = nil
        lock.unlock()
    }

    /// Lets go of pictures nothing has asked for in a while, longest ago first, while there
    /// are more than the resting budget. Without this the pictures of every list passed
    /// through stayed decoded, with their textures, until 96 MB of others had pushed them
    /// out. (One on a layer that is still on screen stays, held by the layer, and is found
    /// again when next asked for.)
    func releaseIdle(after seconds: CFTimeInterval = 20) {
        let now = CACurrentMediaTime()
        // (They are let go of once the lock is: freeing a large bitmap is a system call.)
        var released: [CGImage] = []
        lock.lock()
        letGo = letGo.filter { $0.value.image != nil }
        if bytes > restingBudget {
            let idle = entries.filter { now - $0.value.lastUseTime > seconds }.sorted { $0.value.lastUse < $1.value.lastUse }
            for (id, entry) in idle {
                guard bytes > restingBudget else { break }
                bytes -= entry.bytes
                released.append(entry.image)
                letGo[id] = LetGo(image: entry.image, bytes: entry.bytes)
                entries[id] = nil
            }
        }
        lock.unlock()
        released.removeAll()
    }
}

public extension NSImage {
    /// Lets go of decoded pictures that haven't been shown for a while; called now and then.
    static func releaseIdlePictures() {
        DecodedPictures.shared.releaseIdle()
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
