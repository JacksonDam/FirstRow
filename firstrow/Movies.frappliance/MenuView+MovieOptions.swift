import AVFoundation
import Foundation

/// The panel ↓ opens during a movie (or its buttons above the bar): subtitles, audio track,
/// chapter and playback speed, and for a YouTube video the size of its picture, what it is and
/// its comments.
/// Up and down move between rows, left and right (or Select) change the value, Menu or ↑ from
/// the top closes it, back into its buttons.
extension MenuView {
    struct MovieOptionRow: Equatable {
        enum Kind: Hashable {
            case subtitles
            case audio
            case chapters
            case quality
            case speed
            case info
            case comments
        }

        let kind: Kind
        let title: String
        var values: [String]
        var selected: Int
        /// The row opens something more (Select or →) and has no value to change.
        var opensMore = false
    }

    struct MovieOptionsState {
        var rows: [MovieOptionRow]
        var focusedRow = 0
        /// Set once up or down has moved the focus, so rows arriving late don't move it.
        var hasMoved = false
        /// The row to open on (the button it was opened from), once the rows are in.
        var preferredKind: MovieOptionRow.Kind?
        /// For a YouTube video: its caption tracks (nil for none) and the sizes of its picture
        /// (nil for whatever suits), in the order of their rows' values.
        var captionTracks: [Int?] = []
        var pictureHeights: [Int?] = []
        /// The file's own subtitle tracks (nil for none) and audio tracks, by their ids, and
        /// where its chapters start, each in the order of its row's values.
        var subtitleIDs: [Int?] = []
        var audioIDs: [Int] = []
        var chapterStarts: [Double] = []
    }

    static let movieSpeeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2]

    static func speedTitle(_ speed: Double) -> String {
        let text = speed == speed.rounded() ? String(Int(speed)) : String(format: "%g", speed)
        return text + "×"
    }

    var isMovieOptionsVisible: Bool {
        movieOptions != nil
    }

    /// Opens the panel, out of its buttons, on the row for `kind` (the first row if nil).
    func openMovieOptions(focusing kind: MovieOptionRow.Kind? = nil) {
        guard let player = moviePlayer, movieOptions == nil, !isMovieTransitioning else { return }
        stopMovieScrubbing(revertToPause: false, scheduleAutoHide: false)
        movieControlsGlyphState = player.rate > 0.01 ? .play : .pause
        showMovieControlsInstantly()
        playSound(named: "Selection")
        var state = MovieOptionsState(rows: [])
        state.rows = [speedRow()]
        state.preferredKind = kind
        if kind != nil { state.hasMoved = true }
        movieOptions = state
        // It opens once its rows are known, at the size it will have. Opened first and filled
        // in a moment later, it grew out of its button towards where a panel of one row goes,
        // and jumped to its own place part way: from its top corner, to look at.
        loadMovieTrackRows(player) { [weak self] in
            guard let self, self.movieOptions != nil else { return }
            withAnimation(.smooth(duration: 0.36)) {
                self.movieOptionsReveal = 1
            }
        }
    }

    /// Puts the panel back into its buttons.
    func closeMovieOptions() {
        guard movieOptions != nil else { return }
        withAnimation(.smoothInOut(duration: 0.3)) {
            movieOptions = nil
            movieOptionsReveal = 0
        }
        playSound(named: "Exit")
        scheduleMovieControlsAutoHide()
    }

    /// A tap or click on the options button: opens the panel on its first row, or closes it.
    func toggleMovieOptions() {
        if movieOptions == nil {
            openMovieOptions()
        } else {
            closeMovieOptions()
        }
    }

    /// The panel's rows say what the movie offers, for its buttons.
    private func noteMovieOptionKinds(_ rows: [MovieOptionRow]) {
        let kinds = rows.map(\.kind)
        if kinds != movieOptionKinds { movieOptionKinds = kinds }
    }

    /// Finds what the movie offers (subtitles, more than one audio track, chapters) for its
    /// buttons.
    func probeMovieOptionKinds(_ player: any MoviePlayer) {
        if youtubeSession != nil {
            let kinds = youtubeOptionKinds()
            if kinds != movieOptionKinds { movieOptionKinds = kinds }
            return
        }
        Task { @MainActor in
            let subtitles = await player.tracks(.subtitles)
            let audio = await player.tracks(.audio)
            let chapters = await player.chapters()
            guard self.moviePlayer === player else { return }
            var kinds: [MovieOptionRow.Kind] = []
            if !subtitles.isEmpty { kinds.append(.subtitles) }
            if audio.count > 1 { kinds.append(.audio) }
            if chapters.count > 1 { kinds.append(.chapters) }
            kinds.append(.speed)
            if kinds != self.movieOptionKinds { self.movieOptionKinds = kinds }
        }
    }

    private func speedRow() -> MovieOptionRow {
        let index = Self.movieSpeeds.firstIndex(of: movieSpeed) ?? Self.movieSpeeds.firstIndex(of: 1) ?? 0
        return MovieOptionRow(kind: .speed, title: L("Speed"), values: Self.movieSpeeds.map(Self.speedTitle), selected: index)
    }

    /// Fills in the subtitle, audio and chapter rows from the file, and says when it has.
    private func loadMovieTrackRows(_ player: any MoviePlayer, then done: @escaping () -> Void) {
        if youtubeSession != nil {
            loadYouTubeOptionRows()
            done()
            return
        }
        Task { @MainActor in
            let subtitles = await player.tracks(.subtitles)
            let audio = await player.tracks(.audio)
            let chapters = await player.chapters()
            guard var state = self.movieOptions, self.moviePlayer === player else {
                done()
                return
            }
            var rows: [MovieOptionRow] = []
            if !subtitles.isEmpty {
                state.subtitleIDs = [nil] + subtitles.map(\.id)
                let selected = subtitles.firstIndex(where: \.isChosen).map { $0 + 1 } ?? 0
                rows.append(MovieOptionRow(kind: .subtitles, title: L("Subtitles"), values: [L("Off")] + subtitles.map(\.title), selected: selected))
            }
            if audio.count > 1 {
                state.audioIDs = audio.map(\.id)
                rows.append(MovieOptionRow(kind: .audio, title: L("Audio"), values: audio.map(\.title), selected: audio.firstIndex(where: \.isChosen) ?? 0))
            }
            if chapters.count > 1 {
                state.chapterStarts = chapters.map(\.start)
                // (The chapter the movie is in: the last to have started.)
                let now = self.moviePlaybackCurrentSeconds + 0.25
                let current = chapters.lastIndex { $0.start <= now } ?? 0
                rows.append(MovieOptionRow(kind: .chapters, title: L("Chapter"), values: chapters.map(\.title), selected: current))
            }
            let focusedKind = state.preferredKind ?? (state.rows.indices.contains(state.focusedRow) ? state.rows[state.focusedRow].kind : .speed)
            state.rows = rows + state.rows.filter { $0.kind == .speed }
            state.focusedRow = state.hasMoved ? (state.rows.firstIndex { $0.kind == focusedKind } ?? 0) : 0
            state.preferredKind = nil
            self.movieOptions = state
            self.noteMovieOptionKinds(state.rows)
            done()
        }
    }

    // MARK: - Input

    /// Keys while the panel is open. Returns true when the panel took the key.
    func handleMovieOptionsInput(_ key: KeyCode) -> Bool {
        guard var state = movieOptions else { return false }
        showMovieControlsInstantly()
        switch key {
        case .escape, .delete:
            closeMovieOptions()
        case .upArrow:
            if state.focusedRow == 0 {
                closeMovieOptions()
            } else {
                state.focusedRow -= 1
                state.hasMoved = true
                state.preferredKind = nil
                movieOptions = state
                playSound(named: "SelectionChange")
            }
        case .downArrow:
            if state.focusedRow + 1 < state.rows.count {
                state.focusedRow += 1
                state.hasMoved = true
                state.preferredKind = nil
                movieOptions = state
                playSound(named: "SelectionChange")
            } else {
                playLimitSoundOnceForCurrentHold()
            }
        case .leftArrow:
            changeMovieOption(by: -1, wrapping: false)
        case .rightArrow:
            changeMovieOption(by: 1, wrapping: false)
        case .enter:
            changeMovieOption(by: 1, wrapping: true)
        case .space:
            handleMovieSpacebarPressed()
        default:
            break
        }
        return true
    }

    private func changeMovieOption(by step: Int, wrapping: Bool) {
        guard var state = movieOptions, state.rows.indices.contains(state.focusedRow) else { return }
        var row = state.rows[state.focusedRow]
        if row.opensMore {
            // (A row that opens a panel of its own, over the right of the picture.)
            let panel: YouTubePanelState.Kind? = switch row.kind {
            case .comments: .comments
            case .info: .info
            default: nil
            }
            if step > 0, let panel {
                openYouTubePanel(panel)
            } else {
                playLimitSoundOnceForCurrentHold()
            }
            return
        }
        var next = row.selected + step
        if wrapping {
            next = (next + row.values.count) % max(1, row.values.count)
        }
        guard row.values.indices.contains(next), next != row.selected else {
            playLimitSoundOnceForCurrentHold()
            return
        }
        row.selected = next
        state.rows[state.focusedRow] = row
        movieOptions = state
        playSound(named: "SelectionChange")
        applyMovieOption(row, state: state)
    }

    private func applyMovieOption(_ row: MovieOptionRow, state: MovieOptionsState) {
        guard let player = moviePlayer else { return }
        switch row.kind {
        case .speed:
            movieSpeed = Self.movieSpeeds[row.selected]
            player.setSpeed(movieSpeed)
        case .quality:
            if state.pictureHeights.indices.contains(row.selected) {
                setYouTubeMaximumHeight(state.pictureHeights[row.selected])
            }
        case .comments, .info:
            break
        case .subtitles:
            if youtubeSession != nil {
                if state.captionTracks.indices.contains(row.selected) {
                    selectYouTubeCaptions(state.captionTracks[row.selected])
                }
                return
            }
            if state.subtitleIDs.indices.contains(row.selected) {
                let id = state.subtitleIDs[row.selected]
                if id == nil, !movieCaptions.isEmpty { movieCaptions = [] }
                Task { @MainActor in await player.chooseTrack(.subtitles, id: id) }
            }
        case .audio:
            // (A YouTube video's sounds are streams of their own: it plays on with another.)
            if youtubeSession != nil {
                setYouTubeAudioTrack(row.selected)
                return
            }
            if state.audioIDs.indices.contains(row.selected) {
                let id = state.audioIDs[row.selected]
                Task { @MainActor in await player.chooseTrack(.audio, id: id) }
            }
        case .chapters:
            if state.chapterStarts.indices.contains(row.selected) {
                let seconds = state.chapterStarts[row.selected]
                stopMovieScrubbing(revertToPause: false, scheduleAutoHide: false)
                moviePlaybackCurrentSeconds = seconds
                player.seek(toSeconds: seconds, exactly: true)
            }
        }
    }
}
