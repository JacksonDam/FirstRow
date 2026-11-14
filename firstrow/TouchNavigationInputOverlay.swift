#if os(iOS)
    import UIKit

    /// Passes one finger on as it moves (see MenuView+Touch.swift). A second finger lets the
    /// first go.
    final class TouchNavigationInputView: UIView {
        /// One finger's movements, in this view's points.
        var onTouch: ((TouchPhase, CGPoint, TimeInterval) -> Void)?
        private var trackedTouch: UITouch?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isMultipleTouchEnabled = true
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            let fingers = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? touches.count
            if fingers > 1 {
                // A second finger: let the first go.
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
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            onTouch?(.moved, tracked.location(in: self), tracked.timestamp)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            trackedTouch = nil
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
            onTouch?(phase, point, ProcessInfo.processInfo.systemUptime)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }
    }
#endif
