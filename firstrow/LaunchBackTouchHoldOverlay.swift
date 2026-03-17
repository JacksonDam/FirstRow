#if os(iOS)
    import SwiftUI
    import UIKit

    struct LaunchBackTouchHoldOverlay: UIViewRepresentable {
        let onHoldBegan: () -> Void
        let onHoldEnded: () -> Void
        func makeCoordinator() -> Coordinator {
            Coordinator(onHoldBegan: onHoldBegan, onHoldEnded: onHoldEnded)
        }

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isMultipleTouchEnabled = true
            view.backgroundColor = .clear
            let threeFingerHold = UILongPressGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleThreeFingerHold(_:)),
            )
            threeFingerHold.minimumPressDuration = 0.01
            threeFingerHold.numberOfTouchesRequired = 3
            threeFingerHold.cancelsTouchesInView = false
            view.addGestureRecognizer(threeFingerHold)
            return view
        }

        func updateUIView(_: UIView, context: Context) {
            context.coordinator.onHoldBegan = onHoldBegan
            context.coordinator.onHoldEnded = onHoldEnded
        }

        final class Coordinator: NSObject {
            var onHoldBegan: () -> Void
            var onHoldEnded: () -> Void
            init(onHoldBegan: @escaping () -> Void, onHoldEnded: @escaping () -> Void) {
                self.onHoldBegan = onHoldBegan
                self.onHoldEnded = onHoldEnded
            }

            @objc
            func handleThreeFingerHold(_ gesture: UILongPressGestureRecognizer) {
                switch gesture.state {
                case .began: onHoldBegan()
                case .ended, .failed, .cancelled: onHoldEnded()
                default: break
                }
            }
        }
    }
#endif
