import AVFoundation
import Foundation
import MusicKit
import StoreKit
import SwiftUI
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif

#if os(macOS)
    final class AppleMusicCatalogPlaybackCapabilityCache {
        static let shared = AppleMusicCatalogPlaybackCapabilityCache()

        private let lock = NSLock()
        private var cachedValue: Bool?
        private var hasAttemptedResolution = false

        func canPlayCatalogContent(requestPermissionIfNeeded: Bool) -> Bool {
            lock.lock()
            if let cachedValue {
                lock.unlock()
                return cachedValue
            }
            let shouldResolve = !hasAttemptedResolution || requestPermissionIfNeeded
            if shouldResolve {
                hasAttemptedResolution = true
            }
            lock.unlock()

            guard shouldResolve else { return false }
            let resolvedValue = resolve(requestPermissionIfNeeded: requestPermissionIfNeeded)

            lock.lock()
            cachedValue = resolvedValue
            lock.unlock()
            return resolvedValue
        }

        private func resolve(requestPermissionIfNeeded: Bool) -> Bool {
            if #available(macOS 12.0, *) {
                var authorizationStatus = MusicAuthorization.currentStatus
                if requestPermissionIfNeeded, authorizationStatus == .notDetermined {
                    let semaphore = DispatchSemaphore(value: 0)
                    Task.detached(priority: .userInitiated) {
                        authorizationStatus = await MusicAuthorization.request()
                        semaphore.signal()
                    }
                    semaphore.wait()
                }
                guard authorizationStatus == .authorized else { return false }
                let semaphore = DispatchSemaphore(value: 0)
                var canPlayCatalogContent = false
                Task.detached(priority: .userInitiated) {
                    defer { semaphore.signal() }
                    do {
                        canPlayCatalogContent = try await MusicSubscription.current.canPlayCatalogContent
                    } catch {
                        canPlayCatalogContent = false
                    }
                }
                semaphore.wait()
                return canPlayCatalogContent
            } else {
                let authorizationStatus = SKCloudServiceController.authorizationStatus()
                guard authorizationStatus == .authorized else { return false }
                let semaphore = DispatchSemaphore(value: 0)
                var canPlayCatalogContent = false
                SKCloudServiceController().requestCapabilities { capabilities, _ in
                    canPlayCatalogContent = capabilities.contains(.musicCatalogPlayback)
                    semaphore.signal()
                }
                semaphore.wait()
                return canPlayCatalogContent
            }
        }
    }

    final class UnavailableAppleMusicTrackCache {
        static let shared = UnavailableAppleMusicTrackCache()

        private let lock = NSLock()
        private var cachedPersistentIDHexes: Set<String>?

        func persistentIDHexes() -> Set<String> {
            lock.lock()
            if let cachedPersistentIDHexes {
                lock.unlock()
                return cachedPersistentIDHexes
            }
            lock.unlock()

            let fetchedPersistentIDHexes = fetchPersistentIDHexes()

            lock.lock()
            if cachedPersistentIDHexes == nil {
                cachedPersistentIDHexes = fetchedPersistentIDHexes
            }
            let resolvedPersistentIDHexes = cachedPersistentIDHexes ?? fetchedPersistentIDHexes
            lock.unlock()
            return resolvedPersistentIDHexes
        }

        private func fetchPersistentIDHexes() -> Set<String> {
            // Music.app exposes catalog availability through AppleScript cloud status.
            let source = """
            tell application "Music"
                set unavailableTrackIDs to {}
                set unavailableTrackIDs to unavailableTrackIDs & (get persistent ID of every track of library playlist 1 whose cloud status is error)
                set unavailableTrackIDs to unavailableTrackIDs & (get persistent ID of every track of library playlist 1 whose cloud status is ineligible)
                set unavailableTrackIDs to unavailableTrackIDs & (get persistent ID of every track of library playlist 1 whose cloud status is no longer available)
                set unavailableTrackIDs to unavailableTrackIDs & (get persistent ID of every track of library playlist 1 whose cloud status is prerelease)
                set unavailableTrackIDs to unavailableTrackIDs & (get persistent ID of every track of library playlist 1 whose cloud status is removed)
                set AppleScript's text item delimiters to linefeed
                set unavailableTrackIDsText to unavailableTrackIDs as text
                set AppleScript's text item delimiters to ""
                return unavailableTrackIDsText
            end tell
            """
            var executionError: NSDictionary?
            let resultDescriptor = NSAppleScript(source: source)?.executeAndReturnError(&executionError)
            if let executionError {
                print("[Music] unavailable track lookup error: \(executionError)")
            }
            guard let rawPersistentIDText = resultDescriptor?.stringValue else {
                return []
            }
            let separators = CharacterSet.newlines.union(.whitespacesAndNewlines)
            return Set(
                rawPersistentIDText
                    .components(separatedBy: separators)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                    .filter { !$0.isEmpty },
            )
        }
    }
#endif

extension MenuView {
    func finishStartupMusicLibraryPreload() {
        isStartupMusicLibraryPreloadComplete = true
        withAnimation(.easeInOut(duration: 0.28)) {
            startupMusicLibraryPreloadOverlayOpacity = 0
        }
    }

    func musicPlaybackPool() -> [MusicLibrarySongEntry] {
        if let cachedShuffleSongs = musicShuffleSongsCache, !cachedShuffleSongs.isEmpty {
            return cachedShuffleSongs
        }
        if let cachedSongs = musicAllSongsCache, !cachedSongs.isEmpty {
            return cachedSongs
        }
        return []
    }

    func randomCachedMusicLibrarySong() -> MusicLibrarySongEntry? {
        musicPlaybackPool().randomElement()
    }

    func loadStartupMusicLibrarySnapshot() async throws -> (
        sortedSongs: [MusicLibrarySongEntry],
        shuffleSongs: [MusicLibrarySongEntry],
        itemIndices: [String: Int],
        artworkDataByAlbumKey: [String: Data],
    ) {
        #if os(macOS)
            _ = AppleMusicCatalogPlaybackCapabilityCache.shared.canPlayCatalogContent(
                requestPermissionIfNeeded: true,
            )
        #endif
        #if canImport(iTunesLibrary)
            let result = try await fetchMusicLibrarySongsForShuffleWithItemIndices()
            return (
                sortedSongs: sortedMusicLibraryEntries(result.songs),
                shuffleSongs: result.songs,
                itemIndices: result.itemIndices,
                artworkDataByAlbumKey: result.artworkDataByAlbumKey,
            )
        #else
            let songs = try fetchMusicLibrarySongsForShuffle()
            return (
                sortedSongs: sortedMusicLibraryEntries(songs),
                shuffleSongs: songs,
                itemIndices: [:],
                artworkDataByAlbumKey: [:],
            )
        #endif
    }

    func beginStartupMusicLibraryPreloadIfNeeded() {
        guard !hasStartedStartupMusicLibraryPreload else { return }
        hasStartedStartupMusicLibraryPreload = true
        if musicAllSongsCache != nil || musicShuffleSongsCache != nil {
            finishStartupMusicLibraryPreload()
            return
        }
        let requestID = incrementRequestID(&musicStartupPreloadRequestID)
        requestMusicLibraryAuthorization { isAuthorized in
            guard self.musicStartupPreloadRequestID == requestID else { return }
            guard isAuthorized else {
                self.finishStartupMusicLibraryPreload()
                return
            }
            Task(priority: .utility) {
                do {
                    let snapshot = try await loadStartupMusicLibrarySnapshot()
                    await MainActor.run {
                        guard musicStartupPreloadRequestID == requestID else { return }
                        musicAllSongsCache = snapshot.sortedSongs
                        musicShuffleSongsCache = snapshot.shuffleSongs
                        #if canImport(iTunesLibrary)
                            musicLibraryItemIndexBySongID = snapshot.itemIndices
                            musicLibraryArtworkDataByAlbumKey = snapshot.artworkDataByAlbumKey
                        #endif
                        finishStartupMusicLibraryPreload()
                    }
                } catch {
                    await MainActor.run {
                        guard musicStartupPreloadRequestID == requestID else { return }
                        finishStartupMusicLibraryPreload()
                    }
                }
            }
        }
    }

    func resetMusicCategoryStateForNonMusicITunesTop() {
        _ = incrementRequestID(&musicSongsRequestID)
        activeMusicCategoryKind = nil
        activeMusicCategoryMenuTitle = ""
        lastSelectedMusicCategoryIndex = 0
        isMusicSongsCategoryScoped = false
        musicCategoryThirdMenuItems = []
        musicSongsThirdMenuItems = []
        isLoadingMusicSongs = false
        musicSongsLoadError = nil
    }

    func resetMusicCategoryAndSongStateForMusicITunesTop() {
        isMusicSongsShuffleMode = false
        isMusicSongsCategoryScoped = false
        activeMusicCategoryKind = nil
        activeMusicCategoryMenuTitle = ""
        lastSelectedMusicCategoryIndex = 0
        musicCategoryThirdMenuItems = []
        musicSongsThirdMenuItems = []
        isLoadingMusicSongs = false
        musicSongsLoadError = nil
        _ = incrementRequestID(&musicSongsRequestID)
        musicPreviewTargetSongID = nil
        musicPreviewImage = nil
        _ = incrementRequestID(&musicPreviewRequestID)
    }

    func resetMusicPreviewState() {
        musicPreviewTargetSongID = nil
        musicPreviewImage = nil
        _ = incrementRequestID(&musicPreviewRequestID)
    }

    func prepareMusicLibraryThirdMenu(
        mode: ThirdMenuMode,
        title: String,
        categoryKind: MusicCategoryKind?,
        categoryTitle: String,
        shuffleMode: Bool,
        libraryMediaType: MusicLibraryMediaType,
        showsShuffleAction: Bool,
    ) {
        thirdMenuMode = mode
        isInThirdMenu = true
        selectedThirdIndex = 0
        isMusicSongsShuffleMode = shuffleMode
        isMusicSongsCategoryScoped = false
        activeMusicCategoryKind = categoryKind
        activeMusicCategoryMenuTitle = categoryTitle
        lastSelectedMusicCategoryIndex = 0
        activeMusicLibraryMediaType = libraryMediaType
        musicSongsShowsShuffleAction = showsShuffleAction
        headerText = title
        resetThirdMenuDirectoryState()
        musicCategoryThirdMenuItems = []
        musicSongsThirdMenuItems = []
        isLoadingMusicSongs = true
        musicSongsLoadError = nil
        resetMusicPreviewState()
        resetMusicITunesTopMenusForLibraryContext()
        submenuOpacity = 0
        thirdMenuOpacity = 1
    }

    func resetMusicThirdMenuStateForSecondLevelExit() {
        isMusicSongsShuffleMode = false
        isMusicSongsCategoryScoped = false
        activeMusicCategoryKind = nil
        activeMusicCategoryMenuTitle = ""
        lastSelectedMusicCategoryIndex = 0
        activeMusicLibraryMediaType = .songs
        musicSongsShowsShuffleAction = false
        musicCategoryThirdMenuItems = []
        isLoadingMusicSongs = false
        musicSongsLoadError = nil
        _ = incrementRequestID(&musicSongsRequestID)
    }

    func resolveMusicPreviewTargetSong() -> MusicLibrarySongEntry? {
        guard activeRootItemID == "music", isInSubmenu else { return nil }
        guard isInThirdMenu, thirdMenuMode == .musicSongs else { return nil }
        guard !musicSongsThirdMenuItems.isEmpty else { return nil }
        if shouldShowMusicSongsShuffleActionItem(), selectedThirdIndex == 0 {
            return musicSongsThirdMenuItems[0]
        }
        guard let songIndex = musicSongIndex(forThirdMenuSelectionIndex: selectedThirdIndex) else {
            return nil
        }
        return musicSongsThirdMenuItems[songIndex]
    }

    func generateMusicArtworkThumbnail(for url: URL) async -> NSImage? {
        let standardizedURL = url.standardizedFileURL
        let cacheKey = musicArtworkCacheKey(for: standardizedURL)
        if let cached = cachedDecodedDisplayArtworkImage(
            sourceKey: cacheKey,
            maxPixelSize: 900,
        ) {
            return cached
        }
        let asset = AVURLAsset(url: standardizedURL)
        let metadata: [AVMetadataItem]
        if #available(macOS 12.0, *) {
            guard let loaded = try? await asset.load(.commonMetadata) else { return nil }
            metadata = loaded
        } else {
            metadata = asset.commonMetadata
        }
        let artworkItems = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .commonIdentifierArtwork,
        )
        for item in artworkItems {
            let dataValue: Data? = if #available(macOS 12.0, *) {
                try? await item.load(.dataValue)
            } else {
                item.dataValue
            }
            if let data = dataValue {
                return cachedDecodedDisplayArtworkImage(
                    from: data,
                    sourceKey: cacheKey,
                    maxPixelSize: 900,
                )
            }
            let rawValue: (NSCopying & NSObjectProtocol)? = if #available(macOS 12.0, *) {
                try? await item.load(.value)
            } else {
                item.value
            }
            if let data = rawValue as? Data {
                return cachedDecodedDisplayArtworkImage(
                    from: data,
                    sourceKey: cacheKey,
                    maxPixelSize: 900,
                )
            }
            if let data = rawValue as? NSData {
                return cachedDecodedDisplayArtworkImage(
                    from: data as Data,
                    sourceKey: cacheKey,
                    maxPixelSize: 900,
                )
            }
        }
        return nil
    }

    func musicArtworkCacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    func musicArtworkCacheKey(for song: MusicLibrarySongEntry) -> String? {
        if let songURL = song.url {
            return musicArtworkCacheKey(for: songURL)
        }
        if let artworkAlbumKey = song.artworkAlbumKey {
            return artworkAlbumKey
        }
        return "song::\(song.id)"
    }

    func cachedMusicLibraryArtworkData(for song: MusicLibrarySongEntry) -> Data? {
        #if canImport(iTunesLibrary)
            guard let artworkAlbumKey = song.artworkAlbumKey else { return nil }
            return musicLibraryArtworkDataByAlbumKey[artworkAlbumKey]
        #else
            return nil
        #endif
    }

    func resolveMusicArtworkImage(
        for song: MusicLibrarySongEntry,
        cacheKey: String,
    ) async -> NSImage? {
        #if canImport(iTunesLibrary)
            if let libraryArtworkData = await MainActor.run(body: {
                self.loadMusicLibraryArtworkData(for: song)
            }) {
                return cachedDecodedDisplayArtworkImage(
                    from: libraryArtworkData,
                    sourceKey: cacheKey,
                    maxPixelSize: 900,
                )
            }
            if let artworkURL = song.url?.standardizedFileURL {
                return await generateMusicArtworkThumbnail(for: artworkURL)
            }
            return nil
        #else
            if let artworkURL = song.url?.standardizedFileURL,
               let generatedArtwork = await generateMusicArtworkThumbnail(for: artworkURL)
            {
                return generatedArtwork
            }
            if let libraryArtworkData = await MainActor.run(body: {
                self.loadMusicLibraryArtworkData(for: song)
            }) {
                return cachedDecodedDisplayArtworkImage(
                    from: libraryArtworkData,
                    sourceKey: cacheKey,
                    maxPixelSize: 900,
                )
            }
            return nil
        #endif
    }

    func currentMusicPreviewSongIndex() -> Int? {
        guard !musicSongsThirdMenuItems.isEmpty else { return nil }
        if shouldShowMusicSongsShuffleActionItem(), selectedThirdIndex == 0 {
            return 0
        }
        return musicSongIndex(forThirdMenuSelectionIndex: selectedThirdIndex)
    }

    func prefetchMusicPreviewArtworkAroundCurrentSelection(
        lookbehindCount: Int = 1,
        lookaheadCount: Int = 3,
    ) {
        guard activeRootItemID == "music", isInSubmenu else { return }
        guard isInThirdMenu, thirdMenuMode == .musicSongs else { return }
        guard let currentIndex = currentMusicPreviewSongIndex() else { return }
        guard musicSongsThirdMenuItems.indices.contains(currentIndex) else { return }
        let lowerBound = max(0, currentIndex - max(0, lookbehindCount))
        let upperBound = min(
            musicSongsThirdMenuItems.count - 1,
            currentIndex + max(0, lookaheadCount),
        )
        var queuedSongIDs: Set<String> = []
        for index in lowerBound ... upperBound {
            let song = musicSongsThirdMenuItems[index]
            guard queuedSongIDs.insert(song.id).inserted else { continue }
            prefetchMusicArtworkIfNeeded(for: song)
        }
    }

    func buildSeededShuffleQueue(
        from songs: [MusicLibrarySongEntry],
        currentSong: MusicLibrarySongEntry,
    ) -> [MusicLibrarySongEntry] {
        var remainingSongs = songs.filter { $0.id != currentSong.id }
        remainingSongs.shuffle()
        return [currentSong] + remainingSongs
    }

    func requestShuffledMusicSongs(
        from songs: [MusicLibrarySongEntry],
        requestID: Int,
        completion: @escaping ([MusicLibrarySongEntry]) -> Void,
    ) {
        Task(priority: .userInitiated) {
            let shuffledSongs = songs.shuffled()
            await MainActor.run {
                guard musicShuffleRequestID == requestID else { return }
                completion(shuffledSongs)
            }
        }
    }

    func requestSeededShuffleQueue(
        from songs: [MusicLibrarySongEntry],
        currentSong: MusicLibrarySongEntry,
        requestID: Int,
        completion: @escaping ([MusicLibrarySongEntry]) -> Void,
    ) {
        Task(priority: .userInitiated) {
            let seededQueue = buildSeededShuffleQueue(
                from: songs,
                currentSong: currentSong,
            )
            await MainActor.run {
                guard musicShuffleRequestID == requestID else { return }
                completion(seededQueue)
            }
        }
    }

    func refreshMusicPreviewForCurrentContext() {
        let selectedSong = resolveMusicPreviewTargetSong()
        let resolvedSongID = selectedSong?.id
        if musicPreviewTargetSongID == resolvedSongID {
            return
        }
        musicPreviewTargetSongID = resolvedSongID
        let requestID = incrementRequestID(&musicPreviewRequestID)
        guard let selectedSong else {
            withAnimation(.easeInOut(duration: 0.18)) {
                musicPreviewImage = nil
            }
            return
        }
        prefetchMusicPreviewArtworkAroundCurrentSelection()
        if let embeddedArtwork = selectedSong.artwork {
            withAnimation(.easeInOut(duration: 0.18)) {
                musicPreviewImage = embeddedArtwork
            }
            return
        }
        guard let cacheKey = musicArtworkCacheKey(for: selectedSong) else {
            withAnimation(.easeInOut(duration: 0.18)) {
                musicPreviewImage = nil
            }
            return
        }
        if let cached = musicPreviewCache[cacheKey] {
            withAnimation(.easeInOut(duration: 0.18)) {
                musicPreviewImage = cached
            }
            return
        }
        let targetSongID = selectedSong.id
        Task.detached(priority: .userInitiated) {
            let resolvedArtwork = await self.resolveMusicArtworkImage(
                for: selectedSong,
                cacheKey: cacheKey,
            )
            await MainActor.run {
                guard self.musicPreviewRequestID == requestID else { return }
                guard self.musicPreviewTargetSongID == targetSongID else { return }
                if let resolvedArtwork {
                    self.musicPreviewCache[cacheKey] = resolvedArtwork
                    withAnimation(.easeInOut(duration: 0.22)) {
                        self.musicPreviewImage = resolvedArtwork
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        self.musicPreviewImage = nil
                    }
                }
            }
        }
    }

    var musicSongsShuffleActionItemID: String {
        "music_songs_shuffle_action"
    }

    func shouldShowMusicSongsShuffleActionItem() -> Bool {
        thirdMenuMode == .musicSongs &&
            musicSongsShowsShuffleAction &&
            !musicSongsThirdMenuItems.isEmpty
    }

    func musicSongIndex(forThirdMenuSelectionIndex selectionIndex: Int) -> Int? {
        let resolvedIndex: Int
        if shouldShowMusicSongsShuffleActionItem() {
            guard selectionIndex > 0 else { return nil }
            resolvedIndex = selectionIndex - 1
        } else {
            resolvedIndex = selectionIndex
        }
        guard musicSongsThirdMenuItems.indices.contains(resolvedIndex) else { return nil }
        return resolvedIndex
    }

    func thirdMenuSelectionIndex(forMusicSongIndex songIndex: Int) -> Int {
        if shouldShowMusicSongsShuffleActionItem() {
            return songIndex + 1
        }
        return songIndex
    }

    func refreshMusicTopLevelCarouselForCurrentContext() {
        guard let selectedSubmenuID = selectedTopLevelMusicCarouselSubmenuID else {
            musicTopLevelCarouselActiveSubmenuID = nil
            isLoadingMusicTopLevelCarousel = false
            musicTopLevelCarouselLoadOverlayOpacity = 0
            musicTopLevelCarouselPageStartsInFlight.removeAll()
            _ = incrementRequestID(&musicTopLevelCarouselRequestID)
            return
        }
        musicTopLevelCarouselActiveSubmenuID = selectedSubmenuID
        guard musicTopLevelCarouselLoadedArtworkCount == 0 else {
            isLoadingMusicTopLevelCarousel = false
            musicTopLevelCarouselLoadOverlayOpacity = 0
            return
        }
        guard !isLoadingMusicTopLevelCarousel else { return }
        let requestID = incrementRequestID(&musicTopLevelCarouselRequestID)
        requestMusicTopLevelCarouselPageIfNeeded(
            startIndex: 0,
            requestID: requestID,
            showsOverlay: true,
        )
    }

    func requestMusicTopLevelCarouselPageIfNeeded(
        startIndex: Int,
        requestID: Int = -1,
        showsOverlay: Bool = false,
    ) {
        let resolvedStartIndex = max(0, startIndex)
        guard selectedTopLevelMusicCarouselSubmenuID != nil else { return }
        if let resolvedArtworkCount = musicTopLevelCarouselResolvedArtworkCount,
           resolvedStartIndex >= resolvedArtworkCount
        {
            return
        }
        guard !musicTopLevelCarouselPageStartsInFlight.contains(resolvedStartIndex) else { return }
        let activeRequestID = requestID >= 0 ? requestID : musicTopLevelCarouselRequestID
        musicTopLevelCarouselPageStartsInFlight.insert(resolvedStartIndex)
        isLoadingMusicTopLevelCarousel = true
        var instant = Transaction()
        instant.disablesAnimations = true
        if showsOverlay {
            withTransaction(instant) {
                musicTopLevelCarouselLoadOverlayOpacity = 1
            }
        }
        requestMusicLibraryAuthorization { isAuthorized in
            guard self.musicTopLevelCarouselRequestID == activeRequestID else { return }
            guard isAuthorized else {
                self.musicTopLevelCarouselPageStartsInFlight.remove(resolvedStartIndex)
                self.isLoadingMusicTopLevelCarousel = !self.musicTopLevelCarouselPageStartsInFlight.isEmpty
                if showsOverlay {
                    self.musicTopLevelCarouselLoadOverlayOpacity = 0
                }
                return
            }
            Task(priority: .userInitiated) {
                do {
                    let pageArtworks = try fetchMusicTopLevelCarouselArtworks(
                        startIndex: resolvedStartIndex,
                        limit: musicTopLevelCarouselArtworkLimit,
                    )
                    await MainActor.run {
                        guard musicTopLevelCarouselRequestID == activeRequestID else { return }
                        musicTopLevelCarouselPageStartsInFlight.remove(resolvedStartIndex)
                        guard let activeSelectedSubmenuID = selectedTopLevelMusicCarouselSubmenuID else {
                            musicTopLevelCarouselActiveSubmenuID = nil
                            isLoadingMusicTopLevelCarousel = !musicTopLevelCarouselPageStartsInFlight.isEmpty
                            musicTopLevelCarouselLoadOverlayOpacity = 0
                            return
                        }
                        musicTopLevelCarouselActiveSubmenuID = activeSelectedSubmenuID
                        withTransaction(instant) {
                            for (pageOffset, artwork) in pageArtworks.enumerated() {
                                musicTopLevelCarouselArtworksByIndex[resolvedStartIndex + pageOffset] = artwork
                            }
                        }
                        musicTopLevelCarouselLoadedArtworkCount = max(
                            musicTopLevelCarouselLoadedArtworkCount,
                            resolvedStartIndex + pageArtworks.count,
                        )
                        if pageArtworks.count < musicTopLevelCarouselArtworkLimit {
                            musicTopLevelCarouselResolvedArtworkCount = resolvedStartIndex + pageArtworks.count
                        }
                        isLoadingMusicTopLevelCarousel = !musicTopLevelCarouselPageStartsInFlight.isEmpty
                        if showsOverlay {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                musicTopLevelCarouselLoadOverlayOpacity = 0
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard musicTopLevelCarouselRequestID == activeRequestID else { return }
                        musicTopLevelCarouselPageStartsInFlight.remove(resolvedStartIndex)
                        isLoadingMusicTopLevelCarousel = !musicTopLevelCarouselPageStartsInFlight.isEmpty
                        if showsOverlay {
                            musicTopLevelCarouselLoadOverlayOpacity = 0
                        }
                    }
                }
            }
        }
    }

    var musicTopLevelCarouselArtworkLimit: Int {
        18
    }

    var musicTopLevelCarouselPrefetchLead: Int {
        8
    }

    func prefetchMusicTopLevelCarouselIfNeeded(forSerial serial: Int) {
        guard selectedTopLevelMusicCarouselSubmenuID != nil else { return }
        guard musicTopLevelCarouselLoadedArtworkCount > 0 else { return }
        guard musicTopLevelCarouselResolvedArtworkCount == nil else { return }
        let prefetchTriggerSerial = max(0, musicTopLevelCarouselLoadedArtworkCount - musicTopLevelCarouselPrefetchLead)
        guard serial >= prefetchTriggerSerial else { return }
        requestMusicTopLevelCarouselPageIfNeeded(startIndex: musicTopLevelCarouselLoadedArtworkCount)
    }

    func musicTopLevelCarouselArtwork(forGlobalIndex globalIndex: Int) -> NSImage? {
        musicTopLevelCarouselArtworksByIndex[globalIndex] ?? musicFallbackImage
    }

    func fetchMusicTopLevelCarouselArtworks(startIndex: Int, limit: Int) throws -> [NSImage?] {
        let resolvedStartIndex = max(0, startIndex)
        let resolvedLimit = max(1, limit)
        #if canImport(iTunesLibrary)
            return try withITLibrary { library in
                var seenAlbumKeys: Set<String> = []
                var matchedIndex = 0
                var artworks: [NSImage?] = []
                artworks.reserveCapacity(resolvedLimit)
                for item in library.allMediaItems {
                    guard musicLibraryMediaKindMatches(item.mediaKind, requested: .songs) else { continue }
                    guard isMusicLibraryItemAuthorizedForPlayback(item) else { continue }
                    let albumKey = musicTopLevelCarouselAlbumKey(for: item)
                    guard seenAlbumKeys.insert(albumKey).inserted else { continue }
                    guard matchedIndex >= resolvedStartIndex else {
                        matchedIndex += 1
                        continue
                    }
                    artworks.append(resolvedMusicLibraryEmbeddedArtworkImage(for: item) ?? musicFallbackImage)
                    if artworks.count >= resolvedLimit {
                        break
                    }
                    matchedIndex += 1
                }
                return artworks
            }
        #else
            return []
        #endif
    }

    func normalizedMusicTopLevelCarouselAlbumKey(
        albumTitle: String?,
        albumArtist: String?,
        persistentAlbumID: String?,
        fallbackItemID: String,
    ) -> String {
        let trimmedPersistentAlbumID = persistentAlbumID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedPersistentAlbumID.isEmpty, trimmedPersistentAlbumID != "0" {
            return "album::\(trimmedPersistentAlbumID)"
        }
        let trimmedAlbumTitle = albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedAlbumTitle.isEmpty {
            let trimmedAlbumArtist = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedAlbumArtist.isEmpty {
                return "album::\(trimmedAlbumArtist.lowercased())::\(trimmedAlbumTitle.lowercased())"
            }
            return "album::\(trimmedAlbumTitle.lowercased())"
        }
        return "track::\(fallbackItemID)"
    }

    #if canImport(iTunesLibrary)
        func musicTopLevelCarouselAlbumKey(for item: ITLibMediaItem) -> String {
            normalizedMusicTopLevelCarouselAlbumKey(
                albumTitle: item.album.title,
                albumArtist: item.album.albumArtist,
                persistentAlbumID: item.album.persistentID.stringValue,
                fallbackItemID: "\(item.persistentID)",
            )
        }

        func musicTopLevelCarouselAlbumKeyAliases(for item: ITLibMediaItem) -> [String] {
            var aliases: [String] = []
            let trimmedPersistentAlbumID = item.album.persistentID.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPersistentAlbumID.isEmpty, trimmedPersistentAlbumID != "0" {
                aliases.append("album::\(trimmedPersistentAlbumID)")
            }
            let trimmedAlbumTitle = (item.album.title ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAlbumTitle.isEmpty {
                let trimmedAlbumArtist = (item.album.albumArtist ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedAlbumArtist.isEmpty {
                    aliases.append(
                        "album::\(trimmedAlbumArtist.lowercased())::\(trimmedAlbumTitle.lowercased())",
                    )
                }
                aliases.append("album::\(trimmedAlbumTitle.lowercased())")
            }
            aliases.append("track::\(item.persistentID)")
            var seen: Set<String> = []
            return aliases.filter { seen.insert($0).inserted }
        }
    #endif

    func musicCategoryKind(forSubmenuItemID submenuItemID: String) -> MusicCategoryKind? {
        switch submenuItemID {
        case "music_albums":
            .albums
        case "music_artists":
            .artists
        case "music_genres":
            .genres
        case "music_composers":
            .composers
        case "music_playlists":
            .playlists
        default:
            nil
        }
    }

    func musicCategoryValue(for song: MusicLibrarySongEntry, kind: MusicCategoryKind) -> String {
        switch kind {
        case .albums:
            song.album
        case .artists:
            song.artist
        case .genres:
            song.genre
        case .composers:
            song.composer
        case .playlists:
            ""
        }
    }

    func buildMusicCategoryEntries(
        from songs: [MusicLibrarySongEntry],
        kind: MusicCategoryKind,
    ) -> [MusicCategoryEntry] {
        var groupedSongs: [String: [MusicLibrarySongEntry]] = [:]
        for song in songs {
            let categoryTitle = musicCategoryValue(for: song, kind: kind)
            groupedSongs[categoryTitle, default: []].append(song)
        }
        var categoryEntries: [MusicCategoryEntry] = []
        categoryEntries.reserveCapacity(groupedSongs.count)
        for (categoryTitle, groupedCategorySongs) in groupedSongs {
            let sortedCategorySongs: [MusicLibrarySongEntry]
            if kind == .albums {
                sortedCategorySongs = groupedCategorySongs.sorted {
                    if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                    if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            } else {
                sortedCategorySongs = groupedCategorySongs.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            }
            categoryEntries.append(
                MusicCategoryEntry(
                    id: "\(kind.rawValue)::\(categoryTitle.lowercased())",
                    title: categoryTitle,
                    songs: sortedCategorySongs,
                ),
            )
        }
        categoryEntries.sort {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        guard kind == .artists, !songs.isEmpty else {
            return categoryEntries
        }
        let allSongs = songs.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let allArtistsEntry = MusicCategoryEntry(
            id: "\(kind.rawValue)::all",
            title: "All",
            songs: allSongs,
        )
        return [allArtistsEntry] + categoryEntries
    }

    func exitMusicThirdMenuToSecondLevelWithSwap(useOverlayFade: Bool = false) {
        transitionMenuForFolderSwap(useOverlayFade: useOverlayFade, direction: .backward) {
            isInThirdMenu = false
            thirdMenuMode = .none
            thirdMenuOpacity = 0
            submenuOpacity = 1
            resetMusicThirdMenuStateForSecondLevelExit()
            resetITunesTopCarouselAndPreviewState(
                for: [.songs, .musicVideos],
                resetPlaybackRequestID: true,
            )
            headerText = rootMenuTitle(for: activeRootItemID)
            refreshDetailPreviewForCurrentContext()
        }
    }

    func enterMusicSongsMenu(
        title: String,
        shuffleMode: Bool = false,
        libraryMediaType: MusicLibraryMediaType = .songs,
        showsShuffleAction: Bool = true,
    ) {
        transitionMenuForFolderSwap(
            revealWhen: { !isLoadingMusicSongs },
        ) {
            prepareMusicLibraryThirdMenu(
                mode: .musicSongs,
                title: title,
                categoryKind: nil,
                categoryTitle: "",
                shuffleMode: shuffleMode,
                libraryMediaType: libraryMediaType,
                showsShuffleAction: showsShuffleAction,
            )
            requestMusicLibraryAuthorizationAndLoadSongs()
        }
    }

    func revealDeferredNowPlayingMenuItemIfNeeded(compensateSelection: Bool) {
        guard deferNowPlayingMenuItemUntilAfterFadeOut else { return }
        deferNowPlayingMenuItemUntilAfterFadeOut = false
        guard compensateSelection else { return }
        guard activeRootItemID == "music", isInSubmenu, !isInThirdMenu else { return }
        guard isMusicActivelyPlaying else { return }
        let submenuItemsWithoutNowPlaying = MenuConfiguration.submenuItems(forRootID: "music")
        guard !submenuItemsWithoutNowPlaying.isEmpty else { return }
        selectedSubIndex = min(
            selectedSubIndex + 1,
            max(0, currentSubmenuItems().count - 1),
        )
    }

    func enterMusicCategoryMenu(title: String, kind: MusicCategoryKind) {
        transitionMenuForFolderSwap(
            revealWhen: { !isLoadingMusicSongs },
        ) {
            prepareMusicLibraryThirdMenu(
                mode: .musicCategories,
                title: title,
                categoryKind: kind,
                categoryTitle: title,
                shuffleMode: false,
                libraryMediaType: .songs,
                showsShuffleAction: false,
            )
            requestMusicLibraryAuthorizationAndLoadCategories(for: kind)
        }
    }

    func enterSongsForSelectedMusicCategory() {
        guard thirdMenuMode == .musicCategories else { return }
        guard musicCategoryThirdMenuItems.indices.contains(selectedThirdIndex) else { return }
        let categoryEntry = musicCategoryThirdMenuItems[selectedThirdIndex]
        let categoryIndex = selectedThirdIndex
        transitionMenuForFolderSwap {
            thirdMenuMode = .musicSongs
            isMusicSongsCategoryScoped = true
            isMusicSongsShuffleMode = false
            lastSelectedMusicCategoryIndex = categoryIndex
            musicSongsThirdMenuItems = categoryEntry.songs
            selectedThirdIndex = 0
            activeMusicLibraryMediaType = .songs
            let shouldShowShuffleAction = switch activeMusicCategoryKind {
            case .playlists, .artists, .albums, .genres, .composers:
                true
            case nil:
                false
            }
            musicSongsShowsShuffleAction = shouldShowShuffleAction
            isLoadingMusicSongs = false
            musicSongsLoadError = categoryEntry.songs.isEmpty ? "No Songs in Category" : nil
            headerText = activeMusicCategoryMenuTitle.isEmpty
                ? rootMenuTitle(for: activeRootItemID)
                : activeMusicCategoryMenuTitle
            refreshDetailPreviewForCurrentContext()
            submenuOpacity = 0
            thirdMenuOpacity = 1
        }
    }

    func fetchMusicLibrarySongs() throws -> [MusicLibrarySongEntry] {
        try fetchMusicLibraryEntries(for: .songs, includeArtwork: false)
    }

    func fetchRandomMusicLibrarySongForShuffleSeed(includeArtwork: Bool = true) throws -> MusicLibrarySongEntry? {
        #if canImport(iTunesLibrary)
            return try withITLibrary { library in
                let all = library.allMediaItems
                guard !all.isEmpty else { return nil }
                let startIndex = Int.random(in: 0 ..< all.count)
                for offset in 0 ..< all.count {
                    let resolvedIndex = (startIndex + offset) % all.count
                    let item = all[resolvedIndex]
                    guard musicLibraryMediaKindMatches(item.mediaKind, requested: .songs) else { continue }
                    if let song = makeMusicLibrarySongEntry(from: item, includeArtwork: includeArtwork) {
                        return song
                    }
                }
                return nil
            }
        #else
            let songs = try fetchMusicLibrarySongsForShuffle()
            return songs.randomElement()
        #endif
    }

    func fetchMusicLibrarySongsForShuffle() throws -> [MusicLibrarySongEntry] {
        try fetchMusicLibraryEntries(
            for: .songs,
            includeArtwork: false,
            shouldSort: false,
        )
    }

    #if canImport(iTunesLibrary)
        nonisolated var supportedExternalMusicFileExtensions: Set<String> {
            ["mp3", "m4a", "aiff", "aif", "wav", "flac", "caf", "m4b"]
        }

        nonisolated func externalMusicRootURLs() -> [URL] {
            externalVolumeRootURLs().compactMap { volumeURL in
                let musicURL = volumeURL.appendingPathComponent("Music", isDirectory: true)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: musicURL.path, isDirectory: &isDir),
                      isDir.boolValue else { return nil }
                return musicURL
            }
        }

        nonisolated func scanExternalMusicFiles(in directoryURL: URL) -> [URL] {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            var results: [URL] = []
            for url in contents {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true {
                    results.append(contentsOf: scanExternalMusicFiles(in: url))
                } else if values?.isRegularFile == true,
                          supportedExternalMusicFileExtensions.contains(url.pathExtension.lowercased()) {
                    results.append(url)
                }
            }
            return results
        }

        nonisolated func makeMusicLibrarySongEntryFromAudioFile(_ url: URL) async -> MusicLibrarySongEntry? {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            let commonMetadata: [AVMetadataItem]
            let metadata: [AVMetadataItem]
            let duration: CMTime
            if #available(macOS 12.0, *) {
                commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
                metadata = (try? await asset.load(.metadata)) ?? []
                duration = (try? await asset.load(.duration)) ?? .zero
            } else {
                (commonMetadata, metadata, duration) = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(returning: (asset.commonMetadata, asset.metadata, asset.duration))
                    }
                }
            }
            func firstCommonString(_ key: AVMetadataKey) -> String? {
                AVMetadataItem.metadataItems(from: commonMetadata, withKey: key, keySpace: .common)
                    .first?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
            }
            let title = firstCommonString(.commonKeyTitle)
            let artist = firstCommonString(.commonKeyArtist)
            let albumName = firstCommonString(.commonKeyAlbumName)
            let artworkData = AVMetadataItem.metadataItems(
                from: commonMetadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common
            ).first?.dataValue
            var genre = "Unknown Genre"
            var composer = "Unknown Composer"
            var trackNumber = 0
            var discNumber = 1
            for item in metadata {
                switch item.identifier {
                case .id3MetadataContentType:
                    genre = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? genre
                case .id3MetadataComposer:
                    composer = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? composer
                case .id3MetadataTrackNumber:
                    if let s = item.stringValue?.components(separatedBy: "/").first, let n = Int(s) {
                        trackNumber = n
                    }
                case .id3MetadataPartOfASet:
                    if let s = item.stringValue?.components(separatedBy: "/").first, let n = Int(s) {
                        discNumber = n
                    }
                default:
                    break
                }
            }
            let resolvedTitle = title ?? url.deletingPathExtension().lastPathComponent
            let resolvedArtist = artist ?? "Unknown Artist"
            let resolvedAlbum = albumName ?? "Unknown Album"
            let durationSeconds = max(0, CMTimeGetSeconds(duration))
            let artwork = artworkData.flatMap { NSImage(data: $0) }
            return MusicLibrarySongEntry(
                id: "ext::\(url.standardizedFileURL.path)",
                title: resolvedTitle,
                artist: resolvedArtist,
                album: resolvedAlbum,
                genre: genre,
                composer: composer,
                durationSeconds: durationSeconds,
                trackNumber: trackNumber,
                discNumber: discNumber,
                artworkAlbumKey: artwork != nil ? "\(resolvedArtist):::\(resolvedAlbum)" : nil,
                url: url,
                artwork: artwork,
            )
        }

        nonisolated func fetchExternalMusicSongEntries() async -> [MusicLibrarySongEntry] {
            var results: [MusicLibrarySongEntry] = []
            for root in externalMusicRootURLs() {
                for url in scanExternalMusicFiles(in: root) {
                    if let entry = await makeMusicLibrarySongEntryFromAudioFile(url) {
                        results.append(entry)
                    }
                }
            }
            return results
        }

        func fetchMusicLibrarySongsWithItemIndices(
            includeArtwork: Bool = false,
            shouldSort: Bool = true,
        ) async throws -> (
            songs: [MusicLibrarySongEntry],
            itemIndices: [String: Int],
            artworkDataByAlbumKey: [String: Data],
        ) {
            var (songs, itemIndices, artworkDataByAlbumKey) = try withITLibrary { library in
                var songs: [MusicLibrarySongEntry] = []
                var itemIndices: [String: Int] = [:]
                var artworkDataByAlbumKey: [String: Data] = [:]
                for (index, item) in library.allMediaItems.enumerated() {
                    guard musicLibraryMediaKindMatches(item.mediaKind, requested: .songs) else { continue }
                    guard let entry = makeMusicLibrarySongEntry(from: item, includeArtwork: includeArtwork) else { continue }
                    songs.append(entry)
                    itemIndices[entry.id] = index
                    if let artworkData = item.artwork?.imageData as Data? {
                        for artworkAlbumKey in musicTopLevelCarouselAlbumKeyAliases(for: item)
                            where artworkDataByAlbumKey[artworkAlbumKey] == nil
                        {
                            artworkDataByAlbumKey[artworkAlbumKey] = artworkData
                        }
                    }
                }
                return (songs: songs, itemIndices: itemIndices, artworkDataByAlbumKey: artworkDataByAlbumKey)
            }
            songs.append(contentsOf: await fetchExternalMusicSongEntries())
            return (
                songs: shouldSort ? sortedMusicLibraryEntries(songs) : songs,
                itemIndices: itemIndices,
                artworkDataByAlbumKey: artworkDataByAlbumKey,
            )
        }

        func fetchMusicLibrarySongsForShuffleWithItemIndices() async throws -> (
            songs: [MusicLibrarySongEntry],
            itemIndices: [String: Int],
            artworkDataByAlbumKey: [String: Data],
        ) {
            try await fetchMusicLibrarySongsWithItemIndices(
                includeArtwork: false,
                shouldSort: false,
            )
        }
    #endif

    func fetchMusicLibraryEntries(
        for mediaType: MusicLibraryMediaType,
        includeArtwork: Bool = true,
        shouldSort: Bool = true,
    ) throws -> [MusicLibrarySongEntry] {
        #if canImport(iTunesLibrary)
            return try withITLibrary { library in
                var entries: [MusicLibrarySongEntry] = []
                for item in library.allMediaItems {
                    guard musicLibraryMediaKindMatches(item.mediaKind, requested: mediaType) else { continue }
                    guard let entry = makeMusicLibrarySongEntry(from: item, includeArtwork: includeArtwork) else { continue }
                    entries.append(entry)
                }
                return shouldSort ? sortedMusicLibraryEntries(entries) : entries
            }
        #else
            return []
        #endif
    }

    func fetchMusicLibraryPlaylists() throws -> [MusicCategoryEntry] {
        #if canImport(iTunesLibrary)
            return try withITLibrary { library in
                library.allPlaylists.compactMap { playlist -> MusicCategoryEntry? in
                    guard playlist.isVisible else { return nil }
                    guard playlist.kind != .folder else { return nil }
                    guard !playlist.isMaster else { return nil }
                    if #available(macOS 12.0, *) {
                        guard !playlist.isPrimary else { return nil }
                    }
                    let title = normalizedMusicLibraryText(playlist.name, fallback: "Untitled Playlist")
                    let songs = sortedMusicLibraryEntries(
                        playlist.items.compactMap { item -> MusicLibrarySongEntry? in
                            guard musicLibraryMediaKindMatches(item.mediaKind, requested: .songs) else { return nil }
                            return makeMusicLibrarySongEntry(from: item)
                        },
                    )
                    guard !songs.isEmpty else { return nil }
                    return MusicCategoryEntry(
                        id: "playlist::mac::\(playlist.persistentID)",
                        title: title,
                        songs: songs,
                    )
                }.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            }
        #else
            return []
        #endif
    }

    func normalizedMusicLibraryText(_ rawValue: String?, fallback: String) -> String {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    func sortedMusicLibraryEntries(_ entries: [MusicLibrarySongEntry]) -> [MusicLibrarySongEntry] {
        entries.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    #if canImport(iTunesLibrary)
        func musicPersistentIDHexString(for persistentID: NSNumber) -> String {
            String(format: "%016llX", persistentID.uint64Value)
        }

        func isAppleMusicCatalogLibraryItem(_ item: ITLibMediaItem) -> Bool {
            guard item.isCloud, !item.isPurchased else { return false }
            let normalizedKind = item.kind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return normalizedKind.localizedCaseInsensitiveContains("Apple Music")
        }

        func isMusicLibraryItemAuthorizedForPlayback(_ item: ITLibMediaItem) -> Bool {
            guard !item.isUserDisabled else { return false }
            #if os(macOS)
                if isAppleMusicCatalogLibraryItem(item) {
                    let canPlayCatalogContent = AppleMusicCatalogPlaybackCapabilityCache.shared
                        .canPlayCatalogContent(requestPermissionIfNeeded: false)
                    guard canPlayCatalogContent else { return false }
                }
                let unavailablePersistentIDHexes = UnavailableAppleMusicTrackCache.shared.persistentIDHexes()
                guard !unavailablePersistentIDHexes.isEmpty else { return true }
                return !unavailablePersistentIDHexes.contains(
                    musicPersistentIDHexString(for: item.persistentID),
                )
            #else
                return true
            #endif
        }

        func resolvedMusicLibraryPlaybackURL(for item: ITLibMediaItem) -> URL? {
            guard item.locationType == .file else { return nil }
            guard let locationURL = item.location, locationURL.isFileURL else { return nil }
            guard FileManager.default.isReadableFile(atPath: locationURL.path) else { return nil }
            return locationURL.standardizedFileURL
        }

        /// ITLibrary uses XPC to talk to amplibraryd — both init and all property
        /// access must happen on the main thread or the connection is invalidated.
        func withITLibrary<T>(_ work: (ITLibrary) throws -> T) throws -> T {
            let lib = try ITLibrary(apiVersion: "1.0")
            return try work(lib)
        }

        func musicLibraryMediaKindMatches(
            _ mediaKind: ITLibMediaItemMediaKind,
            requested: MusicLibraryMediaType,
        ) -> Bool {
            switch requested {
            case .songs:
                mediaKind == .kindSong
            case .musicVideos:
                mediaKind == .kindMusicVideo
            case .audiobooks:
                mediaKind == .kindAudiobook
            }
        }

        func resolvedMusicLibraryEmbeddedArtworkImage(for item: ITLibMediaItem) -> NSImage? {
            guard let artworkData = item.artwork?.imageData as Data? else { return nil }
            let sourceKey = "itlib::\(musicTopLevelCarouselAlbumKey(for: item))"
            return cachedDecodedDisplayArtworkImage(
                from: artworkData,
                sourceKey: sourceKey,
                maxPixelSize: 900,
            )
        }

        func makeMusicLibrarySongEntry(from item: ITLibMediaItem, includeArtwork: Bool = true) -> MusicLibrarySongEntry? {
            guard isMusicLibraryItemAuthorizedForPlayback(item) else { return nil }
            let locationURL = resolvedMusicLibraryPlaybackURL(for: item)
            let title = normalizedMusicLibraryText(
                item.title,
                fallback: locationURL?.deletingPathExtension().lastPathComponent ?? "Unknown Song",
            )
            let artist = normalizedMusicLibraryText(item.artist?.name, fallback: "Unknown Artist")
            let album = normalizedMusicLibraryText(item.album.title, fallback: "Unknown Album")
            let genre = normalizedMusicLibraryText(item.genre, fallback: "Unknown Genre")
            let composer = normalizedMusicLibraryText(item.composer, fallback: "Unknown Composer")
            return MusicLibrarySongEntry(
                id: "\(item.persistentID)",
                title: title,
                artist: artist,
                album: album,
                genre: genre,
                composer: composer,
                durationSeconds: max(0, Double(item.totalTime) / 1000.0),
                trackNumber: item.trackNumber,
                discNumber: item.album.discNumber,
                artworkAlbumKey: musicTopLevelCarouselAlbumKey(for: item),
                url: locationURL,
                artwork: includeArtwork ? resolvedMusicLibraryEmbeddedArtworkImage(for: item) : nil,
            )
        }
    #endif

    func requestMusicLibraryAuthorization(completion: @escaping @MainActor (Bool) -> Void) {
        Task { @MainActor in
            completion(true)
        }
    }

    func requestMusicLibraryAuthorizationAndLoadSongs() {
        let requestID = incrementRequestID(&musicSongsRequestID)
        let requestedMediaType = activeMusicLibraryMediaType
        isLoadingMusicSongs = true
        musicSongsLoadError = nil
        requestMusicLibraryAuthorization { isAuthorized in
            guard self.musicSongsRequestID == requestID else { return }
            guard self.thirdMenuMode == .musicSongs else { return }
            guard !self.isMusicSongsCategoryScoped else { return }
            guard self.activeMusicLibraryMediaType == requestedMediaType else { return }
            guard isAuthorized else {
                self.isLoadingMusicSongs = false
                self.musicSongsThirdMenuItems = []
                self.selectedThirdIndex = 0
                self.musicSongsLoadError = "Music library access denied"
                self.refreshMusicPreviewForCurrentContext()
                return
            }
            if requestedMediaType == .songs, let cachedSongs = self.musicAllSongsCache {
                self.isLoadingMusicSongs = false
                self.musicSongsThirdMenuItems = cachedSongs
                let additionalShuffleRow = (self.musicSongsShowsShuffleAction && !cachedSongs.isEmpty) ? 1 : 0
                let maxSelectionIndex = max(0, (cachedSongs.count + additionalShuffleRow) - 1)
                self.selectedThirdIndex = min(self.selectedThirdIndex, maxSelectionIndex)
                self.musicSongsLoadError = nil
                self.refreshMusicPreviewForCurrentContext()
                if cachedSongs.isEmpty {
                    self.presentMusicLibraryEmptyError(for: requestedMediaType)
                }
                return
            }
            Task(priority: .userInitiated) {
                do {
                    #if canImport(iTunesLibrary)
                        let songs: [MusicLibrarySongEntry]
                        let itemIndices: [String: Int]
                        let artworkDataByAlbumKey: [String: Data]
                        if requestedMediaType == .songs {
                            let result = try await fetchMusicLibrarySongsWithItemIndices(includeArtwork: false)
                            songs = result.songs
                            itemIndices = result.itemIndices
                            artworkDataByAlbumKey = result.artworkDataByAlbumKey
                        } else {
                            songs = try fetchMusicLibraryEntries(for: requestedMediaType)
                            itemIndices = [:]
                            artworkDataByAlbumKey = musicLibraryArtworkDataByAlbumKey
                        }
                    #else
                        let songs = try fetchMusicLibraryEntries(for: requestedMediaType)
                    #endif
                    await MainActor.run {
                        guard musicSongsRequestID == requestID else { return }
                        guard thirdMenuMode == .musicSongs else { return }
                        guard !isMusicSongsCategoryScoped else { return }
                        guard activeMusicLibraryMediaType == requestedMediaType else { return }
                        isLoadingMusicSongs = false
                        if requestedMediaType == .songs {
                            #if canImport(iTunesLibrary)
                                musicLibraryItemIndexBySongID = itemIndices
                                musicLibraryArtworkDataByAlbumKey = artworkDataByAlbumKey
                            #endif
                            musicAllSongsCache = songs
                        }
                        musicSongsThirdMenuItems = songs
                        let additionalShuffleRow = (musicSongsShowsShuffleAction && !songs.isEmpty) ? 1 : 0
                        let maxSelectionIndex = max(0, (songs.count + additionalShuffleRow) - 1)
                        selectedThirdIndex = min(selectedThirdIndex, maxSelectionIndex)
                        musicSongsLoadError = nil
                        refreshMusicPreviewForCurrentContext()
                        if songs.isEmpty {
                            presentMusicLibraryEmptyError(for: requestedMediaType)
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard musicSongsRequestID == requestID else { return }
                        guard thirdMenuMode == .musicSongs else { return }
                        guard !isMusicSongsCategoryScoped else { return }
                        guard activeMusicLibraryMediaType == requestedMediaType else { return }
                        isLoadingMusicSongs = false
                        musicSongsThirdMenuItems = []
                        selectedThirdIndex = 0
                        musicSongsLoadError = musicLibraryErrorMessage(for: error)
                        refreshMusicPreviewForCurrentContext()
                    }
                }
            }
        }
    }

    func requestMusicLibraryAuthorizationAndLoadCategories(for kind: MusicCategoryKind) {
        let requestID = incrementRequestID(&musicSongsRequestID)
        isLoadingMusicSongs = true
        musicSongsLoadError = nil
        requestMusicLibraryAuthorization { isAuthorized in
            guard self.musicSongsRequestID == requestID else { return }
            guard self.thirdMenuMode == .musicCategories else { return }
            guard self.activeMusicCategoryKind == kind else { return }
            guard isAuthorized else {
                self.isLoadingMusicSongs = false
                self.musicCategoryThirdMenuItems = []
                self.selectedThirdIndex = 0
                self.musicSongsLoadError = "Music library access denied"
                self.refreshMusicPreviewForCurrentContext()
                return
            }
            let cachedSongs = self.musicAllSongsCache
            Task(priority: .userInitiated) {
                do {
                    let categories: [MusicCategoryEntry]
                    if kind == .playlists {
                        categories = try fetchMusicLibraryPlaylists()
                    } else {
                        let songs: [MusicLibrarySongEntry]
                        #if canImport(iTunesLibrary)
                            let itemIndices: [String: Int]
                            let artworkDataByAlbumKey: [String: Data]
                        #endif
                        if let cachedSongs {
                            songs = cachedSongs
                            #if canImport(iTunesLibrary)
                                itemIndices = musicLibraryItemIndexBySongID
                                artworkDataByAlbumKey = musicLibraryArtworkDataByAlbumKey
                            #endif
                        } else {
                            #if canImport(iTunesLibrary)
                                let result = try await fetchMusicLibrarySongsWithItemIndices(includeArtwork: false)
                                songs = result.songs
                                itemIndices = result.itemIndices
                                artworkDataByAlbumKey = result.artworkDataByAlbumKey
                            #else
                                songs = try fetchMusicLibrarySongs()
                            #endif
                        }
                        categories = buildMusicCategoryEntries(from: songs, kind: kind)
                        await MainActor.run {
                            musicAllSongsCache = songs
                            #if canImport(iTunesLibrary)
                                musicLibraryItemIndexBySongID = itemIndices
                                musicLibraryArtworkDataByAlbumKey = artworkDataByAlbumKey
                            #endif
                        }
                    }
                    await MainActor.run {
                        guard musicSongsRequestID == requestID else { return }
                        guard thirdMenuMode == .musicCategories else { return }
                        guard activeMusicCategoryKind == kind else { return }
                        isLoadingMusicSongs = false
                        musicCategoryThirdMenuItems = categories
                        selectedThirdIndex = min(selectedThirdIndex, max(0, categories.count - 1))
                        musicSongsLoadError = nil
                        refreshMusicPreviewForCurrentContext()
                        if categories.isEmpty {
                            presentMusicCategoryEmptyError(for: kind)
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard musicSongsRequestID == requestID else { return }
                        guard thirdMenuMode == .musicCategories else { return }
                        guard activeMusicCategoryKind == kind else { return }
                        isLoadingMusicSongs = false
                        musicCategoryThirdMenuItems = []
                        selectedThirdIndex = 0
                        musicSongsLoadError = musicLibraryErrorMessage(for: error)
                        refreshMusicPreviewForCurrentContext()
                    }
                }
            }
        }
    }

    func startShufflePlaybackFromCurrentMusicSongsMenu() {
        guard thirdMenuMode == .musicSongs else { return }
        guard !musicSongsThirdMenuItems.isEmpty else {
            musicSongsLoadError = activeMusicLibraryMediaType.emptyLibraryMessage
            return
        }
        let requestID = incrementRequestID(&musicShuffleRequestID)
        let songs = musicSongsThirdMenuItems
        requestShuffledMusicSongs(from: songs, requestID: requestID) { shuffledSongs in
            guard self.thirdMenuMode == .musicSongs else { return }
            guard !shuffledSongs.isEmpty else {
                self.musicSongsLoadError = self.activeMusicLibraryMediaType.emptyLibraryMessage
                return
            }
            self.musicSongsThirdMenuItems = shuffledSongs
            self.selectedThirdIndex = self.thirdMenuSelectionIndex(forMusicSongIndex: 0)
            self.isMusicSongsShuffleMode = true
            self.startPlaybackForMusicLibraryEntry(
                shuffledSongs[0],
                trackIndex: 0,
                trackCount: shuffledSongs.count,
                playbackQueue: shuffledSongs,
            )
            self.refreshMusicPreviewForCurrentContext()
        }
    }

    func applyResolvedRootMusicShufflePlayback(
        with shuffledSongs: [MusicLibrarySongEntry],
        usingExistingBlackout: Bool = false,
    ) {
        isLoadingMusicSongs = false
        guard !shuffledSongs.isEmpty else {
            deferNowPlayingMenuItemUntilAfterFadeOut = false
            musicSongsThirdMenuItems = []
            selectedThirdIndex = 0
            musicSongsLoadError = "No Songs in Music Library"
            return
        }
        musicSongsThirdMenuItems = shuffledSongs
        selectedThirdIndex = 0
        isMusicSongsShuffleMode = true
        isMusicSongsCategoryScoped = false
        activeMusicLibraryMediaType = .songs
        musicSongsShowsShuffleAction = false
        activeMusicCategoryKind = nil
        activeMusicCategoryMenuTitle = ""
        lastSelectedMusicCategoryIndex = 0
        musicCategoryThirdMenuItems = []
        musicSongsLoadError = nil
        deferNowPlayingMenuItemUntilAfterFadeOut = false
        thirdMenuMode = .none
        isInThirdMenu = false
        thirdMenuOpacity = 0
        submenuOpacity = 1
        startMusicPlayback(
            from: shuffledSongs[0],
            trackIndex: 0,
            trackCount: shuffledSongs.count,
            usingExistingBlackout: usingExistingBlackout,
            playbackQueue: shuffledSongs,
        )
    }

    func applyRootMusicShufflePlayback(
        with songs: [MusicLibrarySongEntry],
        usingExistingBlackout: Bool = false,
    ) {
        let requestID = incrementRequestID(&musicShuffleRequestID)
        isLoadingMusicSongs = true
        requestShuffledMusicSongs(from: songs, requestID: requestID) { shuffledSongs in
            self.applyResolvedRootMusicShufflePlayback(
                with: shuffledSongs,
                usingExistingBlackout: usingExistingBlackout,
            )
        }
    }

    func loadRootMusicShufflePlaybackFromLibrary(usingExistingBlackout: Bool = false) {
        let requestID = incrementRequestID(&musicSongsRequestID)
        isLoadingMusicSongs = true
        musicSongsLoadError = nil
        requestMusicLibraryAuthorization { isAuthorized in
            guard self.musicSongsRequestID == requestID else { return }
            guard isAuthorized else {
                self.deferNowPlayingMenuItemUntilAfterFadeOut = false
                self.isLoadingMusicSongs = false
                self.musicSongsThirdMenuItems = []
                self.selectedThirdIndex = 0
                self.musicSongsLoadError = "Music library access denied"
                return
            }
            #if canImport(iTunesLibrary)
                Task(priority: .userInitiated) {
                    do {
                        guard let seedSong = try fetchRandomMusicLibrarySongForShuffleSeed() else {
                            await MainActor.run {
                                guard musicSongsRequestID == requestID else { return }
                                deferNowPlayingMenuItemUntilAfterFadeOut = false
                                isLoadingMusicSongs = false
                                musicSongsThirdMenuItems = []
                                selectedThirdIndex = 0
                                musicSongsLoadError = "No Songs in Music Library"
                            }
                            return
                        }
                        await MainActor.run {
                            guard musicSongsRequestID == requestID else { return }
                            applyResolvedRootMusicShufflePlayback(
                                with: [seedSong],
                                usingExistingBlackout: usingExistingBlackout,
                            )
                        }
                        let result = try await fetchMusicLibrarySongsForShuffleWithItemIndices()
                        await MainActor.run {
                            guard musicSongsRequestID == requestID else { return }
                            musicLibraryItemIndexBySongID = result.itemIndices
                            musicLibraryArtworkDataByAlbumKey = result.artworkDataByAlbumKey
                            musicShuffleSongsCache = result.songs
                            guard activeMusicPlaybackSongID == seedSong.id else { return }
                            let shuffleRequestID = incrementRequestID(&musicShuffleRequestID)
                            requestSeededShuffleQueue(
                                from: result.songs,
                                currentSong: seedSong,
                                requestID: shuffleRequestID,
                            ) { seededQueue in
                                guard self.activeMusicPlaybackSongID == seedSong.id else { return }
                                self.musicSongsThirdMenuItems = seededQueue
                                self.musicNowPlayingTrackPositionText = seededQueue.isEmpty ? "" : "1 of \(seededQueue.count)"
                                self.refreshMusicPreviewForCurrentContext()
                            }
                        }
                    } catch {
                        await MainActor.run {
                            guard musicSongsRequestID == requestID else { return }
                            deferNowPlayingMenuItemUntilAfterFadeOut = false
                            isLoadingMusicSongs = false
                            musicSongsThirdMenuItems = []
                            selectedThirdIndex = 0
                            musicSongsLoadError = musicLibraryErrorMessage(for: error)
                        }
                    }
                }
                return
            #else
                Task(priority: .userInitiated) {
                    do {
                        let songs = try fetchMusicLibrarySongsForShuffle()
                        await MainActor.run {
                            guard musicSongsRequestID == requestID else { return }
                            musicShuffleSongsCache = songs
                            applyRootMusicShufflePlayback(
                                with: songs,
                                usingExistingBlackout: usingExistingBlackout,
                            )
                        }
                    } catch {
                        await MainActor.run {
                            guard musicSongsRequestID == requestID else { return }
                            deferNowPlayingMenuItemUntilAfterFadeOut = false
                            isLoadingMusicSongs = false
                            musicSongsThirdMenuItems = []
                            selectedThirdIndex = 0
                            musicSongsLoadError = musicLibraryErrorMessage(for: error)
                        }
                    }
                }
            #endif
        }
    }

    func startMusicShufflePlaybackFromLibrary() {
        let canReuseExistingSongsQueue =
            activeMusicLibraryMediaType == .songs &&
            !isMusicSongsCategoryScoped &&
            !musicSongsThirdMenuItems.isEmpty
        if !isMusicActivelyPlaying {
            deferNowPlayingMenuItemUntilAfterFadeOut = true
        }
        activeMusicLibraryMediaType = .songs
        musicSongsShowsShuffleAction = false
        if canReuseExistingSongsQueue {
            applyRootMusicShufflePlayback(with: musicSongsThirdMenuItems)
            return
        }
        if let cachedSongs = musicAllSongsCache {
            applyRootMusicShufflePlayback(with: cachedSongs)
            return
        }
        if let cachedShuffleSongs = musicShuffleSongsCache {
            applyRootMusicShufflePlayback(with: cachedShuffleSongs)
            return
        }
        #if canImport(iTunesLibrary)
            transitionMenuForFolderSwap(
                useOverlayFade: true,
                revealWhen: { !self.isLoadingMusicSongs },
            ) {
                self.loadRootMusicShufflePlaybackFromLibrary(usingExistingBlackout: true)
            }
        #else
            loadRootMusicShufflePlaybackFromLibrary()
        #endif
    }

    func musicLibraryErrorMessage(for error: Error) -> String {
        _ = error
        return "Unable to access Music library"
    }

    func musicLibraryEmptyErrorKind(for mediaType: MusicLibraryMediaType) -> FeatureErrorKind {
        switch mediaType {
        case .audiobooks:
            .noAudiobooks
        case .musicVideos:
            .noMusicVideos
        case .songs:
            .noSongs
        }
    }

    func musicCategoryEmptyErrorKind(for kind: MusicCategoryKind) -> FeatureErrorKind {
        switch kind {
        case .playlists:
            .noPlaylists
        case .albums, .artists, .genres, .composers:
            .noSongs
        }
    }

    func presentMusicLibraryEmptyError(for mediaType: MusicLibraryMediaType) {
        presentMusicLibraryEmptyErrorScreen(musicLibraryEmptyErrorKind(for: mediaType))
    }

    func presentMusicCategoryEmptyError(for kind: MusicCategoryKind) {
        presentMusicLibraryEmptyErrorScreen(musicCategoryEmptyErrorKind(for: kind))
    }

    func presentMusicLibraryEmptyErrorScreen(_ kind: FeatureErrorKind) {
        guard activeRootItemID == "music", isInSubmenu else { return }
        var instant = Transaction()
        instant.animation = nil
        withTransaction(instant) {
            isInThirdMenu = false
            thirdMenuMode = .none
            thirdMenuOpacity = 0
            submenuOpacity = 1
            headerText = rootMenuTitle(for: activeRootItemID)
            selectedThirdIndex = 0
            isMusicSongsShuffleMode = false
            isMusicSongsCategoryScoped = false
            activeMusicCategoryKind = nil
            activeMusicCategoryMenuTitle = ""
            lastSelectedMusicCategoryIndex = 0
            musicSongsShowsShuffleAction = false
            isLoadingMusicSongs = false
            musicSongsLoadError = nil
            musicCategoryThirdMenuItems = []
            musicSongsThirdMenuItems = []
        }
        func presentWhenReady(retryCount: Int = 0) {
            guard activeRootItemID == "music", isInSubmenu else { return }
            guard activeFullscreenScene == nil else { return }
            guard !isMovieTransitioning, !isFullscreenSceneTransitioning else {
                guard retryCount < 60 else { return }
                Task {
                    try? await firstRowSleep(0.05)
                    presentWhenReady(retryCount: retryCount + 1)
                }
                return
            }
            presentFeatureErrorScreen(kind)
        }
        presentWhenReady()
    }
}

extension MenuView {
    struct MusicLibrarySongEntry: Identifiable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let genre: String
        let composer: String
        let durationSeconds: Double
        let trackNumber: Int
        let discNumber: Int
        let artworkAlbumKey: String?
        let url: URL?
        let artwork: NSImage?
    }

    struct MusicCategoryEntry: Identifiable {
        let id: String
        let title: String
        let songs: [MusicLibrarySongEntry]
    }

    enum MusicCategoryKind: String {
        case albums
        case artists
        case genres
        case composers
        case playlists
        var emptyLibraryMessage: String {
            switch self {
            case .albums: "No Albums in Music Library"
            case .artists: "No Artists in Music Library"
            case .genres: "No Genres in Music Library"
            case .composers: "No Composers in Music Library"
            case .playlists: "No Playlists in Music Library"
            }
        }
    }

    enum MusicLibraryMediaType {
        case songs
        case musicVideos
        case audiobooks
        var emptyLibraryMessage: String {
            switch self {
            case .songs: "No Songs in Music Library"
            case .musicVideos: "No Music Videos in Music Library"
            case .audiobooks: "No Audiobooks in Music Library"
            }
        }
    }

    var musicFallbackImage: NSImage? {
        NSImage(named: "musicfallback")
    }
}
