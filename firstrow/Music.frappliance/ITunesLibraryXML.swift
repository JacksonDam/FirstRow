import Foundation

/// Parses the library XML that iTunes writes or Music exports (File > Library > Export Library).
final class ITunesLibraryXML: @unchecked Sendable {
    struct Track {
        let trackID: Int
        let persistentID: String
        let title: String
        let artist: String
        let albumArtist: String
        let album: String
        let genre: String
        let composer: String
        let durationSeconds: Double
        let trackNumber: Int
        let discNumber: Int
        let url: URL
    }

    struct Playlist {
        let persistentID: String
        let name: String
        let trackIDs: [Int]
    }

    struct Contents {
        let tracks: [Track]
        let tracksByID: [Int: Track]
        let playlists: [Playlist]
    }

    static let shared = ITunesLibraryXML()

    private let lock = NSLock()
    private var cachedURL: URL?
    private var cachedModificationDate: Date?
    private var cachedContents: Contents?

    /// The chosen library's songs and playlists, or nil when there is none or it can't be read.
    func contents() -> Contents? {
        guard let url = MediaSources.shared.library(.iTunesXML) else { return nil }
        let modificationDate = Self.modificationDate(of: url)
        lock.lock()
        if cachedURL == url, cachedModificationDate == modificationDate, let cachedContents {
            lock.unlock()
            return cachedContents
        }
        lock.unlock()
        guard let parsed = Self.parse(url) else { return nil }
        lock.lock()
        cachedURL = url
        cachedModificationDate = modificationDate
        cachedContents = parsed
        lock.unlock()
        return parsed
    }

    /// When the library file was last written. (Asked of the file each time: the address is
    /// one that is kept, and what an address is asked about its file it can go on answering
    /// from memory, which left a library rewritten while First Row ran looking unchanged.)
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func parse(_ url: URL) -> Contents? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let trackDictionaries = root["Tracks"] as? [String: Any]
        else { return nil }
        let musicFolder = (root["Music Folder"] as? String).flatMap(URL.init(string:))
        var tracks: [Track] = []
        tracks.reserveCapacity(trackDictionaries.count)
        for case let entry as [String: Any] in trackDictionaries.values {
            guard let track = track(from: entry, musicFolder: musicFolder) else { continue }
            tracks.append(track)
        }
        var tracksByID: [Int: Track] = [:]
        for track in tracks {
            tracksByID[track.trackID] = track
        }
        var playlists: [Playlist] = []
        for case let entry as [String: Any] in root["Playlists"] as? [Any] ?? [] {
            // User playlists only: not the whole library, built-in lists or folders.
            if entry["Master"] as? Bool == true || entry["Folder"] as? Bool == true { continue }
            if entry["Distinguished Kind"] != nil || entry["Visible"] as? Bool == false { continue }
            guard let name = entry["Name"] as? String else { continue }
            let trackIDs = (entry["Playlist Items"] as? [[String: Any]] ?? []).compactMap { $0["Track ID"] as? Int }
                .filter { tracksByID[$0] != nil }
            guard !trackIDs.isEmpty else { continue }
            playlists.append(Playlist(
                persistentID: entry["Playlist Persistent ID"] as? String ?? name,
                name: name,
                trackIDs: trackIDs,
            ))
        }
        return Contents(tracks: tracks, tracksByID: tracksByID, playlists: playlists)
    }

    private static func track(from entry: [String: Any], musicFolder: URL?) -> Track? {
        // Songs kept as local files: no streams, videos, podcasts or audiobooks.
        if let type = entry["Track Type"] as? String, type != "File" { return nil }
        for flag in ["Has Video", "Movie", "TV Show", "Music Video", "Podcast", "iTunesU"] where entry[flag] as? Bool == true {
            return nil
        }
        if let kind = entry["Kind"] as? String, kind.localizedCaseInsensitiveContains("audiobook") { return nil }
        guard let trackID = entry["Track ID"] as? Int,
              let location = entry["Location"] as? String,
              let url = resolvedFileURL(location, musicFolder: musicFolder)
        else { return nil }
        func text(_ key: String, _ fallback: String) -> String {
            let value = (entry[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? fallback : value
        }
        return Track(
            trackID: trackID,
            persistentID: entry["Persistent ID"] as? String ?? "\(trackID)",
            title: text("Name", url.deletingPathExtension().lastPathComponent),
            artist: text("Artist", text("Album Artist", L("Unknown Artist"))),
            albumArtist: text("Album Artist", ""),
            album: text("Album", L("Unknown Album")),
            genre: text("Genre", L("Unknown Genre")),
            composer: text("Composer", L("Unknown Composer")),
            durationSeconds: Double(entry["Total Time"] as? Int ?? 0) / 1000,
            trackNumber: entry["Track Number"] as? Int ?? 0,
            discNumber: entry["Disc Number"] as? Int ?? 1,
            url: url,
        )
    }

    /// A copied library keeps the old Mac's paths, so missing files are looked up beside the XML.
    private static func resolvedFileURL(_ location: String, musicFolder: URL?) -> URL? {
        guard let url = URL(string: location), url.isFileURL else { return nil }
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        guard let musicFolder, let libraryURL = MediaSources.shared.library(.iTunesXML) else { return nil }
        let oldRoot = musicFolder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(oldRoot) else { return nil }
        let relative = String(path.dropFirst(oldRoot.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let libraryFolder = libraryURL.deletingLastPathComponent()
        for mediaFolderName in ["iTunes Media", "iTunes Music"] {
            let candidate = libraryFolder.appendingPathComponent(mediaFolderName, isDirectory: true).appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
