import Foundation
import ImageIO
import SwiftUI

final class DecodedDisplayArtworkCache {
    static let shared = DecodedDisplayArtworkCache()
    private struct Entry {
        let image: NSImage
        let cost: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var lruKeys: [String] = []
    private var totalCost: Int = 0
    private let maxEntries: Int = 240
    private let maxCostBytes: Int = 220 * 1024 * 1024
    func image(for key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.image
    }

    func store(_ image: NSImage, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        let cost = decodedArtworkImageCost(image)
        if let old = entries[key] {
            totalCost = max(0, totalCost - old.cost)
        }
        entries[key] = Entry(image: image, cost: cost)
        touch(key)
        totalCost += cost
        trimIfNeeded()
    }

    private func touch(_ key: String) {
        if let existingIndex = lruKeys.firstIndex(of: key) {
            lruKeys.remove(at: existingIndex)
        }
        lruKeys.append(key)
    }

    private func trimIfNeeded() {
        while entries.count > maxEntries || totalCost > maxCostBytes, !lruKeys.isEmpty {
            let keyToRemove = lruKeys.removeFirst()
            if let removed = entries.removeValue(forKey: keyToRemove) {
                totalCost = max(0, totalCost - removed.cost)
            }
        }
    }
}

func decodedArtworkCacheKey(sourceKey: String, maxPixelSize: CGFloat) -> String {
    let roundedMax = Int(max(1, maxPixelSize).rounded(.toNearestOrAwayFromZero))
    return "\(sourceKey)|\(roundedMax)"
}

func cachedDecodedDisplayArtworkImage(sourceKey: String, maxPixelSize: CGFloat) -> NSImage? {
    DecodedDisplayArtworkCache.shared.image(
        for: decodedArtworkCacheKey(sourceKey: sourceKey, maxPixelSize: maxPixelSize),
    )
}

func cachedDecodedDisplayArtworkImage(
    from data: Data,
    sourceKey: String,
    maxPixelSize: CGFloat = 900,
) -> NSImage? {
    let cacheKey = decodedArtworkCacheKey(sourceKey: sourceKey, maxPixelSize: maxPixelSize)
    if let cached = DecodedDisplayArtworkCache.shared.image(for: cacheKey) {
        return cached
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
        guard let fallback = NSImage(data: data) else { return nil }
        DecodedDisplayArtworkCache.shared.store(fallback, for: cacheKey)
        return fallback
    }
    guard let decoded = decodedDisplayArtworkImage(from: source, maxPixelSize: maxPixelSize) else {
        return nil
    }
    DecodedDisplayArtworkCache.shared.store(decoded, for: cacheKey)
    return decoded
}

func cachedDecodedDisplayArtworkImage(
    fromFileURL fileURL: URL,
    sourceKey: String? = nil,
    maxPixelSize: CGFloat = 900,
) -> NSImage? {
    let resolvedSourceKey = sourceKey ?? fileURL.standardizedFileURL.path
    let cacheKey = decodedArtworkCacheKey(sourceKey: resolvedSourceKey, maxPixelSize: maxPixelSize)
    if let cached = DecodedDisplayArtworkCache.shared.image(for: cacheKey) {
        return cached
    }
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
        guard let fallback = NSImage(contentsOf: fileURL) else { return nil }
        DecodedDisplayArtworkCache.shared.store(fallback, for: cacheKey)
        return fallback
    }
    guard let decoded = decodedDisplayArtworkImage(from: source, maxPixelSize: maxPixelSize) else {
        return nil
    }
    DecodedDisplayArtworkCache.shared.store(decoded, for: cacheKey)
    return decoded
}

func decodedDisplayArtworkImage(from source: CGImageSource, maxPixelSize: CGFloat) -> NSImage? {
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceShouldCache: true,
        kCGImageSourceThumbnailMaxPixelSize: max(400, Int(maxPixelSize)),
    ]
    if let downsampled = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
        let decoded = decompressedArtworkCGImage(from: downsampled)
        return NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
    }
    let fullImageOptions: [CFString: Any] = [
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceShouldCache: true,
    ]
    if let fullImage = CGImageSourceCreateImageAtIndex(source, 0, fullImageOptions as CFDictionary) {
        let decoded = decompressedArtworkCGImage(from: fullImage)
        return NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
    }
    return nil
}

func decompressedArtworkCGImage(from image: CGImage) -> CGImage {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return image }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(.init(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue,
    ) else {
        return image
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
}

func decodedArtworkImageCost(_ image: NSImage) -> Int {
    #if os(iOS) || os(tvOS)
        if let cgImage = image.cgImage {
            return max(1, cgImage.width * cgImage.height * 4)
        }
    #else
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return max(1, cgImage.width * cgImage.height * 4)
        }
    #endif
    return 4 * 1024 * 1024
}
