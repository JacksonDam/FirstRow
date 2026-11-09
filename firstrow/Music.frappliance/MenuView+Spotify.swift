import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// A song that plays through Spotify.
struct SpotifyTrackReference {
    let uri: String
    let imageURL: URL?
    /// The playlist, album or artist it was chosen from.
    let contextURI: String?
}

/// Music > Spotify: the signed-in account's songs, playlists, albums and artists.
extension MenuView {
    enum SpotifyMenuPage: Equatable {
        case home
        case collections(SpotifyCollection.Kind)
    }

    struct SpotifyMenuPageState: Equatable {
        var page: SpotifyMenuPage
        var selectedIndex: Int
    }

    static let spotifyMenuItemID = "music_spotify"

    var currentSpotifyMenuPage: SpotifyMenuPage {
        spotifyMenuPages.last?.page ?? .home
    }

    // MARK: - Rows

    func spotifyMenuListItems() -> [MenuListItemConfig] {
        _ = spotifyRevision
        let session = SpotifySession.shared
        switch session.status {
        case .idle, .loading:
            return []
        case let .unavailable(reason):
            return [
                menuMessageItem(id: "spotify_message", title: reason),
                plainMenuListItem(id: "spotify_retry", title: "Try Again", showsTopDivider: true),
            ]
        case .signedOut:
            return [plainMenuListItem(id: "spotify_sign_in", title: "Sign In", trailingText: "...")]
        case .signedIn:
            break
        }
        switch currentSpotifyMenuPage {
        case .home:
            return [
                plainMenuListItem(id: "spotify_liked", title: "Liked Songs", leadsToMenu: true),
                plainMenuListItem(id: "spotify_playlists", title: "Playlists", leadsToMenu: true),
                plainMenuListItem(id: "spotify_albums", title: "Albums", leadsToMenu: true),
                plainMenuListItem(id: "spotify_artists", title: "Artists", leadsToMenu: true),
                plainMenuListItem(id: "spotify_sign_out", title: "Sign Out", showsTopDivider: true),
            ]
        case let .collections(kind):
            if isLoadingSpotifyMenu, spotifyCollections.isEmpty {
                return []
            }
            if let spotifyMenuError {
                return [menuMessageItem(id: "spotify_message", title: spotifyMenuError)]
            }
            if spotifyCollections.isEmpty {
                return [menuMessageItem(id: "spotify_message", title: Self.spotifyEmptyTitle(for: kind))]
            }
            return spotifyCollections.enumerated().map { index, collection in
                plainMenuListItem(id: "spotify_collection_\(index)", title: collection.name, leadsToMenu: true)
            }
        }
    }

    var shouldHideSpotifyMenuUntilLoaded: Bool {
        switch SpotifySession.shared.status {
        case .idle, .loading:
            true
        case .signedIn:
            isLoadingSpotifyMenu && spotifyCollections.isEmpty && spotifyMenuError == nil && currentSpotifyMenuPage != .home
        case .signedOut, .unavailable:
            false
        }
    }

    static func spotifyTitle(for page: SpotifyMenuPage) -> String {
        switch page {
        case .home: "Spotify"
        case .collections(.playlist): "Playlists"
        case .collections(.album): "Albums"
        case .collections(.artist): "Artists"
        }
    }

    static func spotifyEmptyTitle(for kind: SpotifyCollection.Kind) -> String {
        switch kind {
        case .playlist: "No Playlists"
        case .album: "No Saved Albums"
        case .artist: "No Followed Artists"
        }
    }

    // MARK: - Moving between pages

    func enterSpotifyMenu() {
        observeSpotifySessionIfNeeded()
        let session = SpotifySession.shared
        session.start()
        transitionMenuForFolderSwap(
            useOverlayFade: true,
            revealWhen: { !self.shouldHideSpotifyMenuUntilLoaded },
        ) {
            self.thirdMenuMode = .spotify
            self.isInThirdMenu = true
            self.spotifyMenuPages = [SpotifyMenuPageState(page: .home, selectedIndex: 0)]
            self.spotifyCollections = []
            self.spotifyMenuError = nil
            self.spotifySongsReturnPages = nil
            self.selectedThirdIndex = 0
            self.headerText = Self.spotifyTitle(for: .home)
            self.resetMusicPreviewState()
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
        }
    }

    private func observeSpotifySessionIfNeeded() {
        guard spotifySessionObserver == nil else { return }
        spotifySessionObserver = NotificationCenter.default.addObserver(
            forName: SpotifySession.didChangeNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible {
                self?.handleSpotifySessionChange()
            }
        }
    }

    private func handleSpotifySessionChange() {
        spotifyRevision &+= 1
        let status = SpotifySession.shared.status
        if status != .signedIn {
            if isCurrentMusicPlaybackUsingSpotify {
                if activeFullscreenScene?.key == musicNowPlayingFullscreenKey {
                    dismissFullscreenScene(preserveMusicPlayback: false)
                } else {
                    stopMusicPlaybackSession(clearDisplayState: true, pauseSystemMusicPlayback: false)
                }
            }
            // Signed out under a list: back to the first page.
            if thirdMenuMode == .spotify, spotifyMenuPages.count > 1 {
                spotifyMenuPages = [SpotifyMenuPageState(page: .home, selectedIndex: 0)]
                headerText = Self.spotifyTitle(for: .home)
            }
        }
        guard thirdMenuMode == .spotify else { return }
        let count = spotifyMenuListItems().count
        if selectedThirdIndex >= count {
            selectedThirdIndex = max(0, count - 1)
        }
        refreshDetailPreviewForCurrentContext()
    }

    private func pushSpotifyCollectionsPage(_ kind: SpotifyCollection.Kind) {
        let requestID = incrementRequestID(&spotifyMenuRequestID)
        transitionMenuForFolderSwap(revealWhen: { !self.shouldHideSpotifyMenuUntilLoaded }) {
            if var current = self.spotifyMenuPages.popLast() {
                current.selectedIndex = self.selectedThirdIndex
                self.spotifyMenuPages.append(current)
            }
            self.spotifyMenuPages.append(SpotifyMenuPageState(page: .collections(kind), selectedIndex: 0))
            self.spotifyCollections = []
            self.spotifyMenuError = nil
            self.isLoadingSpotifyMenu = true
            self.selectedThirdIndex = 0
            self.headerText = Self.spotifyTitle(for: .collections(kind))
            self.resetMusicPreviewState()
            Task { @MainActor in
                let session = SpotifySession.shared
                do {
                    let collections = switch kind {
                    case .playlist: try await session.playlists()
                    case .album: try await session.savedAlbums()
                    case .artist: try await session.followedArtists()
                    }
                    guard self.spotifyMenuRequestID == requestID else { return }
                    self.spotifyCollections = collections
                } catch {
                    guard self.spotifyMenuRequestID == requestID else { return }
                    self.spotifyMenuError = error.localizedDescription
                }
                self.isLoadingSpotifyMenu = false
                self.refreshDetailPreviewForCurrentContext()
            }
        }
    }

    /// Back from a page: to the page before it, or out to the Music menu from the first one.
    func navigateUpInSpotifyMenu() {
        guard spotifyMenuPages.count > 1 else {
            exitSpotifyMenuToMusic()
            return
        }
        _ = incrementRequestID(&spotifyMenuRequestID)
        transitionMenuForFolderSwap {
            self.spotifyMenuPages.removeLast()
            let previous = self.spotifyMenuPages.last ?? SpotifyMenuPageState(page: .home, selectedIndex: 0)
            self.isLoadingSpotifyMenu = false
            self.spotifyMenuError = nil
            self.spotifyCollections = []
            self.selectedThirdIndex = min(previous.selectedIndex, max(0, self.spotifyMenuListItems().count - 1))
            self.headerText = Self.spotifyTitle(for: previous.page)
            self.resetMusicPreviewState()
            self.refreshDetailPreviewForCurrentContext()
        }
    }

    private func exitSpotifyMenuToMusic() {
        _ = incrementRequestID(&spotifyMenuRequestID)
        transitionMenuForFolderSwap(useOverlayFade: true) {
            self.isInThirdMenu = false
            self.thirdMenuMode = .none
            self.thirdMenuOpacity = 0
            self.submenuOpacity = 1
            self.spotifyMenuPages = []
            self.spotifyCollections = []
            self.isLoadingSpotifyMenu = false
            self.spotifyMenuError = nil
            self.headerText = self.rootMenuTitle(for: self.activeRootItemID)
            self.resetMusicPreviewState()
            self.refreshDetailPreviewForCurrentContext()
        }
    }

    /// Back from a song list opened in the Spotify menu, to the page it was opened from.
    func returnFromSpotifySongs() {
        guard let pages = spotifySongsReturnPages else { return }
        _ = incrementRequestID(&spotifyMenuRequestID)
        transitionMenuForFolderSwap {
            self.spotifySongsReturnPages = nil
            self.thirdMenuMode = .spotify
            self.spotifyMenuPages = pages
            self.isLoadingMusicSongs = false
            self.musicSongsLoadError = nil
            self.musicSongsShowsShuffleAction = false
            let page = pages.last ?? SpotifyMenuPageState(page: .home, selectedIndex: 0)
            self.selectedThirdIndex = min(page.selectedIndex, max(0, self.spotifyMenuListItems().count - 1))
            self.headerText = Self.spotifyTitle(for: page.page)
            self.resetMusicPreviewState()
            self.refreshDetailPreviewForCurrentContext()
        }
    }

    // MARK: - Actions

    func triggerSpotifyMenuAction() {
        let items = spotifyMenuListItems()
        guard items.indices.contains(selectedThirdIndex) else { return }
        let item = items[selectedThirdIndex]
        let session = SpotifySession.shared
        switch item.id {
        case "spotify_sign_in":
            session.signIn()
        case "spotify_retry":
            session.start()
        case "spotify_sign_out":
            session.signOut()
        case "spotify_liked":
            let contextURI = session.username.isEmpty ? nil : "spotify:user:\(session.username):collection"
            openSpotifySongs(title: "Liked Songs", contextURI: contextURI) {
                try await session.likedSongs()
            }
        case "spotify_playlists":
            pushSpotifyCollectionsPage(.playlist)
        case "spotify_albums":
            pushSpotifyCollectionsPage(.album)
        case "spotify_artists":
            pushSpotifyCollectionsPage(.artist)
        default:
            guard case .collections = currentSpotifyMenuPage,
                  spotifyCollections.indices.contains(selectedThirdIndex)
            else {
                playLimitSoundOnceForCurrentHold()
                return
            }
            let collection = spotifyCollections[selectedThirdIndex]
            openSpotifySongs(title: collection.name, contextURI: collection.uri) {
                try await session.tracks(in: collection)
            }
        }
    }

    /// Opens a list of Spotify songs in the Music songs list, with its preview and Now Playing.
    private func openSpotifySongs(
        title: String,
        contextURI: String?,
        load: @escaping @MainActor () async throws -> [SpotifyTrack],
    ) {
        let requestID = incrementRequestID(&spotifyMenuRequestID)
        var returnPages = spotifyMenuPages
        if var current = returnPages.popLast() {
            current.selectedIndex = selectedThirdIndex
            returnPages.append(current)
        }
        transitionMenuForFolderSwap(revealWhen: { !self.isLoadingMusicSongs }) {
            self.prepareMusicLibraryThirdMenu(
                mode: .musicSongs,
                title: self.truncatedHeaderTitle(title, fallback: "Spotify"),
                categoryKind: nil,
                categoryTitle: "",
                shuffleMode: false,
                libraryMediaType: .songs,
                showsShuffleAction: true,
            )
            self.spotifySongsReturnPages = returnPages
            Task { @MainActor in
                do {
                    let tracks = try await load()
                    guard self.spotifyMenuRequestID == requestID, self.thirdMenuMode == .musicSongs else { return }
                    let songs = self.spotifySongEntries(tracks, contextURI: contextURI)
                    self.musicSongsThirdMenuItems = songs
                    self.musicSongsLoadError = songs.isEmpty ? "No Songs" : nil
                } catch {
                    guard self.spotifyMenuRequestID == requestID, self.thirdMenuMode == .musicSongs else { return }
                    self.musicSongsLoadError = error.localizedDescription
                }
                self.isLoadingMusicSongs = false
                self.refreshDetailPreviewForCurrentContext()
            }
        }
    }

    func spotifySongEntries(_ tracks: [SpotifyTrack], contextURI: String?) -> [MusicLibrarySongEntry] {
        tracks.enumerated().compactMap { index, track in
            guard track.isPlayable, !track.uri.isEmpty else { return nil }
            return MusicLibrarySongEntry(
                id: "spotify|\(index)|\(track.uri)",
                title: track.name.isEmpty ? "Unknown Song" : track.name,
                artist: track.artist,
                album: track.album,
                genre: "",
                composer: "",
                durationSeconds: track.durationSeconds,
                trackNumber: track.trackNumber,
                discNumber: track.discNumber,
                artworkAlbumKey: track.imageURL.map { Self.spotifyArtworkKey(for: $0) },
                url: nil,
                artwork: nil,
                spotify: SpotifyTrackReference(uri: track.uri, imageURL: track.imageURL, contextURI: contextURI),
            )
        }
    }

    // MARK: - Covers

    static func spotifyArtworkKey(for url: URL) -> String {
        "spotify-art::\(url.absoluteString)"
    }

    var isShowingSpotifyCollectionCovers: Bool {
        guard thirdMenuMode == .spotify, case .collections = currentSpotifyMenuPage else { return false }
        return spotifyCollections.indices.contains(selectedThirdIndex)
    }

    /// The selected playlist, album or artist, as a song entry the cover preview can show.
    func spotifyCollectionPreviewEntry() -> MusicLibrarySongEntry? {
        guard isShowingSpotifyCollectionCovers else { return nil }
        let collection = spotifyCollections[selectedThirdIndex]
        return MusicLibrarySongEntry(
            id: "spotify-collection|\(collection.uri)",
            title: collection.name,
            artist: collection.subtitle,
            album: "",
            genre: "",
            composer: "",
            durationSeconds: 0,
            trackNumber: 0,
            discNumber: 0,
            artworkAlbumKey: collection.imageURL.map { Self.spotifyArtworkKey(for: $0) },
            url: nil,
            artwork: nil,
            spotify: SpotifyTrackReference(uri: collection.uri, imageURL: collection.imageURL, contextURI: nil),
        )
    }

    func loadSpotifyArtwork(for song: MusicLibrarySongEntry, cacheKey: String) async -> NSImage? {
        guard let url = song.spotify?.imageURL else { return nil }
        if let cached = cachedDecodedDisplayArtworkImage(sourceKey: cacheKey, maxPixelSize: 900) {
            return cached
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode),
              !data.isEmpty
        else { return nil }
        return cachedDecodedDisplayArtworkImage(from: data, sourceKey: cacheKey, maxPixelSize: 900)
    }

    // MARK: - Playback

    /// How many songs, from the one chosen, Spotify is given to play on through by itself.
    private var spotifyQueueWindow: Int {
        200
    }

    func startMusicPlaybackViaSpotify(_ song: MusicLibrarySongEntry, playbackRequestID: Int) {
        guard let reference = song.spotify else { return }
        let session = SpotifySession.shared
        isCurrentMusicPlaybackUsingSpotify = true
        isCurrentMusicPlaybackManagedByFirstRow = true
        spotifyShowsAdvert = false
        spotifyLastTrackPositionSeconds = 0
        session.playerStateHandler = { [weak self] state in
            self?.applySpotifyPlayerState(state)
        }
        startSpotifyProgressTimerIfNeeded()
        // Spotify got here by itself, at the end of the song before: let it play on.
        if let state = session.playerState,
           state.trackURI == reference.uri,
           !state.isPaused,
           state.currentPositionSeconds() < 8
        {
            spotifyPendingTrackURI = nil
            spotifyIsPlaying = true
            applySpotifyPlayerState(state)
            return
        }
        spotifyPendingTrackURI = reference.uri
        spotifyPendingSince = Date()
        spotifyIsPlaying = true
        let queue = resolvedActiveMusicPlaybackQueue()
        var uris: [String] = []
        if let index = queue.firstIndex(where: { $0.id == song.id }) {
            for entry in queue[index...] {
                guard let uri = entry.spotify?.uri else { break }
                uris.append(uri)
                if uris.count == spotifyQueueWindow { break }
            }
        }
        if uris.isEmpty {
            uris = [reference.uri]
        }
        Task { @MainActor in
            do {
                try await session.play(uris: uris, index: 0, contextURI: reference.contextURI)
            } catch {
                spotifyDebugLog("play failed: \(error.localizedDescription)")
                guard self.musicPlaybackRequestID == playbackRequestID, self.isCurrentMusicPlaybackUsingSpotify else { return }
                self.endSpotifyPlayback(pause: false)
            }
        }
    }

    /// Follows what Spotify says it's playing: the time, pauses, adverts and the move to the next song.
    func applySpotifyPlayerState(_ state: SpotifyPlayerState?) {
        guard isCurrentMusicPlaybackUsingSpotify, let activeSongID = activeMusicPlaybackSongID else { return }
        let queue = resolvedActiveMusicPlaybackQueue()
        guard let index = queue.firstIndex(where: { $0.id == activeSongID }),
              let current = queue[index].spotify
        else { return }
        guard let state else { return }
        if let pending = spotifyPendingTrackURI {
            // Until Spotify reports the song asked for, what it says is about the one before.
            guard state.trackURI == pending || state.isAdvert else {
                if let since = spotifyPendingSince, Date().timeIntervalSince(since) > 15 {
                    endSpotifyPlayback(pause: false)
                }
                return
            }
            spotifyPendingTrackURI = nil
            spotifyPendingSince = nil
        }
        if state.isAdvert {
            showSpotifyAdvert(state)
            return
        }
        if state.trackURI == current.uri {
            if spotifyShowsAdvert {
                restoreSpotifySongDisplay(queue[index])
            }
            spotifyIsPlaying = !state.isPaused
            if state.durationSeconds > 0 {
                musicNowPlayingDurationSeconds = state.durationSeconds
            }
            if musicScrubDirection == 0, !isAwaitingSpotifySeek(state) {
                musicNowPlayingElapsedSeconds = state.displayedPositionSeconds()
                spotifyLastTrackPositionSeconds = musicNowPlayingElapsedSeconds
                musicNowPlayingLeadingGlyphState = state.isPaused ? .pause : nil
            }
            // Stopped at the end of the last song.
            if state.isPaused, index + 1 >= queue.count, state.durationSeconds > 0,
               state.positionSeconds >= state.durationSeconds - 1.5
            {
                endSpotifyPlayback(pause: false)
                return
            }
            updateMusicNowPlayingFlipTimerState()
            return
        }
        // Another song. At the end of this one, Spotify moved on: to First Row's next song, or past
        // the songs it was given. Anywhere else, it was told to play something else (on another
        // device, say), so First Row lets go.
        let wasNearEnd = musicNowPlayingDurationSeconds <= 0 ||
            spotifyLastTrackPositionSeconds >= musicNowPlayingDurationSeconds - 4
        guard wasNearEnd || spotifyShowsAdvert else {
            endSpotifyPlayback(pause: false)
            return
        }
        spotifyShowsAdvert = false
        if index + 1 < queue.count {
            stopMusicScrubbing(showPauseGlyph: false)
            switchMusicNowPlayingTrack(direction: 1)
        } else {
            endSpotifyPlayback(pause: true)
        }
    }

    private func showSpotifyAdvert(_ state: SpotifyPlayerState) {
        if !spotifyShowsAdvert {
            spotifyShowsAdvert = true
            withAnimation(.easeInOut(duration: 0.18)) {
                musicNowPlayingTitle = "Advertisement"
                musicNowPlayingArtist = state.advertiser.isEmpty ? "Spotify" : state.advertiser
                musicNowPlayingAlbum = ""
                musicNowPlayingArtwork = musicFallbackImage
            }
        }
        spotifyIsPlaying = !state.isPaused
        musicNowPlayingDurationSeconds = max(0, state.durationSeconds)
        musicNowPlayingElapsedSeconds = state.displayedPositionSeconds()
        musicNowPlayingLeadingGlyphState = state.isPaused ? .pause : nil
        updateMusicNowPlayingFlipTimerState()
    }

    private func restoreSpotifySongDisplay(_ song: MusicLibrarySongEntry) {
        spotifyShowsAdvert = false
        musicNowPlayingTitle = song.title
        musicNowPlayingArtist = song.artist
        musicNowPlayingAlbum = song.album
        musicNowPlayingArtwork = song.artwork ?? musicFallbackImage
        musicNowPlayingDurationSeconds = max(0, song.durationSeconds)
        let artworkRequestID = incrementRequestID(&musicNowPlayingArtworkRequestID)
        updateNowPlayingArtworkIfNeeded(for: song, requestID: artworkRequestID)
    }

    /// Ends First Row's playback of Spotify, leaving Now Playing if it's showing.
    private func endSpotifyPlayback(pause: Bool) {
        if pause {
            Task { try? await SpotifySession.shared.pause() }
        }
        if activeFullscreenScene?.key == musicNowPlayingFullscreenKey {
            dismissFullscreenScene(preserveMusicPlayback: false)
        } else {
            stopMusicPlaybackSession(clearDisplayState: false, pauseSystemMusicPlayback: false)
        }
    }

    func startSpotifyProgressTimerIfNeeded() {
        guard spotifyProgressTimer == nil else { return }
        let timer = Timer(after: 0.25, repeats: true) { _ in
            MainActor.assumeIsolatedIfPossible {
                self.refreshSpotifyPlaybackProgress()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        spotifyProgressTimer = timer
    }

    func stopSpotifyPlayback(pause: Bool) {
        spotifyProgressTimer?.invalidate()
        spotifyProgressTimer = nil
        if isCurrentMusicPlaybackUsingSpotify, pause {
            Task { try? await SpotifySession.shared.pause() }
        }
        isCurrentMusicPlaybackUsingSpotify = false
        spotifyIsPlaying = false
        spotifyShowsAdvert = false
        spotifyPendingTrackURI = nil
        spotifyPendingSince = nil
        spotifyLastTrackPositionSeconds = 0
        spotifySeekTarget = nil
    }

    private func refreshSpotifyPlaybackProgress() {
        guard isCurrentMusicPlaybackUsingSpotify else { return }
        let session = SpotifySession.shared
        if let since = spotifyPendingSince, spotifyPendingTrackURI != nil, Date().timeIntervalSince(since) > 15 {
            spotifyDebugLog("Spotify never started the song")
            endSpotifyPlayback(pause: false)
            return
        }
        guard musicScrubDirection == 0, spotifyPendingTrackURI == nil, let state = session.playerState else { return }
        if spotifyShowsAdvert {
            guard state.isAdvert else { return }
        } else {
            guard let activeSongID = activeMusicPlaybackSongID,
                  let song = resolvedActiveMusicPlaybackQueue().first(where: { $0.id == activeSongID }),
                  song.spotify?.uri == state.trackURI
            else { return }
        }
        guard !isAwaitingSpotifySeek(state) else { return }
        musicNowPlayingElapsedSeconds = state.displayedPositionSeconds()
        if !spotifyShowsAdvert {
            spotifyLastTrackPositionSeconds = musicNowPlayingElapsedSeconds
        }
    }

    /// True while Spotify still reports where it was before a seek.
    private func isAwaitingSpotifySeek(_ state: SpotifyPlayerState) -> Bool {
        guard let target = spotifySeekTarget else { return false }
        if abs(state.positionSeconds - target.seconds) < 2 || Date().timeIntervalSince(target.date) > 3 {
            spotifySeekTarget = nil
            return false
        }
        return true
    }

    /// Plays or pauses; `pausing` pauses a song still getting going.
    func toggleSpotifyPlayback(pausing: Bool = false) {
        stopMusicScrubbing(showPauseGlyph: false)
        let shouldPause = spotifyIsPlaying || pausing
        spotifyIsPlaying = !shouldPause
        musicNowPlayingLeadingGlyphState = shouldPause ? .pause : nil
        Task {
            if shouldPause {
                try? await SpotifySession.shared.pause()
            } else {
                try? await SpotifySession.shared.resume()
            }
        }
        updateMusicNowPlayingFlipTimerState()
    }

    func pauseSpotifyForScrubbing() {
        guard spotifyIsPlaying else { return }
        spotifyIsPlaying = false
        Task { try? await SpotifySession.shared.pause() }
    }

    func seekSpotify(toSeconds seconds: Double) {
        spotifyLastTrackPositionSeconds = seconds
        spotifySeekTarget = (seconds, Date())
        Task { try? await SpotifySession.shared.seek(toSeconds: seconds) }
    }
}
