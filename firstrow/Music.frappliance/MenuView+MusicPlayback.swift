import AVFoundation
import AVKit
import SwiftUI
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif
import Darwin

private let mediaTrackFlagsCache = BoundedCache<String, (hasVideo: Bool, hasAudio: Bool)>(maxEntryCount: 800)

extension MenuView {
    var standaloneAudioFileExtensions: Set<String> {
        ["aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "m4b", "mp3", "opus", "wav"]
    }

    func mediaTrackFlagsCacheKey(for mediaURL: URL) -> String {
        let normalizedURL = mediaURL.standardizedFileURL
        return normalizedURL.isFileURL ? normalizedURL.path : normalizedURL.absoluteString
    }

    func mediaTrackFlags(for mediaURL: URL) -> (hasVideo: Bool, hasAudio: Bool) {
        let cacheKey = mediaTrackFlagsCacheKey(for: mediaURL)
        if let cached = mediaTrackFlagsCache.value(for: cacheKey) {
            return cached
        }
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = BlockingResultBox<(hasVideo: Bool, hasAudio: Bool)>()
        Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: mediaURL)
            let videoTracks: [AVAssetTrack]
            let audioTracks: [AVAssetTrack]
            if #available(macOS 12.0, *) {
                videoTracks = await (try? asset.loadTracks(withMediaType: .video)) ?? []
                audioTracks = await (try? asset.loadTracks(withMediaType: .audio)) ?? []
            } else {
                videoTracks = asset.tracks(withMediaType: .video)
                audioTracks = asset.tracks(withMediaType: .audio)
            }
            resultBox.set((
                hasVideo: !videoTracks.isEmpty,
                hasAudio: !audioTracks.isEmpty,
            ))
            semaphore.signal()
        }
        semaphore.wait()
        let flags = resultBox.value() ?? (hasVideo: false, hasAudio: false)
        mediaTrackFlagsCache.store(flags, for: cacheKey)
        return flags
    }

    func shouldTreatAsAudioOnlyPlayback(url: URL) -> Bool {
        let extensionLowercased = url.pathExtension.lowercased()
        if standaloneAudioFileExtensions.contains(extensionLowercased) {
            return true
        }
        let flags = mediaTrackFlags(for: url)
        if flags.hasVideo {
            return false
        }
        return flags.hasAudio
    }

    func startAudioOnlyPlayback(
        from mediaURL: URL,
        title: String,
        artist: String,
        album: String,
        artwork: NSImage?,
        playbackID: String? = nil,
        trackIndex: Int = 0,
        trackCount: Int = 1,
        showsTrackPosition: Bool = false,
        presentsFullscreen: Bool = true,
    ) {
        let resolvedPlaybackID = playbackID ?? "audio::\(mediaURL.path)"
        let pseudoSong = MusicLibrarySongEntry(
            id: resolvedPlaybackID,
            title: title,
            artist: artist,
            album: album,
            genre: "Audio",
            composer: "",
            durationSeconds: 0,
            trackNumber: 0,
            discNumber: 1,
            artworkAlbumKey: nil,
            url: mediaURL,
            artwork: artwork,
        )
        startMusicPlayback(
            from: pseudoSong,
            trackIndex: trackIndex,
            trackCount: trackCount,
            presentsFullscreen: presentsFullscreen,
        )
        if !showsTrackPosition {
            musicNowPlayingTrackPositionText = ""
        }
        musicNowPlayingShowsShuffleGlyph = false
    }

    func startPlaybackForMusicLibraryEntry(
        _ song: MusicLibrarySongEntry,
        trackIndex: Int,
        trackCount: Int,
        presentsFullscreen: Bool = true,
        playbackQueue: [MusicLibrarySongEntry]? = nil,
    ) {
        if let mediaURL = song.url?.standardizedFileURL,
           activeMusicLibraryMediaType == .musicVideos,
           !shouldTreatAsAudioOnlyPlayback(url: mediaURL)
        {
            startMoviePlayback(from: mediaURL)
            return
        }
        startMusicPlayback(
            from: song,
            trackIndex: trackIndex,
            trackCount: trackCount,
            presentsFullscreen: presentsFullscreen,
            playbackQueue: playbackQueue,
        )
    }

    func updateNowPlayingArtworkIfNeeded(for song: MusicLibrarySongEntry, requestID: Int) {
        guard song.artwork == nil else { return }
        guard let cacheKey = musicArtworkCacheKey(for: song) else { return }
        if let cachedArtwork = musicPreviewCache[cacheKey] {
            withAnimation(.easeInOut(duration: 0.18)) {
                musicNowPlayingArtwork = cachedArtwork
            }
            return
        }
        let activeSongID = song.id
        Task.detached(priority: .userInitiated) {
            let resolvedArtwork = await self.resolveMusicArtworkImage(
                for: song,
                cacheKey: cacheKey,
            )
            guard let resolvedArtwork else { return }
            let shouldContinue = await MainActor.run {
                self.musicNowPlayingArtworkRequestID == requestID &&
                    self.activeMusicPlaybackSongID == activeSongID
            }
            guard shouldContinue else { return }
            await MainActor.run {
                guard self.musicNowPlayingArtworkRequestID == requestID else { return }
                self.musicPreviewCache[cacheKey] = resolvedArtwork
                guard self.activeMusicPlaybackSongID == activeSongID else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    self.musicNowPlayingArtwork = resolvedArtwork
                }
            }
        }
    }

    func resolvedActiveMusicPlaybackQueue() -> [MusicLibrarySongEntry] {
        if !activeMusicPlaybackQueue.isEmpty {
            return activeMusicPlaybackQueue
        }
        return musicSongsThirdMenuItems
    }

    func prefetchMusicArtworkIfNeeded(for song: MusicLibrarySongEntry) {
        guard song.artwork == nil else { return }
        guard let cacheKey = musicArtworkCacheKey(for: song) else { return }
        guard musicPreviewCache[cacheKey] == nil else { return }
        guard musicArtworkPrefetchInFlightKeys.insert(cacheKey).inserted else { return }
        Task.detached(priority: .utility) {
            let resolvedArtwork = await self.resolveMusicArtworkImage(
                for: song,
                cacheKey: cacheKey,
            )
            await MainActor.run {
                self.musicArtworkPrefetchInFlightKeys.remove(cacheKey)
                guard let resolvedArtwork else { return }
                if self.musicPreviewCache[cacheKey] == nil {
                    self.musicPreviewCache[cacheKey] = resolvedArtwork
                }
            }
        }
    }

    func prefetchMusicArtworkAroundTrackIndex(
        _ trackIndex: Int,
        activeSongID: String,
        lookbehindCount: Int = 1,
        lookaheadCount: Int = 1,
    ) {
        guard lookbehindCount > 0 || lookaheadCount > 0 else { return }
        let playbackQueue = resolvedActiveMusicPlaybackQueue()
        guard playbackQueue.indices.contains(trackIndex) else { return }
        guard playbackQueue[trackIndex].id == activeSongID else { return }
        var songsToPrefetch: [MusicLibrarySongEntry] = []
        if lookbehindCount > 0 {
            let lowerBound = max(0, trackIndex - lookbehindCount)
            songsToPrefetch.append(contentsOf: playbackQueue[lowerBound ..< trackIndex])
        }
        if lookaheadCount > 0 {
            let upperBound = min(playbackQueue.count, trackIndex + lookaheadCount + 1)
            songsToPrefetch.append(contentsOf: playbackQueue[(trackIndex + 1) ..< upperBound])
        }
        for song in songsToPrefetch {
            prefetchMusicArtworkIfNeeded(for: song)
        }
    }

    func loadMusicLibraryArtworkData(for song: MusicLibrarySongEntry) -> Data? {
        if let cachedArtworkData = cachedMusicLibraryArtworkData(for: song) {
            return cachedArtworkData
        }
        #if canImport(iTunesLibrary)
            return resolvedMusicLibraryArtworkDataFromITLibrary(for: song)
        #else
            return nil
        #endif
    }

    func hasActiveMusicPlaybackSession() -> Bool {
        if musicAudioPlayer != nil {
            return true
        }
        return activeMusicPlaybackSongID != nil
    }

    func isMusicPlaybackRunning() -> Bool {
        if let musicAudioPlayer {
            return musicAudioPlayer.rate > 0.01
        }
        if isCurrentMusicPlaybackUsingAppleScript {
            return musicAppleScriptIsPlaying && activeMusicPlaybackSongID != nil
        }
        return false
    }

    func startMusicPlayback(
        from song: MusicLibrarySongEntry,
        trackIndex: Int,
        trackCount: Int,
        presentsFullscreen: Bool = true,
        resetTransitionState: Bool = true,
        usingExistingBlackout: Bool = false,
        playbackQueue: [MusicLibrarySongEntry]? = nil,
    ) {
        guard !isMovieTransitioning, !isMoviePlaybackVisible else { return }
        if resetTransitionState {
            clearMusicSongSwitchTransitionState()
        }
        let willUseAppleScriptPlayback = song.prefersSystemMusicPlayerPlayback || song.url == nil
        let hadActiveSession = hasActiveMusicPlaybackSession()
        stopMusicPlaybackSession(
            clearDisplayState: false,
            pauseSystemMusicPlayback: !(isCurrentMusicPlaybackUsingAppleScript && willUseAppleScriptPlayback),
        )
        if !hadActiveSession {
            resetMusicNowPlayingFlipState()
        }
        if let playbackQueue {
            activeMusicPlaybackQueue = playbackQueue
        }
        isCurrentMusicPlaybackManagedByFirstRow = true
        hasPendingExternalMusicRestore = false
        let playbackRequestID = incrementRequestID(&musicPlaybackRequestID)
        let performPlayback: () -> Void
        if song.prefersSystemMusicPlayerPlayback || song.url == nil {
            performPlayback = {
                self.startMusicPlaybackViaAppleScript(song, playbackRequestID: playbackRequestID)
            }
        } else if let songURL = song.url?.standardizedFileURL {
            performPlayback = {
                let player = AVPlayer(url: songURL)
                player.automaticallyWaitsToMinimizeStalling = false
                self.configureMusicPlaybackObservation(for: player)
                self.musicAudioPlayer = player
                player.playImmediately(atRate: 1.0)
            }
        } else {
            return
        }
        isCurrentMusicPlaybackUsingAppleScript = false
        musicAppleScriptCurrentTrackPersistentIDHex = nil
        musicAppleScriptDidHandleTrackBoundary = false
        let resolvedTrackCount = playbackQueue?.count ?? trackCount
        musicNowPlayingTrackPositionText = resolvedTrackCount > 0 ? "\(trackIndex + 1) of \(resolvedTrackCount)" : ""
        musicNowPlayingTitle = song.title
        musicNowPlayingArtist = song.artist
        musicNowPlayingAlbum = song.album
        musicNowPlayingArtwork = song.artwork ?? musicFallbackImage
        musicNowPlayingElapsedSeconds = 0
        musicNowPlayingDurationSeconds = max(0, song.durationSeconds)
        musicNowPlayingShowsShuffleGlyph = isMusicSongsShuffleMode
        musicNowPlayingLeadingGlyphState = nil
        activeMusicPlaybackSongID = song.id
        let artworkRequestID = incrementRequestID(&musicNowPlayingArtworkRequestID)
        updateNowPlayingArtworkIfNeeded(for: song, requestID: artworkRequestID)
        prefetchMusicArtworkAroundTrackIndex(
            trackIndex,
            activeSongID: song.id,
        )
        if presentsFullscreen {
            enterMusicNowPlayingPage(usingExistingBlackout: usingExistingBlackout)
        }
        performPlayback()
        updateMusicNowPlayingFlipTimerState()
        triggerScreenSaverNowPlayingToastIfNeeded()
    }

    #if os(macOS)
        struct MusicAppleScriptPlaybackStatus: Sendable {
            let persistentIDHex: String?
            let elapsedSeconds: Double
            let durationSeconds: Double
            let isPlaying: Bool
        }

        struct MusicAppleScriptTrackStartResult: Sendable {
            let persistentIDHex: String
            let didBeginPlayback: Bool
        }

        struct MusicSystemPlayerSnapshot: Sendable {
            let persistentIDHex: String?
            let persistentIDDecimalString: String?
            let title: String
            let artist: String
            let album: String
            let elapsedSeconds: Double
            let durationSeconds: Double
            let isPlaying: Bool
            let isStopped: Bool
        }

        static func musicPersistentIDHexString(forDecimalString decimalString: String) -> String? {
            guard let decimalID = UInt64(decimalString) else { return nil }
            return String(format: "%016llX", decimalID)
        }

        static func musicPersistentIDDecimalString(forHexString hexString: String) -> String? {
            guard let decimalID = UInt64(hexString, radix: 16) else { return nil }
            return String(decimalID)
        }

        func updateMusicAppleScriptProgressAnchor(
            elapsedSeconds: Double,
            isPlaying: Bool,
        ) {
            musicAppleScriptProgressAnchorElapsedSeconds = max(0, elapsedSeconds)
            musicAppleScriptProgressAnchorDate = isPlaying ? Date() : nil
        }

        func startMusicPlaybackViaAppleScript(_ song: MusicLibrarySongEntry, playbackRequestID: Int) {
            isCurrentMusicPlaybackUsingAppleScript = true
            isCurrentMusicPlaybackManagedByFirstRow = true
            musicAppleScriptIsPlaying = false
            musicAppleScriptStartupDeadline = nil
            updateMusicAppleScriptProgressAnchor(
                elapsedSeconds: 0,
                isPlaying: false,
            )
            musicAppleScriptCurrentTrackPersistentIDHex = nil
            musicAppleScriptDidHandleTrackBoundary = false
            let expectedSongID = song.id
            Task(priority: .userInitiated) {
                let trackStartResult = await musicAppleScriptExecutor.run {
                    self.playMusicTrackViaAppleScript(song: song)
                }
                await MainActor.run {
                    guard self.musicPlaybackRequestID == playbackRequestID else { return }
                    guard self.activeMusicPlaybackSongID == expectedSongID else { return }
                    guard self.isCurrentMusicPlaybackUsingAppleScript else { return }
                    if let trackStartResult {
                        self.musicAppleScriptCurrentTrackPersistentIDHex = trackStartResult.persistentIDHex
                        self.musicAppleScriptIsPlaying = trackStartResult.didBeginPlayback
                        self.musicAppleScriptStartupDeadline = trackStartResult.didBeginPlayback
                            ? Date().addingTimeInterval(2.0)
                            : nil
                        self.updateMusicAppleScriptProgressAnchor(
                            elapsedSeconds: 0,
                            isPlaying: trackStartResult.didBeginPlayback,
                        )
                        self.startMusicAppleScriptProgressTimerIfNeeded()
                    } else {
                        self.isCurrentMusicPlaybackUsingAppleScript = false
                        self.isCurrentMusicPlaybackManagedByFirstRow = false
                        self.musicAppleScriptIsPlaying = false
                        self.musicAppleScriptStartupDeadline = nil
                        self.updateMusicAppleScriptProgressAnchor(
                            elapsedSeconds: 0,
                            isPlaying: false,
                        )
                        self.musicAppleScriptCurrentTrackPersistentIDHex = nil
                        self.musicAppleScriptDidHandleTrackBoundary = false
                        self.stopMusicAppleScriptProgressTimer()
                        self.updateMusicNowPlayingFlipTimerState()
                    }
                }
            }
        }

        func handleMusicAppleScriptTrackBoundary() {
            guard isCurrentMusicPlaybackUsingAppleScript else { return }
            guard isCurrentMusicPlaybackManagedByFirstRow else { return }
            guard !musicAppleScriptDidHandleTrackBoundary else { return }
            musicAppleScriptDidHandleTrackBoundary = true
            stopMusicScrubbing(showPauseGlyph: false)
            musicNowPlayingLeadingGlyphState = nil
            let playbackQueue = resolvedActiveMusicPlaybackQueue()
            if let currentIndex = activeMusicPlaybackIndex(),
               (currentIndex + 1) < playbackQueue.count
            {
                switchMusicNowPlayingTrack(direction: 1)
            } else if activeFullscreenScene?.key == musicNowPlayingFullscreenKey {
                dismissFullscreenScene()
            } else {
                stopMusicPlaybackSession(clearDisplayState: false)
            }
        }

        /// Apple Music cloud tracks have no local URL and can't be played via AVFoundation.
        /// Delegate to Music.app via AppleScript using the track's persistent ID (stored as
        /// a decimal string in song.id; AppleScript needs 16-char uppercase hex).
        func playMusicTrackViaAppleScript(song: MusicLibrarySongEntry) -> MusicAppleScriptTrackStartResult? {
            guard let hexID = Self.musicPersistentIDHexString(forDecimalString: song.id) else {
                return nil
            }
            let sourcePlaylistLookupScript: String
            if let sourcePlaylistPersistentIDHex = song.sourcePlaylistPersistentIDHex,
               !sourcePlaylistPersistentIDHex.isEmpty
            {
                sourcePlaylistLookupScript = """
                    if (count of matchedTracks) is 0 then
                        repeat with playlistRef in every playlist
                            try
                                if (persistent ID of playlistRef) is "\(sourcePlaylistPersistentIDHex)" then
                                    set matchedTracks to (every track of playlistRef whose persistent ID is "\(hexID)")
                                    exit repeat
                                end if
                            end try
                        end repeat
                    end if
                """
            } else {
                sourcePlaylistLookupScript = ""
            }
            let source = """
            tell application "\(musicApplicationName)"
                if not running then
                    return "NOT_RUNNING"
                end if
                set matchedTracks to {}
                try
                    set matchedTracks to (every track of library playlist 1 whose persistent ID is "\(hexID)")
                end try
            \(sourcePlaylistLookupScript)
                if (count of matchedTracks) is 0 then
                    repeat with playlistRef in every playlist
                        try
                            set playlistMatches to (every track of playlistRef whose persistent ID is "\(hexID)")
                            if (count of playlistMatches) > 0 then
                                set matchedTracks to playlistMatches
                                exit repeat
                            end if
                        end try
                    end repeat
                end if
                if (count of matchedTracks) is 0 then
                    return "NOT_FOUND"
                end if
                set targetTrack to item 1 of matchedTracks
                set resolvedPersistentID to ""
                try
                    set resolvedPersistentID to (persistent ID of targetTrack)
                end try
                set didConfirmPlayback to false
                try
                    play targetTrack
                end try
                repeat 18 times
                    delay 0.15
                    set currentPersistentID to ""
                    try
                        set currentPersistentID to (persistent ID of current track)
                    end try
                    set playerStateText to ""
                    try
                        set playerStateText to (player state as text)
                    end try
                    if resolvedPersistentID is "" and currentPersistentID is not "" then
                        set resolvedPersistentID to currentPersistentID
                    end if
                    if resolvedPersistentID is not "" and currentPersistentID is resolvedPersistentID and playerStateText is "playing" then
                        set didConfirmPlayback to true
                        exit repeat
                    end if
                    if currentPersistentID is "" or resolvedPersistentID is "" or currentPersistentID is resolvedPersistentID then
                        try
                            play targetTrack
                        end try
                    end if
                end repeat
                if resolvedPersistentID is "" then
                    try
                        set resolvedPersistentID to (persistent ID of current track)
                    end try
                end if
                if didConfirmPlayback then
                    return "STARTED" & linefeed & resolvedPersistentID
                end if
                if resolvedPersistentID is not "" then
                    return "SELECTED" & linefeed & resolvedPersistentID
                end if
                return "NOT_FOUND"
            end tell
            """
            let result = executeMusicApplicationAppleScript(
                source,
                launchIfNeeded: true,
                retryCount: 24,
            )
            if !result.succeeded {
                print("[AppleScript] playback error: \(result.combinedFailureDescription)")
                return nil
            }
            let parts = result.trimmedStandardOutput
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard let status = parts.first else {
                return nil
            }
            let didBeginPlayback: Bool
            switch status {
            case "STARTED":
                didBeginPlayback = true
            case "SELECTED":
                didBeginPlayback = false
            default:
                return nil
            }
            return MusicAppleScriptTrackStartResult(
                persistentIDHex: parts.dropFirst().first?.uppercased() ?? hexID,
                didBeginPlayback: didBeginPlayback,
            )
        }

        @discardableResult
        func pauseMusicPlaybackViaAppleScript() -> Bool {
            let source = """
            tell application "\(musicApplicationName)"
                if not running then
                    return "NOT_RUNNING"
                end if
                if player state is playing then
                    pause
                end if
                return "OK"
            end tell
            """
            let result = executeAppleScript(source)
            if !result.succeeded {
                print("[AppleScript] pause error: \(result.combinedFailureDescription)")
                return false
            }
            return true
        }

        @discardableResult
        func resumeMusicPlaybackViaAppleScript() -> Bool {
            let source = """
            tell application "\(musicApplicationName)"
                if not running then
                    return "NOT_RUNNING"
                end if
                play
                return "OK"
            end tell
            """
            let result = executeMusicApplicationAppleScript(
                source,
                launchIfNeeded: true,
                retryCount: 24,
            )
            if !result.succeeded {
                print("[AppleScript] play error: \(result.combinedFailureDescription)")
                return false
            }
            return true
        }

        func seekMusicPlaybackViaAppleScript(direction: Int, isRepeat: Bool) {
            guard direction != 0 else { return }
            guard activeMusicPlaybackSongID != nil else { return }
            let stepSeconds: Double = isRepeat ? 16 : 10
            let currentTime = max(0, musicNowPlayingElapsedSeconds)
            var target = currentTime + (Double(direction) * stepSeconds)
            if musicNowPlayingDurationSeconds > 0 {
                target = min(max(0, target), musicNowPlayingDurationSeconds)
            } else {
                target = max(0, target)
            }
            musicNowPlayingElapsedSeconds = target
            musicNowPlayingLeadingGlyphState = direction > 0 ? .fastForward(1) : .rewind(1)
            musicAppleScriptIsPlaying = false
            updateMusicAppleScriptProgressAnchor(elapsedSeconds: target, isPlaying: false)
            updateMusicNowPlayingFlipTimerState()
            musicKitScrubGlyphResetWorkItem?.cancel()
            musicKitScrubGlyphResetWorkItem = Task {
                try? await firstRowSleep(0.22)
                guard !Task.isCancelled else { return }
                self.musicNowPlayingLeadingGlyphState = .pause
            }
            Task(priority: .utility) {
                let source = """
                tell application "\(musicApplicationName)"
                    if not running then
                        return "NOT_RUNNING"
                    end if
                    set player position to \(target)
                    if player state is playing then
                        pause
                    end if
                    return "OK"
                end tell
                """
                let result = await musicAppleScriptExecutor.run {
                    executeMusicApplicationAppleScript(
                        source,
                        retryCount: 6,
                    )
                }
                if !result.succeeded, !appleScriptFailedBecauseApplicationIsNotRunning(result) {
                    print("[AppleScript] seek error: \(result.combinedFailureDescription)")
                }
            }
        }

        func startMusicAppleScriptProgressTimerIfNeeded() {
            if musicAppleScriptProgressTimer == nil {
                let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
                    self.refreshMusicPlaybackViaAppleScriptIfNeeded()
                }
                RunLoop.main.add(timer, forMode: .common)
                musicAppleScriptProgressTimer = timer
            }
            refreshMusicPlaybackViaAppleScriptIfNeeded()
        }

        func stopMusicAppleScriptProgressTimer() {
            musicAppleScriptProgressTimer?.invalidate()
            musicAppleScriptProgressTimer = nil
            musicAppleScriptProgressRequestInFlight = false
            musicAppleScriptLastSyncDate = nil
            musicAppleScriptStartupDeadline = nil
            musicAppleScriptProgressAnchorDate = nil
        }

        func refreshMusicPlaybackViaAppleScriptIfNeeded() {
            guard isCurrentMusicPlaybackUsingAppleScript else { return }
            if musicScrubDirection == 0,
               musicAppleScriptIsPlaying,
               let progressAnchorDate = musicAppleScriptProgressAnchorDate
            {
                let elapsedSeconds = musicAppleScriptProgressAnchorElapsedSeconds
                    + Date().timeIntervalSince(progressAnchorDate)
                if musicNowPlayingDurationSeconds > 0 {
                    musicNowPlayingElapsedSeconds = min(
                        musicNowPlayingDurationSeconds,
                        max(0, elapsedSeconds),
                    )
                } else {
                    musicNowPlayingElapsedSeconds = max(0, elapsedSeconds)
                }
            }

            let isNowPlayingVisible = activeFullscreenScene?.key == musicNowPlayingFullscreenKey
            let timeSinceLastSync = musicAppleScriptLastSyncDate.map { Date().timeIntervalSince($0) } ?? .infinity
            if !musicAppleScriptProgressRequestInFlight,
               timeSinceLastSync > 1.0,
               isNowPlayingVisible,
               musicScrubDirection == 0,
               musicAppleScriptIsPlaying || hasActiveMusicPlaybackSession()
            {
                let syncRequestID = musicPlaybackRequestID
                musicAppleScriptLastSyncDate = Date()
                musicAppleScriptProgressRequestInFlight = true
                Task(priority: .utility) {
                    let snapshot = await musicAppleScriptExecutor.run {
                        Self.queryMusicSystemPlayerSnapshotViaAppleScript()
                    }
                    await MainActor.run {
                        self.musicAppleScriptProgressRequestInFlight = false
                        guard let snapshot else { return }
                        guard self.musicScrubDirection == 0 else { return }
                        guard self.musicPlaybackRequestID == syncRequestID else { return }
                        self.applyMusicSystemPlayerSnapshot(snapshot, allowSessionRestore: false)
                    }
                }
            }
            updateMusicNowPlayingFlipTimerState()
        }

        func installMusicSystemPlayerObserversIfNeeded() {
            guard musicSystemPlayerObserverTokens.isEmpty else { return }
            let distributedCenter = DistributedNotificationCenter.default()
            let notificationNames = [
                Notification.Name("com.apple.Music.playerInfo"),
                Notification.Name("com.apple.iTunes.playerInfo"),
            ]
            musicSystemPlayerObserverTokens = notificationNames.map { notificationName in
                distributedCenter.addObserver(
                    forName: notificationName,
                    object: nil,
                    queue: .main,
                ) { notification in
                    self.handleMusicSystemPlayerInfoNotification(notification)
                }
            }
        }

        func uninstallMusicSystemPlayerObservers() {
            guard !musicSystemPlayerObserverTokens.isEmpty else { return }
            let distributedCenter = DistributedNotificationCenter.default()
            for observerToken in musicSystemPlayerObserverTokens {
                distributedCenter.removeObserver(observerToken)
            }
            musicSystemPlayerObserverTokens.removeAll()
        }

        func handleMusicSystemPlayerInfoNotification(_ notification: Notification) {
            guard let snapshot = Self.musicSystemPlayerSnapshot(from: notification.userInfo) else { return }
            applyMusicSystemPlayerSnapshot(snapshot, allowSessionRestore: true)
        }

        func requestMusicSystemPlayerSnapshotForRestoreIfNeeded(force: Bool) {
            if !force, hasActiveMusicPlaybackSession() {
                return
            }
            let expectedRequestID = musicPlaybackRequestID
            Task(priority: .utility) {
                let snapshot = await musicAppleScriptExecutor.run {
                    Self.queryMusicSystemPlayerSnapshotViaAppleScript()
                }
                await MainActor.run {
                    guard self.musicPlaybackRequestID == expectedRequestID else { return }
                    guard let snapshot else { return }
                    self.applyMusicSystemPlayerSnapshot(snapshot, allowSessionRestore: true)
                }
            }
        }

        func applyMusicSystemPlayerSnapshot(
            _ snapshot: MusicSystemPlayerSnapshot,
            allowSessionRestore: Bool,
        ) {
            if snapshot.isStopped || snapshot.persistentIDHex == nil {
                hasPendingExternalMusicRestore = false
                if isCurrentMusicPlaybackUsingAppleScript, isCurrentMusicPlaybackManagedByFirstRow {
                    let endToleranceSeconds = min(2.0, max(0.35, musicNowPlayingDurationSeconds * 0.02))
                    if musicNowPlayingDurationSeconds > 0 &&
                        musicNowPlayingElapsedSeconds >= (musicNowPlayingDurationSeconds - endToleranceSeconds)
                    {
                        handleMusicAppleScriptTrackBoundary()
                        return
                    }
                }
                musicAppleScriptIsPlaying = false
                updateMusicAppleScriptProgressAnchor(
                    elapsedSeconds: musicNowPlayingElapsedSeconds,
                    isPlaying: false,
                )
                if isCurrentMusicPlaybackUsingAppleScript, !isCurrentMusicPlaybackManagedByFirstRow {
                    stopMusicPlaybackSession(
                        clearDisplayState: false,
                        preserveSystemMusicPlayback: true,
                    )
                    return
                }
                updateMusicNowPlayingFlipTimerState()
                return
            }

            if isCurrentMusicPlaybackUsingAppleScript,
               isCurrentMusicPlaybackManagedByFirstRow,
               let expectedPersistentIDHex = musicAppleScriptCurrentTrackPersistentIDHex,
               let currentPersistentIDHex = snapshot.persistentIDHex,
               expectedPersistentIDHex != currentPersistentIDHex
            {
                handleMusicAppleScriptTrackBoundary()
                return
            }

            if allowSessionRestore &&
                (!hasActiveMusicPlaybackSession() || !isCurrentMusicPlaybackManagedByFirstRow)
            {
                restoreMusicPlaybackSessionFromSystemSnapshot(snapshot)
                return
            }

            hasPendingExternalMusicRestore = false
            if let persistentIDHex = snapshot.persistentIDHex {
                musicAppleScriptCurrentTrackPersistentIDHex = persistentIDHex
            }
            if activeMusicPlaybackSongID == nil,
               let persistentIDDecimalString = snapshot.persistentIDDecimalString
            {
                activeMusicPlaybackSongID = persistentIDDecimalString
            }

            let isGraceActive = (musicAppleScriptStartupDeadline.map { $0 > Date() } ?? false) && !snapshot.isPlaying
            let effectiveIsPlaying = isGraceActive ? musicAppleScriptIsPlaying : snapshot.isPlaying
            
            if musicScrubDirection == 0 {
                musicAppleScriptIsPlaying = effectiveIsPlaying
                musicAppleScriptStartupDeadline = isGraceActive ? musicAppleScriptStartupDeadline : nil
                let snapshotElapsed = max(0, snapshot.elapsedSeconds)
                musicNowPlayingElapsedSeconds = snapshotElapsed
                updateMusicAppleScriptProgressAnchor(
                    elapsedSeconds: snapshotElapsed,
                    isPlaying: isGraceActive ? false : effectiveIsPlaying,
                )
                musicNowPlayingLeadingGlyphState = effectiveIsPlaying ? nil : .pause
            }
            if snapshot.durationSeconds > 0 {
                musicNowPlayingDurationSeconds = snapshot.durationSeconds
            }
            if !snapshot.title.isEmpty {
                musicNowPlayingTitle = snapshot.title
            }
            if !snapshot.artist.isEmpty {
                musicNowPlayingArtist = snapshot.artist
            }
            if !snapshot.album.isEmpty {
                musicNowPlayingAlbum = snapshot.album
            }
            musicAppleScriptDidHandleTrackBoundary = false
            startMusicAppleScriptProgressTimerIfNeeded()
            updateMusicNowPlayingFlipTimerState()
        }

        func restoreMusicPlaybackSessionFromSystemSnapshot(_ snapshot: MusicSystemPlayerSnapshot) {
            guard let persistentIDDecimalString = snapshot.persistentIDDecimalString else { return }
            isCurrentMusicPlaybackUsingAppleScript = true
            isCurrentMusicPlaybackManagedByFirstRow = false
            hasPendingExternalMusicRestore = false
            activeMusicPlaybackQueue = []
            activeMusicPlaybackSongID = persistentIDDecimalString
            musicAppleScriptCurrentTrackPersistentIDHex = snapshot.persistentIDHex
            musicAppleScriptIsPlaying = snapshot.isPlaying
            musicAppleScriptStartupDeadline = nil
            musicAppleScriptDidHandleTrackBoundary = false
            musicNowPlayingTitle = snapshot.title.isEmpty ? musicNowPlayingTitle : snapshot.title
            musicNowPlayingArtist = snapshot.artist.isEmpty ? musicNowPlayingArtist : snapshot.artist
            musicNowPlayingAlbum = snapshot.album
            musicNowPlayingTrackPositionText = ""
            musicNowPlayingElapsedSeconds = max(0, snapshot.elapsedSeconds)
            musicNowPlayingDurationSeconds = max(0, snapshot.durationSeconds)
            musicNowPlayingLeadingGlyphState = snapshot.isPlaying ? nil : .pause
            updateMusicAppleScriptProgressAnchor(
                elapsedSeconds: snapshot.elapsedSeconds,
                isPlaying: snapshot.isPlaying,
            )
            let placeholderSong = MusicLibrarySongEntry(
                id: persistentIDDecimalString,
                title: snapshot.title.isEmpty ? musicNowPlayingTitle : snapshot.title,
                artist: snapshot.artist.isEmpty ? musicNowPlayingArtist : snapshot.artist,
                album: snapshot.album.isEmpty ? musicNowPlayingAlbum : snapshot.album,
                genre: "Unknown Genre",
                composer: "Unknown Composer",
                durationSeconds: max(0, snapshot.durationSeconds),
                trackNumber: 0,
                discNumber: 1,
                artworkAlbumKey: normalizedMusicTopLevelCarouselAlbumKey(
                    albumTitle: snapshot.album,
                    albumArtist: snapshot.artist,
                    persistentAlbumID: nil,
                    fallbackItemID: persistentIDDecimalString,
                ),
                url: nil,
                artwork: nil,
                prefersSystemMusicPlayerPlayback: true,
            )
            let artworkLookupSong = matchingMusicLibrarySongEntry(
                persistentIDDecimalString: persistentIDDecimalString,
                title: snapshot.title,
                artist: snapshot.artist,
                album: snapshot.album,
            ) ?? placeholderSong
            musicNowPlayingArtwork = artworkLookupSong.artwork ?? musicFallbackImage
            let artworkRequestID = incrementRequestID(&musicNowPlayingArtworkRequestID)
            updateNowPlayingArtworkIfNeeded(for: artworkLookupSong, requestID: artworkRequestID)
            startMusicAppleScriptProgressTimerIfNeeded()
            updateMusicNowPlayingFlipTimerState()
        }

        func matchingMusicLibrarySongEntry(
            persistentIDDecimalString: String,
            title: String,
            artist: String,
            album: String,
        ) -> MusicLibrarySongEntry? {
            let candidatePools: [[MusicLibrarySongEntry]] = [
                activeMusicPlaybackQueue,
                musicSongsThirdMenuItems,
                musicAllSongsCache ?? [],
                musicShuffleSongsCache ?? [],
            ]
            for candidatePool in candidatePools {
                if let matchedByID = candidatePool.first(where: { $0.id == persistentIDDecimalString }) {
                    return matchedByID
                }
            }
            for candidatePool in candidatePools {
                if let fuzzyMatch = candidatePool.first(where: {
                    $0.title == title && $0.artist == artist && $0.album == album
                }) {
                    return fuzzyMatch
                }
            }
            return nil
        }

        static func musicSystemPlayerSnapshot(from userInfo: [AnyHashable: Any]?) -> MusicSystemPlayerSnapshot? {
            guard let userInfo else { return nil }
            func stringValue(_ key: String) -> String {
                (userInfo[key] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            func secondsValue(_ key: String, treatsLargeValuesAsMilliseconds: Bool) -> Double {
                if let number = userInfo[key] as? NSNumber {
                    let rawValue = number.doubleValue
                    if treatsLargeValuesAsMilliseconds, rawValue > 1000 {
                        return max(0, rawValue / 1000.0)
                    }
                    return max(0, rawValue)
                }
                return 0
            }
            let playerStateText = stringValue("Player State").lowercased()
            let persistentIDHex = stringValue("PersistentID").uppercased()
            let resolvedPersistentIDHex = persistentIDHex.isEmpty ? nil : persistentIDHex
            let isStopped = playerStateText == "stopped" || resolvedPersistentIDHex == nil
            let isPlaying = playerStateText == "playing" ||
                playerStateText == "fast forwarding" ||
                playerStateText == "rewinding"
            return MusicSystemPlayerSnapshot(
                persistentIDHex: resolvedPersistentIDHex,
                persistentIDDecimalString: resolvedPersistentIDHex.flatMap(Self.musicPersistentIDDecimalString(forHexString:)),
                title: stringValue("Name"),
                artist: stringValue("Artist"),
                album: stringValue("Album"),
                elapsedSeconds: secondsValue("Player Position", treatsLargeValuesAsMilliseconds: false),
                durationSeconds: secondsValue("Total Time", treatsLargeValuesAsMilliseconds: true),
                isPlaying: isPlaying,
                isStopped: isStopped,
            )
        }

        static func queryMusicSystemPlayerSnapshotViaAppleScript() -> MusicSystemPlayerSnapshot? {
            let separator = "ASCII character 31"
            let source = """
            tell application "\(musicApplicationName)"
                if not running then
                    return "NOT_RUNNING"
                end if
                set playerStateText to (player state as text)
                if playerStateText is "stopped" then
                    return "STOPPED"
                end if
                set currentTrackRef to missing value
                try
                    set currentTrackRef to current track
                end try
                if currentTrackRef is missing value then
                    return "STOPPED"
                end if
                set currentPersistentID to ""
                set trackTitle to ""
                set trackArtist to ""
                set trackAlbum to ""
                set elapsedMilliseconds to 0
                set durationMilliseconds to 0
                try
                    set currentPersistentID to (persistent ID of currentTrackRef)
                end try
                try
                    set trackTitle to (name of currentTrackRef)
                end try
                try
                    set trackArtist to (artist of currentTrackRef)
                end try
                try
                    set trackAlbum to (album of currentTrackRef)
                end try
                try
                    set elapsedSecondsValue to (player position)
                    if elapsedSecondsValue is not missing value then
                        set elapsedMilliseconds to (round ((elapsedSecondsValue as real) * 1000))
                    end if
                end try
                try
                    set trackDurationSeconds to (duration of currentTrackRef)
                    if trackDurationSeconds is not missing value then
                        set durationMilliseconds to (round ((trackDurationSeconds as real) * 1000))
                    end if
                end try
                set AppleScript's text item delimiters to \(separator)
                set snapshotText to currentPersistentID & AppleScript's text item delimiters & trackTitle & AppleScript's text item delimiters & trackArtist & AppleScript's text item delimiters & trackAlbum & AppleScript's text item delimiters & elapsedMilliseconds & AppleScript's text item delimiters & durationMilliseconds & AppleScript's text item delimiters & playerStateText
                set AppleScript's text item delimiters to ""
                return snapshotText
            end tell
            """
            let result = executeMusicApplicationAppleScript(
                source,
                retryCount: 6,
            )
            if !result.succeeded {
                if !appleScriptFailedBecauseApplicationIsNotRunning(result) {
                    print("[AppleScript] restore error: \(result.combinedFailureDescription)")
                }
                return nil
            }
            let rawSnapshot = result.trimmedStandardOutput
            guard !rawSnapshot.isEmpty else { return nil }
            switch rawSnapshot {
            case "NOT_RUNNING", "STOPPED":
                return MusicSystemPlayerSnapshot(
                    persistentIDHex: nil,
                    persistentIDDecimalString: nil,
                    title: "",
                    artist: "",
                    album: "",
                    elapsedSeconds: 0,
                    durationSeconds: 0,
                    isPlaying: false,
                    isStopped: true,
                )
            default:
                break
            }
            let parts = rawSnapshot.components(separatedBy: String(UnicodeScalar(31)))
            guard parts.count >= 7 else { return nil }
            let persistentIDHex = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let elapsedMilliseconds = Double(parts[4]) ?? 0
            let durationMilliseconds = Double(parts[5]) ?? 0
            let playerStateText = parts[6].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let resolvedPersistentIDHex = persistentIDHex.isEmpty ? nil : persistentIDHex
            return MusicSystemPlayerSnapshot(
                persistentIDHex: resolvedPersistentIDHex,
                persistentIDDecimalString: resolvedPersistentIDHex.flatMap(Self.musicPersistentIDDecimalString(forHexString:)),
                title: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
                artist: parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
                album: parts[3].trimmingCharacters(in: .whitespacesAndNewlines),
                elapsedSeconds: max(0, elapsedMilliseconds / 1000.0),
                durationSeconds: max(0, durationMilliseconds / 1000.0),
                isPlaying: playerStateText == "playing",
                isStopped: playerStateText == "stopped" || resolvedPersistentIDHex == nil,
            )
        }

        static func queryMusicPlaybackViaAppleScriptStatus() -> MusicAppleScriptPlaybackStatus? {
            let source = """
            tell application "\(musicApplicationName)"
                if not running then
                    return "NOT_RUNNING"
                end if
                set playerStateText to (player state as text)
                if playerStateText is "stopped" then
                    return "STOPPED"
                end if
                set currentTrackRef to missing value
                set currentPersistentID to ""
                set durationMilliseconds to 0
                try
                    set currentTrackRef to current track
                end try
                if currentTrackRef is not missing value then
                    try
                        set currentPersistentID to (persistent ID of currentTrackRef)
                    end try
                    try
                        set trackDurationSeconds to (duration of currentTrackRef)
                        if trackDurationSeconds is not missing value then
                            set durationMilliseconds to (round ((trackDurationSeconds as real) * 1000))
                        end if
                    end try
                end if
                set elapsedMilliseconds to 0
                try
                    set elapsedSecondsValue to (player position)
                    if elapsedSecondsValue is not missing value then
                        set elapsedMilliseconds to (round ((elapsedSecondsValue as real) * 1000))
                    end if
                end try
                if currentPersistentID is "" and playerStateText is not "playing" then
                    return "STOPPED"
                end if
                return currentPersistentID & linefeed & elapsedMilliseconds & linefeed & durationMilliseconds & linefeed & playerStateText
            end tell
            """
            let result = executeMusicApplicationAppleScript(
                source,
                retryCount: 6,
            )
            if !result.succeeded {
                if !appleScriptFailedBecauseApplicationIsNotRunning(result) {
                    print("[AppleScript] progress error: \(result.combinedFailureDescription)")
                }
                return MusicAppleScriptPlaybackStatus(
                    persistentIDHex: nil,
                    elapsedSeconds: 0,
                    durationSeconds: 0,
                    isPlaying: false,
                )
            }
            let rawStatus = result.trimmedStandardOutput
            guard !rawStatus.isEmpty else {
                return nil
            }
            switch rawStatus {
            case "NOT_RUNNING", "STOPPED":
                return MusicAppleScriptPlaybackStatus(
                    persistentIDHex: nil,
                    elapsedSeconds: 0,
                    durationSeconds: 0,
                    isPlaying: false,
                )
            default:
                break
            }
            let parts = rawStatus
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count >= 4 else { return nil }
            let elapsedMilliseconds = Double(parts[1]) ?? 0
            let durationMilliseconds = Double(parts[2]) ?? 0
            let stateText = parts[3].lowercased()
            return MusicAppleScriptPlaybackStatus(
                persistentIDHex: parts[0].isEmpty ? nil : parts[0].uppercased(),
                elapsedSeconds: max(0, elapsedMilliseconds / 1000.0),
                durationSeconds: max(0, durationMilliseconds / 1000.0),
                isPlaying: stateText == "playing",
            )
        }
    #endif

    func configureMusicPlaybackObservation(for player: AVPlayer) {
        removeMusicPlaybackObservation()
        observedMusicAudioPlayer = player
        musicNowPlayingElapsedSeconds = max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
        musicNowPlayingDurationSeconds = resolvedMusicDurationSeconds(for: player)
        if let currentItem = player.currentItem {
            musicPlaybackDidEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main,
            ) { _ in
                guard self.observedMusicAudioPlayer === player else { return }
                let resolvedDuration = self.resolvedMusicDurationSeconds(for: player)
                self.musicNowPlayingDurationSeconds = max(self.musicNowPlayingDurationSeconds, resolvedDuration)
                self.musicNowPlayingElapsedSeconds = self.musicNowPlayingDurationSeconds
                self.stopMusicScrubbing(showPauseGlyph: false)
                self.musicNowPlayingLeadingGlyphState = nil
                if self.musicNowPlayingArtist == "iTunes Top Songs" {
                    if self.thirdMenuMode == .musicNowPlaying {
                        self.exitMusicNowPlayingPage()
                    } else {
                        self.dismissFullscreenScene()
                    }
                } else {
                    self.switchMusicNowPlayingTrack(direction: 1)
                }
            }
        }
        let interval = CMTime(seconds: 1.0 / 20.0, preferredTimescale: 600)
        musicTimeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let currentSeconds = max(0, time.seconds.isFinite ? time.seconds : 0)
            if self.musicScrubDirection == 0 {
                self.musicNowPlayingElapsedSeconds = currentSeconds
            }
            let durationSeconds = self.resolvedMusicDurationSeconds(for: player)
            if durationSeconds > 0 {
                self.musicNowPlayingDurationSeconds = durationSeconds
            }
        }
    }

    func removeMusicPlaybackObservation() {
        if let token = musicTimeObserverToken, let observedMusicAudioPlayer {
            observedMusicAudioPlayer.removeTimeObserver(token)
        }
        musicTimeObserverToken = nil
        if let musicPlaybackDidEndObserver {
            NotificationCenter.default.removeObserver(musicPlaybackDidEndObserver)
        }
        musicPlaybackDidEndObserver = nil
        observedMusicAudioPlayer = nil
    }

    func resolvedMusicDurationSeconds(for player: AVPlayer) -> Double {
        guard let currentItem = player.currentItem else { return 0 }
        let duration = currentItem.duration.seconds
        if duration.isFinite, duration > 0 {
            return duration
        }
        return 0
    }

    func stopMusicPlaybackSession(
        clearDisplayState: Bool = true,
        preserveSystemMusicPlayback: Bool = false,
        pauseSystemMusicPlayback: Bool = true,
    ) {
        stopMusicScrubbing(showPauseGlyph: false)
        cancelScreenSaverMusicTrackSwitchQueue()
        _ = incrementRequestID(&musicPlaybackRequestID)
        _ = incrementRequestID(&musicNowPlayingArtworkRequestID)
        musicAudioPlayer?.pause()
        #if os(macOS)
            stopMusicAppleScriptProgressTimer()
            if isCurrentMusicPlaybackUsingAppleScript,
               !preserveSystemMusicPlayback,
               pauseSystemMusicPlayback
            {
                Task(priority: .utility) {
                    _ = await musicAppleScriptExecutor.run {
                        self.pauseMusicPlaybackViaAppleScript()
                    }
                }
            }
            musicAppleScriptIsPlaying = false
            musicAppleScriptStartupDeadline = nil
            musicAppleScriptProgressAnchorDate = nil
            musicAppleScriptProgressAnchorElapsedSeconds = 0
            musicAppleScriptCurrentTrackPersistentIDHex = nil
            musicAppleScriptDidHandleTrackBoundary = false
        #endif
        removeMusicPlaybackObservation()
        musicAudioPlayer = nil
        isCurrentMusicPlaybackUsingAppleScript = false
        isCurrentMusicPlaybackManagedByFirstRow = false
        if preserveSystemMusicPlayback,
           activeMusicPlaybackSongID != nil
        {
            hasPendingExternalMusicRestore = true
        } else if !preserveSystemMusicPlayback {
            hasPendingExternalMusicRestore = false
        }
        removeCurrentMusicPlaybackTemporaryFileIfNeeded()
        activeMusicPlaybackQueue = []
        activeMusicPlaybackSongID = nil
        clearActivePodcastAudioPlaybackContext()
        if clearDisplayState {
            clearMusicNowPlayingDisplayState()
        }
    }

    func enterMusicNowPlayingPage(usingExistingBlackout: Bool = false) {
        guard isInSubmenu || isInThirdMenu else { return }
        guard thirdMenuMode != .musicNowPlaying else { return }
        let returnMode = isInThirdMenu ? thirdMenuMode : .none
        let returnHeader = headerText
        if usingExistingBlackout {
            isMenuFolderSwapTransitioning = false
            var instant = Transaction()
            instant.animation = nil
            withTransaction(instant) {
                musicNowPlayingReturnThirdMenuMode = returnMode
                musicNowPlayingReturnHeaderText = returnHeader
                deferNowPlayingMenuItemUntilAfterFadeOut = false
                headerText = "Now Playing"
                isInThirdMenu = true
                thirdMenuMode = .musicNowPlaying
                thirdMenuOpacity = 1
                submenuOpacity = 0
            }
            withAnimation(.easeInOut(duration: menuFolderSwapFadeDuration)) {
                menuFolderSwapOverlayOpacity = 0
            }
            return
        }
        transitionMenuForFolderSwap(direction: .forward) {
            musicNowPlayingReturnThirdMenuMode = returnMode
            musicNowPlayingReturnHeaderText = returnHeader
            headerText = "Now Playing"
            isInThirdMenu = true
            thirdMenuMode = .musicNowPlaying
            thirdMenuOpacity = 1
            submenuOpacity = 0
        }
    }

    func exitMusicNowPlayingPage() {
        stopMusicScrubbing(showPauseGlyph: false)
        let returnMode = musicNowPlayingReturnThirdMenuMode
        let returnHeader = musicNowPlayingReturnHeaderText
        transitionMenuForFolderSwap(direction: .backward) {
            if returnMode != .none {
                headerText = returnHeader.isEmpty ? rootMenuTitle(for: activeRootItemID) : returnHeader
                isInThirdMenu = true
                thirdMenuMode = returnMode
                thirdMenuOpacity = 1
                submenuOpacity = 0
            } else {
                headerText = rootMenuTitle(for: activeRootItemID)
                isInThirdMenu = false
                thirdMenuMode = .none
                thirdMenuOpacity = 0
                submenuOpacity = 1
                refreshDetailPreviewForCurrentContext()
            }
        }
    }

    func activeMusicPlaybackIndex() -> Int? {
        if let activeMusicPlaybackSongID,
           let index = activeMusicPlaybackQueue.firstIndex(where: { $0.id == activeMusicPlaybackSongID })
        {
            return index
        }
        if let activeMusicPlaybackSongID,
           let index = musicSongsThirdMenuItems.firstIndex(where: { $0.id == activeMusicPlaybackSongID })
        {
            return index
        }
        if let selectedSongIndex = musicSongIndex(forThirdMenuSelectionIndex: selectedThirdIndex) {
            return selectedSongIndex
        }
        if !musicSongsThirdMenuItems.isEmpty {
            return 0
        }
        return nil
    }

    func switchMusicNowPlayingTrack(direction: Int) {
        guard direction != 0 else { return }
        if activePodcastPlaybackEpisodeID != nil {
            let episodes = activePodcastPlaybackEpisodes()
            guard !episodes.isEmpty else { return }
            guard let currentEpisodeID = activePodcastPlaybackEpisodeID,
                  let currentIndex = episodes.firstIndex(where: { $0.id == currentEpisodeID })
            else {
                return
            }
            let targetIndex = max(0, min(episodes.count - 1, currentIndex + direction))
            guard targetIndex != currentIndex else { return }
            let targetEpisode = episodes[targetIndex]
            if isInThirdMenu,
               isPodcastEpisodesThirdMenuMode,
               activePodcastSeriesID == targetEpisode.seriesID
            {
                selectedThirdIndex = targetIndex
            }
            startPodcastEpisodeAudioPlayback(
                targetEpisode,
                trackIndex: targetIndex,
                trackCount: episodes.count,
                presentsFullscreen: false,
            )
            return
        }
        if thirdMenuMode == .musicITunesTopSongs || musicNowPlayingArtist == "iTunes Top Songs" {
            return
        }
        let playbackQueue = resolvedActiveMusicPlaybackQueue()
        guard !playbackQueue.isEmpty else { return }
        let fallbackIndex = direction > 0 ? -1 : playbackQueue.count
        let currentIndex = activeMusicPlaybackIndex() ?? fallbackIndex
        let targetIndex = max(0, min(playbackQueue.count - 1, currentIndex + direction))
        guard targetIndex != currentIndex else { return }
        let targetSong = playbackQueue[targetIndex]
        selectedThirdIndex = thirdMenuSelectionIndex(forMusicSongIndex: targetIndex)
        startMusicPlayback(
            from: targetSong,
            trackIndex: targetIndex,
            trackCount: playbackQueue.count,
            presentsFullscreen: false,
            playbackQueue: playbackQueue,
        )
    }

    func clearMusicNowPlayingDisplayState() {
        musicNowPlayingTitle = "Unknown Song"
        musicNowPlayingArtist = "Unknown Artist"
        musicNowPlayingAlbum = ""
        musicNowPlayingTrackPositionText = ""
        musicNowPlayingArtwork = nil
        musicNowPlayingElapsedSeconds = 0
        musicNowPlayingDurationSeconds = 0
        musicNowPlayingShowsShuffleGlyph = false
        musicNowPlayingLeadingGlyphState = nil
    }

    // MARK: - Music Input & Scrubbing

    func handleMusicSpacebarPressed() {
        if musicAudioPlayer == nil, isCurrentMusicPlaybackUsingAppleScript, activeMusicPlaybackSongID != nil {
            stopMusicScrubbing(showPauseGlyph: false)
            let shouldPause = musicAppleScriptIsPlaying
            Task(priority: .userInitiated) {
                let didSucceed = await musicAppleScriptExecutor.run {
                    shouldPause
                        ? self.pauseMusicPlaybackViaAppleScript()
                        : self.resumeMusicPlaybackViaAppleScript()
                }
                await MainActor.run {
                    guard self.isCurrentMusicPlaybackUsingAppleScript else { return }
                    guard self.activeMusicPlaybackSongID != nil else { return }
                    guard didSucceed else {
                        self.updateMusicNowPlayingFlipTimerState()
                        return
                    }
                    self.musicAppleScriptIsPlaying = !shouldPause
                    self.musicAppleScriptStartupDeadline = shouldPause ? nil : Date().addingTimeInterval(1.5)
                    self.updateMusicAppleScriptProgressAnchor(
                        elapsedSeconds: self.musicNowPlayingElapsedSeconds,
                        isPlaying: !shouldPause,
                    )
                    self.musicNowPlayingLeadingGlyphState = shouldPause ? .pause : nil
                    if !shouldPause {
                        self.startMusicAppleScriptProgressTimerIfNeeded()
                    } else {
                        self.updateMusicNowPlayingFlipTimerState()
                    }
                    self.refreshMusicPlaybackViaAppleScriptIfNeeded()
                }
            }
            updateMusicNowPlayingFlipTimerState()
            return
        }
        guard let player = musicAudioPlayer else { return }
        let isCurrentlyPlaying = player.rate > 0.01
        if isCurrentlyPlaying {
            player.pause()
            stopMusicScrubbing(showPauseGlyph: false)
            musicNowPlayingLeadingGlyphState = .pause
            return
        }
        stopMusicScrubbing(showPauseGlyph: false)
        musicNowPlayingLeadingGlyphState = nil
        player.playImmediately(atRate: 1.0)
    }

    func beginMusicScrubbing(direction: Int, isRepeat: Bool) {
        guard direction != 0 else { return }
        guard !isMusicSongTransitioning else { return }
        if musicAudioPlayer == nil,
           isCurrentMusicPlaybackUsingAppleScript,
           activeMusicPlaybackSongID != nil
        {
            if musicScrubDirection != direction {
                musicAppleScriptIsPlaying = false
                updateMusicAppleScriptProgressAnchor(
                    elapsedSeconds: musicNowPlayingElapsedSeconds,
                    isPlaying: false,
                )
                Task(priority: .utility) {
                    _ = await musicAppleScriptExecutor.run {
                        self.pauseMusicPlaybackViaAppleScript()
                    }
                }
            }
        }
        if musicAudioPlayer == nil, activeMusicPlaybackSongID == nil { return }
        musicAudioPlayer?.pause()
        updateMusicNowPlayingFlipTimerState()
        let now = Date()
        if musicScrubDirection != direction {
            musicScrubDirection = direction
            musicScrubStartDate = now
            musicLastScrubTickDate = now
        } else if musicScrubStartDate == nil {
            musicScrubStartDate = now
            musicLastScrubTickDate = now
        }
        musicLastScrubInputDate = now
        let holdDuration = now.timeIntervalSince(musicScrubStartDate ?? now)
        let level = movieScrubLevel(for: holdDuration)
        musicNowPlayingLeadingGlyphState = direction > 0 ? .fastForward(level) : .rewind(level)
        startMusicScrubTimerIfNeeded()
    }

    func startMusicScrubTimerIfNeeded() {
        guard musicScrubTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            handleMusicScrubTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        musicScrubTimer = timer
    }

    func stopMusicScrubTimer() {
        musicScrubTimer?.invalidate()
        musicScrubTimer = nil
    }

    func handleMusicScrubTick() {
        guard musicScrubDirection != 0 else {
            stopMusicScrubTimer()
            return
        }
        guard musicAudioPlayer != nil || activeMusicPlaybackSongID != nil else {
            stopMusicScrubbing(showPauseGlyph: true)
            return
        }
        let now = Date()
        guard let lastInput = musicLastScrubInputDate else {
            stopMusicScrubbing(showPauseGlyph: true)
            return
        }
        if now.timeIntervalSince(lastInput) > movieScrubReleaseGracePeriod {
            stopMusicScrubbing(showPauseGlyph: true)
            return
        }
        let delta = now.timeIntervalSince(musicLastScrubTickDate ?? now)
        guard delta > 0 else { return }
        musicLastScrubTickDate = now
        let holdDuration = now.timeIntervalSince(musicScrubStartDate ?? now)
        let level = movieScrubLevel(for: holdDuration)
        musicNowPlayingLeadingGlyphState = musicScrubDirection > 0 ? .fastForward(level) : .rewind(level)
        let maxTime: Double
        if let player = musicAudioPlayer {
            let resolvedDuration = resolvedMusicDurationSeconds(for: player)
            if resolvedDuration > 0 {
                musicNowPlayingDurationSeconds = resolvedDuration
            }
            maxTime = max(0, resolvedDuration > 0 ? resolvedDuration : musicNowPlayingDurationSeconds)
        } else {
            maxTime = max(0, musicNowPlayingDurationSeconds)
        }
        let unclampedTime = musicNowPlayingElapsedSeconds + (Double(musicScrubDirection) * musicScrubVelocity(for: level) * delta)
        let targetSeconds = max(0, min(maxTime > 0 ? maxTime : unclampedTime, unclampedTime))
        musicNowPlayingElapsedSeconds = max(0, targetSeconds)
        if let player = musicAudioPlayer {
            player.seek(
                to: CMTime(seconds: musicNowPlayingElapsedSeconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero,
            )
        } else {
            #if os(tvOS)
                if !isCurrentMusicPlaybackUsingAppleScript, activeMusicPlaybackSongID != nil {
                    ApplicationMusicPlayer.shared.playbackTime = targetSeconds
                }
            #endif
        }
    }

    func stopMusicScrubbing(showPauseGlyph: Bool) {
        #if os(macOS)
            let wasAppleScriptScrubbing =
                musicScrubDirection != 0 &&
                musicAudioPlayer == nil &&
                isCurrentMusicPlaybackUsingAppleScript &&
                activeMusicPlaybackSongID != nil
            let finalScrubPosition = musicNowPlayingElapsedSeconds
        #endif
        musicScrubDirection = 0
        musicScrubStartDate = nil
        musicLastScrubInputDate = nil
        musicLastScrubTickDate = nil
        stopMusicScrubTimer()
        musicKitScrubGlyphResetWorkItem?.cancel()
        musicKitScrubGlyphResetWorkItem = nil
        if wasAppleScriptScrubbing {
            updateMusicAppleScriptProgressAnchor(
                elapsedSeconds: finalScrubPosition,
                isPlaying: false,
            )
            let target = finalScrubPosition
            Task(priority: .utility) {
                let source = """
                tell application "\(musicApplicationName)"
                    if not running then return
                    set player position to \(target)
                end tell
                """
                _ = await musicAppleScriptExecutor.run {
                    executeAppleScript(source)
                }
            }
        }
        if showPauseGlyph {
            musicNowPlayingLeadingGlyphState = .pause
        }
    }

    func musicScrubVelocity(for level: Int) -> Double {
        switch level {
        case 3:
            36
        case 2:
            18
        default:
            7
        }
    }

    func clearMusicSongSwitchTransitionState() {
        isMusicSongTransitioning = false
    }

    func resetMusicNowPlayingFlipState() {
    }

    func updateMusicNowPlayingFlipTimerState() {
    }

    func cancelScreenSaverMusicTrackSwitchQueue() {
    }

    func triggerScreenSaverNowPlayingToastIfNeeded() {
    }
}
