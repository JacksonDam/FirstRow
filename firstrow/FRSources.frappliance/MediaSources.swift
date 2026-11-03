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

    /// A stored folder: where it is now, or nil when it can't be found (an unplugged drive).
    struct FolderEntry {
        let url: URL?
        let displayPath: String
    }

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private var resolvedFolders: [FolderKind: [FolderEntry]] = [:]
    private var resolvedLibraries: [LibraryKind: URL] = [:]
    private var openedScopes: Set<URL> = []
    private var changePending = false

    private init() {}

    // MARK: - Reading

    /// The folders that can be read right now.
    func folders(_ kind: FolderKind) -> [URL] {
        folderEntries(kind).compactMap(\.url)
    }

    /// Every stored folder, in order, including ones that can't be found right now; row `n`
    /// here is the folder `removeFolder(at: n)` removes.
    func folderEntries(_ kind: FolderKind) -> [FolderEntry] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = resolvedFolders[kind] {
            return cached
        }
        var bookmarks = defaults.array(forKey: folderKey(kind)) as? [Data] ?? []
        var entries: [FolderEntry] = []
        var refreshed = false
        for (index, bookmark) in bookmarks.enumerated() {
            if let (url, freshBookmark) = resolveLocked(bookmark) {
                if let freshBookmark {
                    bookmarks[index] = freshBookmark
                    refreshed = true
                }
                entries.append(FolderEntry(url: url, displayPath: url.path))
            } else {
                entries.append(FolderEntry(url: nil, displayPath: Self.storedPath(of: bookmark) ?? "Unavailable folder"))
            }
        }
        if refreshed {
            defaults.set(bookmarks, forKey: folderKey(kind))
        }
        resolvedFolders[kind] = entries
        return entries
    }

    func library(_ kind: LibraryKind) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = resolvedLibraries[kind] {
            return cached
        }
        guard let bookmark = defaults.data(forKey: libraryKey(kind)), let (url, freshBookmark) = resolveLocked(bookmark) else {
            return nil
        }
        if let freshBookmark {
            defaults.set(freshBookmark, forKey: libraryKey(kind))
        }
        resolvedLibraries[kind] = url
        return url
    }

    // MARK: - Changing

    func addFolder(_ url: URL, kind: FolderKind) {
        guard let bookmark = Self.bookmark(for: url) else { return }
        lock.lock()
        var bookmarks = defaults.array(forKey: folderKey(kind)) as? [Data] ?? []
        let existing = bookmarks.compactMap { Self.storedPath(of: $0) }
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
        releaseUnusedScopes()
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
        releaseUnusedScopes()
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

    /// The bookmark's folder, plus a fresh bookmark to store when the old one has gone stale.
    /// Never mounts anything: a network share that isn't connected just counts as unavailable.
    private func resolveLocked(_ bookmark: Data) -> (URL, Data?)? {
        var isStale = false
        #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
            let url = (try? URL(resolvingBookmarkData: bookmark, options: options.union(.withSecurityScope), relativeTo: nil, bookmarkDataIsStale: &isStale))
                ?? (try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale))
        #else
            let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
        #endif
        guard let url else { return nil }
        if !openedScopes.contains(url), url.startAccessingSecurityScopedResource() {
            openedScopes.insert(url)
        }
        return (url, isStale ? Self.bookmark(for: url) : nil)
    }

    /// Where a bookmark pointed when it was made, without resolving it.
    private static func storedPath(of bookmark: Data) -> String? {
        URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
    }

    /// Gives back access to folders that are no longer chosen.
    private func releaseUnusedScopes() {
        let inUse = Set(FolderKind.allCases.flatMap { folders($0) } + LibraryKind.allCases.compactMap { library($0) })
        lock.lock()
        let unused = openedScopes.subtracting(inUse)
        openedScopes.subtract(unused)
        lock.unlock()
        for url in unused {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// One notification for a burst of changes (adding several folders at once reloads once).
    private func postChange() {
        lock.lock()
        let alreadyPending = changePending
        changePending = true
        lock.unlock()
        guard !alreadyPending else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.lock.lock()
            self.changePending = false
            self.lock.unlock()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
