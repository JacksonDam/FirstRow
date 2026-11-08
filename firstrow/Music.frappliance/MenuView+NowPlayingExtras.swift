import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// Now Playing's extras for pointing and touching: the list it was started from, over its
/// right side; the lyrics, when the song has some; and touch mode's buttons, which slide away
/// while a song plays untouched.
extension MenuView {
    // MARK: - The list over the right side

    /// Mouse or touch mode is on: the arrows alone don't reach the list.
    var canPointAtNowPlaying: Bool {
        #if os(iOS)
            if AppSettings.isTouchEnabled { return true }
        #endif
        return AppSettings.isMouseEnabled
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

    /// Up and down while the list is out: the row picked out moves, the list scrolling to keep
    /// it in view.
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
            keepNowPlayingQueueRowInView(target)
        }
    }

    /// Scrolls the list just enough to show all of row `index`.
    private func keepNowPlayingQueueRowInView(_ index: Int) {
        guard let geometry = pointer.hitTester?.nowPlayingQueueGeometry else { return }
        let pitch = Self.nowPlayingQueueRowPitch
        let padding: CGFloat = 14
        let visible = geometry.viewport.height * geometry.canvasPerPoint
        let top = CGFloat(index) * pitch + padding
        var scroll = nowPlayingQueueScroll
        if top - pitch * 0.5 < scroll {
            scroll = top - pitch * 0.5
        } else if top + pitch * 1.5 > scroll + visible {
            scroll = top + pitch * 1.5 - visible
        }
        nowPlayingQueueScroll = max(0, min(geometry.scrollLimit, scroll))
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

    /// Where the list was opened on: a couple of rows above the song playing.
    func scrollNowPlayingQueueToActiveSong() {
        let active = CGFloat(nowPlayingQueueActiveIndex ?? 0)
        nowPlayingQueueScroll = max(0, (active - 2) * Self.nowPlayingQueueRowPitch)
    }

    /// Slides the list all the way out or back, from wherever it is (no fade: it's one sheet
    /// that slides, and the rest moves aside with it).
    func settleNowPlayingQueue(open: Bool) {
        let duration = 0.24 + 0.22 * Double(open ? 1 - nowPlayingQueueReveal : nowPlayingQueueReveal)
        withAnimation(.smooth(duration: duration)) {
            if open { isNowPlayingLyricsVisible = false }
            isNowPlayingQueueVisible = open
            nowPlayingQueueReveal = open ? 1 : 0
            if !open { nowPlayingQueueHoverIndex = nil }
        }
        updateMusicNowPlayingFlipTimerState()
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
        if point.x < geometry.panel.minX - 70 {
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
            if isNowPlayingLyricsVisible { isNowPlayingLyricsVisible = false }
            return
        }
        guard id != nowPlayingLyricsSongID else { return }
        nowPlayingLyricsSongID = id
        nowPlayingLyrics = nil
        guard let song = resolvedActiveMusicPlaybackQueue().first(where: { $0.id == id }) else {
            if isNowPlayingLyricsVisible { isNowPlayingLyricsVisible = false }
            return
        }
        Task { @MainActor in
            let lyrics = await self.loadMusicLyrics(for: song)
            guard self.nowPlayingLyricsSongID == id else { return }
            withAnimation(.smooth(duration: 0.3)) {
                self.nowPlayingLyrics = lyrics
                if lyrics == nil, self.isNowPlayingLyricsVisible { self.isNowPlayingLyricsVisible = false }
            }
        }
    }

    func toggleNowPlayingLyrics() {
        guard hasNowPlayingLyrics || isNowPlayingLyricsVisible else { return }
        playSound(named: isNowPlayingLyricsVisible ? "Exit" : "Selection")
        withAnimation(isNowPlayingLyricsVisible ? .smoothInOut(duration: 0.34) : .smooth(duration: 0.42)) {
            isNowPlayingQueueVisible = false
            nowPlayingQueueReveal = 0
            isNowPlayingLyricsVisible.toggle()
        }
        updateMusicNowPlayingFlipTimerState()
    }

    /// Now Playing went away: its extras go with it.
    func resetNowPlayingExtras() {
        nowPlayingSession += 1
        isNowPlayingQueueVisible = false
        nowPlayingQueueReveal = 0
        nowPlayingQueueHoverIndex = nil
        isNowPlayingLyricsVisible = false
        nowPlayingTouchControlsHideTask?.cancel()
        nowPlayingTouchControlsHideTask = nil
        areNowPlayingTouchControlsHidden = false
    }

    // MARK: - Touch mode's buttons

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
        guard !areNowPlayingTouchControlsHidden else { return }
        withAnimation(.smoothInOut(duration: 0.5)) {
            areNowPlayingTouchControlsHidden = true
        }
    }

    /// Starts the wait before the buttons slide away, if they should: only with on-screen
    /// buttons (touch or mouse mode), in Now Playing, while it plays. Paused, they stay.
    func scheduleNowPlayingTouchControlsHide() {
        nowPlayingTouchControlsHideTask?.cancel()
        nowPlayingTouchControlsHideTask = nil
        guard showsOnScreenControls, activeFullscreenScene?.key == musicNowPlayingFullscreenKey else { return }
        guard isMusicPlaybackRunning() else {
            if areNowPlayingTouchControlsHidden {
                withAnimation(.smooth(duration: 0.4)) { areNowPlayingTouchControlsHidden = false }
            }
            return
        }
        nowPlayingTouchControlsHideTask = Task { @MainActor [weak self] in
            try? await firstRowSleep(Self.nowPlayingTouchControlsHideDelay)
            guard let self, !Task.isCancelled else { return }
            self.nowPlayingTouchControlsHideTask = nil
            guard self.activeFullscreenScene?.key == self.musicNowPlayingFullscreenKey, self.isMusicPlaybackRunning() else { return }
            self.hideNowPlayingTouchControls()
        }
    }

    /// Keeps the extras in step with playback: called whenever it starts, stops or changes song.
    func noteNowPlayingPlaybackChanged() {
        guard activeFullscreenScene?.key == musicNowPlayingFullscreenKey else { return }
        refreshNowPlayingLyrics()
        if showsOnScreenControls, nowPlayingTouchControlsHideTask == nil || !isMusicPlaybackRunning() {
            if areNowPlayingTouchControlsHidden, !isMusicPlaybackRunning() {
                showNowPlayingTouchControls()
            } else if !areNowPlayingTouchControlsHidden {
                scheduleNowPlayingTouchControlsHide()
            }
        }
    }
}

/// Where Now Playing's list sits, in window points, for the pointer and fingers.
struct NowPlayingQueueGeometry {
    /// The panel when it's out.
    let panel: CGRect
    /// The strip along the right edge that brings it out.
    let edgeZone: CGRect
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
        let y = point.y - listTop + scroll / canvasPerPoint
        guard y >= 0 else { return nil }
        let index = Int(y / rowPitch)
        return index < count ? index : nil
    }
}
