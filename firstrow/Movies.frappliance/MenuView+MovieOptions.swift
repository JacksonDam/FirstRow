import AVFoundation
import Foundation

/// The panel ↓ opens during a movie (or its buttons above the bar): subtitles, audio track and
/// playback speed. Up and down move between rows, left and right (or Select) change the value,
/// Menu or ↑ from the top closes it, back into its buttons.
extension MenuView {
    struct MovieOptionRow: Equatable {
        enum Kind: Hashable {
            case subtitles
            case audio
            case speed
        }

        let kind: Kind
        let title: String
        var values: [String]
        var selected: Int
    }

    struct MovieOptionsState {
        var rows: [MovieOptionRow]
        var focusedRow = 0
        /// Set once up or down has moved the focus, so rows arriving late don't move it.
        var hasMoved = false
        /// The row to open on (the button it was opened from), once the rows are in.
        var preferredKind: MovieOptionRow.Kind?
        #if FIRSTROW_PORTABLE
            var subtitleIDs: [Int?] = []
            var audioIDs: [Int] = []
        #else
            var legibleGroup: AVMediaSelectionGroup?
            var legibleOptions: [AVMediaSelectionOption?] = []
            var audibleGroup: AVMediaSelectionGroup?
            var audibleOptions: [AVMediaSelectionOption] = []
        #endif
    }

    static let movieSpeeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

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
        withAnimation(.smooth(duration: 0.36)) {
            movieOptionsReveal = 1
        }
        loadMovieTrackRows(player)
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

    /// A tap or click on one of the buttons: opens the panel on that row, moves to it if the
    /// panel's open on another, or closes it.
    func toggleMovieOptions(focusing kind: MovieOptionRow.Kind) {
        guard var state = movieOptions else {
            openMovieOptions(focusing: kind)
            return
        }
        guard let index = state.rows.firstIndex(where: { $0.kind == kind }), index != state.focusedRow else {
            closeMovieOptions()
            return
        }
        state.focusedRow = index
        state.hasMoved = true
        movieOptions = state
        playSound(named: "SelectionChange")
    }

    /// The panel's rows say what the movie offers, for its buttons.
    private func noteMovieOptionKinds(_ rows: [MovieOptionRow]) {
        let kinds = rows.map(\.kind)
        if kinds != movieOptionKinds { movieOptionKinds = kinds }
    }

    /// Finds what the movie offers (subtitles, more than one audio track) for its buttons.
    func probeMovieOptionKinds(_ player: AVPlayer) {
        #if FIRSTROW_PORTABLE
            var kinds: [MovieOptionRow.Kind] = []
            if !player.tracks(ofType: "sub").isEmpty { kinds.append(.subtitles) }
            if player.tracks(ofType: "audio").count > 1 { kinds.append(.audio) }
            kinds.append(.speed)
            if kinds != movieOptionKinds { movieOptionKinds = kinds }
        #else
            guard let item = player.currentItem else { return }
            Task { @MainActor in
                let legible = await Self.mediaSelectionGroup(item.asset, .legible)
                let audible = await Self.mediaSelectionGroup(item.asset, .audible)
                guard self.moviePlayer === player else { return }
                var kinds: [MovieOptionRow.Kind] = []
                if let legible, legible.options.contains(where: { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }) {
                    kinds.append(.subtitles)
                }
                if let audible, audible.options.count > 1 { kinds.append(.audio) }
                kinds.append(.speed)
                if kinds != self.movieOptionKinds { self.movieOptionKinds = kinds }
            }
        #endif
    }

    private func speedRow() -> MovieOptionRow {
        let index = Self.movieSpeeds.firstIndex(of: movieSpeed) ?? Self.movieSpeeds.firstIndex(of: 1) ?? 0
        return MovieOptionRow(kind: .speed, title: "Speed", values: Self.movieSpeeds.map(Self.speedTitle), selected: index)
    }

    /// Fills in the subtitle and audio rows from the file's tracks.
    private func loadMovieTrackRows(_ player: AVPlayer) {
        #if FIRSTROW_PORTABLE
            let subtitles = player.tracks(ofType: "sub")
            let audio = player.tracks(ofType: "audio")
            guard var state = movieOptions else { return }
            var rows: [MovieOptionRow] = []
            if !subtitles.isEmpty {
                state.subtitleIDs = [nil] + subtitles.map(\.id)
                let selected = subtitles.firstIndex(where: \.isSelected).map { $0 + 1 } ?? 0
                rows.append(MovieOptionRow(kind: .subtitles, title: "Subtitles", values: ["Off"] + subtitles.map(\.title), selected: selected))
            }
            if audio.count > 1 {
                state.audioIDs = audio.map(\.id)
                rows.append(MovieOptionRow(kind: .audio, title: "Audio", values: audio.map(\.title), selected: audio.firstIndex(where: \.isSelected) ?? 0))
            }
            state.rows = rows + state.rows
            if let preferred = state.preferredKind, let index = state.rows.firstIndex(where: { $0.kind == preferred }) {
                state.focusedRow = index
            }
            movieOptions = state
            noteMovieOptionKinds(state.rows)
        #else
            guard let item = player.currentItem else { return }
            Task { @MainActor in
                let legible = await Self.mediaSelectionGroup(item.asset, .legible)
                let audible = await Self.mediaSelectionGroup(item.asset, .audible)
                guard var state = self.movieOptions, self.moviePlayer === player else { return }
                var rows: [MovieOptionRow] = []
                if let legible {
                    let options = legible.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
                    if !options.isEmpty {
                        let current = item.currentMediaSelection.selectedMediaOption(in: legible)
                        state.legibleGroup = legible
                        state.legibleOptions = [nil] + options
                        let selected = current.flatMap { options.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                        rows.append(MovieOptionRow(kind: .subtitles, title: "Subtitles", values: ["Off"] + options.map(\.displayName), selected: selected))
                    }
                }
                if let audible, audible.options.count > 1 {
                    let current = item.currentMediaSelection.selectedMediaOption(in: audible)
                    state.audibleGroup = audible
                    state.audibleOptions = audible.options
                    rows.append(MovieOptionRow(kind: .audio, title: "Audio", values: audible.options.map(\.displayName), selected: current.flatMap { audible.options.firstIndex(of: $0) } ?? 0))
                }
                let focusedKind = state.preferredKind ?? (state.rows.indices.contains(state.focusedRow) ? state.rows[state.focusedRow].kind : .speed)
                state.rows = rows + state.rows.filter { $0.kind == .speed }
                state.focusedRow = state.hasMoved ? (state.rows.firstIndex { $0.kind == focusedKind } ?? 0) : 0
                state.preferredKind = nil
                self.movieOptions = state
                self.noteMovieOptionKinds(state.rows)
            }
        #endif
    }

    #if !FIRSTROW_PORTABLE
        private static func mediaSelectionGroup(_ asset: AVAsset, _ characteristic: AVMediaCharacteristic) async -> AVMediaSelectionGroup? {
            if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
                return try? await asset.loadMediaSelectionGroup(for: characteristic)
            }
            return asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
        }
    #endif

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
            applyMovieSpeed(player)
        case .subtitles:
            #if FIRSTROW_PORTABLE
                if state.subtitleIDs.indices.contains(row.selected) {
                    player.selectTrack(ofType: "sub", id: state.subtitleIDs[row.selected])
                }
            #else
                if let group = state.legibleGroup, state.legibleOptions.indices.contains(row.selected) {
                    player.currentItem?.select(state.legibleOptions[row.selected], in: group)
                }
            #endif
        case .audio:
            #if FIRSTROW_PORTABLE
                if state.audioIDs.indices.contains(row.selected) {
                    player.selectTrack(ofType: "audio", id: state.audioIDs[row.selected])
                }
            #else
                if let group = state.audibleGroup, state.audibleOptions.indices.contains(row.selected) {
                    player.currentItem?.select(state.audibleOptions[row.selected], in: group)
                }
            #endif
        }
    }

    /// Plays at the chosen speed, now and whenever playback resumes.
    func applyMovieSpeed(_ player: AVPlayer) {
        #if FIRSTROW_PORTABLE
            player.playbackSpeed = movieSpeed
        #else
            if #available(macOS 13.0, iOS 16.0, tvOS 16.0, *) {
                player.defaultRate = Float(movieSpeed)
            }
            if player.rate > 0.01 {
                player.rate = Float(movieSpeed)
            }
        #endif
    }
}
