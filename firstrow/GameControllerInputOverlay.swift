import AppKit
import GameController
import SwiftUI

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
            guard controllersByID[controllerID] == nil else { return }
            controllersByID[controllerID] = controller
            configureControllerHandlers(controller, controllerID: controllerID)
        }

        private func unregisterController(_ controller: GCController) {
            let controllerID = ObjectIdentifier(controller)
            guard let storedController = controllersByID.removeValue(forKey: controllerID) else { return }
            clearControllerHandlers(storedController)
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
                self?.setDirection(.up, pressed: isPressed, controllerID: controllerID, source: source)
            }
            directionPad.down.pressedChangedHandler = { [weak self] _, _, isPressed in
                self?.setDirection(.down, pressed: isPressed, controllerID: controllerID, source: source)
            }
            directionPad.left.pressedChangedHandler = { [weak self] _, _, isPressed in
                self?.setDirection(.left, pressed: isPressed, controllerID: controllerID, source: source)
            }
            directionPad.right.pressedChangedHandler = { [weak self] _, _, isPressed in
                self?.setDirection(.right, pressed: isPressed, controllerID: controllerID, source: source)
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
