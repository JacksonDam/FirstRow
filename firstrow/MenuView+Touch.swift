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
        enum Mode {
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
        var momentumTimer: Timer?
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
            stopTouchMomentum()
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
            case .scrubbing:
                continueProgressDrag(at: point)
            case .selecting:
                // A firm move to the right turns the slide into a swipe back.
                if dx > 40, dx > abs(dy) * 2 {
                    state.mode = .swiping
                    endTouchSelection()
                    return
                }
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
                // Coasting on (scene points a second) if the finger was still moving.
                if let level = state.level, let scroll = state.scrollState, time - state.lastTime < 0.1, abs(state.velocity) > 150 {
                    let scale = max(0.0001, scroll.rowPitchInWindow / max(1, scroll.rowPitch))
                    startTouchMomentum(level: level, velocity: state.velocity / scale)
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
            if state.mode == .scrubbing {
                finishProgressDrag(at: state.last)
            }
            if state.mode == .scrolling {
                pointer.tracksFinger = false
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
        private func scrollTouchList(level: MenuListLevel, by dy: CGFloat) {
            guard let scroll = touch.scrollState else { return }
            let scale = max(0.0001, scroll.rowPitchInWindow / max(1, scroll.rowPitch))
            let offset = max(scroll.minScrollOffset, min(0, touch.scrollStart + dy / scale))
            setTouchScroll(scroll, offset: offset)
        }

        private func setTouchScroll(_ scroll: MenuListScrollState, offset: CGFloat) {
            let old = pointer.pinnedScrollOffset(identity: scroll.identity) ?? scroll.scrollOffset
            guard abs(old - offset) > 0.01 else { return }
            pointer.pin = (scroll.identity, offset)
            updateOverflowFadeVisibility(oldOffset: old, newOffset: offset)
            objectWillChange.send()
        }

        /// Coasts a flicked list to a stop, slowing as a scroll view does.
        private func startTouchMomentum(level: MenuListLevel, velocity: CGFloat) {
            stopTouchMomentum()
            pointer.tracksFinger = true
            var speed = velocity
            var last = CACurrentMediaTime()
            let timer = Timer(after: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible {
                    guard let self else { return }
                    let now = CACurrentMediaTime()
                    let elapsed = now - last
                    last = now
                    speed *= CGFloat(pow(0.998, elapsed * 1000))
                    guard level == self.pointerActiveListLevel,
                          let scroll = self.pointer.hitTester?.menuListScrollState(level),
                          let current = self.pointer.pinnedScrollOffset(identity: scroll.identity)
                    else {
                        self.stopTouchMomentum()
                        return
                    }
                    var offset = current + speed * CGFloat(elapsed)
                    if offset > 0 || offset < scroll.minScrollOffset {
                        offset = max(scroll.minScrollOffset, min(0, offset))
                        speed = 0
                    }
                    self.setTouchScroll(scroll, offset: offset)
                    if abs(speed) < 12 { self.stopTouchMomentum() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            touch.momentumTimer = timer
        }

        private func stopTouchMomentum() {
            guard let timer = touch.momentumTimer else { return }
            timer.invalidate()
            touch.momentumTimer = nil
            pointer.tracksFinger = false
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
                if isMoviePlaybackVisible, !fromEdge { return }
                if rightward { pressTouchKey(.escape) }
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
