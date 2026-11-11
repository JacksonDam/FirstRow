import AVFoundation
import Foundation
#if os(macOS)
    import AppKit
    import CoreServices
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif
#if os(iOS)
    import MediaPlayer
#endif
#if os(tvOS)
    import MusicKit
#endif
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif
#if canImport(Darwin)
    import Darwin
#endif

private let mediaTrackFlagsCache = BoundedCache<String, (hasVideo: Bool, hasAudio: Bool)>(maxEntryCount: 800)

/// The music start that's current, readable off the main thread: a start still waiting its turn
/// there checks it's still wanted before it plays anything.
enum MusicPlaybackGate {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var value = 0

    static var current: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    static func isCurrent(_ requestID: Int) -> Bool {
        current == requestID
    }
}

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
        #if os(tvOS)
            let pseudoSong = MusicLibrarySongEntry(
                id: resolvedPlaybackID,
                title: title,
                artist: artist,
                album: album,
                genre: "Podcast",
                composer: "",
                durationSeconds: 0,
                trackNumber: 0,
                discNumber: 1,
                artworkAlbumKey: nil,
                url: mediaURL,
                artwork: artwork,
                musicKitSong: nil,
            )
        #else
            let pseudoSong = MusicLibrarySongEntry(
                id: resolvedPlaybackID,
                title: title,
                artist: artist,
                album: album,
                genre: "Podcast",
                composer: "",
                durationSeconds: 0,
                trackNumber: 0,
                discNumber: 1,
                artworkAlbumKey: nil,
                url: mediaURL,
                artwork: artwork,
            )
        #endif
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
            var resolvedArtwork: NSImage?
            // A streamed song's cover can reach the library only once the song has started (and
            // later still while the library is busy, just after launch). So for as long as that
            // song plays on showing the placeholder, it's asked about again: quickly at first,
            // then every few seconds, from the library and from the player playing it.
            let quickWaits: [Double] = [0, 0.6, 1, 1.5, 2, 3, 4]
            var attempt = 0
            while resolvedArtwork == nil, attempt < 400 {
                let wait = attempt < quickWaits.count ? quickWaits[attempt] : 4
                attempt += 1
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    // Only while that song plays on without a cover (another lookup may have found it).
                    let stillWaiting = await MainActor.run {
                        self.activeMusicPlaybackSongID == activeSongID &&
                            (self.musicNowPlayingArtwork == nil || self.musicNowPlayingArtwork === self.musicFallbackImage)
                    }
                    guard stillWaiting else { return }
                }
                resolvedArtwork = await self.resolveMusicArtworkImage(for: song, cacheKey: cacheKey)
                #if os(iOS)
                    if resolvedArtwork == nil, song.url == nil {
                        // The player streaming it fetches its cover sooner than the library has it.
                        resolvedArtwork = await SystemMusicPlayerCalls.nowPlayingArtwork(persistentID: song.id)
                    }
                #endif
            }
            guard let resolvedArtwork else { return }
            await MainActor.run {
                self.musicPreviewCache[cacheKey] = resolvedArtwork
                self.showLateNowPlayingArtwork(resolvedArtwork, songID: activeSongID, requestID: requestID)
            }
        }
    }

    /// A cover that arrived after its song started: shown if that song is still playing and
    /// either nothing has asked for a cover since or it still shows none.
    func showLateNowPlayingArtwork(_ artwork: NSImage, songID: String, requestID: Int?) {
        guard activeMusicPlaybackSongID == songID else { return }
        let showsNoCover = musicNowPlayingArtwork == nil || musicNowPlayingArtwork === musicFallbackImage
        guard showsNoCover || requestID == musicNowPlayingArtworkRequestID else { return }
        guard musicNowPlayingArtwork !== artwork else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            musicNowPlayingArtwork = artwork
        }
    }

    func resolvedActiveMusicPlaybackQueue() -> [MusicLibrarySongEntry] {
        if !activeMusicPlaybackQueue.isEmpty {
            return activeMusicPlaybackQueue
        }
        return musicSongsThirdMenuItems
    }

    func prefetchMusicArtworkIfNeeded(for song: MusicLibrarySongEntry) {
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
                // The song playing may be waiting on this very cover.
                self.showLateNowPlayingArtwork(resolvedArtwork, songID: song.id, requestID: nil)
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
        #if os(iOS)
            guard MPMediaLibrary.authorizationStatus() == .authorized else { return nil }
            guard let persistentID = UInt64(song.id) else { return nil }
            let query = MPMediaQuery.songs()
            let predicate = MPMediaPropertyPredicate(
                value: NSNumber(value: persistentID),
                forProperty: MPMediaItemPropertyPersistentID,
                comparisonType: .equalTo,
            )
            query.addFilterPredicate(predicate)
            return query.items?.first?.artwork?.image(at: CGSize(width: 800, height: 800))?.pngData()
        #elseif canImport(iTunesLibrary)
            return resolvedMusicLibraryArtworkDataFromITLibrary(for: song)
        #else
            return nil
        #endif
    }

    func hasActiveMusicPlaybackSession() -> Bool {
        if musicAudioPlayer != nil {
            return true
        }
        if isCurrentMusicPlaybackUsingSpotify {
            return activeMusicPlaybackSongID != nil
        }
        #if os(macOS)
            return activeMusicPlaybackSongID != nil
        #elseif os(tvOS)
            return activeMusicPlaybackSongID != nil
        #elseif os(iOS)
            return isCurrentMusicPlaybackUsingMediaPlayer && activeMusicPlaybackSongID != nil
        #else
            return false
        #endif
    }

    func isMusicPlaybackRunning() -> Bool {
        if let musicAudioPlayer {
            return musicAudioPlayer.rate > 0.01
        }
        if isCurrentMusicPlaybackUsingSpotify {
            return spotifyIsPlaying && activeMusicPlaybackSongID != nil
        }
        #if os(macOS)
            if isCurrentMusicPlaybackUsingAppleScript {
                return musicAppleScriptIsPlaying && activeMusicPlaybackSongID != nil
            }
            return false
        #elseif os(tvOS)
            guard activeMusicPlaybackSongID != nil else { return false }
            let status = ApplicationMusicPlayer.shared.state.playbackStatus
            switch status {
            case .playing, .seekingForward, .seekingBackward:
                return true
            default:
                return false
            }
        #elseif os(iOS)
            guard isCurrentMusicPlaybackUsingMediaPlayer, activeMusicPlaybackSongID != nil else { return false }
            // Asking the system player waits on the media server, so the main thread never does:
            // the progress reads (ten a second, off it) and play and pause keep this up to date.
            return musicMediaPlayerWasPlaying
        #else
            return false
        #endif
    }

    /// Playing, or a song just started still getting going (for a few seconds at most): what
    /// Now Playing's play button and its buttons' coming and going go by.
    func isMusicPlaybackRunningOrStarting() -> Bool {
        if isMusicPlaybackRunning() { return true }
        guard let until = musicPlaybackStartingUntil else { return false }
        return until > Date()
    }

    private static let musicPlaybackStartingGrace: TimeInterval = 5

    /// Play or Pause just asked of a player that reports its state as it goes, which can still
    /// report what it was doing for a moment: what was asked holds until a report agrees, or for
    /// a few seconds, so the button doesn't flick back and forth.
    struct AskedPlayState {
        let playing: Bool
        let until: Date

        init(playing: Bool, holdingFor seconds: TimeInterval = 3) {
            self.playing = playing
            until = Date().addingTimeInterval(seconds)
        }

        /// Whether to show playing for `reported`, clearing `asked` once the player agrees (or
        /// the wait is over).
        static func settle(_ reported: Bool, _ asked: inout AskedPlayState?) -> Bool {
            guard let wanted = asked else { return reported }
            if reported == wanted.playing || Date() > wanted.until {
                asked = nil
                return reported
            }
            return wanted.playing
        }
    }

    #if os(macOS)
        /// Play or Pause has been asked of the Music app: it shows at once, and stands until
        /// Music reports the same (see `applyMusicSystemPlayerSnapshot`) or, if it never does,
        /// for a few seconds: longer for Play, since a streamed song takes a while to get
        /// going again.
        func showMusicAppleScriptAsked(playing: Bool) {
            musicAppleScriptIsPlaying = playing
            musicAppleScriptAskedToPlay = AskedPlayState(playing: playing, holdingFor: playing ? 8 : 3)
            musicNowPlayingLeadingGlyphState = playing ? nil : .pause
            if !playing {
                updateMusicAppleScriptProgressAnchor(elapsedSeconds: musicNowPlayingElapsedSeconds, isPlaying: false)
            }
        }
    #endif

    /// A song has been started: it shows as playing while it gets going.
    private func noteMusicPlaybackStarting() {
        let until = Date().addingTimeInterval(Self.musicPlaybackStartingGrace)
        musicPlaybackStartingUntil = until
        Task { @MainActor [weak self] in
            try? await firstRowSleep(Self.musicPlaybackStartingGrace + 0.05)
            guard let self, self.musicPlaybackStartingUntil == until else { return }
            self.musicPlaybackStartingUntil = nil
            // Not going by now: it shows as it is.
            self.updateMusicNowPlayingFlipTimerState()
        }
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
        #if os(macOS)
            let willUseAppleScriptPlayback = song.spotify == nil && (song.prefersSystemMusicPlayerPlayback || song.url == nil)
        #endif
        let hadActiveSession = hasActiveMusicPlaybackSession()
        // Song to song, the Music menu keeps its Now Playing row while one stops and the next
        // starts: anything drawn in between (a cover fading in, say) would take it away a frame.
        isRestartingMusicPlayback = hadActiveSession && !isPodcastAudioNowPlaying
        defer { isRestartingMusicPlayback = false }
        // Spotify going from song to song is told what to play next, not stopped first.
        let staysOnSpotify = isCurrentMusicPlaybackUsingSpotify && song.spotify != nil
        stopMusicPlaybackSession(
            clearDisplayState: false,
            pauseSystemMusicPlayback: !staysOnSpotify && {
                #if os(macOS)
                    !(isCurrentMusicPlaybackUsingAppleScript && willUseAppleScriptPlayback)
                #elseif os(tvOS)
                    // A new Apple Music queue replaces the old one, so there's no need to stop it first.
                    song.musicKitSong == nil
                #elseif os(iOS)
                    song.url != nil
                #else
                    true
                #endif
            }(),
        )
        if !hadActiveSession {
            resetMusicNowPlayingFlipState()
        }
        if let playbackQueue {
            activeMusicPlaybackQueue = playbackQueue
            #if os(macOS)
                rememberMusicQueueForNextLaunch(playbackQueue)
            #endif
        }
        isCurrentMusicPlaybackManagedByFirstRow = true
        hasPendingExternalMusicRestore = false
        let playbackRequestID = incrementRequestID(&musicPlaybackRequestID)
        // Only ever one song: the Music app, playing on its own, stops for this one.
        #if os(macOS)
            if !willUseAppleScriptPlayback { pauseMusicAppIfPlaying() }
        #elseif os(iOS)
            SystemMusicPlayerCalls.pauseMusicApp(unlessPlaying: song.url == nil ? song.id : nil)
        #endif
        let performPlayback: () -> Void
        if song.spotify != nil {
            performPlayback = {
                self.startMusicPlaybackViaSpotify(song, playbackRequestID: playbackRequestID)
            }
        } else {
        #if os(tvOS)
            if let musicKitSong = song.musicKitSong {
                performPlayback = {
                    self.startMusicPlaybackUsingMusicKit(song: musicKitSong)
                }
            } else if let songURL = song.url?.standardizedFileURL {
                performPlayback = {
                    let player = AVPlayer(url: songURL)
                    player.isMuted = FirstRowHarness.isActive
                    player.volume = self.musicPlaybackVolume(for: songURL)
                    player.automaticallyWaitsToMinimizeStalling = false
                    self.configureMusicPlaybackObservation(for: player)
                    self.musicAudioPlayer = player
                    player.playImmediately(atRate: 1.0)
                }
            } else {
                return
            }
        #else
            #if os(macOS)
                if song.prefersSystemMusicPlayerPlayback || song.url == nil {
                    performPlayback = {
                        self.startMusicPlaybackViaAppleScript(song, playbackRequestID: playbackRequestID)
                    }
                } else if let songURL = song.url?.standardizedFileURL {
                    performPlayback = {
                        let player = AVPlayer(url: songURL)
                        player.isMuted = FirstRowHarness.isActive
                        player.volume = self.musicPlaybackVolume(for: songURL)
                        player.automaticallyWaitsToMinimizeStalling = false
                        self.configureMusicPlaybackObservation(for: player)
                        self.musicAudioPlayer = player
                        player.playImmediately(atRate: 1.0)
                    }
                } else {
                    return
                }
            #elseif !FIRSTROW_PORTABLE
                if song.url == nil {
                    performPlayback = {
                        self.startMusicPlaybackUsingMediaPlayer(song)
                    }
                } else if let songURL = song.url?.standardizedFileURL {
                    performPlayback = {
                        let player = AVPlayer(url: songURL)
                        player.isMuted = FirstRowHarness.isActive
                        player.volume = self.musicPlaybackVolume(for: songURL)
                        player.automaticallyWaitsToMinimizeStalling = false
                        self.configureMusicPlaybackObservation(for: player)
                        self.musicAudioPlayer = player
                        player.playImmediately(atRate: 1.0)
                    }
                } else {
                    return
                }
            #else
                // Songs here always come from files.
                guard let songURL = song.url?.standardizedFileURL else { return }
                performPlayback = {
                    let player = AVPlayer(url: songURL)
                    player.isMuted = FirstRowHarness.isActive
                    player.normalizesLoudness = self.musicPlaybackVolume(for: songURL) < 1
                    player.automaticallyWaitsToMinimizeStalling = false
                    self.configureMusicPlaybackObservation(for: player)
                    self.musicAudioPlayer = player
                    player.playImmediately(atRate: 1.0)
                }
            #endif
        #endif
        }
        isCurrentMusicPlaybackUsingAppleScript = false
        musicAppleScriptCurrentTrackPersistentIDHex = nil
        musicAppleScriptDidHandleTrackBoundary = false
        let resolvedTrackCount = playbackQueue?.count ?? trackCount
        musicNowPlayingTrackPositionText = resolvedTrackCount > 0 ? "\(trackIndex + 1) of \(resolvedTrackCount)" : ""
        musicNowPlayingTitle = song.title
        musicNowPlayingArtist = song.artist
        musicNowPlayingAlbum = song.album
        // The copy decoded for the screen when there is one (the list it was chosen from showed
        // it), so the cover isn't decoded on the main thread as Now Playing comes up.
        musicNowPlayingArtwork = musicArtworkCacheKey(for: song).flatMap { musicPreviewCache[$0] } ?? song.artwork ?? musicFallbackImage
        musicNowPlayingElapsedSeconds = 0
        musicNowPlayingDurationSeconds = max(0, song.durationSeconds)
        musicNowPlayingShowsShuffleGlyph = isMusicSongsShuffleMode
        musicNowPlayingLeadingGlyphState = nil
        activeMusicPlaybackSongID = song.id
        // Started to play: shown so straight away, not paused until the player gets going.
        noteMusicPlaybackStarting()
        let artworkRequestID = incrementRequestID(&musicNowPlayingArtworkRequestID)
        updateNowPlayingArtworkIfNeeded(for: song, requestID: artworkRequestID)
        if activeFullscreenScene?.key != screenSaverFullscreenKey {
            prefetchMusicArtworkAroundTrackIndex(
                trackIndex,
                activeSongID: song.id,
            )
        }
        resetScreenSaverIdleTimer()
        if presentsFullscreen {
            presentFullscreenScene(
                key: musicNowPlayingFullscreenKey,
                usingExistingBlackout: usingExistingBlackout,
            )
        }
        performPlayback()
        jellyfinMusicPlaybackDidStart(song)
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
            /// Whether `elapsedSeconds` is Music's position (read from it), not a stand-in.
            var hasPosition = false
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
            musicAppleScriptAskedToPlay = nil
            updateMusicAppleScriptProgressAnchor(
                elapsedSeconds: 0,
                isPlaying: false,
            )
            musicAppleScriptCurrentTrackPersistentIDHex = nil
            musicAppleScriptDidHandleTrackBoundary = false
            let expectedSongID = song.id
            Task(priority: .userInitiated) {
                let trackStartResult = await musicAppleScriptExecutor.run { () -> MusicAppleScriptTrackStartResult? in
                    // Something else was played while this waited its turn: it never starts, so
                    // Music can't end up playing alongside it.
                    guard MusicPlaybackGate.isCurrent(playbackRequestID) else { return nil }
                    return self.playMusicTrackViaAppleScript(song: song)
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
                        // Held at 0 until Music reports the song moving (see applyMusicSystemPlayerSnapshot).
                        self.updateMusicAppleScriptProgressAnchor(
                            elapsedSeconds: 0,
                            isPlaying: false,
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
                dismissFullscreenScene(preserveMusicPlayback: false)
            } else {
                stopMusicPlaybackSession(clearDisplayState: false)
            }
        }

        /// Within a few seconds of the end of the song (where Music moves on, or repeats it, by itself).
        var isMusicAppleScriptSongNearItsEnd: Bool {
            musicNowPlayingDurationSeconds > 0 && musicNowPlayingElapsedSeconds >= musicNowPlayingDurationSeconds - 3
        }

        /// Music moved to another song itself. At the end of a song, or with its Next, First Row's
        /// next song follows. With its Previous (the keyboard's previous key goes to Music, not
        /// First Row), First Row's previous song does: Music only knows its own list, not First
        /// Row's, so which way it went is asked of Music when it isn't plain.
        func handleMusicAppTrackChange(from expectedHex: String, to snapshot: MusicSystemPlayerSnapshot) {
            guard isCurrentMusicPlaybackUsingAppleScript, isCurrentMusicPlaybackManagedByFirstRow,
                  !musicAppleScriptDidHandleTrackBoundary
            else { return }
            let queue = resolvedActiveMusicPlaybackQueue()
            guard let index = activeMusicPlaybackIndex(), !isMusicAppleScriptSongNearItsEnd else {
                handleMusicAppleScriptTrackBoundary()
                return
            }
            if queue.indices.contains(index - 1), queue[index - 1].id == snapshot.persistentIDDecimalString {
                goToPreviousSongAfterMusicApp()
                return
            }
            if queue.indices.contains(index + 1), queue[index + 1].id == snapshot.persistentIDDecimalString {
                handleMusicAppleScriptTrackBoundary()
                return
            }
            // Held while Music is asked, so nothing else acts on the change meanwhile.
            musicAppleScriptDidHandleTrackBoundary = true
            let requestID = musicPlaybackRequestID
            Task(priority: .userInitiated) {
                let wentBack = await musicAppleScriptExecutor.run {
                    Self.musicAppWentBack(from: expectedHex)
                }
                await MainActor.run {
                    guard self.musicPlaybackRequestID == requestID, self.isCurrentMusicPlaybackUsingAppleScript else { return }
                    self.musicAppleScriptDidHandleTrackBoundary = false
                    if wentBack {
                        self.goToPreviousSongAfterMusicApp()
                    } else {
                        self.handleMusicAppleScriptTrackBoundary()
                    }
                }
            }
        }

        /// First Row's previous song, or from the first song, that one again from the start.
        private func goToPreviousSongAfterMusicApp() {
            musicAppleScriptDidHandleTrackBoundary = true
            stopMusicScrubbing(showPauseGlyph: false)
            musicNowPlayingLeadingGlyphState = nil
            let queue = resolvedActiveMusicPlaybackQueue()
            if let index = activeMusicPlaybackIndex(), index == 0, let first = queue.first {
                startMusicPlayback(
                    from: first,
                    trackIndex: 0,
                    trackCount: queue.count,
                    presentsFullscreen: false,
                    playbackQueue: queue,
                )
                return
            }
            switchMusicNowPlayingTrack(direction: -1)
        }

        /// Whether the song Music is playing now comes before `previousHex` in Music's list.
        nonisolated static func musicAppWentBack(from previousHex: String) -> Bool {
            let source = """
            tell application "\(musicApplicationName)"
                if not running then
                    return "ON"
                end if
                try
                    set newIndex to index of current track
                    set oldIndex to index of (first track of current playlist whose persistent ID is "\(previousHex)")
                    if newIndex < oldIndex then
                        return "BACK"
                    end if
                end try
                return "ON"
            end tell
            """
            let result = executeMusicApplicationAppleScript(source, retryCount: 2)
            return result.succeeded && result.trimmedStandardOutput == "BACK"
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

        /// Pauses the Music app if it's playing on its own, before First Row plays something
        /// itself, so the two never play together. Only when First Row may already control Music
        /// (it never asks for that here) and Music is open.
        func pauseMusicAppIfPlaying() {
            guard !FirstRowHarness.isActive,
                  !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
            else { return }
            Task(priority: .userInitiated) {
                _ = await musicAppleScriptExecutor.run { () -> Bool in
                    guard Self.mayControlMusicApp() else { return false }
                    return self.pauseMusicPlaybackViaAppleScript()
                }
            }
        }

        /// Whether First Row has been allowed to control the Music app, without asking.
        nonisolated static func mayControlMusicApp() -> Bool {
            var target = AEAddressDesc()
            let bundleID = Array("com.apple.Music".utf8)
            let created = bundleID.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &target) }
            guard created == noErr else { return false }
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) == noErr
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
                let timer = Timer(after: 0.25, repeats: true) { _ in
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
                handleMusicAppTrackChange(from: expectedPersistentIDHex, to: snapshot)
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
            // What Play or Pause just asked for stands until Music reports the same: it goes
            // on saying "paused" while it gets a streamed song going again (for seconds), and
            // a report already on its way when Pause was pressed still says "playing".
            let askedOrReported = AskedPlayState.settle(snapshot.isPlaying, &musicAppleScriptAskedToPlay)
            let effectiveIsPlaying = isGraceActive ? musicAppleScriptIsPlaying : askedOrReported
            
            // Music's own Previous (the keyboard's previous key goes to Music, not First Row)
            // starts the song again more than a few seconds in: First Row goes to its previous
            // song instead, as its own previous does.
            if snapshot.hasPosition, musicScrubDirection == 0, !isGraceActive,
               isCurrentMusicPlaybackUsingAppleScript, isCurrentMusicPlaybackManagedByFirstRow,
               musicNowPlayingElapsedSeconds > 4, snapshot.elapsedSeconds < 2,
               !isMusicAppleScriptSongNearItsEnd,
               let index = activeMusicPlaybackIndex(), index > 0
            {
                goToPreviousSongAfterMusicApp()
                return
            }
            if musicScrubDirection == 0 {
                musicAppleScriptIsPlaying = effectiveIsPlaying
                musicAppleScriptStartupDeadline = isGraceActive ? musicAppleScriptStartupDeadline : nil
                let snapshotElapsed = max(0, snapshot.elapsedSeconds)
                musicNowPlayingElapsedSeconds = snapshotElapsed
                // Music reports "playing" while a song loads, so only count once the position moves.
                let hasStartedMoving = snapshotElapsed > 0.05
                // (The time only runs once Music itself says it's playing.)
                updateMusicAppleScriptProgressAnchor(
                    elapsedSeconds: snapshotElapsed,
                    isPlaying: (isGraceActive ? false : effectiveIsPlaying) && snapshot.isPlaying && hasStartedMoving,
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
            putRecoveredSongBackInItsList()
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
                hasPosition: true,
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

    func clearActivePodcastAudioPlaybackContext() {
        activePodcastPlaybackSeriesID = nil
        activePodcastPlaybackEpisodeID = nil
    }

    func startPodcastEpisodeAudioPlayback(
        _ episode: PodcastEpisodeEntry,
        trackIndex: Int,
        trackCount: Int,
        presentsFullscreen: Bool = true,
        resetTransitionState: Bool = true,
    ) {
        guard let mediaURL = episode.mediaURL?.standardizedFileURL else { return }
        #if os(macOS)
            // A download macOS won't let First Row open plays from the podcast's feed instead.
            if mediaURL.isFileURL, !PodcastFeedStreams.canRead(mediaURL) {
                playPodcastEpisodeFromFeed(episode, trackIndex: trackIndex, trackCount: trackCount, presentsFullscreen: presentsFullscreen, resetTransitionState: resetTransitionState)
                return
            }
        #endif
        startAudioOnlyPlayback(
            from: mediaURL,
            title: episode.title,
            artist: episode.artist,
            album: episode.seriesTitle,
            // (Its own picture, else its show's, as its menus have it.)
            artwork: episode.artwork ?? podcastSeriesItems.first(where: { $0.id == episode.seriesID })?.artwork ?? podcastFallbackImage,
            playbackID: episode.id,
            trackIndex: trackIndex,
            trackCount: trackCount,
            showsTrackPosition: true,
            presentsFullscreen: presentsFullscreen,
            resetTransitionState: resetTransitionState,
        )
        activePodcastPlaybackSeriesID = episode.seriesID
        activePodcastPlaybackEpisodeID = episode.id
        // Keep the owning series selected in the hidden second-level menu immediately
        // so "Now Playing" insertion does not visibly shift rows on back navigation.
        if activeRootItemID == "podcasts", isInSubmenu {
            let targetSeriesMenuItemID = "\(podcastSeriesSubmenuItemPrefix)\(episode.seriesID)"
            let submenuItems = currentSubmenuItems()
            if let seriesIndex = submenuItems.firstIndex(where: { $0.id == targetSeriesMenuItemID }) {
                selectedSubIndex = seriesIndex
            }
        }
    }

    func podcastPlaybackContextForEpisode(_ episode: PodcastEpisodeEntry) -> (trackIndex: Int, trackCount: Int) {
        let episodes = podcastSeriesItems.first(where: { $0.id == episode.seriesID })?.episodes
            ?? podcastEpisodesThirdMenuItems.filter { $0.seriesID == episode.seriesID }
        guard !episodes.isEmpty else { return (0, 1) }
        let trackIndex = episodes.firstIndex(where: { $0.id == episode.id }) ?? 0
        return (trackIndex, episodes.count)
    }

    func startPodcastEpisodePlayback(_ episode: PodcastEpisodeEntry) {
        guard let mediaURL = episode.mediaURL?.standardizedFileURL else { return }
        #if os(macOS)
            // A download macOS won't let First Row open (audio or video) plays from the podcast's
            // feed instead.
            if mediaURL.isFileURL, !PodcastFeedStreams.canRead(mediaURL) {
                let context = podcastPlaybackContextForEpisode(episode)
                playPodcastEpisodeFromFeed(episode, trackIndex: context.trackIndex, trackCount: context.trackCount, presentsFullscreen: true, resetTransitionState: true)
                return
            }
        #endif
        let hasVideoTrack = mediaTrackFlags(for: mediaURL).hasVideo
        if hasVideoTrack {
            clearActivePodcastAudioPlaybackContext()
            startMoviePlayback(from: mediaURL)
            return
        }
        if episode.isVideo, !shouldTreatAsAudioOnlyPlayback(url: mediaURL) {
            clearActivePodcastAudioPlaybackContext()
            startMoviePlayback(from: mediaURL)
            return
        }
        let context = podcastPlaybackContextForEpisode(episode)
        startPodcastEpisodeAudioPlayback(
            episode,
            trackIndex: context.trackIndex,
            trackCount: context.trackCount,
        )
    }

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
                MainActor.assumeIsolatedIfPossible {
                    guard self.observedMusicAudioPlayer === player else { return }
                    let resolvedDuration = self.resolvedMusicDurationSeconds(for: player)
                    self.musicNowPlayingDurationSeconds = max(self.musicNowPlayingDurationSeconds, resolvedDuration)
                    self.musicNowPlayingElapsedSeconds = self.musicNowPlayingDurationSeconds
                    self.stopMusicScrubbing(showPauseGlyph: false)
                    self.musicNowPlayingLeadingGlyphState = nil
                    if self.musicNowPlayingArtist == "iTunes Top Songs" {
                        if self.activeFullscreenScene?.key == self.musicNowPlayingFullscreenKey {
                            self.dismissFullscreenScene(preserveMusicPlayback: false)
                        } else {
                            // Finished off screen: end the session so the Music menu drops its Now Playing row.
                            self.stopMusicPlaybackSession(clearDisplayState: false)
                        }
                    } else {
                        self.switchMusicNowPlayingTrack(direction: 1)
                    }
                    self.updateMusicNowPlayingFlipTimerState()
                }
            }
        }
        let interval = CMTime(seconds: 1.0 / 20.0, preferredTimescale: 600)
        #if os(iOS)
            var lastStrayCheck = CACurrentMediaTime()
        #endif
        musicTimeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            #if os(iOS)
                // Never two songs: First Row's system player, if it's somehow still going while a
                // file plays, is stopped (checked every couple of seconds, off the main thread).
                let now = CACurrentMediaTime()
                if now - lastStrayCheck > 2, player.rate > 0.01, SystemMusicPlayerCalls.hasStarted {
                    lastStrayCheck = now
                    SystemMusicPlayerCalls.stopStray()
                }
            #endif
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

        #if os(tvOS)
        func startMusicPlaybackUsingMusicKit(song: Song) {
            removeMusicPlaybackObservation()
            musicAudioPlayer = nil
            observedMusicAudioPlayer = nil
            stopMusicKitProgressTimer()
            musicKitScrubGlyphResetWorkItem?.cancel()
            musicKitScrubGlyphResetWorkItem = nil
            musicKitDidHandleTrackEnd = false
            musicSongsLoadError = nil
            musicNowPlayingDurationSeconds = max(0, song.duration ?? 0)
            musicNowPlayingElapsedSeconds = 0
            // (A stop still waiting for the song before gives way to this one.)
            MusicKitPlayerCalls.noteStart()
            Task { @MainActor in
                do {
                    let player = ApplicationMusicPlayer.shared
                    player.queue = ApplicationMusicPlayer.Queue(for: [song], startingAt: song)
                    try await player.play()
                    refreshMusicKitPlaybackProgress()
                    startMusicKitProgressTimerIfNeeded()
                    updateMusicNowPlayingFlipTimerState()
                    // Straight after another song the player can drop a new song as it starts;
                    // start it again if it stops before it has really played. A song that is
                    // only slow to start can look the same for a moment, so it's looked at
                    // twice: starting one again that was about to play is a stop and a start
                    // to the ear.
                    @MainActor func hasDropped() async -> Bool {
                        guard player.state.playbackStatus == .stopped, self.musicNowPlayingLeadingGlyphState != .pause else { return false }
                        return await MusicKitPlayerCalls.playbackTime() < 0.5
                    }
                    var retries = 0
                    for _ in 0 ..< 30 {
                        try? await firstRowSleep(0.1)
                        guard activeMusicPlaybackSongID == song.id.rawValue else { return }
                        guard retries < 2, await hasDropped() else { continue }
                        try? await firstRowSleep(0.3)
                        guard activeMusicPlaybackSongID == song.id.rawValue else { return }
                        guard await hasDropped() else { continue }
                        retries += 1
                        player.queue = ApplicationMusicPlayer.Queue(for: [song], startingAt: song)
                        try await player.play()
                    }
                } catch {
                    // (Not a song that has been moved on from: stopping it for the next one
                    // can end its start with an error.)
                    guard self.activeMusicPlaybackSongID == song.id.rawValue else { return }
                    self.musicSongsLoadError = self.musicLibraryErrorMessage(for: error)
                }
            }
        }

        /// Asks the system's player where it is in its song (off the main thread: see
        /// `MusicKitPlayerCalls`) and brings the progress up to date with the answer.
        func refreshMusicKitPlaybackProgress() {
            guard activeMusicPlaybackSongID != nil else {
                stopMusicKitProgressTimer()
                return
            }
            // One question at a time: an answer can take longer than the time between them.
            guard !isReadingMusicKitProgress else { return }
            isReadingMusicKitProgress = true
            let songID = activeMusicPlaybackSongID
            Task { @MainActor in
                let currentTime = await MusicKitPlayerCalls.playbackTime()
                self.isReadingMusicKitProgress = false
                guard self.activeMusicPlaybackSongID == songID else { return }
                self.applyMusicKitPlaybackProgress(currentTime)
            }
        }

        private func applyMusicKitPlaybackProgress(_ currentTime: TimeInterval) {
            let playbackStatus = ApplicationMusicPlayer.shared.state.playbackStatus
            let elapsed = max(0, currentTime.isFinite ? currentTime : 0)
            if musicScrubDirection == 0 {
                musicNowPlayingElapsedSeconds = elapsed
            }
            if musicNowPlayingDurationSeconds <= 0,
               let activeMusicPlaybackSongID,
               let activeSong = musicSongsThirdMenuItems.first(where: { $0.id == activeMusicPlaybackSongID }),
               let duration = activeSong.musicKitSong?.duration,
               duration.isFinite,
               duration > 0
            {
                musicNowPlayingDurationSeconds = duration
            }
            let duration = musicNowPlayingDurationSeconds
            if duration > 0 {
                let isAtOrPastEnd = elapsed >= (duration - 0.05)
                let didStopAtEnd = playbackStatus == .stopped
                if isAtOrPastEnd && didStopAtEnd && !musicKitDidHandleTrackEnd {
                    musicKitDidHandleTrackEnd = true
                    stopMusicScrubbing(showPauseGlyph: false)
                    musicNowPlayingLeadingGlyphState = nil
                    switchMusicNowPlayingTrack(direction: 1)
                } else if !isAtOrPastEnd || playbackStatus == .playing {
                    musicKitDidHandleTrackEnd = false
                }
            }
        }
        #endif
        #if os(tvOS) || os(iOS)
        func startMusicKitProgressTimerIfNeeded() {
            guard musicKitProgressTimer == nil else { return }
            let timer = Timer(after: 1.0 / 10.0, repeats: true) { _ in
                self.refreshMusicKitPlaybackProgress()
            }
            RunLoop.main.add(timer, forMode: .common)
            musicKitProgressTimer = timer
        }

        func stopMusicKitProgressTimer() {
            musicKitProgressTimer?.invalidate()
            musicKitProgressTimer = nil
        }
        #endif
        #if os(iOS)
        /// Run on `SystemMusicPlayerCalls`' queue.
        nonisolated func setMediaPlayerQueue(for song: MusicLibrarySongEntry) -> Bool {
            guard let persistentID = UInt64(song.id) else { return false }
            let predicate = MPMediaPropertyPredicate(
                value: NSNumber(value: persistentID),
                forProperty: MPMediaItemPropertyPersistentID,
                comparisonType: .equalTo,
            )
            let player = MPMusicPlayerController.applicationQueuePlayer
            player.repeatMode = .none
            player.shuffleMode = .off
            player.setQueue(with: MPMediaQuery(filterPredicates: [predicate]))
            return true
        }

        /// Apple Music and cloud songs have no file, so the system player streams them.
        func startMusicPlaybackUsingMediaPlayer(_ song: MusicLibrarySongEntry) {
            removeMusicPlaybackObservation()
            musicAudioPlayer = nil
            observedMusicAudioPlayer = nil
            stopMusicKitProgressTimer()
            musicKitDidHandleTrackEnd = false
            musicMediaPlayerWasPlaying = false
            musicSongsLoadError = nil
            // A stop still waiting for the song before gives way to this one.
            SystemMusicPlayerCalls.noteStart()
            isCurrentMusicPlaybackUsingMediaPlayer = true
            Task { @MainActor in
                // Everything the system player is told goes through one queue off the main
                // thread, in order, after any stop still under way.
                let queued = await SystemMusicPlayerCalls.run { () -> Bool in
                    // Mix with other audio, or each interface sound stops the system player.
                    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
                    return self.setMediaPlayerQueue(for: song)
                }
                guard activeMusicPlaybackSongID == song.id else { return }
                guard queued else {
                    isCurrentMusicPlaybackUsingMediaPlayer = false
                    return
                }
                if let error = await SystemMusicPlayerCalls.prepareToPlay() {
                    guard activeMusicPlaybackSongID == song.id else { return }
                    musicSongsLoadError = musicLibraryErrorMessage(for: error)
                    return
                }
                // (Paused while it got ready: it waits for Play.)
                guard activeMusicPlaybackSongID == song.id, musicNowPlayingLeadingGlyphState != .pause else { return }
                SystemMusicPlayerCalls.send { MPMusicPlayerController.applicationQueuePlayer.play() }
                musicMediaPlayerWasPlaying = true
                musicMediaPlayerAskedToPlay = AskedPlayState(playing: true)
                refreshMusicKitPlaybackProgress()
                startMusicKitProgressTimerIfNeeded()
                // Straight after another song the player can drop a new song as it starts;
                // start it again if it stops before it has really played.
                @MainActor func hasDropped() async -> Bool {
                    let state = await SystemMusicPlayerCalls.state()
                    return (state.playbackState == .stopped || state.playbackState == .paused) &&
                        state.time < 0.5 &&
                        musicNowPlayingLeadingGlyphState != .pause
                }
                var retries = 0
                for _ in 0 ..< 30 {
                    try? await firstRowSleep(0.1)
                    guard activeMusicPlaybackSongID == song.id else { return }
                    if retries < 2, await hasDropped() {
                        try? await firstRowSleep(0.3)
                        guard activeMusicPlaybackSongID == song.id else { return }
                        guard await hasDropped() else { continue }
                        retries += 1
                        guard await SystemMusicPlayerCalls.run({ self.setMediaPlayerQueue(for: song) }) else { return }
                        _ = await SystemMusicPlayerCalls.prepareToPlay()
                        guard activeMusicPlaybackSongID == song.id else { return }
                        SystemMusicPlayerCalls.send { MPMusicPlayerController.applicationQueuePlayer.play() }
                    }
                }
            }
        }

        /// Reads where the system player is (off the main thread) and follows it: the time, a
        /// pause, and the end of the song.
        func refreshMusicKitPlaybackProgress() {
            guard isCurrentMusicPlaybackUsingMediaPlayer, activeMusicPlaybackSongID != nil else {
                stopMusicKitProgressTimer()
                return
            }
            guard !SystemMusicPlayerCalls.isReadingProgress else { return }
            SystemMusicPlayerCalls.isReadingProgress = true
            let songID = activeMusicPlaybackSongID
            Task { @MainActor in
                let state = await SystemMusicPlayerCalls.state()
                SystemMusicPlayerCalls.isReadingProgress = false
                guard self.activeMusicPlaybackSongID == songID, self.isCurrentMusicPlaybackUsingMediaPlayer else { return }
                self.followMediaPlayer(state)
            }
        }

        private func followMediaPlayer(_ state: SystemMusicPlayerCalls.State) {
            let isPlaying = AskedPlayState.settle(state.isPlaying, &musicMediaPlayerAskedToPlay)
            // Never two songs: a file player left going stops (the system player has the song).
            if isPlaying, let stray = musicAudioPlayer, stray.rate > 0.01 {
                stray.pause()
            }
            if isPlaying != musicMediaPlayerWasPlaying {
                musicMediaPlayerWasPlaying = isPlaying
                updateMusicNowPlayingFlipTimerState()
            }
            let duration = musicNowPlayingDurationSeconds
            // At the end of its queue the player stops and may rewind, so judge the end by where it last was.
            let wasNearEnd = duration > 0 && musicNowPlayingElapsedSeconds >= duration - 1.5
            if !isPlaying, wasNearEnd, musicScrubDirection == 0, musicNowPlayingLeadingGlyphState != .pause {
                guard !musicKitDidHandleTrackEnd else { return }
                musicKitDidHandleTrackEnd = true
                stopMusicScrubbing(showPauseGlyph: false)
                musicNowPlayingLeadingGlyphState = nil
                switchMusicNowPlayingTrack(direction: 1)
                return
            }
            if isPlaying {
                musicKitDidHandleTrackEnd = false
            }
            if musicScrubDirection == 0, state.hasItem, state.time.isFinite {
                musicNowPlayingElapsedSeconds = max(0, state.time)
            }
        }
        #endif
    func stopMusicPlaybackSession(
        clearDisplayState: Bool = true,
        preserveSystemMusicPlayback: Bool = false,
        pauseSystemMusicPlayback: Bool = true,
    ) {
        stopMusicScrubbing(showPauseGlyph: false)
        musicPlaybackStartingUntil = nil
        cancelScreenSaverMusicTrackSwitchQueue()
        endJellyfinMusicReporting()
        _ = incrementRequestID(&musicPlaybackRequestID)
        _ = incrementRequestID(&musicNowPlayingArtworkRequestID)
        musicAudioPlayer?.pause()
        stopSpotifyPlayback(pause: pauseSystemMusicPlayback && !preserveSystemMusicPlayback)
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
            musicAppleScriptAskedToPlay = nil
            musicAppleScriptProgressAnchorDate = nil
            musicAppleScriptProgressAnchorElapsedSeconds = 0
            musicAppleScriptCurrentTrackPersistentIDHex = nil
            musicAppleScriptDidHandleTrackBoundary = false
        #endif
        #if os(tvOS)
            if pauseSystemMusicPlayback {
                stopSystemMusicPlayerSoon()
            }
            stopMusicKitProgressTimer()
            musicKitScrubGlyphResetWorkItem?.cancel()
            musicKitScrubGlyphResetWorkItem = nil
            musicKitDidHandleTrackEnd = false
        #endif
        #if os(iOS)
            if isCurrentMusicPlaybackUsingMediaPlayer, pauseSystemMusicPlayback {
                stopSystemMusicPlayerSoon()
            }
            isCurrentMusicPlaybackUsingMediaPlayer = false
            stopMusicKitProgressTimer()
            musicKitDidHandleTrackEnd = false
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
        invalidateMusicNowPlayingFlipTimer()
        musicNowPlayingFlipMidpointWorkItem?.cancel()
        musicNowPlayingFlipMidpointWorkItem = nil
        if isMusicNowPlayingFlipAnimating {
            cancelMusicNowPlayingFlipAnimation()
        }
        if clearDisplayState {
            clearMusicNowPlayingDisplayState()
            resetMusicNowPlayingFlipState()
        }
        resetScreenSaverIdleTimer()
    }

    #if os(iOS) || os(tvOS)
        /// The system player's stop waits on the media server, often for a few hundred
        /// milliseconds. First Row's own state is cleared already; this runs once whatever the
        /// stop belongs to (a menu moving on, say) has started on screen. It's skipped only when
        /// the system player has been given a new song meanwhile (its new queue replaces the
        /// old); a song that plays from its file instead still needs the old one stopped.
        private func stopSystemMusicPlayerSoon() {
            #if os(iOS)
                // Off the main thread altogether: the stop can take a second or more, and on the
                // main thread it held up whatever moved next.
                SystemMusicPlayerCalls.stop()
            #else
                // Off the main thread here too, and not at all if a song has been given to the
                // system player meanwhile.
                MusicKitPlayerCalls.stopSoon()
            #endif
        }
    #endif

    #if os(tvOS)
        /// What Apple TV's music player is asked and told off the main thread, in order: its
        /// stop, pause and seek, and where it is in its song. Each is a round trip to the
        /// system's music service; a stop can take a second or more, and the question was
        /// asked ten times a second, all of which held the main thread up.
        enum MusicKitPlayerCalls {
            private static let queue = DispatchQueue(label: "firstrow.musickit-player", qos: .userInitiated)
            private static let lock = NSLock()
            nonisolated(unsafe) private static var startCount = 0

            /// A song has been given to the player: a stop asked for before it is dropped.
            static func noteStart() {
                lock.lock()
                startCount += 1
                lock.unlock()
            }

            private static var currentStartCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return startCount
            }

            static func stopSoon() {
                let startsBefore = currentStartCount
                queue.asyncAfter(deadline: .now() + 0.05) {
                    guard currentStartCount == startsBefore else { return }
                    ApplicationMusicPlayer.shared.stop()
                }
            }

            /// Asks the queue to do something, without waiting for it.
            static func send(_ work: @escaping @Sendable () -> Void) {
                queue.async(execute: work)
            }

            static func playbackTime() async -> TimeInterval {
                await withCheckedContinuation { continuation in
                    queue.async { continuation.resume(returning: ApplicationMusicPlayer.shared.playbackTime) }
                }
            }
        }
    #endif

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

    func updateMusicNowPlayingFlipTimerState() {
        noteNowPlayingPlaybackChanged()
        let isMusicSceneVisible = activeFullscreenScene?.key == musicNowPlayingFullscreenKey
        let isMusicPlaying = isMusicPlaybackRunning()
        // Not while the list or the words are beside it, nor while the song is being scrubbed
        // (the wait starts again once it's let go).
        let shouldRun = isMusicSceneVisible && isMusicPlaying && !isMovieTransitioning && !isMoviePlaybackVisible &&
            allowsNowPlayingFlip && musicScrubDirection == 0
        if !shouldRun {
            invalidateMusicNowPlayingFlipTimer()
            // Let a flip under way finish, or the panel is left edge-on until the next song.
            if isMusicNowPlayingFlipAnimating, isMusicSceneVisible {
                return
            }
            musicNowPlayingFlipMidpointWorkItem?.cancel()
            musicNowPlayingFlipMidpointWorkItem = nil
            if isMusicNowPlayingFlipAnimating {
                cancelMusicNowPlayingFlipAnimation()
            } else {
                musicNowPlayingFlipRotationDegrees = 0
            }
            return
        }
        guard musicNowPlayingFlipTimer == nil else { return }
        let timer = Timer(after: musicNowPlayingFlipInterval, repeats: true) { _ in
            MainActor.assumeIsolatedIfPossible {
                self.performMusicNowPlayingFlip()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        musicNowPlayingFlipTimer = timer
    }

    /// Whether Now Playing turns round every so often as things stand. Lying down: not with
    /// the list or the words beside it. Standing upright it's the other way about: the cover is
    /// above the fold and the details under it, with no sides to change, until the list or the
    /// words are out and the two are side by side above the fold.
    var allowsNowPlayingFlip: Bool {
        guard upright != nil else { return !isNowPlayingQueueVisible && !isNowPlayingLyricsVisible }
        return nowPlayingGlide == nil && (isNowPlayingLyricsVisible || (isNowPlayingQueueVisible && nowPlayingQueueReveal >= 1))
    }

    func performMusicNowPlayingFlip() {
        guard activeFullscreenScene?.key == musicNowPlayingFullscreenKey else { return }
        guard allowsNowPlayingFlip, upright != nil || nowPlayingQueueReveal <= 0 else { return }
        guard musicScrubDirection == 0 else {
            invalidateMusicNowPlayingFlipTimer()
            return
        }
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
        musicNowPlayingFlipMidpointWorkItem = Task {
            try? await firstRowSleep(halfDuration)
            guard !Task.isCancelled else { return }
            guard generation == musicNowPlayingFlipGeneration else { return }
            guard activeFullscreenScene?.key == musicNowPlayingFullscreenKey else {
                // Now Playing went away mid-turn: face front again for next time.
                cancelMusicNowPlayingFlipAnimation()
                return
            }
            musicNowPlayingUsesAlternateLayout.toggle()
            var resetTransaction = Transaction()
            resetTransaction.disablesAnimations = true
            withTransaction(resetTransaction) {
                musicNowPlayingFlipRotationDegrees = -halfTurnDegrees
            }
            withAnimation(.linear(duration: halfDuration)) {
                musicNowPlayingFlipRotationDegrees = 0
            }
            try? await firstRowSleep(halfDuration)
            guard !Task.isCancelled else { return }
            guard generation == musicNowPlayingFlipGeneration else { return }
            isMusicNowPlayingFlipAnimating = false
        }
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

    /// Whether Now Playing has songs either side to change to: not for a single preview.
    var canSwitchMusicNowPlayingTrack: Bool {
        if isPlayingSpotifyAdvert { return false }
        if isPodcastAudioNowPlaying {
            return activePodcastPlaybackEpisodes().count > 1
        }
        if thirdMenuMode == .musicITunesTopSongs || musicNowPlayingArtist == "iTunes Top Songs" {
            return false
        }
        return resolvedActiveMusicPlaybackQueue().count > 1
    }

    /// Spotify is playing an advert between songs: there's nothing to skip to until it ends.
    var isPlayingSpotifyAdvert: Bool {
        isCurrentMusicPlaybackUsingSpotify && spotifyShowsAdvert
    }

    /// Moves Now Playing a song on or back, or (`toIndex`) straight to a song in its list.
    func switchMusicNowPlayingTrack(direction: Int, toIndex explicitIndex: Int? = nil) {
        guard direction != 0 || explicitIndex != nil else { return }
        guard !isPlayingSpotifyAdvert else {
            playLimitSoundOnceForCurrentHold()
            return
        }
        if isMusicSongTransitioning {
            if let deadline = musicSongTransitionDeadline, deadline > Date() {
                return
            }
            let isMusicNowPlayingSceneVisible = activeFullscreenScene?.key == musicNowPlayingFullscreenKey
            if !isMusicNowPlayingSceneVisible {
                return
            }
            clearMusicSongSwitchTransitionState()
        }
        if isPodcastAudioNowPlaying {
            let episodes = activePodcastPlaybackEpisodes()
            guard !episodes.isEmpty else { return }
            guard let currentEpisodeID = activePodcastPlaybackEpisodeID else { return }
            guard let currentIndex = episodes.firstIndex(where: { $0.id == currentEpisodeID }) else { return }
            let targetIndex = max(0, min(episodes.count - 1, explicitIndex ?? currentIndex + direction))
            guard targetIndex != currentIndex else { return }
            let direction = targetIndex > currentIndex ? 1 : -1
            let targetEpisode = episodes[targetIndex]
            let isMusicNowPlayingSceneVisible = activeFullscreenScene?.key == musicNowPlayingFullscreenKey
            if isMusicNowPlayingSceneVisible {
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
                startPodcastEpisodeAudioPlayback(
                    targetEpisode,
                    trackIndex: targetIndex,
                    trackCount: episodes.count,
                    presentsFullscreen: true,
                    resetTransitionState: false,
                )
                if isInThirdMenu,
                   thirdMenuMode == .podcastsEpisodes,
                   activePodcastSeriesID == targetEpisode.seriesID
                {
                    selectedThirdIndex = targetIndex
                }
                guard musicSongTransitionRequestID == transitionGeneration else { return }
                let outgoingFadeAnimation: Animation = direction > 0
                    ? .easeOut(duration: musicSongOutgoingFadeDuration)
                    : .easeInOut(duration: musicSongSwitchTransitionDuration)
                withAnimation(.easeInOut(duration: musicSongSwitchTransitionDuration)) {
                    musicSongTransitionOutgoingProgress = 1
                }
                withAnimation(outgoingFadeAnimation) {
                    musicSongTransitionOutgoingOpacityProgress = 1
                }
                Task {
                    try? await firstRowSleep(musicSongIncomingTransitionDelay)
                    guard !Task.isCancelled else { return }
                    guard self.musicSongTransitionRequestID == transitionGeneration else { return }
                    withAnimation(.easeInOut(duration: musicSongSwitchTransitionDuration)) {
                        musicSongTransitionIncomingProgress = 1
                    }
                    try? await firstRowSleep(musicSongSwitchTransitionDuration)
                    guard !Task.isCancelled else { return }
                    guard self.musicSongTransitionRequestID == transitionGeneration else { return }
                    clearMusicSongSwitchTransitionState()
                    updateMusicNowPlayingFlipTimerState()
                }
                return
            }
            clearMusicSongSwitchTransitionState()
            startPodcastEpisodeAudioPlayback(
                targetEpisode,
                trackIndex: targetIndex,
                trackCount: episodes.count,
                presentsFullscreen: isMusicNowPlayingSceneVisible,
            )
            if isInThirdMenu,
               thirdMenuMode == .podcastsEpisodes,
               activePodcastSeriesID == targetEpisode.seriesID
            {
                selectedThirdIndex = targetIndex
            }
            return
        }
        if thirdMenuMode == .musicITunesTopSongs || musicNowPlayingArtist == "iTunes Top Songs" {
            return
        }
        let playbackQueue = resolvedActiveMusicPlaybackQueue()
        guard !playbackQueue.isEmpty else { return }
        let fallbackIndex = direction > 0 ? -1 : playbackQueue.count
        let currentIndex = activeMusicPlaybackIndex() ?? fallbackIndex
        let targetIndex = max(0, min(playbackQueue.count - 1, explicitIndex ?? currentIndex + direction))
        guard targetIndex != currentIndex else { return }
        let direction = targetIndex > currentIndex ? 1 : -1
        let targetSong = playbackQueue[targetIndex]
        let isMusicNowPlayingSceneVisible = activeFullscreenScene?.key == musicNowPlayingFullscreenKey
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
        if thirdMenuMode != .spotify {
            selectedThirdIndex = thirdMenuSelectionIndex(forMusicSongIndex: targetIndex)
        }
        startMusicPlayback(
            from: targetSong,
            trackIndex: targetIndex,
            trackCount: playbackQueue.count,
            resetTransitionState: false,
            playbackQueue: playbackQueue,
        )
        guard musicSongTransitionRequestID == transitionGeneration else { return }
        let outgoingFadeAnimation: Animation = direction > 0
            ? .easeOut(duration: musicSongOutgoingFadeDuration)
            : .easeInOut(duration: musicSongSwitchTransitionDuration)
        withAnimation(.easeInOut(duration: musicSongSwitchTransitionDuration)) {
            musicSongTransitionOutgoingProgress = 1
        }
        withAnimation(outgoingFadeAnimation) {
            musicSongTransitionOutgoingOpacityProgress = 1
        }
        Task {
            try? await firstRowSleep(musicSongIncomingTransitionDelay)
            guard !Task.isCancelled else { return }
            guard self.musicSongTransitionRequestID == transitionGeneration else { return }
            withAnimation(.easeInOut(duration: musicSongSwitchTransitionDuration)) {
                musicSongTransitionIncomingProgress = 1
            }
            try? await firstRowSleep(musicSongSwitchTransitionDuration)
            guard !Task.isCancelled else { return }
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
        // Play and pause from an on-screen button show on the button, not as a glyph.
        hidesMusicLeadingGlyph = isPressingOnScreenPlaybackButton
        // The list, while it's out, takes up, down and Select (but not the on-screen Previous
        // and Next, which still change the song).
        if isNowPlayingQueueVisible, !isPressingOnScreenPlaybackButton {
            switch key {
            case .upArrow:
                moveNowPlayingQueueFocus(by: -1)
                return
            case .downArrow:
                moveNowPlayingQueueFocus(by: 1)
                return
            case .enter:
                chooseFocusedNowPlayingQueueRow()
                return
            default:
                break
            }
        }
        switch key {
        case .delete, .escape:
            // The lyrics or the list go first.
            if isNowPlayingLyricsVisible {
                toggleNowPlayingLyrics()
                return
            }
            if isNowPlayingQueueVisible {
                hideNowPlayingQueue()
                playSound(named: "Exit")
                return
            }
            stopMusicScrubbing(showPauseGlyph: false)
            clearMusicSongSwitchTransitionState()
            dismissFullscreenScene(preserveMusicPlayback: true)
            playSound(named: "Exit")
        case .enter where hasNowPlayingLyrics || isNowPlayingLyricsVisible:
            // Select shows the song's words, when it has some; Play/Pause still pauses.
            toggleNowPlayingLyrics()
        case .space, .enter:
            handleMusicSpacebarPressed()
        case .upArrow:
            switchMusicNowPlayingTrack(direction: -1)
        case .downArrow:
            switchMusicNowPlayingTrack(direction: 1)
        case .leftArrow:
            beginMusicScrubbing(direction: -1, isRepeat: isRepeat)
        case .rightArrow:
            beginMusicScrubbing(direction: 1, isRepeat: isRepeat)
        default:
            break
        }
    }

    func handleMusicSpacebarPressed() {
        // A song still getting going after one that was playing shows as playing, so a press
        // then pauses it (and keeps it from starting).
        let startingUp = !isMusicPlaybackRunning() && isMusicPlaybackRunningOrStarting()
        musicPlaybackStartingUntil = nil
        if musicAudioPlayer == nil, isCurrentMusicPlaybackUsingSpotify, activeMusicPlaybackSongID != nil {
            toggleSpotifyPlayback(pausing: startingUp)
            return
        }
        #if os(tvOS)
            if musicAudioPlayer == nil,
               activeMusicPlaybackSongID != nil,
               !isCurrentMusicPlaybackUsingAppleScript
            {
                let player = ApplicationMusicPlayer.shared
                let status = player.state.playbackStatus
                let isPlaying = status == .playing || status == .seekingForward || status == .seekingBackward
                if isPlaying || startingUp {
                    MusicKitPlayerCalls.send { ApplicationMusicPlayer.shared.pause() }
                    stopMusicScrubbing(showPauseGlyph: false)
                    musicNowPlayingLeadingGlyphState = .pause
                } else {
                    stopMusicScrubbing(showPauseGlyph: false)
                    musicNowPlayingLeadingGlyphState = nil
                    Task {
                        try? await player.play()
                        await MainActor.run {
                            self.startMusicKitProgressTimerIfNeeded()
                        }
                    }
                }
                startMusicKitProgressTimerIfNeeded()
                refreshMusicKitPlaybackProgress()
                updateMusicNowPlayingFlipTimerState()
                return
            }
        #endif
        #if os(iOS)
            if musicAudioPlayer == nil, isCurrentMusicPlaybackUsingMediaPlayer, activeMusicPlaybackSongID != nil {
                stopMusicScrubbing(showPauseGlyph: false)
                // As the progress reads last found it; the play or pause itself goes off the
                // main thread.
                let pausing = musicMediaPlayerWasPlaying || startingUp
                if pausing {
                    SystemMusicPlayerCalls.send { MPMusicPlayerController.applicationQueuePlayer.pause() }
                    musicNowPlayingLeadingGlyphState = .pause
                } else {
                    musicNowPlayingLeadingGlyphState = nil
                    SystemMusicPlayerCalls.send { MPMusicPlayerController.applicationQueuePlayer.play() }
                }
                musicMediaPlayerWasPlaying = !pausing
                musicMediaPlayerAskedToPlay = AskedPlayState(playing: !pausing)
                startMusicKitProgressTimerIfNeeded()
                refreshMusicKitPlaybackProgress()
                updateMusicNowPlayingFlipTimerState()
                return
            }
        #endif
        #if os(macOS)
            if musicAudioPlayer == nil, isCurrentMusicPlaybackUsingAppleScript, activeMusicPlaybackSongID != nil {
                stopMusicScrubbing(showPauseGlyph: false)
                let shouldPause = musicAppleScriptIsPlaying || startingUp
                showMusicAppleScriptAsked(playing: !shouldPause)
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
                            // Music didn't take it: back to what it was doing.
                            self.musicAppleScriptAskedToPlay = nil
                            self.musicAppleScriptIsPlaying = shouldPause
                            self.musicNowPlayingLeadingGlyphState = shouldPause ? nil : .pause
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
        #endif
        guard let player = musicAudioPlayer else { return }
        let isCurrentlyPlaying = player.rate > 0.01 || startingUp
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
        guard direction != 0 else { return }
        guard !isMusicSongTransitioning else { return }
        if musicAudioPlayer == nil, isCurrentMusicPlaybackUsingSpotify, activeMusicPlaybackSongID != nil, musicScrubDirection != direction {
            pauseSpotifyForScrubbing()
        }
        #if os(tvOS) || os(macOS)
            #if os(macOS)
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
            #endif
            #if os(tvOS)
                if musicAudioPlayer == nil,
                   activeMusicPlaybackSongID != nil,
                   !isCurrentMusicPlaybackUsingAppleScript,
                   musicScrubDirection != direction
                {
                    MusicKitPlayerCalls.send { ApplicationMusicPlayer.shared.pause() }
                }
            #endif
        #endif
        #if os(iOS)
            if musicAudioPlayer == nil,
               isCurrentMusicPlaybackUsingMediaPlayer,
               activeMusicPlaybackSongID != nil,
               musicScrubDirection != direction
            {
                SystemMusicPlayerCalls.send { MPMusicPlayerController.applicationQueuePlayer.pause() }
            }
        #endif
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
            MainActor.assumeIsolatedIfPossible {
                self.handleMusicScrubTick()
            }
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
        if !isHoldingScrubKey(direction: musicScrubDirection), now.timeIntervalSince(lastInput) > movieScrubReleaseGracePeriod {
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
                    MusicKitPlayerCalls.send { ApplicationMusicPlayer.shared.playbackTime = targetSeconds }
                }
            #elseif os(iOS)
                if isCurrentMusicPlaybackUsingMediaPlayer, activeMusicPlaybackSongID != nil {
                    SystemMusicPlayerCalls.send { MPMusicPlayerController.applicationQueuePlayer.currentPlaybackTime = targetSeconds }
                }
            #endif
        }
    }

    func stopMusicScrubbing(showPauseGlyph: Bool) {
        let wasScrubbing = musicScrubDirection != 0
        let wasSpotifyScrubbing = musicScrubDirection != 0 && musicAudioPlayer == nil &&
            isCurrentMusicPlaybackUsingSpotify && activeMusicPlaybackSongID != nil
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
        #if os(tvOS) || os(macOS)
            musicKitScrubGlyphResetWorkItem?.cancel()
            musicKitScrubGlyphResetWorkItem = nil
        #endif
        #if os(macOS)
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
        #endif
        if wasSpotifyScrubbing {
            seekSpotify(toSeconds: musicNowPlayingElapsedSeconds)
        }
        if showPauseGlyph {
            musicNowPlayingLeadingGlyphState = .pause
        }
        // A scrub puts off the next turn of Now Playing by a whole wait.
        if wasScrubbing { invalidateMusicNowPlayingFlipTimer() }
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
            // An advert isn't one of the songs, so it has no place among them.
            trackPositionText: isPlayingSpotifyAdvert ? "" : musicNowPlayingTrackPositionText,
            elapsedSeconds: musicNowPlayingElapsedSeconds,
            durationSeconds: musicNowPlayingDurationSeconds,
            showsShuffleGlyph: musicNowPlayingShowsShuffleGlyph,
            leadingGlyphState: hidesMusicLeadingGlyph ? nil : musicNowPlayingLeadingGlyphState,
        )
    }
}

#if os(iOS)
    /// The system music player's stop, made one at a time on a queue of its own: it waits on
    /// the media server, sometimes for a second or more. A stop still waiting when a new song
    /// starts is dropped (the new queue replaces the old), and the new song waits for one
    /// already under way.
    enum SystemMusicPlayerCalls {
        private static let queue = DispatchQueue(label: "firstrow.system-music-player", qos: .userInitiated)
        private static let lock = NSLock()
        private static var startCount = 0

        @MainActor
        static func noteStart() {
            lock.lock()
            startCount += 1
            lock.unlock()
        }

        /// The system player has been used this session (so it might still be playing).
        static var hasStarted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return startCount > 0
        }

        private static var currentStartCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return startCount
        }

        @MainActor
        static func stop() {
            let startsBefore = currentStartCount
            queue.async {
                guard currentStartCount == startsBefore else { return }
                MPMusicPlayerController.applicationQueuePlayer.stop()
                guard currentStartCount == startsBefore else { return }
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            }
        }

        /// Returns once every stop asked for so far has finished.
        static func waitForStops() async {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume() }
            }
        }

        /// Runs `work` on the queue, after everything asked for before it.
        static func run<T>(_ work: @escaping () -> T) async -> T {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: work()) }
            }
        }

        /// Asks the queue to do something, without waiting for it.
        static func send(_ work: @escaping () -> Void) {
            queue.async(execute: work)
        }

        static func prepareToPlay() async -> Error? {
            await withCheckedContinuation { continuation in
                queue.async {
                    MPMusicPlayerController.applicationQueuePlayer.prepareToPlay { error in
                        continuation.resume(returning: error)
                    }
                }
            }
        }

        struct State {
            let playbackState: MPMusicPlaybackState
            let time: TimeInterval
            let hasItem: Bool

            var isPlaying: Bool {
                playbackState == .playing || playbackState == .seekingForward || playbackState == .seekingBackward
            }
        }

        static func state() async -> State {
            await run {
                let player = MPMusicPlayerController.applicationQueuePlayer
                return State(playbackState: player.playbackState, time: player.currentPlaybackTime, hasItem: player.nowPlayingItem != nil)
            }
        }

        /// A progress read is on its way (they don't queue up behind a slow one).
        @MainActor static var isReadingProgress = false

        /// Pauses the Music app's own player if it's playing something (other than the song with
        /// `persistentID`), so it never plays alongside First Row. Only with library access,
        /// which asking without would prompt for.
        @MainActor
        static func pauseMusicApp(unlessPlaying persistentID: String?) {
            guard MPMediaLibrary.authorizationStatus() == .authorized, !FirstRowHarness.isActive else { return }
            queue.async {
                let system = MPMusicPlayerController.systemMusicPlayer
                guard system.playbackState == .playing else { return }
                if let persistentID, let item = system.nowPlayingItem, String(item.persistentID) == persistentID { return }
                system.pause()
            }
        }

        /// Stops First Row's system player now, whatever started since (it's playing when a song
        /// from a file has the speakers).
        static func stopStray() {
            queue.async {
                let player = MPMusicPlayerController.applicationQueuePlayer
                guard player.playbackState == .playing else { return }
                player.stop()
            }
        }

        /// The cover of the song playing, if it's the one with `persistentID`.
        static func nowPlayingArtwork(persistentID: String) async -> NSImage? {
            await run {
                guard let item = MPMusicPlayerController.applicationQueuePlayer.nowPlayingItem,
                      String(item.persistentID) == persistentID
                else { return nil }
                return item.artwork?.image(at: CGSize(width: 800, height: 800))
            }
        }
    }
#endif
