import SwiftUI
#if os(iOS)
    import UIKit

    struct TouchNavigationInputOverlay: UIViewRepresentable {
        let onArrowKeyDown: (KeyCode) -> Void
        let onArrowKeyUp: (KeyCode) -> Void
        let onEnter: () -> Void
        let onBackspace: () -> Void
        let onSpace: () -> Void
        let onSingleFingerTap: () -> Bool
        func makeCoordinator() -> Coordinator {
            Coordinator(
                onArrowKeyDown: onArrowKeyDown,
                onArrowKeyUp: onArrowKeyUp,
                onEnter: onEnter,
                onBackspace: onBackspace,
                onSpace: onSpace,
                onSingleFingerTap: onSingleFingerTap,
            )
        }

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .clear
            view.isMultipleTouchEnabled = true
            let twoFingerTap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleTwoFingerTap(_:)),
            )
            twoFingerTap.numberOfTapsRequired = 1
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.cancelsTouchesInView = false
            view.addGestureRecognizer(twoFingerTap)
            let threeFingerTap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleThreeFingerTap(_:)),
            )
            threeFingerTap.numberOfTapsRequired = 1
            threeFingerTap.numberOfTouchesRequired = 3
            threeFingerTap.cancelsTouchesInView = false
            view.addGestureRecognizer(threeFingerTap)
            let fourFingerTap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleFourFingerTap(_:)),
            )
            fourFingerTap.numberOfTapsRequired = 1
            fourFingerTap.numberOfTouchesRequired = 4
            fourFingerTap.cancelsTouchesInView = false
            view.addGestureRecognizer(fourFingerTap)
            threeFingerTap.require(toFail: fourFingerTap)
            twoFingerTap.require(toFail: threeFingerTap)
            twoFingerTap.require(toFail: fourFingerTap)
            let singleFingerTap = UITapGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleSingleFingerTap(_:)),
            )
            singleFingerTap.numberOfTapsRequired = 1
            singleFingerTap.numberOfTouchesRequired = 1
            singleFingerTap.cancelsTouchesInView = false
            let singleFingerHold = UILongPressGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleSingleFingerHold(_:)),
            )
            singleFingerHold.minimumPressDuration = 0.24
            singleFingerHold.numberOfTouchesRequired = 1
            singleFingerHold.cancelsTouchesInView = false
            singleFingerTap.require(toFail: twoFingerTap)
            singleFingerTap.require(toFail: threeFingerTap)
            singleFingerTap.require(toFail: fourFingerTap)
            singleFingerTap.require(toFail: singleFingerHold)
            view.addGestureRecognizer(singleFingerTap)
            view.addGestureRecognizer(singleFingerHold)
            return view
        }

        func updateUIView(_: UIView, context: Context) {
            context.coordinator.onArrowKeyDown = onArrowKeyDown
            context.coordinator.onArrowKeyUp = onArrowKeyUp
            context.coordinator.onEnter = onEnter
            context.coordinator.onBackspace = onBackspace
            context.coordinator.onSpace = onSpace
            context.coordinator.onSingleFingerTap = onSingleFingerTap
        }

        final class Coordinator: NSObject {
            var onArrowKeyDown: (KeyCode) -> Void
            var onArrowKeyUp: (KeyCode) -> Void
            var onEnter: () -> Void
            var onBackspace: () -> Void
            var onSpace: () -> Void
            var onSingleFingerTap: () -> Bool
            var activeHoldArrowKey: KeyCode?
            init(
                onArrowKeyDown: @escaping (KeyCode) -> Void,
                onArrowKeyUp: @escaping (KeyCode) -> Void,
                onEnter: @escaping () -> Void,
                onBackspace: @escaping () -> Void,
                onSpace: @escaping () -> Void,
                onSingleFingerTap: @escaping () -> Bool,
            ) {
                self.onArrowKeyDown = onArrowKeyDown
                self.onArrowKeyUp = onArrowKeyUp
                self.onEnter = onEnter
                self.onBackspace = onBackspace
                self.onSpace = onSpace
                self.onSingleFingerTap = onSingleFingerTap
                activeHoldArrowKey = nil
            }

            func resolveArrowKey(from gesture: UIGestureRecognizer) -> KeyCode? {
                guard let view = gesture.view else { return nil }
                let bounds = view.bounds
                guard bounds.width > 0, bounds.height > 0 else { return nil }
                let point = gesture.location(in: view)
                let isTopHalf = point.y < bounds.midY
                let isLeftHalf = point.x < bounds.midX
                if isTopHalf {
                    return isLeftHalf ? .upArrow : .downArrow
                }
                return isLeftHalf ? .leftArrow : .rightArrow
            }

            @objc
            func handleSingleFingerTap(_ gesture: UITapGestureRecognizer) {
                guard gesture.state == .ended else { return }
                if onSingleFingerTap() {
                    return
                }
                guard let key = resolveArrowKey(from: gesture) else { return }
                onArrowKeyDown(key)
                onArrowKeyUp(key)
            }

            @objc
            func handleSingleFingerHold(_ gesture: UILongPressGestureRecognizer) {
                switch gesture.state {
                case .began:
                    guard let key = resolveArrowKey(from: gesture) else { return }
                    activeHoldArrowKey = key
                    onArrowKeyDown(key)
                case .ended, .cancelled, .failed:
                    if let key = activeHoldArrowKey {
                        onArrowKeyUp(key)
                    }
                    activeHoldArrowKey = nil
                default:
                    break
                }
            }

            @objc
            func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
                guard gesture.state == .ended else { return }
                onEnter()
            }

            @objc
            func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
                guard gesture.state == .ended else { return }
                onBackspace()
            }

            @objc
            func handleFourFingerTap(_ gesture: UITapGestureRecognizer) {
                guard gesture.state == .ended else { return }
                onSpace()
            }
        }
    }
#endif
