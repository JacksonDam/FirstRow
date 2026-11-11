import Foundation
import ImageIO
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// Albums from Settings folders and iPhoto, keyed by file URL and loaded through ImageIO.
extension MenuView {
    static let filePhotoIdentifierPrefix = "file://"

    nonisolated func filePhotoURL(fromIdentifier identifier: String) -> URL? {
        guard identifier.hasPrefix(Self.filePhotoIdentifierPrefix) else { return nil }
        return URL(string: identifier)
    }

    /// A picture from disk, decoded at no more than the size asked for.
    nonisolated func loadFilePhotoImage(_ url: URL, targetSize: CGSize) -> NSImage? {
        Self.filePhotoImage(at: url, targetSize: targetSize)
    }

    nonisolated static func filePhotoImage(at url: URL, targetSize: CGSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxPixelSize = max(256, max(targetSize.width, targetSize.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    func requestPhotoSourceAlbumsLoad() {
        hasRequestedPhotoSourceAlbums = true
        let requestID = incrementRequestID(&photoSourceAlbumsRequestID)
        Task.detached(priority: .userInitiated) {
            let albums = Self.loadPhotoSourceAlbums()
            await MainActor.run {
                // A newer load (sources changed again) wins over this one.
                guard self.photoSourceAlbumsRequestID == requestID else { return }
                self.photosSourceAlbums = albums
                for album in albums {
                    self.requestPhotoAlbumCoverImageIfNeeded(for: album)
                }
            }
        }
    }

    nonisolated static func loadPhotoSourceAlbums() -> [PhotoLibraryAlbumEntry] {
        var albums: [PhotoLibraryAlbumEntry] = []
        for folder in MediaSources.shared.folders(.photos) {
            let identifiers = imageFiles(in: folder).map(\.absoluteString)
            guard !identifiers.isEmpty else { continue }
            albums.append(sourceAlbum(
                id: "photos_source::folder::\(folder.standardizedFileURL.path)",
                title: FileManager.default.displayName(atPath: folder.path),
                identifiers: identifiers,
            ))
        }
        if let library = MediaSources.shared.library(.iPhoto) {
            for album in IPhotoLibrary.albums(in: library) {
                albums.append(sourceAlbum(
                    id: "photos_source::iphoto::\(album.id)",
                    title: album.title,
                    identifiers: album.imageURLs.map(\.absoluteString),
                ))
            }
        }
        return albums
    }

    private nonisolated static func sourceAlbum(id: String, title: String, identifiers: [String]) -> PhotoLibraryAlbumEntry {
        PhotoLibraryAlbumEntry(
            id: id,
            title: title,
            count: identifiers.count,
            assetLocalIdentifiers: identifiers,
            coverAssetLocalIdentifier: identifiers.first,
            scope: .source,
            dateGroupDay: nil,
        )
    }

    private nonisolated static let photoFileExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    /// Pictures in a folder and its subfolders, in name order.
    private nonisolated static func imageFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where photoFileExtensions.contains(url.pathExtension.lowercased()) {
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// Reads an iPhoto library's AlbumData.xml: its albums and events, each a list of pictures.
enum IPhotoLibrary {
    struct Album {
        let id: String
        let title: String
        let imageURLs: [URL]
    }

    static func albums(in library: URL) -> [Album] {
        let albumDataURL = library.appendingPathComponent("AlbumData.xml")
        guard let data = try? Data(contentsOf: albumDataURL, options: [.mappedIfSafe]),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let images = root["Master Image List"] as? [String: [String: Any]]
        else { return [] }
        let originalRoot = (root["Archive Path"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        func imageURL(forKey key: String) -> URL? {
            guard let image = images[key], (image["MediaType"] as? String ?? "Image") == "Image",
                  let path = image["ImagePath"] as? String
            else { return nil }
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            // A library copied from another Mac still lists the old paths: look inside the chosen one.
            if let originalRoot, path.hasPrefix(originalRoot) {
                let relocated = library.appendingPathComponent(String(path.dropFirst(originalRoot.count)))
                if FileManager.default.fileExists(atPath: relocated.path) {
                    return relocated
                }
            }
            return nil
        }

        func album(id: String, title: String, keys: [Any]) -> Album? {
            let urls = keys.compactMap { key -> URL? in
                if let key = key as? String { return imageURL(forKey: key) }
                if let key = key as? Int { return imageURL(forKey: "\(key)") }
                return nil
            }
            return urls.isEmpty ? nil : Album(id: id, title: title, imageURLs: urls)
        }

        var albums: [Album] = []
        // Albums made by the user (iPhoto's own "Photos", "Last Import" and similar are left out).
        for entry in root["List of Albums"] as? [[String: Any]] ?? [] {
            let type = entry["Album Type"] as? String ?? "Regular"
            guard type == "Regular" || type == "Smart", entry["Master"] as? Bool != true,
                  let title = entry["AlbumName"] as? String,
                  let found = album(id: "album::\(entry["AlbumId"] ?? title)", title: title, keys: entry["KeyList"] as? [Any] ?? [])
            else { continue }
            albums.append(found)
        }
        // Events (called rolls in the file).
        for entry in root["List of Rolls"] as? [[String: Any]] ?? [] {
            guard let title = entry["RollName"] as? String,
                  let found = album(id: "event::\(entry["RollID"] ?? title)", title: title, keys: entry["KeyList"] as? [Any] ?? [])
            else { continue }
            albums.append(found)
        }
        return albums
    }
}
