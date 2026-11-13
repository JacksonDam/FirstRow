import Foundation

/// Where each movie file was stopped, kept between launches so any of them can pick up where
/// it left off, and listed under Movies > Continue Watching.
enum MovieResumeStore {
    struct Entry: Codable, Equatable {
        var path: String
        var title: String
        var seconds: Double
        var duration: Double
        var date: Date

        var url: URL { URL(fileURLWithPath: path) }

        /// "12 min left", or nil when the length isn't known.
        var remainingText: String? {
            guard duration > seconds, duration.isFinite else { return nil }
            let minutes = max(1, Int(((duration - seconds) / 60).rounded()))
            if minutes >= 60 {
                let hours = minutes / 60
                let rest = minutes % 60
                return rest == 0 ? "\(hours) hr left" : "\(hours) hr \(rest) min left"
            }
            return "\(minutes) min left"
        }
    }

    private static let key = "movieResumePositions"
    private static let limit = 60
    /// Less than this in, or this close to the end, and there's nothing to resume.
    private static let minimumSeconds: Double = 10
    private static let finishedMargin: Double = 45

    /// The disc in a drive whose address doesn't say which disc it holds, and what the disc
    /// calls itself: where it was stopped is kept under both, so that the next disc in the
    /// same drive starts at its start. (Set from the main thread as discs come and go.)
    nonisolated(unsafe) static var discInDrive: (path: String, name: String)?

    /// What a movie's place is kept under: its path, with the disc's name for a disc in a drive.
    private static func place(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let discInDrive, discInDrive.path == path {
            return path + "#" + discInDrive.name
        }
        return path
    }

    /// Read often (the Movies menu asks on every draw), so kept until something changes.
    nonisolated(unsafe) private static var cachedEntries: [Entry]?

    /// Newest first, leaving out files that have gone.
    static func entries() -> [Entry] {
        if let cachedEntries { return cachedEntries }
        let list = stored().filter { FileManager.default.fileExists(atPath: $0.path) }
        cachedEntries = list
        return list
    }

    static func seconds(for url: URL) -> Double? {
        guard url.isFileURL else { return nil }
        let path = place(of: url)
        return stored().first { $0.path == path }?.seconds
    }

    /// Remembers where a file stopped, or forgets it if it was barely started or played to the end.
    static func record(_ url: URL, seconds: Double, duration: Double) {
        guard url.isFileURL, seconds.isFinite else { return }
        let path = place(of: url)
        var list = stored().filter { $0.path != path }
        let hasLength = duration.isFinite && duration > 0
        let finished = hasLength && (seconds >= duration - finishedMargin || seconds / duration > 0.95)
        if seconds >= minimumSeconds, !finished {
            let title = url.deletingPathExtension().lastPathComponent
            list.insert(Entry(path: path, title: title, seconds: seconds, duration: hasLength ? duration : 0, date: Date()), at: 0)
        }
        save(Array(list.prefix(limit)))
    }

    /// Forgets every movie (for test runs).
    static func removeAll() {
        save([])
    }

    static func remove(_ url: URL) {
        let path = place(of: url)
        save(stored().filter { $0.path != path })
    }

    private static func stored() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return list
    }

    private static func save(_ list: [Entry]) {
        cachedEntries = nil
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

extension MenuView {
    static let continueWatchingItemID = "movies_continue_watching"

    /// Movies > Continue Watching: files stopped part way, newest first, shown like a movies
    /// folder so they get its previews and the resume prompt.
    func enterContinueWatchingMenu() {
        transitionMenuForFolderSwap {
            let entries = MovieResumeStore.entries()
            self.thirdMenuMode = .moviesFolder
            self.resetAllITunesTopMenusForNonITunesContext()
            self.isShowingContinueWatching = true
            self.thirdMenuRootURL = nil
            self.thirdMenuCurrentURL = nil
            self.thirdMenuItems = entries.map {
                MoviesFolderEntry(id: "continue|\($0.path)", title: $0.title, url: $0.url, isDirectory: false)
            }
            self.continueWatchingRemainingText = Dictionary(uniqueKeysWithValues: entries.map { ("continue|\($0.path)", $0.remainingText ?? "") })
            self.selectedThirdIndex = 0
            self.headerText = "Continue Watching"
            self.isInThirdMenu = true
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
            self.refreshDetailPreviewForCurrentContext()
        }
    }
}

extension MenuView {
    /// Brings Continue Watching up to date after a movie stops, keeping the selection on the
    /// same movie where it's still listed.
    func refreshContinueWatchingIfShown() {
        guard isShowingContinueWatching, thirdMenuMode == .moviesFolder else { return }
        let selectedID = thirdMenuItems.indices.contains(selectedThirdIndex) ? thirdMenuItems[selectedThirdIndex].id : nil
        let entries = MovieResumeStore.entries()
        guard !entries.isEmpty else {
            leaveEmptyContinueWatching()
            return
        }
        thirdMenuItems = entries.map {
            MoviesFolderEntry(id: "continue|\($0.path)", title: $0.title, url: $0.url, isDirectory: false)
        }
        continueWatchingRemainingText = Dictionary(uniqueKeysWithValues: entries.map { ("continue|\($0.path)", $0.remainingText ?? "") })
        if let selectedID, let index = thirdMenuItems.firstIndex(where: { $0.id == selectedID }) {
            selectedThirdIndex = index
        } else {
            selectedThirdIndex = min(selectedThirdIndex, max(0, thirdMenuItems.count - 1))
        }
    }

    /// Nothing left to continue (the last one was watched to the end): back to the Movies menu
    /// it was opened from, rather than an empty list. Behind a movie, that happens out of sight,
    /// so the movie ends on the Movies menu.
    private func leaveEmptyContinueWatching() {
        guard isMoviePlaybackVisible || isMovieTransitioning else {
            exitMoviesThirdMenuToSecondLevelWithSwap()
            return
        }
        isInThirdMenu = false
        thirdMenuMode = .none
        thirdMenuOpacity = 0
        submenuOpacity = 1
        headerText = rootMenuTitle(for: activeRootItemID)
        resetThirdMenuDirectoryState()
        moviesFolderSelectionIndexByDirectoryPath = [:]
        // The Continue Watching row has gone from the top: its place is the first row now.
        selectedSubIndex = 0
        musicSubmenuSelectionMemo = nil
        refreshDetailPreviewForCurrentContext()
    }
}
