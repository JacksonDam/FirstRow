import AVFoundation
import Foundation
import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif
#if os(iOS)
    import MediaPlayer
    import UIKit
#endif
#if os(tvOS)
    import MusicKit
#endif
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif

#if os(macOS)
    let musicApplicationName = "Music"

    actor MusicAppleScriptExecutor {
        func run<T: Sendable>(_ operation: () -> T) -> T {
            operation()
        }
    }

    let musicAppleScriptExecutor = MusicAppleScriptExecutor()

    struct AppleScriptExecutionResult: Sendable {
        let standardOutput: String
        let standardError: String
        let exitCode: Int32
        let processErrorDescription: String?

        var succeeded: Bool {
            exitCode == 0 && processErrorDescription == nil
        }

        var trimmedStandardOutput: String {
            standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var combinedFailureDescription: String {
            [
                processErrorDescription,
                standardError.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        }
    }

    func appleScriptFailureDescription(from errorInfo: NSDictionary) -> String {
        let briefMessage = (errorInfo[NSAppleScript.errorBriefMessage] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fullMessage = (errorInfo[NSAppleScript.errorMessage] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errorNumber = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue

        var components: [String] = []
        if let briefMessage, !briefMessage.isEmpty {
            components.append(briefMessage)
        }
        if let fullMessage, !fullMessage.isEmpty, fullMessage != briefMessage {
            components.append(fullMessage)
        }
        if let errorNumber {
            components.append("(\(errorNumber))")
        }
        return components.joined(separator: " ")
    }

    private func executeAppleScriptInProcess(_ source: String) -> AppleScriptExecutionResult {
        guard let script = NSAppleScript(source: source) else {
            return AppleScriptExecutionResult(
                standardOutput: "",
                standardError: "",
                exitCode: 1,
                processErrorDescription: "Unable to create NSAppleScript",
            )
        }
        var errorInfo: NSDictionary?
        let descriptor = autoreleasepool {
            script.executeAndReturnError(&errorInfo)
        }
        if let errorInfo {
            return AppleScriptExecutionResult(
                standardOutput: descriptor.stringValue ?? "",
                standardError: appleScriptFailureDescription(from: errorInfo),
                exitCode: 1,
                processErrorDescription: nil,
            )
        }
        return AppleScriptExecutionResult(
            standardOutput: descriptor.stringValue ?? "",
            standardError: "",
            exitCode: 0,
            processErrorDescription: nil,
        )
    }

    func executeAppleScript(_ source: String) -> AppleScriptExecutionResult {
        if FirstRowHarness.isActive {
            return AppleScriptExecutionResult(standardOutput: "", standardError: "AppleScript is off in the harness", exitCode: 1, processErrorDescription: nil)
        }
        return executeAppleScriptInProcess(source)
    }

    func appleScriptFailedBecauseApplicationIsNotRunning(_ result: AppleScriptExecutionResult) -> Bool {
        let combined = result.combinedFailureDescription.lowercased()
        return combined.contains("application isn't running") ||
            combined.contains("application isn’t running") ||
            combined.contains("(-600)")
    }

    func isMusicApplicationRunning() -> Bool {
        let result = executeAppleScript(
            """
            tell application "\(musicApplicationName)"
                return running
            end tell
            """
        )
        return result.succeeded && result.trimmedStandardOutput == "true"
    }

    func waitForMusicApplicationToBecomeReady(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1,
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isMusicApplicationRunning() {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return isMusicApplicationRunning()
    }

    func launchMusicApplicationIfNeeded(timeout: TimeInterval) -> Bool {
        if waitForMusicApplicationToBecomeReady(timeout: 0.05, pollInterval: 0.05) {
            return true
        }
        let launchResult = executeAppleScript(
            """
            tell application "\(musicApplicationName)"
                launch
            end tell
            """
        )
        if !launchResult.succeeded, !appleScriptFailedBecauseApplicationIsNotRunning(launchResult) {
            return false
        }
        return waitForMusicApplicationToBecomeReady(timeout: timeout)
    }

    func executeMusicApplicationAppleScript(
        _ source: String,
        launchIfNeeded: Bool = false,
        retryCount: Int = 0,
        retryDelay: TimeInterval = 0.1,
    ) -> AppleScriptExecutionResult {
        if launchIfNeeded {
            let launchTimeout = max(2.5, Double(retryCount + 1) * retryDelay)
            guard launchMusicApplicationIfNeeded(timeout: launchTimeout) else {
                return AppleScriptExecutionResult(
                    standardOutput: "",
                    standardError: "Unable to launch Music.app",
                    exitCode: 1,
                    processErrorDescription: nil,
                )
            }
        }

        var remainingRetries = max(0, retryCount)
        var result = executeAppleScript(source)
        while remainingRetries > 0,
              !result.succeeded,
              appleScriptFailedBecauseApplicationIsNotRunning(result)
        {
            _ = waitForMusicApplicationToBecomeReady(
                timeout: retryDelay,
                pollInterval: min(retryDelay, 0.05),
            )
            result = executeAppleScript(source)
            remainingRetries -= 1
        }
        return result
    }

    /// Unplayable Apple Music tracks, looked up through AppleScript in the background.
    final class UnavailableAppleMusicTrackCache {
        static let shared = UnavailableAppleMusicTrackCache()
        static let didUpdateNotification = Notification.Name("FirstRowUnavailableAppleMusicTracksDidUpdate")
        fileprivate static let lookupQueue = DispatchQueue(label: "First Row unavailable Apple Music tracks", qos: .utility)

        private let lock = NSLock()
        private var cachedPersistentIDHexes: Set<String>?
        private var fetchTask: Task<Set<String>, Never>?

        /// Never blocks: returns what is known so far and starts the lookup if needed.
        func persistentIDHexes() -> Set<String> {
            if let cached = cachedValue() {
                return cached
            }
            _ = startFetchIfNeeded()
            return []
        }

        /// Starts the lookup and waits for it, but never longer than `timeout` seconds.
        func prefetch(timeout: TimeInterval) async {
            guard cachedValue() == nil, let task = startFetchIfNeeded() else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let gate = ResumeOnceGate()
                Task {
                    _ = await task.value
                    if gate.claim() { continuation.resume() }
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    if gate.claim() { continuation.resume() }
                }
            }
        }

        private func cachedValue() -> Set<String>? {
            lock.lock()
            defer { lock.unlock() }
            return cachedPersistentIDHexes
        }

        private func startFetchIfNeeded() -> Task<Set<String>, Never>? {
            lock.lock()
            defer { lock.unlock() }
            if cachedPersistentIDHexes != nil { return nil }
            if let fetchTask { return fetchTask }
            let task = Task.detached(priority: .utility) { () -> Set<String> in
                // Own queue, so a slow lookup on a big library doesn't hold up playback scripts.
                let fetched = await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>, Never>) in
                    UnavailableAppleMusicTrackCache.lookupQueue.async {
                        continuation.resume(returning: UnavailableAppleMusicTrackCache.fetchPersistentIDHexes())
                    }
                }
                UnavailableAppleMusicTrackCache.shared.store(fetched)
                if !fetched.isEmpty {
                    await MainActor.run {
                        NotificationCenter.default.post(name: UnavailableAppleMusicTrackCache.didUpdateNotification, object: nil)
                    }
                }
                return fetched
            }
            fetchTask = task
            return task
        }

        private func store(_ persistentIDHexes: Set<String>) {
            lock.lock()
            defer { lock.unlock() }
            cachedPersistentIDHexes = persistentIDHexes
            fetchTask = nil
        }

        private static let unavailableStatusesSource =
            #"{"error", "ineligible", "no longer available", "prerelease", "removed"}"#

        private static func fetchPersistentIDHexes() -> Set<String> {
            // Two bulk requests for every ID and status, not two Apple Events per track.
            let bulkResult = executeAppleScript(bulkSource)
            if bulkResult.succeeded {
                return parsePersistentIDHexes(bulkResult.trimmedStandardOutput)
            }
            if appleScriptFailedBecauseApplicationIsNotRunning(bulkResult) {
                return []
            }
            // Bulk requests and `whose` filters fail on some libraries, so fall back to one track at a time.
            let perTrackResult = executeAppleScript(perTrackSource)
            if !perTrackResult.succeeded, !appleScriptFailedBecauseApplicationIsNotRunning(perTrackResult) {
                print("[Music] unavailable track lookup error: \(perTrackResult.combinedFailureDescription)")
            }
            return parsePersistentIDHexes(perTrackResult.trimmedStandardOutput)
        }

        private static func parsePersistentIDHexes(_ rawText: String) -> Set<String> {
            guard !rawText.isEmpty else { return [] }
            return Set(
                rawText
                    .components(separatedBy: .whitespacesAndNewlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                    .filter { !$0.isEmpty },
            )
        }

        private static let bulkSource = """
        tell application "\(musicApplicationName)"
            if not running then
                return ""
            end if
            set unavailableStatuses to \(unavailableStatusesSource)
            with timeout of 30 seconds
                set trackIDs to persistent ID of every track of library playlist 1
                set trackStatuses to cloud status of every track of library playlist 1
            end timeout
            if (count of trackIDs) is not (count of trackStatuses) then
                error "Track ID and status counts differ"
            end if
            set unavailableTrackIDs to {}
            repeat with trackIndex from 1 to count of trackIDs
                if unavailableStatuses contains ((item trackIndex of trackStatuses) as text) then
                    set end of unavailableTrackIDs to (item trackIndex of trackIDs)
                end if
            end repeat
            set AppleScript's text item delimiters to linefeed
            set unavailableTrackIDsText to unavailableTrackIDs as text
            set AppleScript's text item delimiters to ""
            return unavailableTrackIDsText
        end tell
        """

        private static let perTrackSource = """
        tell application "\(musicApplicationName)"
            if not running then
                return ""
            end if
            set unavailableTrackIDs to {}
            set unavailableStatuses to \(unavailableStatusesSource)
            repeat with libraryTrack in every track of library playlist 1
                try
                    set cloudStatusText to (cloud status of libraryTrack as text)
                    if unavailableStatuses contains cloudStatusText then
                        set end of unavailableTrackIDs to (persistent ID of libraryTrack)
                    end if
                end try
            end repeat
            if (count of unavailableTrackIDs) is 0 then
                return ""
            end if
            set AppleScript's text item delimiters to linefeed
            set unavailableTrackIDsText to unavailableTrackIDs as text
            set AppleScript's text item delimiters to ""
            return unavailableTrackIDsText
        end tell
        """
    }

    /// Lets exactly one of several racing callbacks resume a continuation.
    final class ResumeOnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
#endif

extension MenuView {
    var startupMusicLibraryPreloadTimeout: Double {
        12
    }

    private static let holdsMusicForStartupLibraryLoad = false

    var blocksMenuForStartupMusicLibraryPreload: Bool {
        !isStartupMusicLibraryPreloadComplete || startupMusicLibraryPreloadOverlayOpacity > 0.001
    }

    /// Music used to wait for the launch library load before it opened. It opens at once now:
    /// nothing in its own menu needs the load, and a list that does waits for it instead.
    func deferForStartupMusicLibraryPreload(_ key: KeyCode) -> Bool {
        guard Self.holdsMusicForStartupLibraryLoad, blocksMenuForStartupMusicLibraryPreload else { return false }
        guard key == .enter, !isInSubmenu, !isEnteringSubmenu, activeFullscreenScene == nil,
              menuItems.indices.contains(selectedIndex), menuItems[selectedIndex].id == "music"
        else { return false }
        isMusicEntryWaitingForStartupPreload = true
        return true
    }

    func finishStartupMusicLibraryPreload() {
        isStartupMusicLibraryPreloadComplete = true
        if isMusicEntryWaitingForStartupPreload {
            isMusicEntryWaitingForStartupPreload = false
            if !isInSubmenu, !isEnteringSubmenu, activeFullscreenScene == nil,
               menuItems.indices.contains(selectedIndex), menuItems[selectedIndex].id == "music"
            {
                startSubmenuTransition()
            }
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            startupMusicLibraryPreloadOverlayOpacity = 0
        }
        #if os(macOS)
            installMusicSystemPlayerObserversIfNeeded()
            requestMusicSystemPlayerSnapshotForRestoreIfNeeded(force: false)
        #endif
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
    ) {
        #if canImport(iTunesLibrary)
            let result = try await fetchMusicLibrarySongsForShuffleWithItemIndices()
            return (
                sortedSongs: sortedMusicLibraryEntries(result.songs),
                shuffleSongs: result.songs,
                itemIndices: result.itemIndices,
            )
        #else
            let songs = try await fetchMusicLibrarySongsForShuffle()
            // Sorting thousands of titles takes a while too.
            let sorted = await Task.detached(priority: .userInitiated) { self.sortedMusicLibraryEntries(songs) }.value
            return (
                sortedSongs: sorted,
                shuffleSongs: songs,
                itemIndices: [:],
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
        // Never leave the menu locked if the library read stalls or a permission prompt goes unanswered.
        Task {
            try? await firstRowSleep(startupMusicLibraryPreloadTimeout)
            guard self.musicStartupPreloadRequestID == requestID, !self.isStartupMusicLibraryPreloadComplete else { return }
            self.finishStartupMusicLibraryPreload()
        }
        requestMusicLibraryAuthorization { isAuthorized in
            guard self.musicStartupPreloadRequestID == requestID else { return }
            guard isAuthorized else {
                self.finishStartupMusicLibraryPreload()
                return
            }
            Task(priority: .userInitiated) {
                #if os(macOS)
                    // Prefetch unplayable tracks first so the library scan doesn't wait on Music.app.
                    await UnavailableAppleMusicTrackCache.shared.prefetch(timeout: 6)
                #endif
                do {
                    let snapshot = try await self.loadStartupMusicLibrarySnapshot()
                    await MainActor.run {
                        guard self.musicStartupPreloadRequestID == requestID else { return }
                        self.musicAllSongsCache = snapshot.sortedSongs
                        self.musicShuffleSongsCache = snapshot.shuffleSongs
                        #if canImport(iTunesLibrary)
                            self.musicLibraryItemIndexBySongID = snapshot.itemIndices
                        #endif
                        self.finishStartupMusicLibraryPreload()
                    }
                } catch {
                    await MainActor.run {
                        guard self.musicStartupPreloadRequestID == requestID else { return }
                        self.finishStartupMusicLibraryPreload()
                    }
                }
            }
        }
    }

    #if os(macOS)
        /// Drops unplayable tracks from the loaded lists once their late lookup finishes.
        func removeUnavailableAppleMusicTracksFromCaches() {
            let unavailable = UnavailableAppleMusicTrackCache.shared.persistentIDHexes()
            guard !unavailable.isEmpty else { return }
            func isAvailable(_ song: MusicLibrarySongEntry) -> Bool {
                guard song.prefersSystemMusicPlayerPlayback, let persistentID = UInt64(song.id) else { return true }
                return !unavailable.contains(String(format: "%016llX", persistentID))
            }
            if let songs = musicAllSongsCache {
                let filtered = songs.filter(isAvailable)
                if filtered.count != songs.count { musicAllSongsCache = filtered }
            }
            if let songs = musicShuffleSongsCache {
                let filtered = songs.filter(isAvailable)
                if filtered.count != songs.count { musicShuffleSongsCache = filtered }
            }
        }
    #endif

    /// Picks up folders and libraries added or removed in Settings, without blocking the menu.
    func reloadMediaAfterSourcesChange() {
        requestPhotoSourceAlbumsLoad()
        guard isStartupMusicLibraryPreloadComplete else { return }
        let requestID = incrementRequestID(&musicStartupPreloadRequestID)
        Task(priority: .userInitiated) {
            guard let snapshot = try? await self.loadStartupMusicLibrarySnapshot() else { return }
            guard self.musicStartupPreloadRequestID == requestID else { return }
            self.musicAllSongsCache = snapshot.sortedSongs
            self.musicShuffleSongsCache = snapshot.shuffleSongs
            #if canImport(iTunesLibrary)
                self.musicLibraryItemIndexBySongID = snapshot.itemIndices
            #endif
            self.reloadMusicTopLevelCarousel()
        }
    }

    func reloadMusicTopLevelCarousel() {
        _ = incrementRequestID(&musicTopLevelCarouselRequestID)
        musicTopLevelCarouselArtworksByIndex = [:]
        musicTopLevelCarouselLoadedArtworkCount = 0
        musicTopLevelCarouselResolvedArtworkCount = nil
        musicTopLevelCarouselPageStartsInFlight.removeAll()
        isLoadingMusicTopLevelCarousel = false
        refreshDetailPreviewForCurrentContext()
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
        musicPreviewDisplayedSong = nil
        _ = incrementRequestID(&musicPreviewRequestID)
    }

    func resetMusicPreviewState() {
        musicPreviewTargetSongID = nil
        musicPreviewImage = nil
        musicPreviewDisplayedSong = nil
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

    var isShowingMusicAlbumsList: Bool {
        thirdMenuMode == .musicCategories && activeMusicCategoryKind == .albums
    }

    func resolveMusicPreviewTargetSong() -> MusicLibrarySongEntry? {
        guard isMusicLibraryContext, isInSubmenu, isInThirdMenu else { return nil }
        if thirdMenuMode == .spotify {
            return spotifyCollectionPreviewEntry()
        }
        if isShowingMusicAlbumsList {
            guard musicCategoryThirdMenuItems.indices.contains(selectedThirdIndex) else { return nil }
            let albumSongs = musicCategoryThirdMenuItems[selectedThirdIndex].songs
            return albumSongs.first { $0.artwork != nil || $0.artworkAlbumKey != nil || $0.url != nil } ?? albumSongs.first
        }
        guard thirdMenuMode == .musicSongs else { return nil }
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
        await generateMusicArtworkThumbnailOffMain(for: url)
    }

    func musicArtworkCacheKey(for url: URL) -> String {
        musicArtworkCacheKeyForFile(url)
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

    #if canImport(iTunesLibrary)
        func resolvedMusicLibraryArtworkDataFromITLibrary(
            for song: MusicLibrarySongEntry
        ) -> Data? {
            func normalizedComparisonText(_ value: String) -> String {
                value
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            }

            let normalizedSongTitle = normalizedComparisonText(song.title)
            let normalizedSongArtist = normalizedComparisonText(song.artist)
            let normalizedSongAlbum = normalizedComparisonText(song.album)
            let cachedIndex = musicLibraryItemIndexBySongID[song.id]

            // While the cover pass runs its library is open, so read just this song's cover.
            if let library = musicLibraryArtworkLibrary, let cachedIndex,
               library.allMediaItems.indices.contains(cachedIndex),
               "\(library.allMediaItems[cachedIndex].persistentID)" == song.id
            {
                if let albumKey = song.artworkAlbumKey {
                    musicLibraryArtworkAttemptsByAlbumKey[albumKey, default: 0] += 1
                }
                return storeMusicLibraryArtwork(from: library.allMediaItems[cachedIndex])
            }
            // The pass already tried this album, and opening the whole library again is slow.
            if let albumKey = song.artworkAlbumKey, musicLibraryArtworkAttemptsByAlbumKey[albumKey] != nil {
                return nil
            }

            func itemMatchesRequestedSong(_ item: ITLibMediaItem) -> Bool {
                if "\(item.persistentID)" == song.id {
                    return true
                }
                guard
                    !normalizedSongTitle.isEmpty,
                    !normalizedSongArtist.isEmpty,
                    !normalizedSongAlbum.isEmpty
                else {
                    return false
                }
                let normalizedItemTitle = normalizedComparisonText(item.title)
                let normalizedItemArtist = normalizedComparisonText(item.artist?.name ?? "")
                let normalizedItemAlbum = normalizedComparisonText(item.album.title ?? "")
                return normalizedItemTitle == normalizedSongTitle &&
                    normalizedItemArtist == normalizedSongArtist &&
                    normalizedItemAlbum == normalizedSongAlbum
            }

            return try? withITLibrary { library in
                if let cachedIndex,
                   library.allMediaItems.indices.contains(cachedIndex)
                {
                    let indexedItem = library.allMediaItems[cachedIndex]
                    if itemMatchesRequestedSong(indexedItem),
                       let artworkData = storeMusicLibraryArtwork(from: indexedItem)
                    {
                        return artworkData
                    }
                }

                if let directLibraryMatch = library.allMediaItems.first(where: itemMatchesRequestedSong),
                   let artworkData = storeMusicLibraryArtwork(from: directLibraryMatch)
                {
                    return artworkData
                }

                for playlist in library.allPlaylists {
                    if let playlistMatch = playlist.items.first(where: itemMatchesRequestedSong),
                       let artworkData = storeMusicLibraryArtwork(from: playlistMatch)
                    {
                        return artworkData
                    }
                }

                return nil
            }
        }
    #endif

    func resolveMusicArtworkImage(
        for song: MusicLibrarySongEntry,
        cacheKey: String,
    ) async -> NSImage? {
        if song.spotify != nil {
            return await loadSpotifyArtwork(for: song, cacheKey: cacheKey)
        }
        if song.jellyfin != nil {
            return await loadJellyfinArtwork(for: song, cacheKey: cacheKey)
        }
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
            #if os(tvOS)
                // Apple TV songs are Apple Music streams. Their artwork only loads after a library
                // request, so look the song up again and use that copy's artwork.
                if let musicKitSong = song.musicKitSong {
                    guard #available(tvOS 16.0, *) else { return nil }
                    var request = MusicLibraryRequest<Song>()
                    request.filter(matching: \.id, equalTo: musicKitSong.id)
                    let current = try? await request.response().items.first
                    return await loadMusicKitArtworkImage((current ?? musicKitSong).artwork)
                }
            #endif
            if let artworkURL = song.url?.standardizedFileURL,
               let generatedArtwork = await generateMusicArtworkThumbnail(for: artworkURL)
            {
                return generatedArtwork
            }
            #if os(iOS)
                // The library's own picture, read off the main thread (it took the main thread a
                // moment for every cover, and more for an 800-pixel PNG to be made and read back).
                let songID = song.id
                return await Task.detached(priority: .userInitiated) { Self.mediaLibraryArtwork(persistentID: songID) }.value
            #else
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
        #endif
    }

    #if os(iOS)
        /// A library song's cover, from anywhere but the main thread. Streamed songs can have
        /// none yet; the caller asks again later.
        nonisolated static func mediaLibraryArtwork(persistentID: String) -> NSImage? {
            guard MPMediaLibrary.authorizationStatus() == .authorized, let id = UInt64(persistentID) else { return nil }
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(
                value: NSNumber(value: id),
                forProperty: MPMediaItemPropertyPersistentID,
                comparisonType: .equalTo,
            ))
            return query.items?.first?.artwork?.image(at: CGSize(width: 800, height: 800))
        }
    #endif

    func currentMusicPreviewSongIndex() -> Int? {
        guard !musicSongsThirdMenuItems.isEmpty else { return nil }
        if shouldShowMusicSongsShuffleActionItem(), selectedThirdIndex == 0 {
            return 0
        }
        return musicSongIndex(forThirdMenuSelectionIndex: selectedThirdIndex)
    }

    /// Prefetches covers around the selection, reaching further ahead while an arrow is held.
    func prefetchMusicPreviewArtworkAroundCurrentSelection() {
        guard isMusicLibraryContext, isInSubmenu else { return }
        guard isInThirdMenu, thirdMenuMode == .musicSongs else { return }
        guard let currentIndex = currentMusicPreviewSongIndex() else { return }
        guard musicSongsThirdMenuItems.indices.contains(currentIndex) else { return }
        let direction: Int = switch activeDirectionalHoldKey {
        case .upArrow: -1
        case .downArrow: 1
        default: 0
        }
        let forward = direction == 0 ? 1 : direction
        let ahead = direction == 0 ? 3 : 12
        // Nearest first: this song, the next one, the previous one, then further ahead.
        var offsets = [0, forward, -forward]
        if ahead > 1 {
            offsets += (2 ... ahead).map { $0 * forward }
        }
        for offset in offsets {
            let index = currentIndex + offset
            guard musicSongsThirdMenuItems.indices.contains(index) else { continue }
            // A few at a time, so a long held scroll doesn't queue hundreds of decodes.
            guard musicArtworkPrefetchInFlightKeys.count < 6 else { return }
            prefetchMusicArtworkIfNeeded(for: musicSongsThirdMenuItems[index])
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
        _ = incrementRequestID(&musicPreviewRequestID)
        musicPreviewRefreshWorkItem?.cancel()
        musicPreviewRefreshWorkItem = nil
        guard let selectedSong else {
            withAnimation(.easeInOut(duration: 0.18)) {
                musicPreviewImage = nil
            }
            musicPreviewDisplayedSong = nil
            return
        }
        // Details and cover follow every step, using covers prefetched around the selection.
        let isScrolling = activeDirectionalHoldKey != .none
        let fadeDuration = isScrolling ? 0.06 : 0.18
        musicPreviewDisplayedSong = selectedSong
        prefetchMusicPreviewArtworkAroundCurrentSelection()
        if let embeddedArtwork = selectedSong.artwork {
            withAnimation(.easeInOut(duration: fadeDuration)) {
                musicPreviewImage = embeddedArtwork
            }
            return
        }
        guard let cacheKey = musicArtworkCacheKey(for: selectedSong) else {
            withAnimation(.easeInOut(duration: fadeDuration)) {
                musicPreviewImage = nil
            }
            return
        }
        if let cached = musicPreviewCache[cacheKey] {
            withAnimation(.easeInOut(duration: fadeDuration)) {
                musicPreviewImage = cached
            }
            return
        }
        // Not decoded yet: keep the current cover up rather than flash the placeholder.
        let targetSongID = selectedSong.id
        Task.detached(priority: .userInitiated) {
            let resolvedArtwork = await self.resolveMusicArtworkImage(
                for: selectedSong,
                cacheKey: cacheKey,
            )
            await MainActor.run {
                if let resolvedArtwork {
                    // Kept even if the selection has moved on, for when it comes back.
                    self.musicPreviewCache[cacheKey] = resolvedArtwork
                }
                guard self.musicPreviewTargetSongID == targetSongID else { return }
                withAnimation(.easeInOut(duration: self.activeDirectionalHoldKey != .none ? 0.06 : 0.22)) {
                    self.musicPreviewImage = resolvedArtwork
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
                    #if canImport(iTunesLibrary)
                        let songCachePage = await self.fetchMusicTopLevelCarouselArtworksFromSongCache(
                            startIndex: resolvedStartIndex,
                            limit: self.musicTopLevelCarouselArtworkLimit,
                        )
                        let pageArtworks: [NSImage?]
                        if let songCachePage {
                            pageArtworks = songCachePage
                        } else {
                            pageArtworks = try await self.fetchMusicTopLevelCarouselArtworks(
                                startIndex: resolvedStartIndex,
                                limit: self.musicTopLevelCarouselArtworkLimit,
                            )
                        }
                    #else
                        let pageArtworks = try await self.fetchMusicTopLevelCarouselArtworks(
                            startIndex: resolvedStartIndex,
                            limit: self.musicTopLevelCarouselArtworkLimit,
                        )
                    #endif
                    await MainActor.run {
                        guard self.musicTopLevelCarouselRequestID == activeRequestID else {
                            // Superseded: drop this request's loading overlay if nothing else is loading.
                            if showsOverlay, self.musicTopLevelCarouselPageStartsInFlight.isEmpty {
                                self.musicTopLevelCarouselLoadOverlayOpacity = 0
                            }
                            return
                        }
                        self.musicTopLevelCarouselPageStartsInFlight.remove(resolvedStartIndex)
                        guard let activeSelectedSubmenuID = self.selectedTopLevelMusicCarouselSubmenuID else {
                            self.musicTopLevelCarouselActiveSubmenuID = nil
                            self.isLoadingMusicTopLevelCarousel = !self.musicTopLevelCarouselPageStartsInFlight.isEmpty
                            self.musicTopLevelCarouselLoadOverlayOpacity = 0
                            return
                        }
                        self.musicTopLevelCarouselActiveSubmenuID = activeSelectedSubmenuID
                        withTransaction(instant) {
                            for (pageOffset, artwork) in pageArtworks.enumerated() {
                                self.musicTopLevelCarouselArtworksByIndex[resolvedStartIndex + pageOffset] = artwork
                            }
                        }
                        self.musicTopLevelCarouselLoadedArtworkCount = max(
                            self.musicTopLevelCarouselLoadedArtworkCount,
                            resolvedStartIndex + pageArtworks.count,
                        )
                        if pageArtworks.count < self.musicTopLevelCarouselArtworkLimit {
                            self.musicTopLevelCarouselResolvedArtworkCount = resolvedStartIndex + pageArtworks.count
                        }
                        self.isLoadingMusicTopLevelCarousel = !self.musicTopLevelCarouselPageStartsInFlight.isEmpty
                        // Covers arrived: clear the overlay even if a superseded request raised it.
                        if self.musicTopLevelCarouselLoadOverlayOpacity > 0, self.musicTopLevelCarouselLoadedArtworkCount > 0 {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                self.musicTopLevelCarouselLoadOverlayOpacity = 0
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard self.musicTopLevelCarouselRequestID == activeRequestID else { return }
                        self.musicTopLevelCarouselPageStartsInFlight.remove(resolvedStartIndex)
                        self.isLoadingMusicTopLevelCarousel = !self.musicTopLevelCarouselPageStartsInFlight.isEmpty
                        if showsOverlay {
                            self.musicTopLevelCarouselLoadOverlayOpacity = 0
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

    func fetchMusicTopLevelCarouselArtworks(startIndex: Int, limit: Int) async throws -> [NSImage?] {
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
            // Album by album rather than song by song, and off the main thread: reading the
            // whole library there held up everything while Music opened.
            let fallback = musicFallbackImage
            return await Task.detached(priority: .userInitiated) { () -> [NSImage?] in
                let albums = MPMediaQuery.albums().collections ?? []
                var artworks: [NSImage?] = []
                artworks.reserveCapacity(resolvedLimit)
                for album in albums.dropFirst(resolvedStartIndex) {
                    guard let item = album.representativeItem else { continue }
                    if item.assetURL == nil, item.mediaType.contains(.anyVideo) { continue }
                    artworks.append(item.artwork?.image(at: CGSize(width: 800, height: 800)) ?? fallback)
                    if artworks.count >= resolvedLimit { break }
                }
                return artworks
            }.value
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
                    let albumKey = musicTopLevelCarouselAlbumKey(for: song)
                    guard seenAlbumKeys.insert(albumKey).inserted else { continue }
                    guard uniqueAlbumIndex >= resolvedStartIndex else {
                        uniqueAlbumIndex += 1
                        continue
                    }
                    artworks.append(await loadMusicKitArtworkImage(song.artwork) ?? musicFallbackImage)
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
            return artworks
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

    #if canImport(iTunesLibrary)
        /// Where one album's carousel cover comes from.
        enum MusicCarouselArtworkSource {
            case libraryData(Data, sourceKey: String)
            case file(URL)
            case image(NSImage)
        }

        /// A carousel page from the startup song cache, one distinct cover per album, or nil if empty.
        func fetchMusicTopLevelCarouselArtworksFromSongCache(startIndex: Int, limit: Int) async -> [NSImage?]? {
            guard (musicShuffleSongsCache ?? musicAllSongsCache) != nil else { return nil }
            await waitForMusicLibraryArtwork(timeout: 8)
            // Still going: show what's there now and rebuild once every cover is in.
            let isArtworkStillLoading = isLoadingMusicLibraryArtwork
            if isArtworkStillLoading {
                musicTopLevelCarouselNeedsReloadAfterArtwork = true
            }
            guard let songs = musicShuffleSongsCache ?? musicAllSongsCache, !songs.isEmpty else { return nil }
            let libraryArtworkData = musicLibraryArtworkDataByAlbumKey
            let resolvedStartIndex = max(0, startIndex)
            let resolvedLimit = max(1, limit)
            var seenAlbums: Set<String> = []
            var seenArtworkDigests: Set<Int> = []
            var albumIndex = 0
            var pageSources: [MusicCarouselArtworkSource] = []
            for song in songs {
                let albumIdentity = song.album == "Unknown Album"
                    ? "song::\(song.id)"
                    : "\(song.album.lowercased())::\(song.artist.lowercased())"
                guard seenAlbums.insert(albumIdentity).inserted else { continue }
                guard let source = await musicTopLevelCarouselArtworkSource(
                    for: song,
                    libraryArtworkData: libraryArtworkData,
                    seenArtworkDigests: &seenArtworkDigests,
                ) else { continue }
                defer { albumIndex += 1 }
                guard albumIndex >= resolvedStartIndex else { continue }
                pageSources.append(source)
                if pageSources.count >= resolvedLimit {
                    break
                }
            }
            if resolvedStartIndex == 0, pageSources.isEmpty {
                return isArtworkStillLoading ? [] : nil
            }
            var artworks: [NSImage?] = []
            artworks.reserveCapacity(pageSources.count)
            for source in pageSources {
                artworks.append(await Self.decodedMusicCarouselArtwork(source))
            }
            return artworks
        }

        nonisolated static func decodedMusicCarouselArtwork(_ source: MusicCarouselArtworkSource) async -> NSImage? {
            switch source {
            case let .libraryData(data, sourceKey):
                await Task.detached(priority: .userInitiated) {
                    cachedDecodedDisplayArtworkImage(from: data, sourceKey: sourceKey, maxPixelSize: 900)
                }.value
            case let .file(url):
                await Task.detached(priority: .userInitiated) {
                    await generateMusicArtworkThumbnailOffMain(for: url)
                }.value
            case let .image(image):
                image
            }
        }

        /// The library's cover, or the song file's own art when another album already shows that picture.
        func musicTopLevelCarouselArtworkSource(
            for song: MusicLibrarySongEntry,
            libraryArtworkData: [String: Data],
            seenArtworkDigests: inout Set<Int>,
        ) async -> MusicCarouselArtworkSource? {
            let digestCache = MusicCarouselArtworkDigestCache.shared
            if let albumKey = song.artworkAlbumKey, let data = libraryArtworkData[albumKey] {
                let digestKey = "library::\(albumKey)"
                let digest = digestCache.digest(for: digestKey) ?? artworkContentDigest(data)
                digestCache.store(digest, for: digestKey)
                if seenArtworkDigests.insert(digest).inserted {
                    return .libraryData(data, sourceKey: "music_carousel::\(albumKey)")
                }
            }
            if let url = song.url?.standardizedFileURL {
                let digestKey = "file::\(url.path)"
                let digest: Int?
                if digestCache.hasEntry(for: digestKey) {
                    digest = digestCache.digest(for: digestKey)
                } else {
                    digest = await loadEmbeddedArtworkData(from: url).map(artworkContentDigest)
                    digestCache.store(digest, for: digestKey)
                }
                if let digest, seenArtworkDigests.insert(digest).inserted {
                    return .file(url)
                }
            }
            return song.artwork.map(MusicCarouselArtworkSource.image)
        }
    #endif

    nonisolated func normalizedMusicTopLevelCarouselAlbumKey(
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
        nonisolated func musicTopLevelCarouselAlbumKey(for item: MPMediaItem) -> String {
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
        transitionMenuForFolderSwap(useOverlayFade: useOverlayFade) {
            self.isInThirdMenu = false
            self.thirdMenuMode = .none
            self.thirdMenuOpacity = 0
            self.submenuOpacity = 1
            self.resetMusicThirdMenuStateForSecondLevelExit()
            self.resetITunesTopCarouselAndPreviewState(
                for: [.songs, .musicVideos],
                resetPlaybackRequestID: true,
            )
            self.headerText = self.rootMenuTitle(for: self.activeRootItemID)
            self.refreshDetailPreviewForCurrentContext()
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
            revealWhen: { !self.isLoadingMusicSongs },
        ) {
            self.prepareMusicLibraryThirdMenu(
                mode: .musicSongs,
                title: title,
                categoryKind: nil,
                categoryTitle: "",
                shuffleMode: shuffleMode,
                libraryMediaType: libraryMediaType,
                showsShuffleAction: showsShuffleAction,
            )
            self.requestMusicLibraryAuthorizationAndLoadSongs()
        }
    }

    /// Shows the Now Playing row held back while the menu faded out.
    func revealDeferredNowPlayingMenuItemIfNeeded() {
        guard deferNowPlayingMenuItemUntilAfterFadeOut else { return }
        deferNowPlayingMenuItemUntilAfterFadeOut = false
    }

    func enterMusicCategoryMenu(title: String, kind: MusicCategoryKind) {
        transitionMenuForFolderSwap(
            useOverlayFade: true,
            revealWhen: { !self.isLoadingMusicSongs },
        ) {
            self.prepareMusicLibraryThirdMenu(
                mode: .musicCategories,
                title: title,
                categoryKind: kind,
                categoryTitle: title,
                shuffleMode: false,
                libraryMediaType: .songs,
                showsShuffleAction: false,
            )
            self.requestMusicLibraryAuthorizationAndLoadCategories(for: kind)
        }
    }

    func enterSongsForSelectedMusicCategory() {
        guard thirdMenuMode == .musicCategories else { return }
        guard musicCategoryThirdMenuItems.indices.contains(selectedThirdIndex) else { return }
        let categoryEntry = musicCategoryThirdMenuItems[selectedThirdIndex]
        let categoryIndex = selectedThirdIndex
        transitionMenuForFolderSwap {
            self.thirdMenuMode = .musicSongs
            self.isMusicSongsCategoryScoped = true
            self.isMusicSongsShuffleMode = false
            self.lastSelectedMusicCategoryIndex = categoryIndex
            self.musicSongsThirdMenuItems = categoryEntry.songs
            self.selectedThirdIndex = 0
            self.activeMusicLibraryMediaType = .songs
            let shouldShowShuffleAction = switch self.activeMusicCategoryKind {
            case .playlists, .artists, .albums, .genres, .composers:
                true
            case nil:
                false
            }
            self.musicSongsShowsShuffleAction = shouldShowShuffleAction
            self.isLoadingMusicSongs = false
            self.musicSongsLoadError = categoryEntry.songs.isEmpty ? "No Songs in Category" : nil
            self.headerText = self.activeMusicCategoryMenuTitle.isEmpty
                ? self.rootMenuTitle(for: self.activeRootItemID)
                : self.activeMusicCategoryMenuTitle
            self.refreshDetailPreviewForCurrentContext()
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
        }
    }

    func fetchMusicLibrarySongs() async throws -> [MusicLibrarySongEntry] {
        try await fetchMusicLibraryEntries(for: .songs, includeArtwork: false)
    }

    func fetchRandomMusicLibrarySongForShuffleSeed(includeArtwork: Bool = true) async throws -> MusicLibrarySongEntry? {
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
            let songs = try await fetchMusicLibrarySongsForShuffle()
            return songs.randomElement()
        #endif
    }

    func fetchMusicLibrarySongsForShuffle() async throws -> [MusicLibrarySongEntry] {
        try await fetchMusicLibraryEntries(
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
            if let harnessMusicFolder = FirstRowHarness.musicFolderOverride {
                return [harnessMusicFolder] + MediaSources.shared.folders(.music)
            }
            var chosenFolders = MediaSources.shared.folders(.music)
            #if FIRSTROW_PORTABLE
                // With no Music app here, the user's own Music folder is the library.
                let ownMusic = portableUserFolder(named: "Music", standardName: "Music", xdgKey: "XDG_MUSIC_DIR")
                var isOwnMusicFolder: ObjCBool = false
                if FileManager.default.fileExists(atPath: ownMusic.path, isDirectory: &isOwnMusicFolder), isOwnMusicFolder.boolValue,
                   !chosenFolders.contains(where: { $0.standardizedFileURL.path == ownMusic.standardizedFileURL.path })
                {
                    chosenFolders.insert(ownMusic, at: 0)
                }
            #endif
            return chosenFolders + externalVolumeRootURLs().compactMap { volumeURL in
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
                (commonMetadata, metadata, duration) = await Task.detached(priority: .utility) {
                    (asset.commonMetadata, asset.metadata, asset.duration)
                }.value
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
        ) {
            typealias LibrarySnapshot = (songs: [MusicLibrarySongEntry], itemIndices: [String: Int], library: ITLibrary?)
            let libraryResult: Result<LibrarySnapshot, Error> = FirstRowHarness.isActive
                ? .success(([], [:], nil))
                : Result { try withITLibrary { library in
                var songs: [MusicLibrarySongEntry] = []
                var itemIndices: [String: Int] = [:]
                for (index, item) in library.allMediaItems.enumerated() {
                    guard musicLibraryMediaKindMatches(item.mediaKind, requested: .songs) else { continue }
                    guard let entry = makeMusicLibrarySongEntry(from: item, includeArtwork: includeArtwork) else { continue }
                    songs.append(entry)
                    itemIndices[entry.id] = index
                }
                return (songs: songs, itemIndices: itemIndices, library: library)
            } }
            let snapshot: LibrarySnapshot = (try? libraryResult.get()) ?? ([], [:], nil)
            var songs = snapshot.songs
            // Covers come afterwards, so they never hold up the songs.
            if let library = snapshot.library {
                startMusicLibraryArtworkPass(library: library)
            }
            // Add folder, drive and iTunes XML songs, even when the Music library can't be read.
            var knownPaths = Set(songs.compactMap { $0.url?.standardizedFileURL.path })
            for entry in await fetchExternalMusicSongEntries() where entry.url.map({ knownPaths.insert($0.standardizedFileURL.path).inserted }) ?? true {
                songs.append(entry)
            }
            let xmlEntries = await Task.detached(priority: .userInitiated) { self.iTunesXMLSongEntries() }.value
            for entry in xmlEntries where entry.url.map({ knownPaths.insert($0.standardizedFileURL.path).inserted }) ?? true {
                songs.append(entry)
            }
            // Library unreadable and no other songs: throw rather than cache an empty library.
            if case let .failure(error) = libraryResult, songs.isEmpty {
                throw error
            }
            return (
                songs: shouldSort ? sortedMusicLibraryEntries(songs) : songs,
                itemIndices: snapshot.itemIndices,
            )
        }

        /// Reads one cover per album after the songs are in. Each cover is its own request to the
        /// library service, and an Apple Music library's covers took most of a minute that way.
        func startMusicLibraryArtworkPass(library: ITLibrary) {
            let requestID = incrementRequestID(&musicLibraryArtworkPassRequestID)
            musicLibraryArtworkLibrary = library
            isLoadingMusicLibraryArtwork = true
            Task {
                let startDate = Date()
                var albumCount = 0
                for (index, item) in library.allMediaItems.enumerated() {
                    if index % 500 == 499 {
                        try? await Task.sleep(nanoseconds: 8_000_000)
                    }
                    guard self.musicLibraryArtworkPassRequestID == requestID else { return }
                    guard self.musicLibraryMediaKindMatches(item.mediaKind, requested: .songs),
                          self.isMusicLibraryItemAuthorizedForPlayback(item) else { continue }
                    let albumKey = self.musicTopLevelCarouselAlbumKey(for: item)
                    guard self.musicLibraryArtworkDataByAlbumKey[albumKey] == nil else { continue }
                    // Each album's first song, then a couple more that say they have a cover.
                    let attempts = self.musicLibraryArtworkAttemptsByAlbumKey[albumKey, default: 0]
                    guard attempts == 0 || (attempts < 3 && item.hasArtworkAvailable) else { continue }
                    self.musicLibraryArtworkAttemptsByAlbumKey[albumKey] = attempts + 1
                    let readStartDate = Date()
                    if self.storeMusicLibraryArtwork(from: item) != nil {
                        albumCount += 1
                    }
                    // Reads block the main thread, so give it back for a while after each one.
                    let readSeconds = Date().timeIntervalSince(readStartDate)
                    try? await Task.sleep(nanoseconds: UInt64(max(0.008, readSeconds / 2) * 1_000_000_000))
                }
                guard self.musicLibraryArtworkPassRequestID == requestID else { return }
                print("[Music] read \(albumCount) album covers in \(String(format: "%.1f", Date().timeIntervalSince(startDate))) s")
                self.musicLibraryArtworkLibrary = nil
                self.isLoadingMusicLibraryArtwork = false
                if self.musicTopLevelCarouselNeedsReloadAfterArtwork {
                    self.musicTopLevelCarouselNeedsReloadAfterArtwork = false
                    self.reloadMusicTopLevelCarousel()
                }
            }
        }

        /// Keeps an item's cover under each of its album's keys.
        @discardableResult
        func storeMusicLibraryArtwork(from item: ITLibMediaItem) -> Data? {
            guard let artworkData = item.artwork?.imageData as Data? else { return nil }
            let newKeys = musicTopLevelCarouselAlbumKeyAliases(for: item)
                .filter { musicLibraryArtworkDataByAlbumKey[$0] == nil }
            musicLibraryArtworkDataByAlbumKey.merge(newKeys.map { ($0, artworkData) }) { current, _ in current }
            return artworkData
        }

        /// Waits for the cover pass, but no longer than `timeout` seconds.
        func waitForMusicLibraryArtwork(timeout: TimeInterval) async {
            let deadline = Date().addingTimeInterval(timeout)
            while isLoadingMusicLibraryArtwork, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        func fetchMusicLibrarySongsForShuffleWithItemIndices() async throws -> (
            songs: [MusicLibrarySongEntry],
            itemIndices: [String: Int],
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
    ) async throws -> [MusicLibrarySongEntry] {
        #if os(iOS)
            guard MPMediaLibrary.authorizationStatus() == .authorized else {
                throw NSError(
                    domain: "firstRowMusicLibrary",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Music library access not authorized"],
                )
            }
            // A big library takes seconds to read and turn into entries: well away from the main
            // thread, which would otherwise ignore every touch meanwhile (at launch, say).
            return await Task.detached(priority: .userInitiated) { () -> [MusicLibrarySongEntry] in
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
                let entries = mediaItems.compactMap { self.makeMusicLibrarySongEntry(from: $0, includeArtwork: includeArtwork) }
                return shouldSort ? self.sortedMusicLibraryEntries(entries) : entries
            }.value
        #elseif os(tvOS)
            switch mediaType {
            case .songs:
                return try await fetchMusicLibrarySongsFromMusicKit(
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
                let songs = sortedMusicLibraryEntries(collection.items.compactMap { makeMusicLibrarySongEntry(from: $0, includeArtwork: false) })
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
            let libraryPlaylists = (try? withITLibrary { library in
                library.allPlaylists.compactMap { playlist -> MusicCategoryEntry? in
                    guard playlist.isVisible else { return nil }
                    guard playlist.kind != .folder else { return nil }
                    guard !playlist.isMaster else { return nil }
                    if #available(macOS 12.0, *) {
                        guard !playlist.isPrimary else { return nil }
                    }
                    let title = normalizedMusicLibraryText(playlist.name, fallback: "Untitled Playlist")
                    let playlistPersistentIDHex = musicPersistentIDHexString(for: playlist.persistentID)
                    let songs = sortedMusicLibraryEntries(
                        playlist.items.compactMap { item -> MusicLibrarySongEntry? in
                            guard musicLibraryMediaKindMatches(item.mediaKind, requested: .songs) else { return nil }
                            return makeMusicLibrarySongEntry(
                                from: item,
                                sourcePlaylistPersistentIDHex: playlistPersistentIDHex,
                            )
                        },
                    )
                    guard !songs.isEmpty else { return nil }
                    return MusicCategoryEntry(
                        id: "playlist::mac::\(playlist.persistentID)",
                        title: title,
                        songs: songs,
                    )
                }
            }) ?? []
            return (libraryPlaylists + iTunesXMLPlaylistEntries()).sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        #else
            return []
        #endif
    }

    #if canImport(iTunesLibrary)
        nonisolated func iTunesXMLSongEntry(_ track: ITunesLibraryXML.Track) -> MusicLibrarySongEntry {
            MusicLibrarySongEntry(
                id: "xml::\(track.persistentID)",
                title: track.title,
                artist: track.artist,
                album: track.album,
                genre: track.genre,
                composer: track.composer,
                durationSeconds: track.durationSeconds,
                trackNumber: track.trackNumber,
                discNumber: track.discNumber,
                artworkAlbumKey: nil,
                url: track.url,
                artwork: nil,
            )
        }

        nonisolated func iTunesXMLSongEntries() -> [MusicLibrarySongEntry] {
            ITunesLibraryXML.shared.contents()?.tracks.map(iTunesXMLSongEntry) ?? []
        }

        nonisolated func iTunesXMLPlaylistEntries() -> [MusicCategoryEntry] {
            guard let contents = ITunesLibraryXML.shared.contents() else { return [] }
            return contents.playlists.map { playlist in
                MusicCategoryEntry(
                    id: "playlist::xml::\(playlist.persistentID)",
                    title: playlist.name,
                    songs: playlist.trackIDs.compactMap { contents.tracksByID[$0] }.map(iTunesXMLSongEntry),
                )
            }
        }
    #endif

    nonisolated func normalizedMusicLibraryText(_ rawValue: String?, fallback: String) -> String {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    nonisolated func sortedMusicLibraryEntries(_ entries: [MusicLibrarySongEntry]) -> [MusicLibrarySongEntry] {
        entries.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    #if os(iOS)
        nonisolated func makeMusicLibrarySongEntry(from item: MPMediaItem, includeArtwork: Bool = true) -> MusicLibrarySongEntry? {
            // Apple Music and cloud songs have no file and play through the system player, which can't show video.
            let locationURL = item.assetURL
            if locationURL == nil, item.mediaType.contains(.anyVideo) { return nil }
            let title = normalizedMusicLibraryText(
                item.title,
                fallback: locationURL?.deletingPathExtension().lastPathComponent ?? "Unknown Song",
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
                trackNumber: item.albumTrackNumber,
                discNumber: item.discNumber,
                artworkAlbumKey: musicTopLevelCarouselAlbumKey(for: item),
                url: locationURL,
                artwork: includeArtwork ? item.artwork?.image(at: CGSize(width: 800, height: 800)) : nil,
                prefersSystemMusicPlayerPlayback: locationURL == nil,
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
                guard isAppleMusicCatalogLibraryItem(item) else { return true }
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
            if FirstRowHarness.isActive {
                throw NSError(domain: "firstRowHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Libraries are off in the harness"])
            }
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
        makeMusicLibrarySongEntry(
            from: item,
            includeArtwork: includeArtwork,
            sourcePlaylistPersistentIDHex: nil,
            )
        }

        func makeMusicLibrarySongEntry(
            from item: ITLibMediaItem,
            includeArtwork: Bool = true,
            sourcePlaylistPersistentIDHex: String?,
        ) -> MusicLibrarySongEntry? {
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
                prefersSystemMusicPlayerPlayback: isAppleMusicCatalogLibraryItem(item) || item.isDRMProtected,
                sourcePlaylistPersistentIDHex: sourcePlaylistPersistentIDHex,
            )
        }
    #endif
    #if os(tvOS)
        func fetchMusicLibrarySongsFromMusicKit(
            includeArtwork: Bool = true,
            shouldSort: Bool = true,
        ) async throws -> [MusicLibrarySongEntry] {
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
            var request = MusicLibraryRequest<Song>()
            request.limit = 5000
            let response = try await request.response()
            var songs: [MusicLibrarySongEntry] = []
            songs.reserveCapacity(response.items.count)
            for song in response.items {
                guard let entry = await makeMusicLibrarySongEntry(from: song, includeArtwork: includeArtwork) else {
                    continue
                }
                songs.append(entry)
            }
            return shouldSort ? sortedMusicLibraryEntries(songs) : songs
        }

        func makeMusicLibrarySongEntry(from song: Song, includeArtwork: Bool = true) async -> MusicLibrarySongEntry? {
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
                trackNumber: song.trackNumber ?? 0,
                discNumber: song.discNumber ?? 1,
                artworkAlbumKey: musicTopLevelCarouselAlbumKey(for: song),
                url: playbackURL,
                artwork: includeArtwork ? await loadMusicKitArtworkImage(song.artwork) : nil,
                musicKitSong: song,
            )
        }

        func loadMusicKitArtworkImage(_ artwork: Artwork?) async -> NSImage? {
            guard let artwork else { return nil }
            let side = max(300, min(800, min(artwork.maximumWidth, artwork.maximumHeight)))
            guard let artworkURL = artwork.url(width: side, height: side) else { return nil }
            // Read off the main thread: the artwork can be a download.
            guard let data = await Task.detached(operation: { try? Data(contentsOf: artworkURL) }).value else { return nil }
            return cachedDecodedDisplayArtworkImage(
                from: data,
                sourceKey: artworkURL.absoluteString,
                maxPixelSize: CGFloat(side),
            )
        }
    #endif

    func requestMusicLibraryAuthorization(completion: @escaping (Bool) -> Void) {
        if FirstRowHarness.isActive {
            completion(FirstRowHarness.musicFolderOverride != nil)
            return
        }
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
            // The launch load is still reading the whole library: wait for it rather than read
            // it all again alongside.
            if requestedMediaType == .songs, self.hasStartedStartupMusicLibraryPreload, !self.isStartupMusicLibraryPreloadComplete {
                Task { @MainActor in
                    while !self.isStartupMusicLibraryPreloadComplete {
                        try? await firstRowSleep(0.1)
                        guard self.musicSongsRequestID == requestID else { return }
                    }
                    guard self.musicSongsRequestID == requestID, self.thirdMenuMode == .musicSongs else { return }
                    self.requestMusicLibraryAuthorizationAndLoadSongs()
                }
                return
            }
            Task(priority: .userInitiated) {
                do {
                    #if canImport(iTunesLibrary)
                        let songs: [MusicLibrarySongEntry]
                        let itemIndices: [String: Int]
                        if requestedMediaType == .songs {
                            let result = try await self.fetchMusicLibrarySongsWithItemIndices(includeArtwork: false)
                            songs = result.songs
                            itemIndices = result.itemIndices
                        } else {
                            songs = try await self.fetchMusicLibraryEntries(for: requestedMediaType)
                            itemIndices = [:]
                        }
                    #else
                        let songs = try await self.fetchMusicLibraryEntries(for: requestedMediaType)
                    #endif
                    await MainActor.run {
                        guard self.musicSongsRequestID == requestID else { return }
                        guard self.thirdMenuMode == .musicSongs else { return }
                        guard !self.isMusicSongsCategoryScoped else { return }
                        guard self.activeMusicLibraryMediaType == requestedMediaType else { return }
                        self.isLoadingMusicSongs = false
                        if requestedMediaType == .songs {
                            #if canImport(iTunesLibrary)
                                self.musicLibraryItemIndexBySongID = itemIndices
                            #endif
                            self.musicAllSongsCache = songs
                        }
                        self.musicSongsThirdMenuItems = songs
                        let additionalShuffleRow = (self.musicSongsShowsShuffleAction && !songs.isEmpty) ? 1 : 0
                        let maxSelectionIndex = max(0, (songs.count + additionalShuffleRow) - 1)
                        self.selectedThirdIndex = min(self.selectedThirdIndex, maxSelectionIndex)
                        self.musicSongsLoadError = nil
                        self.refreshMusicPreviewForCurrentContext()
                        if songs.isEmpty {
                            self.presentMusicLibraryEmptyError(for: requestedMediaType)
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard self.musicSongsRequestID == requestID else { return }
                        guard self.thirdMenuMode == .musicSongs else { return }
                        guard !self.isMusicSongsCategoryScoped else { return }
                        guard self.activeMusicLibraryMediaType == requestedMediaType else { return }
                        self.isLoadingMusicSongs = false
                        self.musicSongsThirdMenuItems = []
                        self.selectedThirdIndex = 0
                        self.musicSongsLoadError = self.musicLibraryErrorMessage(for: error)
                        self.refreshMusicPreviewForCurrentContext()
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
            Task(priority: .userInitiated) {
                do {
                    let categories: [MusicCategoryEntry]
                    if kind == .playlists {
                        categories = try self.fetchMusicLibraryPlaylists()
                    } else {
                        let songs: [MusicLibrarySongEntry]
                        #if canImport(iTunesLibrary)
                            // The songs read at launch, as the Songs list uses; reading the whole
                            // library again took as long as launch did.
                            var freshItemIndices: [String: Int]?
                            if let cachedSongs = self.musicAllSongsCache {
                                songs = cachedSongs
                            } else {
                                let result = try await self.fetchMusicLibrarySongsWithItemIndices(includeArtwork: false)
                                songs = result.songs
                                freshItemIndices = result.itemIndices
                            }
                        #else
                            let cachedSongs = self.musicAllSongsCache
                            if let cachedSongs {
                                songs = cachedSongs
                            } else {
                                songs = try await self.fetchMusicLibrarySongs()
                            }
                        #endif
                        categories = self.buildMusicCategoryEntries(from: songs, kind: kind)
                        await MainActor.run {
                            self.musicAllSongsCache = songs
                            #if canImport(iTunesLibrary)
                                if let freshItemIndices {
                                    self.musicLibraryItemIndexBySongID = freshItemIndices
                                }
                            #endif
                        }
                    }
                    await MainActor.run {
                        guard self.musicSongsRequestID == requestID else { return }
                        guard self.thirdMenuMode == .musicCategories else { return }
                        guard self.activeMusicCategoryKind == kind else { return }
                        self.isLoadingMusicSongs = false
                        self.musicCategoryThirdMenuItems = categories
                        self.selectedThirdIndex = min(self.selectedThirdIndex, max(0, categories.count - 1))
                        self.musicSongsLoadError = nil
                        self.refreshMusicPreviewForCurrentContext()
                        if categories.isEmpty {
                            self.presentMusicCategoryEmptyError(for: kind)
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard self.musicSongsRequestID == requestID else { return }
                        guard self.thirdMenuMode == .musicCategories else { return }
                        guard self.activeMusicCategoryKind == kind else { return }
                        self.isLoadingMusicSongs = false
                        self.musicCategoryThirdMenuItems = []
                        self.selectedThirdIndex = 0
                        self.musicSongsLoadError = self.musicLibraryErrorMessage(for: error)
                        self.refreshMusicPreviewForCurrentContext()
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
                        guard let seedSong = try await self.fetchRandomMusicLibrarySongForShuffleSeed() else {
                            await MainActor.run {
                                guard self.musicSongsRequestID == requestID else { return }
                                self.deferNowPlayingMenuItemUntilAfterFadeOut = false
                                self.isLoadingMusicSongs = false
                                self.musicSongsThirdMenuItems = []
                                self.selectedThirdIndex = 0
                                self.musicSongsLoadError = "No Songs in Music Library"
                            }
                            return
                        }
                        await MainActor.run {
                            guard self.musicSongsRequestID == requestID else { return }
                            self.applyResolvedRootMusicShufflePlayback(
                                with: [seedSong],
                                usingExistingBlackout: usingExistingBlackout,
                            )
                        }
                        let result = try await self.fetchMusicLibrarySongsForShuffleWithItemIndices()
                        await MainActor.run {
                            guard self.musicSongsRequestID == requestID else { return }
                            self.musicLibraryItemIndexBySongID = result.itemIndices
                            self.musicShuffleSongsCache = result.songs
                            guard self.activeMusicPlaybackSongID == seedSong.id else { return }
                            let shuffleRequestID = self.incrementRequestID(&self.musicShuffleRequestID)
                            self.requestSeededShuffleQueue(
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
                            guard self.musicSongsRequestID == requestID else { return }
                            self.deferNowPlayingMenuItemUntilAfterFadeOut = false
                            self.isLoadingMusicSongs = false
                            self.musicSongsThirdMenuItems = []
                            self.selectedThirdIndex = 0
                            self.musicSongsLoadError = self.musicLibraryErrorMessage(for: error)
                        }
                    }
                }
                return
            #else
                Task(priority: .userInitiated) {
                    do {
                        let songs = try await self.fetchMusicLibrarySongsForShuffle()
                        await MainActor.run {
                            guard self.musicSongsRequestID == requestID else { return }
                            self.musicShuffleSongsCache = songs
                            self.applyRootMusicShufflePlayback(
                                with: songs,
                                usingExistingBlackout: usingExistingBlackout,
                            )
                        }
                    } catch {
                        await MainActor.run {
                            guard self.musicSongsRequestID == requestID else { return }
                            self.deferNowPlayingMenuItemUntilAfterFadeOut = false
                            self.isLoadingMusicSongs = false
                            self.musicSongsThirdMenuItems = []
                            self.selectedThirdIndex = 0
                            self.musicSongsLoadError = self.musicLibraryErrorMessage(for: error)
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
        // A new Now Playing row waits for the fade-out, but an existing one stays so rows don't shift.
        if !shouldExposeMusicNowPlayingMenuItem {
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
        let trackNumber: Int
        let discNumber: Int
        let artworkAlbumKey: String?
        let url: URL?
        let artwork: NSImage?
        let prefersSystemMusicPlayerPlayback: Bool
        let sourcePlaylistPersistentIDHex: String?
        /// Set for songs that play through Spotify.
        let spotify: SpotifyTrackReference?
        /// Set for songs that stream from a Jellyfin server.
        let jellyfin: JellyfinTrackReference?
        #if os(tvOS)
            let musicKitSong: Song?
        #endif

        #if os(tvOS)
            init(
                id: String,
                title: String,
                artist: String,
                album: String,
                genre: String,
                composer: String,
                durationSeconds: Double,
                trackNumber: Int,
                discNumber: Int,
                artworkAlbumKey: String?,
                url: URL?,
                artwork: NSImage?,
                prefersSystemMusicPlayerPlayback: Bool = false,
                sourcePlaylistPersistentIDHex: String? = nil,
                spotify: SpotifyTrackReference? = nil,
                jellyfin: JellyfinTrackReference? = nil,
                musicKitSong: Song? = nil,
            ) {
                self.id = id
                self.title = title
                self.artist = artist
                self.album = album
                self.genre = genre
                self.composer = composer
                self.durationSeconds = durationSeconds
                self.trackNumber = trackNumber
                self.discNumber = discNumber
                self.artworkAlbumKey = artworkAlbumKey
                self.url = url
                self.artwork = artwork
                self.prefersSystemMusicPlayerPlayback = prefersSystemMusicPlayerPlayback
                self.sourcePlaylistPersistentIDHex = sourcePlaylistPersistentIDHex
                self.spotify = spotify
                self.jellyfin = jellyfin
                self.musicKitSong = musicKitSong
            }
        #else
            init(
                id: String,
                title: String,
                artist: String,
                album: String,
                genre: String,
                composer: String,
                durationSeconds: Double,
                trackNumber: Int,
                discNumber: Int,
                artworkAlbumKey: String?,
                url: URL?,
                artwork: NSImage?,
                prefersSystemMusicPlayerPlayback: Bool = false,
                sourcePlaylistPersistentIDHex: String? = nil,
                spotify: SpotifyTrackReference? = nil,
                jellyfin: JellyfinTrackReference? = nil,
            ) {
                self.id = id
                self.title = title
                self.artist = artist
                self.album = album
                self.genre = genre
                self.composer = composer
                self.durationSeconds = durationSeconds
                self.trackNumber = trackNumber
                self.discNumber = discNumber
                self.artworkAlbumKey = artworkAlbumKey
                self.url = url
                self.artwork = artwork
                self.prefersSystemMusicPlayerPlayback = prefersSystemMusicPlayerPlayback
                self.sourcePlaylistPersistentIDHex = sourcePlaylistPersistentIDHex
                self.spotify = spotify
                self.jellyfin = jellyfin
            }
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
        ModernTheme.isActive ? ModernTheme.placeholderArtwork(symbol: "music.note") : NSImage(named: "musicfallback")
    }
}

/// Remembers artwork fingerprints so carousel pages after the first don't re-read every file.
final class MusicCarouselArtworkDigestCache {
    static let shared = MusicCarouselArtworkDigestCache()
    private let lock = NSLock()
    private var digests: [String: Int?] = [:]

    func hasEntry(for key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return digests[key] != nil
    }

    func digest(for key: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return digests[key] ?? nil
    }

    func store(_ digest: Int?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        digests[key] = .some(digest)
    }
}

/// Artwork cache key. iPhone library songs all have the path "/item.m4a", so they use the full URL.
func musicArtworkCacheKeyForFile(_ url: URL) -> String {
    url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
}

/// Artwork embedded in a song file, decoded for display; safe to call off the main thread.
func generateMusicArtworkThumbnailOffMain(for url: URL) async -> NSImage? {
    let standardizedURL = url.standardizedFileURL
    let cacheKey = musicArtworkCacheKeyForFile(standardizedURL)
    if let cached = cachedDecodedDisplayArtworkImage(sourceKey: cacheKey, maxPixelSize: 900) {
        return cached
    }
    guard let data = await loadEmbeddedArtworkData(from: standardizedURL) else { return nil }
    return cachedDecodedDisplayArtworkImage(from: data, sourceKey: cacheKey, maxPixelSize: 900)
}
