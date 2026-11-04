import AVFoundation
import Foundation
import ImageIO
import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

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

/// The picture embedded in a media file (MPEG-4 `covr`, ID3 `APIC` or QuickTime artwork), if any.
func loadEmbeddedArtworkData(from url: URL) async -> Data? {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
    var candidates: [AVMetadataItem] = []
    if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
        if let commonMetadata = try? await asset.load(.commonMetadata) {
            candidates = AVMetadataItem.metadataItems(from: commonMetadata, filteredByIdentifier: .commonIdentifierArtwork)
        }
        if candidates.isEmpty, let metadata = try? await asset.load(.metadata) {
            candidates = embeddedArtworkMetadataItems(in: metadata)
        }
    } else {
        candidates = AVMetadataItem.metadataItems(from: asset.commonMetadata, filteredByIdentifier: .commonIdentifierArtwork)
        if candidates.isEmpty {
            candidates = embeddedArtworkMetadataItems(in: asset.metadata)
        }
    }
    for item in candidates {
        if let data = await embeddedArtworkData(of: item), !data.isEmpty {
            return data
        }
    }
    return nil
}

private func embeddedArtworkMetadataItems(in metadata: [AVMetadataItem]) -> [AVMetadataItem] {
    let artworkIdentifiers: Set<AVMetadataIdentifier> = [
        .iTunesMetadataCoverArt,
        .id3MetadataAttachedPicture,
        .quickTimeMetadataArtwork,
        .commonIdentifierArtwork,
    ]
    return metadata.filter { item in
        guard let identifier = item.identifier else { return false }
        return artworkIdentifiers.contains(identifier)
    }
}

private func embeddedArtworkData(of item: AVMetadataItem) async -> Data? {
    let dataValue: Data?
    let rawValue: (NSCopying & NSObjectProtocol)?
    if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
        dataValue = try? await item.load(.dataValue)
        rawValue = dataValue == nil ? (try? await item.load(.value)) : nil
    } else {
        dataValue = item.dataValue
        rawValue = dataValue == nil ? item.value : nil
    }
    if let dataValue {
        return dataValue
    }
    if let data = rawValue as? Data {
        return data
    }
    // Older ID3 tags surface APIC frames as a dictionary with the picture under "data".
    if let dictionary = rawValue as? NSDictionary, let data = dictionary["data"] as? Data {
        return data
    }
    return nil
}

/// A cheap content fingerprint, used to spot the same picture showing up for different items.
func artworkContentDigest(_ data: Data) -> Int {
    var hasher = Hasher()
    data.withUnsafeBytes { hasher.combine(bytes: $0) }
    return hasher.finalize()
}
