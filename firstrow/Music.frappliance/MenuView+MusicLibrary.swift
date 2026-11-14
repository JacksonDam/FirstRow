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
#if os(iOS) || os(tvOS)
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
        watchMusicLibraryForChanges()
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
                        #if os(macOS)
                            self.putRecoveredSongBackInItsList()
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
    /// Only what the kinds that changed hold is read again: a folder of movies is no reason
    /// to read the music library and the photo albums a second time.
    func reloadMediaAfterSourcesChange(folders: Set<MediaSources.FolderKind>, libraries: Set<MediaSources.LibraryKind>) {
        if folders.contains(.photos) || libraries.contains(.iPhoto) {
            requestPhotoSourceAlbumsLoad()
        }
        if folders.contains(.movies) {
            noteMoviesTopLevelChanged()
            if activeRootItemID == "tv_shows", isInSubmenu { refreshTVShows() }
        }
        guard folders.contains(.music) || libraries.contains(.iTunesXML) else { return }
        guard isStartupMusicLibraryPreloadComplete else { return }
        let requestID = incrementRequestID(&musicStartupPreloadRequestID)
        Task(priority: .userInitiated) {
            #if canImport(iTunesLibrary)
                // The Music app's own songs are as they were: only the songs in folders and in
                // the library file are read again. (Reading the app's again would have its
                // covers read again too, which takes most of a minute with a large library.)
                if let songs = await self.musicSongsWithFoldersReadAgain() {
                    guard self.musicStartupPreloadRequestID == requestID else { return }
                    self.musicAllSongsCache = songs.sortedSongs
                    self.musicShuffleSongsCache = songs.shuffleSongs
                    self.reloadMusicTopLevelCarousel()
                    return
                }
            #endif
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

    #if canImport(iTunesLibrary)
        /// The songs as they are known, with those from folders and from an iTunes library
        /// file read again. Nil before the library has been read at all.
        func musicSongsWithFoldersReadAgain() async -> (sortedSongs: [MusicLibrarySongEntry], shuffleSongs: [MusicLibrarySongEntry])? {
            guard let known = musicShuffleSongsCache else { return nil }
            let fromMusicApp = musicLibraryItemIndexBySongID
            var songs = known.filter { fromMusicApp[$0.id] != nil }
            var knownPaths = Set(songs.compactMap { $0.url?.standardizedFileURL.path })
            for entry in await fetchExternalMusicSongEntries() where entry.url.map({ knownPaths.insert($0.standardizedFileURL.path).inserted }) ?? true {
                songs.append(entry)
            }
            let xmlEntries = await Task.detached(priority: .userInitiated) { self.iTunesXMLSongEntries() }.value
            for entry in xmlEntries where entry.url.map({ knownPaths.insert($0.standardizedFileURL.path).inserted }) ?? true {
                songs.append(entry)
            }
            return (sortedSongs: sortedMusicLibraryEntries(songs), shuffleSongs: songs)
        }
    #endif

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
        musicArtistsReturn = nil
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
        musicArtistsReturn = nil
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

    var isShowingMusicArtistsList: Bool {
        thirdMenuMode == .musicCategories && activeMusicCategoryKind == .artists
    }

    var isShowingMusicPlaylistsList: Bool {
        thirdMenuMode == .musicCategories && activeMusicCategoryKind == .playlists
    }

    /// Genres and composers: their rows' picture is made of their albums' covers, as a
    /// playlist's is.
    var isShowingMusicGenresOrComposersList: Bool {
        thirdMenuMode == .musicCategories && (activeMusicCategoryKind == .genres || activeMusicCategoryKind == .composers)
    }

    /// Every list of the library's categories shows a cover beside its rows.
    var isShowingMusicCategoryCovers: Bool {
        isShowingMusicAlbumsList || isShowingMusicArtistsList || isShowingMusicPlaylistsList || isShowingMusicGenresOrComposersList
    }

    func resolveMusicPreviewTargetSong() -> MusicLibrarySongEntry? {
        guard isMusicLibraryContext, isInSubmenu, isInThirdMenu else { return nil }
        if thirdMenuMode == .spotify {
            return spotifyCollectionPreviewEntry() ?? spotifyRowCoverStandIn()
        }
        if isShowingMusicAlbumsList {
            guard musicCategoryThirdMenuItems.indices.contains(selectedThirdIndex) else { return nil }
            let album = musicCategoryThirdMenuItems[selectedThirdIndex]
            if album.id.hasPrefix(Self.musicArtistAllSongsIDPrefix) {
                return musicPlaylistCoverStandIn(for: album)
            }
            return album.songs.first { $0.artwork != nil || $0.artworkAlbumKey != nil || $0.url != nil } ?? album.songs.first
        }
        if isShowingMusicArtistsList {
            guard musicCategoryThirdMenuItems.indices.contains(selectedThirdIndex) else { return nil }
            return musicArtistCoverSong(for: musicCategoryThirdMenuItems[selectedThirdIndex])
        }
        if isShowingMusicPlaylistsList || isShowingMusicGenresOrComposersList {
            guard musicCategoryThirdMenuItems.indices.contains(selectedThirdIndex) else { return nil }
            return musicPlaylistCoverStandIn(for: musicCategoryThirdMenuItems[selectedThirdIndex])
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

    /// An artist's picture is the cover of their first album in the library (by name, as the
    /// Albums list has them), from its first song that has one. "All" has none.
    func musicArtistCoverSong(for artist: MusicCategoryEntry) -> MusicLibrarySongEntry? {
        guard artist.id != "\(MusicCategoryKind.artists.rawValue)::all" else { return nil }
        return artist.songs
            .filter { $0.artwork != nil || $0.artworkAlbumKey != nil || $0.url != nil }
            .min { lhs, rhs in
                let albums = lhs.album.localizedCaseInsensitiveCompare(rhs.album)
                if albums != .orderedSame { return albums == .orderedAscending }
                if lhs.discNumber != rhs.discNumber { return lhs.discNumber < rhs.discNumber }
                return lhs.trackNumber < rhs.trackNumber
            }
    }

    static let musicPlaylistCoverIDPrefix = "playlist-cover|"

    /// A playlist's cover is asked for the way a song's is, through this stand-in for it (as a
    /// Spotify list's is).
    func musicPlaylistCoverStandIn(for playlist: MusicCategoryEntry) -> MusicLibrarySongEntry {
        let id = Self.musicPlaylistCoverIDPrefix + playlist.id
        return MusicLibrarySongEntry(
            id: id, title: playlist.title, artist: "", album: "", genre: "", composer: "", durationSeconds: 0,
            trackNumber: 0, discNumber: 0, artworkAlbumKey: id, url: nil, artwork: nil,
        )
    }

    /// How many albums a playlist, a genre and the rest offer for their picture: more than
    /// the four it takes, as some have no cover.
    nonisolated static let musicCoverCandidateCount = 8

    /// A playlist's first songs from different albums, in its own order: the covers of the
    /// first four that have one make its cover when it has none of its own.
    nonisolated func musicPlaylistCoverSongs(from songsInOrder: [MusicLibrarySongEntry]) -> [MusicLibrarySongEntry] {
        let count = Self.musicCoverCandidateCount
        var albumsSeen: Set<String> = []
        var coverSongs: [MusicLibrarySongEntry] = []
        for song in songsInOrder {
            guard albumsSeen.insert(song.artworkAlbumKey ?? "\(song.listedArtist)|\(song.album)").inserted else { continue }
            coverSongs.append(song)
            if coverSongs.count == count { break }
        }
        return coverSongs
    }

    /// A playlist's cover as Apple Music makes one: the covers of its first four albums together,
    /// or the first alone when there are fewer. Its own cover (one it was given, or the one a
    /// playlist of Apple's comes with) takes this one's place a moment later, where there is one
    /// and it can be asked for.
    func resolveMusicPlaylistCover(standIn: MusicLibrarySongEntry, cacheKey: String) async -> NSImage? {
        let playlistID = String(standIn.id.dropFirst(Self.musicPlaylistCoverIDPrefix.count))
        guard let playlist = musicCategoryThirdMenuItems.first(where: { $0.id == playlistID }) else { return nil }
        let covers = await musicCovers(of: playlist.coverSongs)
        followWithMusicPlaylistOwnCover(for: playlist, standInID: standIn.id, cacheKey: cacheKey)
        return await Task.detached(priority: .userInitiated) { Self.musicPlaylistMosaic(of: covers) }.value
    }

    /// Four covers as one, two by two; fewer than four, the first as it is.
    nonisolated static func musicPlaylistMosaic(of covers: [CGImage]) -> NSImage? {
        picturesAsOne(covers, width: 800, height: 800)
    }

    /// Four pictures as one of this size, two by two; fewer than four, the first as it is.
    nonisolated static func picturesAsOne(_ pictures: [CGImage], width: Int, height: Int) -> NSImage? {
        guard let first = pictures.first else { return nil }
        let whole = NSImage(cgImage: first, size: NSSize(width: first.width, height: first.height))
        guard pictures.count >= 4 else { return whole }
        let halfWidth = width / 2
        let halfHeight = height / 2
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ScreenColorSpace.current ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: layerBitmapInfo,
        ) else { return whole }
        context.interpolationQuality = .high
        for (index, picture) in pictures.prefix(4).enumerated() {
            // The first is at the top left. Each fills its quarter, cut about its middle.
            let quarter = CGRect(x: (index % 2) * halfWidth, y: (1 - index / 2) * halfHeight, width: halfWidth, height: halfHeight)
            let scale = max(CGFloat(halfWidth) / CGFloat(max(1, picture.width)), CGFloat(halfHeight) / CGFloat(max(1, picture.height)))
            let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
            context.saveGState()
            context.clip(to: quarter)
            context.draw(picture, in: CGRect(x: quarter.midX - size.width / 2, y: quarter.midY - size.height / 2, width: size.width, height: size.height))
            context.restoreGState()
        }
        guard let made = context.makeImage() else { return whole }
        return NSImage(cgImage: made, size: NSSize(width: width, height: height))
    }

    // MARK: - Rows of Music that show what they hold

    /// The picture beside one of Music's rows, and the row it is of.
    struct MusicRowCover {
        let rowID: String
        let image: NSImage
    }

    /// Music Videos, Playlists or Audiobooks, when it is the row chosen in Music: its
    /// picture is made of what it holds (the first four together, or the first alone).
    var selectedMusicRowWithCover: String? {
        guard let row = selectedMusicSubmenuItemID, ["music_music_videos", "music_playlists", "music_audiobooks"].contains(row) else { return nil }
        return row
    }

    /// The chosen row's picture, once it is made. (Until then, and for a row with nothing
    /// to show, Music's own picture stays.)
    var shownMusicRowCover: NSImage? {
        guard let row = selectedMusicRowWithCover, let cover = musicRowCover, cover.rowID == row else { return nil }
        return cover.image
    }

    func refreshMusicRowCoverForCurrentContext() {
        guard let row = selectedMusicRowWithCover, musicRowCover?.rowID != row else { return }
        if let known = musicRowCovers[row] {
            // (Made before. A row that had nothing to show is asked again when the library changes.)
            guard let known else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                musicRowCover = MusicRowCover(rowID: row, image: known)
            }
            return
        }
        guard musicRowCoversBeingMade.insert(row).inserted else { return }
        requestMusicLibraryAuthorization { isAuthorized in
            guard isAuthorized else {
                self.musicRowCoversBeingMade.remove(row)
                return
            }
            Task { @MainActor in
                // (Only for a row that is stayed on: one passed on the way to another isn't
                // worth reading the library for.)
                try? await firstRowSleep(0.25)
                guard self.selectedMusicRowWithCover == row else {
                    self.musicRowCoversBeingMade.remove(row)
                    return
                }
                let made = await self.makeMusicRowCover(forRow: row)
                self.musicRowCoversBeingMade.remove(row)
                self.musicRowCovers.updateValue(made, forKey: row)
                guard let made, self.selectedMusicRowWithCover == row else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    self.musicRowCover = MusicRowCover(rowID: row, image: made)
                }
            }
        }
    }

    /// The library has changed: the rows' pictures are made again as each is next chosen
    /// (the one showing, now).
    func remakeMusicRowCovers() {
        musicRowCovers.removeAll()
        guard let shown = musicRowCover else { return }
        guard selectedMusicRowWithCover == shown.rowID else {
            musicRowCover = nil
            return
        }
        guard !musicRowCoversBeingMade.contains(shown.rowID) else { return }
        // (The one on screen stays up until the new one is made.)
        musicRowCoversBeingMade.insert(shown.rowID)
        Task { @MainActor in
            let made = await self.makeMusicRowCover(forRow: shown.rowID)
            self.musicRowCoversBeingMade.remove(shown.rowID)
            self.musicRowCovers.updateValue(made, forKey: shown.rowID)
            guard self.musicRowCover?.rowID == shown.rowID else { return }
            withAnimation(.easeInOut(duration: 0.22)) {
                self.musicRowCover = made.map { MusicRowCover(rowID: shown.rowID, image: $0) }
            }
        }
    }

    private func makeMusicRowCover(forRow row: String) async -> NSImage? {
        #if os(macOS) && !FIRSTROW_PORTABLE
            // (With a library file chosen as well, its playlists are among the Music app's:
            // the list is made as Playlists makes it.)
            if row != "music_playlists" || MediaSources.shared.library(.iTunesXML) == nil,
               let made = await Task.detached(priority: .userInitiated, operation: { Self.musicAppRowCover(forRow: row) }).value
            {
                return made
            }
        #endif
        let inOrder: [MusicLibrarySongEntry]
        switch row {
        case "music_playlists":
            // Each playlist's first cover before any playlist's others: with four playlists
            // or more, the picture is of four of them.
            let playlists = await libraryPlaylistsNow()
            inOrder = playlists.compactMap(\.coverSongs.first) + playlists.flatMap { $0.coverSongs.dropFirst() }
        case "music_music_videos":
            inOrder = await (try? fetchMusicLibraryEntries(for: .musicVideos, includeArtwork: false)) ?? []
        case "music_audiobooks":
            inOrder = await (try? fetchMusicLibraryEntries(for: .audiobooks, includeArtwork: false)) ?? []
        default:
            return nil
        }
        let covers = await musicCovers(of: musicPlaylistCoverSongs(from: inOrder))
        return await Task.detached(priority: .userInitiated) { Self.musicPlaylistMosaic(of: covers) }.value
    }

    #if os(macOS) && !FIRSTROW_PORTABLE
        /// The Mac's row pictures come straight from the Music library, read on another
        /// thread: making the row's whole list to find its first four covers would hold
        /// everything on screen still as the row was reached (the library is read on the
        /// main thread for the lists, a tenth of a second and more). Nil if the library
        /// can't be read; no picture (a nil within) for a row with nothing to show.
        nonisolated static func musicAppRowCover(forRow row: String) -> NSImage?? {
            guard !FirstRowHarness.isActive, let library = try? ITLibrary(apiVersion: "1.0") else { return nil }
            func byName(_ a: String?, _ b: String?) -> Bool {
                (a ?? "").localizedCaseInsensitiveCompare(b ?? "") == .orderedAscending
            }
            var inOrder: [ITLibMediaItem]
            switch row {
            case "music_playlists":
                // As Playlists lists them: the user's own, by name, those with a song.
                let playlists = library.allPlaylists.filter { playlist in
                    guard playlist.isVisible, playlist.kind != .folder, !playlist.isMaster else { return false }
                    if #available(macOS 12.0, *), playlist.isPrimary { return false }
                    return true
                }.sorted { byName($0.name, $1.name) }
                var firsts: [ITLibMediaItem] = []
                var others: [ITLibMediaItem] = []
                for playlist in playlists {
                    let songs = playlist.items.lazy.filter { $0.mediaKind == .kindSong && !$0.isUserDisabled }.prefix(musicCoverCandidateCount)
                    guard let first = songs.first else { continue }
                    firsts.append(first)
                    others += songs.dropFirst()
                    // (Each playlist's first cover before any playlist's others: four
                    // playlists make the picture where there are four.)
                    if firsts.count == musicCoverCandidateCount { break }
                }
                inOrder = firsts + others
            case "music_music_videos", "music_audiobooks":
                let kind: ITLibMediaItemMediaKind = row == "music_music_videos" ? .kindMusicVideo : .kindAudiobook
                inOrder = library.allMediaItems.filter { $0.mediaKind == kind && !$0.isUserDisabled }.sorted { byName($0.title, $1.title) }
            default:
                return .some(nil)
            }
            var albumsSeen: Set<String> = []
            var asked = 0
            var covers: [CGImage] = []
            for item in inOrder {
                let album = item.album.persistentID.stringValue
                let key = album.isEmpty || album == "0" ? "\(item.album.albumArtist ?? item.artist?.name ?? "")|\(item.album.title ?? "")" : album
                guard albumsSeen.insert(key).inserted else { continue }
                asked += 1
                guard asked <= musicCoverCandidateCount else { break }
                guard let data = item.artwork?.imageData as Data?,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cover = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: 800,
                      ] as CFDictionary) else { continue }
                covers.append(cover)
                if covers.count == 4 { break }
            }
            return .some(musicPlaylistMosaic(of: covers))
        }
    #endif

    /// The covers of these songs, as far as the fourth: what a picture of several is made of.
    func musicCovers(of songs: [MusicLibrarySongEntry]) async -> [CGImage] {
        var covers: [CGImage] = []
        for song in songs {
            var cover = song.artwork
            if cover == nil, let songKey = musicArtworkCacheKey(for: song) {
                cover = await resolveMusicArtworkImage(for: song, cacheKey: songKey)
            }
            // (The same picture again, from another song of an album: once is enough.)
            if let cgImage = LayerImageCache.cgImage(for: cover), !covers.contains(where: { $0 === cgImage }) {
                covers.append(cgImage)
                if covers.count == 4 { break }
            }
        }
        return covers
    }

    /// Apple Music's own cover for a playlist, in place of the one made from its albums. Asked
    /// for once that one is up: it can take a moment, and has to be asked of the Music app (Mac)
    /// or of Apple Music's library (iPhone and iPad, iOS 16 on).
    func followWithMusicPlaylistOwnCover(for playlist: MusicCategoryEntry, standInID: String, cacheKey: String) {
        #if os(macOS) || os(iOS)
            #if os(macOS)
                // (Only the Music library's own playlists: the Music app knows them by this.)
                let prefix = "playlist::mac::"
                guard playlist.id.hasPrefix(prefix),
                      let persistentIDHex = Self.musicPersistentIDHexString(forDecimalString: String(playlist.id.dropFirst(prefix.count)))
                else { return }
            #else
                guard playlist.id.hasPrefix("playlist::ios::") else { return }
                let playlistTitle = playlist.title
            #endif
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 150_000_000)
                var ownCover: NSImage?
                #if os(macOS)
                    if let data = await musicAppleScriptExecutor.run({ Self.musicPlaylistArtworkDataFromMusicApp(persistentIDHex: persistentIDHex) }) {
                        ownCover = cachedDecodedDisplayArtworkImage(from: data, sourceKey: cacheKey + "|own", maxPixelSize: 900)
                    }
                #else
                    if #available(iOS 16.0, *) {
                        ownCover = await Self.appleMusicPlaylistArtwork(named: playlistTitle)
                    }
                #endif
                guard let ownCover else { return }
                await MainActor.run {
                    self.musicPreviewCache[cacheKey] = ownCover
                    guard self.musicPreviewTargetSongID == standInID else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        self.musicPreviewImage = ownCover
                    }
                }
            }
        #endif
    }

    #if os(macOS)
        /// A playlist's own cover as the Music app has it (a playlist's artwork can be asked for
        /// as a track's can): its data, or nil when it has none or the Music app isn't open.
        nonisolated static func musicPlaylistArtworkDataFromMusicApp(persistentIDHex: String) -> Data? {
            guard !FirstRowHarness.isActive else { return nil }
            let source = """
            tell application "\(musicApplicationName)"
                if not running then return missing value
                try
                    set thePlaylist to first playlist whose persistent ID is "\(persistentIDHex)"
                    if (count of artworks of thePlaylist) is 0 then return missing value
                    return raw data of artwork 1 of thePlaylist
                end try
                return missing value
            end tell
            """
            guard let script = NSAppleScript(source: source) else { return nil }
            var errorInfo: NSDictionary?
            let descriptor = autoreleasepool { script.executeAndReturnError(&errorInfo) }
            guard errorInfo == nil else { return nil }
            let data = descriptor.data
            return data.count > 64 ? data : nil
        }
    #endif

    #if os(iOS)
        /// A playlist's own cover from Apple Music's library (iOS 16 on): nil when it has none,
        /// and its albums' covers serve.
        @available(iOS 16.0, *)
        nonisolated static func appleMusicPlaylistArtwork(named name: String) async -> NSImage? {
            guard MusicAuthorization.currentStatus == .authorized else { return nil }
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 500
            guard let playlists = try? await request.response().items,
                  let artwork = playlists.first(where: { $0.name == name })?.artwork,
                  var address = artwork.url(width: 800, height: 800) else { return nil }
            // A picture kept on the phone comes as an address only Apple's own views open. It
            // carries the web address of the same picture, which anything can fetch.
            if address.scheme?.hasPrefix("http") != true {
                guard let carried = URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems?
                    .compactMap(\.value).first(where: { $0.hasPrefix("http") }),
                    let web = URL(string: carried.replacingOccurrences(of: "{w}", with: "800").replacingOccurrences(of: "{h}", with: "800")
                        .replacingOccurrences(of: "{f}", with: "jpg"))
                else { return nil }
                address = web
            }
            guard let (data, _) = try? await URLSession.shared.data(from: address) else { return nil }
            return NSImage(data: data)
        }
    #endif

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
        if song.id.hasPrefix(Self.musicPlaylistCoverIDPrefix) {
            return await resolveMusicPlaylistCover(standIn: song, cacheKey: cacheKey)
        }
        if song.id.hasPrefix(Self.spotifyRowCoverIDPrefix) {
            return await resolveSpotifyRowCover(standInID: song.id)
        }
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
                    maxPixelSize: DisplayArtworkSize.maxPixelSize,
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
                        maxPixelSize: DisplayArtworkSize.maxPixelSize,
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
            var item = query.items?.first ?? PlaylistItems.item(persistentID)
            if item == nil {
                // (An audiobook or a music video isn't among the songs: among everything.)
                let everything = MPMediaQuery()
                everything.addFilterPredicate(MPMediaPropertyPredicate(
                    value: NSNumber(value: id),
                    forProperty: MPMediaItemPropertyPersistentID,
                    comparisonType: .equalTo,
                ))
                item = everything.items?.first
            }
            return item?.artwork?.image(at: CGSize(width: 800, height: 800))
        }

        /// The playlists' own items, by their identifiers. A song can be in a playlist without
        /// being in the library (added to the playlist in Music): looking among the library's
        /// songs doesn't find it, for its cover or to play it.
        enum PlaylistItems {
            private static let lock = NSLock()
            nonisolated(unsafe) private static var items: [String: MPMediaItem] = [:]

            static func remember(_ found: [MPMediaItem]) {
                lock.lock()
                for item in found { items["\(item.persistentID)"] = item }
                lock.unlock()
            }

            static func item(_ persistentID: String) -> MPMediaItem? {
                lock.lock()
                defer { lock.unlock() }
                return items[persistentID]
            }
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
        // (A cover that came in the song's own file is still as the file holds it. Shown like
        // that it would be decoded on the main thread as it reached the screen, a missed frame
        // or several for every song passed; so it's shown from the decoded copy, as any other.)
        guard let cacheKey = musicArtworkCacheKey(for: selectedSong) else {
            withAnimation(.easeInOut(duration: fadeDuration)) {
                musicPreviewImage = selectedSong.artwork
            }
            return
        }
        // (Another song of the album may have had the same cover decoded already.)
        if let cached = musicPreviewCache[cacheKey] ?? selectedSong.url.flatMap({ decodedEmbeddedMusicCover(for: $0) }) {
            musicPreviewCache[cacheKey] = cached
            withAnimation(.easeInOut(duration: fadeDuration)) {
                musicPreviewImage = cached
            }
            return
        }
        // Not decoded yet: keep the current cover up rather than flash the placeholder.
        let targetSongID = selectedSong.id
        Task.detached(priority: .userInitiated) {
            // (Failing that copy, the song's own picture as it is.)
            let resolvedArtwork = await self.resolveMusicArtworkImage(
                for: selectedSong,
                cacheKey: cacheKey,
            ) ?? selectedSong.artwork
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
                    userInfo: [NSLocalizedDescriptionKey: L("Music library access not authorized")],
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
                    // Albums whose cover isn't here (yet) are left out rather than shown blank.
                    guard let cover = item.artwork?.image(at: CGSize(width: 800, height: 800)) else { continue }
                    artworks.append(cover)
                    if artworks.count >= resolvedLimit { break }
                }
                if artworks.isEmpty, resolvedStartIndex == 0 { artworks.append(fallback) }
                return artworks
            }.value
        #elseif os(tvOS)
            guard MusicAuthorization.currentStatus == .authorized else {
                throw NSError(
                    domain: "firstRowMusicLibrary",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: L("Music library access not authorized")],
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
                let albumIdentity = song.album == L("Unknown Album")
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
                    cachedDecodedDisplayArtworkImage(from: data, sourceKey: sourceKey, maxPixelSize: DisplayArtworkSize.maxPixelSize)
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
        nonisolated func musicTopLevelCarouselAlbumKey(for song: Song) -> String {
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
            // By the album's artist, so that an album is under one name: by each song's own,
            // an artist was there once for everyone they had made a song with.
            song.listedArtist
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
            // (An artist with one album in the library: its songs, in its order.)
            let firstAlbum = groupedCategorySongs.first.map { musicCategoryValue(for: $0, kind: .albums) }
            let isOneAlbum = kind == .albums
                || (kind == .artists && !groupedCategorySongs.contains { musicCategoryValue(for: $0, kind: .albums) != firstAlbum })
            if isOneAlbum {
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
            var entry = MusicCategoryEntry(
                id: "\(kind.rawValue)::\(categoryTitle.lowercased())",
                title: categoryTitle,
                songs: sortedCategorySongs,
            )
            if kind == .genres || kind == .composers {
                // Its picture: the covers of its first four albums (by name), or its first.
                entry.coverSongs = musicPlaylistCoverSongs(from: musicSongsByAlbum(groupedCategorySongs))
            }
            categoryEntries.append(entry)
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
            title: L("All"),
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

    /// What the row of an artist's albums that holds all of the artist's songs is known by
    /// (the artist's own name for the list follows it).
    static let musicArtistAllSongsIDPrefix = "albums::all songs of::"

    /// Songs by album (by name, as the Albums list has them), each album's in its own order.
    nonisolated func musicSongsByAlbum(_ songs: [MusicLibrarySongEntry]) -> [MusicLibrarySongEntry] {
        songs.sorted {
            let albums = $0.album.localizedCaseInsensitiveCompare($1.album)
            if albums != .orderedSame { return albums == .orderedAscending }
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            return $0.trackNumber < $1.trackNumber
        }
    }

    /// The artists an artist's albums were opened from: their rows, the row that was chosen,
    /// the list's heading and the artist.
    struct MusicArtistsReturn {
        var artists: [MusicCategoryEntry]
        var index: Int
        let title: String
        let artistID: String
    }

    /// An artist's albums, as a list of albums is shown: "All Songs" first, then each album
    /// by name. Back from it is the artists again (`musicArtistsReturn`).
    private func enterAlbums(of artist: MusicCategoryEntry, albums: [MusicCategoryEntry], artistIndex: Int) {
        transitionMenuForFolderSwap {
            self.musicArtistsReturn = MusicArtistsReturn(
                artists: self.musicCategoryThirdMenuItems, index: artistIndex, title: self.activeMusicCategoryMenuTitle, artistID: artist.id,
            )
            var everySong = MusicCategoryEntry(id: Self.musicArtistAllSongsIDPrefix + artist.id, title: L("All Songs"), songs: artist.songs)
            // (Its picture is made of the artist's albums' covers.)
            everySong.coverSongs = self.musicPlaylistCoverSongs(from: self.musicSongsByAlbum(artist.songs))
            self.musicCategoryThirdMenuItems = [everySong] + albums
            self.activeMusicCategoryKind = .albums
            self.activeMusicCategoryMenuTitle = artist.title
            self.selectedThirdIndex = 0
            self.headerText = artist.title
            self.refreshDetailPreviewForCurrentContext()
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
        }
    }

    /// Back from an artist's albums to the artists, on the artist they were opened from.
    /// False if the list showing isn't an artist's albums.
    func returnToMusicArtistsFromAlbums() -> Bool {
        guard thirdMenuMode == .musicCategories, let back = musicArtistsReturn else { return false }
        transitionMenuForFolderSwap {
            self.musicArtistsReturn = nil
            self.activeMusicCategoryKind = .artists
            self.musicCategoryThirdMenuItems = back.artists
            self.activeMusicCategoryMenuTitle = back.title
            self.headerText = back.title.isEmpty ? self.rootMenuTitle(for: self.activeRootItemID) : back.title
            self.selectedThirdIndex = min(back.index, max(0, back.artists.count - 1))
            self.refreshDetailPreviewForCurrentContext()
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
        }
        return true
    }

    func enterSongsForSelectedMusicCategory() {
        guard thirdMenuMode == .musicCategories else { return }
        guard musicCategoryThirdMenuItems.indices.contains(selectedThirdIndex) else { return }
        let categoryEntry = musicCategoryThirdMenuItems[selectedThirdIndex]
        let categoryIndex = selectedThirdIndex
        // An artist leads to their albums, and an album to its songs. (With one album there
        // is nothing to choose between, and "All" is every artist's songs.)
        let songs = categoryEntry.songs
        if activeMusicCategoryKind == .artists, musicArtistsReturn == nil, categoryEntry.id != "\(MusicCategoryKind.artists.rawValue)::all" {
            let albums = buildMusicCategoryEntries(from: categoryEntry.songs, kind: .albums)
            if albums.count > 1 {
                enterAlbums(of: categoryEntry, albums: albums, artistIndex: categoryIndex)
                return
            }
        }
        transitionMenuForFolderSwap {
            self.thirdMenuMode = .musicSongs
            self.isMusicSongsCategoryScoped = true
            self.isMusicSongsShuffleMode = false
            self.lastSelectedMusicCategoryIndex = categoryIndex
            self.musicSongsThirdMenuItems = songs
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
            self.musicSongsLoadError = songs.isEmpty ? L("No Songs in Category") : nil
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
                    userInfo: [NSLocalizedDescriptionKey: L("Music library access not authorized")],
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
            // (Sizes and dates come with the list: a file not changed since it was last read
            // isn't read again, see `fetchExternalMusicSongEntries`.)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
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

        /// A song that is still with a service such as Dropbox, told from where it's kept
        /// ("Artist/Album/03 Title.mp3"): reading what the file says of itself would fetch all
        /// of it, and every song in the folder with it. Once it has been played it is on the
        /// disk, and is read like any other the next time the library is.
        nonisolated func songEntryFromItsPlace(_ url: URL, in root: URL?) -> MusicLibrarySongEntry {
            var title = url.deletingPathExtension().lastPathComponent
            var trackNumber = 0
            var discNumber = 1
            // "03 Title", "03 - Title", "03. Title", "2-03 Title".
            let digits = title.prefix(while: \.isNumber)
            if !digits.isEmpty, digits.count <= 3 {
                var rest = title.dropFirst(digits.count)
                var number = Int(digits) ?? 0
                if rest.first == "-", let following = Optional(rest.dropFirst().prefix(while: \.isNumber)), !following.isEmpty, following.count <= 3 {
                    discNumber = max(1, number)
                    number = Int(following) ?? 0
                    rest = rest.dropFirst(1 + following.count)
                }
                let name = rest.drop(while: { $0 == " " || $0 == "-" || $0 == "." || $0 == "_" })
                if !name.isEmpty, rest.count > name.count {
                    title = String(name)
                    trackNumber = number
                }
            }
            var folders = url.deletingLastPathComponent().standardizedFileURL.pathComponents
            if let root {
                let above = root.standardizedFileURL.pathComponents
                folders = folders.starts(with: above) ? Array(folders.dropFirst(above.count)) : []
            }
            let album = folders.last ?? L("Unknown Album")
            let artist = folders.count > 1 ? folders[folders.count - 2] : L("Unknown Artist")
            return MusicLibrarySongEntry(
                id: "ext::\(url.standardizedFileURL.path)",
                title: title,
                artist: artist,
                album: album,
                genre: L("Unknown Genre"),
                composer: L("Unknown Composer"),
                durationSeconds: 0,
                trackNumber: trackNumber,
                discNumber: discNumber,
                artworkAlbumKey: nil,
                url: url,
                artwork: nil,
            )
        }

        nonisolated func makeMusicLibrarySongEntryFromAudioFile(_ url: URL, covers: SharedCovers? = nil, in root: URL? = nil) async -> MusicLibrarySongEntry? {
            if CloudFolders.isStillInTheCloud(url) {
                return songEntryFromItsPlace(url, in: root)
            }
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
            var title = firstCommonString(.commonKeyTitle)
            var artist = firstCommonString(.commonKeyArtist)
            var albumName = firstCommonString(.commonKeyAlbumName)
            let artworkData = AVMetadataItem.metadataItems(
                from: commonMetadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common
            ).first?.dataValue
            var genre = L("Unknown Genre")
            var composer = L("Unknown Composer")
            var albumArtist = ""
            var trackNumber = 0
            var discNumber = 1
            // The rest is in each kind of file's own tags: an MP3's (id3), an MP4's (itsk)
            // and a FLAC's (vorb).
            for item in metadata {
                guard let tag = item.identifier.map({ Self.plainMusicTagName($0.rawValue) }) else { continue }
                let words = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let text: String? = words.isEmpty ? nil : words
                // A number as "3" or "3 of 12" ("3/12"), or as an MP4 holds it: in its third
                // and fourth bytes.
                var number: Int? {
                    if let text { return Int(text.components(separatedBy: "/")[0].trimmingCharacters(in: .whitespaces)) }
                    guard let bytes = item.dataValue, bytes.count >= 4 else { return nil }
                    return Int(bytes[bytes.startIndex + 2]) << 8 | Int(bytes[bytes.startIndex + 3])
                }
                switch tag {
                case "id3/TPE2", "itsk/aART", "vorb/ALBUMARTIST", "vorb/ALBUM ARTIST":
                    albumArtist = text ?? albumArtist
                case "id3/TCON", "itsk/©gen", "vorb/GENRE":
                    genre = text ?? genre
                case "itsk/gnre":
                    // (One of the genres every player knows, by its number: one more than
                    // its place among them.)
                    if let text {
                        genre = text
                    } else if let bytes = item.dataValue, bytes.count >= 2 {
                        let place = (Int(bytes[bytes.startIndex]) << 8 | Int(bytes[bytes.startIndex + 1])) - 1
                        if Self.numberedMusicGenres.indices.contains(place) { genre = Self.numberedMusicGenres[place] }
                    }
                case "id3/TCOM", "itsk/©wrt", "vorb/COMPOSER":
                    composer = text ?? composer
                case "id3/TRCK", "itsk/trkn", "vorb/TRACKNUMBER":
                    trackNumber = number ?? trackNumber
                case "id3/TPOS", "itsk/disk", "vorb/DISCNUMBER":
                    discNumber = number ?? discNumber
                // (A FLAC's name, artist and album aren't among what every kind of file has
                // in common, where the system reads them.)
                case "vorb/TITLE":
                    title = title ?? text
                case "vorb/ARTIST":
                    artist = artist ?? text
                case "vorb/ALBUM":
                    albumName = albumName ?? text
                default:
                    break
                }
            }
            let resolvedTitle = title ?? url.deletingPathExtension().lastPathComponent
            let resolvedArtist = artist ?? L("Unknown Artist")
            let resolvedAlbum = albumName ?? L("Unknown Album")
            let durationSeconds = max(0, CMTimeGetSeconds(duration))
            let artwork = artworkData.flatMap { data in covers.map { $0.image(for: data, inFile: url) } ?? NSImage(data: data) }
            var song = MusicLibrarySongEntry(
                id: "ext::\(url.standardizedFileURL.path)",
                title: resolvedTitle,
                artist: resolvedArtist,
                album: resolvedAlbum,
                genre: genre,
                composer: composer,
                durationSeconds: durationSeconds,
                trackNumber: trackNumber,
                discNumber: discNumber,
                // (By the album's artist where the file says: the songs of an album made
                // with other people are still one album, with one cover.)
                artworkAlbumKey: artwork != nil ? "\(albumArtist.isEmpty ? resolvedArtist : albumArtist):::\(resolvedAlbum)" : nil,
                url: url,
                artwork: artwork,
            )
            song.albumArtist = albumArtist
            return song
        }

        /// A tag's name, the same however it is written: an MP4's "©gen" comes as
        /// "%A9gen" from the system, and a FLAC's as "vorb/" or "vorbis/".
        nonisolated static func plainMusicTagName(_ name: String) -> String {
            var plain = name.replacingOccurrences(of: "%A9", with: "©")
            if plain.hasPrefix("vorbis/") { plain = "vorb/" + plain.dropFirst("vorbis/".count) }
            return plain
        }

        /// The genres an MP4 can name by number alone, in their order.
        nonisolated static let numberedMusicGenres = [
            "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies",
            "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks",
            "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental",
            "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative",
            "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk",
            "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
            "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk",
            "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        ]

        /// The songs in the music folders. A file that was read before and hasn't changed
        /// since (the same size and date) is the song it was then: reading a file's tags and
        /// length takes long enough that a large folder read all over again, each time a
        /// folder was added or a song copied in, held the new songs back for a long while.
        nonisolated func fetchExternalMusicSongEntries() async -> [MusicLibrarySongEntry] {
            var results: [MusicLibrarySongEntry] = []
            let covers = SharedCovers()
            var read: [String: FolderSongsRead.Song] = [:]
            for root in externalMusicRootURLs() {
                for url in scanExternalMusicFiles(in: root) {
                    let path = url.standardizedFileURL.path
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let size = values?.fileSize
                    let date = values?.contentModificationDate
                    if let size, let date, let before = FolderSongsRead.shared.song(at: path, size: size, date: date) {
                        results.append(before.entry)
                        read[path] = before
                        continue
                    }
                    guard let entry = await makeMusicLibrarySongEntryFromAudioFile(url, covers: covers, in: root) else { continue }
                    results.append(entry)
                    // (One still with its service is told from where it's kept, and read
                    // properly once it has been fetched.)
                    if let size, let date, !CloudFolders.isStillInTheCloud(url) {
                        read[path] = FolderSongsRead.Song(size: size, date: date, entry: entry)
                    }
                }
            }
            FolderSongsRead.shared.keep(read)
            return results
        }

        /// What was read of the music folders' files the last time they were looked through.
        final class FolderSongsRead: @unchecked Sendable {
            struct Song {
                let size: Int
                let date: Date
                let entry: MusicLibrarySongEntry
            }

            static let shared = FolderSongsRead()
            private let lock = NSLock()
            private var songs: [String: Song] = [:]

            func song(at path: String, size: Int, date: Date) -> Song? {
                lock.lock()
                defer { lock.unlock() }
                guard let song = songs[path], song.size == size, song.date == date else { return nil }
                return song
            }

            func keep(_ read: [String: Song]) {
                lock.lock()
                songs = read
                lock.unlock()
            }
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
                    userInfo: [NSLocalizedDescriptionKey: L("Music library access not authorized")],
                )
            }
            // A big library takes seconds to read and turn into entries: well away from the main
            // thread, which would otherwise ignore every touch meanwhile (at launch, say).
            return await Task.detached(priority: .userInitiated) { () -> [MusicLibrarySongEntry] in
                let mediaItems: [MPMediaItem]
                switch mediaType {
                case .songs:
                    var items = MPMediaQuery.songs().items ?? []
                    // A song that's in a playlist and nowhere else is a song too: the
                    // system's list of the library's songs leaves those out.
                    var known = Set(items.map(\.persistentID))
                    var alike = Set(items.map { "\(($0.title ?? "").lowercased())|\(($0.artist ?? "").lowercased())|\(($0.albumTitle ?? "").lowercased())|\(Int($0.playbackDuration.rounded()))" })
                    for collection in MPMediaQuery.playlists().collections ?? [] {
                        let only = collection.items.filter { item in
                            item.mediaType.contains(.music) && !item.mediaType.contains(.anyVideo) && known.insert(item.persistentID).inserted
                                && alike.insert("\((item.title ?? "").lowercased())|\((item.artist ?? "").lowercased())|\((item.albumTitle ?? "").lowercased())|\(Int(item.playbackDuration.rounded()))").inserted
                        }
                        guard !only.isEmpty else { continue }
                        // (Kept to hand: the library can't be asked for these by number.)
                        PlaylistItems.remember(only)
                        items += only
                    }
                    mediaItems = items
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

    /// What tells one song from another where two of the library's entries may be the same
    /// song: its name, who it's by, the album and its length to the second.
    nonisolated static func musicSongLikeness(_ song: MusicLibrarySongEntry) -> String {
        "\(song.title.lowercased())|\(song.artist.lowercased())|\(song.album.lowercased())|\(Int(song.durationSeconds.rounded()))"
    }

    func fetchMusicLibraryPlaylists() throws -> [MusicCategoryEntry] {
        #if os(iOS)
            guard MPMediaLibrary.authorizationStatus() == .authorized else {
                throw NSError(
                    domain: "firstRowMusicLibrary",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: L("Music library access not authorized")],
                )
            }
            return mediaLibraryPlaylists()
        #elseif canImport(iTunesLibrary)
            let libraryPlaylists = (try? withITLibrary { library in
                library.allPlaylists.compactMap { playlist -> MusicCategoryEntry? in
                    guard playlist.isVisible else { return nil }
                    guard playlist.kind != .folder else { return nil }
                    guard !playlist.isMaster else { return nil }
                    if #available(macOS 12.0, *) {
                        guard !playlist.isPrimary else { return nil }
                    }
                    let title = normalizedMusicLibraryText(playlist.name, fallback: L("Untitled Playlist"))
                    let playlistPersistentIDHex = musicPersistentIDHexString(for: playlist.persistentID)
                    let songsInOrder = playlist.items.compactMap { item -> MusicLibrarySongEntry? in
                        guard musicLibraryMediaKindMatches(item.mediaKind, requested: .songs) else { return nil }
                        return makeMusicLibrarySongEntry(
                            from: item,
                            // A cover is a fetch from the library of its own: one for every song
                            // of every playlist held First Row still for over a second with a
                            // few hundred of them. It comes when the song is shown, as in Songs
                            // (but a song that is only in a playlist has no other way to its).
                            includeArtwork: musicLibraryItemIndexBySongID["\(item.persistentID)"] == nil,
                            sourcePlaylistPersistentIDHex: playlistPersistentIDHex,
                        )
                    }
                    // (In the playlist's own order, not by title.)
                    guard !songsInOrder.isEmpty else { return nil }
                    return MusicCategoryEntry(
                        id: "playlist::mac::\(playlist.persistentID)",
                        title: title,
                        songs: songsInOrder,
                        coverSongs: musicPlaylistCoverSongs(from: songsInOrder),
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

    #if os(iOS)
        /// The library's playlists, by name. (Can be read on any thread.)
        nonisolated func mediaLibraryPlaylists() -> [MusicCategoryEntry] {
            let collections = MPMediaQuery.playlists().collections ?? []
            let playlists: [MusicCategoryEntry] = collections.compactMap { collection in
                let playlist = collection as? MPMediaPlaylist
                let title = normalizedMusicLibraryText(playlist?.name, fallback: L("Untitled Playlist"))
                let persistentID = playlist.map { "\($0.persistentID)" } ?? title.lowercased()
                // (In the playlist's own order, not by title.)
                PlaylistItems.remember(collection.items)
                let songs = collection.items.compactMap { makeMusicLibrarySongEntry(from: $0, includeArtwork: false) }
                guard !songs.isEmpty else { return nil }
                return MusicCategoryEntry(
                    id: "playlist::ios::\(persistentID)",
                    title: title,
                    songs: songs,
                    coverSongs: musicPlaylistCoverSongs(from: songs),
                )
            }
            return playlists.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    #endif

    #if canImport(iTunesLibrary)
        nonisolated func iTunesXMLSongEntry(_ track: ITunesLibraryXML.Track) -> MusicLibrarySongEntry {
            var song = MusicLibrarySongEntry(
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
            song.albumArtist = track.albumArtist
            return song
        }

        nonisolated func iTunesXMLSongEntries() -> [MusicLibrarySongEntry] {
            ITunesLibraryXML.shared.contents()?.tracks.map(iTunesXMLSongEntry) ?? []
        }

        nonisolated func iTunesXMLPlaylistEntries() -> [MusicCategoryEntry] {
            guard let contents = ITunesLibraryXML.shared.contents() else { return [] }
            return contents.playlists.map { playlist in
                let songs = playlist.trackIDs.compactMap { contents.tracksByID[$0] }.map(iTunesXMLSongEntry)
                return MusicCategoryEntry(
                    id: "playlist::xml::\(playlist.persistentID)",
                    title: playlist.name,
                    songs: songs,
                    coverSongs: musicPlaylistCoverSongs(from: songs),
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
                fallback: locationURL?.deletingPathExtension().lastPathComponent ?? L("Unknown Song"),
            )
            let artist = normalizedMusicLibraryText(item.artist, fallback: L("Unknown Artist"))
            let album = normalizedMusicLibraryText(item.albumTitle, fallback: L("Unknown Album"))
            let genre = normalizedMusicLibraryText(item.genre, fallback: L("Unknown Genre"))
            let composer = normalizedMusicLibraryText(item.composer, fallback: L("Unknown Composer"))
            var song = MusicLibrarySongEntry(
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
            song.albumArtist = normalizedMusicLibraryText(item.albumArtist, fallback: "")
            return song
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
                maxPixelSize: DisplayArtworkSize.maxPixelSize,
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
                fallback: locationURL?.deletingPathExtension().lastPathComponent ?? L("Unknown Song"),
            )
            let artist = normalizedMusicLibraryText(item.artist?.name, fallback: L("Unknown Artist"))
            let album = normalizedMusicLibraryText(item.album.title, fallback: L("Unknown Album"))
            let genre = normalizedMusicLibraryText(item.genre, fallback: L("Unknown Genre"))
            let composer = normalizedMusicLibraryText(item.composer, fallback: L("Unknown Composer"))
            var song = MusicLibrarySongEntry(
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
            song.albumArtist = normalizedMusicLibraryText(item.album.albumArtist, fallback: "")
            return song
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
                    userInfo: [NSLocalizedDescriptionKey: L("Music library access not authorized")],
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
            let items = Array(response.items)
            // Off the main thread: a song's details are read from the library as each is asked
            // for, which for a few hundred songs held First Row up as it started.
            return await Task.detached(priority: .userInitiated) {
                let albumArtists = await Self.musicKitAlbumArtists()
                var songs: [MusicLibrarySongEntry] = []
                songs.reserveCapacity(items.count)
                for song in items {
                    guard var entry = await self.makeMusicLibrarySongEntry(from: song, includeArtwork: includeArtwork) else {
                        continue
                    }
                    entry.albumArtist = albumArtists[entry.album] ?? ""
                    songs.append(entry)
                }
                // A song that's in a playlist and nowhere else is a song too: the system's
                // list of the library's songs leaves those out.
                var known = Set(songs.map(\.id))
                var alike = Set(songs.map(Self.musicSongLikeness))
                for playlist in await (try? self.fetchMusicKitPlaylists()) ?? [] {
                    for var song in playlist.songs where known.insert(song.id).inserted && alike.insert(Self.musicSongLikeness(song)).inserted {
                        song.albumArtist = albumArtists[song.album] ?? ""
                        songs.append(song)
                    }
                }
                return shouldSort ? self.sortedMusicLibraryEntries(songs) : songs
            }.value
        }

        /// Whose album each of the library's albums is, by the album's name: a song here
        /// says what its album is called and no more. Two albums of one name by different
        /// artists can't be told apart from a song, and are left out (their songs stay
        /// under their own artists).
        @available(tvOS 16.0, *)
        nonisolated static func musicKitAlbumArtists() async -> [String: String] {
            var request = MusicLibraryRequest<Album>()
            request.limit = 5000
            guard let albums = try? await request.response().items else { return [:] }
            var artists: [String: String] = [:]
            var sharedNames: Set<String> = []
            for album in albums {
                let title = album.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let artist = album.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, !artist.isEmpty else { continue }
                if let known = artists[title], known != artist {
                    sharedNames.insert(title)
                } else {
                    artists[title] = artist
                }
            }
            for title in sharedNames {
                artists[title] = nil
            }
            return artists
        }

        nonisolated func makeMusicLibrarySongEntry(from song: Song, includeArtwork: Bool = true) async -> MusicLibrarySongEntry? {
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
                title: title.isEmpty ? L("Unknown Song") : title,
                artist: artist.isEmpty ? L("Unknown Artist") : artist,
                album: album.isEmpty ? L("Unknown Album") : album,
                genre: genre.isEmpty ? L("Unknown Genre") : genre,
                composer: composer.isEmpty ? L("Unknown Composer") : composer,
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
            // (The library's own artwork doesn't say how large it comes, and was asked for at
            // the smallest size used here: 300 pixels across, on a screen of 3840.)
            let largest = min(artwork.maximumWidth, artwork.maximumHeight)
            let side = largest > 0 ? max(300, min(800, largest)) : 800
            guard let artworkURL = artwork.url(width: side, height: side) else { return nil }
            // The selected row's cover before its neighbours', which are asked for more quietly.
            let isForSelectedRow = Task.currentPriority >= .userInitiated
            guard let data = await LibraryCoverReader.shared.data(from: artworkURL, forSelectedRow: isForSelectedRow) else { return nil }
            return cachedDecodedDisplayArtworkImage(
                from: data,
                sourceKey: artworkURL.absoluteString,
                maxPixelSize: CGFloat(side),
            )
        }

        /// Reads the library's covers on threads of its own, three at a time: first the one
        /// for the row that's selected now, then the ones for the rows near it, then the ones
        /// for rows that were selected and have been left, the latest asked for first.
        ///
        /// A read waits on the system, which may have to fetch the picture. Each used to wait
        /// on one of Swift's own few threads, and a list swiped down at speed asked for a
        /// cover for every row it passed: with every one of those threads waiting, nothing
        /// else due on them ran, and the row the list came to rest on had its cover after
        /// all the rows passed had theirs (a quarter of a minute later, with slow reads).
        final class LibraryCoverReader: @unchecked Sendable {
            static let shared = LibraryCoverReader()

            private typealias Request = (url: URL, answer: CheckedContinuation<Data?, Never>)
            private let threads = DispatchQueue(label: "firstrow.covers", qos: .userInitiated, attributes: .concurrent)
            private let lock = NSLock()
            private var selected: Request?
            private var nearby: [Request] = []
            private var left: [Request] = []
            private var reading = 0
            private let readsAtOnce = 3
            private let longestLine = 24

            /// The picture's data. Nil if it can't be read, or if it was let go: with more
            /// waiting than a line holds, the ones that have waited longest give way.
            func data(from url: URL, forSelectedRow: Bool) async -> Data? {
                await withCheckedContinuation { answer in
                    var letGo: [Request] = []
                    lock.lock()
                    if forSelectedRow {
                        if let before = selected { left.append(before) }
                        selected = (url, answer)
                    } else {
                        nearby.append((url, answer))
                    }
                    while nearby.count > longestLine { letGo.append(nearby.removeFirst()) }
                    while left.count > longestLine { letGo.append(left.removeFirst()) }
                    lock.unlock()
                    for request in letGo { request.answer.resume(returning: nil) }
                    readNext()
                }
            }

            private func readNext() {
                lock.lock()
                guard reading < readsAtOnce else {
                    lock.unlock()
                    return
                }
                let request: Request
                if let first = selected {
                    request = first
                    selected = nil
                } else if let next = nearby.popLast() ?? left.popLast() {
                    request = next
                } else {
                    lock.unlock()
                    return
                }
                reading += 1
                lock.unlock()
                threads.async {
                    request.answer.resume(returning: try? Data(contentsOf: request.url))
                    self.lock.lock()
                    self.reading -= 1
                    self.lock.unlock()
                    self.readNext()
                }
            }
        }

        /// The library's playlists as the system gives them, by name, each with its songs in
        /// its own order. (On tvOS there is no other way to them.)
        func fetchMusicKitPlaylists() async throws -> [MusicCategoryEntry] {
            guard MusicAuthorization.currentStatus == .authorized else {
                throw NSError(
                    domain: "firstRowMusicLibrary",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: L("Music library access not authorized")],
                )
            }
            guard #available(tvOS 16.0, *) else { return [] }
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 1000
            let playlists = try await Array(request.response().items)
            // (Off the main thread, as the songs are: each track's details are read as asked for.)
            return await Task.detached(priority: .userInitiated) {
                var entries: [MusicCategoryEntry] = []
                for playlist in playlists {
                    guard let first = try? await playlist.with([.tracks]).tracks else { continue }
                    var tracks = Array(first)
                    var batch = first
                    while batch.hasNextBatch, let next = try? await batch.nextBatch() {
                        tracks += Array(next)
                        batch = next
                    }
                    var songs: [MusicLibrarySongEntry] = []
                    songs.reserveCapacity(tracks.count)
                    for track in tracks {
                        // (A playlist's music videos are left out, as Songs leaves them out.)
                        guard case let .song(song) = track,
                              let entry = await self.makeMusicLibrarySongEntry(from: song, includeArtwork: false)
                        else { continue }
                        songs.append(entry)
                    }
                    guard !songs.isEmpty else { continue }
                    entries.append(MusicCategoryEntry(
                        id: "playlist::tvos::\(playlist.id.rawValue)",
                        title: self.normalizedMusicLibraryText(playlist.name, fallback: L("Untitled Playlist")),
                        songs: songs,
                        coverSongs: self.musicPlaylistCoverSongs(from: songs),
                    ))
                }
                return entries.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            }.value
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
                self.musicSongsLoadError = L("Music library access denied")
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
                self.musicSongsLoadError = L("Music library access denied")
                self.refreshMusicPreviewForCurrentContext()
                return
            }
            Task(priority: .userInitiated) {
                do {
                    let categories: [MusicCategoryEntry]
                    if kind == .playlists {
                        #if os(tvOS)
                            categories = try await self.fetchMusicKitPlaylists()
                        #else
                            categories = try self.fetchMusicLibraryPlaylists()
                        #endif
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
                queueOrigin: self.shownMusicListOrigin,
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
            musicSongsLoadError = L("No Songs in Music Library")
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
            // (Every song in the library, unless the songs last on screen were shuffled
            // again and those were from somewhere else.)
            queueOrigin: shuffledSongs.contains(where: { $0.spotify != nil || $0.jellyfin != nil })
                ? nil
                : MusicQueueOrigin(category: nil, isShuffled: true),
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
                self.musicSongsLoadError = L("Music library access denied")
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
                                self.musicSongsLoadError = L("No Songs in Music Library")
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
                                self.musicNowPlayingTrackPositionText = seededQueue.isEmpty ? "" : L("%@ of %@", 1, seededQueue.count)
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
                return L("Music library access is unavailable for this build.")
            }
        #endif
        return L("Unable to access Music library")
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
    /// One picture for every song that carries the same cover: an album's songs each have a
    /// copy of it in their file, and a library kept a copy for each song.
    final class SharedCovers: @unchecked Sendable {
        #if FIRSTROW_PORTABLE
            /// On Linux and Windows a picture made of a file's bytes keeps them, to decode when
            /// it's shown, so a library's covers all stayed in memory: a megabyte an album is
            /// common. There a cover is told from another by a digest of its bytes, and its
            /// picture reads them from the song's file again when it's shown.
            private struct Key: Hashable {
                let count: Int
                let digest: Int

                init(data: Data) {
                    count = data.count
                    var hasher = Hasher()
                    data.withUnsafeBytes { hasher.combine(bytes: $0) }
                    digest = hasher.finalize()
                }
            }
        #else
            private struct Key: Hashable {
                let data: Data

                /// The length and a few stretches of it: covers of one size start with the same bytes.
                func hash(into hasher: inout Hasher) {
                    hasher.combine(data.count)
                    let stretch = 48
                    guard data.count > stretch * 4 else {
                        hasher.combine(data)
                        return
                    }
                    for start in [data.count / 4, data.count / 2, data.count * 3 / 4, data.count - stretch] {
                        hasher.combine(data.subdata(in: data.startIndex + start ..< data.startIndex + start + stretch))
                    }
                }

                static func == (a: Key, b: Key) -> Bool { a.data == b.data }
            }
        #endif

        private let lock = NSLock()
        private var images: [Key: NSImage?] = [:]

        /// The picture for a cover's bytes, which were read from `file`.
        func image(for data: Data, inFile file: URL) -> NSImage? {
            let key = Key(data: data)
            lock.lock()
            defer { lock.unlock() }
            if let known = images[key] { return known }
            #if FIRSTROW_PORTABLE
                // (No larger than a cover is ever shown: some files carry one 3000 pixels across.)
                let image = NSImage(data: data, longestSide: 900) {
                    let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
                    return AVMetadataItem.metadataItems(from: asset.commonMetadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first?.dataValue
                }
            #else
                let image = NSImage(data: data)
            #endif
            images[key] = image
            return image
        }
    }

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
        /// Whose album the song is on, where the library or the file says (empty where it
        /// doesn't): a song two people made together is still on one of their albums.
        var albumArtist = ""

        /// The artist the song is listed under in Artists: its album's, or else its own.
        var listedArtist: String {
            albumArtist.isEmpty ? artist : albumArtist
        }

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
        /// A playlist's first songs from different albums, in its own order (`songs` is by name).
        var coverSongs: [MusicLibrarySongEntry] = []
    }

    enum MusicCategoryKind: String, Codable {
        case albums
        case artists
        case genres
        case composers
        case playlists
        var emptyLibraryMessage: String {
            switch self {
            case .albums: L("No Albums in Music Library")
            case .artists: L("No Artists in Music Library")
            case .genres: L("No Genres in Music Library")
            case .composers: L("No Composers in Music Library")
            case .playlists: L("No Playlists in Music Library")
            }
        }
    }

    enum MusicLibraryMediaType {
        case songs
        case musicVideos
        case audiobooks
        var emptyLibraryMessage: String {
            switch self {
            case .songs: L("No Songs in Music Library")
            case .musicVideos: L("No Music Videos in Music Library")
            case .audiobooks: L("No Audiobooks in Music Library")
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

/// Which picture each song file carries, by a name made from the picture itself. An album's
/// songs each carry a copy of its cover, and this way they share one decoded copy of it (and
/// with it one texture, one reflection and one background wash) instead of having one each.
private final class EmbeddedCoverNames: @unchecked Sendable {
    static let shared = EmbeddedCoverNames()
    private let lock = NSLock()
    private var names: [String: String] = [:]

    func name(forFile file: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return names[file]
    }

    func set(_ name: String, forFile file: String) {
        lock.lock()
        defer { lock.unlock() }
        if names.count > 50000 { names.removeAll() }
        names[file] = name
    }

    /// The picture's length and a 64-bit FNV-1a hash of all of it.
    static func name(for data: Data) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        data.withUnsafeBytes { bytes in
            for byte in bytes {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
        }
        return "embedded-cover|\(data.count)|\(String(hash, radix: 16))"
    }
}

/// The decoded copy of the cover a song file carries, if it's been made (for this song or for
/// another with the same cover). Reads nothing from the disk.
func decodedEmbeddedMusicCover(for url: URL) -> NSImage? {
    guard let name = EmbeddedCoverNames.shared.name(forFile: musicArtworkCacheKeyForFile(url)) else { return nil }
    return cachedDecodedDisplayArtworkImage(sourceKey: name, maxPixelSize: DisplayArtworkSize.maxPixelSize)
}

/// Artwork embedded in a song file, decoded for display; safe to call off the main thread.
func generateMusicArtworkThumbnailOffMain(for url: URL) async -> NSImage? {
    let standardizedURL = url.standardizedFileURL
    let file = musicArtworkCacheKeyForFile(standardizedURL)
    let size = DisplayArtworkSize.maxPixelSize
    if let name = EmbeddedCoverNames.shared.name(forFile: file),
       let cached = cachedDecodedDisplayArtworkImage(sourceKey: name, maxPixelSize: size)
    {
        return cached
    }
    guard let data = await loadEmbeddedArtworkData(from: standardizedURL) else { return nil }
    let name = EmbeddedCoverNames.name(for: data)
    EmbeddedCoverNames.shared.set(name, forFile: file)
    return cachedDecodedDisplayArtworkImage(from: data, sourceKey: name, maxPixelSize: size)
}
