import Foundation
#if os(tvOS)
    import UIKit

    /// A swipe on the Siri Remote's touch surface, as it goes.
    @MainActor
    final class RemoteSwipeState {
        enum Mode {
            /// Not yet moved far enough to say which way it's going.
            case undecided
            /// Up and down through a list, a row for each stretch of the swipe.
            case stepping
            /// Anything else: one arrow press when the finger lifts.
            case gesture
        }

        var mode: Mode = .undecided
        /// When a button of the remote was last pressed. A press during a touch, or just
        /// before it ends, means the thumb slid as it pressed: not a swipe.
        var lastPressAt = Date.distantPast
        /// How much of the swipe has been turned into steps (positive is down).
        var consumed: CGFloat = 0
        /// How far the swipe has gone past the end of the list.
        var overshoot: CGFloat = 0
        var momentum: Task<Void, Never>?
    }

    /// Siri Remote swipes, as on Apple TV: in a list, the selection follows the finger a row at a
    /// time and carries on a few rows after a quick flick; at the end of the list only the
    /// selected row gives a little in the direction of the swipe, and settles back when it lets
    /// go. Elsewhere a swipe is one press of the arrow it points along.
    extension MenuView {
        /// How far a swipe goes for each row (in the remote's touch points).
        private static let remoteSwipeStep: CGFloat = 150
        private static let remoteSwipeSlop: CGFloat = 24
        /// How far a swipe has to go, across or up and down, to count as a press of an arrow.
        /// (The surface is some 1900 points across and 1100 tall. A thumb settling on it, or
        /// sliding as it clicks, moves a good deal more than the slop.)
        private static let remoteSwipeAcross: CGFloat = 300
        private static let remoteSwipeUpOrDown: CGFloat = 170
        /// How quickly a flick dies away once the finger lifts (its speed falls to a third in
        /// this long, in seconds).
        private static let remoteFlickDecay: Double = 0.25

        /// Notes a press of one of the remote's buttons (see `RemoteSwipeState.lastPressAt`).
        func noteRemotePress() {
            remoteSwipe.lastPressAt = Date()
        }

        private var remotePressedLately: Bool {
            Date().timeIntervalSince(remoteSwipe.lastPressAt) < 0.7
        }
        /// How far the selected row gives at most, in scene points.
        private static let remoteRubberBandReach: CGFloat = 26

        func handleRemotePan(_ state: UIGestureRecognizer.State, translation: CGPoint, velocity: CGPoint) {
            let swipe = remoteSwipe
            switch state {
            case .began:
                swipe.momentum?.cancel()
                swipe.momentum = nil
                swipe.mode = .undecided
                swipe.consumed = 0
                swipe.overshoot = 0
                registerUserInteractionForScreenSaver()
            case .changed:
                remoteSwipeMoved(translation)
            case .ended:
                remoteSwipeEnded(translation: translation, velocity: velocity)
            default:
                remoteSwipeEnded(translation: translation, velocity: .zero)
            }
        }

        /// A list the arrows step through, where a swipe moves the selection along.
        private var remoteSwipeSteppingList: Bool {
            if activeFullscreenScene?.key == musicNowPlayingFullscreenKey { return isNowPlayingQueueVisible }
            return activeFullscreenScene == nil && !isMoviePlaybackVisible && textEntry == nil && codeDisplay == nil &&
                !isMovieResumePromptVisible && pointerActiveListLevel != nil && !isPointerInputPaused
        }

        private func remoteSwipeMoved(_ translation: CGPoint) {
            let swipe = remoteSwipe
            if swipe.mode == .undecided {
                guard max(abs(translation.x), abs(translation.y)) > Self.remoteSwipeSlop else { return }
                swipe.mode = abs(translation.y) > abs(translation.x) && remoteSwipeSteppingList ? .stepping : .gesture
            }
            guard swipe.mode == .stepping, !remotePressedLately else { return }
            // A row for each stretch of the swipe, past the first nudge.
            var travel = translation.y - swipe.consumed
            while abs(travel) >= Self.remoteSwipeStep {
                let direction = travel > 0 ? 1 : -1
                if stepRemoteSwipe(direction: direction) {
                    swipe.consumed += CGFloat(direction) * Self.remoteSwipeStep
                    swipe.overshoot = 0
                    travel = translation.y - swipe.consumed
                } else {
                    break
                }
            }
            // Pushing on at the end of the list: the selected row gives a little, no more.
            if !canStepRemoteSwipe(direction: travel > 0 ? 1 : -1), abs(travel) > 0 {
                swipe.overshoot = travel
                setRemoteRubberBand(Self.rubberBand(travel), animation: .smooth(duration: 0.12))
            } else if remoteRubberBand != 0 {
                setRemoteRubberBand(0, animation: .smooth(duration: 0.2))
            }
        }

        private func remoteSwipeEnded(translation: CGPoint, velocity: CGPoint) {
            let swipe = remoteSwipe
            defer {
                swipe.mode = .undecided
                swipe.overshoot = 0
            }
            switch swipe.mode {
            case .undecided:
                return
            case .gesture:
                // One press of the arrow the swipe points along: for a stroke of some length,
                // mostly along that axis, with no button pressed meanwhile.
                let horizontal = abs(translation.x) > abs(translation.y)
                let along = horizontal ? abs(translation.x) : abs(translation.y)
                let aside = horizontal ? abs(translation.y) : abs(translation.x)
                guard along >= (horizontal ? Self.remoteSwipeAcross : Self.remoteSwipeUpOrDown), aside <= along * 0.6, !remotePressedLately else { return }
                let key: KeyCode = horizontal ? (translation.x > 0 ? .rightArrow : .leftArrow) : (translation.y > 0 ? .downArrow : .upArrow)
                handleKeyDown(key)
                handleKeyUp(key)
            case .stepping:
                // Let go at the end: the row settles back.
                if remoteRubberBand != 0 {
                    setRemoteRubberBand(0, animation: .smooth(duration: 0.38))
                }
                // A quick flick carries on a few more rows, slowing as it goes: the rows the
                // swipe's speed would cover as it died away (over a quarter of a second), left
                // off once they'd come slower than seven a second. So it's over in half a
                // second however fast the flick, and never crawls to its last row (a fast one
                // took nearly three seconds to come to rest, its last rows half a second apart).
                let speed = abs(velocity.y)
                guard speed > 700 else { return }
                let direction = velocity.y > 0 ? 1 : -1
                let reach = Double(speed) * Self.remoteFlickDecay / Double(Self.remoteSwipeStep)
                var times: [Double] = []
                while Double(times.count + 1) < reach, times.count < 14 {
                    let time = -Self.remoteFlickDecay * log(1 - Double(times.count + 1) / reach)
                    guard time - (times.last ?? 0) <= 0.14 else { break }
                    times.append(time)
                }
                guard !times.isEmpty else { return }
                swipe.momentum = Task { @MainActor [weak self] in
                    var elapsed = 0.0
                    for time in times {
                        try? await firstRowSleep(time - elapsed)
                        elapsed = time
                        guard let self, !Task.isCancelled, self.remoteSwipeSteppingList else { return }
                        guard self.stepRemoteSwipe(direction: direction) else {
                            // Ran into the end: the selected row gives, and settles back.
                            self.setRemoteRubberBand(Self.rubberBand(CGFloat(direction) * Self.remoteSwipeStep * 0.6), animation: .smooth(duration: 0.12))
                            try? await firstRowSleep(0.12)
                            self.setRemoteRubberBand(0, animation: .smooth(duration: 0.4))
                            return
                        }
                    }
                }
            }
        }

        // MARK: - Play/Pause

        /// Whether a play or pause that has just come in is to be acted on. The remote's
        /// Play/Pause button can reach First Row as a press and as the system's media command
        /// too. If it does, the first of the two acts, and the other, coming straight after
        /// from the other side, is the same press: acted on as well, it would undo the first.
        func takesPlayPause(fromRemotePress: Bool) -> Bool {
            let now = Date()
            if let last = lastPlayPause, last.fromRemotePress != fromRemotePress, now.timeIntervalSince(last.date) < 0.75 {
                lastPlayPause = nil
                return false
            }
            lastPlayPause = (now, fromRemotePress)
            return true
        }

        // MARK: - Holding Select

        /// Select going down on the remote. In Now Playing a click does what Select does
        /// there, on its way up; held, it brings the song list out or puts it away, which the
        /// remote's TV button does on a Mac and can't here, where that button is the system's.
        /// Returns false anywhere else: Select acts as it goes down.
        func remoteSelectBegan() -> Bool {
            guard activeFullscreenScene?.key == musicNowPlayingFullscreenKey, !isFullscreenSceneTransitioning, !isTextEntryActive else { return false }
            remoteSelectHold?.cancel()
            remoteSelectIsDown = true
            remoteSelectHold = Task { @MainActor in
                try? await firstRowSleep(0.55)
                guard !Task.isCancelled, self.remoteSelectIsDown else { return }
                self.remoteSelectIsDown = false
                self.handleRemoteTVButton()
            }
            return true
        }

        func remoteSelectEnded() {
            remoteSelectHold?.cancel()
            remoteSelectHold = nil
            guard remoteSelectIsDown else { return }
            remoteSelectIsDown = false
            handleKeyDown(.enter)
        }

        /// The selected row's give for a push of `overshoot` past the end: a little at first,
        /// never more than `remoteRubberBandReach`.
        private static func rubberBand(_ overshoot: CGFloat) -> CGFloat {
            let reach = remoteRubberBandReach
            let amount = reach * (1 - exp(-abs(overshoot) / 220))
            return overshoot < 0 ? -amount : amount
        }

        private func setRemoteRubberBand(_ value: CGFloat, animation: Animation) {
            guard abs(value - remoteRubberBand) > 0.1 || (value == 0 && remoteRubberBand != 0) else { return }
            withAnimation(animation) {
                remoteRubberBand = value
            }
        }

        /// Whether the selection can move one row (positive is down) in the list being swiped.
        private func canStepRemoteSwipe(direction: Int) -> Bool {
            if isNowPlayingQueueVisible, activeFullscreenScene?.key == musicNowPlayingFullscreenKey {
                let current = nowPlayingQueueHoverIndex ?? nowPlayingQueueActiveIndex ?? 0
                return nowPlayingQueueHoverIndex == nil || (current + direction >= 0 && current + direction < nowPlayingQueueCount)
            }
            guard let level = pointerActiveListLevel else { return false }
            let next = pointerSelectionIndex(for: level) + direction
            return next >= 0 && next < pointerListItemCount(for: level)
        }

        /// Moves the selection one row (straight there, however quick the swipe: the arrows'
        /// own pacing would drop steps). Returns false at the end of the list.
        @discardableResult
        private func stepRemoteSwipe(direction: Int) -> Bool {
            guard canStepRemoteSwipe(direction: direction) else { return false }
            if isNowPlayingQueueVisible, activeFullscreenScene?.key == musicNowPlayingFullscreenKey {
                moveNowPlayingQueueFocus(by: direction)
                return true
            }
            guard let level = pointerActiveListLevel else { return false }
            selectRowFromPointer(level: level, index: pointerSelectionIndex(for: level) + direction, pinsList: false)
            return true
        }
    }

    /// Listens for swipes on the Siri Remote's touch surface (not on the screen: tvOS has none).
    final class RemoteSwipeRecognizer: NSObject {
        private let onPan: @MainActor (UIGestureRecognizer.State, CGPoint, CGPoint) -> Void
        private(set) var recognizer: UIPanGestureRecognizer!

        init(onPan: @escaping @MainActor (UIGestureRecognizer.State, CGPoint, CGPoint) -> Void) {
            self.onPan = onPan
            super.init()
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            pan.cancelsTouchesInView = false
            recognizer = pan
        }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            let view = pan.view
            let translation = pan.translation(in: view)
            let velocity = pan.velocity(in: view)
            let state = pan.state
            MainActor.assumeIsolatedIfPossible {
                self.onPan(state, translation, velocity)
            }
        }
    }
#endif
