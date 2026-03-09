import AVFoundation
import Foundation
import SwiftUI
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

extension MenuView {
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
        let asset = AVURLAsset(url: url)
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
            if let data = dataValue, let image = NSImage(data: data) {
                return image
            }
            let rawValue: (NSCopying & NSObjectProtocol)? = if #available(macOS 12.0, *) {
                try? await item.load(.value)
            } else {
                item.value
            }
            if let data = rawValue as? Data, let image = NSImage(data: data) {
                return image
            }
            if let data = rawValue as? NSData, let image = NSImage(data: data as Data) {
                return image
            }
        }
        return nil
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
        if let embeddedArtwork = selectedSong.artwork {
            withAnimation(.easeInOut(duration: 0.18)) {
                musicPreviewImage = embeddedArtwork
            }
            return
        }
        guard let previewURL = selectedSong.url else {
            withAnimation(.easeInOut(duration: 0.18)) {
                musicPreviewImage = nil
            }
            return
        }
        let standardizedURL = previewURL.standardizedFileURL
        let cacheKey = standardizedURL.path
        if let cached = musicPreviewCache[cacheKey] {
            withAnimation(.easeInOut(duration: 0.18)) {
                musicPreviewImage = cached
            }
            return
        }
        let targetSongID = selectedSong.id
        Task.detached(priority: .userInitiated) { [standardizedURL] in
            let generatedArtwork = await self.generateMusicArtworkThumbnail(for: standardizedURL)
            await MainActor.run {
                guard self.musicPreviewRequestID == requestID else { return }
                guard self.musicPreviewTargetSongID == targetSongID else { return }
                if let generatedArtwork {
                    self.musicPreviewCache[cacheKey] = generatedArtwork
                    withAnimation(.easeInOut(duration: 0.22)) {
                        self.musicPreviewImage = generatedArtwork
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
            _ = incrementRequestID(&musicTopLevelCarouselRequestID)
            return
        }
        musicTopLevelCarouselActiveSubmenuID = selectedSubmenuID
        let sharedCarouselKey = "music_top_level_shared_songs"
        if let cached = musicTopLevelCarouselArtworkCache[sharedCarouselKey] {
            musicTopLevelCarouselArtworks = cached
            return
        }
        let requestID = incrementRequestID(&musicTopLevelCarouselRequestID)
        requestMusicLibraryAuthorization { isAuthorized in
            guard self.musicTopLevelCarouselRequestID == requestID else { return }
            guard self.musicTopLevelCarouselActiveSubmenuID == selectedSubmenuID else { return }
            guard isAuthorized else {
                self.musicTopLevelCarouselArtworks = []
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let songs = try self.fetchMusicLibrarySongs()
                    let sharedArtworks = songs.map { song in
                        song.artwork ?? self.musicFallbackImage
                    }
                    DispatchQueue.main.async {
                        guard self.musicTopLevelCarouselRequestID == requestID else { return }
                        self.musicTopLevelCarouselArtworkCache[sharedCarouselKey] = sharedArtworks
                        guard let activeSelectedSubmenuID = self.selectedTopLevelMusicCarouselSubmenuID else {
                            self.musicTopLevelCarouselActiveSubmenuID = nil
                            self.musicTopLevelCarouselArtworks = []
                            return
                        }
                        self.musicTopLevelCarouselActiveSubmenuID = activeSelectedSubmenuID
                        self.musicTopLevelCarouselArtworks = sharedArtworks
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.musicTopLevelCarouselRequestID == requestID else { return }
                        guard self.musicTopLevelCarouselActiveSubmenuID == selectedSubmenuID else { return }
                        self.musicTopLevelCarouselArtworks = []
                    }
                }
            }
        }
    }

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
        try fetchMusicLibraryEntries(for: .songs)
    }

    func fetchMusicLibraryEntries(for mediaType: MusicLibraryMediaType) throws -> [MusicLibrarySongEntry] {
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
            return sortedMusicLibraryEntries(mediaItems.compactMap { makeMusicLibrarySongEntry(from: $0) })
        #elseif os(tvOS)
            switch mediaType {
            case .songs:
                return try fetchMusicLibrarySongsFromMusicKit()
            case .musicVideos, .audiobooks:
                return []
            }
        #elseif canImport(iTunesLibrary)
            return try withITLibrary { library in
                let all = library.allMediaItems
                let matched = all.filter { musicLibraryMediaKindMatches($0.mediaKind, requested: mediaType) }
                return sortedMusicLibraryEntries(matched.compactMap { makeMusicLibrarySongEntry(from: $0) })
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
        func makeMusicLibrarySongEntry(from item: MPMediaItem) -> MusicLibrarySongEntry? {
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
                url: locationURL,
                artwork: item.artwork?.image(at: CGSize(width: 800, height: 800)),
            )
        }
    #endif
    #if canImport(iTunesLibrary)
        func isMusicLibraryPlayableLocally(_ item: ITLibMediaItem) -> Bool {
            guard !item.isUserDisabled else { return false }
            guard item.locationType == .file else { return false }
            guard let locationURL = item.location, locationURL.isFileURL else { return false }
            return FileManager.default.isReadableFile(atPath: locationURL.path)
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

        func makeMusicLibrarySongEntry(from item: ITLibMediaItem) -> MusicLibrarySongEntry? {
            guard isMusicLibraryPlayableLocally(item) else { return nil }
            guard let locationURL = item.location else { return nil }
            let title = normalizedMusicLibraryText(
                item.title,
                fallback: locationURL.deletingPathExtension().lastPathComponent,
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
                url: locationURL,
                artwork: item.artwork?.image,
            )
        }
    #endif
    #if os(tvOS)
        func fetchMusicLibrarySongsFromMusicKit() throws -> [MusicLibrarySongEntry] {
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
                        guard let entry = makeMusicLibrarySongEntry(from: song) else { continue }
                        songs.append(entry)
                    }
                    fetchResult = .success(sortedMusicLibraryEntries(songs))
                } catch {
                    fetchResult = .failure(error)
                }
            }
            semaphore.wait()
            return try fetchResult?.get() ?? []
        }

        func makeMusicLibrarySongEntry(from song: Song) -> MusicLibrarySongEntry? {
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
                url: playbackURL,
                artwork: loadMusicKitArtworkImage(song.artwork),
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
                    DispatchQueue.main.async {
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
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let songs = try self.fetchMusicLibraryEntries(for: requestedMediaType)
                    DispatchQueue.main.async {
                        guard self.musicSongsRequestID == requestID else { return }
                        guard self.thirdMenuMode == .musicSongs else { return }
                        guard !self.isMusicSongsCategoryScoped else { return }
                        guard self.activeMusicLibraryMediaType == requestedMediaType else { return }
                        self.isLoadingMusicSongs = false
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
                    DispatchQueue.main.async {
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
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let categories: [MusicCategoryEntry]
                    if kind == .playlists {
                        categories = try self.fetchMusicLibraryPlaylists()
                    } else {
                        let songs = try self.fetchMusicLibrarySongs()
                        categories = self.buildMusicCategoryEntries(from: songs, kind: kind)
                    }
                    DispatchQueue.main.async {
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
                    DispatchQueue.main.async {
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
        let shuffledSongs = musicSongsThirdMenuItems.shuffled()
        musicSongsThirdMenuItems = shuffledSongs
        selectedThirdIndex = thirdMenuSelectionIndex(forMusicSongIndex: 0)
        isMusicSongsShuffleMode = true
        startPlaybackForMusicLibraryEntry(
            shuffledSongs[0],
            trackIndex: 0,
            trackCount: shuffledSongs.count,
        )
        refreshMusicPreviewForCurrentContext()
    }

    func startMusicShufflePlaybackFromLibrary() {
        if !isMusicActivelyPlaying {
            deferNowPlayingMenuItemUntilAfterFadeOut = true
        }
        activeMusicLibraryMediaType = .songs
        musicSongsShowsShuffleAction = false
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
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let songs = try self.fetchMusicLibrarySongs()
                    let shuffledSongs = songs.shuffled()
                    DispatchQueue.main.async {
                        guard self.musicSongsRequestID == requestID else { return }
                        self.isLoadingMusicSongs = false
                        guard !shuffledSongs.isEmpty else {
                            self.deferNowPlayingMenuItemUntilAfterFadeOut = false
                            self.musicSongsThirdMenuItems = []
                            self.selectedThirdIndex = 0
                            self.musicSongsLoadError = "No Songs in Music Library"
                            return
                        }
                        self.musicSongsThirdMenuItems = shuffledSongs
                        self.selectedThirdIndex = 0
                        self.isMusicSongsShuffleMode = true
                        self.isMusicSongsCategoryScoped = false
                        self.activeMusicLibraryMediaType = .songs
                        self.musicSongsShowsShuffleAction = false
                        self.activeMusicCategoryKind = nil
                        self.activeMusicCategoryMenuTitle = ""
                        self.lastSelectedMusicCategoryIndex = 0
                        self.musicCategoryThirdMenuItems = []
                        self.musicSongsLoadError = nil
                        self.thirdMenuMode = .none
                        self.isInThirdMenu = false
                        self.thirdMenuOpacity = 0
                        self.submenuOpacity = 1
                        self.startMusicPlayback(
                            from: shuffledSongs[0],
                            trackIndex: 0,
                            trackCount: shuffledSongs.count,
                        )
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.musicSongsRequestID == requestID else { return }
                        self.deferNowPlayingMenuItemUntilAfterFadeOut = false
                        self.isLoadingMusicSongs = false
                        self.musicSongsThirdMenuItems = []
                        self.selectedThirdIndex = 0
                        self.musicSongsLoadError = self.musicLibraryErrorMessage(for: error)
                    }
                }
            }
        }
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

    func musicLibraryEmptyErrorCopy(for mediaType: MusicLibraryMediaType) -> (header: String, subcaption: String) {
        switch mediaType {
        case .audiobooks:
            (
                "First Row cannot find any audiobooks.",
                "Use iTunes to purchase audiobooks from the iTunes Store.",
            )
        case .musicVideos:
            (
                "First Row cannot find any music videos.",
                "Use iTunes to purchase music videos from the iTunes Store.",
            )
        case .songs:
            (
                "First Row cannot find any songs.",
                "Use iTunes to import songs or purchase songs from the iTunes Store.",
            )
        }
    }

    func musicCategoryEmptyErrorCopy(for kind: MusicCategoryKind) -> (header: String, subcaption: String) {
        switch kind {
        case .playlists:
            (
                "First Row cannot find any playlists.",
                "Use iTunes to create and manage your playlists.",
            )
        case .albums, .artists, .genres, .composers:
            (
                "First Row cannot find any songs.",
                "Use iTunes to import songs or purchase songs from the iTunes Store.",
            )
        }
    }

    func presentMusicLibraryEmptyError(for mediaType: MusicLibraryMediaType) {
        let copy = musicLibraryEmptyErrorCopy(for: mediaType)
        presentMusicLibraryEmptyErrorScreen(header: copy.header, subcaption: copy.subcaption)
    }

    func presentMusicCategoryEmptyError(for kind: MusicCategoryKind) {
        let copy = musicCategoryEmptyErrorCopy(for: kind)
        presentMusicLibraryEmptyErrorScreen(header: copy.header, subcaption: copy.subcaption)
    }

    func presentMusicLibraryEmptyErrorScreen(header: String, subcaption: String) {
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    presentWhenReady(retryCount: retryCount + 1)
                }
                return
            }
            presentFeatureErrorScreen(header: header, subcaption: subcaption)
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
