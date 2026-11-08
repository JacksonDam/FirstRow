#if os(iOS)
    import UIKit

    /// Touch controls: hold a screen quarter for an arrow, 2 fingers select, 3 go back, 4 play/pause.
    /// With Settings > Touch Controls on, one finger is passed on as it moves instead (see
    /// MenuView+Touch.swift), and the quarter taps and holds stand aside.
    final class TouchNavigationInputView: UIView {
        var onArrowKeyDown: ((KeyCode) -> Void)?
        var onArrowKeyUp: ((KeyCode) -> Void)?
        var onEnter: (() -> Void)?
        var onBackspace: (() -> Void)?
        var onSpace: (() -> Void)?
        var onSingleFingerTap: (() -> Bool)?
        /// Direct touch: one finger's movements, in this view's points.
        var onTouch: ((TouchPhase, CGPoint, TimeInterval) -> Void)? {
            didSet { updateSingleFingerRecognizers() }
        }
        private var activeHoldArrowKey: KeyCode?
        private var trackedTouch: UITouch?
        private var singleFingerRecognizers: [UIGestureRecognizer] = []
        private var multiFingerRecognizers: [UIGestureRecognizer] = []

        private var usesDirectTouch: Bool {
            AppSettings.isTouchEnabled && onTouch != nil
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isMultipleTouchEnabled = true
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let twoFingerTap = tap(touches: 2, action: #selector(handleTwoFingerTap(_:)))
            let threeFingerTap = tap(touches: 3, action: #selector(handleThreeFingerTap(_:)))
            let fourFingerTap = tap(touches: 4, action: #selector(handleFourFingerTap(_:)))
            threeFingerTap.require(toFail: fourFingerTap)
            twoFingerTap.require(toFail: threeFingerTap)
            twoFingerTap.require(toFail: fourFingerTap)
            let singleFingerTap = tap(touches: 1, action: #selector(handleSingleFingerTap(_:)))
            let singleFingerHold = UILongPressGestureRecognizer(target: self, action: #selector(handleSingleFingerHold(_:)))
            singleFingerHold.minimumPressDuration = 0.24
            singleFingerHold.numberOfTouchesRequired = 1
            singleFingerHold.cancelsTouchesInView = false
            addGestureRecognizer(singleFingerHold)
            singleFingerTap.require(toFail: twoFingerTap)
            singleFingerTap.require(toFail: threeFingerTap)
            singleFingerTap.require(toFail: fourFingerTap)
            singleFingerTap.require(toFail: singleFingerHold)
            singleFingerRecognizers = [singleFingerTap, singleFingerHold]
            multiFingerRecognizers = [twoFingerTap, threeFingerTap, fourFingerTap]
            updateSingleFingerRecognizers()
            settingsObserver = NotificationCenter.default.addObserver(forName: AppSettings.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible { self?.updateSingleFingerRecognizers() }
            }
        }

        private var settingsObserver: NSObjectProtocol?

        /// The quarter taps and holds are switched off outright while direct touch is on, so a
        /// slide or swipe can never also press an arrow.
        private func updateSingleFingerRecognizers() {
            let enabled = !usesDirectTouch
            // Touch mode has buttons for these, so the multi-finger taps are off too.
            for recognizer in singleFingerRecognizers + multiFingerRecognizers where recognizer.isEnabled != enabled {
                recognizer.isEnabled = enabled
            }
            if !enabled, let key = activeHoldArrowKey {
                activeHoldArrowKey = nil
                onArrowKeyUp?(key)
            }
        }

        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            !(usesDirectTouch && singleFingerRecognizers.contains(recognizer))
        }

        // MARK: - Direct touch

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            guard usesDirectTouch else { return }
            let fingers = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? touches.count
            if fingers > 1 {
                // A second finger means one of the multi-finger taps: let the first go.
                if let tracked = trackedTouch {
                    trackedTouch = nil
                    onTouch?(.cancelled, tracked.location(in: self), tracked.timestamp)
                }
                return
            }
            guard trackedTouch == nil, let touch = touches.first else { return }
            trackedTouch = touch
            onTouch?(.began, touch.location(in: self), touch.timestamp)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            guard usesDirectTouch, let tracked = trackedTouch, touches.contains(tracked) else { return }
            onTouch?(.moved, tracked.location(in: self), tracked.timestamp)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            trackedTouch = nil
            guard usesDirectTouch else { return }
            onTouch?(.ended, tracked.location(in: self), tracked.timestamp)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            trackedTouch = nil
            onTouch?(.cancelled, tracked.location(in: self), tracked.timestamp)
        }

        /// For the test harness: a touch as if from a finger at `point`.
        func injectTouch(_ phase: TouchPhase, at point: CGPoint) {
            guard usesDirectTouch else { return }
            onTouch?(phase, point, ProcessInfo.processInfo.systemUptime)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        private func tap(touches: Int, action: Selector) -> UITapGestureRecognizer {
            let recognizer = UITapGestureRecognizer(target: self, action: action)
            recognizer.numberOfTapsRequired = 1
            recognizer.numberOfTouchesRequired = touches
            recognizer.cancelsTouchesInView = false
            addGestureRecognizer(recognizer)
            return recognizer
        }

        private func arrowKey(for gesture: UIGestureRecognizer) -> KeyCode? {
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let point = gesture.location(in: self)
            let isTopHalf = point.y < bounds.midY
            let isLeftHalf = point.x < bounds.midX
            if isTopHalf {
                return isLeftHalf ? .upArrow : .downArrow
            }
            return isLeftHalf ? .leftArrow : .rightArrow
        }

        @objc private func handleSingleFingerTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, !usesDirectTouch else { return }
            if onSingleFingerTap?() == true { return }
            guard let key = arrowKey(for: gesture) else { return }
            onArrowKeyDown?(key)
            onArrowKeyUp?(key)
        }

        @objc private func handleSingleFingerHold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                guard !usesDirectTouch, let key = arrowKey(for: gesture) else { return }
                activeHoldArrowKey = key
                onArrowKeyDown?(key)
            case .ended, .cancelled, .failed:
                if let key = activeHoldArrowKey { onArrowKeyUp?(key) }
                activeHoldArrowKey = nil
            default:
                break
            }
        }

        @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { onEnter?() }
        }

        @objc private func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { onBackspace?() }
        }

        @objc private func handleFourFingerTap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { onSpace?() }
        }
    }
#endif
