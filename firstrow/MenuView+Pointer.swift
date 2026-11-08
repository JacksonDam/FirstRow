import AVFoundation
import Foundation
#if os(iOS)
    import MediaPlayer
#elseif os(tvOS)
    import MusicKit
#endif
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
    var pin: (identity: String, offset: CGFloat)? {
        didSet {
            // In touch mode each list is left where the finger left it, to come back to, when
            // the finger moves on to another list (not when the arrows take one over).
            guard isTouchMode, let pin else { return }
            leftScrollOffsets[pin.identity] = nil
            guard let old = oldValue, old.identity != pin.identity else { return }
            if leftScrollOffsets.count > 40 { leftScrollOffsets.removeAll() }
            leftScrollOffsets[old.identity] = old.offset
        }
    }

    /// Touch mode's lists, by identity, as they were last left.
    private var leftScrollOffsets: [String: CGFloat] = [:]
    private var isTouchMode: Bool {
        #if os(iOS)
            AppSettings.isTouchEnabled
        #else
            false
        #endif
    }
    /// The pin follows a finger: no nudging to show the selected row, and no easing.
    var tracksFinger = false
    /// How the next move of the pin animates (a flick coasting to a stop), used once.
    var scrollAnimation: Animation?
    fileprivate(set) var location: CGPoint?
    fileprivate var pressTarget: PointerTarget?
    /// The row of Now Playing's list a click started on.
    fileprivate var queuePressRow: Int?
    /// The on-screen button a click started on.
    fileprivate var pressedControl: TouchControl?
    var drag: Drag?
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
        let minOffset = min(0, viewportHeight - contentHeight)
        guard let pin, pin.identity == identity else {
            // A list touch mode left scrolled, come back to.
            guard isTouchMode, let left = leftScrollOffsets[identity] else { return nil }
            return max(minOffset, min(0, left))
        }
        var offset = max(minOffset, min(0, pin.offset))
        // A list moved by a finger stays where it was left, wherever the selection is, and may
        // be pulled past its ends for a moment (it springs back when let go).
        if tracksFinger { return pin.offset }
        #if os(iOS)
            if AppSettings.isTouchEnabled { return pin.offset }
        #endif
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

    /// Drops what's kept of one list's scroll.
    func forgetScroll(identity: String) {
        if pin?.identity == identity { pin = nil }
        leftScrollOffsets[identity] = nil
    }

    /// Lists gone back out of, whose scroll is dropped when they next appear (not as they go,
    /// or they'd jump while fading).
    private var forgetWhenShownAgain: Set<String> = []

    func forgetScrollWhenShownAgain(identity: String) {
        forgetWhenShownAgain.insert(identity)
    }

    /// A list is appearing afresh.
    func listAppears(identity: String) {
        if forgetWhenShownAgain.remove(identity) != nil {
            forgetScroll(identity: identity)
        }
    }

    /// A list clicked into a player keeps where the wheel left it while the player comes up over
    /// it, and takes up its usual place once it's out of sight.
    var clearsPinOnceCovered = false

    func clearPin() {
        clearsPinOnceCovered = false
        pin = nil
        leftScrollOffsets.removeAll()
        forgetWhenShownAgain.removeAll()
        tracksFinger = false
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
/// clicking chooses, the on-screen Back button (or the mouse's back button) goes back, the wheel
/// scrolls, and the progress bars seek.
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
        if onboardingStep != nil {
            handleOnboardingPointer(event)
            return
        }
        guard AppSettings.isMouseEnabled, !isChoosingMediaSource else { return }
        let wasPointing = lastInputSource == .pointer
        noteInputSource(.pointer)
        // After keys or a remote, a click only brings the on-screen buttons back.
        if case .pressed = event, !wasPointing {
            pointer.location = event.location
            return
        }
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
            #if os(iOS)
                // Touch mode's lists stay where the finger left them, as other apps' do: the one
                // a choice was made in, for coming back to. Going back up out of a list forgets
                // it, so next time it opens afresh.
                if AppSettings.isTouchEnabled {
                    pointer.tracksFinger = false
                    if key == .escape || key == .delete, activeFullscreenScene == nil, !isMoviePlaybackVisible,
                       !isMovieResumePromptVisible, textEntry == nil, let level = pointerActiveListLevel,
                       let identity = pointer.hitTester?.menuListScrollState(level)?.identity
                    {
                        // Not yet: it stays where it is as it fades, and starts afresh next time.
                        pointer.forgetScrollWhenShownAgain(identity: identity)
                    }
                    return
                }
            #endif
            // Enter waits to see what it opens (see settlePointerScrollAfterEnter).
            if key != .enter { pointer.clearPin() }
        }
    }

    /// After Enter: a player coming up over the list leaves it where the wheel left it until
    /// the player covers it; anything else hands the list back to the arrows straight away.
    func settlePointerScrollAfterEnter() {
        #if os(iOS)
            if AppSettings.isTouchEnabled { return }
        #endif
        guard pointer.pin != nil else { return }
        if isPlayerCoveringMenus(orComing: true) {
            pointer.clearsPinOnceCovered = true
        } else {
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
            let distance = ((point.x - origin.x) * (point.x - origin.x) + (point.y - origin.y) * (point.y - origin.y)).squareRoot()
            if distance > 6, !isFullscreenSceneTransitioning {
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
        if let control = pointer.pressedControl {
            // Held down only while the pointer stays on it.
            pointer.hitTester?.highlightTouchControl(pointer.hitTester?.touchControl(at: point) == control ? control : nil)
            return
        }
        guard !isPointerInputPaused else { return }
        if isMoviePlaybackVisible {
            guard !isMovieTransitioning, moviePlayer != nil else { return }
            // The controls fade in as the pointer moves, and stay while it does.
            showMovieControlsFading()
            // Over the open options, the row under the pointer is picked out.
            if var options = movieOptions, let hit = pointer.hitTester?.movieOptionsRow(at: point),
               options.rows.indices.contains(hit.index), hit.index != options.focusedRow
            {
                options.focusedRow = hit.index
                options.hasMoved = true
                movieOptions = options
                playSound(named: "SelectionChange")
            }
            if movieOptions == nil { scheduleMovieControlsAutoHide() }
            return
        }
        if activeFullscreenScene?.key == musicNowPlayingFullscreenKey, !isFullscreenSceneTransitioning {
            pointerMovedOverNowPlaying(point)
            return
        }
        if activeFullscreenScene?.key == photoSlideshowFullscreenKey, !isFullscreenSceneTransitioning {
            showSlideshowControls()
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
        // The on-screen buttons come first, as for fingers.
        if button == .primary, let control = pointer.hitTester?.touchControl(at: point) {
            pointer.pressedControl = control
            pointer.pressTarget = nil
            pointer.hitTester?.highlightTouchControl(control)
            return
        }
        guard button == .primary else {
            // The mouse's own back button goes back; the right button does nothing (Back is
            // on screen instead).
            if button == .back {
                pointer.clearPin()
                pointer.pressTarget = nil
                handleKeyDown(.escape)
            }
            return
        }
        // Now Playing's list takes clicks on it; one beside it puts it away.
        if isNowPlayingQueueVisible, let geometry = pointer.hitTester?.nowPlayingQueueGeometry {
            pointer.pressTarget = nil
            if geometry.panel.contains(point) {
                pointer.queuePressRow = geometry.row(at: point, scroll: nowPlayingQueueScroll, count: nowPlayingQueueCount)
            } else {
                hideNowPlayingQueue()
            }
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
        if let control = pointer.pressedControl {
            pointer.pressedControl = nil
            pointer.hitTester?.highlightTouchControl(nil)
            if pointer.hitTester?.touchControl(at: point) == control {
                pressOnScreenControl(control)
            }
            return
        }
        if pointer.drag != nil {
            finishProgressDrag(at: point)
            return
        }
        if let pressedRow = pointer.queuePressRow {
            pointer.queuePressRow = nil
            if isNowPlayingQueueVisible, let geometry = pointer.hitTester?.nowPlayingQueueGeometry,
               geometry.row(at: point, scroll: nowPlayingQueueScroll, count: nowPlayingQueueCount) == pressedRow
            {
                chooseNowPlayingQueueRow(pressedRow)
            }
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
        if isMoviePlaybackVisible {
            performMovieClick(on: target)
            return
        }
        if activeFullscreenScene != nil {
            // Now Playing: a click brings the buttons back, as moving does (only the play button
            // plays and pauses).
            let key = activeFullscreenScene?.key
            if key == musicNowPlayingFullscreenKey {
                showNowPlayingTouchControls()
            } else if key == photoSlideshowFullscreenKey {
                // As on a movie: a click brings Back up (moving the pointer does too).
                showSlideshowControls()
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
        case .progressBar, .background, .movieOptionButton, .movieOptionRow:
            break
        }
    }

    /// A click during a movie: on the options or their buttons, or anywhere else to bring the
    /// controls up (playing and pausing is the play button's job; the controls go by themselves).
    private func performMovieClick(on target: PointerTarget) {
        guard !isMovieTransitioning, moviePlayer != nil else { return }
        switch target {
        case let .movieOptionRow(index, backward):
            chooseMovieOptionRow(index, backward: backward)
        case let .movieOptionButton(kind):
            toggleMovieOptions(focusing: kind)
        default:
            if isMovieOptionsVisible {
                closeMovieOptions()
            } else {
                showMovieControlsFading()
                scheduleMovieControlsAutoHide()
            }
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
        // Now Playing's list scrolls under the pointer.
        if isNowPlayingQueueVisible, let geometry = pointer.hitTester?.nowPlayingQueueGeometry, geometry.panel.contains(point) {
            let step = precise ? dy * geometry.canvasPerPoint : dy * Self.nowPlayingQueueRowPitch
            setNowPlayingQueueScroll(nowPlayingQueueScroll - step, limit: geometry.scrollLimit, animation: precise ? nil : .smooth(duration: 0.2))
            pointerMovedOverNowPlaying(point)
            return
        }
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
    var isPointerInputPaused: Bool {
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

    func pointerListItemCount(for level: MenuListLevel) -> Int {
        switch level {
        case .root: rootListItems().count
        case .submenu: submenuListItems().count
        case .third: thirdMenuListItems().count
        }
    }

    /// Moves the selection to the row under the pointer, keeping the list still under it.
    func selectRowFromPointer(level: MenuListLevel, index: Int, pinsList: Bool = true, touchSliding: Bool = false) {
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
        case .third:
            selectedThirdIndex = index
            rememberCurrentMoviesFolderSelectionIndex()
        }
        #if os(iOS)
            if AppSettings.isTouchEnabled, isTouchSelecting || touchSliding {
                deferTouchPreviewRefresh { [weak self] in self?.refreshPreviewForPointerSelection(level) }
                objectWillChange.send()
                return
            }
        #endif
        refreshPreviewForPointerSelection(level)
        objectWillChange.send()
    }

    /// The preview (and what it loads) for a row the pointer or a finger selected.
    private func refreshPreviewForPointerSelection(_ level: MenuListLevel) {
        guard level == pointerActiveListLevel else { return }
        switch level {
        case .root:
            break
        case .submenu:
            refreshDetailPreviewForCurrentContext()
        case .third:
            if activeRootItemID == "music", thirdMenuMode == .musicSongs {
                refreshMusicPreviewForCurrentContext()
            } else if !(activeRootItemID == "photos" && thirdMenuMode == .photosDateAlbums) {
                refreshDetailPreviewForCurrentContext()
            }
        }
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

    func selectResumeOptionFromPointer(_ index: Int) {
        guard isMovieResumePromptVisible, !isMovieResumePromptConfirming, index != movieResumePromptSelectedIndex else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            movieResumePromptSelectedIndex = index
        }
        playSound(named: "SelectionChange")
    }

    // MARK: - Progress bars

    func beginMovieProgressDrag(at fraction: Double) {
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

    /// A finger or the pointer has hold of Now Playing's progress bar.
    var isMusicProgressBarHeld: Bool {
        if case .music = pointer.drag { return true }
        return false
    }

    func beginMusicProgressDrag(at fraction: Double) {
        guard !isMusicSongTransitioning, musicAudioPlayer != nil || activeMusicPlaybackSongID != nil else { return }
        let duration = musicNowPlayingDurationSeconds
        guard duration.isFinite, duration > 0 else { return }
        let wasPlaying = (musicAudioPlayer?.rate ?? 0) > 0.01
        pointer.drag = .music(wasPlaying: wasPlaying)
        // Held by a finger or the pointer, the bar itself shows what's happening.
        hidesMusicLeadingGlyph = true
        pointer.cursorHideTask?.cancel()
        stopMusicScrubbing(showPauseGlyph: false)
        musicAudioPlayer?.pause()
        // Holds back every player's progress updates while the pointer has the position.
        musicScrubDirection = 1
        musicNowPlayingLeadingGlyphState = nil
        seekMusic(toFraction: fraction)
        updateMusicNowPlayingFlipTimerState()
    }

    func continueProgressDrag(at point: CGPoint) {
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

    func finishProgressDrag(at point: CGPoint) {
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
            } else {
                seekSystemMusicPlayer(toSeconds: target)
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

    func skipMovie(bySeconds delta: Double) {
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

extension MenuView {
    /// A player (Now Playing, a movie, a slideshow) over the menus; with `orComing`, one on its
    /// way too, or the movie prompt that comes before one.
    func isPlayerCoveringMenus(orComing: Bool = false) -> Bool {
        let scene = activeFullscreenScene.map { $0.key != screenSaverFullscreenKey } ?? false
        if orComing {
            return scene || isFullscreenSceneTransitioning || isMoviePlaybackVisible || isMovieTransitioning || isMovieResumePromptVisible
        }
        return (scene && !isFullscreenSceneTransitioning) || (isMoviePlaybackVisible && !isMovieTransitioning)
    }

    /// One of the on-screen buttons was pressed (by a finger or the pointer).
    func pressOnScreenControl(_ control: TouchControl) {
        func press(_ key: KeyCode) {
            handleKeyDown(key)
            handleKeyUp(key)
        }
        switch control {
        case .back:
            press(.escape)
        case .playPause, .previous, .next:
            // The buttons show the state themselves, so the glyph under the bar stays away.
            isPressingOnScreenPlaybackButton = true
            press(control == .playPause ? .space : control == .previous ? .upArrow : .downArrow)
            isPressingOnScreenPlaybackButton = false
        case .skipBack:
            skipMovie(bySeconds: -10)
        case .skipForward:
            skipMovie(bySeconds: 10)
        case .lyrics:
            toggleNowPlayingLyrics()
        }
        if activeFullscreenScene?.key == musicNowPlayingFullscreenKey {
            scheduleNowPlayingTouchControlsHide()
        }
        if isMoviePlaybackVisible, movieOptions == nil {
            scheduleMovieControlsAutoHide()
        }
    }

    /// A tap or click on a row of the movie's options: on its "‹" back a value, anywhere else on
    /// to the next one, round to the first after the last; between rows, nothing.
    func chooseMovieOptionRow(_ index: Int, backward: Bool) {
        guard var options = movieOptions, options.rows.indices.contains(index) else { return }
        if index != options.focusedRow {
            options.focusedRow = index
            options.hasMoved = true
            movieOptions = options
        }
        _ = handleMovieOptionsInput(backward ? .leftArrow : .enter)
    }

    /// Moves the system's own music player (Apple Music and library songs on iPhone, iPad and
    /// Apple TV), which plays without an AVPlayer of First Row's.
    func seekSystemMusicPlayer(toSeconds seconds: Double) {
        guard activeMusicPlaybackSongID != nil, !isCurrentMusicPlaybackUsingSpotify else { return }
        #if os(iOS)
            if isCurrentMusicPlaybackUsingMediaPlayer {
                SystemMusicPlayerCalls.send { MPMusicPlayerController.applicationQueuePlayer.currentPlaybackTime = seconds }
            }
        #elseif os(tvOS)
            if !isCurrentMusicPlaybackUsingAppleScript {
                ApplicationMusicPlayer.shared.playbackTime = seconds
            }
        #endif
    }
}
