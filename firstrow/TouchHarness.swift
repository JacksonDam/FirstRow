#if os(iOS) && (DEBUG || FIRSTROW_HARNESS_BUILD)
    import UIKit

    /// The iPhone and iPad side of the test harness: with `FIRSTROW_HARNESS=1`, commands are read
    /// a line at a time from the file or FIFO named in `FIRSTROW_HARNESS_FIFO` (the simulator can
    /// reach the Mac's paths), and touches go straight to the touch handling.
    ///
    /// - `touch:down|move|up|cancel:x:y` in the view's points
    /// - `touchmove:x:y:seconds` moves the finger there from where it is, steadily
    /// - `swipe:x1:y1:x2:y2:seconds` puts a finger down, moves it and lifts it
    /// - `rowtap:<index>`, `rowtitle:<title>` tap a visible row of the list in front
    /// - `listswipe:<from>:<to>:<seconds>[:<hold>]` drags the list in front (heights as fractions
    ///   of its visible part); `listslide:<from>:<to>:<seconds>:<hold>` slides the selection and
    ///   lets go without choosing; `rowslide:<from>:<to>:<seconds>[:<hold>]` does the same from
    ///   one row's middle to another's; `back` taps the Back button, `control:<name>` any of
    ///   the buttons (back, play, previous, next, skipback, skipforward, options, lyrics)
    /// - `wait:<seconds>` pauses the script (for a script copied into the app's own folder on a
    ///   device, where relative `FIRSTROW_HARNESS_FIFO`/`_LOG` paths resolve to its tmp folder)
    /// - `FIRSTROW_DEBUG_RENDER=1` logs render pass times and frame pacing
    /// - `theme:classic|modern`, `setting:theme:...`, `setting:screensaver:<seconds>` (0 for never)
    /// - `nopicker` stops Movies Folder offering the folder picker this session
    /// - `playfolder:<folder>` plays a folder's audio files as a list, into Now Playing
    /// - `down`, `up`, `left`, `right`, `enter`, `escape`, `delete`, `space`
    extension FirstRowHarness {
        @MainActor private static weak var touchView: TouchNavigationInputView?
        @MainActor private static weak var touchMenu: MenuView?
        @MainActor private static var fingerLocation = CGPoint.zero
        private static var commandThread: Thread?

        @MainActor
        static func startTouchHarness(menu: MenuView, touchView: TouchNavigationInputView) {
            guard isActive, commandThread == nil, let named = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_FIFO"] else { return }
            let path = resolvedHarnessPath(named)
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
                        // `wait:seconds` pauses the script, so a whole script can sit in a file.
                        if command.hasPrefix("wait:"), let seconds = Double(command.dropFirst(5)) {
                            Thread.sleep(forTimeInterval: seconds)
                            continue
                        }
                        DispatchQueue.main.async { MainActor.assumeIsolatedIfPossible { performTouchCommand(command) } }
                    }
                }
            }
            thread.name = "FirstRowTouchHarness"
            commandThread = thread
            thread.start()
            if ProcessInfo.processInfo.environment["FIRSTROW_DEBUG_RENDER"] == "1" {
                FrameProbe.shared.start()
            }
        }

        /// Logs how evenly frames arrive, once a second, so dropped frames show in the log.
        @MainActor
        final class FrameProbe: NSObject {
            static let shared = FrameProbe()
            private var link: CADisplayLink?
            private var last: CFTimeInterval = 0
            private var frames = 0
            private var hitches = 0
            private var worst: CFTimeInterval = 0
            private var windowStart: CFTimeInterval = 0

            func start() {
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                if #available(iOS 15.0, *) { link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120) }
                link.add(to: .main, forMode: .common)
                self.link = link
            }

            @objc private func tick(_ link: CADisplayLink) {
                let now = link.timestamp
                let expected = link.targetTimestamp - link.timestamp
                if last > 0 {
                    let interval = now - last
                    frames += 1
                    if interval > expected * 1.5 { hitches += 1 }
                    worst = max(worst, interval)
                }
                last = now
                if windowStart == 0 { windowStart = now }
                if now - windowStart >= 1 {
                    FirstRowHarness.touchLog(String(format: "[frames] %d in %.2f s (%.0f Hz), %d late, worst %.1f ms", frames, now - windowStart, 1 / max(0.001, expected), hitches, worst * 1000))
                    frames = 0
                    hitches = 0
                    worst = 0
                    windowStart = now
                }
            }
        }

        /// A path as given, or for a relative one (on a device, where the app can't reach the
        /// Mac), the same path inside the app's temporary folder.
        static func resolvedHarnessPath(_ path: String) -> String {
            path.hasPrefix("/") ? path : (NSTemporaryDirectory() as NSString).appendingPathComponent(path)
        }

        /// Appends a line to the file named in `FIRSTROW_HARNESS_LOG`, for checking what a touch did.
        static func touchLog(_ message: String) {
            guard isActive, let named = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_LOG"] else { return }
            let path = resolvedHarnessPath(named)
            guard let handle = FileHandle(forWritingAtPath: path) ?? {
                FileManager.default.createFile(atPath: path, contents: nil)
                return FileHandle(forWritingAtPath: path)
            }() else { return }
            handle.seekToEndOfFile()
            handle.write(Data((message + "\n").utf8))
            handle.closeFile()
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
            case "rowtitle" where parts.count == 2:
                // rowtitle:<title>: a tap on the visible row with that title.
                guard let menu = touchMenu, let level = menu.pointerActiveListLevel else { return }
                let items: [MenuListItemConfig] = switch level {
                case .root: menu.rootListItems()
                case .submenu: menu.submenuListItems()
                case .third: menu.thirdMenuListItems()
                }
                guard let index = items.firstIndex(where: { $0.title == parts[1] }) else {
                    touchLog("[harness] no row called \(parts[1]) in \(items.map(\.title))")
                    return
                }
                performTouchCommand("rowtap:\(index)")
            case "rowtap" where numbers.count == 1:
                // A tap on a visible row of the list in front, wherever it is on this screen.
                guard let row = scanActiveList()?.rows[Int(numbers[0])] else {
                    touchLog("[harness] row \(Int(numbers[0])) isn't showing")
                    return
                }
                let point = CGPoint(x: row.midX, y: row.midY)
                touchView?.injectTouch(.began, at: point)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    touchView?.injectTouch(.ended, at: point)
                }
            case "listswipe" where numbers.count == 3 || numbers.count == 4:
                // listswipe:from:to:seconds[:hold], heights as fractions of the list's visible
                // part: down, an optional wait, a steady move, and up.
                guard let list = scanActiveList()?.frame else {
                    touchLog("[harness] no list showing")
                    return
                }
                let from = CGPoint(x: list.midX, y: list.minY + list.height * numbers[0])
                let to = CGPoint(x: list.midX, y: list.minY + list.height * numbers[1])
                fingerLocation = from
                touchView?.injectTouch(.began, at: from)
                let hold = numbers.count == 4 ? Double(numbers[3]) : 0
                Task { @MainActor in
                    if hold > 0 { try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000)) }
                    moveFinger(to: to, over: Double(numbers[2]), liftingAtEnd: true)
                }
            case "listslide" where numbers.count == 4:
                // listslide:from:to:seconds:hold: holds, slides the selection and lets it go
                // without choosing anything.
                guard let list = scanActiveList()?.frame else { return }
                let from = CGPoint(x: list.midX, y: list.minY + list.height * numbers[0])
                let to = CGPoint(x: list.midX, y: list.minY + list.height * numbers[1])
                fingerLocation = from
                touchView?.injectTouch(.began, at: from)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Double(numbers[3]) * 1_000_000_000))
                    moveFinger(to: to, over: Double(numbers[2]), liftingAtEnd: false)
                    try? await Task.sleep(nanoseconds: UInt64((Double(numbers[2]) + 0.3) * 1_000_000_000))
                    touchView?.injectTouch(.cancelled, at: fingerLocation)
                }
            case "rowslide" where numbers.count == 3 || numbers.count == 4:
                // rowslide:from:to:seconds[:hold]: a finger down on one visible row, an optional
                // wait, a slide to another row's middle, then let go without choosing.
                guard let rows = scanActiveList()?.rows, let from = rows[Int(numbers[0])], let to = rows[Int(numbers[1])] else {
                    touchLog("[harness] rows \(Int(numbers[0])) and \(Int(numbers[1])) aren't both showing")
                    return
                }
                fingerLocation = CGPoint(x: from.midX, y: from.midY)
                touchView?.injectTouch(.began, at: fingerLocation)
                let hold = numbers.count == 4 ? Double(numbers[3]) : 0
                Task { @MainActor in
                    if hold > 0 { try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000)) }
                    moveFinger(to: CGPoint(x: to.midX, y: to.midY), over: Double(numbers[2]), liftingAtEnd: false)
                    try? await Task.sleep(nanoseconds: UInt64((Double(numbers[2]) + 0.4) * 1_000_000_000))
                    touchView?.injectTouch(.cancelled, at: fingerLocation)
                }
            case "back":
                guard let view = touchView, let hitTester = touchMenu?.pointer.hitTester else { return }
                var found: CGPoint?
                for y in stride(from: CGFloat(0), to: view.bounds.height * 0.4, by: 4) {
                    for x in stride(from: CGFloat(0), to: view.bounds.width * 0.4, by: 4) where hitTester.touchControl(at: CGPoint(x: x, y: y)) == .back {
                        found = found ?? CGPoint(x: x + 20, y: y + 20)
                    }
                }
                guard let point = found else {
                    touchLog("[harness] no Back button")
                    return
                }
                touchView?.injectTouch(.began, at: point)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    touchView?.injectTouch(.ended, at: point)
                }
            case "control" where parts.count == 2:
                // control:<name>: a tap on one of the on-screen buttons, found by looking for it.
                let controls: [String: TouchControl] = [
                    "back": .back, "play": .playPause, "previous": .previous, "next": .next,
                    "skipback": .skipBack, "skipforward": .skipForward, "lyrics": .lyrics,
                ]
                if ["options", "subtitles", "audio", "speed"].contains(parts[1]), let view = touchView, let hitTester = touchMenu?.pointer.hitTester {
                    // control:options: the movie's options button above the bar.
                    var found: CGPoint?
                    for y in stride(from: CGFloat(0), to: view.bounds.height, by: 4) {
                        for x in stride(from: CGFloat(0), to: view.bounds.width, by: 4) where found == nil && hitTester.movieOptionsButton(at: CGPoint(x: x, y: y)) != nil {
                            found = CGPoint(x: x + 10, y: y + 10)
                        }
                    }
                    guard let point = found else {
                        touchLog("[harness] no \(parts[1]) button showing")
                        return
                    }
                    touchView?.injectTouch(.began, at: point)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        touchView?.injectTouch(.ended, at: point)
                    }
                    return
                }
                guard let wanted = controls[parts[1]], let view = touchView, let hitTester = touchMenu?.pointer.hitTester else { return }
                var found: CGPoint?
                for y in stride(from: CGFloat(0), to: view.bounds.height, by: 6) {
                    for x in stride(from: CGFloat(0), to: view.bounds.width, by: 6) where found == nil && hitTester.touchControl(at: CGPoint(x: x, y: y)) == wanted {
                        found = CGPoint(x: x + 16, y: y + 16)
                    }
                }
                guard let point = found else {
                    touchLog("[harness] no \(parts[1]) button showing")
                    return
                }
                touchView?.injectTouch(.began, at: point)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    touchView?.injectTouch(.ended, at: point)
                }
            case "playmovie" where parts.count == 2:
                // playmovie:<file>: plays a movie, for trying its controls.
                touchMenu?.startMoviePlayback(from: URL(fileURLWithPath: resolvedHarnessPath(parts[1])))
            case "playfolder" where parts.count == 2:
                // playfolder:<folder>: plays the audio files there as a list, from the first,
                // for trying Now Playing's list and lyrics where there's no music library.
                guard let menu = touchMenu else { return }
                let folder = URL(fileURLWithPath: resolvedHarnessPath(parts[1]), isDirectory: true)
                let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                    .filter { ["m4a", "mp3"].contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                let songs = files.enumerated().map { index, url in
                    MenuView.MusicLibrarySongEntry(
                        id: "harness-\(index)", title: String(url.deletingPathExtension().lastPathComponent.dropFirst(3)),
                        artist: "Test Band", album: "Queue Test", genre: "", composer: "", durationSeconds: 60,
                        trackNumber: index + 1, discNumber: 1, artworkAlbumKey: nil, url: url, artwork: nil,
                    )
                }
                guard let first = songs.first else {
                    touchLog("[harness] no songs in \(folder.path)")
                    return
                }
                menu.startMusicPlayback(from: first, trackIndex: 0, trackCount: songs.count, playbackQueue: songs)
            case "theme" where parts.count == 2:
                AppSettings.theme = InterfaceTheme(rawValue: parts[1]) ?? .classic
            case "setting":
                _ = performSettingCommand(parts)
            case "nopicker":
                touchMenu?.hasPromptedMoviesFolderPickerThisSession = true
            case "intro":
                introSink?()
            case "code":
                showSampleCode(on: touchMenu)
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

        /// Finds the list in front by asking what lies under points all over the window: each
        /// visible row's rectangle, and the box around them.
        @MainActor
        private static func scanActiveList() -> (frame: CGRect, rows: [Int: CGRect])? {
            guard let view = touchView, let menu = touchMenu, let hitTester = menu.pointer.hitTester,
                  let level = menu.pointerActiveListLevel
            else { return nil }
            var rows: [Int: CGRect] = [:]
            let size = view.bounds.size
            for y in stride(from: CGFloat(1), to: size.height, by: 3) {
                for x in stride(from: CGFloat(1), to: size.width, by: 12) {
                    let point = CGPoint(x: x, y: y)
                    guard case let .menuRow(rowLevel, index)? = hitTester.pointerTarget(at: point), rowLevel == level else { continue }
                    rows[index] = rows[index].map { $0.union(CGRect(origin: point, size: .zero)) } ?? CGRect(origin: point, size: .zero)
                }
            }
            guard let frame = rows.values.reduce(nil, { (partial: CGRect?, rect) in partial.map { $0.union(rect) } ?? rect }) else { return nil }
            touchLog(String(format: "[harness] window %.0fx%.0f, list %.0f,%.0f %.0fx%.0f, rows %@", size.width, size.height, frame.minX, frame.minY, frame.width, frame.height, rows.keys.sorted().map(String.init).joined(separator: ",")))
            return (frame, rows)
        }

        /// Moves the finger in steps of a 120th of a second, as a real drag arrives on ProMotion.
        @MainActor
        private static func moveFinger(to target: CGPoint, over seconds: Double, liftingAtEnd: Bool) {
            let from = fingerLocation
            let steps = max(1, Int(seconds * 120))
            Task { @MainActor in
                for step in 1 ... steps {
                    try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 / 120))
                    let progress = CGFloat(step) / CGFloat(steps)
                    fingerLocation = CGPoint(x: from.x + (target.x - from.x) * progress, y: from.y + (target.y - from.y) * progress)
                    touchView?.injectTouch(.moved, at: fingerLocation)
                }
                if liftingAtEnd { touchView?.injectTouch(.ended, at: fingerLocation) }
            }
        }
    }
#endif
