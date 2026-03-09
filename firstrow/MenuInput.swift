import SwiftUI

#if os(macOS)
    struct KeyEventHandlingModifier: ViewModifier {
        let onKeyDown: (KeyCode, Bool, NSEvent.ModifierFlags) -> Void
        let onKeyUp: (KeyCode, NSEvent.ModifierFlags) -> Void
        func body(content: Content) -> some View {
            content.background(
                KeyEventHandlingView(
                    onKeyDown: onKeyDown,
                    onKeyUp: onKeyUp,
                ),
            )
        }
    }

    struct KeyEventHandlingView: NSViewRepresentable {
        let onKeyDown: (KeyCode, Bool, NSEvent.ModifierFlags) -> Void
        let onKeyUp: (KeyCode, NSEvent.ModifierFlags) -> Void
        func makeCoordinator() -> Coordinator {
            Coordinator(onKeyDown: onKeyDown, onKeyUp: onKeyUp)
        }

        func makeNSView(context: Context) -> NSView {
            let view = KeyCapturingView()
            view.onKeyDown = onKeyDown
            view.onKeyUp = onKeyUp
            context.coordinator.startMonitoring()
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            if let keyView = nsView as? KeyCapturingView {
                keyView.onKeyDown = onKeyDown
                keyView.onKeyUp = onKeyUp
            }
            context.coordinator.onKeyDown = onKeyDown
            context.coordinator.onKeyUp = onKeyUp
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }

        static func dismantleNSView(_: NSView, coordinator: Coordinator) {
            coordinator.stopMonitoring()
        }

        class Coordinator {
            var onKeyDown: (KeyCode, Bool, NSEvent.ModifierFlags) -> Void
            var onKeyUp: (KeyCode, NSEvent.ModifierFlags) -> Void
            private var keyDownMonitor: Any?
            private var keyUpMonitor: Any?
            init(
                onKeyDown: @escaping (KeyCode, Bool, NSEvent.ModifierFlags) -> Void,
                onKeyUp: @escaping (KeyCode, NSEvent.ModifierFlags) -> Void,
            ) {
                self.onKeyDown = onKeyDown
                self.onKeyUp = onKeyUp
            }

            func startMonitoring() {
                guard keyDownMonitor == nil else { return }
                keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                    guard let self else { return event }
                    let key = KeyCode(rawValue: event.keyCode) ?? .none
                    let modifiers = event.modifierFlags
                    let independentModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
                    let isCommandEscape =
                        independentModifiers.contains(.command) &&
                        (key == .escape || event.charactersIgnoringModifiers == "\u{1b}")
                    if isCommandEscape {
                        onKeyDown(.escape, event.isARepeat, modifiers)
                        return nil
                    }
                    if event.window?.firstResponder is KeyCapturingView {
                        return event
                    }
                    onKeyDown(key, event.isARepeat, modifiers)
                    return nil
                }
                guard keyUpMonitor == nil else { return }
                keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
                    guard let self else { return event }
                    let key = KeyCode(rawValue: event.keyCode) ?? .none
                    let modifiers = event.modifierFlags
                    if event.window?.firstResponder is KeyCapturingView {
                        return event
                    }
                    onKeyUp(key, modifiers)
                    return nil
                }
            }

            func stopMonitoring() {
                if let keyDownMonitor {
                    NSEvent.removeMonitor(keyDownMonitor)
                    self.keyDownMonitor = nil
                }
                if let keyUpMonitor {
                    NSEvent.removeMonitor(keyUpMonitor)
                    self.keyUpMonitor = nil
                }
            }
        }

        class KeyCapturingView: NSView {
            var onKeyDown: ((KeyCode, Bool, NSEvent.ModifierFlags) -> Void)?
            var onKeyUp: ((KeyCode, NSEvent.ModifierFlags) -> Void)?
            override func keyDown(with event: NSEvent) {
                let key = KeyCode(rawValue: event.keyCode) ?? .none
                let modifiers = event.modifierFlags
                let independentModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
                let isCommandEscape =
                    independentModifiers.contains(.command) &&
                    (key == .escape || event.charactersIgnoringModifiers == "\u{1b}")
                if isCommandEscape {
                    onKeyDown?(.escape, event.isARepeat, modifiers)
                    return
                }
                onKeyDown?(key, event.isARepeat, modifiers)
            }

            override func keyUp(with event: NSEvent) {
                let key = KeyCode(rawValue: event.keyCode) ?? .none
                onKeyUp?(key, event.modifierFlags)
            }

            override func performKeyEquivalent(with event: NSEvent) -> Bool {
                guard event.type == .keyDown else {
                    return super.performKeyEquivalent(with: event)
                }
                let key = KeyCode(rawValue: event.keyCode) ?? .none
                let modifiers = event.modifierFlags
                if key == .escape, modifiers.contains(.command) {
                    onKeyDown?(key, event.isARepeat, modifiers)
                    return true
                }
                return super.performKeyEquivalent(with: event)
            }

            override var acceptsFirstResponder: Bool {
                true
            }

            override func becomeFirstResponder() -> Bool {
                true
            }
        }
    }
#else
    enum NSEvent {
        struct ModifierFlags: OptionSet {
            let rawValue: Int
            static let command = ModifierFlags(rawValue: 1 << 0)
        }
    }

    struct KeyEventHandlingModifier: ViewModifier {
        let onKeyDown: (KeyCode, Bool, NSEvent.ModifierFlags) -> Void
        let onKeyUp: (KeyCode, NSEvent.ModifierFlags) -> Void
        func body(content: Content) -> some View {
            content
        }
    }
#endif
enum KeyCode: UInt16 {
    case none = 0
    case space = 49
    case leftArrow = 123
    case rightArrow = 124
    case upArrow = 126
    case downArrow = 125
    case enter = 36
    case escape = 53
    case delete = 51
}

extension View {
    func onKeyDown(_ action: @escaping (KeyCode, Bool, NSEvent.ModifierFlags) -> Void) -> some View {
        modifier(
            KeyEventHandlingModifier(
                onKeyDown: action,
                onKeyUp: { _, _ in },
            ),
        )
    }

    func onKeyEvents(
        onKeyDown: @escaping (KeyCode, Bool, NSEvent.ModifierFlags) -> Void,
        onKeyUp: @escaping (KeyCode, NSEvent.ModifierFlags) -> Void,
    ) -> some View {
        modifier(
            KeyEventHandlingModifier(
                onKeyDown: onKeyDown,
                onKeyUp: onKeyUp,
            ),
        )
    }
}
