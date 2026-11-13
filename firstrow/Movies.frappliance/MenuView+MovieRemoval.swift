import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import CPortable
    import FirstRowPortable
#endif

// Taking a movie out. Holding the confirm input on a movie (Return, a remote's or a
// controller's Select, the mouse button, a finger) brings up a question with two answers side
// by side, Delete and Cancel, with Cancel the one picked out.
//
// What Delete does depends on whose the movie is. A movie First Row keeps a copy of (brought
// in from Files on iPhone and iPad) loses the copy. One of the person's own files, on a Mac or
// a PC, goes to the Trash, from where it can be put back. And in Continue Watching it is only
// the place in the movie that is forgotten.
//
// A folder, or a file, that was brought in with Movies > Import and stands at the top of
// Movies Folder is asked about in the same way, and is only taken out of First Row: it stays
// where it is, with everything in it.

/// A movie that the question screen is asking about.
struct MovieRemoval: Equatable {
    enum Kind: Equatable {
        /// First Row's own copy, on iPhone and iPad.
        case ownCopy
        /// One of the person's own files, which goes to the Trash.
        case ownFile
        /// A row of Continue Watching: only where it was stopped is forgotten.
        case continueWatching
        /// A folder or a file brought in with Import: it is no longer shown, and stays where it is.
        case imported(isFolder: Bool)
    }

    var url: URL
    var title: String
    var kind: Kind

    var question: String {
        switch kind {
        case .continueWatching: "Remove “\(title)” from Continue Watching?"
        case .imported: "Remove “\(title)” from First Row?"
        case .ownCopy, .ownFile: "Delete “\(title)”?"
        }
    }

    /// What will happen, under the question.
    var note: String? {
        switch kind {
        case .ownCopy: "It will be removed from First Row."
        case .continueWatching: nil
        case let .imported(isFolder): isFolder ? "The folder and what is in it stay where they are." : "The file stays where it is."
        case .ownFile:
            #if os(Windows)
                "It will be moved to the Recycle Bin."
            #else
                "It will be moved to the Trash."
            #endif
        }
    }

    /// The two answers, in their order on the screen.
    var answers: [String] {
        switch kind {
        case .continueWatching, .imported: ["Remove", "Cancel"]
        case .ownCopy, .ownFile: ["Delete", "Cancel"]
        }
    }

    /// What is said if it couldn't be done.
    var failure: (header: String, subcaption: String) {
        switch kind {
        case .imported:
            ("“\(title)” couldn't be removed.", "First Row has lost track of it. It can be taken out in Settings, under Media Folders.")
        case .continueWatching, .ownCopy, .ownFile:
            ("“\(title)” couldn't be deleted.", "First Row isn't allowed to change it where it is.")
        }
    }
}

extension MenuView {
    /// How long a key or a button is held before it counts as held, and a finger, which has
    /// first to be told from one that is about to scroll.
    static let confirmHoldDelay: TimeInterval = 0.7
    static let touchRemoveHoldDelay: TimeInterval = 1.0

    // MARK: - Which movies

    /// The movie in a row of the list that is showing, if it is one that can be taken out
    /// (or the folder, if it is one that was brought in).
    func movieRemoval(forThirdMenuRow index: Int) -> MovieRemoval? {
        guard activeRootItemID == "movies" || tvShowListing != nil, isInThirdMenu, thirdMenuMode == .moviesFolder,
              activeFullscreenScene == nil, !isMovieTransitioning, !isMenuFolderSwapTransitioning, !isMovieResumePromptVisible,
              !isMoviePlaybackVisible, !isLoadingMoviesFolderEntries, thirdMenuItems.indices.contains(index)
        else { return nil }
        let entry = thirdMenuItems[index]
        guard entry.url.isFileURL else { return nil }
        if isShowingContinueWatching {
            return entry.isDirectory ? nil : MovieRemoval(url: entry.url, title: entry.title, kind: .continueWatching)
        }
        // What was brought in with Import, at the top of Movies Folder: a folder or a file.
        if entry.isImported, thirdMenuCurrentURL == nil {
            return MovieRemoval(url: entry.url, title: entry.title, kind: .imported(isFolder: entry.isDirectory))
        }
        guard !entry.isDirectory else { return nil }
        // (An episode is asked about by its show and its name: its row has only its number.)
        let title = tvShowListing == nil ? entry.title : tvLibrary.episode(at: entry.url)?.titleWithShow ?? entry.title
        #if os(iOS)
            // (Only what First Row keeps itself: nothing in a folder of someone else's.)
            let own = moviesDocumentsDirectoryURL().standardizedFileURL.path
            guard entry.url.standardizedFileURL.path.hasPrefix(own + "/") else { return nil }
            return MovieRemoval(url: entry.url, title: title, kind: .ownCopy)
        #elseif os(macOS) || FIRSTROW_PORTABLE
            return MovieRemoval(url: entry.url, title: title, kind: .ownFile)
        #else
            return nil
        #endif
    }

    // MARK: - Holding the confirm input

    /// A confirm press that will be let go of has begun on the row that's picked out (a key,
    /// a button). True if that row is a movie that can be taken out: the press then does what
    /// it usually does as it is let go (`confirmPressEnded`), or brings the question up if it
    /// is held instead.
    func confirmPressBegan() -> Bool {
        if isConfirmPressDown { return true }
        guard let removal = movieRemoval(forThirdMenuRow: selectedThirdIndex) else { return false }
        isConfirmPressDown = true
        confirmHoldFired = false
        confirmHold?.cancel()
        let hold = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolatedIfPossible {
                guard let self, self.isConfirmPressDown, self.movieRemoval(forThirdMenuRow: self.selectedThirdIndex) == removal else { return }
                self.confirmHoldFired = true
                self.askAboutRemoving(removal)
            }
        }
        confirmHold = hold
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmHoldDelay, execute: hold)
        return true
    }

    /// The press has been let go of: if it wasn't held long enough to ask, it is a press.
    func confirmPressEnded() {
        guard isConfirmPressDown else { return }
        isConfirmPressDown = false
        confirmHold?.cancel()
        confirmHold = nil
        let fired = confirmHoldFired
        confirmHoldFired = false
        if !fired { handleKeyInput(.enter, isRepeat: false) }
    }

    /// A pointer or a finger has been kept down on a row for long enough: asks about the
    /// movie there, if it's one that can be taken out. Returns whether it asked.
    func askAboutRemovingMovie(inThirdMenuRow index: Int) -> Bool {
        guard let removal = movieRemoval(forThirdMenuRow: index) else { return false }
        if index != selectedThirdIndex { selectedThirdIndex = index }
        askAboutRemoving(removal)
        return true
    }

    // MARK: - The question

    /// Fades the menu away and brings the question up, over a blurred frame of the movie.
    func askAboutRemoving(_ removal: MovieRemoval) {
        guard !isMovieTransitioning, !isMovieResumePromptVisible else { return }
        isMovieTransitioning = true
        playSound(named: "Selection")
        movieResumePromptOpacity = 0
        withAnimation(.easeInOut(duration: movieEntryFadeDuration)) {
            menuSceneOpacity = 0
        }
        Task {
            try? await firstRowSleep(movieEntryFadeDuration)
            guard !Task.isCancelled else { return }
            // (Behind the question about a folder, a picture from the first movie in it,
            // found away from the main thread.)
            var picture: URL?
            if case .imported(isFolder: true) = removal.kind {
                let rules = moviesScanRules
                picture = await Task.detached(priority: .userInitiated) {
                    MoviesFolderScanner.previewMovieFileURLs(in: removal.url, limit: 1, rules: rules).first
                }.value
                guard !Task.isCancelled else { return }
            }
            presentMovieResumePrompt(for: removal.url, pictureFrom: picture)
            movieRemoval = removal
            // (Cancel is the answer picked out: deleting takes a deliberate move.)
            movieResumePromptSelectedIndex = 1
            withAnimation(.easeInOut(duration: movieResumePromptFadeDuration)) {
                movieResumePromptOpacity = 1
            }
            try? await firstRowSleep(movieResumePromptFadeDuration)
            guard !Task.isCancelled else { return }
            isMovieTransitioning = false
        }
    }

    /// Keys while the question is up: left and right move between the two answers.
    func handleMovieRemovalInput(_ key: KeyCode) {
        guard let removal = movieRemoval, !isMovieResumePromptConfirming, !isMovieTransitioning else { return }
        switch key {
        case .leftArrow, .rightArrow:
            let next = key == .leftArrow ? 0 : 1
            guard next != movieResumePromptSelectedIndex else {
                playLimitSoundOnceForCurrentHold()
                return
            }
            withAnimation(.easeInOut(duration: 0.16)) {
                movieResumePromptSelectedIndex = next
            }
            playSound(named: "SelectionChange")
        case .enter:
            if movieResumePromptSelectedIndex == 0 {
                playSound(named: "Selection")
                let removed = remove(removal)
                leaveMovieRemoval(showing: removed ? nil : removal)
            } else {
                playSound(named: "Exit")
                leaveMovieRemoval(showing: nil)
            }
        case .delete, .escape:
            playSound(named: "Exit")
            leaveMovieRemoval(showing: nil)
        default:
            break
        }
    }

    /// Back to the list, brought up to date. If the movie couldn't be deleted, that is said.
    private func leaveMovieRemoval(showing failed: MovieRemoval?) {
        noteMoviesTopLevelChanged()
        if isShowingContinueWatching {
            refreshContinueWatchingIfShown()
        } else if tvShowListing != nil {
            tvEpisodeWasRemoved()
        } else if thirdMenuMode == .moviesFolder {
            if let folder = thirdMenuCurrentURL {
                loadThirdMenuDirectory(folder, resetSelection: false)
            } else {
                rememberCurrentMoviesFolderSelectionIndex()
                loadMoviesTopLevel(resetSelection: false)
            }
        }
        dismissMovieResumePromptToMenu()
        guard let failed else { return }
        Task {
            try? await firstRowSleep(movieResumePromptFadeDuration * 2 + 0.1)
            presentFullscreenScene(key: featureErrorFullscreenKey, payload: [
                "header": failed.failure.header,
                "subcaption": failed.failure.subcaption,
            ])
        }
    }

    // MARK: - Removing

    /// Does what Delete says for this movie. False if it couldn't be done.
    private func remove(_ removal: MovieRemoval) -> Bool {
        let file = removal.url.standardizedFileURL
        var removed = true
        switch removal.kind {
        case .continueWatching:
            break
        case .ownCopy:
            #if os(iOS)
                removed = removeOwnMovie(file)
            #else
                removed = false
            #endif
        case .ownFile:
            removed = Self.moveToTrash(file)
        case let .imported(isFolder):
            // (Found by where it is: the list in Settings may have changed meanwhile.)
            let entries = MediaSources.shared.folderEntries(.movies)
            guard let index = entries.firstIndex(where: { $0.url?.standardizedFileURL.path == file.path }) else { return false }
            MediaSources.shared.removeFolder(at: index, kind: .movies)
            mediaSourcesRevision &+= 1
            // (A folder's movies keep their places: it may be brought in again.)
            if isFolder { return true }
        }
        guard removed else { return false }
        MovieResumeStore.remove(file)
        if lastClosedMovieURL?.standardizedFileURL == file { lastClosedMovieURL = nil }
        return true
    }

    /// Puts a file or a folder in the system's Trash (the Recycle Bin on Windows).
    private static func moveToTrash(_ file: URL) -> Bool {
        #if os(macOS)
            return (try? FileManager.default.trashItem(at: file, resultingItemURL: nil)) != nil
        #elseif FIRSTROW_PORTABLE
            let path = file.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? file.path
            return fr_move_to_trash(path) != 0
        #else
            return false
        #endif
    }
}
