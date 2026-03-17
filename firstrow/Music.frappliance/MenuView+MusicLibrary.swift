import AVFoundation
import Foundation
import SwiftUI
#if os(iOS)
    import MediaPlayer
    import UIKit
#endif
#if os(tvOS) || os(macOS)
    import MusicKit
#endif
#if os(macOS)
    import StoreKit
#endif
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
    var blocksMenuForStartupMusicLibraryPreload: Bool {
        !isStartupMusicLibraryPreloadComplete || startupMusicLibraryPreloadOverlayOpacity > 0.001
    }

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

    func loadStartupMusicLibrarySnapshot() throws -> (
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
            let result = try fetchMusicLibrarySongsForShuffleWithItemIndices()
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
            Task(priority: .userInitiated) {
                do {
                    let snapshot = try loadStartupMusicLibrarySnapshot()
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
        #if os(iOS)
            guard MPMediaLibrary.authorizationStatus() == .authorized else {
                throw NSError(
                    domain: "firstRowMusicLibrary",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Music library access not authorized"],
                )
            }
            let mediaItems = MPMediaQuery.songs().items ?? []
            var seenAlbumKeys: Set<String> = []
            var matchedIndex = 0
            var artworks: [NSImage?] = []
            artworks.reserveCapacity(resolvedLimit)
            for item in mediaItems {
                guard let song = makeMusicLibrarySongEntry(from: item) else { continue }
                let albumKey = musicTopLevelCarouselAlbumKey(for: item)
                guard seenAlbumKeys.insert(albumKey).inserted else { continue }
                guard matchedIndex >= resolvedStartIndex else {
                    matchedIndex += 1
                    continue
                }
                artworks.append(song.artwork ?? musicFallbackImage)
                if artworks.count >= resolvedLimit {
                    break
                }
                matchedIndex += 1
            }
            return artworks
        #elseif os(tvOS)
            guard MusicAuthorization.currentStatus == .authorized else {
                throw NSError(
                    domain: "firstRowMusicLibrary",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Music library access not authorized"],
                )
            }
            guard #available(tvOS 16.0, *) else {
                throw NSError(
                    domain: "firstRowMusicLibrary",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "MusicKit library requests require tvOS 16 or newer"],
                )
            }
            var fetchResult: Result<[NSImage?], Error>?
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                defer { semaphore.signal() }
                do {
                    let rawBatchSize = max(resolvedLimit * 4, 72)
                    var rawOffset = 0
                    var uniqueAlbumIndex = 0
                    var seenAlbumKeys: Set<String> = []
                    var artworks: [NSImage?] = []
                    artworks.reserveCapacity(resolvedLimit)
                    while artworks.count < resolvedLimit {
                        var request = MusicLibraryRequest<Song>()
                        request.limit = rawBatchSize
                        request.offset = rawOffset
                        let response = try await request.response()
                        guard !response.items.isEmpty else { break }
                        for song in response.items {
                            let albumKey = self.musicTopLevelCarouselAlbumKey(for: song)
                            guard seenAlbumKeys.insert(albumKey).inserted else { continue }
                            guard uniqueAlbumIndex >= resolvedStartIndex else {
                                uniqueAlbumIndex += 1
                                continue
                            }
                            artworks.append(loadMusicKitArtworkImage(song.artwork) ?? musicFallbackImage)
                            uniqueAlbumIndex += 1
                            if artworks.count >= resolvedLimit {
                                break
                            }
                        }
                        rawOffset += response.items.count
                        if response.items.count < rawBatchSize {
                            break
                        }
                    }
                    fetchResult = .success(artworks)
                } catch {
                    fetchResult = .failure(error)
                }
            }
            semaphore.wait()
            return try fetchResult?.get() ?? []
        #elseif canImport(iTunesLibrary)
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

    #if os(iOS)
        func musicTopLevelCarouselAlbumKey(for item: MPMediaItem) -> String {
            let albumPersistentID = (item.value(forProperty: MPMediaItemPropertyAlbumPersistentID) as? NSNumber)?.stringValue
            return normalizedMusicTopLevelCarouselAlbumKey(
                albumTitle: item.albumTitle,
                albumArtist: item.albumArtist,
                persistentAlbumID: albumPersistentID,
                fallbackItemID: "\(item.persistentID)",
            )
        }
    #endif

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

    #if os(tvOS)
        func musicTopLevelCarouselAlbumKey(for song: Song) -> String {
            normalizedMusicTopLevelCarouselAlbumKey(
                albumTitle: song.albumTitle,
                albumArtist: nil,
                persistentAlbumID: nil,
                fallbackItemID: song.id.rawValue,
            )
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
            let sortedCategorySongs = groupedCategorySongs.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
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
        transitionMenuForFolderSwap(useOverlayFade: useOverlayFade) {
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
            useOverlayFade: true,
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
            useOverlayFade: true,
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
        #if os(iOS)
            guard MPMediaLibrary.authorizationStatus() == .authorized else {
                throw NSError(
                    domain: "firstRowMusicLibrary",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Music library access not authorized"],
                )
            }
            let mediaItems = MPMediaQuery.songs().items ?? []
            guard !mediaItems.isEmpty else { return nil }
            let startIndex = Int.random(in: 0 ..< mediaItems.count)
            for offset in 0 ..< mediaItems.count {
                let resolvedIndex = (startIndex + offset) % mediaItems.count
                let item = mediaItems[resolvedIndex]
                if let song = makeMusicLibrarySongEntry(from: item, includeArtwork: includeArtwork) {
                    return song
                }
            }
            return nil
        #elseif canImport(iTunesLibrary)
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
        func fetchMusicLibrarySongsWithItemIndices(
            includeArtwork: Bool = false,
            shouldSort: Bool = true,
        ) throws -> (
            songs: [MusicLibrarySongEntry],
            itemIndices: [String: Int],
            artworkDataByAlbumKey: [String: Data],
        ) {
            try withITLibrary { library in
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
                return (
                    songs: shouldSort ? sortedMusicLibraryEntries(songs) : songs,
                    itemIndices: itemIndices,
                    artworkDataByAlbumKey: artworkDataByAlbumKey,
                )
            }
        }

        func fetchMusicLibrarySongsForShuffleWithItemIndices() throws -> (
            songs: [MusicLibrarySongEntry],
            itemIndices: [String: Int],
            artworkDataByAlbumKey: [String: Data],
        ) {
            try fetchMusicLibrarySongsWithItemIndices(
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
        #if os(iOS)
            guard MPMediaLibrary.authorizationStatus() == .authorized else {
                throw NSError(
                    domain: "firstRowMusicLibrary",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Music library access not authorized"],
                )
            }
            let mediaItems: [MPMediaItem]
            switch mediaType {
            case .songs:
                mediaItems = MPMediaQuery.songs().items ?? []
            case .musicVideos:
                let query = MPMediaQuery.songs()
                let predicate = MPMediaPropertyPredicate(
                    value: MPMediaType.musicVideo.rawValue,
                    forProperty: MPMediaItemPropertyMediaType,
                    comparisonType: .equalTo,
                )
                query.addFilterPredicate(predicate)
                mediaItems = query.items ?? []
            case .audiobooks:
                mediaItems = MPMediaQuery.audiobooks().items ?? []
            }
            let entries = mediaItems.compactMap { makeMusicLibrarySongEntry(from: $0, includeArtwork: includeArtwork) }
            return shouldSort ? sortedMusicLibraryEntries(entries) : entries
        #elseif os(tvOS)
            switch mediaType {
            case .songs:
                return try fetchMusicLibrarySongsFromMusicKit(
                    includeArtwork: includeArtwork,
                    shouldSort: shouldSort,
                )
            case .musicVideos, .audiobooks:
                return []
            }
        #elseif canImport(iTunesLibrary)
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
        #if os(iOS)
            guard MPMediaLibrary.authorizationStatus() == .authorized else {
                throw NSError(
                    domain: "firstRowMusicLibrary",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Music library access not authorized"],
                )
            }
            let collections = MPMediaQuery.playlists().collections ?? []
            let playlists: [MusicCategoryEntry] = collections.compactMap { collection in
                let playlist = collection as? MPMediaPlaylist
                let title = normalizedMusicLibraryText(playlist?.name, fallback: "Untitled Playlist")
                let persistentID = playlist.map { "\($0.persistentID)" } ?? title.lowercased()
                let songs = sortedMusicLibraryEntries(collection.items.compactMap { makeMusicLibrarySongEntry(from: $0) })
                guard !songs.isEmpty else { return nil }
                return MusicCategoryEntry(
                    id: "playlist::ios::\(persistentID)",
                    title: title,
                    songs: songs,
                )
            }
            return playlists.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        #elseif canImport(iTunesLibrary)
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

    #if os(iOS)
        func makeMusicLibrarySongEntry(from item: MPMediaItem, includeArtwork: Bool = true) -> MusicLibrarySongEntry? {
            guard let locationURL = item.assetURL else { return nil }
            let title = normalizedMusicLibraryText(
                item.title,
                fallback: locationURL.deletingPathExtension().lastPathComponent,
            )
            let artist = normalizedMusicLibraryText(item.artist, fallback: "Unknown Artist")
            let album = normalizedMusicLibraryText(item.albumTitle, fallback: "Unknown Album")
            let genre = normalizedMusicLibraryText(item.genre, fallback: "Unknown Genre")
            let composer = normalizedMusicLibraryText(item.composer, fallback: "Unknown Composer")
            return MusicLibrarySongEntry(
                id: "\(item.persistentID)",
                title: title,
                artist: artist,
                album: album,
                genre: genre,
                composer: composer,
                durationSeconds: max(0, item.playbackDuration),
                artworkAlbumKey: musicTopLevelCarouselAlbumKey(for: item),
                url: locationURL,
                artwork: includeArtwork ? item.artwork?.image(at: CGSize(width: 800, height: 800)) : nil,
            )
        }
    #endif
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
            if Thread.isMainThread {
                let lib = try ITLibrary(apiVersion: "1.0")
                return try work(lib)
            }
            var result: Result<T, Error>?
            DispatchQueue.main.sync {
                result = Result {
                    let lib = try ITLibrary(apiVersion: "1.0")
                    return try work(lib)
                }
            }
            return try result!.get()
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
                artworkAlbumKey: musicTopLevelCarouselAlbumKey(for: item),
                url: locationURL,
                artwork: includeArtwork ? resolvedMusicLibraryEmbeddedArtworkImage(for: item) : nil,
            )
        }
    #endif
    #if os(tvOS)
        func fetchMusicLibrarySongsFromMusicKit(
            includeArtwork: Bool = true,
            shouldSort: Bool = true,
        ) throws -> [MusicLibrarySongEntry] {
            guard MusicAuthorization.currentStatus == .authorized else {
                throw NSError(
                    domain: "firstRowMusicLibrary",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Music library access not authorized"],
                )
            }
            guard #available(tvOS 16.0, *) else {
                throw NSError(
                    domain: "firstRowMusicLibrary",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "MusicKit library requests require tvOS 16 or newer"],
                )
            }
            var fetchResult: Result<[MusicLibrarySongEntry], Error>?
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                defer { semaphore.signal() }
                do {
                    var request = MusicLibraryRequest<Song>()
                    request.limit = 5000
                    let response = try await request.response()
                    var songs: [MusicLibrarySongEntry] = []
                    songs.reserveCapacity(response.items.count)
                    for song in response.items {
                        guard let entry = makeMusicLibrarySongEntry(from: song, includeArtwork: includeArtwork) else {
                            continue
                        }
                        songs.append(entry)
                    }
                    fetchResult = .success(shouldSort ? sortedMusicLibraryEntries(songs) : songs)
                } catch {
                    fetchResult = .failure(error)
                }
            }
            semaphore.wait()
            return try fetchResult?.get() ?? []
        }

        func makeMusicLibrarySongEntry(from song: Song, includeArtwork: Bool = true) -> MusicLibrarySongEntry? {
            guard song.playParameters != nil else { return nil }
            let previewURL = song.previewAssets?.first(where: { $0.hlsURL != nil || $0.url != nil })
            let playbackURL = previewURL?.hlsURL ?? previewURL?.url ?? song.url
            let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = song.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
            let album = (song.albumTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let genre = song.genreNames.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let composer = (song.composerName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return MusicLibrarySongEntry(
                id: song.id.rawValue,
                title: title.isEmpty ? "Unknown Song" : title,
                artist: artist.isEmpty ? "Unknown Artist" : artist,
                album: album.isEmpty ? "Unknown Album" : album,
                genre: genre.isEmpty ? "Unknown Genre" : genre,
                composer: composer.isEmpty ? "Unknown Composer" : composer,
                durationSeconds: max(0, song.duration ?? 0),
                artworkAlbumKey: musicTopLevelCarouselAlbumKey(for: song),
                url: playbackURL,
                artwork: includeArtwork ? loadMusicKitArtworkImage(song.artwork) : nil,
                musicKitSong: song,
            )
        }

        func loadMusicKitArtworkImage(_ artwork: Artwork?) -> NSImage? {
            guard let artwork else { return nil }
            let side = max(300, min(800, min(artwork.maximumWidth, artwork.maximumHeight)))
            guard let artworkURL = artwork.url(width: side, height: side) else { return nil }
            guard let data = try? Data(contentsOf: artworkURL) else { return nil }
            return cachedDecodedDisplayArtworkImage(
                from: data,
                sourceKey: artworkURL.absoluteString,
                maxPixelSize: CGFloat(side),
            )
        }
    #endif

    func requestMusicLibraryAuthorization(completion: @escaping (Bool) -> Void) {
        #if os(iOS)
            let status = MPMediaLibrary.authorizationStatus()
            switch status {
            case .authorized:
                completion(true)
            case .denied, .restricted:
                completion(false)
            case .notDetermined:
                MPMediaLibrary.requestAuthorization { newStatus in
                    Task { @MainActor in
                        completion(newStatus == .authorized)
                    }
                }
            @unknown default:
                completion(false)
            }
        #elseif os(tvOS)
            let status = MusicAuthorization.currentStatus
            switch status {
            case .authorized:
                completion(true)
            case .denied, .restricted:
                completion(false)
            case .notDetermined:
                Task {
                    let newStatus = await MusicAuthorization.request()
                    await MainActor.run {
                        completion(newStatus == .authorized)
                    }
                }
            @unknown default:
                completion(false)
            }
        #else
            completion(true)
        #endif
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
                            let result = try fetchMusicLibrarySongsWithItemIndices(includeArtwork: false)
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
                                let result = try fetchMusicLibrarySongsWithItemIndices(includeArtwork: false)
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
                        let result = try fetchMusicLibrarySongsForShuffleWithItemIndices()
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
        #if os(tvOS) || os(iOS)
            let nsError = error as NSError
            if nsError.domain == "ICError", nsError.code == -7013 {
                return "Music library access is unavailable for this build."
            }
        #endif
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
        let artworkAlbumKey: String?
        let url: URL?
        let artwork: NSImage?
        #if os(tvOS)
            let musicKitSong: Song?
        #endif
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
