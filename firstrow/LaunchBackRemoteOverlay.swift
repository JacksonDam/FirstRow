#if os(tvOS)
    import SwiftUI
    import UIKit

    struct LaunchBackRemoteOverlay: UIViewRepresentable {
        let onBackPressed: () -> Void
        let onBackReleased: () -> Void
        func makeUIView(context _: Context) -> LaunchBackRemoteCapturingView {
            let view = LaunchBackRemoteCapturingView()
            view.backgroundColor = .clear
            view.onBackPressed = onBackPressed
            view.onBackReleased = onBackReleased
            return view
        }

        func updateUIView(_ uiView: LaunchBackRemoteCapturingView, context _: Context) {
            uiView.onBackPressed = onBackPressed
            uiView.onBackReleased = onBackReleased
            uiView.makePrimaryResponderIfPossible()
        }
    }

    final class LaunchBackRemoteCapturingView: UIView {
        var onBackPressed: (() -> Void)?
        var onBackReleased: (() -> Void)?
        override var canBecomeFirstResponder: Bool {
            true
        }

        override func didMoveToWindow() {
            super.didMoveToWindow(); makePrimaryResponderIfPossible()
        }

        override func layoutSubviews() {
            super.layoutSubviews(); makePrimaryResponderIfPossible()
        }

        func makePrimaryResponderIfPossible() {
            guard window != nil, !isFirstResponder else { return }
            _ = becomeFirstResponder()
        }

        private func handleMenuPresses(_ presses: Set<UIPress>, handler: (() -> Void)?, fallback: () -> Void) {
            if presses.contains(where: { $0.type == .menu }) { handler?() } else { fallback() }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            handleMenuPresses(presses, handler: onBackPressed) { super.pressesBegan(presses, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            handleMenuPresses(presses, handler: onBackReleased) { super.pressesEnded(presses, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            handleMenuPresses(presses, handler: onBackReleased) { super.pressesCancelled(presses, with: event) }
        }
    }
#endif
