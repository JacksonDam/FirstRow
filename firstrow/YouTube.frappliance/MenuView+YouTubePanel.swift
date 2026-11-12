import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// One thing in the panel over a YouTube video's picture: a comment, a line that does something
/// when it's pressed, a paragraph.
struct YouTubePanelRow: Equatable {
    enum Role: Equatable {
        /// A comment. Pressing it shows its replies, if it has any.
        case comment(YouTubeComment)
        /// The video's title, or a paragraph of its description: nothing to press.
        case text
        /// Who the video is from. Pressing it opens their channel.
        case channel(id: String, name: String)
    }

    var id: String
    var role: Role
    /// The first line, in bold: who wrote a comment, a channel's name, what a line does.
    var heading = ""
    /// Beside the heading, dimmer: when a comment was written, how many follow a channel.
    var aside = ""
    /// The words themselves, wrapped.
    var body = ""
    /// A dim last line: a comment's likes and replies, a video's views and date.
    var footer = ""
    /// A round picture to the left of the heading (a channel's).
    var pictureURL: URL?
    /// The words are a title: drawn larger.
    var isTitle = false
    /// Pressing it leads somewhere: it has a "›" at its right end.
    var leadsOn = false

    /// Pressing it does something.
    var isPressable: Bool {
        switch role {
        case let .comment(comment): comment.repliesToken != nil
        case .text: false
        case .channel: true
        }
    }
}

/// The panel over the right of a YouTube video's picture: its comments (and one comment's
/// replies), or what the video is and who it's from.
struct YouTubePanelState {
    enum Kind: Equatable {
        case comments
        case replies
        case info
    }

    /// The comments, kept while one of them shows its replies, to go back to.
    struct Comments {
        var rows: [YouTubePanelRow]
        var focused: Int
        var countText: String?
        var continuation: String?
    }

    var videoID: String
    var kind: Kind
    var rows: [YouTubePanelRow] = []
    var focused = 0
    /// Beside the title: "5,240" comments.
    var countText: String?
    /// Where more comments or replies come from.
    var continuation: String?
    /// How far the row picked out has been moved up, when there's more of it than the panel
    /// shows at once (a long description, a long comment).
    var scrolled: CGFloat = 0
    var isLoading = true
    var isLoadingMore = false
    /// Shown in place of rows when there are none.
    var note: String?
    var commentsBeneath: Comments?

    var title: String {
        switch kind {
        case .comments: "Comments"
        case .replies: "Replies"
        case .info: "Info"
        }
    }
}

/// The panel's contents and what pressing its rows does.
extension MenuView {
    var isYouTubePanelOut: Bool {
        youtubePanel != nil && youtubePanelReveal > 0
    }

    /// Brings the panel out over the right of the picture.
    func openYouTubePanel(_ kind: YouTubePanelState.Kind) {
        guard let session = youtubeSession, youtubePanel == nil else { return }
        playSound(named: "Selection")
        withAnimation(.smoothInOut(duration: 0.3)) {
            movieOptions = nil
            movieOptionsReveal = 0
        }
        youtubePanel = YouTubePanelState(videoID: session.video.id, kind: kind)
        withAnimation(.smooth(duration: 0.36)) {
            youtubePanelReveal = 1
        }
        spreadYouTubePanel(to: 1, .smooth(duration: 0.36))
        showMovieControlsInstantly()
        switch kind {
        case .comments, .replies: loadYouTubeComments()
        case .info: loadYouTubeInfo()
        }
    }

    func closeYouTubePanel(playsSound: Bool = true) {
        guard isYouTubePanelOut else { return }
        if playsSound { playSound(named: "Exit") }
        withAnimation(.smoothInOut(duration: 0.3)) {
            youtubePanelReveal = 0
        }
        spreadYouTubePanel(to: 0, .smoothInOut(duration: 0.3))
        scheduleMovieControlsAutoHide()
        Task { @MainActor in
            try? await firstRowSleep(0.32)
            guard self.youtubePanelReveal <= 0.001 else { return }
            self.youtubePanel = nil
        }
    }

    /// Moves what makes way for the panel (see `youtubePanelSpread`) in step with it.
    func spreadYouTubePanel(to target: CGFloat, _ animation: Animation?) {
        guard let animation, animation.duration > 0, abs(target - youtubePanelSpread) > 0.001 else {
            youtubePanelSpreadMove = nil
            if youtubePanelSpread != target { youtubePanelSpread = target }
            return
        }
        youtubePanelSpreadMove = (youtubePanelSpread, target, 0, animation)
        if youtubePanelSpreadClock.onFrame == nil {
            youtubePanelSpreadClock.onFrame = { [weak self] seconds in
                guard let self, var move = self.youtubePanelSpreadMove else { return false }
                move.elapsed += seconds
                let progress = min(1, move.elapsed / move.animation.duration)
                let eased = CGFloat(TimingCurve(move.animation.timingFunction).value(at: progress))
                self.youtubePanelSpread = move.from + (move.to - move.from) * eased
                self.youtubePanelSpreadMove = progress < 1 ? move : nil
                return progress < 1
            }
        }
        youtubePanelSpreadClock.run()
    }

    /// Back has a place of its own at the head of the panel while a comment's replies show:
    /// there it leads back to the comments, not out of the video.
    var youtubePanelHasBack: Bool {
        isYouTubePanelOut && youtubePanel?.kind == .replies
    }

    /// The panel under a point of the window, while it's out: whether the point is on it, and
    /// on which of its rows.
    func youtubePanelHit(at windowPoint: CGPoint) -> (isOnPanel: Bool, index: Int?)? {
        guard isMoviePlaybackVisible, isYouTubePanelOut else { return nil }
        return pointer.hitTester?.youtubePanelRow(at: windowPoint)
    }

    /// Changes the panel being shown, if it is still the one for `videoID` of that kind.
    private func changeYouTubePanel(_ videoID: String, _ kind: YouTubePanelState.Kind, _ change: (inout YouTubePanelState) -> Void) {
        guard var state = youtubePanel, state.videoID == videoID, state.kind == kind else { return }
        change(&state)
        youtubePanel = state
    }

    // MARK: Moving and pressing

    /// Picks out another row (for the wheel or a finger; the arrows have their own way below).
    /// One step up or down the panel: more of the row picked out, while there's more of it
    /// than the panel shows, then the next row (or the one before, at its end). False at
    /// either end of the panel.
    @discardableResult
    func moveYouTubePanel(by direction: Int, playsSound: Bool = true) -> Bool {
        guard var state = youtubePanel, isYouTubePanelOut, direction != 0 else { return false }
        func room(_ index: Int) -> (overflow: CGFloat, page: CGFloat) {
            pointer.hitTester?.youtubePanelRoom(ofRow: index) ?? (0, 400)
        }
        let here = room(state.focused)
        let scrolled = min(max(0, state.scrolled), here.overflow)
        if direction > 0 {
            if scrolled < here.overflow - 0.5 {
                state.scrolled = min(here.overflow, scrolled + here.page)
            } else if state.focused + 1 < state.rows.count {
                state.focused += 1
                state.scrolled = 0
            } else {
                return false
            }
        } else {
            if scrolled > 0.5 {
                state.scrolled = max(0, scrolled - here.page)
            } else if state.focused > 0 {
                state.focused -= 1
                // (Come to from below, it shows its end.)
                state.scrolled = room(state.focused).overflow
            } else {
                return false
            }
        }
        youtubePanel = state
        if playsSound { playSound(named: "SelectionChange") }
        loadMoreYouTubePanelRowsIfNeeded()
        return true
    }

    /// Moves the row picked out up under the panel by this much (a finger does, on a long one).
    func setYouTubePanelScrolled(_ scrolled: CGFloat) {
        guard var state = youtubePanel, isYouTubePanelOut, abs(state.scrolled - scrolled) > 0.5 else { return }
        state.scrolled = scrolled
        youtubePanel = state
    }

    func showYouTubePanelRow(_ index: Int, playsSound: Bool = false) {
        guard var state = youtubePanel, isYouTubePanelOut, index != state.focused, state.rows.indices.contains(index) else { return }
        state.focused = index
        state.scrolled = 0
        youtubePanel = state
        if playsSound { playSound(named: "SelectionChange") }
        loadMoreYouTubePanelRowsIfNeeded()
    }

    /// A click or a tap on a row: a row that does something does it; a comment is picked out,
    /// and pressed again shows its replies.
    func pressYouTubePanelRow(_ index: Int) {
        guard let state = youtubePanel, isYouTubePanelOut, state.rows.indices.contains(index) else { return }
        let row = state.rows[index]
        if case .comment = row.role, index != state.focused {
            showYouTubePanelRow(index, playsSound: true)
            return
        }
        if index != state.focused { showYouTubePanelRow(index) }
        if row.isPressable { pressFocusedYouTubePanelRow() }
    }

    /// Keys while the panel is out. Returns true when it took the key.
    func handleYouTubePanelInput(_ key: KeyCode) -> Bool {
        guard var state = youtubePanel, isYouTubePanelOut else { return false }
        switch key {
        case .escape, .delete, .leftArrow:
            if state.kind == .replies {
                leaveYouTubeReplies()
            } else {
                closeYouTubePanel()
            }
        case .upArrow, .downArrow:
            if !moveYouTubePanel(by: key == .downArrow ? 1 : -1) { playLimitSoundOnceForCurrentHold() }
        case .enter, .rightArrow:
            if state.rows.indices.contains(state.focused), state.rows[state.focused].isPressable {
                pressFocusedYouTubePanelRow()
            } else {
                playLimitSoundOnceForCurrentHold()
            }
        case .space:
            handleMovieSpacebarPressed()
        default:
            break
        }
        return true
    }

    private func pressFocusedYouTubePanelRow() {
        guard let state = youtubePanel, state.rows.indices.contains(state.focused) else { return }
        switch state.rows[state.focused].role {
        case let .comment(comment):
            openYouTubeReplies(to: comment)
        case let .channel(id, name):
            openYouTubeChannelFromPanel(id: id, name: name)
        case .text:
            break
        }
    }

    // MARK: Comments and replies

    private static func youtubeCommentRow(_ comment: YouTubeComment, id: String? = nil, leadsToReplies: Bool = true) -> YouTubePanelRow {
        var shown = comment
        if !leadsToReplies { shown.repliesToken = nil }
        var when = comment.publishedText
        if comment.isPinned { when = when.isEmpty ? "Pinned" : "Pinned, " + when }
        var words = comment.text
        if words.count > 700 { words = String(words.prefix(700)) + "…" }
        var parts: [String] = []
        // (A comment nobody has liked comes with a space for its count.)
        let likes = comment.likesText.trimmingCharacters(in: .whitespaces)
        let replies = comment.replyCountText.trimmingCharacters(in: .whitespaces)
        if !likes.isEmpty { parts.append(likes == "1" ? "1 like" : "\(likes) likes") }
        if !replies.isEmpty { parts.append(replies == "1" ? "1 reply" : "\(replies) replies") }
        if comment.isHearted { parts.append("liked by the creator") }
        return YouTubePanelRow(
            id: id ?? "comment:" + comment.id,
            role: .comment(shown),
            heading: comment.author,
            aside: when,
            body: words,
            footer: parts.joined(separator: ", "),
            leadsOn: shown.repliesToken != nil,
        )
    }

    private func loadYouTubeComments() {
        guard let videoID = youtubePanel?.videoID else { return }
        Task { @MainActor in
            do {
                var token = self.youtube.details[videoID]?.commentsToken
                if token == nil {
                    let details = try await YouTubeClient.shared.details(of: videoID)
                    self.rememberYouTubeDetails(details, for: videoID)
                    token = details.commentsToken
                }
                guard let token else {
                    self.changeYouTubePanel(videoID, .comments) {
                        $0.isLoading = false
                        $0.note = "Comments are turned off."
                    }
                    return
                }
                let page = try await YouTubeClient.shared.comments(token)
                self.changeYouTubePanel(videoID, .comments) { state in
                    state.isLoading = false
                    state.countText = page.totalText?.split(separator: " ").first.map(String.init)
                    state.rows = page.comments.map { Self.youtubeCommentRow($0) }
                    state.continuation = page.continuation
                    if page.comments.isEmpty { state.note = "No comments yet." }
                }
            } catch {
                self.changeYouTubePanel(videoID, .comments) {
                    $0.isLoading = false
                    $0.note = error.localizedDescription
                }
            }
        }
    }

    /// Fetches more comments, or more replies, as the row picked out nears the last one.
    private func loadMoreYouTubePanelRowsIfNeeded() {
        guard let state = youtubePanel, state.kind == .comments || state.kind == .replies, !state.isLoadingMore,
              let token = state.continuation, state.focused >= state.rows.count - 6, state.rows.count < 400
        else { return }
        youtubePanel?.isLoadingMore = true
        let (videoID, kind) = (state.videoID, state.kind)
        Task { @MainActor in
            let page = try? await YouTubeClient.shared.comments(token)
            self.changeYouTubePanel(videoID, kind) { state in
                state.isLoadingMore = false
                guard state.continuation == token else { return }
                guard let page else {
                    state.continuation = nil
                    return
                }
                let known = Set(state.rows.map(\.id))
                let fresh = page.comments.map { Self.youtubeCommentRow($0, leadsToReplies: kind == .comments) }.filter { !known.contains($0.id) }
                state.rows += fresh
                state.continuation = fresh.isEmpty ? nil : page.continuation
            }
        }
    }

    /// Shows a comment's replies in place of the comments, the comment itself at their head.
    private func openYouTubeReplies(to comment: YouTubeComment) {
        guard var state = youtubePanel, state.kind == .comments, let token = comment.repliesToken else { return }
        playSound(named: "Selection")
        state.commentsBeneath = .init(rows: state.rows, focused: state.focused, countText: state.countText, continuation: state.continuation)
        state.kind = .replies
        state.rows = [Self.youtubeCommentRow(comment, id: "parent", leadsToReplies: false)]
        state.focused = 0
        state.countText = comment.replyCountText.isEmpty ? nil : comment.replyCountText
        state.continuation = nil
        state.isLoading = true
        state.isLoadingMore = false
        state.note = nil
        youtubePanel = state
        let videoID = state.videoID
        Task { @MainActor in
            let page = try? await YouTubeClient.shared.comments(token)
            self.changeYouTubePanel(videoID, .replies) { state in
                guard state.rows.first?.id == "parent", state.rows.count == 1, state.isLoading else { return }
                state.isLoading = false
                state.rows += (page?.comments ?? []).map { Self.youtubeCommentRow($0, leadsToReplies: false) }
                state.continuation = page?.continuation
                // (On to the first reply: the comment has just been read.)
                if state.rows.count > 1 { state.focused = 1 }
            }
        }
    }

    /// Back from a comment's replies to the comments, as they were left.
    private func leaveYouTubeReplies() {
        guard var state = youtubePanel, state.kind == .replies, let comments = state.commentsBeneath else {
            closeYouTubePanel()
            return
        }
        playSound(named: "Exit")
        state.kind = .comments
        state.rows = comments.rows
        state.focused = min(comments.focused, max(0, comments.rows.count - 1))
        state.countText = comments.countText
        state.continuation = comments.continuation
        state.commentsBeneath = nil
        state.isLoading = false
        state.isLoadingMore = false
        state.note = nil
        youtubePanel = state
    }

    // MARK: What the video is and who it's from

    private func loadYouTubeInfo() {
        guard let session = youtubeSession, let videoID = youtubePanel?.videoID, session.video.id == videoID else { return }
        if let details = youtube.details[videoID] {
            showYouTubeInfo(details, for: videoID)
        }
        Task { @MainActor in
            // (Asked for again even if it's known: the counts move, and a video opened from a
            // list may have been looked up before it had a picture of its channel.)
            if let details = try? await YouTubeClient.shared.details(of: videoID) {
                self.rememberYouTubeDetails(details, for: videoID)
                self.showYouTubeInfo(details, for: videoID)
            } else if self.youtube.details[videoID] == nil {
                self.changeYouTubePanel(videoID, .info) {
                    $0.isLoading = false
                    $0.note = "Can't Reach YouTube"
                }
            }
        }
    }

    /// Fills the panel with a video's title and counts, who it's from, and its description a
    /// paragraph to a row, so that moving down the rows reads through it.
    private func showYouTubeInfo(_ details: YouTubeVideoDetails, for videoID: String) {
        guard let session = youtubeSession, session.video.id == videoID else { return }
        var rows: [YouTubePanelRow] = []
        let counts = [details.viewsText, details.dateText].compactMap { $0 }.filter { !$0.isEmpty }
        rows.append(YouTubePanelRow(
            id: "title", role: .text,
            body: details.title ?? session.video.title,
            footer: counts.joined(separator: ", "),
            isTitle: true,
        ))
        let channelID = details.channelID ?? session.video.channelID
        let channelName = details.channel ?? session.video.channel
        if let channelID, !channelName.isEmpty {
            rows.append(YouTubePanelRow(
                id: "channel", role: .channel(id: channelID, name: channelName),
                heading: channelName,
                aside: details.subscribersText ?? "",
                pictureURL: details.channelPictureURL,
                leadsOn: true,
            ))
        }
        // (The player was told the whole description; the page about the video has it with
        // its links cut short.)
        let description = session.playback.description.flatMap { $0.isEmpty ? nil : $0 } ?? details.description
        // (One row, however many paragraphs: it moves up under the arrows when it's longer
        // than the panel.)
        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            rows.append(YouTubePanelRow(id: "description", role: .text, body: description))
        }
        changeYouTubePanel(videoID, .info) { state in
            let focusedID = state.rows.indices.contains(state.focused) ? state.rows[state.focused].id : nil
            state.isLoading = false
            state.note = nil
            state.rows = rows
            state.focused = focusedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        }
        if let url = details.channelPictureURL { loadYouTubePanelPicture(url) }
    }

    /// A description as rows to move through: its paragraphs, a long one cut into pieces of a
    /// few lines at the ends of sentences or lines.

    /// Leaves the video for its channel's page: the channel's videos, in the menus.
    private func openYouTubeChannelFromPanel(id: String, name: String) {
        guard thirdMenuMode == .youtube, !isMovieTransitioning else {
            playLimitSoundOnceForCurrentHold()
            return
        }
        youtubePanel = nil
        youtubePanelReveal = 0
        spreadYouTubePanel(to: 0, nil)
        playSound(named: "Selection")
        stopMoviePlaybackAndReturnToMenu()
        Task { @MainActor in
            // (Once the movie has gone from over the menus.)
            for _ in 0 ..< 80 where self.isMoviePlaybackVisible || self.isMovieTransitioning {
                try? await firstRowSleep(0.05)
            }
            guard self.thirdMenuMode == .youtube, !self.isMoviePlaybackVisible, !self.isMenuFolderSwapTransitioning else { return }
            if case .list(.channel(id, _)) = self.currentYouTubePage?.page { return }
            self.pushYouTubePage(.list(.channel(id: id, name: name)))
        }
    }

    /// Fetches a round picture for the panel (a channel's), once.
    private func loadYouTubePanelPicture(_ url: URL) {
        guard youtube.panelPictures[url] == nil, !youtube.panelPicturesInFlight.contains(url) else { return }
        youtube.panelPicturesInFlight.insert(url)
        Task { @MainActor in
            let image = await self.loadYouTubeImage(url, maxPixelSize: 200)
            self.youtube.panelPicturesInFlight.remove(url)
            guard let image else { return }
            if self.youtube.panelPictures.count > 12 { self.youtube.panelPictures.removeAll() }
            self.youtube.panelPictures[url] = image
        }
    }
}
