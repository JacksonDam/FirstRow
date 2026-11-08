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

    /// Whether Now Playing has a list worth showing beside it.
    var canShowNowPlayingQueue: Bool {
        canPointAtNowPlaying && activeFullscreenScene?.key == musicNowPlayingFullscreenKey && nowPlayingQueueCount > 1
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

    func showNowPlayingQueue() {
        guard canShowNowPlayingQueue, !isNowPlayingQueueVisible else { return }
        // Opened on the song playing, with a couple of rows above it.
        let active = CGFloat(nowPlayingQueueActiveIndex ?? 0)
        nowPlayingQueueScroll = max(0, (active - 2) * Self.nowPlayingQueueRowPitch)
        nowPlayingQueueHoverIndex = nil
        playSound(named: "SelectionChange")
        withAnimation(.smooth(duration: 0.42)) {
            isNowPlayingLyricsVisible = false
            isNowPlayingQueueVisible = true
        }
        updateMusicNowPlayingFlipTimerState()
    }

    func hideNowPlayingQueue() {
        guard isNowPlayingQueueVisible else { return }
        withAnimation(.smoothInOut(duration: 0.34)) {
            isNowPlayingQueueVisible = false
            nowPlayingQueueHoverIndex = nil
        }
        updateMusicNowPlayingFlipTimerState()
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
            isNowPlayingLyricsVisible.toggle()
        }
        updateMusicNowPlayingFlipTimerState()
    }

    /// Now Playing went away: its extras go with it.
    func resetNowPlayingExtras() {
        isNowPlayingQueueVisible = false
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

    /// Starts the wait before the buttons slide away, if they should: only in touch mode, in
    /// Now Playing, while it plays. Paused, they stay.
    func scheduleNowPlayingTouchControlsHide() {
        nowPlayingTouchControlsHideTask?.cancel()
        nowPlayingTouchControlsHideTask = nil
        #if os(iOS)
            guard AppSettings.isTouchEnabled, activeFullscreenScene?.key == musicNowPlayingFullscreenKey else { return }
            guard isMusicPlaybackRunning() else {
                if areNowPlayingTouchControlsHidden {
                    withAnimation(.smooth(duration: 0.4)) { areNowPlayingTouchControlsHidden = false }
                }
                return
            }
            nowPlayingTouchControlsHideTask = Task { @MainActor [weak self] in
                try? await firstRowSleep(Self.nowPlayingTouchControlsHideDelay)
                guard let self, !Task.isCancelled else { return }
                guard self.activeFullscreenScene?.key == self.musicNowPlayingFullscreenKey, self.isMusicPlaybackRunning() else { return }
                self.hideNowPlayingTouchControls()
            }
        #endif
    }

    /// Keeps the extras in step with playback: called whenever it starts, stops or changes song.
    func noteNowPlayingPlaybackChanged() {
        guard activeFullscreenScene?.key == musicNowPlayingFullscreenKey else { return }
        refreshNowPlayingLyrics()
        #if os(iOS)
            if AppSettings.isTouchEnabled, nowPlayingTouchControlsHideTask == nil || !isMusicPlaybackRunning() {
                if areNowPlayingTouchControlsHidden, !isMusicPlaybackRunning() {
                    showNowPlayingTouchControls()
                } else if !areNowPlayingTouchControlsHidden {
                    scheduleNowPlayingTouchControlsHide()
                }
            }
        #endif
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

    /// The row under a window point with the list scrolled `scroll` canvas points.
    func row(at point: CGPoint, scroll: CGFloat, count: Int) -> Int? {
        guard viewport.contains(point) else { return nil }
        let y = point.y - listTop + scroll / canvasPerPoint
        guard y >= 0 else { return nil }
        let index = Int(y / rowPitch)
        return index < count ? index : nil
    }
}
