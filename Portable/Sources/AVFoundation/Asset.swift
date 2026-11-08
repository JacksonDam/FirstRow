@_exported import CoreGraphics
import Foundation

public let AVURLAssetPreferPreciseDurationAndTimingKey = "AVURLAssetPreferPreciseDurationAndTimingKey"

public struct AVMetadataKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let commonKeyTitle = AVMetadataKey("title")
    public static let commonKeyArtist = AVMetadataKey("artist")
    public static let commonKeyAlbumName = AVMetadataKey("albumName")
    public static let commonKeyArtwork = AVMetadataKey("artwork")
    public static let commonKeyDescription = AVMetadataKey("description")
    public static let commonKeyCreator = AVMetadataKey("creator")
    public static let commonKeyType = AVMetadataKey("type")
}

public struct AVMetadataKeySpace: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let common = AVMetadataKeySpace(rawValue: "comn")
    public static let id3 = AVMetadataKeySpace(rawValue: "org.id3")
    public static let iTunes = AVMetadataKeySpace(rawValue: "itsk")
}

public struct AVMetadataIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let commonIdentifierTitle = AVMetadataIdentifier("common/title")
    public static let commonIdentifierArtist = AVMetadataIdentifier("common/artist")
    public static let commonIdentifierAlbumName = AVMetadataIdentifier("common/albumName")
    public static let commonIdentifierArtwork = AVMetadataIdentifier("common/artwork")
    public static let commonIdentifierDescription = AVMetadataIdentifier("common/description")
    public static let id3MetadataAttachedPicture = AVMetadataIdentifier("id3/APIC")
    public static let id3MetadataComposer = AVMetadataIdentifier("id3/TCOM")
    public static let id3MetadataContentType = AVMetadataIdentifier("id3/TCON")
    public static let id3MetadataPartOfASet = AVMetadataIdentifier("id3/TPOS")
    public static let id3MetadataTrackNumber = AVMetadataIdentifier("id3/TRCK")
    public static let id3MetadataUnsynchronizedLyric = AVMetadataIdentifier("id3/USLT")
    public static let iTunesMetadataLyrics = AVMetadataIdentifier("itsk/©lyr")
    public static let iTunesMetadataCoverArt = AVMetadataIdentifier("itsk/covr")
    public static let quickTimeMetadataArtwork = AVMetadataIdentifier("mdta/com.apple.quicktime.artwork")
}

public struct AVMediaType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let video = AVMediaType(rawValue: "vide")
    public static let audio = AVMediaType(rawValue: "soun")
}

public enum AVKeyValueStatus: Int, Sendable {
    case unknown, loading, loaded, failed, cancelled
}

/// The async `load(_:)` property handles.
public struct AVAsyncProperty<Root, Value>: @unchecked Sendable {
    let read: (Root) -> Value
}

public final class AVMetadataItem: NSObject, @unchecked Sendable {
    public let identifier: AVMetadataIdentifier?
    public let commonKey: AVMetadataKey?
    public let keySpace: AVMetadataKeySpace?
    public let value: (NSCopying & NSObjectProtocol)?
    private let raw: Any

    init(tag: MediaFileInfo.Tag, common: Bool) {
        raw = tag.value
        if common, let key = tag.commonKey {
            identifier = AVMetadataIdentifier("common/\(key)")
            commonKey = AVMetadataKey(key)
            keySpace = .common
        } else {
            identifier = AVMetadataIdentifier(tag.identifier)
            commonKey = tag.commonKey.map { AVMetadataKey($0) }
            keySpace = AVMetadataKeySpace(rawValue: String(tag.identifier.split(separator: "/").first ?? ""))
        }
        if let text = tag.value as? String {
            value = NSString(string: text)
        } else if let data = tag.value as? Data {
            value = NSData(data: data)
        } else {
            value = nil
        }
        super.init()
    }

    public var key: (NSCopying & NSObjectProtocol)? {
        identifier.map { NSString(string: String($0.rawValue.split(separator: "/").last ?? "")) }
    }

    public var stringValue: String? { raw as? String }
    public var dataValue: Data? { raw as? Data }
    public var numberValue: NSNumber? { (raw as? String).flatMap { Double($0) }.map { NSNumber(value: $0) } }
    public var dateValue: Date? { nil }

    public static func metadataItems(from items: [AVMetadataItem], withKey key: Any?, keySpace: AVMetadataKeySpace?) -> [AVMetadataItem] {
        let wanted = (key as? AVMetadataKey)?.rawValue ?? (key as? String)
        return items.filter { item in
            (keySpace == nil || item.keySpace == keySpace) && (wanted == nil || item.commonKey?.rawValue == wanted || (item.key as? NSString).map { String($0) } == wanted)
        }
    }

    public static func metadataItems(from items: [AVMetadataItem], filteredByIdentifier identifier: AVMetadataIdentifier) -> [AVMetadataItem] {
        items.filter { $0.identifier == identifier }
    }

    public func load<T>(_ property: AVAsyncProperty<AVMetadataItem, T>) async throws -> T {
        property.read(self)
    }
}

public extension AVAsyncProperty where Root == AVMetadataItem, Value == Data? {
    static var dataValue: AVAsyncProperty<AVMetadataItem, Data?> { .init { $0.dataValue } }
}

public extension AVAsyncProperty where Root == AVMetadataItem, Value == String? {
    static var stringValue: AVAsyncProperty<AVMetadataItem, String?> { .init { $0.stringValue } }
}

public extension AVAsyncProperty where Root == AVMetadataItem, Value == (NSCopying & NSObjectProtocol)? {
    static var value: AVAsyncProperty<AVMetadataItem, (NSCopying & NSObjectProtocol)?> { .init { $0.value } }
}

public final class AVAssetTrack: NSObject, @unchecked Sendable {
    public let mediaType: AVMediaType
    public let naturalSize: CGSize
    public let preferredTransform: CGAffineTransform = .identity

    init(mediaType: AVMediaType, naturalSize: CGSize) {
        self.mediaType = mediaType
        self.naturalSize = naturalSize
    }
}

open class AVAsset: NSObject, @unchecked Sendable {
    public let url: URL
    lazy var info: MediaFileInfo = TagReader.info(for: url)

    init(url: URL) {
        self.url = url
    }

    public var duration: CMTime {
        if let seconds = info.duration { return CMTime(seconds: seconds, preferredTimescale: 600) }
        if let seconds = MediaProbe.duration(of: url) { return CMTime(seconds: seconds, preferredTimescale: 600) }
        return .zero
    }

    public var commonMetadata: [AVMetadataItem] {
        info.tags.filter { $0.commonKey != nil }.map { AVMetadataItem(tag: $0, common: true) }
    }

    public var metadata: [AVMetadataItem] {
        info.tags.map { AVMetadataItem(tag: $0, common: false) }
    }

    public var tracks: [AVAssetTrack] {
        var list: [AVAssetTrack] = []
        if info.hasVideo { list.append(AVAssetTrack(mediaType: .video, naturalSize: info.videoSize ?? .zero)) }
        if info.hasAudio || !info.hasVideo { list.append(AVAssetTrack(mediaType: .audio, naturalSize: .zero)) }
        return list
    }

    public func tracks(withMediaType type: AVMediaType) -> [AVAssetTrack] {
        tracks.filter { $0.mediaType == type }
    }

    public func loadTracks(withMediaType type: AVMediaType) async throws -> [AVAssetTrack] {
        tracks(withMediaType: type)
    }

    /// Files with DRM can't be played; nothing here can tell, so none count as protected.
    public var hasProtectedContent: Bool { false }

    public var isPlayable: Bool { FileManager.default.fileExists(atPath: url.path) || url.scheme?.hasPrefix("http") == true }

    public func load<T>(_ property: AVAsyncProperty<AVAsset, T>) async throws -> T {
        property.read(self)
    }

    public func loadValuesAsynchronously(forKeys _: [String], completionHandler: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = info
            completionHandler?()
        }
    }

    public func statusOfValue(forKey _: String, error _: UnsafeMutablePointer<NSError?>?) -> AVKeyValueStatus { .loaded }
}

public final class AVURLAsset: AVAsset, @unchecked Sendable {
    public init(url: URL, options _: [String: Any]? = nil) {
        super.init(url: url)
    }
}

public extension AVAsyncProperty where Root == AVAsset, Value == CMTime {
    static var duration: AVAsyncProperty<AVAsset, CMTime> { .init { $0.duration } }
}

public extension AVAsyncProperty where Root == AVAsset, Value == [AVMetadataItem] {
    static var commonMetadata: AVAsyncProperty<AVAsset, [AVMetadataItem]> { .init { $0.commonMetadata } }
    static var metadata: AVAsyncProperty<AVAsset, [AVMetadataItem]> { .init { $0.metadata } }
}

public extension AVAsyncProperty where Root == AVAsset, Value == [AVAssetTrack] {
    static var tracks: AVAsyncProperty<AVAsset, [AVAssetTrack]> { .init { $0.tracks } }
}

public extension AVAsyncProperty where Root == AVAsset, Value == Bool {
    static var isPlayable: AVAsyncProperty<AVAsset, Bool> { .init { $0.isPlayable } }
    static var hasProtectedContent: AVAsyncProperty<AVAsset, Bool> { .init { $0.hasProtectedContent } }
}

/// Frames from a video file, decoded with mpv.
public final class AVAssetImageGenerator: @unchecked Sendable {
    public let asset: AVAsset
    public var appliesPreferredTrackTransform = false
    public var maximumSize: CGSize = .zero
    public var requestedTimeToleranceBefore: CMTime = .indefinite
    public var requestedTimeToleranceAfter: CMTime = .indefinite

    public init(asset: AVAsset) {
        self.asset = asset
    }

    public func copyCGImage(at time: CMTime, actualTime: UnsafeMutablePointer<CMTime>?) throws -> CGImage {
        guard let image = MediaProbe.frame(of: asset.url, at: time.seconds.isFinite ? time.seconds : 0, maximumSize: maximumSize) else {
            throw NSError(domain: "AVFoundationErrorDomain", code: -11800)
        }
        actualTime?.pointee = time
        return image
    }

    public func image(at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        let image = try copyCGImage(at: time, actualTime: nil)
        return (image, time)
    }
}
