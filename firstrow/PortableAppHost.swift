#if FIRSTROW_PORTABLE
    import FirstRowPortable

    /// Runs the app controller in the Linux and Windows window: keys, game controllers and
    /// quitting, as the Mac's app delegate does.
    @MainActor
    final class PortableAppHost: PortableHost {
        private let controller = FirstRowAppController()
        private var started = false

        init() {
            // Inter, which ships with First Row, stands in for the Apple system font of the modern look.
            if let fonts = AppResources.url("Fonts") {
                FontRegistry.extraDirectories.append(fonts)
            }
            Harness.customCommand = { command in
                let parts = command.split(separator: ":", maxSplits: 2).map(String.init)
                switch parts.first {
                case "source" where parts.count == 3:
                    guard let kind = MediaSources.FolderKind(rawValue: parts[1]) else { return false }
                    MediaSources.shared.addFolder(URL(fileURLWithPath: parts[2], isDirectory: true), kind: kind)
                    return true
                case "library" where parts.count == 3:
                    guard let kind = MediaSources.LibraryKind(rawValue: parts[1]) else { return false }
                    MediaSources.shared.setLibrary(URL(fileURLWithPath: parts[2]), kind: kind)
                    return true
                case "setting":
                    return FirstRowHarness.performSettingCommand(parts)
                case "type":
                    // type:<text> types it as if from a keyboard.
                    NotificationCenter.default.post(name: .firstRowHarnessTypeText, object: nil, userInfo: ["text": String(command.dropFirst("type:".count))])
                    return true
                default:
                    return false
                }
            }
        }

        var rootLayer: CALayer { controller.hostView.hostLayer }

        func layout(size: CGSize, scale: CGFloat) {
            controller.hostView.layout(size: size, scale: scale)
            if !started {
                started = true
                controller.start()
            }
        }

        func keyDown(_ key: PortableKey, isRepeat: Bool, modifiers: PortableModifiers, character: String?) {
            let shortcut = modifiers.contains(.control) || modifiers.contains(.meta)
            if shortcut, character == "q" || key.isEscape {
                NotificationCenter.default.post(name: .firstRowQuitRequested, object: nil)
                return
            }
            if shortcut, character == "," {
                controller.showMediaFolders()
                return
            }
            if modifiers.contains(.alt), key.isF4 {
                NotificationCenter.default.post(name: .firstRowQuitRequested, object: nil)
                return
            }
            guard let code = key.keyCode else { return }
            controller.handleKeyDown(code, isRepeat: isRepeat)
        }

        func keyUp(_ key: PortableKey) {
            guard let code = key.keyCode else { return }
            controller.handleKeyUp(code)
        }

        func textInput(_ text: String) {
            controller.menu?.handleTypedText(text)
        }

        func gamepad(_ button: GamepadButton, pressed: Bool) {
            GameControllerInput.current?.handle(button, pressed: pressed)
        }

        func pointerMoved(to point: CGPoint) {
            controller.handlePointer(.moved(point))
        }

        func pointerButton(_ button: PortablePointerButton, pressed: Bool, at point: CGPoint) {
            let resolved: PointerButton
            switch button {
            case .primary: resolved = .primary
            case .secondary: resolved = .secondary
            case .back: resolved = .back
            case .middle, .forward: return
            }
            controller.handlePointer(pressed ? .pressed(resolved, point) : .released(resolved, point))
        }

        func pointerScrolled(dx: CGFloat, dy: CGFloat, at point: CGPoint) {
            controller.handlePointer(.scrolled(dx: dx, dy: dy, precise: false, at: point))
        }

        func shouldQuitImmediately() -> Bool {
            // Closing the window fades out like Command-Escape on the Mac.
            NotificationCenter.default.post(name: .firstRowQuitRequested, object: nil)
            return false
        }
    }

    extension PortableKey {
        var keyCode: KeyCode? {
            switch self {
            case .up: .upArrow
            case .down: .downArrow
            case .left: .leftArrow
            case .right: .rightArrow
            case .enter: .enter
            case .escape: .escape
            case .delete: .delete
            case .space: .space
            case .other: nil
            }
        }

        var isEscape: Bool {
            if case .escape = self { return true }
            return false
        }

        var isF4: Bool {
            if case let .other(code) = self { return code == 0x4000_003D }
            return false
        }
    }

    /// Game controllers as arrow, select, back and play keys: the D-pad or left stick moves,
    /// A selects, B or Menu goes back and X plays or pauses, as on the Mac.
    final class GameControllerInput {
        nonisolated(unsafe) static weak var current: GameControllerInput?

        var onArrowKeyDown: (KeyCode) -> Void
        var onArrowKeyUp: (KeyCode) -> Void
        var onEnter: () -> Void
        var onBackspace: () -> Void
        var onSpace: () -> Void
        private var heldDirections: [KeyCode: Int] = [:]

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
        }

        func startMonitoringControllersIfNeeded() {
            Self.current = self
        }

        func stopMonitoringControllers() {
            if Self.current === self { Self.current = nil }
        }

        func handle(_ button: GamepadButton, pressed: Bool) {
            let direction: KeyCode? = switch button {
            case .up: .upArrow
            case .down: .downArrow
            case .left: .leftArrow
            case .right: .rightArrow
            default: nil
            }
            if let direction {
                // The D-pad and the stick can hold the same direction; release it once both let go.
                let count = heldDirections[direction, default: 0] + (pressed ? 1 : -1)
                heldDirections[direction] = max(0, count)
                if pressed, count == 1 { onArrowKeyDown(direction) }
                if !pressed, count <= 0 { onArrowKeyUp(direction) }
                return
            }
            guard pressed else { return }
            switch button {
            case .south: onEnter()
            case .east, .back, .start: onBackspace()
            case .west: onSpace()
            default: break
            }
        }
    }
#endif
