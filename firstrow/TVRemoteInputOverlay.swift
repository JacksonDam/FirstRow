import SwiftUI

#if os(iOS) || os(tvOS)
    import GameController

    private let appleRemoteProductCategories: Set<String> = [
        GCProductCategorySiriRemote1stGen,
        GCProductCategorySiriRemote2ndGen,
        GCProductCategoryControlCenterRemote,
        GCProductCategoryUniversalElectronicsRemote,
        GCProductCategoryCoalescedRemote,
    ]

    private func isAppleRemoteMicroGamepadController(_ controller: GCController) -> Bool {
        guard controller.microGamepad != nil else { return false }
        return appleRemoteProductCategories.contains(controller.productCategory)
    }
#endif

#if os(tvOS)
    import UIKit

    struct TVRemoteInputOverlay: UIViewRepresentable {
        let onKeyDown: (KeyCode) -> Void
        let onKeyUp: (KeyCode) -> Void
        func makeUIView(context _: Context) -> RemotePressCapturingView {
            let view = RemotePressCapturingView()
            view.backgroundColor = .clear
            view.onKeyDown = onKeyDown
            view.onKeyUp = onKeyUp
            return view
        }

        func updateUIView(_ uiView: RemotePressCapturingView, context _: Context) {
            uiView.onKeyDown = onKeyDown
            uiView.onKeyUp = onKeyUp
            uiView.makePrimaryResponderIfPossible()
        }
    }

    final class RemotePressCapturingView: UIView {
        var onKeyDown: ((KeyCode) -> Void)?
        var onKeyUp: ((KeyCode) -> Void)?

        override var canBecomeFirstResponder: Bool {
            true
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            makePrimaryResponderIfPossible()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            makePrimaryResponderIfPossible()
        }

        func makePrimaryResponderIfPossible() {
            guard window != nil else { return }
            guard !isFirstResponder else { return }
            _ = becomeFirstResponder()
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                guard let key = mapPressTypeToKeyCode(press.type) else { continue }
                onKeyDown?(key)
                handled = true
            }
            if !handled {
                super.pressesBegan(presses, with: event)
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                guard let key = mapPressTypeToKeyCode(press.type) else { continue }
                onKeyUp?(key)
                handled = true
            }
            if !handled {
                super.pressesEnded(presses, with: event)
            }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                guard let key = mapPressTypeToKeyCode(press.type) else { continue }
                onKeyUp?(key)
                handled = true
            }
            if !handled {
                super.pressesCancelled(presses, with: event)
            }
        }

        private func mapPressTypeToKeyCode(_ pressType: UIPress.PressType) -> KeyCode? {
            switch pressType {
            case .upArrow:
                .upArrow
            case .downArrow:
                .downArrow
            case .leftArrow:
                .leftArrow
            case .rightArrow:
                .rightArrow
            case .select:
                .enter
            case .menu:
                .delete
            case .playPause:
                .space
            default:
                nil
            }
        }
    }
#endif

#if os(iOS) || os(tvOS)
    import GameController
    import UIKit

    struct GameControllerInputOverlay: UIViewRepresentable {
        let onArrowKeyDown: (KeyCode) -> Void
        let onArrowKeyUp: (KeyCode) -> Void
        let onEnter: () -> Void
        let onBackspace: () -> Void
        let onSpace: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(
                onArrowKeyDown: onArrowKeyDown,
                onArrowKeyUp: onArrowKeyUp,
                onEnter: onEnter,
                onBackspace: onBackspace,
                onSpace: onSpace,
            )
        }

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            context.coordinator.startMonitoringControllersIfNeeded()
            return view
        }

        func updateUIView(_: UIView, context: Context) {
            context.coordinator.onArrowKeyDown = onArrowKeyDown
            context.coordinator.onArrowKeyUp = onArrowKeyUp
            context.coordinator.onEnter = onEnter
            context.coordinator.onBackspace = onBackspace
            context.coordinator.onSpace = onSpace
        }

        static func dismantleUIView(_: UIView, coordinator: Coordinator) {
            coordinator.stopMonitoringControllers()
        }

        final class Coordinator: NSObject {
            enum ControllerDirection: CaseIterable {
                case up
                case down
                case left
                case right

                var keyCode: KeyCode {
                    switch self {
                    case .up:
                        .upArrow
                    case .down:
                        .downArrow
                    case .left:
                        .leftArrow
                    case .right:
                        .rightArrow
                    }
                }
            }

            enum DirectionSource: Hashable {
                case dpad
                case leftThumbstick
            }

            struct DirectionToken: Hashable {
                let controllerID: ObjectIdentifier
                let source: DirectionSource
                let direction: ControllerDirection
            }

            var onArrowKeyDown: (KeyCode) -> Void
            var onArrowKeyUp: (KeyCode) -> Void
            var onEnter: () -> Void
            var onBackspace: () -> Void
            var onSpace: () -> Void

            private var controllerObservers: [NSObjectProtocol] = []
            private var controllersByID: [ObjectIdentifier: GCController] = [:]
            private var activeDirectionTokens: Set<DirectionToken> = []
            private var activeDirectionCountByDirection: [ControllerDirection: Int] = [:]

            init(
                onArrowKeyDown: @escaping (KeyCode) -> Void,
                onArrowKeyUp: @escaping (KeyCode) -> Void,
                onEnter: @escaping () -> Void,
                onBackspace: @escaping () -> Void,
                onSpace: @escaping () -> Void,
            ) {
                self.onArrowKeyDown = onArrowKeyDown
                self.onArrowKeyUp = onArrowKeyUp
                self.onEnter = onEnter
                self.onBackspace = onBackspace
                self.onSpace = onSpace
                super.init()
            }

            func startMonitoringControllersIfNeeded() {
                guard controllerObservers.isEmpty else { return }
                let center = NotificationCenter.default
                controllerObservers.append(
                    center.addObserver(
                        forName: .GCControllerDidConnect,
                        object: nil,
                        queue: .main,
                    ) { [weak self] notification in
                        guard let controller = notification.object as? GCController else { return }
                        self?.registerController(controller)
                    },
                )
                controllerObservers.append(
                    center.addObserver(
                        forName: .GCControllerDidDisconnect,
                        object: nil,
                        queue: .main,
                    ) { [weak self] notification in
                        guard let controller = notification.object as? GCController else { return }
                        self?.unregisterController(controller)
                    },
                )
                for controller in GCController.controllers() {
                    registerController(controller)
                }
            }

            func stopMonitoringControllers() {
                let center = NotificationCenter.default
                for observer in controllerObservers {
                    center.removeObserver(observer)
                }
                controllerObservers.removeAll()
                for (controllerID, controller) in controllersByID {
                    clearControllerHandlers(controller)
                    releaseDirectionalState(forControllerID: controllerID)
                }
                controllersByID.removeAll()
                activeDirectionTokens.removeAll()
                activeDirectionCountByDirection.removeAll()
            }

            private func registerController(_ controller: GCController) {
                let controllerID = ObjectIdentifier(controller)
                if controllersByID[controllerID] != nil {
                    return
                }
                controllersByID[controllerID] = controller
                configureControllerHandlers(controller, controllerID: controllerID)
            }

            private func unregisterController(_ controller: GCController) {
                let controllerID = ObjectIdentifier(controller)
                guard let stored = controllersByID.removeValue(forKey: controllerID) else { return }
                clearControllerHandlers(stored)
                releaseDirectionalState(forControllerID: controllerID)
            }

            private func configureControllerHandlers(_ controller: GCController, controllerID: ObjectIdentifier) {
                if let gamepad = controller.extendedGamepad {
                    configureDirectionPadHandlers(gamepad.dpad, controllerID: controllerID, source: .dpad)
                    configureDirectionPadHandlers(
                        gamepad.leftThumbstick,
                        controllerID: controllerID,
                        source: .leftThumbstick,
                    )
                    gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onEnter()
                        }
                    }
                    gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onBackspace()
                        }
                    }
                    gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onSpace()
                        }
                    }
                    gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onBackspace()
                        }
                    }
                }

                if let gamepad = controller.microGamepad {
                    if isAppleRemoteMicroGamepadController(controller) {
                        if let cardinalDPad = controller.physicalInputProfile.dpads[GCInputDirectionalCardinalDpad] {
                            configureDirectionPadHandlers(
                                cardinalDPad,
                                controllerID: controllerID,
                                source: .dpad,
                            )
                        }
                        return
                    }
                    configureDirectionPadHandlers(gamepad.dpad, controllerID: controllerID, source: .dpad)
                    gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onEnter()
                        }
                    }
                    gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onSpace()
                        }
                    }
                    gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onBackspace()
                        }
                    }
                }
            }

            private func clearControllerHandlers(_ controller: GCController) {
                if let gamepad = controller.extendedGamepad {
                    clearDirectionPadHandlers(gamepad.dpad)
                    clearDirectionPadHandlers(gamepad.leftThumbstick)
                    gamepad.buttonA.pressedChangedHandler = nil
                    gamepad.buttonB.pressedChangedHandler = nil
                    gamepad.buttonX.pressedChangedHandler = nil
                    gamepad.buttonMenu.pressedChangedHandler = nil
                }
                if let gamepad = controller.microGamepad {
                    if isAppleRemoteMicroGamepadController(controller),
                       let cardinalDPad = controller.physicalInputProfile.dpads[GCInputDirectionalCardinalDpad]
                    {
                        clearDirectionPadHandlers(cardinalDPad)
                    } else {
                        clearDirectionPadHandlers(gamepad.dpad)
                    }
                    gamepad.buttonA.pressedChangedHandler = nil
                    gamepad.buttonX.pressedChangedHandler = nil
                    gamepad.buttonMenu.pressedChangedHandler = nil
                }
            }

            private func configureDirectionPadHandlers(
                _ directionPad: GCControllerDirectionPad,
                controllerID: ObjectIdentifier,
                source: DirectionSource,
            ) {
                directionPad.up.pressedChangedHandler = { [weak self] _, _, isPressed in
                    self?.setDirection(
                        .up,
                        pressed: isPressed,
                        controllerID: controllerID,
                        source: source,
                    )
                }
                directionPad.down.pressedChangedHandler = { [weak self] _, _, isPressed in
                    self?.setDirection(
                        .down,
                        pressed: isPressed,
                        controllerID: controllerID,
                        source: source,
                    )
                }
                directionPad.left.pressedChangedHandler = { [weak self] _, _, isPressed in
                    self?.setDirection(
                        .left,
                        pressed: isPressed,
                        controllerID: controllerID,
                        source: source,
                    )
                }
                directionPad.right.pressedChangedHandler = { [weak self] _, _, isPressed in
                    self?.setDirection(
                        .right,
                        pressed: isPressed,
                        controllerID: controllerID,
                        source: source,
                    )
                }
            }

            private func clearDirectionPadHandlers(_ directionPad: GCControllerDirectionPad) {
                directionPad.up.pressedChangedHandler = nil
                directionPad.down.pressedChangedHandler = nil
                directionPad.left.pressedChangedHandler = nil
                directionPad.right.pressedChangedHandler = nil
            }

            private func setDirection(
                _ direction: ControllerDirection,
                pressed: Bool,
                controllerID: ObjectIdentifier,
                source: DirectionSource,
            ) {
                let token = DirectionToken(
                    controllerID: controllerID,
                    source: source,
                    direction: direction,
                )
                dispatchOnMain { [weak self] in
                    guard let self else { return }
                    if pressed {
                        guard !activeDirectionTokens.contains(token) else { return }
                        activeDirectionTokens.insert(token)
                        let nextCount = (activeDirectionCountByDirection[direction] ?? 0) + 1
                        activeDirectionCountByDirection[direction] = nextCount
                        if nextCount == 1 {
                            onArrowKeyDown(direction.keyCode)
                        }
                    } else {
                        guard activeDirectionTokens.remove(token) != nil else { return }
                        let currentCount = activeDirectionCountByDirection[direction] ?? 0
                        let nextCount = max(0, currentCount - 1)
                        if nextCount == 0 {
                            activeDirectionCountByDirection.removeValue(forKey: direction)
                            onArrowKeyUp(direction.keyCode)
                        } else {
                            activeDirectionCountByDirection[direction] = nextCount
                        }
                    }
                }
            }

            private func releaseDirectionalState(forControllerID controllerID: ObjectIdentifier) {
                let tokensToRelease = activeDirectionTokens.filter { $0.controllerID == controllerID }
                for token in tokensToRelease {
                    if activeDirectionTokens.remove(token) != nil {
                        let currentCount = activeDirectionCountByDirection[token.direction] ?? 0
                        let nextCount = max(0, currentCount - 1)
                        if nextCount == 0 {
                            activeDirectionCountByDirection.removeValue(forKey: token.direction)
                            onArrowKeyUp(token.direction.keyCode)
                        } else {
                            activeDirectionCountByDirection[token.direction] = nextCount
                        }
                    }
                }
            }

            private func dispatchOnMain(_ work: @escaping () -> Void) {
                if Thread.isMainThread {
                    work()
                } else {
                    DispatchQueue.main.async(execute: work)
                }
            }
        }
    }
#endif

#if os(macOS)
    import AppKit
    import GameController

    struct GameControllerInputOverlay: NSViewRepresentable {
        let onArrowKeyDown: (KeyCode) -> Void
        let onArrowKeyUp: (KeyCode) -> Void
        let onEnter: () -> Void
        let onBackspace: () -> Void
        let onSpace: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(
                onArrowKeyDown: onArrowKeyDown,
                onArrowKeyUp: onArrowKeyUp,
                onEnter: onEnter,
                onBackspace: onBackspace,
                onSpace: onSpace,
            )
        }

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            context.coordinator.startMonitoringControllersIfNeeded()
            return view
        }

        func updateNSView(_: NSView, context: Context) {
            context.coordinator.onArrowKeyDown = onArrowKeyDown
            context.coordinator.onArrowKeyUp = onArrowKeyUp
            context.coordinator.onEnter = onEnter
            context.coordinator.onBackspace = onBackspace
            context.coordinator.onSpace = onSpace
        }

        static func dismantleNSView(_: NSView, coordinator: Coordinator) {
            coordinator.stopMonitoringControllers()
        }

        final class Coordinator: NSObject {
            enum ControllerDirection {
                case up
                case down
                case left
                case right

                var keyCode: KeyCode {
                    switch self {
                    case .up:
                        .upArrow
                    case .down:
                        .downArrow
                    case .left:
                        .leftArrow
                    case .right:
                        .rightArrow
                    }
                }
            }

            enum DirectionSource: Hashable {
                case dpad
                case leftThumbstick
            }

            struct DirectionToken: Hashable {
                let controllerID: ObjectIdentifier
                let source: DirectionSource
                let direction: ControllerDirection
            }

            var onArrowKeyDown: (KeyCode) -> Void
            var onArrowKeyUp: (KeyCode) -> Void
            var onEnter: () -> Void
            var onBackspace: () -> Void
            var onSpace: () -> Void

            private var controllerObservers: [NSObjectProtocol] = []
            private var controllersByID: [ObjectIdentifier: GCController] = [:]
            private var activeDirectionTokens: Set<DirectionToken> = []
            private var activeDirectionCountByDirection: [ControllerDirection: Int] = [:]

            init(
                onArrowKeyDown: @escaping (KeyCode) -> Void,
                onArrowKeyUp: @escaping (KeyCode) -> Void,
                onEnter: @escaping () -> Void,
                onBackspace: @escaping () -> Void,
                onSpace: @escaping () -> Void,
            ) {
                self.onArrowKeyDown = onArrowKeyDown
                self.onArrowKeyUp = onArrowKeyUp
                self.onEnter = onEnter
                self.onBackspace = onBackspace
                self.onSpace = onSpace
                super.init()
            }

            func startMonitoringControllersIfNeeded() {
                guard controllerObservers.isEmpty else { return }
                let center = NotificationCenter.default
                controllerObservers.append(
                    center.addObserver(
                        forName: .GCControllerDidConnect,
                        object: nil,
                        queue: .main,
                    ) { [weak self] notification in
                        guard let controller = notification.object as? GCController else { return }
                        self?.registerController(controller)
                    },
                )
                controllerObservers.append(
                    center.addObserver(
                        forName: .GCControllerDidDisconnect,
                        object: nil,
                        queue: .main,
                    ) { [weak self] notification in
                        guard let controller = notification.object as? GCController else { return }
                        self?.unregisterController(controller)
                    },
                )
                for controller in GCController.controllers() {
                    registerController(controller)
                }
            }

            func stopMonitoringControllers() {
                let center = NotificationCenter.default
                for observer in controllerObservers {
                    center.removeObserver(observer)
                }
                controllerObservers.removeAll()
                for (controllerID, controller) in controllersByID {
                    clearControllerHandlers(controller)
                    releaseDirectionalState(forControllerID: controllerID)
                }
                controllersByID.removeAll()
                activeDirectionTokens.removeAll()
                activeDirectionCountByDirection.removeAll()
            }

            private func registerController(_ controller: GCController) {
                let controllerID = ObjectIdentifier(controller)
                if controllersByID[controllerID] != nil {
                    return
                }
                controllersByID[controllerID] = controller
                configureControllerHandlers(controller, controllerID: controllerID)
            }

            private func unregisterController(_ controller: GCController) {
                let controllerID = ObjectIdentifier(controller)
                guard let stored = controllersByID.removeValue(forKey: controllerID) else { return }
                clearControllerHandlers(stored)
                releaseDirectionalState(forControllerID: controllerID)
            }

            private func configureControllerHandlers(_ controller: GCController, controllerID: ObjectIdentifier) {
                if let gamepad = controller.extendedGamepad {
                    configureDirectionPadHandlers(gamepad.dpad, controllerID: controllerID, source: .dpad)
                    configureDirectionPadHandlers(
                        gamepad.leftThumbstick,
                        controllerID: controllerID,
                        source: .leftThumbstick,
                    )
                    gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onEnter()
                        }
                    }
                    gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onBackspace()
                        }
                    }
                    gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onSpace()
                        }
                    }
                    gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onBackspace()
                        }
                    }
                }

                if let gamepad = controller.microGamepad {
                    configureDirectionPadHandlers(gamepad.dpad, controllerID: controllerID, source: .dpad)
                    gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onEnter()
                        }
                    }
                    gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onSpace()
                        }
                    }
                    gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, isPressed in
                        guard isPressed else { return }
                        self?.dispatchOnMain {
                            self?.onBackspace()
                        }
                    }
                }
            }

            private func clearControllerHandlers(_ controller: GCController) {
                if let gamepad = controller.extendedGamepad {
                    clearDirectionPadHandlers(gamepad.dpad)
                    clearDirectionPadHandlers(gamepad.leftThumbstick)
                    gamepad.buttonA.pressedChangedHandler = nil
                    gamepad.buttonB.pressedChangedHandler = nil
                    gamepad.buttonX.pressedChangedHandler = nil
                    gamepad.buttonMenu.pressedChangedHandler = nil
                }
                if let gamepad = controller.microGamepad {
                    clearDirectionPadHandlers(gamepad.dpad)
                    gamepad.buttonA.pressedChangedHandler = nil
                    gamepad.buttonX.pressedChangedHandler = nil
                    gamepad.buttonMenu.pressedChangedHandler = nil
                }
            }

            private func configureDirectionPadHandlers(
                _ directionPad: GCControllerDirectionPad,
                controllerID: ObjectIdentifier,
                source: DirectionSource,
            ) {
                directionPad.up.pressedChangedHandler = { [weak self] _, _, isPressed in
                    self?.setDirection(
                        .up,
                        pressed: isPressed,
                        controllerID: controllerID,
                        source: source,
                    )
                }
                directionPad.down.pressedChangedHandler = { [weak self] _, _, isPressed in
                    self?.setDirection(
                        .down,
                        pressed: isPressed,
                        controllerID: controllerID,
                        source: source,
                    )
                }
                directionPad.left.pressedChangedHandler = { [weak self] _, _, isPressed in
                    self?.setDirection(
                        .left,
                        pressed: isPressed,
                        controllerID: controllerID,
                        source: source,
                    )
                }
                directionPad.right.pressedChangedHandler = { [weak self] _, _, isPressed in
                    self?.setDirection(
                        .right,
                        pressed: isPressed,
                        controllerID: controllerID,
                        source: source,
                    )
                }
            }

            private func clearDirectionPadHandlers(_ directionPad: GCControllerDirectionPad) {
                directionPad.up.pressedChangedHandler = nil
                directionPad.down.pressedChangedHandler = nil
                directionPad.left.pressedChangedHandler = nil
                directionPad.right.pressedChangedHandler = nil
            }

            private func setDirection(
                _ direction: ControllerDirection,
                pressed: Bool,
                controllerID: ObjectIdentifier,
                source: DirectionSource,
            ) {
                let token = DirectionToken(
                    controllerID: controllerID,
                    source: source,
                    direction: direction,
                )
                dispatchOnMain { [weak self] in
                    guard let self else { return }
                    if pressed {
                        guard !activeDirectionTokens.contains(token) else { return }
                        activeDirectionTokens.insert(token)
                        let nextCount = (activeDirectionCountByDirection[direction] ?? 0) + 1
                        activeDirectionCountByDirection[direction] = nextCount
                        if nextCount == 1 {
                            onArrowKeyDown(direction.keyCode)
                        }
                    } else {
                        guard activeDirectionTokens.remove(token) != nil else { return }
                        let currentCount = activeDirectionCountByDirection[direction] ?? 0
                        let nextCount = max(0, currentCount - 1)
                        if nextCount == 0 {
                            activeDirectionCountByDirection.removeValue(forKey: direction)
                            onArrowKeyUp(direction.keyCode)
                        } else {
                            activeDirectionCountByDirection[direction] = nextCount
                        }
                    }
                }
            }

            private func releaseDirectionalState(forControllerID controllerID: ObjectIdentifier) {
                let tokensToRelease = activeDirectionTokens.filter { $0.controllerID == controllerID }
                for token in tokensToRelease {
                    if activeDirectionTokens.remove(token) != nil {
                        let currentCount = activeDirectionCountByDirection[token.direction] ?? 0
                        let nextCount = max(0, currentCount - 1)
                        if nextCount == 0 {
                            activeDirectionCountByDirection.removeValue(forKey: token.direction)
                            onArrowKeyUp(token.direction.keyCode)
                        } else {
                            activeDirectionCountByDirection[token.direction] = nextCount
                        }
                    }
                }
            }

            private func dispatchOnMain(_ work: @escaping () -> Void) {
                if Thread.isMainThread {
                    work()
                } else {
                    DispatchQueue.main.async(execute: work)
                }
            }
        }
    }
#endif
