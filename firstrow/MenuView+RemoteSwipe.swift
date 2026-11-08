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
            guard swipe.mode == .stepping else { return }
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
                // One press of the arrow the swipe points along.
                let horizontal = abs(translation.x) > abs(translation.y)
                let key: KeyCode = horizontal ? (translation.x > 0 ? .rightArrow : .leftArrow) : (translation.y > 0 ? .downArrow : .upArrow)
                handleKeyDown(key)
                handleKeyUp(key)
            case .stepping:
                // Let go at the end: the row settles back.
                if remoteRubberBand != 0 {
                    setRemoteRubberBand(0, animation: .smooth(duration: 0.38))
                }
                // A quick flick carries on a few more rows, slowing as it goes.
                let speed = abs(velocity.y)
                guard speed > 700 else { return }
                let direction = velocity.y > 0 ? 1 : -1
                let rows = min(12, Int(speed / 650))
                swipe.momentum = Task { @MainActor [weak self] in
                    var interval = 0.06
                    for _ in 0 ..< rows {
                        try? await firstRowSleep(interval)
                        guard let self, !Task.isCancelled, self.remoteSwipeSteppingList else { return }
                        guard self.stepRemoteSwipe(direction: direction) else {
                            // Ran into the end: the selected row gives, and settles back.
                            self.setRemoteRubberBand(Self.rubberBand(CGFloat(direction) * Self.remoteSwipeStep * 0.6), animation: .smooth(duration: 0.12))
                            try? await firstRowSleep(0.12)
                            self.setRemoteRubberBand(0, animation: .smooth(duration: 0.4))
                            return
                        }
                        interval *= 1.22
                    }
                }
            }
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
