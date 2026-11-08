#if os(iOS) && (DEBUG || FIRSTROW_HARNESS_BUILD)
    import UIKit

    /// The iPhone and iPad side of the test harness: with `FIRSTROW_HARNESS=1`, commands are read
    /// a line at a time from the file or FIFO named in `FIRSTROW_HARNESS_FIFO` (the simulator can
    /// reach the Mac's paths), and touches go straight to the touch handling.
    ///
    /// - `touch:down|move|up|cancel:x:y` in the view's points
    /// - `touchmove:x:y:seconds` moves the finger there from where it is, steadily
    /// - `swipe:x1:y1:x2:y2:seconds` puts a finger down, moves it and lifts it
    /// - `theme:classic|modern`, `setting:touch|theme:...`
    /// - `nopicker` stops Movies Folder offering the folder picker this session
    /// - `down`, `up`, `left`, `right`, `enter`, `escape`, `delete`, `space`
    extension FirstRowHarness {
        @MainActor private static weak var touchView: TouchNavigationInputView?
        @MainActor private static weak var touchMenu: MenuView?
        @MainActor private static var fingerLocation = CGPoint.zero
        private static var commandThread: Thread?

        @MainActor
        static func startTouchHarness(menu: MenuView, touchView: TouchNavigationInputView) {
            guard isActive, commandThread == nil, let path = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_FIFO"] else { return }
            self.touchView = touchView
            touchMenu = menu
            let thread = Thread {
                let fd = open(path, O_RDWR)
                guard fd >= 0 else { return }
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 256)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    guard count > 0 else {
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                    pending.append(contentsOf: buffer[0 ..< count])
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = String(decoding: pending[pending.startIndex ..< newline], as: UTF8.self)
                        pending.removeSubrange(pending.startIndex ... newline)
                        let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !command.isEmpty else { continue }
                        DispatchQueue.main.async { MainActor.assumeIsolatedIfPossible { performTouchCommand(command) } }
                    }
                }
            }
            thread.name = "FirstRowTouchHarness"
            commandThread = thread
            thread.start()
        }

        private static let harnessKeys: [String: KeyCode] = [
            "down": .downArrow, "up": .upArrow, "left": .leftArrow, "right": .rightArrow,
            "enter": .enter, "escape": .escape, "delete": .delete, "space": .space,
        ]

        @MainActor
        private static func performTouchCommand(_ command: String) {
            let parts = command.split(separator: ":").map(String.init)
            let numbers = parts.dropFirst().compactMap(Double.init).map { CGFloat($0) }
            switch parts.first {
            case "touch" where parts.count == 4 && numbers.count == 2:
                let phase: TouchPhase? = switch parts[1] {
                case "down": .began
                case "move": .moved
                case "up": .ended
                case "cancel": .cancelled
                default: nil
                }
                guard let phase else { return }
                fingerLocation = CGPoint(x: numbers[0], y: numbers[1])
                touchView?.injectTouch(phase, at: fingerLocation)
            case "touchmove" where numbers.count == 3:
                moveFinger(to: CGPoint(x: numbers[0], y: numbers[1]), over: Double(numbers[2]), liftingAtEnd: false)
            case "swipe" where numbers.count == 5:
                fingerLocation = CGPoint(x: numbers[0], y: numbers[1])
                touchView?.injectTouch(.began, at: fingerLocation)
                moveFinger(to: CGPoint(x: numbers[2], y: numbers[3]), over: Double(numbers[4]), liftingAtEnd: true)
            case "theme" where parts.count == 2:
                AppSettings.theme = InterfaceTheme(rawValue: parts[1]) ?? .classic
            case "setting":
                _ = performSettingCommand(parts)
            case "nopicker":
                touchMenu?.hasPromptedMoviesFolderPickerThisSession = true
            default:
                guard let key = harnessKeys[command], let menu = touchMenu else { return }
                if [.upArrow, .downArrow, .leftArrow, .rightArrow].contains(key) {
                    menu.handleDirectionalPressBegan(key)
                    menu.handleDirectionalPressEnded(key)
                } else {
                    menu.handleKeyDown(key)
                }
            }
        }

        /// Moves the finger in steps of a sixtieth of a second, as a real drag arrives.
        @MainActor
        private static func moveFinger(to target: CGPoint, over seconds: Double, liftingAtEnd: Bool) {
            let from = fingerLocation
            let steps = max(1, Int(seconds * 60))
            Task { @MainActor in
                for step in 1 ... steps {
                    try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / 60))
                    let progress = CGFloat(step) / CGFloat(steps)
                    fingerLocation = CGPoint(x: from.x + (target.x - from.x) * progress, y: from.y + (target.y - from.y) * progress)
                    touchView?.injectTouch(.moved, at: fingerLocation)
                }
                if liftingAtEnd { touchView?.injectTouch(.ended, at: fingerLocation) }
            }
        }
    }
#endif
