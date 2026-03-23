import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

extension MenuView {
    func isSupportedMovieFile(url: URL, values _: URLResourceValues?) -> Bool {
        let normalizedExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return supportedMovieFileExtensions.contains(normalizedExtension)
    }

    nonisolated func realUserHomeDirectoryURL() -> URL? {
        let username = NSUserName()
        guard !username.isEmpty else { return nil }
        return URL(fileURLWithPath: "/Users/\(username)", isDirectory: true)
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

    nonisolated func externalVolumeRootURLs() -> [URL] {
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [],
            options: [.skipHiddenVolumes]
        ) else { return [] }
        return volumes.filter { url in
            let path = url.standardizedFileURL.path
            return path != "/" && path.hasPrefix("/Volumes/")
        }
    }

    nonisolated func externalMoviesRootURLs() -> [URL] {
        externalVolumeRootURLs().compactMap { volumeURL in
            let moviesURL = volumeURL.appendingPathComponent("Movies", isDirectory: true)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: moviesURL.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return moviesURL
        }
    }

    func allMoviesRootURLs() -> [URL] {
        [moviesRootDirectoryURL()] + externalMoviesRootURLs()
    }

    nonisolated func moviesRootDisplayTitle(for url: URL) -> String {
        let internalPath = realUserHomeDirectoryURL()?
            .appendingPathComponent("Movies").standardizedFileURL.path
        if url.standardizedFileURL.path == internalPath {
            return "My Mac"
        }
        return (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
            ?? url.lastPathComponent
    }

    func loadMoviesRootSelectorEntries(resetSelection: Bool) {
        isLoadingMoviesFolderEntries = false
        thirdMenuCurrentURL = nil
        thirdMenuRootURL = nil
        thirdMenuItems = movieLibraryRootURLs.map { url in
            MoviesFolderEntry(
                id: url.standardizedFileURL.path,
                title: moviesRootDisplayTitle(for: url),
                url: url,
                isDirectory: true,
            )
        }
        if resetSelection { selectedThirdIndex = 0 }
        refreshDetailPreviewForCurrentContext()
    }

    func moviesRootDirectoryURL() -> URL {
        realUserHomeDirectoryURL()!.appendingPathComponent("Movies", isDirectory: true)
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
        8
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
        movieLibraryRootURLs = []
        isLoadingMoviesFolderEntries = false
        _ = incrementRequestID(&moviesFolderEntriesRequestID)
    }

    func resolveMoviePreviewTargetURL() -> URL? {
        guard activeRootItemID == "movies", isInSubmenu else { return nil }
        if isInThirdMenu {
            switch thirdMenuMode {
            case .moviesFolder:
                guard thirdMenuItems.indices.contains(selectedThirdIndex) else { return nil }
                let entry = thirdMenuItems[selectedThirdIndex]
                return entry.isDirectory ? nil : entry.url
            case .videoPodcastEpisodes:
                return selectedVideoPodcastEpisodeForPreview?.mediaURL?.standardizedFileURL
            default:
                return nil
            }
        }
        let submenuItems = currentSubmenuItems()
        guard submenuItems.indices.contains(selectedSubIndex) else { return nil }
        let selectedItem = submenuItems[selectedSubIndex]
        guard selectedItem.id == "movies_folder" else { return nil }
        return firstMovieFileURL(in: moviesRootDirectoryURL())
    }

    func resolveMovieGapPreviewLoopURL() -> URL? {
        guard isInThirdMenu else { return nil }
        switch thirdMenuMode {
        case .moviesFolder:
            guard thirdMenuItems.indices.contains(selectedThirdIndex) else { return nil }
            let entry = thirdMenuItems[selectedThirdIndex]
            return entry.isDirectory ? nil : entry.url.standardizedFileURL
        case .videoPodcastEpisodes:
            return selectedVideoPodcastEpisodeForPreview?.mediaURL?.standardizedFileURL
        default:
            return nil
        }
    }

    nonisolated func generateMovieThumbnail(for url: URL, preferredSeconds: Double? = nil) async -> NSImage? {
        let standardizedURL = url.standardizedFileURL
        if shouldSkipMovieThumbnailGeneration(for: standardizedURL) {
            return nil
        }
        let asset = AVURLAsset(url: standardizedURL)
        func makeGenerator() -> AVAssetImageGenerator {
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 1100, height: 1100)
                    return generator
                }
                func makeImage(from cgImage: CGImage) -> NSImage {
                    NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                }
                func generateSync(at time: CMTime, requestsExactFrame: Bool) -> NSImage? {
                    let generator = makeGenerator()
                    if requestsExactFrame {
                        generator.requestedTimeToleranceBefore = .zero
                        generator.requestedTimeToleranceAfter = .zero
                    }
                    guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                        return nil
                    }
                    return makeImage(from: cgImage)
                }

                if let preferredSeconds, preferredSeconds > 0 {
                    let preferredTime = CMTime(seconds: preferredSeconds, preferredTimescale: 600)
                    if let exactImage = generateSync(at: preferredTime, requestsExactFrame: true) {
                        return exactImage
                    }
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
            guard let image = generateSync(at: time, requestsExactFrame: false) else { continue }
            return image
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

    func refreshMoviesFolderGapPlayer() {
        guard let url = resolveMovieGapPreviewLoopURL() else {
            stopMoviesFolderGapPlayer()
            return
        }

        guard url != moviesFolderGapPlayerURL else { return }

        moviesFolderGapPlayerDebounceWork?.cancel()

        moviesFolderGapPlayerDebounceWork = Task { @MainActor in
            try? await firstRowSleep(1.0)
            guard !Task.isCancelled else { return }
            let item = AVPlayerItem(url: url)
            let queuePlayer = AVQueuePlayer()
            queuePlayer.isMuted = true
            let looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
            queuePlayer.play()
            let previousPlayer = moviesFolderGapPlayer
            moviesFolderGapPlayerURL = url
            moviesFolderGapPlayer = queuePlayer
            moviesFolderGapPlayerLooper = looper
            previousPlayer?.pause()
            moviesFolderGapPlayerDebounceWork = nil
        }
    }

    func stopMoviesFolderGapPlayer() {
        moviesFolderGapPlayerDebounceWork?.cancel()
        moviesFolderGapPlayer?.pause()
        moviesFolderGapPlayerLooper = nil
        moviesFolderGapPlayer = nil
        moviesFolderGapPlayerURL = nil
    }

    func refreshMoviePreviewForCurrentContext() {
        refreshMoviesFolderGapPlayer()
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
        if thirdMenuCurrentURL == nil, !movieLibraryRootURLs.isEmpty {
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

    func enterMoviesFolderMenu() {
        transitionMenuForFolderSwap(revealWhen: { !isLoadingMoviesFolderEntries }) {
            thirdMenuMode = .moviesFolder
            resetAllITunesTopMenusForNonITunesContext()
            resetMusicCategoryStateForNonMusicITunesTop()
            activeMusicLibraryMediaType = .songs
            musicSongsShowsShuffleAction = false
            moviesFolderSelectionIndexByDirectoryPath = [:]
            isInThirdMenu = true
            submenuOpacity = 0
            thirdMenuOpacity = 1
            let roots = allMoviesRootURLs()
            movieLibraryRootURLs = roots.count > 1 ? roots : []
            if roots.count > 1 {
                loadMoviesRootSelectorEntries(resetSelection: true)
            } else {
                thirdMenuRootURL = roots[0]
                loadThirdMenuDirectory(roots[0], resetSelection: true)
            }
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
