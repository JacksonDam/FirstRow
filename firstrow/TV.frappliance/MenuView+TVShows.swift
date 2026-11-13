import Foundation

// TV Shows: iTunes Top TV Episodes in a group of its own at the top, and under it the shows
// found among the movie files (see `TVShowLibrary`). Sorted by show, there is a row for each
// show, which leads to its episodes (through its seasons, if it has more than one). Sorted
// by date, every episode is a row, the newest first.
//
// A show's episodes are listed as a folder of movies is (`thirdMenuMode == .moviesFolder`, with
// `tvShowListing` saying which show), so they have a movie's picture beside them, its question
// about resuming, and its question about deleting when the confirm button is held.

/// The show whose list is showing, and the season of it (nil for the list of its seasons).
struct TVShowListing: Equatable {
    var showKey: String
    var season: Int?
    /// The show has more than one season: Back from a season's episodes goes to the seasons.
    var hasSeasons: Bool
}

extension MenuView {
    static let tvShowRowPrefix = "tvshow|"
    static let tvEpisodeRowPrefix = "tvepisode|"

    // MARK: - Finding the shows

    /// Looks for the shows again, off to one side, and brings the lists up to date if what
    /// is found has changed.
    func refreshTVShows() {
        #if os(iOS)
            adoptMoviesFolderChosenBefore()
        #endif
        let rules = moviesScanRules
        let candidates = moviesRootCandidateURLs()
        let requestID = incrementRequestID(&tvLibraryRequestID)
        Task.detached(priority: .userInitiated) {
            // (Where to look is found out here too: it is read from the disk.)
            var folders = self.moviesTopLevelFolderURLs(rootCandidates: candidates, rules: rules)
            var files: [URL] = []
            for url in MediaSources.shared.folders(.movies) {
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
                if !isFolder.boolValue {
                    files.append(url)
                } else if !Self.isDiscFolder(url) {
                    folders.append(url)
                }
            }
            let library = TVShowScanner.library(folders: folders, files: files, movieExtensions: rules.movieExtensions)
            await MainActor.run {
                guard self.tvLibraryRequestID == requestID, library != self.tvLibrary else { return }
                self.adoptTVLibrary(library)
            }
        }
    }

    /// Takes a new set of shows, keeping the selection on its row where that row is still there.
    private func adoptTVLibrary(_ library: TVShowLibrary) {
        let isShowingList = activeRootItemID == "tv_shows" && isInSubmenu
        let before = isShowingList ? currentSubmenuItems() : []
        let selectedID = before.indices.contains(selectedSubIndex) ? before[selectedSubIndex].id : nil
        tvLibrary = library
        tvSubmenuRowsMemo = nil
        guard isShowingList else { return }
        let rows = currentSubmenuItems()
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            selectedSubIndex = index
        } else {
            selectedSubIndex = min(selectedSubIndex, max(0, rows.count - 1))
        }
        if isInThirdMenu, tvShowListing != nil { reloadTVShowListing() }
        refreshDetailPreviewForCurrentContext()
    }

    // MARK: - The rows of TV Shows

    /// The rows under iTunes Top TV Episodes: the shows by name, or every episode with the
    /// newest first.
    func tvShowsSubmenuItems() -> [SubmenuItemConfig] {
        if let memo = tvSubmenuRowsMemo, memo.mode == tvShowsSortMode { return memo.rows }
        var rows: [SubmenuItemConfig] = switch tvShowsSortMode {
        case .show:
            tvLibrary.shows.map { SubmenuItemConfig(id: Self.tvShowRowPrefix + $0.key, title: $0.name, leadsToMenu: true) }
        case .date:
            tvLibrary.newestFirst.map { SubmenuItemConfig(id: Self.tvEpisodeRowPrefix + $0.url.path, title: $0.titleWithShow) }
        }
        // (A line over them: iTunes Top TV Episodes stays in a group of its own at the top.)
        if let first = rows.first {
            rows[0] = SubmenuItemConfig(id: first.id, title: first.title, leadsToMenu: first.leadsToMenu, showsTopDivider: true)
        }
        tvSubmenuRowsMemo = (tvShowsSortMode, rows)
        return rows
    }

    /// The sorter has changed: the rows are other rows now.
    func tvShowsSortDidChange() {
        tvSubmenuRowsMemo = nil
        selectedSubIndex = min(selectedSubIndex, max(0, currentSubmenuItems().count - 1))
        refreshDetailPreviewForCurrentContext()
    }

    /// Chooses a row of TV Shows that is a show or an episode. False for any other row.
    func triggerTVShowsItem(_ item: SubmenuItemConfig) -> Bool {
        if item.id.hasPrefix(Self.tvShowRowPrefix) {
            guard let show = tvLibrary.show(withKey: String(item.id.dropFirst(Self.tvShowRowPrefix.count))) else { return true }
            playSound(named: "Selection")
            enterTVShow(show)
            return true
        }
        if item.id.hasPrefix(Self.tvEpisodeRowPrefix) {
            playSound(named: "Selection")
            startMoviePlayback(from: URL(fileURLWithPath: String(item.id.dropFirst(Self.tvEpisodeRowPrefix.count))))
            return true
        }
        return false
    }

    /// The movie file whose picture goes beside TV Shows' lists: the episode that is picked
    /// out, or the first episode of the show or the season that is.
    func tvPreviewTargetURL() -> URL? {
        if isInThirdMenu {
            guard thirdMenuMode == .moviesFolder, tvShowListing != nil, thirdMenuItems.indices.contains(selectedThirdIndex) else { return nil }
            return thirdMenuItems[selectedThirdIndex].url
        }
        guard let id = selectedTVShowsSubmenuItemID else { return nil }
        if id.hasPrefix(Self.tvShowRowPrefix) {
            return tvLibrary.show(withKey: String(id.dropFirst(Self.tvShowRowPrefix.count)))?.episodes.first?.url
        }
        if id.hasPrefix(Self.tvEpisodeRowPrefix) {
            return URL(fileURLWithPath: String(id.dropFirst(Self.tvEpisodeRowPrefix.count)))
        }
        return nil
    }

    // MARK: - A show's list

    /// The rows of a show's list: its seasons, or the episodes of one of them.
    private func tvShowListingEntries(_ listing: TVShowListing) -> [MoviesFolderEntry] {
        guard let show = tvLibrary.show(withKey: listing.showKey) else { return [] }
        if let season = listing.season {
            return show.episodes(inSeason: season).map {
                MoviesFolderEntry(id: "tv|\($0.url.path)", title: $0.numberedTitle, url: $0.url, isDirectory: false)
            }
        }
        // (A season's row carries its first episode, for the picture beside the list.)
        return show.seasons.compactMap { season in
            show.episodes(inSeason: season).first.map {
                MoviesFolderEntry(id: "tvseason|\(season)", title: TVShow.name(ofSeason: season), url: $0.url, isDirectory: true)
            }
        }
    }

    func enterTVShow(_ show: TVShow) {
        let seasons = show.seasons
        let listing = TVShowListing(showKey: show.key, season: seasons.count > 1 ? nil : seasons.first, hasSeasons: seasons.count > 1)
        transitionMenuForFolderSwap {
            self.thirdMenuMode = .moviesFolder
            self.resetAllITunesTopMenusForNonITunesContext()
            self.isShowingContinueWatching = false
            self.thirdMenuRootURL = nil
            self.thirdMenuCurrentURL = nil
            self.tvShowListing = listing
            self.thirdMenuItems = self.tvShowListingEntries(listing)
            self.selectedThirdIndex = 0
            self.headerText = show.name
            self.isInThirdMenu = true
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
            self.refreshDetailPreviewForCurrentContext()
        }
    }

    /// Chooses a row of a show's list: a season opens, an episode plays.
    func triggerTVShowListingRow(_ entry: MoviesFolderEntry) {
        guard let listing = tvShowListing else { return }
        guard entry.isDirectory else {
            startMoviePlayback(from: entry.url)
            return
        }
        guard let season = entry.id.split(separator: "|").last.flatMap({ Int($0) }) else { return }
        let next = TVShowListing(showKey: listing.showKey, season: season, hasSeasons: true)
        transitionMenuForFolderSwap {
            self.tvShowListing = next
            self.thirdMenuItems = self.tvShowListingEntries(next)
            self.selectedThirdIndex = 0
            self.headerText = TVShow.name(ofSeason: season)
            self.refreshDetailPreviewForCurrentContext()
        }
    }

    /// Back from a show's list: from a season's episodes to the show's seasons, and from
    /// those (or from the episodes of a show that has one season) to TV Shows.
    func navigateUpInTVShowListing() {
        guard let listing = tvShowListing, listing.hasSeasons, let season = listing.season,
              let show = tvLibrary.show(withKey: listing.showKey)
        else {
            exitMoviesThirdMenuToSecondLevelWithSwap()
            return
        }
        let seasons = TVShowListing(showKey: listing.showKey, season: nil, hasSeasons: true)
        transitionMenuForFolderSwap {
            self.tvShowListing = seasons
            self.thirdMenuItems = self.tvShowListingEntries(seasons)
            self.selectedThirdIndex = self.thirdMenuItems.firstIndex { $0.id == "tvseason|\(season)" } ?? 0
            self.headerText = show.name
            self.refreshDetailPreviewForCurrentContext()
        }
    }

    /// Brings a show's list up to date with the shows as they are now, keeping the selection
    /// on its row. With nothing of the show left, it is TV Shows again.
    func reloadTVShowListing() {
        guard var listing = tvShowListing, thirdMenuMode == .moviesFolder else { return }
        guard let show = tvLibrary.show(withKey: listing.showKey) else {
            leaveEmptyTVShowListing()
            return
        }
        let seasons = show.seasons
        if seasons.count < 2 {
            // (One season is left of several: its episodes are the show's list.)
            listing = TVShowListing(showKey: listing.showKey, season: seasons.first, hasSeasons: false)
        } else if let season = listing.season, !seasons.contains(season) {
            listing.season = nil
        }
        let selectedID = thirdMenuItems.indices.contains(selectedThirdIndex) ? thirdMenuItems[selectedThirdIndex].id : nil
        tvShowListing = listing
        thirdMenuItems = tvShowListingEntries(listing)
        headerText = listing.hasSeasons ? listing.season.map { TVShow.name(ofSeason: $0) } ?? show.name : show.name
        if let selectedID, let index = thirdMenuItems.firstIndex(where: { $0.id == selectedID }) {
            selectedThirdIndex = index
        } else {
            selectedThirdIndex = min(selectedThirdIndex, max(0, thirdMenuItems.count - 1))
        }
    }

    /// An episode has just been deleted: it is out of the lists at once, and the shows are
    /// looked for again.
    func tvEpisodeWasRemoved() {
        let left = tvLibrary.newestFirst.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if left.count != tvLibrary.newestFirst.count { adoptTVLibrary(TVShowLibrary(episodes: left)) }
        refreshTVShows()
    }

    /// The show's last episode has gone: back to TV Shows. Behind a question or a movie
    /// that happens out of sight.
    private func leaveEmptyTVShowListing() {
        guard isMoviePlaybackVisible || isMovieTransitioning || isMovieResumePromptVisible else {
            exitMoviesThirdMenuToSecondLevelWithSwap()
            return
        }
        isInThirdMenu = false
        thirdMenuMode = .none
        thirdMenuOpacity = 0
        submenuOpacity = 1
        headerText = rootMenuTitle(for: activeRootItemID)
        resetThirdMenuDirectoryState()
        selectedSubIndex = min(selectedSubIndex, max(0, currentSubmenuItems().count - 1))
        refreshDetailPreviewForCurrentContext()
    }
}
