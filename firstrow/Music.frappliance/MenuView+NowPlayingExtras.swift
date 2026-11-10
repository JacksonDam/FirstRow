import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// Now Playing's extras for pointing and touching: the list it was started from, over its
/// right side; the lyrics, when the song has some; and the on-screen buttons, which slide away
/// while a song plays untouched.
extension MenuView {
    // MARK: - The list over the right side

    /// There's a pointer or fingers to reach the list with (everywhere but Apple TV, where the
    /// arrows alone don't reach it).
    var canPointAtNowPlaying: Bool {
        #if os(tvOS)
            false
        #else
            true
        #endif
    }

    var isMusicNowPlayingShowing: Bool {
        activeFullscreenScene?.key == musicNowPlayingFullscreenKey && !isFullscreenSceneTransitioning
    }

    /// A Siri Remote is held, whose TV button brings the list out.
    var hasSiriRemoteForNowPlaying: Bool {
        #if os(macOS)
            SiriRemoteInput.shared.hasRemote
        #else
            false
        #endif
    }

    /// Whether Now Playing has a list worth showing beside it.
    var canShowNowPlayingQueue: Bool {
        (canPointAtNowPlaying || hasSiriRemoteForNowPlaying || isNowPlayingQueueVisible) &&
            activeFullscreenScene?.key == musicNowPlayingFullscreenKey && nowPlayingQueueCount > 1
    }

    var nowPlayingQueueCount: Int {
        if isPodcastAudioNowPlaying { return activePodcastPlaybackEpisodes().count }
        if thirdMenuMode == .musicITunesTopSongs || musicNowPlayingArtist == "iTunes Top Songs" { return 0 }
        return resolvedActiveMusicPlaybackQueue().count
    }

    /// A row of that list: the song and who it's by.
    func nowPlayingQueueRow(_ index: Int) -> (title: String, detail: String)? {
        if isPodcastAudioNowPlaying {
            let episodes = activePodcastPlaybackEpisodes()
            guard episodes.indices.contains(index) else { return nil }
            return (episodes[index].title, episodes[index].seriesTitle)
        }
        let queue = resolvedActiveMusicPlaybackQueue()
        guard queue.indices.contains(index) else { return nil }
        return (queue[index].title, queue[index].artist)
    }

    /// The song playing, in that list.
    var nowPlayingQueueActiveIndex: Int? {
        if isPodcastAudioNowPlaying {
            guard let id = activePodcastPlaybackEpisodeID else { return nil }
            return activePodcastPlaybackEpisodes().firstIndex { $0.id == id }
        }
        guard let id = activeMusicPlaybackSongID else { return nil }
        return resolvedActiveMusicPlaybackQueue().firstIndex { $0.id == id }
    }

    /// What the list is called: the menu it came from.
    var nowPlayingQueueTitle: String {
        if isInThirdMenu, !headerText.isEmpty { return headerText }
        return isPodcastAudioNowPlaying ? "Episodes" : "Songs"
    }

    /// Rows are this far apart in the list, in full-screen canvas points.
    static let nowPlayingQueueRowPitch: CGFloat = 78

    /// Brings the list out. Opened from a key or remote, the song playing is picked out in it,
    /// for the arrows to move from.
    func showNowPlayingQueue(focusingActiveSong: Bool = false) {
        guard canShowNowPlayingQueue, !isNowPlayingQueueVisible else { return }
        // Opened on the song playing, with a couple of rows above it.
        if nowPlayingQueueReveal == 0 { scrollNowPlayingQueueToActiveSong() }
        nowPlayingQueueHoverIndex = focusingActiveSong ? (nowPlayingQueueActiveIndex ?? 0) : nil
        playSound(named: "SelectionChange")
        settleNowPlayingQueue(open: true)
    }

    /// The Siri Remote's TV button: brings Now Playing's list out, or puts it away.
    func handleRemoteTVButton() {
        noteInputSource(.siriRemote)
        guard activeFullscreenScene?.key == musicNowPlayingFullscreenKey, !isFullscreenSceneTransitioning else { return }
        registerUserInteractionForScreenSaver()
        if isNowPlayingQueueVisible {
            hideNowPlayingQueue()
            playSound(named: "Exit")
        } else {
            if isNowPlayingLyricsVisible { toggleNowPlayingLyrics() }
            showNowPlayingQueue(focusingActiveSong: true)
        }
    }

    /// Up and down while the list is out: the row picked out moves, and as in the menus it stays
    /// on the fourth row while the list scrolls under it.
    func moveNowPlayingQueueFocus(by step: Int) {
        let count = nowPlayingQueueCount
        guard count > 0 else { return }
        let current = nowPlayingQueueHoverIndex ?? nowPlayingQueueActiveIndex ?? 0
        let target = nowPlayingQueueHoverIndex == nil ? current : max(0, min(count - 1, current + step))
        guard target != nowPlayingQueueHoverIndex else {
            playLimitSoundOnceForCurrentHold()
            return
        }
        playSound(named: "SelectionChange")
        withAnimation(.smooth(duration: 0.22)) {
            nowPlayingQueueHoverIndex = target
            scrollNowPlayingQueue(holdingRowOnFourth: target)
        }
    }

    /// Scrolls the list so row `index` sits where the menus keep their selection (the fourth
    /// row), as far as the list's ends allow.
    private func scrollNowPlayingQueue(holdingRowOnFourth index: Int) {
        nowPlayingQueueScroll = max(0, min(nowPlayingQueueScrollLimit, CGFloat(index - stickySelectionRowIndex) * Self.nowPlayingQueueRowPitch))
    }

    /// How far the list scrolls, for its length now (the last list's may have been different).
    private var nowPlayingQueueScrollLimit: CGFloat {
        guard let geometry = pointer.hitTester?.nowPlayingQueueGeometry else { return .greatestFiniteMagnitude }
        return max(0, CGFloat(nowPlayingQueueCount) * Self.nowPlayingQueueRowPitch + 14 * 2 - geometry.viewport.height * geometry.canvasPerPoint)
    }

    /// Select while the list is out: plays the row picked out.
    func chooseFocusedNowPlayingQueueRow() {
        if let index = nowPlayingQueueHoverIndex {
            chooseNowPlayingQueueRow(index)
        } else {
            hideNowPlayingQueue()
        }
    }

    func hideNowPlayingQueue() {
        guard isNowPlayingQueueVisible || nowPlayingQueueReveal > 0 else { return }
        settleNowPlayingQueue(open: false)
    }

    /// Where the list was opened on: the song playing on the fourth row, where the arrows'
    /// selection stays.
    func scrollNowPlayingQueueToActiveSong() {
        scrollNowPlayingQueue(holdingRowOnFourth: nowPlayingQueueActiveIndex ?? 0)
    }

    /// Slides the list all the way out or back, from wherever it is (no fade: it's one sheet
    /// that slides, and the rest moves aside with it).
    func settleNowPlayingQueue(open: Bool) {
        let duration = 0.24 + 0.22 * Double(open ? 1 - nowPlayingQueueReveal : nowPlayingQueueReveal)
        let wordsAreOut = isNowPlayingLyricsVisible || nowPlayingWordsGlide != nil
        holdNowPlayingGlide()
        if glidesNowPlayingExtras, !wordsAreOut {
            // Standing upright, a frame at a time: the rest gets out of its way in two moves.
            isNowPlayingQueueVisible = open
            if !open { nowPlayingQueueHoverIndex = nil }
            updateMusicNowPlayingFlipTimerState()
            startNowPlayingGlide(.list, from: nowPlayingQueueReveal, to: open ? 1 : 0, duration: duration + 0.08)
            return
        }
        // (Taking over from the words, upright, the rest stays tucked up as it is.)
        withAnimation(.smooth(duration: duration)) {
            if open {
                isNowPlayingLyricsVisible = false
                nowPlayingWordsGlide = nil
            }
            isNowPlayingQueueVisible = open
            nowPlayingQueueReveal = open ? 1 : 0
            if !open { nowPlayingQueueHoverIndex = nil }
        }
        updateMusicNowPlayingFlipTimerState()
    }

    // MARK: - A frame at a time

    /// Whether the list and the words come and go a frame at a time as things stand.
    private var glidesNowPlayingExtras: Bool {
        upright != nil && activeFullscreenScene?.key == musicNowPlayingFullscreenKey
    }

    private func startNowPlayingGlide(_ subject: NowPlayingGlide.Subject, from: CGFloat, to: CGFloat, duration: Double) {
        nowPlayingGlide = NowPlayingGlide(subject: subject, from: from, to: to, duration: max(0.05, duration))
        if subject == .words { nowPlayingWordsGlide = from }
        let clock = nowPlayingGlideClock
        if clock.onFrame == nil {
            clock.onFrame = { [weak self] seconds in
                self?.stepNowPlayingGlide(seconds) ?? false
            }
        }
        clock.run()
    }

    /// One frame of the move under way. Returns whether there is more of it to come.
    private func stepNowPlayingGlide(_ seconds: Double) -> Bool {
        guard var glide = nowPlayingGlide else { return false }
        glide.elapsed += seconds
        let fraction = min(1, glide.elapsed / glide.duration)
        guard fraction < 1, glidesNowPlayingExtras else {
            landNowPlayingGlide()
            return false
        }
        nowPlayingGlide = glide
        let value = glide.from + (glide.to - glide.from) * CGFloat(glide.subject.curve.value(at: fraction))
        switch glide.subject {
        case .list: nowPlayingQueueReveal = value
        case .words: nowPlayingWordsGlide = value
        }
        return true
    }

    /// Puts what's on its way where it was going, at once.
    func landNowPlayingGlide() {
        guard let glide = nowPlayingGlide else { return }
        nowPlayingGlide = nil
        nowPlayingGlideClock.stop()
        switch glide.subject {
        case .list: nowPlayingQueueReveal = glide.to
        case .words: nowPlayingWordsGlide = nil
        }
        updateMusicNowPlayingFlipTimerState()
    }

    /// Stops what's on its way where it has got to, for something else to take it from there
    /// (a finger on the list, say). The words, with nowhere to rest part way, go where they were
    /// going.
    func holdNowPlayingGlide() {
        guard let glide = nowPlayingGlide else { return }
        guard glide.subject == .list else {
            landNowPlayingGlide()
            return
        }
        nowPlayingGlide = nil
        nowPlayingGlideClock.stop()
    }

    /// A finger pulling the list part way: 0 away to 1 out, unanimated.
    func pullNowPlayingQueue(to reveal: CGFloat) {
        let clamped = max(0, min(1, reveal))
        guard abs(clamped - nowPlayingQueueReveal) > 0.0005 else { return }
        if nowPlayingQueueReveal == 0, clamped > 0, !isNowPlayingQueueVisible {
            // Coming out from away: on the song playing.
            scrollNowPlayingQueueToActiveSong()
            nowPlayingQueueHoverIndex = nil
        }
        nowPlayingQueueReveal = clamped
    }

    /// Plays a song chosen from the list, and puts the list away.
    func chooseNowPlayingQueueRow(_ index: Int) {
        guard index >= 0, index < nowPlayingQueueCount else { return }
        if index != nowPlayingQueueActiveIndex {
            playSound(named: "Selection")
            switchMusicNowPlayingTrack(direction: 0, toIndex: index)
        }
        hideNowPlayingQueue()
    }

    /// Scrolls the list to `scroll` canvas points from its top, held within its length.
    func setNowPlayingQueueScroll(_ scroll: CGFloat, limit: CGFloat, animation: Animation? = nil) {
        let clamped = max(0, min(limit, scroll))
        guard abs(clamped - nowPlayingQueueScroll) > 0.01 else { return }
        if let animation {
            withAnimation(animation) { nowPlayingQueueScroll = clamped }
        } else {
            nowPlayingQueueScroll = clamped
        }
    }

    /// The pointer moved over Now Playing: up against the right edge brings the list out, away
    /// from it puts it back, and over it picks out a row.
    func pointerMovedOverNowPlaying(_ point: CGPoint) {
        // The buttons come back while the pointer moves, and go again when it rests.
        if areNowPlayingTouchControlsHidden {
            showNowPlayingTouchControls()
        } else if nowPlayingTouchControlsHideTask != nil {
            scheduleNowPlayingTouchControlsHide()
        }
        guard let geometry = pointer.hitTester?.nowPlayingQueueGeometry else { return }
        if !isNowPlayingQueueVisible {
            if geometry.edgeZone.contains(point) { showNowPlayingQueue() }
            return
        }
        // (Standing upright the list is under the fold: away is above it.)
        if point.x < geometry.panel.minX - 70 || (upright != nil && point.y < geometry.panel.minY - 70) {
            hideNowPlayingQueue()
            return
        }
        let row = geometry.row(at: point, scroll: nowPlayingQueueScroll, count: nowPlayingQueueCount)
        if row != nowPlayingQueueHoverIndex {
            nowPlayingQueueHoverIndex = row
            if row != nil { playSound(named: "SelectionChange") }
        }
    }

    // MARK: - Lyrics

    /// The current song's lyrics, once looked up.
    var hasNowPlayingLyrics: Bool {
        guard let lyrics = nowPlayingLyrics else { return false }
        return nowPlayingLyricsSongID == activeMusicPlaybackSongID && !lyrics.lines.isEmpty
    }

    /// Looks the current song's lyrics up, once per song.
    func refreshNowPlayingLyrics() {
        guard let id = activeMusicPlaybackSongID, !isPodcastAudioNowPlaying else {
            nowPlayingLyrics = nil
            nowPlayingLyricsSongID = nil
            dropNowPlayingLyrics()
            return
        }
        guard id != nowPlayingLyricsSongID else { return }
        nowPlayingLyricsSongID = id
        nowPlayingLyrics = nil
        guard let song = resolvedActiveMusicPlaybackQueue().first(where: { $0.id == id }) else {
            dropNowPlayingLyrics()
            return
        }
        Task { @MainActor in
            let lyrics = await self.loadMusicLyrics(for: song)
            guard self.nowPlayingLyricsSongID == id else { return }
            withAnimation(.smooth(duration: 0.3)) {
                self.nowPlayingLyrics = lyrics
                if lyrics == nil { self.dropNowPlayingLyrics() }
            }
        }
    }

    /// The words go because the song playing now has none.
    private func dropNowPlayingLyrics() {
        guard isNowPlayingLyricsVisible else { return }
        isNowPlayingLyricsVisible = false
        // (Standing upright the song's details come back down a frame at a time.)
        if glidesNowPlayingExtras, !isNowPlayingQueueVisible, nowPlayingQueueReveal <= 0 {
            startNowPlayingGlide(.words, from: nowPlayingWordsGlide ?? 1, to: 0, duration: 0.44)
        }
    }

    func toggleNowPlayingLyrics() {
        guard hasNowPlayingLyrics || isNowPlayingLyricsVisible else { return }
        playSound(named: isNowPlayingLyricsVisible ? "Exit" : "Selection")
        if nowPlayingGlide?.subject == .list { landNowPlayingGlide() }
        if glidesNowPlayingExtras, !isNowPlayingQueueVisible, nowPlayingQueueReveal <= 0 {
            // Standing upright, a frame at a time: the song's details leave the part under the
            // fold before the words come in there, and come back once they've gone.
            let showing = !isNowPlayingLyricsVisible
            let from = nowPlayingWordsGlide ?? (showing ? 0 : 1)
            let target: CGFloat = showing ? 1 : 0
            isNowPlayingLyricsVisible = showing
            startNowPlayingGlide(.words, from: from, to: target, duration: (showing ? 0.56 : 0.48) * Double(abs(target - from)))
            updateMusicNowPlayingFlipTimerState()
            return
        }
        holdNowPlayingGlide()
        withAnimation(isNowPlayingLyricsVisible ? .smoothInOut(duration: 0.34) : .smooth(duration: 0.42)) {
            isNowPlayingQueueVisible = false
            nowPlayingQueueReveal = 0
            nowPlayingWordsGlide = nil
            isNowPlayingLyricsVisible.toggle()
        }
        updateMusicNowPlayingFlipTimerState()
    }

    /// Now Playing went away: its extras go with it.
    func resetNowPlayingExtras() {
        nowPlayingSession += 1
        nowPlayingGlide = nil
        nowPlayingGlideClock.stop()
        nowPlayingWordsGlide = nil
        isNowPlayingQueueVisible = false
        nowPlayingQueueReveal = 0
        nowPlayingQueueHoverIndex = nil
        isNowPlayingLyricsVisible = false
        nowPlayingTouchControlsHideTask?.cancel()
        nowPlayingTouchControlsHideTask = nil
        areNowPlayingTouchControlsHidden = false
    }

    // MARK: - The on-screen buttons

    private static let nowPlayingTouchControlsHideDelay: TimeInterval = 4

    /// Brings the buttons back and, while a song plays, puts them away again after a while.
    func showNowPlayingTouchControls() {
        if areNowPlayingTouchControlsHidden {
            withAnimation(.smooth(duration: 0.4)) {
                areNowPlayingTouchControlsHidden = false
            }
        }
        scheduleNowPlayingTouchControlsHide()
    }

    func hideNowPlayingTouchControls() {
        nowPlayingTouchControlsHideTask?.cancel()
        nowPlayingTouchControlsHideTask = nil
        guard !areNowPlayingTouchControlsHidden, upright == nil else { return }
        withAnimation(.smoothInOut(duration: 0.5)) {
            areNowPlayingTouchControlsHidden = true
        }
    }

    /// The screen stood up or lay back down with Now Playing on it. Upright the buttons have
    /// their own part of the screen, under the fold, and stay; lying down they go away again
    /// after a while.
    func nowPlayingStanceDidChange() {
        landNowPlayingGlide()
        guard activeFullscreenScene?.key == musicNowPlayingFullscreenKey else { return }
        // (A plain change, drawn with the layout that follows the change of stance, so that
        // everything moves to its new place together.)
        if upright != nil, areNowPlayingTouchControlsHidden { areNowPlayingTouchControlsHidden = false }
        scheduleNowPlayingTouchControlsHide()
        // Turning round every so often goes by how it stands, too.
        updateMusicNowPlayingFlipTimerState()
    }

    /// Starts the wait before the buttons slide away, if they should: only with on-screen
    /// buttons, in Now Playing, while it plays. Paused, standing upright, or with the list
    /// out beside it, they stay.
    func scheduleNowPlayingTouchControlsHide() {
        nowPlayingTouchControlsHideTask?.cancel()
        nowPlayingTouchControlsHideTask = nil
        guard showsOnScreenControls, activeFullscreenScene?.key == musicNowPlayingFullscreenKey else { return }
        guard nowPlayingQueueReveal <= 0 else { return }
        guard isMusicPlaybackRunningOrStarting(), upright == nil else {
            if areNowPlayingTouchControlsHidden {
                withAnimation(.smooth(duration: 0.4)) { areNowPlayingTouchControlsHidden = false }
            }
            return
        }
        nowPlayingTouchControlsHideTask = Task { @MainActor [weak self] in
            try? await firstRowSleep(Self.nowPlayingTouchControlsHideDelay)
            guard let self, !Task.isCancelled else { return }
            self.nowPlayingTouchControlsHideTask = nil
            guard self.activeFullscreenScene?.key == self.musicNowPlayingFullscreenKey, self.isMusicPlaybackRunningOrStarting(),
                  self.nowPlayingQueueReveal <= 0 else { return }
            self.hideNowPlayingTouchControls()
        }
    }

    /// Keeps the extras in step with playback: called whenever it starts, stops or changes song.
    func noteNowPlayingPlaybackChanged() {
        guard activeFullscreenScene?.key == musicNowPlayingFullscreenKey else { return }
        refreshNowPlayingLyrics()
        // (A song just started is as good as playing: the buttons don't come back for the
        // moment it takes to get going, between songs say.)
        let playing = isMusicPlaybackRunningOrStarting()
        if showsOnScreenControls, nowPlayingTouchControlsHideTask == nil || !playing {
            if areNowPlayingTouchControlsHidden, !playing {
                showNowPlayingTouchControls()
            } else if !areNowPlayingTouchControlsHidden {
                scheduleNowPlayingTouchControlsHide()
            }
        }
    }
}

/// Where Now Playing's list sits, in window points, for the pointer and fingers.
/// The list or the words on their way out or back a frame at a time. Standing upright the
/// song's details get out of their way in two moves (off one edge under the fold, in from
/// another above it: see `NowPlayingSideLayout.detailsPlace`), which a single animation from
/// here to there can't follow; so there they're moved as a finger moves the list.
struct NowPlayingGlide {
    enum Subject: Equatable {
        case list
        case words

        /// The list keeps the speed it was let go at and settles; the words leave and arrive.
        var curve: TimingCurve {
            switch self {
            case .list: TimingCurve(c1: CGPoint(x: 0.25, y: 0.46), c2: CGPoint(x: 0.45, y: 0.94))
            case .words: TimingCurve(c1: CGPoint(x: 0.455, y: 0.03), c2: CGPoint(x: 0.515, y: 0.955))
            }
        }
    }

    let subject: Subject
    let from: CGFloat
    let to: CGFloat
    let duration: Double
    var elapsed: Double = 0
}

struct NowPlayingQueueGeometry {
    /// The panel when it's out.
    let panel: CGRect
    /// The strip along the right edge that brings it out.
    let edgeZone: CGRect
    /// Where a sideways drag moves it once it's out: anywhere or, standing upright, under the fold.
    let dragZone: CGRect
    /// Where the rows show.
    let viewport: CGRect
    /// The first row's top, unscrolled.
    let listTop: CGFloat
    let rowPitch: CGFloat
    /// Canvas points per window point.
    let canvasPerPoint: CGFloat
    /// How far it can scroll, in canvas points.
    let scrollLimit: CGFloat
    /// How far its left edge moves between out and away, in window points.
    let travel: CGFloat

    /// The row under a window point with the list scrolled `scroll` canvas points.
    func row(at point: CGPoint, scroll: CGFloat, count: Int) -> Int? {
        guard viewport.contains(point) else { return nil }
        // Held within the list's length, as it's drawn.
        let y = point.y - listTop + max(0, min(scrollLimit, scroll)) / canvasPerPoint
        guard y >= 0 else { return nil }
        let index = Int(y / rowPitch)
        return index < count ? index : nil
    }
}
