#if os(iOS)
    import UIKit

    /// Touch controls on iPhone and iPad: tap or hold a quarter of the screen for an arrow
    /// (top left up, top right down, bottom left left, bottom right right), two fingers to
    /// select, three to go back and four to play or pause.
    final class TouchNavigationInputView: UIView {
        var onArrowKeyDown: ((KeyCode) -> Void)?
        var onArrowKeyUp: ((KeyCode) -> Void)?
        var onEnter: (() -> Void)?
        var onBackspace: (() -> Void)?
        var onSpace: (() -> Void)?
        var onSingleFingerTap: (() -> Bool)?
        private var activeHoldArrowKey: KeyCode?

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
            guard gesture.state == .ended else { return }
            if onSingleFingerTap?() == true { return }
            guard let key = arrowKey(for: gesture) else { return }
            onArrowKeyDown?(key)
            onArrowKeyUp?(key)
        }

        @objc private func handleSingleFingerHold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                guard let key = arrowKey(for: gesture) else { return }
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
