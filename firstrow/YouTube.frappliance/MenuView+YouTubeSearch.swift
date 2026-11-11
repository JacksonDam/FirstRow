import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// A key of the search screen's grid.
enum YouTubeSearchKey: Equatable {
    case character(String)
    case space
    case delete
    /// Turns the grid over to symbols, and back to letters.
    case symbols

    func label(showsSymbols: Bool) -> String {
        switch self {
        case let .character(value): value
        case .space: "Space"
        case .delete: "Delete"
        case .symbols: showsSymbols ? "abc" : "#=+"
        }
    }

    /// Six rows of six keys, and under them three wide ones.
    static func rows(showsSymbols: Bool) -> [[YouTubeSearchKey]] {
        let grid = showsSymbols
            ? ["!@#$%&", "*()-_+", "=:;'\"?", ",./<>~", "[]{}|\\", "^`€£¥°"]
            : ["abcdef", "ghijkl", "mnopqr", "stuvwx", "yz1234", "567890"]
        return grid.map { $0.map { .character(String($0)) } } + [[.space, .delete, .symbols]]
    }
}

/// The search screen: on the left a field and a grid of
/// keys to pick with the arrows (a keyboard types into the field as well), on the right what has
/// been found so far, which changes as the text does.
struct YouTubeSearchPad: Equatable {
    var text = ""
    var row = 0
    var column = 0
    var showsSymbols = false
    /// The keys have the arrows; otherwise the list of what was found has them.
    var hasFocus = true
    /// The text has been asked about and the answer hasn't come.
    var isSearching = false
    /// The last input was typed on a keyboard: Return then goes to what was found.
    var lastInputWasTyping = false
}

extension MenuView {
    static let youtubeSearchTextLimit = 80

    /// Whether Search has the screen above. Not on iPhone and iPad, where fingers type on the
    /// system's keyboard.
    static var youtubeSearchUsesPad: Bool {
        #if os(iOS)
            false
        #else
            true
        #endif
    }

    /// The search screen's keys, while it is the screen showing.
    var youtubeSearchPad: YouTubeSearchPad? {
        guard isInThirdMenu, thirdMenuMode == .youtube else { return nil }
        return currentYouTubePage?.searchPad
    }

    var youtubeSearchPadHasFocus: Bool {
        youtubeSearchPad?.hasFocus == true
    }

    /// Typing on a keyboard goes into the search field (nothing else is in front of it).
    var youtubeSearchTakesTypedText: Bool {
        youtubeSearchPad != nil && textEntry == nil && codeDisplay == nil && activeFullscreenScene == nil &&
            !isMoviePlaybackVisible && !isMovieTransitioning && !isFullscreenSceneTransitioning
    }

    /// What the search screen says over its field: how many videos there are so far.
    var youtubeSearchResultsText: String {
        guard let pad = youtubeSearchPad, !pad.text.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        if pad.isSearching { return "Searching..." }
        let count = currentYouTubePage?.videos.count ?? 0
        return count == 1 ? "1 Result" : "\(count) Results"
    }

    func enterYouTubeSearchPad() {
        youtube.requestID &+= 1
        transitionMenuForFolderSwap(useOverlayFade: true) {
            self.thirdMenuMode = .youtube
            self.isInThirdMenu = true
            var state = YouTubePageState(page: .search(""))
            state.isLoaded = true
            state.searchPad = YouTubeSearchPad()
            self.youtube.pages = [state]
            self.youtube.error = nil
            self.youtube.status = nil
            self.selectedThirdIndex = 0
            self.headerText = "Search"
            self.clearYouTubePreview()
            self.submenuOpacity = 0
            self.thirdMenuOpacity = 1
            self.updateYouTubeSearchTextInput()
        }
    }

    /// Typed text reaches First Row on Linux and Windows only while it's asked for.
    func updateYouTubeSearchTextInput() {
        #if FIRSTROW_PORTABLE
            let wanted = youtubeSearchPad != nil
            guard wanted != youtube.asksForTypedText, textEntry == nil else { return }
            youtube.asksForTypedText = wanted
            PortableApplication.setTextInputActive(wanted)
        #endif
    }

    // MARK: - Arrows and Select

    /// An arrow, Select or Back on the search screen. False for what the list handles itself.
    func handleYouTubeSearchPadInput(_ key: KeyCode) -> Bool {
        guard let index = youtube.pages.indices.last, var pad = youtubeSearchPad else { return false }
        let hasResults = !(currentYouTubePage?.videos.isEmpty ?? true)
        guard pad.hasFocus else {
            // The list has the arrows: left goes back to the keys.
            guard key == .leftArrow else { return false }
            pad.hasFocus = true
            pad.lastInputWasTyping = false
            youtube.pages[index].searchPad = pad
            playSound(named: "SelectionChange")
            return true
        }
        func goToResults() {
            pad.hasFocus = false
            pad.lastInputWasTyping = false
            youtube.pages[index].searchPad = pad
            selectedThirdIndex = min(selectedThirdIndex, max(0, youtubeMenuListItems().count - 1))
            playSound(named: "SelectionChange")
            refreshDetailPreviewForCurrentContext()
        }
        let rows = YouTubeSearchKey.rows(showsSymbols: pad.showsSymbols)
        switch key {
        case .upArrow:
            moveYouTubeSearchPadFocus(rows: -1)
        case .downArrow:
            moveYouTubeSearchPadFocus(rows: 1)
        case .leftArrow, .rightArrow:
            let target = pad.column + (key == .leftArrow ? -1 : 1)
            if rows[pad.row].indices.contains(target) {
                pad.column = target
                pad.lastInputWasTyping = false
                youtube.pages[index].searchPad = pad
                playSound(named: "SelectionChange")
            } else if key == .rightArrow, hasResults {
                goToResults()
            } else {
                playLimitSoundOnceForCurrentHold()
            }
        case .enter:
            if pad.lastInputWasTyping {
                // After typing, Return is for what was typed, not for the key the arrows left.
                if hasResults { goToResults() } else { playLimitSoundOnceForCurrentHold() }
            } else {
                pressYouTubeSearchKey(rows[pad.row][min(pad.column, rows[pad.row].count - 1)])
            }
        case .delete:
            #if os(tvOS)
                // (The remote's Back: it leaves, as everywhere. The grid has Delete.)
                return false
            #else
                guard !pad.text.isEmpty else { return false }
                pad.text.removeLast()
                youtube.pages[index].searchPad = pad
                playSound(named: "SelectionChange")
                youtubeSearchTextDidChange()
            #endif
        case .space:
            // (A typed space arrives as text.)
            break
        default:
            return false
        }
        return true
    }

    /// Whether the focus can move a row of keys up or down (positive is down).
    func canMoveYouTubeSearchPadFocus(rows step: Int) -> Bool {
        guard let pad = youtubeSearchPad, pad.hasFocus else { return false }
        return YouTubeSearchKey.rows(showsSymbols: pad.showsSymbols).indices.contains(pad.row + step)
    }

    @discardableResult
    func moveYouTubeSearchPadFocus(rows step: Int) -> Bool {
        guard let index = youtube.pages.indices.last, var pad = youtubeSearchPad, pad.hasFocus else { return false }
        let rows = YouTubeSearchKey.rows(showsSymbols: pad.showsSymbols)
        let target = pad.row + step
        guard rows.indices.contains(target) else {
            playLimitSoundOnceForCurrentHold()
            return false
        }
        // Each of the three wide keys sits under two of the six above it.
        if rows[target].count < rows[pad.row].count {
            pad.column /= 2
        } else if rows[target].count > rows[pad.row].count {
            pad.column *= 2
        }
        pad.column = min(pad.column, rows[target].count - 1)
        pad.row = target
        pad.lastInputWasTyping = false
        youtube.pages[index].searchPad = pad
        playSound(named: "SelectionChange")
        return true
    }

    private func pressYouTubeSearchKey(_ key: YouTubeSearchKey) {
        guard let index = youtube.pages.indices.last, var pad = youtubeSearchPad else { return }
        switch key {
        case let .character(value):
            pad.text += value
        case .space:
            guard !pad.text.isEmpty, !pad.text.hasSuffix(" ") else {
                playLimitSoundOnceForCurrentHold()
                return
            }
            pad.text += " "
        case .delete:
            guard !pad.text.isEmpty else {
                playLimitSoundOnceForCurrentHold()
                return
            }
            pad.text.removeLast()
        case .symbols:
            pad.showsSymbols.toggle()
            youtube.pages[index].searchPad = pad
            playSound(named: "Selection")
            return
        }
        pad.text = String(pad.text.prefix(Self.youtubeSearchTextLimit))
        youtube.pages[index].searchPad = pad
        playSound(named: "Selection")
        youtubeSearchTextDidChange()
    }

    /// The pointer is over a key: the arrows are there too.
    func pointAtYouTubeSearchKey(row: Int, column: Int) {
        guard let index = youtube.pages.indices.last, var pad = youtubeSearchPad else { return }
        guard !pad.hasFocus || pad.lastInputWasTyping || pad.row != row || pad.column != column else { return }
        let rows = YouTubeSearchKey.rows(showsSymbols: pad.showsSymbols)
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return }
        pad.row = row
        pad.column = column
        pad.hasFocus = true
        pad.lastInputWasTyping = false
        youtube.pages[index].searchPad = pad
        playSound(named: "SelectionChange")
    }

    func clickYouTubeSearchKey(row: Int, column: Int) {
        pointAtYouTubeSearchKey(row: row, column: column)
        guard let pad = youtubeSearchPad, pad.hasFocus else { return }
        let rows = YouTubeSearchKey.rows(showsSymbols: pad.showsSymbols)
        guard rows.indices.contains(pad.row), rows[pad.row].indices.contains(pad.column) else { return }
        pressYouTubeSearchKey(rows[pad.row][pad.column])
    }

    /// The pointer has picked a row of what was found: the list has the arrows now.
    func youtubeSearchPadDidPointAtResults() {
        guard let index = youtube.pages.indices.last, youtubeSearchPadHasFocus else { return }
        youtube.pages[index].searchPad?.hasFocus = false
        youtube.pages[index].searchPad?.lastInputWasTyping = false
    }

    // MARK: - Typing

    /// Characters typed on a keyboard while the search screen shows: they go into its field,
    /// wherever the arrows are. False if the search screen isn't the one to take them.
    func handleYouTubeSearchTypedText(_ typed: String) -> Bool {
        guard youtubeSearchTakesTypedText, let index = youtube.pages.indices.last, var pad = youtubeSearchPad else { return false }
        let printable = typed.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700 ... 0xF8FF).contains(scalar.value)
        }
        guard !printable.isEmpty else { return true }
        registerUserInteractionForScreenSaver()
        var text = pad.text + String(String.UnicodeScalarView(printable))
        while text.hasPrefix(" ") { text.removeFirst() }
        pad.text = String(text.prefix(Self.youtubeSearchTextLimit))
        pad.hasFocus = true
        pad.lastInputWasTyping = true
        youtube.pages[index].searchPad = pad
        youtubeSearchTextDidChange()
        return true
    }

    // MARK: - Looking as the text changes

    /// Asks YouTube about the text once it has stood still a moment, and shows what comes back
    /// in the list. What was asked about text that has changed since is dropped.
    private func youtubeSearchTextDidChange() {
        guard let index = youtube.pages.indices.last, var pad = youtube.pages[index].searchPad else { return }
        youtube.requestID &+= 1
        let requestID = youtube.requestID
        let query = pad.text.trimmingCharacters(in: .whitespacesAndNewlines)
        youtube.pages[index].page = .search(query)
        guard !query.isEmpty else {
            pad.isSearching = false
            youtube.pages[index].searchPad = pad
            youtube.pages[index].videos = []
            youtube.pages[index].continuation = nil
            youtube.pages[index].isLoadingMore = false
            youtube.error = nil
            selectedThirdIndex = 0
            return
        }
        pad.isSearching = true
        youtube.pages[index].searchPad = pad
        Task { @MainActor in
            try? await firstRowSleep(0.45)
            guard self.youtube.requestID == requestID else { return }
            var found: YouTubePage?
            var failure: String?
            do {
                found = try await YouTubeClient.shared.search(query)
            } catch {
                failure = error.localizedDescription
            }
            guard self.youtube.requestID == requestID, let index = self.youtube.pages.indices.last,
                  self.youtube.pages[index].searchPad != nil else { return }
            self.youtube.pages[index].searchPad?.isSearching = false
            self.youtube.pages[index].videos = found?.videos ?? []
            self.youtube.pages[index].continuation = found?.continuation
            self.youtube.pages[index].isLoadingMore = false
            self.youtube.error = failure
            self.selectedThirdIndex = 0
            if found?.videos.isEmpty != false { self.youtube.pages[index].searchPad?.hasFocus = true }
            self.refreshDetailPreviewForCurrentContext()
        }
    }
}
