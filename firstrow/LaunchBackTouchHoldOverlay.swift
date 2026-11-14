#if os(iOS)
    import UIKit

    /// Three fingers held down at launch (the touch equivalent of holding Delete). It only
    /// watches the touches, from the view everything sits in, so ordinary taps reach the menus
    /// straight away rather than waiting for the launch window to close.
    @MainActor
    final class LaunchBackTouchHold: NSObject {
        var onHoldBegan: (() -> Void)?
        var onHoldEnded: (() -> Void)?
        private let recognizer = UILongPressGestureRecognizer()
        private weak var view: UIView?

        override init() {
            super.init()
            recognizer.addTarget(self, action: #selector(handleThreeFingerHold(_:)))
            recognizer.minimumPressDuration = 0.01
            recognizer.numberOfTouchesRequired = 3
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
        }

        func attach(to view: UIView) {
            view.addGestureRecognizer(recognizer)
            self.view = view
        }

        func detach() {
            view?.removeGestureRecognizer(recognizer)
            view = nil
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
