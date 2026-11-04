@_exported import CoreGraphics
import FirstRowPortable
import Foundation

// There is no system photo library on Linux or Windows, so this answers as a Mac does when
// access to Photos is turned off; photos come from the folders added in Settings instead.

public enum PHAuthorizationStatus: Int, Sendable {
    case notDetermined, restricted, denied, authorized, limited
}

public enum PHAccessLevel: Int, Sendable {
    case addOnly = 1
    case readWrite = 2
}

public final class PHPhotoLibrary: @unchecked Sendable {
    public static func shared() -> PHPhotoLibrary { PHPhotoLibrary() }
    public static func authorizationStatus() -> PHAuthorizationStatus { .restricted }
    public static func authorizationStatus(for _: PHAccessLevel) -> PHAuthorizationStatus { .restricted }

    public static func requestAuthorization(_ handler: @escaping @Sendable (PHAuthorizationStatus) -> Void) {
        handler(.restricted)
    }

    public static func requestAuthorization(for _: PHAccessLevel, handler: @escaping @Sendable (PHAuthorizationStatus) -> Void) {
        handler(.restricted)
    }

    public static func requestAuthorization(for _: PHAccessLevel) async -> PHAuthorizationStatus { .restricted }
}

public enum PHAssetMediaType: Int, Sendable {
    case unknown, image, video, audio
}

public final class PHAsset: NSObject, @unchecked Sendable {
    public let localIdentifier: String = ""
    public let pixelWidth = 0
    public let pixelHeight = 0
    public let creationDate: Date? = nil
    public let mediaType: PHAssetMediaType = .image
    public let duration: TimeInterval = 0

    public static func fetchAssets(withLocalIdentifiers _: [String], options _: PHFetchOptions?) -> PHFetchResult<PHAsset> {
        PHFetchResult()
    }

    public static func fetchAssets(with _: PHAssetMediaType, options _: PHFetchOptions?) -> PHFetchResult<PHAsset> {
        PHFetchResult()
    }

    public static func fetchAssets(with _: PHFetchOptions?) -> PHFetchResult<PHAsset> {
        PHFetchResult()
    }
}

public final class PHFetchOptions: @unchecked Sendable {
    public var sortDescriptors: [NSSortDescriptor]?
    public var predicate: NSPredicate?
    public var fetchLimit = 0
    public var includeHiddenAssets = false
    public init() {}
}

public final class PHFetchResult<ObjectType: AnyObject>: @unchecked Sendable {
    public init() {}
    public var count: Int { 0 }
    public var firstObject: ObjectType? { nil }
    public var lastObject: ObjectType? { nil }
    public func object(at _: Int) -> ObjectType { fatalError("empty fetch result") }
    public func enumerateObjects(_: (ObjectType, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

public enum PHImageContentMode: Int, Sendable {
    case aspectFit = 0
    case aspectFill = 1
    public static let `default` = PHImageContentMode.aspectFit
}

public enum PHImageRequestOptionsDeliveryMode: Int, Sendable {
    case opportunistic, highQualityFormat, fastFormat
}

public enum PHImageRequestOptionsResizeMode: Int, Sendable {
    case none, fast, exact
}

public enum PHImageRequestOptionsVersion: Int, Sendable {
    case current, unadjusted, original
}

public final class PHImageRequestOptions: @unchecked Sendable {
    public var deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic
    public var resizeMode: PHImageRequestOptionsResizeMode = .fast
    public var version: PHImageRequestOptionsVersion = .current
    public var isNetworkAccessAllowed = false
    public var isSynchronous = false
    public init() {}
}

public typealias PHImageRequestID = Int32
public let PHInvalidImageRequestID: PHImageRequestID = 0
public let PHImageManagerMaximumSize = CGSize(width: -1, height: -1)
public let PHImageCancelledKey = "PHImageCancelledKey"
public let PHImageResultIsDegradedKey = "PHImageResultIsDegradedKey"
public let PHImageErrorKey = "PHImageErrorKey"
public let PHImageResultIsInCloudKey = "PHImageResultIsInCloudKey"

public final class PHImageManager: @unchecked Sendable {
    public static func `default`() -> PHImageManager { PHImageManager() }

    @discardableResult
    public func requestImage(for _: PHAsset, targetSize _: CGSize, contentMode _: PHImageContentMode, options _: PHImageRequestOptions?, resultHandler: @escaping (NSImage?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID {
        resultHandler(nil, [PHImageErrorKey: NSError(domain: "PHPhotosErrorDomain", code: 3311)])
        return PHInvalidImageRequestID
    }

    public func cancelImageRequest(_: PHImageRequestID) {}
}
