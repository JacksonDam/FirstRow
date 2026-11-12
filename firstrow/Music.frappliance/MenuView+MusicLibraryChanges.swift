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
#endif
#if os(tvOS)
    import MusicKit
#endif
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif

/// What can be told about the music library without reading it into the menus. When it
/// differs from the last time, there's something new to read.
struct MusicLibraryMark: Equatable {
    /// The system's songs: when its library last changed (iPhone, iPad), or the songs
    /// themselves boiled down to a number (Mac).
    var songs: Int?
    /// The system's playlists, where they can be told apart from its songs (Mac).
    var playlists: Int?
    /// The music files in the folders that are read, by name, size and date.
    var files: Int?
}

/// The music library is read once, as First Row starts. A song bought or a playlist edited
/// afterwards (in Music, on this device or another) is picked up here, so nothing waits for
/// First Row to be opened again: the library is looked at when First Row comes back to the
/// front, when Music is opened from the main menu and, on iPhone and iPad, when the system
/// says it has changed, and read again only if it has.
extension MenuView {
    enum MusicLibraryCheckReason {
        case cameToFront
        case openedMusic
        case systemNotice
    }

    /// Called once the library has been read at launch.
    func watchMusicLibraryForChanges() {
        guard !isWatchingMusicLibrary else { return }
        isWatchingMusicLibrary = true
        musicLibraryCheckedAt = Date()
        // (A little later: First Row is still starting.)
        Task {
            try? await firstRowSleep(2)
            guard self.musicLibraryMark == nil else { return }
            let mark = await Task.detached(priority: .utility) { self.currentMusicLibraryMark() }.value
            if self.musicLibraryMark == nil { self.musicLibraryMark = mark }
        }
        #if os(macOS)
            let active = NSApplication.didBecomeActiveNotification
        #elseif canImport(UIKit)
            let active = UIApplication.didBecomeActiveNotification
        #endif
        #if os(macOS) || canImport(UIKit)
            musicLibraryChangeObservers.append(NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible { self?.checkMusicLibraryForChanges(.cameToFront) }
            })
        #endif
        listenForMusicLibraryNotices()
    }

    /// The system's own word that the library has changed, where it gives one.
    private func listenForMusicLibraryNotices() {
        #if os(iOS)
            guard !isListeningForMusicLibraryNotices, MPMediaLibrary.authorizationStatus() == .authorized else { return }
            isListeningForMusicLibraryNotices = true
            MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
            musicLibraryChangeObservers.append(NotificationCenter.default.addObserver(forName: .MPMediaLibraryDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible {
                    guard let self else { return }
                    // They come in bursts as the library syncs, and a song played is a change
                    // too: one look after the last of them, and not many a minute.
                    self.musicLibraryNoticeTask?.cancel()
                    let wait = max(1, 15 - Date().timeIntervalSince(self.musicLibraryCheckedAt))
                    self.musicLibraryNoticeTask = Task {
                        try? await firstRowSleep(wait)
                        guard !Task.isCancelled else { return }
                        self.checkMusicLibraryForChanges(.systemNotice)
                    }
                }
            })
        #endif
    }

    /// Looks whether the music library has changed since it was read, and reads it again if
    /// it has.
    func checkMusicLibraryForChanges(_ reason: MusicLibraryCheckReason) {
        guard isWatchingMusicLibrary, isStartupMusicLibraryPreloadComplete, musicAllSongsCache != nil else { return }
        listenForMusicLibraryNotices()
        guard !isCheckingMusicLibrary else {
            // (What is being read now may have been read before the change.)
            if reason != .openedMusic { musicLibraryNeedsAnotherCheck = true }
            return
        }
        let sinceLastCheck = Date().timeIntervalSince(musicLibraryCheckedAt)
        switch reason {
        case .cameToFront:
            guard sinceLastCheck >= 5 else { return }
        case .openedMusic:
            guard sinceLastCheck >= 60 else { return }
        case .systemNotice:
            break
        }
        isCheckingMusicLibrary = true
        musicLibraryCheckedAt = Date()
        Task {
            await self.readMusicLibraryIfChanged()
            self.isCheckingMusicLibrary = false
            self.musicLibraryCheckedAt = Date()
            if self.musicLibraryNeedsAnotherCheck {
                self.musicLibraryNeedsAnotherCheck = false
                self.checkMusicLibraryForChanges(.systemNotice)
            }
        }
    }

    private func readMusicLibraryIfChanged() async {
        #if os(iOS)
            guard MPMediaLibrary.authorizationStatus() == .authorized else { return }
        #elseif os(tvOS)
            guard MusicAuthorization.currentStatus == .authorized else { return }
        #endif
        let found = await Task.detached(priority: .utility) { self.currentMusicLibraryMark() }.value
        #if os(tvOS)
            // Apple TV has nothing to tell a change by: its library is read (off the main
            // thread) and compared with what the menus have.
            let mark = found
            let songsMayHaveChanged = true
            let playlistsMayHaveChanged = false
        #else
            guard let known = musicLibraryMark else {
                musicLibraryMark = found
                return
            }
            #if os(macOS)
                // (Music's library couldn't be looked at this time: taken to be as it was.)
                let mark = found.songs == nil
                    ? MusicLibraryMark(songs: known.songs, playlists: known.playlists, files: found.files)
                    : found
            #else
                let mark = found
            #endif
            guard mark != known else { return }
            let songsMayHaveChanged = mark.songs != known.songs || mark.files != known.files
            let playlistsMayHaveChanged = true
        #endif
        #if os(macOS)
            // The Mac reads its library on the main thread, which holds everything on screen
            // still meanwhile: left until nothing has been pressed for a moment.
            let patience = Date().addingTimeInterval(30)
            while Date().timeIntervalSince(lastUserInteractionAt) < 0.8, Date() < patience {
                try? await firstRowSleep(0.2)
            }
        #endif
        let oldSongs = musicAllSongsCache ?? []
        var newSongs: [MusicLibrarySongEntry]?
        if songsMayHaveChanged {
            let requestID = incrementRequestID(&musicStartupPreloadRequestID)
            guard let snapshot = try? await loadStartupMusicLibrarySnapshot(),
                  musicStartupPreloadRequestID == requestID else { return }
            #if canImport(iTunesLibrary)
                // (Music's library unreadable this time, with songs from elsewhere still
                // found: what the menus have is kept.)
                if snapshot.itemIndices.isEmpty, !musicLibraryItemIndexBySongID.isEmpty { return }
                // The covers are now read from the library object just made.
                musicLibraryItemIndexBySongID = snapshot.itemIndices
            #endif
            if !Self.areSameSongs(snapshot.sortedSongs, oldSongs) {
                musicAllSongsCache = snapshot.sortedSongs
                musicShuffleSongsCache = snapshot.shuffleSongs
                reloadMusicTopLevelCarousel()
                newSongs = snapshot.sortedSongs
            }
        }
        musicLibraryMark = mark
        if newSongs != nil || playlistsMayHaveChanged {
            await remakeShownMusicList(newSongs: newSongs, oldSongs: oldSongs)
        }
    }

    /// A list of the library's music is on screen (Songs, Playlists and the rest, or the
    /// songs of one of them).
    private var isShowingMusicLibraryList: Bool {
        activeRootItemID == "music" && isInThirdMenu && !isLoadingMusicSongs && musicSongsLoadError == nil
            && activeMusicLibraryMediaType == .songs && spotifySongsReturnPages == nil
            && (thirdMenuMode == .musicSongs || thirdMenuMode == .musicCategories)
    }

    /// The list of the library's music that is on screen is made again from the library as
    /// it now is, the row that was chosen staying chosen. (The others are made from it when
    /// they're next opened.)
    private func remakeShownMusicList(newSongs: [MusicLibrarySongEntry]?, oldSongs: [MusicLibrarySongEntry]) async {
        guard isShowingMusicLibraryList else { return }
        var playlists: [MusicCategoryEntry] = []
        if activeMusicCategoryKind == .playlists {
            #if os(iOS)
                // (Off the main thread: the library can say it has changed as often as a song
                // is played.)
                playlists = await Task.detached(priority: .userInitiated) { self.mediaLibraryPlaylists() }.value
                guard isShowingMusicLibraryList else { return }
            #elseif os(tvOS)
                playlists = await (try? fetchMusicKitPlaylists()) ?? []
                guard isShowingMusicLibraryList else { return }
            #else
                playlists = (try? fetchMusicLibraryPlaylists()) ?? []
            #endif
        }
        guard let kind = activeMusicCategoryKind else {
            // Songs: every song there is.
            guard thirdMenuMode == .musicSongs, !isMusicSongsCategoryScoped, let newSongs,
                  Self.areSameSongs(musicSongsThirdMenuItems, oldSongs) else { return }
            showMusicSongsKeepingChosenRow(newSongs)
            refreshMusicPreviewForCurrentContext()
            return
        }
        // Playlists, Artists, Albums and the rest, or the songs of one of them.
        guard thirdMenuMode == .musicCategories || (thirdMenuMode == .musicSongs && isMusicSongsCategoryScoped) else { return }
        let categories: [MusicCategoryEntry]
        if kind == .playlists {
            categories = playlists
        } else if let newSongs {
            categories = buildMusicCategoryEntries(from: newSongs, kind: kind)
        } else {
            return
        }
        guard !categories.isEmpty, !Self.areSameCategories(categories, musicCategoryThirdMenuItems) else { return }
        let isInsideOne = thirdMenuMode == .musicSongs
        let chosenIndex = isInsideOne ? lastSelectedMusicCategoryIndex : selectedThirdIndex
        let chosenID = musicCategoryThirdMenuItems.indices.contains(chosenIndex) ? musicCategoryThirdMenuItems[chosenIndex].id : nil
        let newIndex = chosenID.flatMap { id in categories.firstIndex { $0.id == id } }
        musicCategoryThirdMenuItems = categories
        if isInsideOne {
            // (The one being looked at has gone: its songs stay until it's left.)
            guard let newIndex else { return }
            lastSelectedMusicCategoryIndex = newIndex
            guard !Self.areSameSongs(categories[newIndex].songs, musicSongsThirdMenuItems) else { return }
            showMusicSongsKeepingChosenRow(categories[newIndex].songs)
        } else {
            selectedThirdIndex = newIndex ?? min(selectedThirdIndex, categories.count - 1)
        }
        refreshMusicPreviewForCurrentContext()
    }

    private func showMusicSongsKeepingChosenRow(_ songs: [MusicLibrarySongEntry]) {
        let chosenID = musicSongIndex(forThirdMenuSelectionIndex: selectedThirdIndex).map { musicSongsThirdMenuItems[$0].id }
        musicSongsThirdMenuItems = songs
        if let chosenID, let index = songs.firstIndex(where: { $0.id == chosenID }) {
            selectedThirdIndex = thirdMenuSelectionIndex(forMusicSongIndex: index)
        } else {
            let rows = songs.count + (shouldShowMusicSongsShuffleActionItem() ? 1 : 0)
            selectedThirdIndex = min(selectedThirdIndex, max(0, rows - 1))
        }
    }

    private static func areSameSongs(_ songs: [MusicLibrarySongEntry], _ others: [MusicLibrarySongEntry]) -> Bool {
        songs.count == others.count && zip(songs, others).allSatisfy { song, other in
            guard song.id == other.id, song.title == other.title, song.artist == other.artist, song.album == other.album,
                  song.genre == other.genre, song.composer == other.composer else { return false }
            guard song.trackNumber == other.trackNumber, song.discNumber == other.discNumber,
                  song.durationSeconds == other.durationSeconds, song.url == other.url else { return false }
            return song.prefersSystemMusicPlayerPlayback == other.prefersSystemMusicPlayerPlayback
        }
    }

    private static func areSameCategories(_ categories: [MusicCategoryEntry], _ others: [MusicCategoryEntry]) -> Bool {
        categories.count == others.count && zip(categories, others).allSatisfy { category, other in
            category.id == other.id && category.title == other.title && areSameSongs(category.songs, other.songs)
        }
    }

    /// Run off the main thread.
    nonisolated func currentMusicLibraryMark() -> MusicLibraryMark {
        var mark = MusicLibraryMark()
        #if os(iOS)
            mark.songs = MPMediaLibrary.default().lastModifiedDate.hashValue
        #elseif os(macOS)
            if !FirstRowHarness.isActive {
                (mark.songs, mark.playlists) = musicAppLibraryMarks()
            }
        #endif
        #if canImport(iTunesLibrary)
            var files = Hasher()
            for root in externalMusicRootURLs() {
                for url in scanExternalMusicFiles(in: root) {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    files.combine(url.path)
                    files.combine(values?.fileSize)
                    files.combine(values?.contentModificationDate)
                }
            }
            // The library file that has been chosen, whose playlists are nowhere else.
            if let libraryFile = MediaSources.shared.library(.iTunesXML) {
                files.combine(libraryFile.path)
                files.combine(ITunesLibraryXML.modificationDate(of: libraryFile))
            }
            mark.files = files.finalize()
        #endif
        return mark
    }

    #if os(macOS)
        /// The Music app's songs and its playlists, each boiled down to a number that changes
        /// when they do (a song played doesn't count). From a library object of its own, on
        /// the thread this is called on, and nothing of it is kept: the lists the menus show
        /// are still read on the main thread, but only once this has found something new to
        /// read, where reading the whole library there to find nothing new would hold the
        /// menus up each time. Nil if the library can't be read.
        nonisolated func musicAppLibraryMarks() -> (songs: Int?, playlists: Int?) {
            guard let library = try? ITLibrary(apiVersion: "1.0") else { return (nil, nil) }
            var songs = Hasher()
            for item in library.allMediaItems where item.mediaKind == .kindSong {
                songs.combine(item.persistentID)
                songs.combine(item.title)
                songs.combine(item.artist?.name)
                songs.combine(item.album.title)
                songs.combine(item.genre)
                songs.combine(item.composer)
                songs.combine(item.trackNumber)
                songs.combine(item.album.discNumber)
                songs.combine(item.totalTime)
                songs.combine(item.isUserDisabled)
                songs.combine(item.locationType.rawValue)
            }
            // What Playlists shows, and no more: a playlist's name and its songs. (Apple's own
            // lists of podcasts and audiobooks are numbered differently from one look to the
            // next.)
            var playlists = Hasher()
            for playlist in library.allPlaylists where playlist.isVisible && playlist.kind != .folder && !playlist.isMaster {
                let songIDs = playlist.items.filter { $0.mediaKind == .kindSong }.map(\.persistentID)
                guard !songIDs.isEmpty else { continue }
                playlists.combine(playlist.name)
                playlists.combine(songIDs)
            }
            return (songs.finalize(), playlists.finalize())
        }
    #endif
}
