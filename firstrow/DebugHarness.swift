import Foundation
#if os(macOS)
    import AppKit
#endif

/// Dev harness: `FIRSTROW_HARNESS=1` runs the app in a background window driven by a command FIFO.
enum FirstRowHarness {
    #if DEBUG || FIRSTROW_HARNESS_BUILD
        static let isActive = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS"] == "1"
    #else
        static let isActive = false
    #endif

    /// A test run starts at the menus, so its first key isn't spent skipping the intro movie;
    /// `FIRSTROW_HARNESS_INTRO=1` has it open as it does for anyone else.
    static var startsAtMenus: Bool {
        #if FIRSTROW_PORTABLE
            // (On Linux and Windows any build takes a test script, a released one included.)
            let isTestRun = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS"] == "1"
        #else
            let isTestRun = isActive
        #endif
        return isTestRun && ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_INTRO"] != "1"
    }

    /// `FIRSTROW_HARNESS_MUSIC=<folder>`: audio files there stand in for the Music library.
    static var musicFolderOverride: URL? {
        guard isActive, let path = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_MUSIC"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var moviesFolderOverride: URL? {
        guard isActive, let path = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_MOVIES"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Where the harness's pointer commands go once the menus are up.
    @MainActor static var pointerEventSink: ((PointerEvent) -> Void)?
    /// Pulls the selected row past the end of its list, as a Siri Remote swipe does on Apple TV.
    @MainActor static var rubberBandSink: ((CGFloat) -> Void)?
    /// The menus, for the commands that drive them directly (playfolder, playmovie).
    @MainActor static weak var harnessMenu: MenuView?
    /// Plays the look's intro movie, as after Get Started (the `intro` command).
    @MainActor static var introSink: (() -> Void)?
    /// Turns the test window upright (true) or on its side, as a foldable is turned (the
    /// `stance` command, with `FIRSTROW_HARNESS_SCENE=duo`).
    @MainActor static var stanceSink: ((Bool) -> Void)?
    /// Whether the test window, standing upright, is bent at its fold or out flat (the `fold`
    /// command, or `FIRSTROW_HARNESS_FOLD=half` from the start), and what lays it out again.
    @MainActor static var standsBent = ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_FOLD"] == "half"
    @MainActor static var foldSink: (() -> Void)?
    @MainActor private static var lastPointerLocation = CGPoint.zero

    /// `mouse:move|down|up|click|right|back:x:y` and `mouse:scroll:dx:dy[:precise]` (points from
    /// the window's top left), handed to the menus as the window would. Returns false if unknown.
    @MainActor
    static func performPointerCommand(_ parts: [String]) -> Bool {
        guard parts.first == "mouse", parts.count >= 4, let a = Double(parts[2]), let b = Double(parts[3]) else { return false }
        let point = CGPoint(x: a, y: b)
        switch parts[1] {
        case "move":
            lastPointerLocation = point
            pointerEventSink?(.moved(point))
        case "down":
            lastPointerLocation = point
            pointerEventSink?(.pressed(.primary, point))
        case "up":
            lastPointerLocation = point
            pointerEventSink?(.released(.primary, point))
        case "click":
            lastPointerLocation = point
            pointerEventSink?(.moved(point))
            pointerEventSink?(.pressed(.primary, point))
            pointerEventSink?(.released(.primary, point))
        case "right":
            lastPointerLocation = point
            pointerEventSink?(.pressed(.secondary, point))
            pointerEventSink?(.released(.secondary, point))
        case "back":
            lastPointerLocation = point
            pointerEventSink?(.pressed(.back, point))
        case "scroll":
            pointerEventSink?(.scrolled(dx: a, dy: b, precise: parts.count > 4 && parts[4] == "precise", at: lastPointerLocation))
        default:
            return false
        }
        return true
    }

    /// `setting:theme:classic|modern`, `setting:screensaver:<seconds>` (0 for never).
    @MainActor
    static func performSettingCommand(_ parts: [String]) -> Bool {
        guard parts.first == "setting", parts.count == 3 else { return false }
        switch parts[1] {
        case "theme":
            guard let theme = InterfaceTheme(rawValue: parts[2]) else { return false }
            AppSettings.theme = theme
        case "screensaver":
            guard let seconds = TimeInterval(parts[2]) else { return false }
            AppSettings.screenSaverDelay = seconds
        default:
            return false
        }
        return true
    }

    /// `code` shows a sample code screen, as signing in to a server does.
    @MainActor
    static func showSampleCode(on menu: MenuView?) {
        menu?.presentCodeDisplay(CodeDisplayState(
            title: "Quick Connect",
            message: "On a device signed in to Home Server, open Quick Connect in your profile and enter this code.",
            code: "482913",
            status: "Waiting for approval...",
        )) {}
    }
}

#if os(macOS) && (DEBUG || FIRSTROW_HARNESS_BUILD)
    extension FirstRowHarness {
        private static var fifoThread: Thread?
        private static var configuredWindowNumbers: Set<Int> = []

        static func applicationWillFinishLaunching() {
            guard isActive else { return }
            // Settings are keyed by bundle id, so the harness needs its own to leave the real app's alone.
            if !(Bundle.main.bundleIdentifier ?? "").hasSuffix(".harness") {
                FileHandle.standardError.write(Data("First Row harness: build with PRODUCT_BUNDLE_IDENTIFIER=<id>.harness so its settings stay apart from the real app's.\n".utf8))
                exit(64)
            }
            NSApplication.shared.setActivationPolicy(.accessory)
        }

        /// Keeps App Nap from throttling a covered window's display frames, which stalls animations.
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
            case "dumplayers":
                // Image-backed layers with their size and visibility, so memory in hidden layers shows up.
                for window in NSApplication.shared.windows {
                    guard let root = window.contentView?.layer else { continue }
                    var lines: [String] = []
                    var shownBytes = 0
                    var hiddenBytes = 0
                    func walk(_ layer: CALayer, path: String, hidden: Bool) {
                        let isHidden = hidden || layer.isHidden || layer.opacity <= 0
                        let name = "\(path)/\(String(describing: type(of: layer)))"
                        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                            let image = contents as! CGImage
                            let bytes = image.bytesPerRow * image.height
                            if isHidden { hiddenBytes += bytes } else { shownBytes += bytes }
                            lines.append("\(bytes / 1024)KB \(image.width)x\(image.height) \(isHidden ? "hidden" : "shown") \(name.suffix(140))")
                        }
                        for sublayer in layer.sublayers ?? [] { walk(sublayer, path: name, hidden: isHidden) }
                        if let mask = layer.mask { walk(mask, path: name + "/mask", hidden: isHidden) }
                    }
                    walk(root, path: "", hidden: false)
                    lines.sort { (Int($0.prefix { $0.isNumber }) ?? 0) > (Int($1.prefix { $0.isNumber }) ?? 0) }
                    fputs("[dumplayers] window \(window.windowNumber): \(lines.count) pictures, shown \(shownBytes / 1_048_576) MB, hidden \(hiddenBytes / 1_048_576) MB\n" + lines.joined(separator: "\n") + "\n", stderr)
                }
            case "windowshot" where parts.count == 2:
                // windowshot:/path.png: the window as the window server shows it (system glass
                // and all), which `shot` can't draw.
                saveWindowPicture(to: URL(fileURLWithPath: parts[1]))
            case "shot" where parts.count == 2:
                // shot:/path/to/file.png draws the window's layers to a picture (blurs and
                // other filters are left out), with no need for screen recording.
                saveLayerPicture(to: URL(fileURLWithPath: parts[1]))
            case "source" where parts.count == 3:
                // source:movies|music|photos:/path/to/folder
                guard let kind = MediaSources.FolderKind(rawValue: parts[1]) else { return }
                MediaSources.shared.addFolder(URL(fileURLWithPath: parts[2], isDirectory: true), kind: kind)
            case "library" where parts.count == 3:
                // library:iTunesXML|iPhoto:/path
                guard let kind = MediaSources.LibraryKind(rawValue: parts[1]) else { return }
                MediaSources.shared.setLibrary(URL(fileURLWithPath: parts[2]), kind: kind)
            case "theme" where parts.count == 2:
                // theme:classic|modern
                AppSettings.theme = InterfaceTheme(rawValue: parts[1]) ?? .classic
            case "type" where parts.count >= 2:
                // type:<text> types it as if from a keyboard (into a text field).
                NotificationCenter.default.post(name: .firstRowHarnessTypeText, object: nil, userInfo: ["text": String(command.dropFirst("type:".count))])
            case "intro":
                // intro plays the look's intro movie, the menus coming in after it fades to black.
                introSink?()
            case "turn":
                // turn has Now Playing turn round now, as it does every so often.
                harnessMenu?.performMusicNowPlayingFlip()
            case "code":
                showSampleCode(on: harnessMenu)
            case "stance" where parts.count == 2:
                // stance:portrait|landscape turns the test window, the layout gliding over.
                stanceSink?(parts[1] == "portrait")
            case "fold" where parts.count == 2:
                // fold:half|flat bends the upright test window at its fold, or lays it flat.
                standsBent = parts[1] == "half"
                foldSink?()
            case "volume" where parts.count == 2:
                // volume:0.5 shows the volume overlay at that level.
                NotificationCenter.default.post(name: .firstRowVolumeChanged, object: nil, userInfo: ["volume": Double(parts[1]) ?? 0])
            case "irremote" where parts.count == 4:
                // irremote:<usage page>:<usage>:<1|0> in hex, as the infrared receiver sends them.
                guard let page = UInt32(parts[1], radix: 16), let usage = UInt32(parts[2], radix: 16) else { return }
                AppleRemoteInput.shared.handle(page: page, usage: usage, pressed: parts[3] == "1")
            case "rubberband" where parts.count == 2:
                // rubberband:<scene points>
                rubberBandSink?(CGFloat(Double(parts[1]) ?? 0))
            case "playfolder" where parts.count == 2:
                // playfolder:<folder>: plays the audio files there as a list, from the first.
                guard let menu = harnessMenu else { return }
                let folder = URL(fileURLWithPath: parts[1], isDirectory: true)
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
                guard let first = songs.first else { return }
                menu.startMusicPlayback(from: first, trackIndex: 0, trackCount: songs.count, playbackQueue: songs)
            case "playmovie" where parts.count == 2:
                // playmovie:<file>
                harnessMenu?.startMoviePlayback(from: URL(fileURLWithPath: parts[1]))
            case "clearresume":
                // Empties Continue Watching.
                MovieResumeStore.removeAll()
            case "tvbutton":
                // The Siri Remote's TV button.
                SiriRemoteInput.shared.onTVButton()
            case "mouse":
                _ = performPointerCommand(parts)
            case "setting":
                _ = performSettingCommand(parts)
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
            SyntheticKeyEvents.post(key, down: type == .keyDown)
        }

        @MainActor
        private static func saveWindowPicture(to url: URL) {
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let window = NSApplication.shared.windows.first(where: { $0 is FirstRowWindow }),
                  let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage")
            else { return }
            let capture = unsafeBitCast(symbol, to: Capture.self)
            // Just this window, without its frame.
            guard let image = capture(.null, 0x8, UInt32(window.windowNumber), 0x1)?.takeRetainedValue() else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }

        @MainActor
        private static func saveLayerPicture(to url: URL) {
            guard let window = NSApplication.shared.windows.first(where: { $0 is FirstRowWindow }),
                  let layer = window.contentView?.layer
            else { return }
            let scale = window.backingScaleFactor
            let size = layer.bounds.size
            guard let context = CGContext(
                data: nil,
                width: Int(size.width * scale),
                height: Int(size.height * scale),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ) else { return }
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
            context.scaleBy(x: scale, y: scale)
            if layer.isGeometryFlipped == false, window.contentView?.isFlipped == true {
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
            }
            layer.render(in: context)
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }
#elseif os(macOS)
    extension FirstRowHarness {
        static func applicationWillFinishLaunching() {}
        static func applicationDidFinishLaunching() {}
    }
#endif
