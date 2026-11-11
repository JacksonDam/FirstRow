#if FIRSTROW_PORTABLE
    import FirstRowPortable
    import Foundation
    #if os(Windows)
        import WinSDK
    #elseif canImport(Glibc)
        import Glibc
    #endif

    @MainActor
    func makeSpotifyPageHost() -> SpotifyPageHost? {
        guard let browser = SpotifyBrowserHost.findBrowser() else { return nil }
        return SpotifyBrowserHost(browser: browser)
    }

    func spotifyPageHostUnavailableReason() -> String {
        #if os(Windows)
            "Spotify Needs Microsoft Edge or Google Chrome"
        #else
            "Spotify Needs Google Chrome or Chromium"
        #endif
    }

    /// The browser, so it can be closed when First Row quits: asked through DevTools (a snap's
    /// launcher stands between First Row and the browser), and stopped if it doesn't listen.
    nonisolated(unsafe) private var spotifyBrowserProcessID: Int32 = 0
    nonisolated(unsafe) private var spotifyBrowserControl: LocalWebSocket?

    /// Spotify's web player in a Chrome, Edge or Chromium of its own, with its own profile,
    /// driven through the DevTools protocol. It runs without a window, and opens one to sign in.
    @MainActor
    final class SpotifyBrowserHost: SpotifyPageHost {
        var messageHandler: ((String) -> Void)?
        var failureHandler: ((String) -> Void)?

        private static let playerURL = URL(string: "https://open.spotify.com/")!
        private static let bindingName = "firstRowSpotifyPost"

        private let browser: URL
        private let profile: URL
        private var process: Process?
        private var socket: LocalWebSocket?
        private var launchID = 0
        private var isShowingSignIn = false
        private var signInClosed: (() -> Void)?
        private var isBridgeReady = false
        private var queuedScripts: [String] = []
        private var nextCommandID = 1
        private var commandReplies: [Int: ([String: Any]) -> Void] = [:]
        private var heartbeat: Timer?
        /// The sign-in window's cookies, on their way to the player's browser (see `dismissSignIn`).
        private var carriedCookies: [[String: Any]] = []
        private var handOverID = 0
        /// The launch whose browser has been sent to Spotify's page.
        private var openedLaunchID = 0

        init(browser: URL) {
            self.browser = browser
            profile = Self.profileDirectory(for: browser)
            PortableApplication.quitHandlers.append { [weak self] in
                self?.closeForQuit()
            }
            // Only if First Row exits some other way.
            atexit {
                spotifyBrowserControl?.send(#"{"id":1,"method":"Browser.close"}"#)
                let pid = spotifyBrowserProcessID
                guard pid > 0 else { return }
                #if os(Windows)
                    if let handle = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(pid)) {
                        TerminateProcess(handle, 0)
                        CloseHandle(handle)
                    }
                #else
                    kill(pid, SIGTERM)
                #endif
            }
        }

        // MARK: - Finding a browser

        static func findBrowser() -> URL? {
            let environment = ProcessInfo.processInfo.environment
            if let chosen = environment["FIRSTROW_SPOTIFY_BROWSER"], FileManager.default.isExecutableFile(atPath: chosen) {
                return URL(fileURLWithPath: chosen)
            }
            #if os(Windows)
                let roots = ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"].compactMap { environment[$0] }
                let paths = ["Google\\Chrome\\Application\\chrome.exe", "Microsoft\\Edge\\Application\\msedge.exe", "Chromium\\Application\\chrome.exe"]
                for path in paths {
                    for root in roots {
                        let candidate = root + "\\" + path
                        if FileManager.default.fileExists(atPath: candidate) {
                            return URL(fileURLWithPath: candidate)
                        }
                    }
                }
                return nil
            #else
                let names = ["google-chrome-stable", "google-chrome", "chromium", "chromium-browser", "microsoft-edge-stable", "microsoft-edge"]
                let folders = (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":").map(String.init) + ["/opt/google/chrome", "/snap/bin"]
                for name in names {
                    for folder in folders {
                        let candidate = folder + "/" + name
                        if FileManager.default.isExecutableFile(atPath: candidate) {
                            return URL(fileURLWithPath: candidate)
                        }
                    }
                }
                return nil
            #endif
        }

        /// The browser's own profile, apart from the person's. A Chromium installed as a snap can
        /// only write in visible folders of the home folder and in its own.
        private static func profileDirectory(for browser: URL) -> URL {
            let environment = ProcessInfo.processInfo.environment
            #if os(Windows)
                let base = environment["LOCALAPPDATA"] ?? ((environment["USERPROFILE"] ?? "C:\\") + "\\AppData\\Local")
                return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("First Row", isDirectory: true)
                    .appendingPathComponent("Spotify", isDirectory: true)
            #else
                let home = environment["HOME"] ?? NSHomeDirectory()
                if browser.path.hasPrefix("/snap/") {
                    return URL(fileURLWithPath: home + "/snap/\(browser.lastPathComponent)/common/first-row-spotify", isDirectory: true)
                }
                let base = environment["XDG_DATA_HOME"] ?? (home + "/.local/share")
                return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("first-row/spotify", isDirectory: true)
            #endif
        }

        // MARK: - SpotifyPageHost

        func load(_ url: URL) {
            if socket != nil, !isShowingSignIn {
                isBridgeReady = false
                command("Page.navigate", ["url": url.absoluteString])
            } else {
                launch(url, visible: false)
            }
        }

        func evaluate(_ script: String) {
            guard socket != nil, isBridgeReady else {
                queuedScripts.append(script)
                return
            }
            command("Runtime.evaluate", ["expression": script])
        }

        func presentSignIn(_ url: URL, closed: @escaping () -> Void) {
            signInClosed = closed
            carriedCookies = []
            launch(url, visible: true)
        }

        func dismissSignIn() {
            signInClosed = nil
            guard isShowingSignIn else { return }
            // Signed in: back to the player, out of sight, in a browser started afresh. The
            // sign-in is the window's cookies, and they go across by hand: read here, and given
            // to the new browser before it opens Spotify. Left to the browser, they reach the
            // new one only if the old one wrote them all to disk as it closed (it had held them
            // for a second or two), in a form the new one reads; when they didn't, the player
            // came up signed out and the menu went back to Sign In.
            handOverID += 1
            let id = handOverID
            guard socket != nil else {
                finishHandOver(id, cookies: [])
                return
            }
            command("Storage.getCookies") { [weak self] reply in
                let cookies = (reply["result"] as? [String: Any])?["cookies"] as? [[String: Any]]
                self?.finishHandOver(id, cookies: cookies ?? [])
            }
            // (A browser that doesn't answer isn't waited for.)
            Task { @MainActor [weak self] in
                try? await firstRowSleep(1.5)
                self?.finishHandOver(id, cookies: [])
            }
        }

        private func finishHandOver(_ id: Int, cookies: [[String: Any]]) {
            guard id == handOverID else { return }
            handOverID += 1
            spotifyDebugLog("taking \(cookies.count) cookies from the sign-in window to the player")
            carriedCookies = cookies
            launch(Self.playerURL, visible: false)
        }

        /// A cookie as a browser lists it, in the form a browser takes one.
        private static func cookieToSet(_ cookie: [String: Any]) -> [String: Any] {
            var out: [String: Any] = [:]
            for key in ["name", "value", "domain", "path", "secure", "httpOnly", "sameSite", "priority", "sourceScheme", "sourcePort", "partitionKey"] {
                if let value = cookie[key] { out[key] = value }
            }
            // (One without a date lasts as long as the browser runs, as it did in the window.)
            if cookie["session"] as? Bool != true, let expires = (cookie["expires"] as? NSNumber)?.doubleValue, expires > 0 {
                out["expires"] = expires
            }
            return out
        }

        /// Sends the hidden browser to Spotify's page, once.
        private func openPlayer(_ url: URL, launchID id: Int) {
            guard id == launchID, openedLaunchID != id else { return }
            openedLaunchID = id
            command("Page.navigate", ["url": url.absoluteString])
        }

        func forgetAccount(_ completion: @escaping () -> Void) {
            carriedCookies = []
            guard socket != nil else {
                try? FileManager.default.removeItem(at: profile)
                completion()
                return
            }
            command("Network.clearBrowserCookies")
            command("Storage.clearDataForOrigin", ["origin": "https://open.spotify.com", "storageTypes": "all"])
            command("Storage.clearDataForOrigin", ["origin": "https://accounts.spotify.com", "storageTypes": "all"]) { _ in
                completion()
            }
        }

        // MARK: - Running the browser

        private var isHeadless: Bool {
            ProcessInfo.processInfo.environment["FIRSTROW_SPOTIFY_BROWSER_WINDOW"] != "1"
        }

        private func launch(_ url: URL, visible: Bool) {
            let previous = stopBrowser()
            // (A sign-in on its way to the player goes with this launch, or not at all.)
            handOverID += 1
            launchID += 1
            let id = launchID
            isShowingSignIn = visible
            isBridgeReady = false
            let profile = profile
            let portFile = profile.appendingPathComponent("DevToolsActivePort")
            Task { @MainActor in
                // Waiting for browsers to close happens off the main thread.
                await Task.detached {
                    if let previous { Self.finishClosing(previous) }
                    try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
                    Self.closeLeftoverBrowser(portFile: portFile)
                    try? FileManager.default.removeItem(at: portFile)
                }.value
                guard id == self.launchID else { return }
                self.startBrowser(url, visible: visible, launchID: id, portFile: portFile)
            }
        }

        private func startBrowser(_ url: URL, visible: Bool, launchID id: Int, portFile: URL) {
            var arguments = [
                "--user-data-dir=\(profile.path)",
                "--remote-debugging-port=0",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-default-apps",
                "--disable-sync",
                "--autoplay-policy=no-user-gesture-required",
                "--disable-background-timer-throttling",
                "--disable-renderer-backgrounding",
                "--disable-backgrounding-occluded-windows",
                "--disable-features=Translate,MediaRouter,GlobalMediaControls",
            ]
            #if os(Linux)
                // Keeps the browser from asking to unlock the keyring for its own profile.
                arguments.append("--password-store=basic")
            #endif
            if Harness.isActive {
                arguments.append("--mute-audio")
            }
            if visible {
                arguments += ["--app=\(url.absoluteString)", "--window-size=540,780"]
            } else {
                if isHeadless {
                    arguments.append("--headless=new")
                }
                arguments.append("about:blank")
            }
            let process = Process()
            process.executableURL = browser
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in self?.browserExited(launchID: id) }
            }
            do {
                try process.run()
            } catch {
                failureHandler?("Spotify's browser could not start")
                return
            }
            self.process = process
            spotifyBrowserProcessID = process.processIdentifier
            spotifyDebugLog("started \(browser.lastPathComponent) (\(visible ? "sign-in window" : "hidden"))")
            Task { @MainActor in
                await self.connect(launchID: id, portFile: portFile, url: visible ? nil : url)
            }
        }

        /// Asks the browser to close, and stops it if it hasn't within two seconds.
        private func closeForQuit() {
            heartbeat?.invalidate()
            heartbeat = nil
            spotifyBrowserControl?.send(#"{"id":1,"method":"Browser.close"}"#)
            if let process {
                process.terminationHandler = nil
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                }
            }
            process = nil
            socket?.onClose = nil
            socket?.close()
            socket = nil
            spotifyBrowserControl?.close()
            spotifyBrowserControl = nil
            spotifyBrowserProcessID = 0
        }

        /// A browser left running on this profile (after a crash, say) would take over new launches.
        private nonisolated static func closeLeftoverBrowser(portFile: URL) {
            guard let port = readPort(portFile),
                  let version = LocalWebSocket.get(port: port, path: "/json/version"),
                  let info = object(version),
                  let address = info["webSocketDebuggerUrl"] as? String,
                  let browserPath = path(of: address),
                  let socket = LocalWebSocket(port: port, path: browserPath)
            else { return }
            spotifyDebugLog("closing a browser left running")
            socket.send(#"{"id":1,"method":"Browser.close"}"#)
            Thread.sleep(forTimeInterval: 1)
            socket.close()
        }

        /// Asks the browser to close, returning its process to wait for if it was still running.
        /// It is asked rather than stopped so it saves its cookies first: a sign-in that has just
        /// finished isn't on disk yet, and on Windows stopping a process gives it no chance to save.
        @discardableResult
        private func stopBrowser() -> Process? {
            heartbeat?.invalidate()
            heartbeat = nil
            // (Messages it had already sent are waiting their turn on the main thread: they're
            // from a browser that's gone, and say nothing about the next one.)
            socket?.onMessage = nil
            socket?.onClose = nil
            socket?.close()
            socket = nil
            commandReplies.removeAll()
            var closing: Process?
            if let process, process.isRunning {
                process.terminationHandler = nil
                closing = process
            }
            process = nil
            spotifyBrowserProcessID = 0
            if let control = spotifyBrowserControl {
                control.send(#"{"id":1,"method":"Browser.close"}"#)
                control.close()
            } else {
                // Not connected yet, so there is nothing to ask.
                closing?.terminate()
            }
            spotifyBrowserControl = nil
            return closing
        }

        /// Waits up to five seconds for a browser that was asked to close, then stops it. Blocks.
        private nonisolated static func finishClosing(_ process: Process) {
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        private func browserExited(launchID id: Int) {
            guard id == launchID else { return }
            spotifyDebugLog("browser closed")
            socket?.onClose = nil
            socket?.close()
            socket = nil
            process = nil
            spotifyBrowserProcessID = 0
            heartbeat?.invalidate()
            heartbeat = nil
            if isShowingSignIn {
                isShowingSignIn = false
                let closed = signInClosed
                signInClosed = nil
                closed?()
            } else {
                failureHandler?("Spotify's browser closed")
            }
        }

        private func connect(launchID id: Int, portFile: URL, url: URL?) async {
            var port: Int?
            for _ in 0 ..< 200 {
                port = Self.readPort(portFile)
                if port != nil || id != launchID { break }
                try? await firstRowSleep(0.1)
            }
            guard id == launchID else { return }
            spotifyDebugLog(port.map { "DevTools on port \($0)" } ?? "no DevTools port")
            let opened: (socket: LocalWebSocket, agent: String?, control: LocalWebSocket?)? = if let port {
                await Task.detached { Self.openPage(port: port) }.value
            } else {
                nil
            }
            guard id == launchID else {
                opened?.socket.close()
                opened?.control?.close()
                return
            }
            guard let opened else {
                failureHandler?("Spotify's browser did not answer")
                return
            }
            let socket = opened.socket
            spotifyBrowserControl = opened.control
            spotifyDebugLog("connected")
            socket.onMessage = { [weak self] text in self?.handleDevToolsMessage(text) }
            socket.onClose = { [weak self] in
                guard let self, id == self.launchID else { return }
                self.socket = nil
            }
            self.socket = socket
            socket.start()
            command("Runtime.enable")
            command("Page.enable")
            command("Runtime.addBinding", ["name": Self.bindingName])
            command("Page.addScriptToEvaluateOnNewDocument", ["source": spotifyBridgeScript])
            if let url {
                // Spotify turns away browsers that call themselves headless.
                if isHeadless, let agent = opened.agent {
                    command("Emulation.setUserAgentOverride", ["userAgent": agent.replacingOccurrences(of: "Headless", with: "")])
                }
                // A sign-in that has just been made comes first (see `dismissSignIn`): one cookie
                // at a time, so that one the browser won't take doesn't cost the rest, and the
                // page is opened when the last has been answered (or two seconds have gone by).
                let cookies = carriedCookies
                carriedCookies = []
                if cookies.isEmpty {
                    openPlayer(url, launchID: id)
                } else {
                    for (index, cookie) in cookies.enumerated() {
                        var whenAnswered: (([String: Any]) -> Void)?
                        if index == cookies.count - 1 {
                            whenAnswered = { [weak self] _ in self?.openPlayer(url, launchID: id) }
                        }
                        command("Storage.setCookies", ["cookies": [Self.cookieToSet(cookie)]], reply: whenAnswered)
                    }
                    Task { @MainActor [weak self] in
                        try? await firstRowSleep(2)
                        self?.openPlayer(url, launchID: id)
                    }
                }
                startHeartbeat()
            } else {
                command("Runtime.evaluate", ["expression": spotifyBridgeScript])
            }
        }

        /// The page pauses the music if First Row stops checking in (see the bridge's `alive`).
        private func startHeartbeat() {
            heartbeat?.invalidate()
            let timer = Timer(after: 5, repeats: true) { _ in
                MainActor.assumeIsolatedIfPossible {
                    guard self.isBridgeReady else { return }
                    self.command("Runtime.evaluate", ["expression": "window.firstRowSpotify && window.firstRowSpotify.alive()"])
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
        }

        // MARK: - DevTools messages

        private func command(_ method: String, _ parameters: [String: Any] = [:], reply: (([String: Any]) -> Void)? = nil) {
            guard let socket else { return }
            let id = nextCommandID
            nextCommandID += 1
            if let reply {
                commandReplies[id] = reply
            }
            let message: [String: Any] = ["id": id, "method": method, "params": parameters]
            guard let data = try? JSONSerialization.data(withJSONObject: message),
                  let text = String(data: data, encoding: .utf8)
            else { return }
            socket.send(text)
        }

        private func handleDevToolsMessage(_ text: String) {
            guard let message = Self.object(text) else { return }
            if let id = message["id"] as? Int {
                commandReplies.removeValue(forKey: id)?(message)
                return
            }
            let parameters = message["params"] as? [String: Any] ?? [:]
            switch message["method"] as? String {
            case "Runtime.bindingCalled":
                guard parameters["name"] as? String == Self.bindingName,
                      let payload = parameters["payload"] as? String
                else { return }
                if payload.contains(#""type":"ready""#) {
                    isBridgeReady = true
                    let scripts = queuedScripts
                    queuedScripts.removeAll()
                    for script in scripts {
                        command("Runtime.evaluate", ["expression": script])
                    }
                }
                messageHandler?(payload)
            case "Page.frameNavigated":
                if let frame = parameters["frame"] as? [String: Any], frame["parentId"] == nil {
                    isBridgeReady = false
                }
            case "Page.javascriptDialogOpening":
                command("Page.handleJavaScriptDialog", ["accept": true])
            case "Inspector.targetCrashed":
                spotifyDebugLog("page crashed, reloading")
                isBridgeReady = false
                command("Page.reload")
            default:
                break
            }
        }

        // MARK: - Helpers

        /// Connects to the browser's first page, with the browser's user agent, and to the browser
        /// itself (for closing it). Blocks.
        private nonisolated static func openPage(port: Int) -> (socket: LocalWebSocket, agent: String?, control: LocalWebSocket?)? {
            guard let list = LocalWebSocket.get(port: port, path: "/json/list"),
                  let targets = (try? JSONSerialization.jsonObject(with: Data(list.utf8))) as? [[String: Any]],
                  let page = targets.first(where: { $0["type"] as? String == "page" }),
                  let address = page["webSocketDebuggerUrl"] as? String,
                  let pagePath = path(of: address),
                  let socket = LocalWebSocket(port: port, path: pagePath)
            else { return nil }
            let version = LocalWebSocket.get(port: port, path: "/json/version").flatMap { object($0) }
            let control = (version?["webSocketDebuggerUrl"] as? String).flatMap { path(of: $0) }.flatMap { LocalWebSocket(port: port, path: $0) }
            return (socket, version?["User-Agent"] as? String, control)
        }

        private nonisolated static func readPort(_ file: URL) -> Int? {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let line = text.split(whereSeparator: \.isNewline).first
            else { return nil }
            return Int(line)
        }

        private nonisolated static func object(_ text: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }

        /// The path of a `ws://127.0.0.1:<port>/devtools/...` address.
        private nonisolated static func path(of address: String) -> String? {
            guard let url = URL(string: address) else { return nil }
            return url.path.isEmpty ? nil : url.path
        }
    }
#endif
