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

/// A picture, as AppKit's NSImage is used by First Row: loaded from the app's assets or a
/// file, and handed to layers as a CGImage.
public final class NSImage: LayerContentsProviding, @unchecked Sendable {
    public let cgImage: CGImage?
    /// The size in points.
    public var size: CGSize

    public init(cgImage: CGImage, size: CGSize) {
        self.cgImage = cgImage
        self.size = size == .zero ? CGSize(width: cgImage.width, height: cgImage.height) : size
    }

    public init?(data: Data) {
        guard let image = CGImageSourceCreateWithData(data, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { return nil }
        cgImage = image
        size = CGSize(width: image.width, height: image.height)
    }

    public convenience init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    public convenience init?(contentsOfFile path: String) {
        self.init(contentsOf: URL(fileURLWithPath: path))
    }

    /// An image from the app's asset catalogue, by its set's name.
    public convenience init?(named name: String) {
        guard let (image, scale) = AssetCatalog.image(named: name) else { return nil }
        self.init(cgImage: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

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

/// Reads images straight out of Assets.xcassets, which is shipped next to the app.
public enum AssetCatalog {
    nonisolated(unsafe) private static var cache: [String: (CGImage, CGFloat)] = [:]
    private static let lock = NSLock()

    static func image(named name: String) -> (CGImage, CGFloat)? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
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
