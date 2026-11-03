#if os(iOS)
    import UIKit

    /// Three fingers held down at launch (the touch equivalent of holding Delete).
    final class LaunchBackTouchHoldView: UIView {
        var onHoldBegan: (() -> Void)?
        var onHoldEnded: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let threeFingerHold = UILongPressGestureRecognizer(target: self, action: #selector(handleThreeFingerHold(_:)))
            threeFingerHold.minimumPressDuration = 0.01
            threeFingerHold.numberOfTouchesRequired = 3
            threeFingerHold.cancelsTouchesInView = false
            addGestureRecognizer(threeFingerHold)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        @objc private func handleThreeFingerHold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began: onHoldBegan?()
            case .ended, .failed, .cancelled: onHoldEnded?()
            default: break
            }
        }
    }
#endif
