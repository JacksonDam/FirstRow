import AVFoundation
#if canImport(Darwin)
    import Darwin
#endif
import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif
#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif
#if os(iOS)
    import UIKit
#endif

extension MenuView {
    /// File properties read while scanning for movies (content types where the system has them).
    static var movieScanResourceKeys: Set<URLResourceKey> {
        #if canImport(UniformTypeIdentifiers)
            if #available(macOS 11.0, iOS 14.0, tvOS 14.0, *) {
                return [.isDirectoryKey, .isRegularFileKey, .contentTypeKey]
            }
        #endif
        return [.isDirectoryKey, .isRegularFileKey]
    }

    #if os(iOS)
        func isSupportedMovieFile(url: URL, values: URLResourceValues?) -> Bool {
            let normalizedExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isSupportedByExtension = supportedMovieFileExtensions.contains(normalizedExtension)
            let isSupportedByType = values?.contentType?.conforms(to: .movie) ?? false
            return isSupportedByExtension || isSupportedByType
        }

        /// Before 2.4 one folder could be chosen in Files, and its movies were copied in each
        /// time Movies Folder opened. That folder is now one brought in with Import like any
        /// other, a folder at the top of Movies Folder; the copies made of its movies stay.
        func adoptMoviesFolderChosenBefore() {
            let key = "firstRow.movies.bookmarkedFolder"
            guard let bookmark = UserDefaults.standard.data(forKey: key) else { return }
            UserDefaults.standard.removeObject(forKey: key)
            var isStale = false
            guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) else { return }
            let isOpen = folder.startAccessingSecurityScopedResource()
            MediaSources.shared.addFolder(folder, kind: .movies)
            if isOpen { folder.stopAccessingSecurityScopedResource() }
        }

        /// Takes in what was picked in Files (Movies > Import). A folder stays where it is and
        /// is a folder at the top of Movies Folder. A movie is copied in among First Row's own
        /// (with the subtitle files picked with it) and is a movie at the top: Files fetches
        /// one that is still with its service as it is read, which can take a while, so the
        /// copying is done off to one side and the Import page says so meanwhile.
        func handleMoviesPickedFromFiles(_ urls: [URL]) {
            var files: [URL] = []
            for url in urls {
                let isOpen = url.startAccessingSecurityScopedResource()
                let isFolder = url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isFolder {
                    // (Kept by a bookmark, made while Files' leave to read it is in hand.)
                    MediaSources.shared.addFolder(url, kind: .movies)
                } else {
                    files.append(url)
                }
                if isOpen { url.stopAccessingSecurityScopedResource() }
            }
            mediaSourcesRevision &+= 1
            let kinds = supportedMovieFileExtensions.union(Self.subtitleFileExtensions)
            files = files.filter { kinds.contains($0.pathExtension.lowercased()) }
            guard !files.isEmpty else {
                finishTakingInPickedMovies()
                return
            }
            let documents = moviesDocumentsDirectoryURL().standardizedFileURL
            pickedMoviesBeingCopied += files.count
            mediaSourcesRevision &+= 1
            Task.detached(priority: .userInitiated) {
                for file in files {
                    Self.copyPickedMovie(file, into: documents)
                    await MainActor.run {
                        self.pickedMoviesBeingCopied = max(0, self.pickedMoviesBeingCopied - 1)
                        self.mediaSourcesRevision &+= 1
                    }
                }
                await MainActor.run { self.finishTakingInPickedMovies() }
            }
        }

        /// Copies one picked file in, under its own name where that is free. Read through a
        /// file coordinator, which has Files fetch it first if it isn't on the device yet.
        private nonisolated static func copyPickedMovie(_ source: URL, into documents: URL) {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
            let isOpen = source.startAccessingSecurityScopedResource()
            defer { if isOpen { source.stopAccessingSecurityScopedResource() } }
            let base = source.deletingPathExtension().lastPathComponent
            let kind = source.pathExtension
            var destination = documents.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            var copy = 2
            while fileManager.fileExists(atPath: destination.path) {
                destination = documents.appendingPathComponent("\(base) \(copy).\(kind)", isDirectory: false)
                copy += 1
            }
            var failure: NSError?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &failure) { readable in
                try? fileManager.copyItem(at: readable, to: destination)
            }
        }

        /// Everything picked is in: Movies Folder opens if the picking was asked for from
        /// there, and the Import page gives way to the Movies menu, where it all now is.
        private func finishTakingInPickedMovies() {
            guard pickedMoviesBeingCopied == 0 else { return }
            if entersMoviesFolderAfterPicking {
                entersMoviesFolderAfterPicking = false
                enterMoviesFolderMenu()
                return
            }
            if thirdMenuMode == .moviesFolder, thirdMenuCurrentURL == nil, !isShowingContinueWatching, tvShowListing == nil {
                loadMoviesTopLevel(resetSelection: true)
            }
            if thirdMenuMode == .mediaFolders, currentMediaFoldersPage == .importMovies {
                navigateUpInMediaFolders()
            }
        }

        // MARK: - Removing movies

        /// Takes a movie out of First Row: its copy here and the subtitle files that came with
        /// it. Whatever it was copied from is left as it is.
        func removeOwnMovie(_ file: URL) -> Bool {
            let fileManager = FileManager.default
            let folder = file.deletingLastPathComponent()
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
            do {
                try fileManager.removeItem(at: file)
            } catch {
                return false
            }
            for other in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                // ("Movie.srt", "Movie.en.srt": the subtitle files kept beside it.)
                let otherName = other.deletingPathExtension().lastPathComponent.lowercased()
                guard Self.subtitleFileExtensions.contains(other.pathExtension.lowercased()), otherName == name || otherName.hasPrefix(name + ".") else { continue }
                try? fileManager.removeItem(at: other)
            }
            return true
        }

        /// With nothing in Movies Folder and nothing brought in yet, Movies Folder asks for
        /// something first: the Files picker comes straight up (iOS moves the menu back behind
        /// it), and the folder opens once something is picked. Returns whether it asked.
        func promptForMoviesFolderPickerIfNeeded() -> Bool {
            guard !hasPromptedMoviesFolderPickerThisSession, pickedMoviesBeingCopied == 0,
                  scanMoviesTopLevelEntries().isEmpty
            else { return false }
            hasPromptedMoviesFolderPickerThisSession = true
            entersMoviesFolderAfterPicking = true
            isMovieFilesPickerPresented = true
            return true
        }
    #else
        func isSupportedMovieFile(url: URL, values _: URLResourceValues?) -> Bool {
            let normalizedExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return supportedMovieFileExtensions.contains(normalizedExtension)
        }
    #endif

    nonisolated func realUserHomeDirectoryURL() -> URL? {
        #if FIRSTROW_PORTABLE
            return FileManager.default.homeDirectoryForCurrentUser
        #else
            let username = NSUserName()
            guard !username.isEmpty else { return nil }
            return URL(fileURLWithPath: "/Users/\(username)", isDirectory: true)
        #endif
    }

    #if os(macOS) || FIRSTROW_PORTABLE
        nonisolated func externalVolumeRootURLs() -> [URL] {
            #if FIRSTROW_PORTABLE
                return portableExternalVolumeURLs()
            #endif
            #if !FIRSTROW_PORTABLE
                guard !FirstRowHarness.isActive else { return [] }
                guard let volumes = FileManager.default.mountedVolumeURLs(
                    includingResourceValuesForKeys: [],
                    options: [.skipHiddenVolumes]
                ) else { return [] }
                return volumes.filter { url in
                    let path = url.standardizedFileURL.path
                    return path != "/" && path.hasPrefix("/Volumes/")
                }
            #endif
        }
    #endif

    // MARK: - The top of Movies Folder

    /// The folders whose contents are at the top of Movies Folder: the Movies folder itself
    /// and, on a computer, every folder called Movies at the top of a drive.
    func moviesTopLevelFolderURLs() -> [URL] {
        var folders = [moviesRootDirectoryURL()]
        #if os(macOS) || FIRSTROW_PORTABLE
            folders += externalVolumeRootURLs().compactMap { volume in
                let movies = volume.appendingPathComponent("Movies", isDirectory: true)
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: movies.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
                return movies
            }
        #endif
        return folders
    }

    /// The top of Movies Folder: what is in those folders, with what was brought in by
    /// Movies > Import among it, a file as a movie and a folder as a folder. Movies first,
    /// then folders, each by name.
    func scanMoviesTopLevelEntries() -> [MoviesFolderEntry] {
        #if os(iOS)
            adoptMoviesFolderChosenBefore()
        #endif
        var movies: [MoviesFolderEntry] = []
        var folders: [MoviesFolderEntry] = []
        var seen = Set<String>()
        let topFolders = moviesTopLevelFolderURLs()
        let topPaths = Set(topFolders.map(\.standardizedFileURL.path))
        // (What was brought in comes first, so that it is known as brought in where it is
        // also inside one of those folders.)
        let movieExtensions = supportedMovieFileExtensions
        for url in MediaSources.shared.folders(.movies) {
            let path = url.standardizedFileURL.path
            var isFolder: ObjCBool = false
            guard !topPaths.contains(path), FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), seen.insert(path).inserted else { continue }
            if isFolder.boolValue, !(Self.playsEveryKindOfMovie && Self.isDiscFolder(url)) {
                // (A folder of nothing but TV episodes is under TV Shows, as an episode is.)
                if TVShowScanner.holdsOnlyEpisodes(url, movieExtensions: movieExtensions) { continue }
                folders.append(MoviesFolderEntry(id: path, title: CloudFolders.title(ofFolder: url), url: url, isDirectory: true, isImported: true))
            } else if !isFolder.boolValue, TVShowNames.episode(at: url) != nil {
                continue
            } else if isFolder.boolValue || isSupportedMovieFile(url: url, values: try? url.resourceValues(forKeys: Self.movieScanResourceKeys)) {
                let title = url.pathExtension.lowercased() == "dvdmedia" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
                movies.append(MoviesFolderEntry(id: path, title: title, url: url, isDirectory: false, isImported: true))
            }
        }
        for folder in topFolders {
            for entry in scanMoviesFolderEntries(in: folder) where seen.insert(entry.id).inserted {
                if entry.isDirectory { folders.append(entry) } else { movies.append(entry) }
            }
        }
        let byName: (MoviesFolderEntry, MoviesFolderEntry) -> Bool = {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return movies.sorted(by: byName) + folders.sorted(by: byName)
    }

    /// The first few movies there are to show a picture of for Movies Folder: those at its
    /// top, then those inside the folders brought in.
    func moviesTopLevelPreviewURLs(limit: Int) -> [URL] {
        var urls: [URL] = []
        let entries = scanMoviesTopLevelEntries()
        for entry in entries where !entry.isDirectory && urls.count < limit && !Self.isDiscFolder(entry.url) {
            urls.append(entry.url.standardizedFileURL)
        }
        for entry in entries where entry.isDirectory && entry.isImported && urls.count < limit {
            urls += previewMovieFileURLs(in: entry.url, limit: limit - urls.count)
        }
        return urls
    }

    /// Shows the top of Movies Folder. With nothing there at all, the menu goes back to
    /// Movies and says so.
    func loadMoviesTopLevel(resetSelection: Bool) {
        thirdMenuCurrentURL = nil
        thirdMenuRootURL = nil
        isLoadingMoviesFolderEntries = true
        let requestID = incrementRequestID(&moviesFolderEntriesRequestID)
        Task(priority: .userInitiated) {
            let entries = scanMoviesTopLevelEntries()
            await MainActor.run {
                guard moviesFolderEntriesRequestID == requestID, thirdMenuMode == .moviesFolder, thirdMenuCurrentURL == nil else { return }
                isLoadingMoviesFolderEntries = false
                thirdMenuItems = entries
                let maxIndex = max(0, entries.count - 1)
                if let remembered = moviesFolderSelectionIndexByDirectoryPath[Self.moviesTopLevelSelectionKey] {
                    selectedThirdIndex = min(max(0, remembered), maxIndex)
                } else if resetSelection {
                    selectedThirdIndex = 0
                } else {
                    selectedThirdIndex = min(max(0, selectedThirdIndex), maxIndex)
                }
                refreshDetailPreviewForCurrentContext()
                if entries.isEmpty {
                    isInThirdMenu = false
                    thirdMenuMode = .none
                    thirdMenuOpacity = 0
                    submenuOpacity = 1
                    headerText = rootMenuTitle(for: activeRootItemID)
                    resetThirdMenuDirectoryState()
                    moviesFolderSelectionIndexByDirectoryPath = [:]
                    refreshDetailPreviewForCurrentContext()
                    presentNoMoviesLibraryFeatureErrorScreen(afterMenuSwap: true)
                }
            }
        }
    }

    /// What the place in the list at the top of Movies Folder is remembered under (the
    /// folders are remembered under their paths).
    static let moviesTopLevelSelectionKey = ""

    func moviesDocumentsDirectoryURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
    }

    nonisolated func tvManagedMediaRootURL() -> URL? {
        if let homeURL = realUserHomeDirectoryURL() {
            return homeURL
                .appendingPathComponent("Movies", isDirectory: true)
                .appendingPathComponent("TV", isDirectory: true)
                .appendingPathComponent("Media.localized", isDirectory: true)
        }
        return nil
    }

    nonisolated func isURLInsideTVManagedMediaLibrary(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let standardizedURL = url.standardizedFileURL
        if let tvMediaRoot = tvManagedMediaRootURL()?.standardizedFileURL.path {
            let path = standardizedURL.path
            return path == tvMediaRoot || path.hasPrefix(tvMediaRoot + "/")
        }
        return standardizedURL.path.contains("/Movies/TV/Media.localized/")
    }

    nonisolated func shouldForceExternalMoviePlayback(for url: URL) -> Bool {
        guard isURLInsideTVManagedMediaLibrary(url) else { return false }
        let ext = url.standardizedFileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ext == "m4v" || ext == "m4p"
    }

    nonisolated func shouldSkipMovieThumbnailGeneration(for url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let standardizedURL = url.standardizedFileURL
        let ext = standardizedURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ext == "m4v" else { return false }
        return isURLInsideTVManagedMediaLibrary(standardizedURL)
    }

    func movieFileEntries(in directoryURL: URL) -> [MoviesFolderEntry] {
        scanMoviesFolderEntries(in: directoryURL).filter { !$0.isDirectory }
    }

    func moviesRootDirectoryURL() -> URL {
        #if os(iOS)
            let documentsDirectory = moviesDocumentsDirectoryURL()
            let fileManager = FileManager.default
            let legacyfirstRowDirectory = documentsDirectory.appendingPathComponent("Front Row", isDirectory: true)
            let inboxDirectory = documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)
            let candidates = [documentsDirectory, legacyfirstRowDirectory, inboxDirectory]
            for candidate in candidates {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                if !movieFileEntries(in: candidate).isEmpty {
                    return candidate
                }
            }
            return documentsDirectory
        #else
            if let harnessMoviesFolder = FirstRowHarness.moviesFolderOverride {
                return harnessMoviesFolder
            }
            #if FIRSTROW_PORTABLE
                return portableUserFolder(named: "Movies", standardName: "Videos", xdgKey: "XDG_VIDEOS_DIR")
            #else
                // (The user's name can come back empty, as it does in the Apple TV simulator.)
                let home = realUserHomeDirectoryURL() ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                return home.appendingPathComponent("Movies", isDirectory: true)
            #endif
        #endif
    }

    var supportedMovieFileExtensions: Set<String> {
        var kinds: Set<String> = [
            "mov",
            "mp4",
            "m4v",
            "mkv",
            "avi",
            "mpg",
            "mpeg",
            "ts",
            "m2ts",
            "wmv",
            "webm",
        ]
        if Self.playsEveryKindOfMovie {
            kinds.formUnion(Self.furtherMovieFileExtensions)
        }
        return kinds
    }

    /// The kinds of movie file beyond the system's own that First Row plays where it has
    /// something to play them with: its engine on the Mac, iPhone, iPad and Apple TV, mpv on
    /// Linux and Windows.
    static let furtherMovieFileExtensions: Set<String> = [
        "3gp", "3g2", "asf", "divx", "dvr-ms", "evo", "f4v", "flv", "img", "iso", "m1v", "m2t", "m2v", "mk3d", "mpe", "mpv",
        "mts", "mxf", "ogm", "ogv", "rm", "rmvb", "tp", "trp", "vob", "wtv",
    ]

    static var playsEveryKindOfMovie: Bool {
        #if FIRSTROW_PORTABLE
            true
        #else
            MediaEngine.isAvailable
        #endif
    }

    /// Whether a folder is a disc kept as its files: a DVD's (it holds VIDEO_TS, or is a
    /// .dvdmedia package) or a Blu-ray's (it holds BDMV). Such a folder is a movie to play,
    /// not a folder to look in.
    nonisolated static func isDiscFolder(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "dvdmedia" { return true }
        let fileManager = FileManager.default
        for name in ["VIDEO_TS", "BDMV", "video_ts", "bdmv"] {
            var isFolder: ObjCBool = false
            if fileManager.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isFolder), isFolder.boolValue {
                return true
            }
        }
        return false
    }

    var moviesFolderSubmenuPreviewLoadLimit: Int {
        #if os(iOS)
            6
        #else
            8
        #endif
    }

    func moviesFolderContainsNavigableContent(in directoryURL: URL) -> Bool {
        let fileManager = FileManager.default
        let resourceKeys = Self.movieScanResourceKeys
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles],
            )
        } catch {
            return false
        }
        for url in urls {
            let values = try? url.resourceValues(forKeys: resourceKeys)
            if values?.isDirectory == true {
                if TVShowScanner.holdsOnlyEpisodes(url, movieExtensions: supportedMovieFileExtensions) { continue }
                return true
            }
            guard values?.isRegularFile == true else { continue }
            if isSupportedMovieFile(url: url, values: values), TVShowNames.episode(at: url) == nil {
                return true
            }
        }
        return false
    }

    func scanMoviesFolderEntries(in directoryURL: URL) -> [MoviesFolderEntry] {
        let fileManager = FileManager.default
        let resourceKeys = Self.movieScanResourceKeys
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles],
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                return []
            }
            print("Unable to read Movies directory at path: \(directoryURL.path) (\(error.localizedDescription))")
            return []
        }
        var directoryEntries: [MoviesFolderEntry] = []
        var movieEntries: [MoviesFolderEntry] = []
        let movieExtensions = supportedMovieFileExtensions
        for url in urls {
            let values = try? url.resourceValues(forKeys: resourceKeys)
            let isDirectory = values?.isDirectory ?? false
            if isDirectory {
                // (Episodes of TV shows, and folders of nothing else, are under TV Shows.)
                if !Self.isDiscFolder(url), TVShowScanner.holdsOnlyEpisodes(url, movieExtensions: movieExtensions) { continue }
                if Self.playsEveryKindOfMovie, Self.isDiscFolder(url) {
                    movieEntries.append(
                        MoviesFolderEntry(
                            id: url.standardizedFileURL.path,
                            title: url.pathExtension.lowercased() == "dvdmedia" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
                            url: url,
                            isDirectory: false,
                        ),
                    )
                    continue
                }
                directoryEntries.append(
                    MoviesFolderEntry(
                        id: url.standardizedFileURL.path,
                        title: url.lastPathComponent,
                        url: url,
                        isDirectory: true,
                    ),
                )
                continue
            }
            if isSupportedMovieFile(url: url, values: values), TVShowNames.episode(at: url) == nil {
                movieEntries.append(
                    MoviesFolderEntry(
                        id: url.standardizedFileURL.path,
                        title: url.lastPathComponent,
                        url: url,
                        isDirectory: false,
                    ),
                )
            }
        }
        let sorter: (MoviesFolderEntry, MoviesFolderEntry) -> Bool = {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return movieEntries.sorted(by: sorter) + directoryEntries.sorted(by: sorter)
    }

    func firstMovieFileURL(in directoryURL: URL) -> URL? {
        previewMovieFileURLs(in: directoryURL, limit: 1).first
    }

    func previewMovieFileURLs(in directoryURL: URL, limit: Int) -> [URL] {
        guard limit > 0 else { return [] }
        let fileManager = FileManager.default
        let resourceKeys = Self.movieScanResourceKeys
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles],
            )
        } catch {
            return []
        }
        var resolved: [URL] = []
        resolved.reserveCapacity(limit)
        for url in urls {
            if resolved.count >= limit { break }
            let values = try? url.resourceValues(forKeys: resourceKeys)
            if values?.isDirectory == true { continue }
            guard values?.isRegularFile == true else { continue }
            guard isSupportedMovieFile(url: url, values: values), TVShowNames.episode(at: url) == nil else { continue }
            resolved.append(url.standardizedFileURL)
        }
        return resolved
    }

    func resetThirdMenuDirectoryState() {
        isShowingContinueWatching = false
        tvShowListing = nil
        thirdMenuItems = []
        thirdMenuCurrentURL = nil
        thirdMenuRootURL = nil
        isLoadingMoviesFolderEntries = false
        _ = incrementRequestID(&moviesFolderEntriesRequestID)
    }

    func resolveMoviePreviewTargetURL() -> URL? {
        if activeRootItemID == "tv_shows", isInSubmenu { return tvPreviewTargetURL() }
        guard activeRootItemID == "movies", isInSubmenu else { return nil }
        if isInThirdMenu {
            guard thirdMenuMode == .moviesFolder else { return nil }
            guard thirdMenuItems.indices.contains(selectedThirdIndex) else { return nil }
            let entry = thirdMenuItems[selectedThirdIndex]
            return entry.isDirectory ? nil : entry.url
        }
        let submenuItems = currentSubmenuItems()
        guard submenuItems.indices.contains(selectedSubIndex) else { return nil }
        let selectedItem = submenuItems[selectedSubIndex]
        guard selectedItem.id == "movies_folder" else { return nil }
        return moviesTopLevelPreviewURLs(limit: 1).first
    }

    /// A movie's menu picture: its embedded cover art, or else a frame from the video.
    nonisolated func generateMoviePreviewImage(for url: URL) async -> NSImage? {
        let standardizedURL = url.standardizedFileURL
        if CloudFolders.isStillInTheCloud(standardizedURL) {
            // Reading it for a picture would fetch the whole movie from its service: it's
            // fetched when it's played. Its service may have a picture of it to show.
            #if canImport(QuickLookThumbnailing)
                if let picture = await CloudFolders.picture(of: standardizedURL, longestSide: 1100) {
                    return NSImage(cgImage: picture, size: NSSize(width: picture.width, height: picture.height))
                }
            #endif
            return nil
        }
        #if !FIRSTROW_PORTABLE
            if await MediaEngine.plays(standardizedURL) {
                // (A kind of file the system knows nothing of: the engine reads it.)
                let found = await MediaEngine.describe(standardizedURL)
                if let artworkData = found[MediaEngineKey.artwork] as? Data,
                   let artwork = cachedDecodedDisplayArtworkImage(
                       from: artworkData,
                       sourceKey: "movie_artwork::\(standardizedURL.path)",
                       maxPixelSize: 1100,
                   )
                {
                    return artwork
                }
                let length = (found[MediaEngineKey.duration] as? Double) ?? 0
                let seconds = length > 0 ? min(60, length * 0.25) : 10
                guard let frame = await MediaEngine.picture(of: standardizedURL, atSeconds: seconds) else { return nil }
                return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }
        #endif
        if let artworkData = await loadEmbeddedArtworkData(from: standardizedURL),
           let artwork = cachedDecodedDisplayArtworkImage(
               from: artworkData,
               sourceKey: "movie_artwork::\(standardizedURL.path)",
               maxPixelSize: 1100,
           )
        {
            return artwork
        }
        return await generateMovieThumbnail(for: standardizedURL)
    }

    nonisolated func generateMovieThumbnail(for url: URL, preferredSeconds: Double? = nil) async -> NSImage? {
        let standardizedURL = url.standardizedFileURL
        if shouldSkipMovieThumbnailGeneration(for: standardizedURL) || CloudFolders.isStillInTheCloud(standardizedURL) {
            return nil
        }
        #if !FIRSTROW_PORTABLE
            if await MediaEngine.plays(standardizedURL) {
                guard let frame = await MediaEngine.picture(of: standardizedURL, atSeconds: max(0, preferredSeconds ?? 10)) else { return nil }
                return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            }
        #endif
        let asset = AVURLAsset(url: standardizedURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1100, height: 1100)
        func generateSync(at time: CMTime) async -> CGImage? {
            if #available(macOS 13.0, iOS 16.0, tvOS 16.0, *) {
                return try? await generator.image(at: time).image
            }
            return try? generator.copyCGImage(at: time, actualTime: nil)
        }

        var candidateTimes: [CMTime] = []
        if let preferredSeconds, preferredSeconds > 0 {
            candidateTimes.append(CMTime(seconds: preferredSeconds, preferredTimescale: 600))
        } else {
            // Avoid defaulting to the first frame; probe deeper timestamps first.
            for second in [60.0, 45.0, 30.0, 20.0, 12.0, 8.0, 5.0, 2.0] {
                candidateTimes.append(CMTime(seconds: second, preferredTimescale: 600))
            }
        }
        candidateTimes.append(.zero)

        for time in candidateTimes {
            guard let cgImage = await generateSync(at: time) else { continue }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return nil
    }

    func resolveMoviesFolderSubmenuPreviewURLs() -> [URL] {
        guard activeRootItemID == "movies", isInSubmenu, !isInThirdMenu else { return [] }
        guard selectedMoviesSubmenuItemID == "movies_folder" else { return [] }
        return moviesTopLevelPreviewURLs(limit: moviesFolderSubmenuPreviewLoadLimit)
    }

    func moviesFolderSubmenuPreviewIdentityKey(from urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "|")
    }

    func clearMoviesFolderSubmenuPreviewState() {
        guard !moviesFolderSubmenuPreviewIdentity.isEmpty || !moviesFolderSubmenuPreviewDescriptors.isEmpty else {
            return
        }
        moviesFolderSubmenuPreviewIdentity = ""
        _ = incrementRequestID(&moviesFolderSubmenuPreviewRequestID)
        withAnimation(.easeInOut(duration: 0.18)) {
            moviesFolderSubmenuPreviewDescriptors = []
        }
    }

    func refreshMoviesFolderSubmenuPreviewForCurrentContext() {
        let previewURLs = resolveMoviesFolderSubmenuPreviewURLs()
        guard !previewURLs.isEmpty else {
            clearMoviesFolderSubmenuPreviewState()
            return
        }
        let identity = moviesFolderSubmenuPreviewIdentityKey(from: previewURLs)
        guard moviesFolderSubmenuPreviewIdentity != identity else { return }
        moviesFolderSubmenuPreviewIdentity = identity
        let requestID = incrementRequestID(&moviesFolderSubmenuPreviewRequestID)
        let cacheSnapshot = moviePreviewCache
        let cachedDescriptors: [MovieGapPreviewDescriptor] = previewURLs.compactMap { url in
            guard let cached = cacheSnapshot[url.path] else { return nil }
            return MovieGapPreviewDescriptor(
                id: "movies_folder_preview:\(url.path)",
                image: cached,
                aspectRatio: 16.0 / 9.0,
                sizeScale: 1.0,
            )
        }
        if !cachedDescriptors.isEmpty {
            withAnimation(.easeInOut(duration: 0.18)) {
                moviesFolderSubmenuPreviewDescriptors = cachedDescriptors
            }
        }
        Task.detached(priority: .userInitiated) { [previewURLs, identity, cacheSnapshot] in
            var generatedCacheEntries: [String: NSImage] = [:]
            var resolvedDescriptors: [MovieGapPreviewDescriptor] = []
            resolvedDescriptors.reserveCapacity(previewURLs.count)
            for url in previewURLs {
                let cacheKey = url.path
                let image: NSImage?
                if let cached = cacheSnapshot[cacheKey] {
                    image = cached
                } else {
                    image = await self.generateMoviePreviewImage(for: url)
                    if let image {
                        generatedCacheEntries[cacheKey] = image
                    }
                }
                guard let image else { continue }
                resolvedDescriptors.append(
                    MovieGapPreviewDescriptor(
                        id: "movies_folder_preview:\(cacheKey)",
                        image: image,
                        aspectRatio: 16.0 / 9.0,
                        sizeScale: 1.0,
                    ),
                )
            }
            let generatedCacheEntriesSnapshot = generatedCacheEntries
            let resolvedDescriptorsSnapshot = resolvedDescriptors
            await MainActor.run {
                guard self.moviesFolderSubmenuPreviewRequestID == requestID else { return }
                guard self.moviesFolderSubmenuPreviewIdentity == identity else { return }
                for (cacheKey, image) in generatedCacheEntriesSnapshot {
                    self.moviePreviewCache[cacheKey] = image
                }
                withAnimation(.easeInOut(duration: 0.22)) {
                    self.moviesFolderSubmenuPreviewDescriptors = resolvedDescriptorsSnapshot
                }
            }
        }
    }

    func refreshMoviePreviewForCurrentContext() {
        refreshMoviesFolderSubmenuPreviewForCurrentContext()
        if isInThirdMenu, thirdMenuMode == .moviesITunesTop {
            moviePreviewTargetURL = nil
            _ = incrementRequestID(&moviePreviewRequestID)
            withAnimation(.easeInOut(duration: 0.18)) {
                moviePreviewImage = nil
            }
            return
        }
        let resolvedTarget = resolveMoviePreviewTargetURL()?.standardizedFileURL
        if moviePreviewTargetURL?.standardizedFileURL == resolvedTarget {
            return
        }
        moviePreviewTargetURL = resolvedTarget
        let requestID = incrementRequestID(&moviePreviewRequestID)
        guard let resolvedTarget else {
            withAnimation(.easeInOut(duration: 0.18)) {
                moviePreviewImage = nil
            }
            return
        }
        let cacheKey = resolvedTarget.path
        if let cached = moviePreviewCache[cacheKey] {
            withAnimation(.easeInOut(duration: 0.18)) {
                moviePreviewImage = cached
            }
            return
        }
        Task.detached(priority: .userInitiated) { [resolvedTarget] in
            let generatedThumbnail = await self.generateMoviePreviewImage(for: resolvedTarget)
            await MainActor.run {
                guard self.moviePreviewRequestID == requestID else { return }
                guard self.moviePreviewTargetURL?.standardizedFileURL == resolvedTarget else { return }
                if let generatedThumbnail {
                    self.moviePreviewCache[cacheKey] = generatedThumbnail
                    withAnimation(.easeInOut(duration: 0.22)) {
                        self.moviePreviewImage = generatedThumbnail
                    }
                }
            }
        }
    }

    func moviesFolderDirectorySelectionKey(for directoryURL: URL) -> String {
        directoryURL.standardizedFileURL.path
    }

    func rememberCurrentMoviesFolderSelectionIndex() {
        guard thirdMenuMode == .moviesFolder, !isShowingContinueWatching, tvShowListing == nil else { return }
        guard !thirdMenuItems.isEmpty else { return }
        let maxIndex = max(0, thirdMenuItems.count - 1)
        let clampedIndex = min(max(0, selectedThirdIndex), maxIndex)
        // (The top of Movies Folder is no one folder: it has a key of its own.)
        let key = thirdMenuCurrentURL.map { moviesFolderDirectorySelectionKey(for: $0) } ?? Self.moviesTopLevelSelectionKey
        moviesFolderSelectionIndexByDirectoryPath[key] = clampedIndex
    }

    func rememberedMoviesFolderSelectionIndex(for directoryURL: URL) -> Int? {
        let key = moviesFolderDirectorySelectionKey(for: directoryURL)
        return moviesFolderSelectionIndexByDirectoryPath[key]
    }

    func loadThirdMenuDirectory(_ directoryURL: URL, resetSelection: Bool) {
        // (A folder opened from the top of Movies Folder: Back from it goes back there.)
        if thirdMenuCurrentURL == nil {
            thirdMenuRootURL = directoryURL.standardizedFileURL
        }
        let standardizedDirectory = directoryURL.standardizedFileURL
        thirdMenuCurrentURL = standardizedDirectory
        isLoadingMoviesFolderEntries = true
        let requestID = incrementRequestID(&moviesFolderEntriesRequestID)
        Task(priority: .userInitiated) {
            let scannedEntries = scanMoviesFolderEntries(in: standardizedDirectory)
            await MainActor.run {
                guard moviesFolderEntriesRequestID == requestID else { return }
                guard thirdMenuMode == .moviesFolder else { return }
                guard thirdMenuCurrentURL?.standardizedFileURL == standardizedDirectory else { return }
                isLoadingMoviesFolderEntries = false
                thirdMenuItems = scannedEntries
                let maxIndex = max(0, scannedEntries.count - 1)
                if let remembered = rememberedMoviesFolderSelectionIndex(for: standardizedDirectory) {
                    selectedThirdIndex = min(max(0, remembered), maxIndex)
                } else if resetSelection {
                    selectedThirdIndex = 0
                } else {
                    selectedThirdIndex = min(max(0, selectedThirdIndex), maxIndex)
                }
                if !scannedEntries.isEmpty {
                    let key = moviesFolderDirectorySelectionKey(for: standardizedDirectory)
                    moviesFolderSelectionIndexByDirectoryPath[key] = selectedThirdIndex
                }
                refreshDetailPreviewForCurrentContext()
                let isShowingRootDirectory =
                    thirdMenuRootURL?.standardizedFileURL == standardizedDirectory
                if isShowingRootDirectory, scannedEntries.isEmpty {
                    // (Its last movie has just been deleted: the top of Movies Folder again.)
                    loadMoviesTopLevel(resetSelection: false)
                }
            }
        }
    }

    func enterMoviesFolderMenu() {
        #if os(iOS)
            if promptForMoviesFolderPickerIfNeeded() { return }
        #endif
        transitionMenuForFolderSwap(revealWhen: { !self.isLoadingMoviesFolderEntries }) {
            self.isShowingContinueWatching = false
            self.thirdMenuMode = .moviesFolder
            self.resetAllITunesTopMenusForNonITunesContext()
            self.resetMusicCategoryStateForNonMusicITunesTop()
            self.activeMusicLibraryMediaType = .songs
            self.musicSongsShowsShuffleAction = false
            self.moviesFolderSelectionIndexByDirectoryPath = [:]
            self.isInThirdMenu = true
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
            self.loadMoviesTopLevel(resetSelection: true)
        }
    }
}

extension MenuView {
    struct MoviesFolderEntry: Identifiable {
        let id: String
        let title: String
        let url: URL
        let isDirectory: Bool
        /// Brought in with Movies > Import (or added in Settings > Media Folders): it is at
        /// the top of Movies Folder because it was asked for, and can be taken out again.
        var isImported = false
    }

    struct MovieGapPreviewDescriptor: Equatable {
        let id: String
        let image: NSImage
        let aspectRatio: CGFloat
        let sizeScale: CGFloat
        static func == (lhs: MovieGapPreviewDescriptor, rhs: MovieGapPreviewDescriptor) -> Bool {
            lhs.id == rhs.id && lhs.aspectRatio == rhs.aspectRatio && lhs.sizeScale == rhs.sizeScale
        }
    }

    var moviesFallbackImage: NSImage? {
        ModernTheme.isActive ? ModernTheme.placeholderArtwork(symbol: "film.fill", aspect: 2.0 / 3.0) : NSImage(named: "moviesfallback")
    }
}
