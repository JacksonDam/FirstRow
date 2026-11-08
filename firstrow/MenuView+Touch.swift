import Foundation
import QuartzCore
#if canImport(UIKit)
    import UIKit
#endif

extension MenuView {
    /// Touch mode with no finger choosing a row: the lists show nothing as selected.
    var touchHidesSelection: Bool {
        #if os(iOS)
            AppSettings.isTouchEnabled && !isTouchSelecting
        #else
            false
        #endif
    }
}

#if os(iOS)
    enum TouchPhase {
        case began
        case moved
        case ended
        case cancelled
    }

    /// One finger's progress through a touch, between events.
    @MainActor
    final class TouchInputState {
        enum Mode: Equatable {
            /// Down, but not yet a slide, a scroll or a swipe.
            case undecided
            /// Sliding the selection over the rows; lifting chooses.
            case selecting
            /// Dragging a list longer than the screen.
            case scrolling
            /// Dragging along a progress bar.
            case scrubbing
            /// Moving sideways or (in a movie) up or down, for a swipe.
            case swiping
            /// On one of touch mode's buttons; lifting over it presses it.
            case button(TouchControl)
            case ignored
        }

        var mode = Mode.ignored
        var start = CGPoint.zero
        var startTime: TimeInterval = 0
        var last = CGPoint.zero
        var lastTime: TimeInterval = 0
        /// Vertical speed in window points a second, for coasting after a scroll.
        var velocity: CGFloat = 0
        var level: MenuListLevel?
        var scrollState: MenuListScrollState?
        var scrollStart: CGFloat = 0
        var startTarget: PointerTarget?
        var holdTask: Task<Void, Never>?
        /// A flick's coast to a stop, or a list springing back from past its end.
        var coastTask: Task<Void, Never>?
    }

    /// Direct touch, when Settings > Touch Controls is on. In menus nothing is selected until a
    /// finger is down: touching a row selects it, sliding moves the selection a row at a time,
    /// and lifting chooses. Long lists scroll with a drag and coast; holding still first slides
    /// the selection instead. Swiping right goes back. In playback, a tap plays or pauses,
    /// dragging the bar scrubs, Now Playing swipes change song and a movie swipe down opens its
    /// options.
    extension MenuView {
        private static let touchSlop: CGFloat = 10
        private static let touchHighlightDelay: TimeInterval = 0.1
        private static let touchHoldDelay: TimeInterval = 0.25
        private static let touchEdgeWidth: CGFloat = 30
        private static let touchSwipeDistance: CGFloat = 60

        func handleTouch(_ phase: TouchPhase, at point: CGPoint, time: TimeInterval) {
            guard AppSettings.isTouchEnabled, !isChoosingMediaSource else { return }
            switch phase {
            case .began: touchBegan(at: point, time: time)
            case .moved: touchMoved(to: point, time: time)
            case .ended: touchEnded(at: point, time: time)
            case .cancelled: touchCancelled()
            }
        }

        /// Menus, rather than a playback screen, a prompt or text entry, have the touch.
        private var isMenuTouchContext: Bool {
            activeFullscreenScene == nil && !isMoviePlaybackVisible && !isMovieResumePromptVisible &&
                textEntry == nil && codeDisplay == nil
        }

        // MARK: - Phases

        /// A key press with its release straight after: without the release an arrow would
        /// count as held and repeat.
        private func pressTouchKey(_ key: KeyCode) {
            handleKeyDown(key)
            handleKeyUp(key)
        }

        private func touchBegan(at point: CGPoint, time: TimeInterval) {
            let caughtList = catchCoastingList()
            let state = touch
            state.holdTask?.cancel()
            state.start = point
            state.last = point
            state.startTime = time
            state.lastTime = time
            state.velocity = 0
            state.level = nil
            state.scrollState = nil
            state.startTarget = nil
            state.mode = .undecided
            if activeFullscreenScene?.key == screenSaverFullscreenKey {
                if !isFullscreenSceneTransitioning { dismissScreenSaverForUserInteraction() }
                state.mode = .ignored
                return
            }
            registerUserInteractionForScreenSaver()
            guard !isPointerInputPaused else {
                state.mode = .ignored
                return
            }
            // The on-screen buttons come first.
            if let control = pointer.hitTester?.touchControl(at: point) {
                state.mode = .button(control)
                pointer.hitTester?.highlightTouchControl(control)
                return
            }
            // A finger on a list that's still moving stops it there, as a scroll view does.
            if let caughtList {
                state.mode = .scrolling
                state.level = caughtList.level
                state.scrollState = caughtList.scroll
                state.scrollStart = caughtList.scroll.presentedScrollOffset
                return
            }
            let target = pointer.hitTester?.pointerTarget(at: point)
            state.startTarget = target
            // The progress bars take the finger at once, so the drag can follow.
            if case let .progressBar(fraction) = target {
                if isMoviePlaybackVisible {
                    beginMovieProgressDrag(at: fraction)
                    state.mode = .scrubbing
                    return
                }
                if activeFullscreenScene?.key == musicNowPlayingFullscreenKey {
                    beginMusicProgressDrag(at: fraction)
                    state.mode = .scrubbing
                    return
                }
            }
            guard isMenuTouchContext, case let .menuRow(level, index) = target, level == pointerActiveListLevel else { return }
            state.level = level
            let scroll = pointer.hitTester?.menuListScrollState(level)
            state.scrollState = scroll
            if scroll?.canScroll != true {
                // Nothing to scroll: the finger slides the selection straight away.
                beginTouchSelection(level: level, index: index)
                return
            }
            // A long list waits to see whether this is a scroll: a moment for the highlight,
            // a little longer for sliding.
            state.holdTask = Task { @MainActor [weak self] in
                try? await firstRowSleep(Self.touchHighlightDelay)
                guard let self, !Task.isCancelled, self.touch.mode == .undecided else { return }
                self.showTouchSelection(level: level, at: self.touch.last)
                try? await firstRowSleep(Self.touchHoldDelay - Self.touchHighlightDelay)
                guard !Task.isCancelled, self.touch.mode == .undecided else { return }
                self.touch.mode = .selecting
            }
        }

        private func touchMoved(to point: CGPoint, time: TimeInterval) {
            let state = touch
            let interval = max(0.001, time - state.lastTime)
            let speed = (point.y - state.last.y) / CGFloat(interval)
            state.velocity = state.velocity * 0.3 + speed * 0.7
            state.last = point
            state.lastTime = time
            let dx = point.x - state.start.x
            let dy = point.y - state.start.y
            switch state.mode {
            case let .button(control):
                // Held down only while the finger stays on it.
                let over = pointer.hitTester?.touchControl(at: point) == control
                pointer.hitTester?.highlightTouchControl(over ? control : nil)
            case .scrubbing:
                continueProgressDrag(at: point)
            case .selecting:
                slideTouchSelection(to: point)
            case .undecided:
                guard (dx * dx + dy * dy).squareRoot() > Self.touchSlop else { return }
                state.holdTask?.cancel()
                if abs(dx) > abs(dy) || !isMenuTouchContext {
                    state.mode = .swiping
                    endTouchSelection()
                } else if let scroll = state.scrollState, scroll.canScroll, let level = state.level {
                    state.mode = .scrolling
                    endTouchSelection()
                    state.scrollStart = pointer.pinnedScrollOffset(identity: scroll.identity) ?? scroll.scrollOffset
                    pointer.tracksFinger = true
                    scrollTouchList(level: level, by: dy)
                } else {
                    state.mode = .swiping
                }
            case .scrolling:
                if let level = state.level { scrollTouchList(level: level, by: dy) }
            case .swiping, .ignored:
                break
            }
        }

        private func touchEnded(at point: CGPoint, time: TimeInterval) {
            let state = touch
            state.holdTask?.cancel()
            let dx = point.x - state.start.x
            let dy = point.y - state.start.y
            let mode = state.mode
            state.mode = .ignored
            switch mode {
            case let .button(control):
                pointer.hitTester?.highlightTouchControl(nil)
                if pointer.hitTester?.touchControl(at: point) == control {
                    pressTouchControl(control)
                }
            case .scrubbing:
                finishProgressDrag(at: point)
            case .selecting:
                // Lifting over a row chooses it; anywhere else lets it go.
                if case let .menuRow(level, index)? = pointer.hitTester?.pointerTarget(at: point), level == pointerActiveListLevel {
                    chooseTouchRow(level: level, index: index)
                } else {
                    endTouchSelection()
                }
            case .scrolling:
                // Coasting on (in scene points a second) if the finger was still moving, and
                // springing back if it left the list pulled past an end.
                if let level = state.level, let scroll = state.scrollState {
                    let scale = max(0.0001, scroll.rowPitchInWindow / max(1, scroll.rowPitch))
                    let moving = time - state.lastTime < 0.1
                    coastTouchList(level: level, velocity: moving ? state.velocity / scale : 0)
                } else {
                    pointer.tracksFinger = false
                }
            case .swiping:
                handleTouchSwipe(dx: dx, dy: dy, startX: state.start.x)
            case .undecided:
                handleTouchTap(at: point, target: state.startTarget)
            case .ignored:
                break
            }
        }

        private func touchCancelled() {
            let state = touch
            state.holdTask?.cancel()
            pointer.hitTester?.highlightTouchControl(nil)
            if state.mode == .scrubbing {
                finishProgressDrag(at: state.last)
            }
            if state.mode == .scrolling, let level = state.level {
                coastTouchList(level: level, velocity: 0)
            }
            state.mode = .ignored
            endTouchSelection()
        }

        // MARK: - Menus

        private func beginTouchSelection(level: MenuListLevel, index: Int) {
            touch.mode = .selecting
            showTouchSelection(level: level, index: index)
        }

        /// Shows the selection on the row under the finger.
        private func showTouchSelection(level: MenuListLevel, at point: CGPoint) {
            guard case let .menuRow(rowLevel, index)? = pointer.hitTester?.pointerTarget(at: point), rowLevel == level else { return }
            showTouchSelection(level: level, index: index)
        }

        private func showTouchSelection(level: MenuListLevel, index: Int) {
            if index != pointerSelectionIndex(for: level) {
                selectRowFromPointer(level: level, index: index)
            } else if let scroll = pointer.hitTester?.menuListScrollState(level) {
                // Keep the list still under the finger.
                pointer.pin = (scroll.identity, scroll.scrollOffset)
            }
            isTouchSelecting = true
        }

        /// The selection snaps to whichever visible row the finger is over.
        private func slideTouchSelection(to point: CGPoint) {
            guard let level = touch.level, level == pointerActiveListLevel,
                  case let .menuRow(rowLevel, index)? = pointer.hitTester?.pointerTarget(at: point), rowLevel == level
            else { return }
            if index != pointerSelectionIndex(for: level) {
                selectRowFromPointer(level: level, index: index)
            }
            if !isTouchSelecting { isTouchSelecting = true }
        }

        private func endTouchSelection() {
            if isTouchSelecting { isTouchSelecting = false }
        }

        private func chooseTouchRow(level: MenuListLevel, index: Int) {
            if index != pointerSelectionIndex(for: level) {
                selectRowFromPointer(level: level, index: index)
            }
            pointer.clearPin()
            endTouchSelection()
            pressTouchKey(.enter)
        }

        /// Moves a long list with the finger, `dy` window points from where the drag started.
        /// Past either end it keeps following, but less and less, as a scroll view does.
        private func scrollTouchList(level _: MenuListLevel, by dy: CGFloat) {
            guard let scroll = touch.scrollState else { return }
            let scale = max(0.0001, scroll.rowPitchInWindow / max(1, scroll.rowPitch))
            var offset = touch.scrollStart + dy / scale
            let reach: CGFloat = 700
            func band(_ past: CGFloat) -> CGFloat { (1 - 1 / (past * 0.55 / reach + 1)) * reach }
            if offset > 0 {
                offset = band(offset)
            } else if offset < scroll.minScrollOffset {
                offset = scroll.minScrollOffset - band(scroll.minScrollOffset - offset)
            }
            setTouchScroll(scroll, offset: offset)
        }

        private func setTouchScroll(_ scroll: MenuListScrollState, offset: CGFloat, animation: Animation? = nil) {
            let old = pointer.pinnedScrollOffset(identity: scroll.identity) ?? scroll.scrollOffset
            guard abs(old - offset) > 0.01 else { return }
            pointer.scrollAnimation = animation
            pointer.pin = (scroll.identity, offset)
            updateOverflowFadeVisibility(oldOffset: old, newOffset: offset)
            objectWillChange.send()
        }

        /// Stops a list that is still coasting where it is on screen, for a finger landing on it.
        private func catchCoastingList() -> (level: MenuListLevel, scroll: MenuListScrollState)? {
            touch.coastTask?.cancel()
            touch.coastTask = nil
            guard isMenuTouchContext, let level = pointerActiveListLevel,
                  let scroll = pointer.hitTester?.menuListScrollState(level),
                  abs(scroll.presentedScrollOffset - scroll.scrollOffset) > 1
            else { return nil }
            pointer.tracksFinger = true
            pointer.pin = (scroll.identity, scroll.presentedScrollOffset)
            objectWillChange.send()
            return (level, scroll)
        }

        /// Lets a list go: a flick coasts to a stop on a decelerating curve that starts at the
        /// finger's speed, bouncing off an end it runs into; a list pulled past an end springs
        /// back. Core Animation runs the motion, so it keeps the screen's full frame rate.
        private func coastTouchList(level: MenuListLevel, velocity: CGFloat) {
            pointer.tracksFinger = false
            guard let scroll = pointer.hitTester?.menuListScrollState(level),
                  let current = pointer.pinnedScrollOffset(identity: scroll.identity)
            else { return }
            let lower = scroll.minScrollOffset
            let upper: CGFloat = 0
            if current > upper || current < lower {
                setTouchScroll(scroll, offset: min(upper, max(lower, current)), animation: .smooth(duration: 0.5))
                return
            }
            guard abs(velocity) > 150 else { return }
            // An ease-out over 2t starting at speed v travels v * t.
            let glide: CGFloat = 0.42
            let projected = current + velocity * glide
            guard projected > upper || projected < lower else {
                setTouchScroll(scroll, offset: projected, animation: .smooth(duration: Double(glide * 2)))
                return
            }
            let bound = projected > upper ? upper : lower
            let overshoot = min(80, abs(velocity) * 0.035) * (projected > upper ? 1 : -1)
            let first = bound + overshoot
            let duration = Double(max(0.12, min(0.7, 2 * abs(first - current) / abs(velocity))))
            setTouchScroll(scroll, offset: first, animation: .smooth(duration: duration))
            touch.coastTask = Task { @MainActor [weak self] in
                try? await firstRowSleep(duration)
                guard let self, !Task.isCancelled, let scroll = self.pointer.hitTester?.menuListScrollState(level) else { return }
                self.setTouchScroll(scroll, offset: bound, animation: .smoothInOut(duration: 0.38))
            }
        }

        // MARK: - Buttons

        private func pressTouchControl(_ control: TouchControl) {
            switch control {
            case .back:
                pressTouchKey(.escape)
            case .playPause:
                pressTouchKey(.space)
            case .previous:
                pressTouchKey(.upArrow)
            case .next:
                pressTouchKey(.downArrow)
            case .skipBack:
                skipMovie(bySeconds: -10)
            case .skipForward:
                skipMovie(bySeconds: 10)
            }
            if isMoviePlaybackVisible {
                scheduleMovieControlsAutoHide()
            }
        }

        // MARK: - Taps and swipes

        private func handleTouchTap(at point: CGPoint, target: PointerTarget?) {
            endTouchSelection()
            if isMovieResumePromptVisible {
                if case let .resumeOption(index)? = target {
                    selectResumeOptionFromPointer(index)
                    pressTouchKey(.enter)
                }
                return
            }
            if isMoviePlaybackVisible {
                handleMovieTouchTap(at: point)
                return
            }
            if let scene = activeFullscreenScene {
                if scene.key == musicNowPlayingFullscreenKey || scene.key == photoSlideshowFullscreenKey {
                    pressTouchKey(.space)
                } else if scene.key != screenSaverFullscreenKey {
                    // Errors and messages go away with a tap.
                    pressTouchKey(.escape)
                }
                return
            }
            guard isMenuTouchContext else { return }
            switch target {
            case let .menuRow(level, index)? where level == pointerActiveListLevel:
                chooseTouchRow(level: level, index: index)
            case let .sortSegment(mode)?:
                handleTVShowsSortInput(direction: mode == .date ? -1 : 1)
            default:
                break
            }
        }

        private func handleMovieTouchTap(at point: CGPoint) {
            guard !isMovieTransitioning, moviePlayer != nil else { return }
            if var options = movieOptions {
                guard let row = pointer.hitTester?.movieOptionsRow(at: point) else {
                    closeMovieOptions()
                    return
                }
                guard options.rows.indices.contains(row) else { return }
                if row == options.focusedRow {
                    _ = handleMovieOptionsInput(.enter)
                } else {
                    options.focusedRow = row
                    options.hasMoved = true
                    movieOptions = options
                    playSound(named: "SelectionChange")
                    showMovieControlsInstantly()
                }
                return
            }
            if areMovieControlsVisible {
                pressTouchKey(.space)
            } else {
                showMovieControlsInstantly()
                scheduleMovieControlsAutoHide()
            }
        }

        private func handleTouchSwipe(dx: CGFloat, dy: CGFloat, startX: CGFloat) {
            let fromEdge = startX < Self.touchEdgeWidth
            #if DEBUG || FIRSTROW_HARNESS_BUILD
                FirstRowHarness.touchLog("[touch] swipe dx \(Int(dx)) dy \(Int(dy))\(fromEdge ? " from the edge" : "")")
            #endif
            if abs(dx) > abs(dy) * 1.5, abs(dx) > Self.touchSwipeDistance {
                let rightward = dx > 0
                if activeFullscreenScene?.key == musicNowPlayingFullscreenKey, !fromEdge {
                    // Left for the next song, right for the one before.
                    #if DEBUG || FIRSTROW_HARNESS_BUILD
                        FirstRowHarness.touchLog("[touch] \(rightward ? "previous" : "next") song")
                    #endif
                    pressTouchKey(rightward ? .upArrow : .downArrow)
                    return
                }
                // Back is a swipe in from the left edge, as elsewhere on iPhone, or the Back button.
                if rightward, fromEdge { pressTouchKey(.escape) }
                return
            }
            if abs(dy) > abs(dx) * 1.5, abs(dy) > Self.touchSwipeDistance, isMoviePlaybackVisible {
                if dy > 0 {
                    openMovieOptions()
                } else {
                    closeMovieOptions()
                }
            }
        }
    }
#endif
