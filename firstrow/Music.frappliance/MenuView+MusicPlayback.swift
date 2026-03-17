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
        resetTransitionState: Bool = true,
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
            artworkAlbumKey: nil,
            url: mediaURL,
            artwork: artwork,
        )
        startMusicPlayback(
            from: pseudoSong,
            trackIndex: trackIndex,
            trackCount: trackCount,
            presentsFullscreen: presentsFullscreen,
            resetTransitionState: resetTransitionState,
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
        Task.detached(priority: .utility) {
            let resolvedArtwork = await self.resolveMusicArtworkImage(
                for: song,
                cacheKey: cacheKey,
            )
            guard let resolvedArtwork else { return }
            await MainActor.run {
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
        return nil
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
        return isCurrentMusicPlaybackUsingAppleScript && activeMusicPlaybackSongID != nil
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
        let hadActiveSession = hasActiveMusicPlaybackSession()
        stopMusicPlaybackSession(clearDisplayState: false)
        if !hadActiveSession {
            resetMusicNowPlayingFlipState()
        }
        if let playbackQueue {
            activeMusicPlaybackQueue = playbackQueue
        }
        isCurrentMusicPlaybackUsingAppleScript = false
        if let songURL = song.url?.standardizedFileURL {
            let player = AVPlayer(url: songURL)
            player.automaticallyWaitsToMinimizeStalling = false
            configureMusicPlaybackObservation(for: player)
            musicAudioPlayer = player
            player.playImmediately(atRate: 1.0)
        } else {
            isCurrentMusicPlaybackUsingAppleScript = true
            playMusicTrackViaAppleScript(persistentIDDecimal: song.id)
        }
        let resolvedTrackCount = playbackQueue?.count ?? trackCount
        musicNowPlayingTrackPositionText = resolvedTrackCount > 0 ? "\(trackIndex + 1) of \(resolvedTrackCount)" : ""
        musicNowPlayingTitle = song.title
        musicNowPlayingArtist = song.artist
        musicNowPlayingAlbum = song.album
        musicNowPlayingArtwork = song.artwork ?? musicFallbackImage
        musicNowPlayingElapsedSeconds = 0
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
        updateMusicNowPlayingFlipTimerState()
    }

    #if os(macOS)
        /// Apple Music cloud tracks have no local URL and can't be played via AVFoundation.
        /// Delegate to Music.app via AppleScript using the track's persistent ID (stored as
        /// a decimal string in song.id; AppleScript needs 16-char uppercase hex).
        func playMusicTrackViaAppleScript(persistentIDDecimal: String) {
            guard let decimalID = UInt64(persistentIDDecimal) else { return }
            let hexID = String(format: "%016llX", decimalID)
            let source = """
            tell application "Music"
                activate
                set matchedTracks to (every track of library playlist 1 whose persistent ID is "\(hexID)")
                if (count of matchedTracks) > 0 then
                    play item 1 of matchedTracks
                end if
            end tell
            """
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error { print("[AppleScript] playback error: \(error)") }
            }
        }

        func pauseMusicPlaybackViaAppleScript() {
            let source = """
            tell application "Music"
                if player state is playing then
                    pause
                end if
            end tell
            """
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error { print("[AppleScript] pause error: \(error)") }
            }
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
                        self.dismissFullscreenScene(preserveMusicPlayback: false)
                    }
                } else {
                    self.switchMusicNowPlayingTrack(direction: 1)
                }
                self.updateMusicNowPlayingFlipTimerState()
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

    func stopMusicPlaybackSession(clearDisplayState: Bool = true) {
        stopMusicScrubbing(showPauseGlyph: false)
        _ = incrementRequestID(&musicNowPlayingArtworkRequestID)
        musicAudioPlayer?.pause()
        #if os(macOS)
            if isCurrentMusicPlaybackUsingAppleScript {
                pauseMusicPlaybackViaAppleScript()
            }
        #endif
        removeMusicPlaybackObservation()
        musicAudioPlayer = nil
        isCurrentMusicPlaybackUsingAppleScript = false
        removeCurrentMusicPlaybackTemporaryFileIfNeeded()
        activeMusicPlaybackQueue = []
        activeMusicPlaybackSongID = nil
        invalidateMusicNowPlayingFlipTimer()
        musicNowPlayingFlipMidpointWorkItem?.cancel()
        musicNowPlayingFlipMidpointWorkItem = nil
        if clearDisplayState {
            clearMusicNowPlayingDisplayState()
            resetMusicNowPlayingFlipState()
        }
    }

    func clearMusicSongSwitchTransitionState() {
        musicSongTransitionSnapshot = nil
        musicSongTransitionOutgoingProgress = 0
        musicSongTransitionOutgoingOpacityProgress = 0
        musicSongTransitionIncomingProgress = 0
        musicSongTransitionDeadline = nil
        isMusicSongTransitioning = false
        _ = incrementRequestID(&musicSongTransitionRequestID)
    }

    func cancelMusicNowPlayingFlipAnimation(preserveLayout: Bool = true) {
        invalidateMusicNowPlayingFlipTimer()
        musicNowPlayingFlipMidpointWorkItem?.cancel()
        musicNowPlayingFlipMidpointWorkItem = nil
        musicNowPlayingFlipGeneration += 1
        musicNowPlayingFlipRotationDegrees = 0
        isMusicNowPlayingFlipAnimating = false
        if !preserveLayout {
            musicNowPlayingUsesAlternateLayout = false
        }
    }

    func musicNowPlayingFlipVisibilityOpacity() -> Double {
        1
    }

    func resetMusicNowPlayingFlipState() {
        invalidateMusicNowPlayingFlipTimer()
        musicNowPlayingFlipMidpointWorkItem?.cancel()
        musicNowPlayingFlipMidpointWorkItem = nil
        musicNowPlayingFlipGeneration = 0
        musicNowPlayingFlipRotationDegrees = 0
        musicNowPlayingUsesAlternateLayout = false
        isMusicNowPlayingFlipAnimating = false
    }

    func invalidateMusicNowPlayingFlipTimer() {
        musicNowPlayingFlipTimer?.invalidate()
        musicNowPlayingFlipTimer = nil
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
        clearMusicSongSwitchTransitionState()
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

    func updateMusicNowPlayingFlipTimerState() {
        let isMusicSceneVisible = activeFullscreenScene?.key == musicNowPlayingFullscreenKey
            || thirdMenuMode == .musicNowPlaying
        let isMusicPlaying = isMusicPlaybackRunning()
        let shouldRun = isMusicSceneVisible && isMusicPlaying && !isMovieTransitioning && !isMoviePlaybackVisible
        if !shouldRun {
            invalidateMusicNowPlayingFlipTimer()
            musicNowPlayingFlipMidpointWorkItem?.cancel()
            musicNowPlayingFlipMidpointWorkItem = nil
            if !isMusicNowPlayingFlipAnimating {
                musicNowPlayingFlipRotationDegrees = 0
            }
            return
        }
        guard musicNowPlayingFlipTimer == nil else { return }
        let timer = Timer(timeInterval: musicNowPlayingFlipInterval, repeats: true) { _ in
            self.performMusicNowPlayingFlip()
        }
        RunLoop.main.add(timer, forMode: .common)
        musicNowPlayingFlipTimer = timer
    }

    func performMusicNowPlayingFlip() {
        guard activeFullscreenScene?.key == musicNowPlayingFullscreenKey || thirdMenuMode == .musicNowPlaying else { return }
        guard isMusicPlaybackRunning() else { return }
        guard !isMusicSongTransitioning else { return }
        guard !isMusicNowPlayingFlipAnimating else { return }
        isMusicNowPlayingFlipAnimating = true
        musicNowPlayingFlipGeneration += 1
        let generation = musicNowPlayingFlipGeneration
        let halfDuration = musicNowPlayingFlipDuration * 0.5
        // Alternate the spin sign so each pass is the exact reverse of the previous one.
        // Right -> Left uses one direction; Left -> Right uses the mirrored reverse path.
        let spinSign: Double = musicNowPlayingUsesAlternateLayout ? 1 : -1
        let halfTurnDegrees = 90.0 * spinSign
        musicNowPlayingFlipMidpointWorkItem?.cancel()
        let midpointWorkItem = DispatchWorkItem {
            guard generation == musicNowPlayingFlipGeneration else { return }
            guard activeFullscreenScene?.key == musicNowPlayingFullscreenKey || thirdMenuMode == .musicNowPlaying else { return }
            musicNowPlayingUsesAlternateLayout.toggle()
            var resetTransaction = Transaction()
            resetTransaction.disablesAnimations = true
            withTransaction(resetTransaction) {
                musicNowPlayingFlipRotationDegrees = -halfTurnDegrees
            }
            withAnimation(.linear(duration: halfDuration)) {
                musicNowPlayingFlipRotationDegrees = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + halfDuration) {
                guard generation == self.musicNowPlayingFlipGeneration else { return }
                self.isMusicNowPlayingFlipAnimating = false
            }
        }
        musicNowPlayingFlipMidpointWorkItem = midpointWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + halfDuration, execute: midpointWorkItem)
        withAnimation(.linear(duration: halfDuration)) {
            musicNowPlayingFlipRotationDegrees = halfTurnDegrees
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
        if isMusicSongTransitioning {
            clearMusicSongSwitchTransitionState()
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
        let isMusicNowPlayingSceneVisible = activeFullscreenScene?.key == musicNowPlayingFullscreenKey
            || thirdMenuMode == .musicNowPlaying
        if !isMusicNowPlayingSceneVisible {
            clearMusicSongSwitchTransitionState()
            startMusicPlayback(
                from: targetSong,
                trackIndex: targetIndex,
                trackCount: playbackQueue.count,
                presentsFullscreen: false,
                playbackQueue: playbackQueue,
            )
            return
        }
        cancelMusicNowPlayingFlipAnimation()
        let transitionGeneration = incrementRequestID(&musicSongTransitionRequestID)
        musicSongTransitionDeadline = Date().addingTimeInterval(
            musicSongIncomingTransitionDelay + musicSongSwitchTransitionDuration + 0.05,
        )
        musicSongTransitionDirection = direction > 0 ? 1 : -1
        musicSongTransitionSnapshot = currentMusicNowPlayingSnapshot
        musicSongTransitionOutgoingProgress = 0
        musicSongTransitionOutgoingOpacityProgress = 0
        musicSongTransitionIncomingProgress = 0
        isMusicSongTransitioning = true
        selectedThirdIndex = thirdMenuSelectionIndex(forMusicSongIndex: targetIndex)
        startMusicPlayback(
            from: targetSong,
            trackIndex: targetIndex,
            trackCount: playbackQueue.count,
            resetTransitionState: false,
            playbackQueue: playbackQueue,
        )
        DispatchQueue.main.async {
            guard self.musicSongTransitionRequestID == transitionGeneration else { return }
            let outgoingFadeAnimation: Animation = direction > 0
                ? .easeOut(duration: musicSongOutgoingFadeDuration)
                : .easeInOut(duration: musicSongSwitchTransitionDuration)
            withAnimation(.easeInOut(duration: musicSongSwitchTransitionDuration)) {
                musicSongTransitionOutgoingProgress = 1
            }
            withAnimation(outgoingFadeAnimation) {
                musicSongTransitionOutgoingOpacityProgress = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + musicSongIncomingTransitionDelay) {
            guard self.musicSongTransitionRequestID == transitionGeneration else { return }
            withAnimation(.easeInOut(duration: musicSongSwitchTransitionDuration)) {
                musicSongTransitionIncomingProgress = 1
            }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + musicSongIncomingTransitionDelay + musicSongSwitchTransitionDuration,
        ) {
            guard self.musicSongTransitionRequestID == transitionGeneration else { return }
            clearMusicSongSwitchTransitionState()
            updateMusicNowPlayingFlipTimerState()
        }
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

    func handleMusicPlaybackInput(_ key: KeyCode, isRepeat: Bool) {
        switch key {
        case .delete, .escape:
            stopMusicScrubbing(showPauseGlyph: false)
            clearMusicSongSwitchTransitionState()
            dismissFullscreenScene(preserveMusicPlayback: true)
            playSound(named: "Exit")
        case .space:
            handleMusicSpacebarPressed()
        case .upArrow, .downArrow:
            guard prepareNavigationTiming(for: key, isRepeat: isRepeat) else { return }
            switchMusicNowPlayingTrack(direction: key == .upArrow ? -1 : 1)
        case .leftArrow:
            beginMusicScrubbing(direction: -1, isRepeat: isRepeat)
        case .rightArrow:
            beginMusicScrubbing(direction: 1, isRepeat: isRepeat)
        default:
            break
        }
    }

    func handleMusicSpacebarPressed() {
        guard let player = musicAudioPlayer else { return }
        let isCurrentlyPlaying = player.rate > 0.01
        if isCurrentlyPlaying {
            player.pause()
            stopMusicScrubbing(showPauseGlyph: false)
            musicNowPlayingLeadingGlyphState = .pause
            updateMusicNowPlayingFlipTimerState()
            return
        }
        stopMusicScrubbing(showPauseGlyph: false)
        musicNowPlayingLeadingGlyphState = nil
        player.playImmediately(atRate: 1.0)
        updateMusicNowPlayingFlipTimerState()
    }

    func beginMusicScrubbing(direction: Int, isRepeat: Bool) {
        guard let player = musicAudioPlayer else { return }
        guard direction != 0 else { return }
        guard !isMusicSongTransitioning else { return }
        _ = isRepeat
        player.pause()
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
        guard let player = musicAudioPlayer else {
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
        let resolvedDuration = resolvedMusicDurationSeconds(for: player)
        if resolvedDuration > 0 {
            musicNowPlayingDurationSeconds = resolvedDuration
        }
        let maxTime = max(0, resolvedDuration > 0 ? resolvedDuration : musicNowPlayingDurationSeconds)
        let unclampedTime = musicNowPlayingElapsedSeconds + (Double(musicScrubDirection) * musicScrubVelocity(for: level) * delta)
        let targetSeconds = max(0, min(maxTime > 0 ? maxTime : unclampedTime, unclampedTime))
        musicNowPlayingElapsedSeconds = max(0, targetSeconds)
        player.seek(
            to: CMTime(seconds: musicNowPlayingElapsedSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero,
        )
    }

    func stopMusicScrubbing(showPauseGlyph: Bool) {
        musicScrubDirection = 0
        musicScrubStartDate = nil
        musicLastScrubInputDate = nil
        musicLastScrubTickDate = nil
        stopMusicScrubTimer()
        if showPauseGlyph {
            musicNowPlayingLeadingGlyphState = .pause
        }
        updateMusicNowPlayingFlipTimerState()
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
}

extension MenuView {
    struct MusicNowPlayingSnapshot {
        let artworkImage: NSImage?
        let trackTitle: String
        let artistName: String
        let albumTitle: String
        let trackPositionText: String
        let elapsedSeconds: Double
        let durationSeconds: Double
        let showsShuffleGlyph: Bool
        let leadingGlyphState: MoviePlaybackGlyphState?
    }

    var currentMusicNowPlayingSnapshot: MusicNowPlayingSnapshot {
        .init(
            artworkImage: musicNowPlayingArtwork,
            trackTitle: musicNowPlayingTitle,
            artistName: musicNowPlayingArtist,
            albumTitle: musicNowPlayingAlbum,
            trackPositionText: musicNowPlayingTrackPositionText,
            elapsedSeconds: musicNowPlayingElapsedSeconds,
            durationSeconds: musicNowPlayingDurationSeconds,
            showsShuffleGlyph: musicNowPlayingShowsShuffleGlyph,
            leadingGlyphState: musicNowPlayingLeadingGlyphState,
        )
    }

    func musicNowPlayingView(for snapshot: MusicNowPlayingSnapshot) -> some View {
        MusicNowPlayingFullscreenView(
            artworkImage: snapshot.artworkImage,
            trackTitle: snapshot.trackTitle,
            artistName: snapshot.artistName,
            albumTitle: snapshot.albumTitle,
            trackPositionText: snapshot.trackPositionText,
            elapsedSeconds: snapshot.elapsedSeconds,
            durationSeconds: snapshot.durationSeconds,
            showsShuffleGlyph: snapshot.showsShuffleGlyph,
            leadingGlyphState: snapshot.leadingGlyphState,
            layoutMode: musicNowPlayingUsesAlternateLayout ? .artworkLeft : .artworkRight,
        )
    }

    func musicNowPlayingSceneView() -> some View {
        let hasTransition = musicSongTransitionSnapshot != nil
        let incomingStartScale: CGFloat = musicSongTransitionDirection > 0 ? 0.25 : 6
        let outgoingEndScale: CGFloat = musicSongTransitionDirection > 0 ? 6 : 0.25
        let outgoingProgress = min(max(musicSongTransitionOutgoingProgress, 0), 1)
        let outgoingOpacityProgress = min(max(musicSongTransitionOutgoingOpacityProgress, 0), 1)
        let incomingProgress = min(max(musicSongTransitionIncomingProgress, 0), 1)
        let incomingScale = hasTransition
            ? (incomingStartScale + ((1 - incomingStartScale) * incomingProgress))
            : 1
        let outgoingScale = hasTransition
            ? (1 + ((outgoingEndScale - 1) * outgoingProgress))
            : 1
        let incomingOpacity = hasTransition ? Double(incomingProgress) : 1
        let outgoingOpacity = hasTransition ? Double(1 - outgoingOpacityProgress) : 1
        let flipOpacity = musicNowPlayingFlipVisibilityOpacity()
        return ZStack {
            musicNowPlayingView(for: currentMusicNowPlayingSnapshot).scaleEffect(incomingScale).opacity(incomingOpacity)
            if let outgoing = musicSongTransitionSnapshot {
                musicNowPlayingView(for: outgoing).scaleEffect(outgoingScale).opacity(outgoingOpacity)
            }
        }.rotation3DEffect(.degrees(musicNowPlayingFlipRotationDegrees),
                           axis: (x: 0, y: 1, z: 0),
                           perspective: 0.9).opacity(flipOpacity)
    }
}
