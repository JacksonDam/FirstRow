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
            /// On Now Playing's list: a tap chooses a song, a drag scrolls.
            case queue
            /// Sliding the selection over Now Playing's list, as in the menus; lifting plays.
            case queueSelecting
            /// Pulling Now Playing's list out from the right edge, or pushing it back.
            case queuePull
            case ignored
        }

        var mode = Mode.ignored
        var start = CGPoint.zero
        var startTime: TimeInterval = 0
        var last = CGPoint.zero
        var lastTime: TimeInterval = 0
        var level: MenuListLevel?
        var scrollState: MenuListScrollState?
        var scrollStart: CGFloat = 0
        var startTarget: PointerTarget?
        var holdTask: Task<Void, Never>?
        /// The finger's recent heights in window points, for its speed when it lets go.
        var samples: [(time: TimeInterval, y: CGFloat)] = []
        /// Where the finger was when the drag became a scroll, so getting past the slop
        /// doesn't make the list jump.
        var scrollOriginY: CGFloat = 0
        /// A list moving on its own after the finger let go.
        var motion: TouchListMotion?
        /// The row under a sliding finger. The selection walks to it a row a frame, so every
        /// row it passes shows as selected.
        var selectionTarget: (level: MenuListLevel, index: Int)?
        /// A preview change put off while a finger slides through the rows.
        var previewRefresh: Task<Void, Never>?
        var pendingPreview: (@MainActor () -> Void)?
        var isFingerDown = false
        var motionStarted: CFTimeInterval = 0
        /// Now Playing's list: where a drag on it started, whether it has moved, and the list
        /// moving on its own after a flick.
        var queueStartScroll: CGFloat = 0
        var queueOriginY: CGFloat?
        var queueWasMoving = false
        var queueMotion: TouchListMotion?
        /// The row of Now Playing's list under a sliding finger, walked to a row a frame.
        var queueSelectionTarget: Int?
        /// How far out the list was, and where the finger was, when a pull began; and the
        /// finger's recent sideways positions, for how fast it let go.
        var pullStartReveal: CGFloat = 0
        var pullOriginX: CGFloat = 0
        var xSamples: [(time: TimeInterval, x: CGFloat)] = []
        /// Frames at the screen's full rate while a finger is down or a list moves on its own.
        let clock = TouchFrameClock()
    }

    /// Calls back once a frame, at the fastest rate the screen offers, while asked to.
    @MainActor
    final class TouchFrameClock: NSObject {
        /// Gets the seconds since the last frame; returns whether to keep going.
        var onFrame: ((Double) -> Bool)?
        private var link: CADisplayLink?
        private var lastTarget: CFTimeInterval = 0

        func run() {
            if let link {
                guard link.isPaused else { return }
                link.isPaused = false
            } else {
                let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
                if #available(iOS 15.0, *) {
                    let fastest = Float(max(60, UIScreen.main.maximumFramesPerSecond))
                    link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, fastest), maximum: fastest, preferred: fastest)
                }
                link.add(to: .main, forMode: .common)
                self.link = link
            }
            lastTarget = 0
        }

        func stop() {
            link?.isPaused = true
        }

        @objc private func frame(_ link: CADisplayLink) {
            let target = link.targetTimestamp
            let elapsed = lastTarget == 0 ? max(0.001, target - link.timestamp) : min(1.0 / 30, max(0, target - lastTarget))
            lastTarget = target
            if onFrame?(elapsed) != true { stop() }
        }
    }

    /// A list's own motion after a finger lets go, worked out a frame at a time as a scroll
    /// view's is: momentum that fades away slowly, and a critically damped spring that brings
    /// it back to an end it was pulled or carried past. Offsets are in scene points.
    struct TouchListMotion {
        enum Phase {
            case coasting
            case springing
        }

        let level: MenuListLevel
        let identity: String
        var offset: CGFloat
        /// Scene points a second.
        var velocity: CGFloat
        let lower: CGFloat
        let upper: CGFloat
        /// Scene points to a window point, so speeds and distances feel the same on any screen.
        let scenePerPoint: CGFloat
        var phase = Phase.coasting
        private var springTarget: CGFloat = 0
        private var springStart: CGFloat = 0
        private var springVelocity: CGFloat = 0
        private var springTime: Double = 0

        /// A scroll view's normal deceleration: 99.8% of the speed kept every millisecond.
        private static let decay = 1000 * log(1 / 0.998)
        /// How quickly the spring settles (about half a second from a pull).
        private static let stiffness = 10.5

        init(level: MenuListLevel, identity: String, offset: CGFloat, velocity: CGFloat, lower: CGFloat, upper: CGFloat, scenePerPoint: CGFloat) {
            self.level = level
            self.identity = identity
            self.offset = offset
            self.velocity = velocity
            self.lower = lower
            self.upper = upper
            self.scenePerPoint = scenePerPoint
            if offset > upper || offset < lower {
                spring(toward: offset > upper ? upper : lower)
            }
        }

        /// Whether a flick this fast is worth coasting on.
        var isWorthMoving: Bool {
            phase == .springing || abs(velocity) > 30 * scenePerPoint
        }

        private mutating func spring(toward target: CGFloat) {
            phase = .springing
            springTarget = target
            springStart = offset
            springTime = 0
            // Running into an end carries the list only a little way past it.
            let cap = 110 * scenePerPoint * CGFloat(Self.stiffness * M_E)
            springVelocity = max(-cap, min(cap, velocity))
        }

        /// Moves on by `seconds`. Returns false once it has come to rest.
        mutating func advance(_ seconds: Double) -> Bool {
            switch phase {
            case .coasting:
                let kept = exp(-Self.decay * seconds)
                offset += velocity * CGFloat((1 - kept) / Self.decay)
                velocity *= CGFloat(kept)
                if offset > upper || offset < lower {
                    spring(toward: offset > upper ? upper : lower)
                    return true
                }
                return abs(velocity) > 6 * scenePerPoint
            case .springing:
                springTime += seconds
                let rate = Self.stiffness
                let start = Double(springStart - springTarget)
                let speed = Double(springVelocity)
                let b = speed + rate * start
                let fade = exp(-rate * springTime)
                let distance = (start + b * springTime) * fade
                velocity = CGFloat((speed - rate * b * springTime) * fade)
                offset = springTarget + CGFloat(distance)
                // Thrown back in past the end: momentum takes over again.
                if (offset < upper && offset > lower), (start > 0 ? velocity < 0 : velocity > 0),
                   (start > 0 ? distance < 0 : distance > 0), abs(velocity) > 30 * scenePerPoint
                {
                    phase = .coasting
                    return true
                }
                if abs(CGFloat(distance)) < 0.1 * scenePerPoint, abs(velocity) < 4 * scenePerPoint || springTime > 3 {
                    offset = springTarget
                    velocity = 0
                    return false
                }
                return true
            }
        }
    }

    /// Direct touch, when Settings > Touch Controls is on. In menus nothing is selected until a
    /// finger is down: touching a row selects it, sliding moves the selection a row at a time,
    /// and lifting chooses. Long lists scroll with a drag and coast; holding still first slides
    /// the selection instead. Swiping right goes back. In Now Playing a tap plays or pauses (in
    /// a movie it shows or hides the controls),
    /// dragging the bar scrubs, Now Playing swipes change song, and a movie's option buttons
    /// above its bar (or a swipe down) open its options.
    extension MenuView {
        private static let touchSlop: CGFloat = 10
        private static let touchHighlightDelay: TimeInterval = 0.1
        private static let touchHoldDelay: TimeInterval = 0.4
        private static let touchEdgeWidth: CGFloat = 30
        private static let touchSwipeDistance: CGFloat = 60

        func handleTouch(_ phase: TouchPhase, at point: CGPoint, time: TimeInterval) {
            if onboardingStep != nil {
                handleOnboardingTouch(phase, at: point)
                return
            }
            guard AppSettings.isTouchEnabled, !isChoosingMediaSource else { return }
            let wasTouching = lastInputSource == .touch
            noteInputSource(.touch)
            if phase == .began, !wasTouching {
                // After a remote or keyboard, a touch only brings the on-screen buttons back.
                touch.holdTask?.cancel()
                touch.mode = .ignored
                touch.isFingerDown = true
                return
            }
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
            state.isFingerDown = true
            state.selectionTarget = nil
            startTouchClock()
            state.start = point
            state.last = point
            state.startTime = time
            state.lastTime = time
            state.samples = [(time, point.y)]
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
            let queueWasMoving = state.queueMotion.map { abs($0.velocity) > 20 * $0.scenePerPoint } ?? false
            state.queueMotion = nil
            if activeFullscreenScene?.key == musicNowPlayingFullscreenKey, !areNowPlayingTouchControlsHidden {
                // Any touch keeps Now Playing's buttons up a while longer.
                scheduleNowPlayingTouchControlsHide()
            }
            // The on-screen buttons come first.
            if let control = pointer.hitTester?.touchControl(at: point) {
                state.mode = .button(control)
                pointer.hitTester?.highlightTouchControl(control)
                return
            }
            // In from the right edge, Now Playing's list follows the thumb.
            if activeFullscreenScene?.key == musicNowPlayingFullscreenKey, !isNowPlayingQueueVisible, canShowNowPlayingQueue,
               let geometry = pointer.hitTester?.nowPlayingQueueGeometry, geometry.edgeZone.contains(point)
            {
                beginNowPlayingQueuePull(at: point, time: time)
                return
            }
            if isNowPlayingQueueVisible, let geometry = pointer.hitTester?.nowPlayingQueueGeometry, geometry.panel.contains(point) {
                state.mode = .queue
                state.queueStartScroll = nowPlayingQueueScroll
                state.queueOriginY = nil
                state.queueWasMoving = queueWasMoving
                state.queueSelectionTarget = nil
                guard !queueWasMoving, geometry.row(at: point, scroll: nowPlayingQueueScroll, count: nowPlayingQueueCount) != nil else { return }
                if geometry.scrollLimit <= 0 {
                    // Nothing to scroll: the finger slides the selection straight away.
                    state.mode = .queueSelecting
                    showQueueTouchSelection(at: point)
                    return
                }
                // As in the menus: a moment for the highlight, a little longer for sliding,
                // and a drag before then scrolls.
                state.holdTask = Task { @MainActor [weak self] in
                    try? await firstRowSleep(Self.touchHighlightDelay)
                    guard let self, !Task.isCancelled, self.touch.mode == .queue, self.touch.queueOriginY == nil else { return }
                    self.showQueueTouchSelection(at: self.touch.last)
                    try? await firstRowSleep(Self.touchHoldDelay - Self.touchHighlightDelay)
                    guard !Task.isCancelled, self.touch.mode == .queue, self.touch.queueOriginY == nil else { return }
                    self.touch.mode = .queueSelecting
                }
                return
            }
            // A finger on a list that's still moving stops it there, as a scroll view does.
            if let caughtList {
                state.mode = .scrolling
                state.level = caughtList.level
                state.scrollState = caughtList.scroll
                state.scrollStart = caughtList.offset
                state.scrollOriginY = point.y
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
            state.last = point
            state.lastTime = time
            state.samples.append((time, point.y))
            if let first = state.samples.first, time - first.time > 0.15 {
                state.samples.removeAll { time - $0.time > 0.12 }
            }
            let dx = point.x - state.start.x
            let dy = point.y - state.start.y
            switch state.mode {
            case let .button(control):
                // Held down only while the finger stays on it.
                let over = pointer.hitTester?.touchControl(at: point) == control
                pointer.hitTester?.highlightTouchControl(over ? control : nil)
            case .scrubbing:
                continueProgressDrag(at: point)
            case .queuePull:
                state.xSamples.append((time, point.x))
                if let first = state.xSamples.first, time - first.time > 0.15 {
                    state.xSamples.removeAll { time - $0.time > 0.12 }
                }
                if let geometry = pointer.hitTester?.nowPlayingQueueGeometry {
                    pullNowPlayingQueue(to: state.pullStartReveal + (state.pullOriginX - point.x) / geometry.travel)
                }
            case .queue:
                if state.queueOriginY == nil {
                    guard (dx * dx + dy * dy).squareRoot() > Self.touchSlop else { return }
                    state.holdTask?.cancel()
                    endQueueTouchSelection()
                    if abs(dx) > abs(dy) {
                        // Sideways: the list goes with the finger, back towards the edge.
                        beginNowPlayingQueuePull(at: point, time: time)
                        return
                    }
                    state.queueOriginY = point.y
                }
                scrollNowPlayingQueue(by: point.y - (state.queueOriginY ?? point.y))
            case .selecting:
                slideTouchSelection(to: point)
            case .queueSelecting:
                slideQueueTouchSelection(to: point)
            case .undecided:
                guard (dx * dx + dy * dy).squareRoot() > Self.touchSlop else { return }
                state.holdTask?.cancel()
                if isNowPlayingQueueVisible, abs(dx) > abs(dy), activeFullscreenScene?.key == musicNowPlayingFullscreenKey {
                    // Beside the list, a sideways drag moves it too.
                    beginNowPlayingQueuePull(at: point, time: time)
                    return
                }
                if abs(dx) > abs(dy) || !isMenuTouchContext {
                    state.mode = .swiping
                    endTouchSelection()
                } else if let scroll = state.scrollState, scroll.canScroll, let level = state.level {
                    state.mode = .scrolling
                    endTouchSelection()
                    state.scrollStart = pointer.pinnedScrollOffset(identity: scroll.identity) ?? scroll.scrollOffset
                    state.scrollOriginY = point.y
                    pointer.tracksFinger = true
                    scrollTouchList(level: level, by: 0)
                } else {
                    state.mode = .swiping
                }
            case .scrolling:
                if let level = state.level { scrollTouchList(level: level, by: point.y - state.scrollOriginY) }
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
            state.isFingerDown = false
            switch mode {
            case let .button(control):
                pointer.hitTester?.highlightTouchControl(nil)
                if pointer.hitTester?.touchControl(at: point) == control {
                    pressTouchControl(control)
                }
            case .scrubbing:
                finishProgressDrag(at: point)
            case .queuePull:
                state.xSamples.append((time, point.x))
                if abs(point.x - state.start.x) < Self.touchSlop, abs(point.y - state.start.y) < Self.touchSlop, !isNowPlayingQueueVisible {
                    // Only a tap by the edge.
                    settleNowPlayingQueue(open: false)
                    handleTouchTap(at: point, target: state.startTarget)
                } else {
                    finishNowPlayingQueuePull(velocity: releaseSidewaysVelocity(at: time))
                }
            case .queue:
                if state.queueOriginY == nil {
                    // A tap: a song, unless the finger only stopped the list moving.
                    if !state.queueWasMoving, let geometry = pointer.hitTester?.nowPlayingQueueGeometry,
                       let row = geometry.row(at: point, scroll: nowPlayingQueueScroll, count: nowPlayingQueueCount)
                    {
                        chooseNowPlayingQueueRow(row)
                    }
                } else {
                    state.samples.append((time, point.y))
                    releaseNowPlayingQueue(velocity: releaseVelocity(at: time))
                }
            case .queueSelecting:
                // Lifting over a song plays it; anywhere else lets it go.
                state.queueSelectionTarget = nil
                if let geometry = pointer.hitTester?.nowPlayingQueueGeometry, geometry.panel.contains(point),
                   let row = geometry.row(at: point, scroll: nowPlayingQueueScroll, count: nowPlayingQueueCount)
                {
                    chooseNowPlayingQueueRow(row)
                } else {
                    endQueueTouchSelection()
                }
            case .selecting:
                // Lifting over a row chooses it; anywhere else lets it go.
                if case let .menuRow(level, index)? = pointer.hitTester?.pointerTarget(at: point), level == pointerActiveListLevel {
                    chooseTouchRow(level: level, index: index)
                } else {
                    endTouchSelection()
                }
            case .scrolling:
                // Coasting on if the finger was still moving, and springing back if it left the
                // list pulled past an end.
                if let level = state.level {
                    state.samples.append((time, point.y))
                    releaseTouchList(level: level, velocity: releaseVelocity(at: time))
                } else {
                    pointer.tracksFinger = false
                }
            case .swiping:
                handleTouchSwipe(dx: dx, dy: dy, start: state.start)
            case .undecided:
                handleTouchTap(at: point, target: state.startTarget)
            case .ignored:
                break
            }
        }

        private func touchCancelled() {
            let state = touch
            state.holdTask?.cancel()
            state.isFingerDown = false
            state.selectionTarget = nil
            pointer.hitTester?.highlightTouchControl(nil)
            if state.mode == .scrubbing {
                finishProgressDrag(at: state.last)
            }
            if state.mode == .scrolling, let level = state.level {
                releaseTouchList(level: level, velocity: 0)
            }
            if state.mode == .queue, state.queueOriginY != nil {
                releaseNowPlayingQueue(velocity: 0)
            }
            if state.mode == .queuePull {
                finishNowPlayingQueuePull(velocity: 0)
            }
            if state.mode == .queue || state.mode == .queueSelecting {
                endQueueTouchSelection()
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
            touch.selectionTarget = nil
            // The row changes before the selection shows, so the first frame with a selection
            // has it under the finger rather than on the row chosen last time.
            if index != pointerSelectionIndex(for: level) {
                selectRowFromPointer(level: level, index: index, touchSliding: true)
            } else if let scroll = pointer.hitTester?.menuListScrollState(level) {
                // Keep the list still under the finger.
                pointer.pin = (scroll.identity, scroll.scrollOffset)
            }
            isTouchSelecting = true
        }

        /// The selection follows the finger to whichever visible row it is over, a row a frame,
        /// so a quick slide still lights up every row on the way.
        private func slideTouchSelection(to point: CGPoint) {
            guard let level = touch.level, level == pointerActiveListLevel,
                  case let .menuRow(rowLevel, index)? = pointer.hitTester?.pointerTarget(at: point), rowLevel == level
            else { return }
            if !isTouchSelecting { isTouchSelecting = true }
            touch.selectionTarget = index != pointerSelectionIndex(for: level) ? (level, index) : nil
            startTouchClock()
        }

        /// Moves the selection one row nearer the finger's. Returns whether rows remain.
        private func stepTouchSelection() -> Bool {
            guard let target = touch.selectionTarget else { return false }
            guard target.level == pointerActiveListLevel, isMenuTouchContext else {
                touch.selectionTarget = nil
                return false
            }
            let current = pointerSelectionIndex(for: target.level)
            guard current != target.index else {
                touch.selectionTarget = nil
                return false
            }
            let next = current + (target.index > current ? 1 : -1)
            selectRowFromPointer(level: target.level, index: next)
            #if DEBUG || FIRSTROW_HARNESS_BUILD
                FirstRowHarness.touchLog(String(format: "[touch] row %d (finger on %d) at %.3f", next, target.index, CACurrentMediaTime()))
            #endif
            guard next != target.index, pointerSelectionIndex(for: target.level) == next else {
                touch.selectionTarget = nil
                return false
            }
            return true
        }

        private func endTouchSelection() {
            touch.selectionTarget = nil
            if isTouchSelecting { isTouchSelecting = false }
            flushTouchPreviewRefresh()
        }

        private func chooseTouchRow(level: MenuListLevel, index: Int) {
            touch.selectionTarget = nil
            if index != pointerSelectionIndex(for: level) {
                selectRowFromPointer(level: level, index: index)
            }
            // The list stays where it is, as it goes and when it comes back.
            pointer.tracksFinger = false
            endTouchSelection()
            pressTouchKey(.enter)
        }

        /// While a finger slides through the rows, the preview for each row it passes waits
        /// until the selection rests, so passing rows costs no more than drawing them.
        func deferTouchPreviewRefresh(_ refresh: @escaping @MainActor () -> Void) {
            touch.previewRefresh?.cancel()
            touch.previewRefresh = Task { @MainActor [weak self] in
                try? await firstRowSleep(0.12)
                guard let self, !Task.isCancelled else { return }
                self.touch.previewRefresh = nil
                self.touch.pendingPreview = nil
                refresh()
            }
            touch.pendingPreview = refresh
        }

        /// Runs a put-off preview change now.
        private func flushTouchPreviewRefresh() {
            guard let refresh = touch.pendingPreview, let task = touch.previewRefresh else { return }
            task.cancel()
            touch.previewRefresh = nil
            touch.pendingPreview = nil
            refresh()
        }

        // MARK: - Frames

        private func startTouchClock() {
            let clock = touch.clock
            if clock.onFrame == nil {
                clock.onFrame = { [weak self] seconds in
                    self?.touchFrame(seconds) ?? false
                }
            }
            clock.run()
        }

        /// One frame: the selection steps towards the finger and a moving list moves on.
        /// Returns whether more frames are wanted.
        private func touchFrame(_ seconds: Double) -> Bool {
            var wantsMore = touch.isFingerDown
            if stepTouchSelection() { wantsMore = true }
            if stepQueueTouchSelection() { wantsMore = true }
            if var motion = touch.queueMotion {
                if isNowPlayingQueueVisible {
                    let moving = motion.advance(seconds)
                    nowPlayingQueueScroll = -motion.offset
                    touch.queueMotion = moving ? motion : nil
                    if moving { wantsMore = true }
                } else {
                    touch.queueMotion = nil
                }
            }
            if var motion = touch.motion {
                guard isMenuTouchContext, motion.level == pointerActiveListLevel,
                      let scroll = pointer.hitTester?.menuListScrollState(motion.level), scroll.identity == motion.identity
                else {
                    #if DEBUG || FIRSTROW_HARNESS_BUILD
                        FirstRowHarness.touchLog("[touch] list motion dropped: the list changed")
                    #endif
                    touch.motion = nil
                    return wantsMore
                }
                let moving = motion.advance(seconds)
                setTouchScroll(scroll, offset: motion.offset)
                touch.motion = moving ? motion : nil
                #if DEBUG || FIRSTROW_HARNESS_BUILD
                    if !moving {
                        FirstRowHarness.touchLog(String(format: "[touch] came to rest at %.1f after %.2f s", motion.offset, CACurrentMediaTime() - touch.motionStarted))
                    }
                #endif
                if moving { wantsMore = true }
            }
            return wantsMore
        }

        /// The finger's speed as it let go, in window points a second, from its last tenth of a
        /// second; nothing if it had stopped before lifting.
        private func releaseVelocity(at time: TimeInterval) -> CGFloat {
            let recent = touch.samples.filter { time - $0.time <= 0.1 }
            guard let first = recent.first, let last = recent.last, last.time - first.time > 0.008 else { return 0 }
            let stillFor = time - (recent.last { abs($0.y - last.y) > 0.5 }?.time ?? first.time)
            if stillFor > 0.07 { return 0 }
            return (last.y - first.y) / CGFloat(last.time - first.time)
        }

        /// Moves a long list with the finger, `dy` window points from where the drag started.
        /// Past either end it keeps following, but less and less, as a scroll view does.
        private func scrollTouchList(level _: MenuListLevel, by dy: CGFloat) {
            guard let scroll = touch.scrollState else { return }
            let scale = max(0.0001, scroll.rowPitchInWindow / max(1, scroll.rowPitch))
            var offset = touch.scrollStart + dy / scale
            if offset > 0 {
                offset = Self.band(offset)
            } else if offset < scroll.minScrollOffset {
                offset = scroll.minScrollOffset - Self.band(scroll.minScrollOffset - offset)
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

        private static let bandReach: CGFloat = 700

        /// How far a list goes when pulled `past` scene points beyond an end: less and less.
        private static func band(_ past: CGFloat) -> CGFloat {
            (1 - 1 / (past * 0.55 / bandReach + 1)) * bandReach
        }

        /// The pull that leaves a list `shown` scene points beyond an end.
        private static func unband(_ shown: CGFloat) -> CGFloat {
            let clamped = min(shown, bandReach * 0.98)
            return (bandReach / (bandReach - clamped) - 1) * bandReach / 0.55
        }

        /// Stops a list that is still moving where it is, for a finger landing on it, and
        /// returns where the drag carries on from (unbanded, if it was past an end).
        private func catchCoastingList() -> (level: MenuListLevel, scroll: MenuListScrollState, offset: CGFloat)? {
            guard let motion = touch.motion else { return nil }
            touch.motion = nil
            guard isMenuTouchContext, motion.level == pointerActiveListLevel,
                  let scroll = pointer.hitTester?.menuListScrollState(motion.level), scroll.identity == motion.identity
            else { return nil }
            // A list that has all but stopped is let go of where it rests, and the touch counts
            // as a touch on the rows rather than a catch.
            let pointsPerSecond = abs(motion.velocity) / motion.scenePerPoint
            let pointsPastEnd = max(0, motion.offset - motion.upper, motion.lower - motion.offset) / motion.scenePerPoint
            #if DEBUG || FIRSTROW_HARNESS_BUILD
                FirstRowHarness.touchLog(String(format: "[touch] finger on the list at %.1f moving %.0f pt/s, %.1f pt past an end", motion.offset, pointsPerSecond, pointsPastEnd))
            #endif
            guard pointsPerSecond > 20 || pointsPastEnd > 1 else {
                setTouchScroll(scroll, offset: min(motion.upper, max(motion.lower, motion.offset)))
                return nil
            }
            pointer.tracksFinger = true
            var offset = motion.offset
            if offset > 0 {
                offset = Self.unband(offset)
            } else if offset < scroll.minScrollOffset {
                offset = scroll.minScrollOffset - Self.unband(scroll.minScrollOffset - offset)
            }
            return (motion.level, scroll, offset)
        }

        /// Lets a list go: a flick coasts on and slowly comes to a stop, running into an end
        /// carries it a little past and back, and a list pulled past an end springs back.
        /// `velocity` is the finger's, in window points a second.
        private func releaseTouchList(level: MenuListLevel, velocity: CGFloat) {
            guard let scroll = pointer.hitTester?.menuListScrollState(level),
                  let current = pointer.pinnedScrollOffset(identity: scroll.identity)
            else {
                pointer.tracksFinger = false
                return
            }
            let scenePerPoint = max(1, scroll.rowPitch) / max(0.0001, scroll.rowPitchInWindow)
            let motion = TouchListMotion(
                level: level,
                identity: scroll.identity,
                offset: current,
                velocity: velocity * scenePerPoint,
                lower: scroll.minScrollOffset,
                upper: 0,
                scenePerPoint: scenePerPoint,
            )
            #if DEBUG || FIRSTROW_HARNESS_BUILD
                FirstRowHarness.touchLog(String(format: "[touch] let go at %.0f, %.0f pt/s%@", current, velocity, motion.isWorthMoving ? "" : " (stays)"))
            #endif
            guard motion.isWorthMoving else { return }
            touch.motion = motion
            touch.motionStarted = CACurrentMediaTime()
            startTouchClock()
        }

        // MARK: - Buttons

        private func pressTouchControl(_ control: TouchControl) {
            pressOnScreenControl(control)
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
                if scene.key == musicNowPlayingFullscreenKey {
                    // A tap beside the list puts it away; anywhere else it brings the buttons
                    // back, or keeps them up. Only the play button plays and pauses.
                    if isNowPlayingQueueVisible {
                        hideNowPlayingQueue()
                    } else {
                        showNowPlayingTouchControls()
                    }
                } else if scene.key == photoSlideshowFullscreenKey {
                    // As on a movie: a tap shows or hides Back.
                    toggleSlideshowControls()
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

        /// Now Playing's own swipes: in from the right edge for its list (and back out to the
        /// right), up for its buttons and down to put them away. Returns whether it took it.
        private func handleNowPlayingSwipe(dx: CGFloat, dy: CGFloat, start: CGPoint) -> Bool {
            let sideways = abs(dx) > abs(dy) * 1.5 && abs(dx) > Self.touchSwipeDistance
            let upright = abs(dy) > abs(dx) * 1.5 && abs(dy) > Self.touchSwipeDistance * 0.7
            if sideways {
                if isNowPlayingQueueVisible {
                    if dx > 0 { hideNowPlayingQueue() }
                    return true
                }
                if dx < 0, let geometry = pointer.hitTester?.nowPlayingQueueGeometry, geometry.edgeZone.contains(start) {
                    showNowPlayingQueue()
                    return true
                }
                return false
            }
            if upright, !isNowPlayingQueueVisible {
                if dy < 0 {
                    showNowPlayingTouchControls()
                } else if isMusicPlaybackRunningOrStarting() {
                    hideNowPlayingTouchControls()
                }
                return true
            }
            return false
        }

        private func beginNowPlayingQueuePull(at point: CGPoint, time: TimeInterval) {
            let state = touch
            state.mode = .queuePull
            state.queueMotion = nil
            state.pullStartReveal = nowPlayingQueueReveal
            state.pullOriginX = point.x
            state.xSamples = [(time, point.x)]
        }

        /// The thumb let go of the list: out if it was pulled far enough or flicked out, back
        /// if not or flicked back.
        private func finishNowPlayingQueuePull(velocity: CGFloat) {
            let wasOpen = isNowPlayingQueueVisible
            let open: Bool = if velocity < -350 {
                true
            } else if velocity > 350 {
                false
            } else {
                nowPlayingQueueReveal > 0.5
            }
            #if DEBUG || FIRSTROW_HARNESS_BUILD
                FirstRowHarness.touchLog(String(format: "[touch] list let go at %.2f, %.0f pt/s: %@", nowPlayingQueueReveal, velocity, open ? "out" : "back"))
            #endif
            if open, !wasOpen { playSound(named: "SelectionChange") }
            settleNowPlayingQueue(open: open)
        }

        /// The finger's sideways speed as it let go, in window points a second.
        private func releaseSidewaysVelocity(at time: TimeInterval) -> CGFloat {
            let recent = touch.xSamples.filter { time - $0.time <= 0.1 }
            guard let first = recent.first, let last = recent.last, last.time - first.time > 0.008 else { return 0 }
            return (last.x - first.x) / CGFloat(last.time - first.time)
        }

        /// Drags Now Playing's list, `dy` window points from where the drag started, past its
        /// ends less and less.
        private func scrollNowPlayingQueue(by dy: CGFloat) {
            guard let geometry = pointer.hitTester?.nowPlayingQueueGeometry else { return }
            var scroll = touch.queueStartScroll - dy * geometry.canvasPerPoint
            if scroll < 0 {
                scroll = -Self.band(-scroll)
            } else if scroll > geometry.scrollLimit {
                scroll = geometry.scrollLimit + Self.band(scroll - geometry.scrollLimit)
            }
            nowPlayingQueueScroll = scroll
        }

        /// Picks out the song under the finger in Now Playing's list.
        private func showQueueTouchSelection(at point: CGPoint) {
            guard let geometry = pointer.hitTester?.nowPlayingQueueGeometry,
                  let row = geometry.row(at: point, scroll: nowPlayingQueueScroll, count: nowPlayingQueueCount),
                  row != nowPlayingQueueHoverIndex
            else { return }
            touch.queueSelectionTarget = nil
            nowPlayingQueueHoverIndex = row
            playSound(named: "SelectionChange")
        }

        /// The selection follows the finger through Now Playing's list, a row a frame, so a
        /// quick slide still picks out every song on the way.
        private func slideQueueTouchSelection(to point: CGPoint) {
            guard let geometry = pointer.hitTester?.nowPlayingQueueGeometry, geometry.panel.contains(point),
                  let row = geometry.row(at: point, scroll: nowPlayingQueueScroll, count: nowPlayingQueueCount)
            else { return }
            if nowPlayingQueueHoverIndex == nil {
                showQueueTouchSelection(at: point)
                return
            }
            touch.queueSelectionTarget = row != nowPlayingQueueHoverIndex ? row : nil
            startTouchClock()
        }

        /// Moves the list's selection one row nearer the finger's. Returns whether rows remain.
        private func stepQueueTouchSelection() -> Bool {
            guard let target = touch.queueSelectionTarget else { return false }
            guard isNowPlayingQueueVisible, let current = nowPlayingQueueHoverIndex, current != target else {
                touch.queueSelectionTarget = nil
                return false
            }
            let next = current + (target > current ? 1 : -1)
            nowPlayingQueueHoverIndex = next
            playSound(named: "SelectionChange")
            guard next != target else {
                touch.queueSelectionTarget = nil
                return false
            }
            return true
        }

        /// The finger left Now Playing's list without choosing: nothing stays picked out.
        private func endQueueTouchSelection() {
            touch.queueSelectionTarget = nil
            if nowPlayingQueueHoverIndex != nil { nowPlayingQueueHoverIndex = nil }
        }

        /// Lets Now Playing's list go, coasting or springing back as the menus' lists do.
        private func releaseNowPlayingQueue(velocity: CGFloat) {
            guard let geometry = pointer.hitTester?.nowPlayingQueueGeometry else { return }
            let motion = TouchListMotion(
                level: .third,
                identity: "now-playing-list",
                offset: -nowPlayingQueueScroll,
                velocity: velocity * geometry.canvasPerPoint,
                lower: -geometry.scrollLimit,
                upper: 0,
                scenePerPoint: geometry.canvasPerPoint,
            )
            guard motion.isWorthMoving else { return }
            touch.queueMotion = motion
            startTouchClock()
        }

        private func handleMovieTouchTap(at point: CGPoint) {
            guard !isMovieTransitioning, moviePlayer != nil else { return }
            // The options button above the bar opens or closes the panel.
            if pointer.hitTester?.movieOptionsButton(at: point) != nil {
                toggleMovieOptions()
                return
            }
            if movieOptions != nil {
                guard let hit = pointer.hitTester?.movieOptionsRow(at: point) else {
                    closeMovieOptions()
                    return
                }
                // A tap changes the row it lands on: on its "‹" back a value, anywhere else
                // on to the next one, round to the first after the last.
                chooseMovieOptionRow(hit.index, backward: hit.backward)
                return
            }
            // A tap away from the buttons shows or hides the controls; playing and pausing is
            // the play button's job.
            if areMovieControlsVisible {
                cancelMovieControlsAutoHide()
                hideMovieControlsWithFade()
            } else {
                showMovieControlsInstantly()
                scheduleMovieControlsAutoHide()
            }
        }

        private func handleTouchSwipe(dx: CGFloat, dy: CGFloat, start: CGPoint) {
            let startX = start.x
            let fromEdge = startX < Self.touchEdgeWidth
            if activeFullscreenScene?.key == musicNowPlayingFullscreenKey, handleNowPlayingSwipe(dx: dx, dy: dy, start: start) {
                return
            }
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
