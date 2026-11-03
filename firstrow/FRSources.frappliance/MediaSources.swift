import Foundation

/// Places First Row reads media from on top of the standard libraries: folders of movies, music
/// and photos the user picks, an iTunes Library XML file and an iPhoto library.
///
/// Choices are stored as bookmarks so they survive renames, moves and (in the sandboxed app)
/// relaunches; the sandbox grants access to each through its security scope, which stays open
/// for the life of the app. Thread-safe: the library scanners read it off the main thread.
final class MediaSources: @unchecked Sendable {
    static let shared = MediaSources()
    static let didChangeNotification = Notification.Name("FirstRowMediaSourcesDidChange")

    enum FolderKind: String, CaseIterable {
        case movies
        case music
        case photos

        var title: String {
            switch self {
            case .movies: "Movies"
            case .music: "Music"
            case .photos: "Photos"
            }
        }
    }

    enum LibraryKind: String, CaseIterable {
        /// "iTunes Music Library.xml" / "iTunes Library.xml", as exported by iTunes and Music.
        case iTunesXML
        /// An "iPhoto Library" package (read through its AlbumData.xml).
        case iPhoto
    }

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private var resolvedFolders: [FolderKind: [URL]] = [:]
    private var resolvedLibraries: [LibraryKind: URL] = [:]
    private var openedScopes: Set<URL> = []

    private init() {}

    // MARK: - Reading

    func folders(_ kind: FolderKind) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = resolvedFolders[kind] {
            return cached
        }
        let bookmarks = defaults.array(forKey: folderKey(kind)) as? [Data] ?? []
        let urls = bookmarks.compactMap(resolveLocked)
        resolvedFolders[kind] = urls
        return urls
    }

    func library(_ kind: LibraryKind) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = resolvedLibraries[kind] {
            return cached
        }
        guard let bookmark = defaults.data(forKey: libraryKey(kind)), let url = resolveLocked(bookmark) else {
            return nil
        }
        resolvedLibraries[kind] = url
        return url
    }

    // MARK: - Changing

    func addFolder(_ url: URL, kind: FolderKind) {
        guard let bookmark = Self.bookmark(for: url) else { return }
        lock.lock()
        var bookmarks = defaults.array(forKey: folderKey(kind)) as? [Data] ?? []
        let existing = bookmarks.compactMap(resolveLocked).map(\.standardizedFileURL.path)
        if !existing.contains(url.standardizedFileURL.path) {
            bookmarks.append(bookmark)
            defaults.set(bookmarks, forKey: folderKey(kind))
        }
        resolvedFolders[kind] = nil
        lock.unlock()
        postChange()
    }

    func removeFolder(at index: Int, kind: FolderKind) {
        lock.lock()
        var bookmarks = defaults.array(forKey: folderKey(kind)) as? [Data] ?? []
        if bookmarks.indices.contains(index) {
            bookmarks.remove(at: index)
            defaults.set(bookmarks, forKey: folderKey(kind))
        }
        resolvedFolders[kind] = nil
        lock.unlock()
        postChange()
    }

    func setLibrary(_ url: URL?, kind: LibraryKind) {
        lock.lock()
        if let url, let bookmark = Self.bookmark(for: url) {
            defaults.set(bookmark, forKey: libraryKey(kind))
        } else {
            defaults.removeObject(forKey: libraryKey(kind))
        }
        resolvedLibraries[kind] = nil
        lock.unlock()
        postChange()
    }

    // MARK: - Bookmarks

    private func folderKey(_ kind: FolderKind) -> String { "mediaSources.folders.\(kind.rawValue)" }
    private func libraryKey(_ kind: LibraryKind) -> String { "mediaSources.library.\(kind.rawValue)" }

    private static func bookmark(for url: URL) -> Data? {
        #if os(macOS)
            // Security-scoped where the app is sandboxed; a plain bookmark otherwise
            // (development builds run unsandboxed and can't make scoped ones).
            if let scoped = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
                return scoped
            }
        #endif
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func resolveLocked(_ bookmark: Data) -> URL? {
        var isStale = false
        #if os(macOS)
            let url = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale))
                ?? (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale))
        #else
            let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #endif
        guard let url else { return nil }
        if !openedScopes.contains(url), url.startAccessingSecurityScopedResource() {
            openedScopes.insert(url)
        }
        return url
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
