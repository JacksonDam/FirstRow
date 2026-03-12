import AVFoundation
import Darwin
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
    import UIKit
#endif

extension MenuView {
    #if os(iOS)
        var moviesFolderBookmarkDefaultsKey: String {
            "firstRow.movies.bookmarkedFolder"
        }

        func resolveBookmarkedMoviesFolderURL() -> URL? {
            guard let bookmarkData = UserDefaults.standard.data(forKey: moviesFolderBookmarkDefaultsKey) else {
                return nil
            }
            var isStale = false
            do {
                let resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale,
                )
                if isStale {
                    storeBookmarkedMoviesFolderURL(resolvedURL)
                }
                return resolvedURL
            } catch {
                UserDefaults.standard.removeObject(forKey: moviesFolderBookmarkDefaultsKey)
                return nil
            }
        }

        func storeBookmarkedMoviesFolderURL(_ folderURL: URL) {
            do {
                let bookmarkData = try folderURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil,
                )
                UserDefaults.standard.set(bookmarkData, forKey: moviesFolderBookmarkDefaultsKey)
            } catch {
                print("Unable to bookmark picked Movies folder at path: \(folderURL.path) (\(error.localizedDescription))")
            }
        }

        func isSupportedMovieFile(url: URL, values: URLResourceValues?) -> Bool {
            let normalizedExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isSupportedByExtension = supportedMovieFileExtensions.contains(normalizedExtension)
            let isSupportedByType = values?.contentType?.conforms(to: .movie) ?? false
            return isSupportedByExtension || isSupportedByType
        }

        func importMoviesFromFolderIntoDocuments(_ folderURL: URL) {
            let didStartSecurityScope = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didStartSecurityScope {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }
            let fileManager = FileManager.default
            let documentsDirectory = moviesDocumentsDirectoryURL().standardizedFileURL
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .contentTypeKey]
            let urls: [URL]
            do {
                urls = try fileManager.contentsOfDirectory(
                    at: folderURL,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles],
                )
            } catch {
                print("Unable to import movies from picked folder at path: \(folderURL.path) (\(error.localizedDescription))")
                return
            }
            for sourceURL in urls {
                let values = try? sourceURL.resourceValues(forKeys: resourceKeys)
                let isDirectory = values?.isDirectory ?? false
                if isDirectory { continue }
                guard isSupportedMovieFile(url: sourceURL, values: values) else { continue }
                let standardizedSource = sourceURL.standardizedFileURL
                if standardizedSource.path.hasPrefix(documentsDirectory.path + "/") {
                    continue
                }
                var destinationURL = documentsDirectory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    let baseName = sourceURL.deletingPathExtension().lastPathComponent
                    let pathExtension = sourceURL.pathExtension
                    var duplicateIndex = 2
                    while fileManager.fileExists(atPath: destinationURL.path) {
                        let duplicateName = if pathExtension.isEmpty {
                            "\(baseName) \(duplicateIndex)"
                        } else {
                            "\(baseName) \(duplicateIndex).\(pathExtension)"
                        }
                        destinationURL = documentsDirectory.appendingPathComponent(duplicateName, isDirectory: false)
                        duplicateIndex += 1
                    }
                }
                do {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                } catch {
                    print(
                        "Unable to copy movie from \(sourceURL.lastPathComponent) to Documents (\(error.localizedDescription))",
                    )
                }
            }
        }

        func importMoviesFromBookmarkedFolderIfNeeded() {
            guard let bookmarkedFolderURL = resolveBookmarkedMoviesFolderURL() else { return }
            importMoviesFromFolderIntoDocuments(bookmarkedFolderURL)
        }

        func handleMoviesFolderPickedFromFiles(_ selectedFolderURL: URL) {
            storeBookmarkedMoviesFolderURL(selectedFolderURL)
            importMoviesFromFolderIntoDocuments(selectedFolderURL)
            if thirdMenuMode == .moviesFolder {
                loadThirdMenuDirectory(moviesRootDirectoryURL(), resetSelection: true)
            }
        }

        func promptForMoviesFolderPickerIfNeeded() {
            guard thirdMenuMode == .moviesFolder else { return }
            guard thirdMenuItems.isEmpty else { return }
            guard !hasPromptedMoviesFolderPickerThisSession else { return }
            hasPromptedMoviesFolderPickerThisSession = true
            DispatchQueue.main.async {
                self.isMoviesFolderPickerPresented = true
            }
        }
    #else
        func isSupportedMovieFile(url: URL, values _: URLResourceValues?) -> Bool {
            let normalizedExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return supportedMovieFileExtensions.contains(normalizedExtension)
        }
    #endif

    nonisolated func realUserHomeDirectoryURL() -> URL? {
        guard let passwdEntry = getpwuid(getuid()),
              let rawHome = passwdEntry.pointee.pw_dir
        else {
            return nil
        }
        let homePath = String(cString: rawHome)
        guard !homePath.isEmpty else { return nil }
        return URL(fileURLWithPath: homePath, isDirectory: true)
    }

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
            importMoviesFromBookmarkedFolderIfNeeded()
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
            if let homeURL = realUserHomeDirectoryURL() {
                return homeURL.appendingPathComponent("Movies", isDirectory: true)
            }
            let guessedHome = URL(fileURLWithPath: "/Users/\(NSUserName())", isDirectory: true)
            if FileManager.default.fileExists(atPath: guessedHome.path) {
                return guessedHome.appendingPathComponent("Movies", isDirectory: true)
            }
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Movies", isDirectory: true)
        #endif
    }

    var supportedMovieFileExtensions: Set<String> {
        [
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
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .contentTypeKey]
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
                return true
            }
            guard values?.isRegularFile == true else { continue }
            if isSupportedMovieFile(url: url, values: values) {
                return true
            }
        }
        return false
    }

    func scanMoviesFolderEntries(in directoryURL: URL) -> [MoviesFolderEntry] {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .contentTypeKey]
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
        for url in urls {
            let values = try? url.resourceValues(forKeys: resourceKeys)
            let isDirectory = values?.isDirectory ?? false
            if isDirectory {
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
            if isSupportedMovieFile(url: url, values: values) {
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
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .contentTypeKey]
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
            guard isSupportedMovieFile(url: url, values: values) else { continue }
            resolved.append(url.standardizedFileURL)
        }
        return resolved
    }

    func resetThirdMenuDirectoryState() {
        thirdMenuItems = []
        thirdMenuCurrentURL = nil
        thirdMenuRootURL = nil
        isLoadingMoviesFolderEntries = false
        _ = incrementRequestID(&moviesFolderEntriesRequestID)
    }

    func resolveMoviePreviewTargetURL() -> URL? {
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
        return firstMovieFileURL(in: moviesRootDirectoryURL())
    }

    nonisolated func generateMovieThumbnail(for url: URL, preferredSeconds: Double? = nil) async -> NSImage? {
        let standardizedURL = url.standardizedFileURL
        if shouldSkipMovieThumbnailGeneration(for: standardizedURL) {
            return nil
        }
        let asset = AVURLAsset(url: standardizedURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1100, height: 1100)
        func generateSync(at time: CMTime) -> CGImage? {
            try? generator.copyCGImage(at: time, actualTime: nil)
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
            guard let cgImage = generateSync(at: time) else { continue }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return nil
    }

    func resolveMoviesFolderSubmenuPreviewURLs() -> [URL] {
        guard activeRootItemID == "movies", isInSubmenu, !isInThirdMenu else { return [] }
        guard selectedMoviesSubmenuItemID == "movies_folder" else { return [] }
        return previewMovieFileURLs(
            in: moviesRootDirectoryURL(),
            limit: moviesFolderSubmenuPreviewLoadLimit,
        )
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
                    image = await self.generateMovieThumbnail(for: url)
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
            let generatedThumbnail = await self.generateMovieThumbnail(for: resolvedTarget)
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
        guard thirdMenuMode == .moviesFolder else { return }
        guard let currentURL = thirdMenuCurrentURL else { return }
        guard !thirdMenuItems.isEmpty else { return }
        let maxIndex = max(0, thirdMenuItems.count - 1)
        let clampedIndex = min(max(0, selectedThirdIndex), maxIndex)
        let key = moviesFolderDirectorySelectionKey(for: currentURL)
        moviesFolderSelectionIndexByDirectoryPath[key] = clampedIndex
    }

    func rememberedMoviesFolderSelectionIndex(for directoryURL: URL) -> Int? {
        let key = moviesFolderDirectorySelectionKey(for: directoryURL)
        return moviesFolderSelectionIndexByDirectoryPath[key]
    }

    func loadThirdMenuDirectory(_ directoryURL: URL, resetSelection: Bool) {
        let standardizedDirectory = directoryURL.standardizedFileURL
        thirdMenuCurrentURL = standardizedDirectory
        isLoadingMoviesFolderEntries = true
        let requestID = incrementRequestID(&moviesFolderEntriesRequestID)
        DispatchQueue.global(qos: .userInitiated).async {
            let scannedEntries = self.scanMoviesFolderEntries(in: standardizedDirectory)
            DispatchQueue.main.async {
                guard self.moviesFolderEntriesRequestID == requestID else { return }
                guard self.thirdMenuMode == .moviesFolder else { return }
                guard self.thirdMenuCurrentURL?.standardizedFileURL == standardizedDirectory else { return }
                self.isLoadingMoviesFolderEntries = false
                self.thirdMenuItems = scannedEntries
                let maxIndex = max(0, scannedEntries.count - 1)
                if let remembered = self.rememberedMoviesFolderSelectionIndex(for: standardizedDirectory) {
                    self.selectedThirdIndex = min(max(0, remembered), maxIndex)
                } else if resetSelection {
                    self.selectedThirdIndex = 0
                } else {
                    self.selectedThirdIndex = min(max(0, self.selectedThirdIndex), maxIndex)
                }
                if !scannedEntries.isEmpty {
                    let key = self.moviesFolderDirectorySelectionKey(for: standardizedDirectory)
                    self.moviesFolderSelectionIndexByDirectoryPath[key] = self.selectedThirdIndex
                }
                self.refreshDetailPreviewForCurrentContext()
                let isShowingRootDirectory =
                    self.thirdMenuRootURL?.standardizedFileURL == standardizedDirectory
                if isShowingRootDirectory, scannedEntries.isEmpty {
                    self.isInThirdMenu = false
                    self.thirdMenuMode = .none
                    self.thirdMenuOpacity = 0
                    self.submenuOpacity = 1
                    self.headerText = self.rootMenuTitle(for: self.activeRootItemID)
                    self.resetThirdMenuDirectoryState()
                    self.moviesFolderSelectionIndexByDirectoryPath = [:]
                    self.refreshDetailPreviewForCurrentContext()
                    self.presentNoMoviesLibraryFeatureErrorScreen(afterMenuSwap: true)
                }
            }
        }
    }

    func enterMoviesFolderMenu() {
        transitionMenuForFolderSwap(revealWhen: { !isLoadingMoviesFolderEntries }) {
            let rootURL = moviesRootDirectoryURL()
            thirdMenuMode = .moviesFolder
            resetAllITunesTopMenusForNonITunesContext()
            resetMusicCategoryStateForNonMusicITunesTop()
            activeMusicLibraryMediaType = .songs
            musicSongsShowsShuffleAction = false
            moviesFolderSelectionIndexByDirectoryPath = [:]
            thirdMenuRootURL = rootURL
            loadThirdMenuDirectory(rootURL, resetSelection: true)
            isInThirdMenu = true
            #if os(iOS)
                promptForMoviesFolderPickerIfNeeded()
            #endif
            submenuOpacity = 0
            thirdMenuOpacity = 1
        }
    }
}

extension MenuView {
    struct MoviesFolderEntry: Identifiable {
        let id: String
        let title: String
        let url: URL
        let isDirectory: Bool
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
        NSImage(named: "moviesfallback")
    }
}
