import AVFoundation
import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// What the pointer is doing between events.
@MainActor
final class PointerInputState {
    enum Drag {
        case movie(wasPlaying: Bool)
        case music(wasPlaying: Bool)
    }

    weak var hitTester: (any PointerHitTesting)?
    /// A list scrolled by the pointer stays put until the arrows take over again.
    fileprivate(set) var pin: (identity: String, offset: CGFloat)?
    fileprivate(set) var location: CGPoint?
    fileprivate var pressTarget: PointerTarget?
    fileprivate var drag: Drag?
    fileprivate var screenSaverWakeOrigin: CGPoint?
    fileprivate var wheelAccumulator: CGFloat = 0
    fileprivate var lastWheelDate = Date.distantPast
    fileprivate var cursorHideTask: Task<Void, Never>?

    /// The pinned scroll for the list with `identity`, nudged to show all of the selected row.
    func pinnedScrollOffset(
        identity: String,
        selectedRowTop: CGFloat,
        selectedRowHeight: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat,
    ) -> CGFloat? {
        guard let pin, pin.identity == identity else { return nil }
        let minOffset = min(0, viewportHeight - contentHeight)
        var offset = max(minOffset, min(0, pin.offset))
        // Scrolled just enough to show the whole selected row, if it's cut off at an edge.
        let top = selectedRowTop + offset
        if top < 0 {
            offset -= top
        } else if top + selectedRowHeight > viewportHeight {
            offset -= top + selectedRowHeight - viewportHeight
        }
        // Left in the pin as it was: this runs mid-change too, before a new selection lands.
        return max(minOffset, min(0, offset))
    }

    /// The pinned scroll for the list with `identity`, before the arrows move its selection.
    func pinnedScrollOffset(identity: String) -> CGFloat? {
        guard let pin, pin.identity == identity else { return nil }
        return pin.offset
    }

    /// An arrow moved the selection in a pinned list. The pin holds while the selection walks
    /// towards the row the list normally keeps it on, and lets go once it gets there, so the
    /// usual scrolling takes over without a jump. Returns the scroll the list ends up at.
    func handOver(identity: String, stickyOffset: CGFloat, direction: Int) -> CGFloat? {
        guard let pin, pin.identity == identity else { return nil }
        let reached = direction > 0 ? stickyOffset <= pin.offset + 0.5 : stickyOffset >= pin.offset - 0.5
        if reached {
            self.pin = nil
            return nil
        }
        return pin.offset
    }

    func clearPin() {
        pin = nil
    }
}

/// Showing and hiding the pointer itself.
@MainActor
enum PointerCursor {
    static func hideUntilMoved() {
        #if os(macOS)
            NSCursor.setHiddenUntilMouseMoves(true)
        #elseif FIRSTROW_PORTABLE
            PortableApplication.hideCursorIfFullscreen()
        #endif
    }
}

/// Mouse and trackpad input, when Settings > Mouse is on: hovering moves the selection,
/// clicking chooses, the right button goes back, the wheel scrolls, and the progress bars seek.
extension MenuView {
    private static let pointerCursorHideDelay: TimeInterval = 3
    private static let pointerSelectionDuration: Double = 0.22
    private static let pointerScrollDuration: Double = 0.2

    /// The list the pointer can work in now, or nil while menus are moving.
    var pointerActiveListLevel: MenuListLevel? {
        guard !isEnteringSubmenu, !isReturningToRoot else { return nil }
        if isInThirdMenu { return .third }
        if isInSubmenu { return .submenu }
        return .root
    }

    func handlePointerEvent(_ event: PointerEvent) {
        guard AppSettings.isMouseEnabled, !isChoosingMediaSource else { return }
        switch event {
        case let .moved(point):
            pointerMoved(to: point)
        case let .pressed(button, point):
            pointerPressed(button, at: point)
        case let .released(button, point):
            pointerReleased(button, at: point)
        case let .scrolled(dx, dy, precise, point):
            pointerScrolled(dx: dx, dy: dy, precise: precise, at: point)
        }
    }

    /// Keys put the arrows back in charge of the lists.
    func notePointerAwareKey(_ key: KeyCode) {
        if key == .enter || key == .escape || key == .delete {
            pointer.clearPin()
        }
    }

    // MARK: - Events

    private func pointerMoved(to point: CGPoint) {
        pointer.location = point
        scheduleCursorHide()
        if activeFullscreenScene?.key == screenSaverFullscreenKey {
            // A nudge of the desk shouldn't end it, a real move should.
            let origin = pointer.screenSaverWakeOrigin ?? point
            pointer.screenSaverWakeOrigin = origin
            if hypot(point.x - origin.x, point.y - origin.y) > 6, !isFullscreenSceneTransitioning {
                pointer.screenSaverWakeOrigin = nil
                dismissScreenSaverForUserInteraction()
            }
            return
        }
        pointer.screenSaverWakeOrigin = nil
        registerUserInteractionForScreenSaver()
        if pointer.drag != nil {
            continueProgressDrag(at: point)
            return
        }
        guard !isPointerInputPaused else { return }
        if isMoviePlaybackVisible {
            guard !isMovieTransitioning, moviePlayer != nil else { return }
            showMovieControlsInstantly()
            scheduleMovieControlsAutoHide()
            return
        }
        guard activeFullscreenScene == nil, let target = pointer.hitTester?.pointerTarget(at: point) else { return }
        switch target {
        case let .resumeOption(index):
            selectResumeOptionFromPointer(index)
        case let .menuRow(level, index):
            selectRowFromPointer(level: level, index: index)
        default:
            break
        }
    }

    private func pointerPressed(_ button: PointerButton, at point: CGPoint) {
        pointer.location = point
        scheduleCursorHide()
        registerUserInteractionForScreenSaver()
        if activeFullscreenScene?.key == screenSaverFullscreenKey {
            if !isFullscreenSceneTransitioning { dismissScreenSaverForUserInteraction() }
            return
        }
        guard !isPointerInputPaused else { return }
        guard button == .primary else {
            pointer.clearPin()
            pointer.pressTarget = nil
            handleKeyDown(.escape)
            return
        }
        let target = pointer.hitTester?.pointerTarget(at: point)
        pointer.pressTarget = target
        // The bars react on the press, so a drag can start from it.
        if case let .progressBar(fraction) = target {
            if isMoviePlaybackVisible {
                beginMovieProgressDrag(at: fraction)
            } else if activeFullscreenScene?.key == musicNowPlayingFullscreenKey {
                beginMusicProgressDrag(at: fraction)
            }
            pointer.pressTarget = nil
        }
    }

    private func pointerReleased(_ button: PointerButton, at point: CGPoint) {
        pointer.location = point
        guard button == .primary else { return }
        if pointer.drag != nil {
            finishProgressDrag(at: point)
            return
        }
        guard let pressed = pointer.pressTarget else { return }
        pointer.pressTarget = nil
        guard !isPointerInputPaused else { return }
        let target = pointer.hitTester?.pointerTarget(at: point)
        // A click is a press and release over the same thing.
        guard target == pressed else { return }
        performPointerClick(on: pressed)
    }

    private func performPointerClick(on target: PointerTarget) {
        if isMoviePlaybackVisible || activeFullscreenScene != nil {
            // Playback screens: a click plays or pauses, as the space bar does.
            let key = activeFullscreenScene?.key
            if isMoviePlaybackVisible || key == musicNowPlayingFullscreenKey || key == photoSlideshowFullscreenKey {
                handleKeyDown(.space)
            }
            return
        }
        switch target {
        case let .resumeOption(index):
            guard isMovieResumePromptVisible else { return }
            if index != movieResumePromptSelectedIndex {
                movieResumePromptSelectedIndex = index
            }
            handleKeyDown(.enter)
        case let .menuRow(level, index):
            guard level == pointerActiveListLevel else { return }
            if index != pointerSelectionIndex(for: level) {
                selectRowFromPointer(level: level, index: index)
            }
            pointer.clearPin()
            handleKeyDown(.enter)
        case let .carouselItem(index):
            guard pointerActiveListLevel == .root else { return }
            if index == selectedIndex {
                handleKeyDown(.enter)
            } else {
                selectRowFromPointer(level: .root, index: index)
            }
        case let .sortSegment(mode):
            handleTVShowsSortInput(direction: mode == .date ? -1 : 1)
        case .progressBar, .background:
            break
        }
    }

    private func pointerScrolled(dx: CGFloat, dy: CGFloat, precise: Bool, at point: CGPoint) {
        pointer.location = point
        scheduleCursorHide()
        registerUserInteractionForScreenSaver()
        if activeFullscreenScene?.key == screenSaverFullscreenKey {
            if !isFullscreenSceneTransitioning { dismissScreenSaverForUserInteraction() }
            return
        }
        guard pointer.drag == nil, !isPointerInputPaused else { return }
        // Movies go forward for down or right; lists move towards the top for up.
        let amount = isMoviePlaybackVisible ? -dy + dx : dy
        let now = Date()
        // Each gesture starts its count afresh, and so does a change of direction.
        if now.timeIntervalSince(pointer.lastWheelDate) > 0.35 || (pointer.wheelAccumulator != 0 && amount != 0 && (pointer.wheelAccumulator > 0) != (amount > 0)) {
            pointer.wheelAccumulator = 0
        }
        pointer.lastWheelDate = now
        if isMoviePlaybackVisible {
            // Ten seconds a notch.
            pointer.wheelAccumulator += precise ? amount / 40 : amount
            let steps = wholeSteps(&pointer.wheelAccumulator)
            if steps != 0 { skipMovie(bySeconds: Double(steps) * 10) }
            return
        }
        guard activeFullscreenScene == nil, !isMovieResumePromptVisible, let level = pointerActiveListLevel,
              let state = pointer.hitTester?.menuListScrollState(level)
        else { return }
        let unit = precise ? max(12, state.rowPitchInWindow * 0.75) : 1
        pointer.wheelAccumulator += amount / unit
        let steps = wholeSteps(&pointer.wheelAccumulator)
        guard steps != 0 else { return }
        if state.canScroll {
            scrollMenuList(level: level, state: state, rows: steps, pointerAt: point)
        } else {
            // Nothing to scroll: step the selection instead, as the arrows do.
            let current = pointerSelectionIndex(for: level)
            let next = current - steps
            let count = pointerListItemCount(for: level)
            guard count > 0 else { return }
            let clamped = max(0, min(count - 1, next))
            if clamped == current {
                playLimitSoundOnceForCurrentHold()
            } else {
                selectRowFromPointer(level: level, index: clamped)
            }
        }
    }

    /// Whole steps taken out of an accumulated amount, towards zero.
    private func wholeSteps(_ accumulator: inout CGFloat) -> Int {
        let steps = Int(accumulator.rounded(.towardZero))
        accumulator -= CGFloat(steps)
        return steps
    }

    // MARK: - Menus

    /// Times when nothing should react to the pointer, as keys are held off then.
    private var isPointerInputPaused: Bool {
        isFullscreenSceneTransitioning || isMenuFolderSwapTransitioning || isMovieTransitioning ||
            (isMovieResumePromptVisible && isMovieResumePromptConfirming)
    }

    func pointerSelectionIndex(for level: MenuListLevel) -> Int {
        switch level {
        case .root: selectedIndex
        case .submenu: selectedSubIndex
        case .third: selectedThirdIndex
        }
    }

    private func pointerListItemCount(for level: MenuListLevel) -> Int {
        switch level {
        case .root: rootListItems().count
        case .submenu: submenuListItems().count
        case .third: thirdMenuListItems().count
        }
    }

    /// Moves the selection to the row under the pointer, keeping the list still under it.
    func selectRowFromPointer(level: MenuListLevel, index: Int, pinsList: Bool = true) {
        guard level == pointerActiveListLevel, index != pointerSelectionIndex(for: level) else { return }
        guard index >= 0, index < pointerListItemCount(for: level) else { return }
        if pinsList, let state = pointer.hitTester?.menuListScrollState(level) {
            // Where the list is on screen now, nudges included.
            pointer.pin = (state.identity, state.scrollOffset)
        }
        resetNavigationAccelerationState()
        useLinearSelectionSweepAnimation = false
        selectionAnimationDuration = Self.pointerSelectionDuration
        markSelectionAsMoving()
        playSound(named: "SelectionChange")
        switch level {
        case .root:
            selectedIndex = index
        case .submenu:
            selectedSubIndex = index
            refreshDetailPreviewForCurrentContext()
        case .third:
            selectedThirdIndex = index
            rememberCurrentMoviesFolderSelectionIndex()
            if activeRootItemID == "music", thirdMenuMode == .musicSongs {
                refreshMusicPreviewForCurrentContext()
            } else if !(activeRootItemID == "photos" && thirdMenuMode == .photosDateAlbums) {
                refreshDetailPreviewForCurrentContext()
            }
        }
        objectWillChange.send()
    }

    /// Scrolls a list by whole rows (positive: towards the top) and selects the row now under the pointer.
    private func scrollMenuList(level: MenuListLevel, state: MenuListScrollState, rows: Int, pointerAt point: CGPoint) {
        let current = pointer.pinnedScrollOffset(identity: state.identity) ?? state.scrollOffset
        let target = max(state.minScrollOffset, min(0, current + CGFloat(rows) * state.rowPitch))
        guard abs(target - current) > 0.5 else {
            playLimitSoundOnceForCurrentHold()
            return
        }
        didPlayLimitForCurrentHold = false
        pointer.pin = (state.identity, target)
        useLinearSelectionSweepAnimation = false
        selectionAnimationDuration = Self.pointerScrollDuration
        updateOverflowFadeVisibility(oldOffset: current, newOffset: target)
        if let index = pointer.hitTester?.menuRowIndex(level, at: point, scrollOffset: target),
           index != pointerSelectionIndex(for: level)
        {
            selectRowFromPointer(level: level, index: index, pinsList: false)
            selectionAnimationDuration = Self.pointerScrollDuration
        } else {
            objectWillChange.send()
        }
    }

    private func selectResumeOptionFromPointer(_ index: Int) {
        guard isMovieResumePromptVisible, !isMovieResumePromptConfirming, index != movieResumePromptSelectedIndex else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            movieResumePromptSelectedIndex = index
        }
        playSound(named: "SelectionChange")
    }

    // MARK: - Progress bars

    private func beginMovieProgressDrag(at fraction: Double) {
        guard let player = moviePlayer, !isMovieTransitioning else { return }
        let duration = moviePlaybackDurationSeconds
        guard duration.isFinite, duration > 0 else { return }
        let wasPlaying = player.rate > 0.01
        pointer.drag = .movie(wasPlaying: wasPlaying)
        pointer.cursorHideTask?.cancel()
        stopMovieScrubbing(revertToPause: false, scheduleAutoHide: false)
        showMovieControlsInstantly()
        player.pause()
        // Holds back the playback clock while the pointer has the position.
        movieScrubDirection = 1
        movieControlsGlyphState = .pause
        seekMovie(toFraction: fraction, exact: false)
    }

    private func beginMusicProgressDrag(at fraction: Double) {
        guard !isMusicSongTransitioning, musicAudioPlayer != nil || activeMusicPlaybackSongID != nil else { return }
        let duration = musicNowPlayingDurationSeconds
        guard duration.isFinite, duration > 0 else { return }
        let wasPlaying = (musicAudioPlayer?.rate ?? 0) > 0.01
        pointer.drag = .music(wasPlaying: wasPlaying)
        pointer.cursorHideTask?.cancel()
        stopMusicScrubbing(showPauseGlyph: false)
        musicAudioPlayer?.pause()
        // Holds back every player's progress updates while the pointer has the position.
        musicScrubDirection = 1
        musicNowPlayingLeadingGlyphState = nil
        seekMusic(toFraction: fraction)
        updateMusicNowPlayingFlipTimerState()
    }

    private func continueProgressDrag(at point: CGPoint) {
        guard let drag = pointer.drag, let fraction = pointer.hitTester?.progressBarFraction(at: point) else { return }
        switch drag {
        case .movie:
            guard isMoviePlaybackVisible else {
                pointer.drag = nil
                return
            }
            seekMovie(toFraction: fraction, exact: false)
        case .music:
            guard activeFullscreenScene?.key == musicNowPlayingFullscreenKey else {
                pointer.drag = nil
                return
            }
            seekMusic(toFraction: fraction)
        }
    }

    private func finishProgressDrag(at point: CGPoint) {
        guard let drag = pointer.drag else { return }
        let fraction = pointer.hitTester?.progressBarFraction(at: point)
        pointer.drag = nil
        switch drag {
        case let .movie(wasPlaying):
            if let fraction { seekMovie(toFraction: fraction, exact: true) }
            movieScrubDirection = 0
            if wasPlaying {
                movieControlsGlyphState = .play
                moviePlayer?.play()
            }
            scheduleMovieControlsAutoHide()
        case let .music(wasPlaying):
            if let fraction { seekMusic(toFraction: fraction) }
            let target = musicNowPlayingElapsedSeconds
            if let player = musicAudioPlayer {
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            // Ends the hold on progress updates, and moves players that seek by themselves.
            stopMusicScrubbing(showPauseGlyph: false)
            if let player = musicAudioPlayer {
                if wasPlaying {
                    player.playImmediately(atRate: 1.0)
                    musicNowPlayingLeadingGlyphState = nil
                } else {
                    musicNowPlayingLeadingGlyphState = .pause
                }
            }
            updateMusicNowPlayingFlipTimerState()
        }
        scheduleCursorHide()
    }

    private func seekMovie(toFraction fraction: Double, exact: Bool) {
        guard let player = moviePlayer else { return }
        let duration = moviePlaybackDurationSeconds
        guard duration.isFinite, duration > 0 else { return }
        let seconds = max(0, min(duration, fraction * duration))
        moviePlaybackCurrentSeconds = seconds
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func skipMovie(bySeconds delta: Double) {
        guard let player = moviePlayer, !isMovieTransitioning else { return }
        let duration = moviePlaybackDurationSeconds
        guard duration.isFinite, duration > 0 else { return }
        stopMovieScrubbing(revertToPause: false, scheduleAutoHide: false)
        showMovieControlsInstantly()
        let seconds = max(0, min(duration - 0.5, moviePlaybackCurrentSeconds + delta))
        moviePlaybackCurrentSeconds = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        scheduleMovieControlsAutoHide()
    }

    /// Shows the new position, and moves the player there now if it can follow a drag.
    private func seekMusic(toFraction fraction: Double) {
        let duration = musicNowPlayingDurationSeconds
        guard duration.isFinite, duration > 0 else { return }
        let seconds = max(0, min(duration, fraction * duration))
        musicNowPlayingElapsedSeconds = seconds
        if let player = musicAudioPlayer {
            let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
    }

    // MARK: - The pointer itself

    private func scheduleCursorHide() {
        pointer.cursorHideTask?.cancel()
        pointer.cursorHideTask = Task { @MainActor [weak self] in
            try? await firstRowSleep(Self.pointerCursorHideDelay)
            guard !Task.isCancelled, let self, self.pointer.drag == nil else { return }
            PointerCursor.hideUntilMoved()
        }
    }
}
