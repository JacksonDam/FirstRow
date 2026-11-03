import Foundation
#if os(macOS)
    import AppKit
#endif

/// A development harness for running First Row without taking over the Mac.
///
/// Debug builds, or Release builds made with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=FIRSTROW_HARNESS_BUILD`.
/// Launch with `FIRSTROW_HARNESS=1` (for example
/// `open -g -n -a "First Row.app" --env FIRSTROW_HARNESS=1`) and the app:
/// - runs as a background accessory app in a 1280x720 window behind other windows,
///   never activating, hiding the Dock or menu bar, or hiding the cursor;
/// - skips everything that would show a privacy prompt (Music, Photos, Podcasts,
///   external volumes, AppleScript), so libraries look empty;
/// - reads key commands, one per line, from the FIFO named by `FIRSTROW_HARNESS_FIFO`
///   (`down`, `up`, `left`, `right`, `enter`, `delete`, `escape`, `space`, or
///   `press:<key>` / `release:<key>` for holds);
/// - writes `{"pid":…, "windowNumber":…}` to `FIRSTROW_HARNESS_INFO` once its window exists,
///   for `screencapture -l <windowNumber>`.
/// Optional: `FIRSTROW_HARNESS_SIZE=WxH`, `FIRSTROW_HARNESS_ORIGIN=x,y`,
/// `FIRSTROW_HARNESS_MOVIES=<folder>` to use another folder as the Movies library.
enum FirstRowHarness {
    #if DEBUG || FIRSTROW_HARNESS_BUILD
        static let isActive = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS"] == "1"
    #else
        static let isActive = false
    #endif

    /// `FIRSTROW_HARNESS_MUSIC=<folder>`: audio files there stand in for the Music library.
    static var musicFolderOverride: URL? {
        guard isActive, let path = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_MUSIC"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var moviesFolderOverride: URL? {
        guard isActive, let path = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_MOVIES"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

#if os(macOS) && (DEBUG || FIRSTROW_HARNESS_BUILD)
    extension FirstRowHarness {
        private static var fifoThread: Thread?
        private static var configuredWindowNumbers: Set<Int> = []

        static func applicationWillFinishLaunching() {
            guard isActive else { return }
            NSApplication.shared.setActivationPolicy(.accessory)
        }

        /// Keeps App Nap away: a background app with a covered window gets its display frames
        /// throttled, which stalls SwiftUI animations (they advance on display frames) half way.
        private static var appNapActivity: NSObjectProtocol?

        static func applicationDidFinishLaunching() {
            guard isActive else { return }
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "First Row test harness",
            )
            Task { @MainActor in
                for _ in 0 ..< 100 {
                    configureWindows()
                    if !configuredWindowNumbers.isEmpty { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            startReadingCommands()
        }

        private static var windowSize: CGSize {
            let parts = (ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_SIZE"] ?? "1280x720")
                .split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : CGSize(width: 1280, height: 720)
        }

        private static var windowOrigin: CGPoint {
            let parts = (ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_ORIGIN"] ?? "0,0")
                .split(separator: ",").compactMap { Double($0) }
            return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : .zero
        }

        @MainActor
        static func configureWindows() {
            for window in NSApplication.shared.windows where !(window is NSPanel) && window.contentView != nil {
                window.alphaValue = 1
                window.isOpaque = true
                window.backgroundColor = .black
                window.hasShadow = false
                window.level = .normal
                window.collectionBehavior = [.fullScreenNone, .ignoresCycle]
                window.setFrame(NSRect(origin: windowOrigin, size: windowSize), display: true)
                window.orderBack(nil)
                if configuredWindowNumbers.insert(window.windowNumber).inserted {
                    writeInfo(windowNumber: window.windowNumber)
                }
            }
        }

        private static func writeInfo(windowNumber: Int) {
            guard let path = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_INFO"] else { return }
            let info = "{\"pid\":\(ProcessInfo.processInfo.processIdentifier),\"windowNumber\":\(windowNumber)}\n"
            try? info.write(toFile: path, atomically: true, encoding: .utf8)
        }

        private static func startReadingCommands() {
            guard let path = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_FIFO"] else { return }
            let thread = Thread {
                // O_RDWR keeps the FIFO open between writers, so each `echo down > fifo` works.
                let fd = open(path, O_RDWR)
                guard fd >= 0 else { return }
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 256)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    guard count > 0 else { continue }
                    pending.append(contentsOf: buffer[0 ..< count])
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = String(decoding: pending[pending.startIndex ..< newline], as: UTF8.self)
                        pending.removeSubrange(pending.startIndex ... newline)
                        let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !command.isEmpty else { continue }
                        DispatchQueue.main.async { MainActor.assumeIsolatedIfPossible { perform(command) } }
                    }
                }
            }
            thread.name = "FirstRowHarnessCommands"
            fifoThread = thread
            thread.start()
        }

        private static let keyCodes: [String: KeyCode] = [
            "down": .downArrow, "up": .upArrow, "left": .leftArrow, "right": .rightArrow,
            "enter": .enter, "return": .enter, "delete": .delete, "escape": .escape, "space": .space,
        ]

        @MainActor
        private static func perform(_ command: String) {
            let parts = command.split(separator: ":").map(String.init)
            switch parts.first {
            case "dumpviews":
                for window in NSApplication.shared.windows where window.contentView != nil {
                    var lines: [String] = []
                    func walk(_ view: NSView, depth: Int) {
                        guard depth < 40 else { return }
                        let name = String(describing: type(of: view))
                        let interesting = name.contains("PlatformView") || name.contains("Flipped") || depth < 3
                        if interesting {
                            lines.append(String(repeating: " ", count: depth) + "\(name.prefix(90)) frame=\(view.frame) hidden=\(view.isHidden) alpha=\(view.alphaValue) sublayers=\(view.layer?.sublayers?.count ?? -1)")
                        }
                        for sub in view.subviews { walk(sub, depth: depth + 1) }
                    }
                    walk(window.contentView!, depth: 0)
                    fputs("[dumpviews] window \(window.windowNumber) occlusion=\(window.occlusionState.rawValue)\n" + lines.joined(separator: "\n") + "\n", stderr)
                }
            case "settingswindow":
                // Shows the Settings window behind everything (never activating) for a screenshot.
                guard let window = MediaSourcesWindowController.shared.window else { return }
                MediaSourcesWindowController.shared.reloadForHarness()
                window.setFrameOrigin(NSPoint(x: 40, y: 360))
                window.orderBack(nil)
                fputs("[harness] settings window \(window.windowNumber)\n", stderr)
            case "source" where parts.count == 3:
                // source:movies|music|photos:/path/to/folder
                guard let kind = MediaSources.FolderKind(rawValue: parts[1]) else { return }
                MediaSources.shared.addFolder(URL(fileURLWithPath: parts[2], isDirectory: true), kind: kind)
            case "library" where parts.count == 3:
                // library:iTunesXML|iPhoto:/path
                guard let kind = MediaSources.LibraryKind(rawValue: parts[1]) else { return }
                MediaSources.shared.setLibrary(URL(fileURLWithPath: parts[2]), kind: kind)
            case "press" where parts.count == 2:
                guard let key = keyCodes[parts[1]] else { return }
                post(key, type: .keyDown)
            case "release" where parts.count == 2:
                guard let key = keyCodes[parts[1]] else { return }
                post(key, type: .keyUp)
            default:
                guard let key = keyCodes[command] else { return }
                post(key, type: .keyDown)
                post(key, type: .keyUp)
            }
        }

        private static func post(_ key: KeyCode, type: NSEvent.EventType) {
            let characters: String = switch key {
            case .enter: "\r"
            case .escape: "\u{1b}"
            case .delete: "\u{7f}"
            case .space: " "
            default: ""
            }
            // Window number 0: the event reaches the app's key monitors even though
            // the harness window is never the key window.
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: key.rawValue,
            ) else { return }
            NSApplication.shared.postEvent(event, atStart: false)
        }
    }
#elseif os(macOS)
    extension FirstRowHarness {
        static func applicationWillFinishLaunching() {}
        static func applicationDidFinishLaunching() {}
    }
#endif
