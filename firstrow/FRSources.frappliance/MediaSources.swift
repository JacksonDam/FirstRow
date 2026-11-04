import Foundation

/// User-picked media folders and library files, stored as bookmarks. Thread-safe.
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

    /// Every stored folder, including missing ones. Index `n` is what `removeFolder(at: n)` removes.
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
        #if FIRSTROW_PORTABLE
            // No bookmarks or sandbox here: the path is the bookmark.
            return Data(url.standardizedFileURL.path.utf8)
        #endif
        #if os(macOS)
            // Unsandboxed dev builds can't make security-scoped bookmarks, so fall back to a plain one.
            if let scoped = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
                return scoped
            }
        #endif
        #if !FIRSTROW_PORTABLE
            return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// The bookmark's folder, plus a fresh bookmark to store when the old one has gone stale.
    /// Never mounts anything: a network share that isn't connected just counts as unavailable.
    private func resolveLocked(_ bookmark: Data) -> (URL, Data?)? {
        #if FIRSTROW_PORTABLE
            let path = String(decoding: bookmark, as: UTF8.self)
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            return (URL(fileURLWithPath: path), nil)
        #else
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
        #endif
    }

    /// Where a bookmark pointed when it was made, without resolving it.
    private static func storedPath(of bookmark: Data) -> String? {
        #if FIRSTROW_PORTABLE
            String(decoding: bookmark, as: UTF8.self)
        #else
            URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
        #endif
    }

    /// Gives back access to folders that are no longer chosen.
    private func releaseUnusedScopes() {
        let inUse = Set(FolderKind.allCases.flatMap { folders($0) } + LibraryKind.allCases.compactMap { library($0) })
        lock.lock()
        let unused = openedScopes.subtracting(inUse)
        openedScopes.subtract(unused)
        lock.unlock()
        #if !FIRSTROW_PORTABLE
            for url in unused {
                url.stopAccessingSecurityScopedResource()
            }
        #endif
    }

    /// Coalesces a burst of changes into one notification.
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
