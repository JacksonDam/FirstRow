#if os(macOS)
    import AppKit
    import WebKit

    func spotifyPageHostUnavailableReason() -> String {
        ""
    }

    @MainActor
    func makeSpotifyPageHost() -> SpotifyPageHost? {
        SpotifyWebViewHost()
    }

    /// Spotify's web player in a web view nobody sees. Its window sits off every screen and never
    /// takes the keyboard; the web view moves into a panel over First Row to sign in.
    @MainActor
    final class SpotifyWebViewHost: NSObject, SpotifyPageHost, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
        var messageHandler: ((String) -> Void)?
        var failureHandler: ((String) -> Void)?

        private let webView: WKWebView
        private let hiddenWindow: NSWindow
        private var signInPanel: NSPanel?
        private var signInClosed: (() -> Void)?

        private final class HiddenWindow: NSWindow {
            override var canBecomeKey: Bool { false }
            override var canBecomeMain: Bool { false }
        }

        override init() {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            configuration.mediaTypesRequiringUserActionForPlayback = []
            // Spotify only offers its player to browsers it knows.
            configuration.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"
            if #available(macOS 14.0, *) {
                configuration.preferences.inactiveSchedulingPolicy = .none
            }
            if FirstRowHarness.isActive {
                // Test runs play silently.
                configuration.userContentController.addUserScript(WKUserScript(
                    source: "(() => { const play = HTMLMediaElement.prototype.play; HTMLMediaElement.prototype.play = function (...args) { this.muted = true; return play.apply(this, args); }; })();",
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false,
                ))
            }
            configuration.userContentController.addUserScript(WKUserScript(
                source: spotifyBridgeScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
            ))
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
            hiddenWindow = HiddenWindow(
                contentRect: NSRect(x: -20000, y: -20000, width: 1024, height: 768),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
            )
            super.init()
            configuration.userContentController.add(self, name: "firstRowSpotify")
            webView.navigationDelegate = self
            webView.uiDelegate = self
            hiddenWindow.isReleasedWhenClosed = false
            hiddenWindow.ignoresMouseEvents = true
            hiddenWindow.isExcludedFromWindowsMenu = true
            hiddenWindow.collectionBehavior = [.transient, .ignoresCycle, .stationary]
            hiddenWindow.contentView = webView
            hiddenWindow.orderBack(nil)
        }

        func load(_ url: URL) {
            webView.load(URLRequest(url: url))
        }

        func evaluate(_ script: String) {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        // MARK: - Signing in

        func presentSignIn(_ url: URL, closed: @escaping () -> Void) {
            signInClosed = closed
            if signInPanel == nil {
                let screenFrame = (NSApplication.shared.windows.first { $0 is FirstRowWindow }?.screen ?? NSScreen.main)?.visibleFrame
                    ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                let size = NSSize(width: min(560, screenFrame.width - 80), height: min(760, screenFrame.height - 80))
                let panel = NSPanel(
                    contentRect: NSRect(
                        x: screenFrame.midX - size.width / 2,
                        y: screenFrame.midY - size.height / 2,
                        width: size.width,
                        height: size.height,
                    ),
                    styleMask: [.titled, .closable, .resizable],
                    backing: .buffered,
                    defer: false,
                )
                panel.title = "Sign In to Spotify"
                panel.isReleasedWhenClosed = false
                panel.hidesOnDeactivate = false
                panel.level = .modalPanel
                panel.delegate = self
                signInPanel = panel
            }
            guard let signInPanel else { return }
            webView.removeFromSuperview()
            webView.frame = signInPanel.contentLayoutRect
            webView.autoresizingMask = [.width, .height]
            signInPanel.contentView = webView
            webView.load(URLRequest(url: url))
            NSCursor.setHiddenUntilMouseMoves(false)
            NSApplication.shared.activate(ignoringOtherApps: true)
            signInPanel.makeKeyAndOrderFront(nil)
        }

        func dismissSignIn() {
            signInClosed = nil
            guard let signInPanel, signInPanel.isVisible else { return }
            signInPanel.close()
        }

        func windowWillClose(_ notification: Notification) {
            guard notification.object as? NSPanel === signInPanel else { return }
            webView.removeFromSuperview()
            hiddenWindow.contentView = webView
            if FirstRowHarness.isActive {
                // Test runs stay behind other windows.
                NSApplication.shared.deactivate()
            } else if let firstRowWindow = NSApplication.shared.windows.first(where: { $0 is FirstRowWindow }) {
                firstRowWindow.makeKeyAndOrderFront(nil)
                NSCursor.setHiddenUntilMouseMoves(true)
            }
            let closed = signInClosed
            signInClosed = nil
            closed?()
        }

        func forgetAccount(_ completion: @escaping () -> Void) {
            let store = webView.configuration.websiteDataStore
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            store.fetchDataRecords(ofTypes: types) { records in
                let spotifyRecords = records.filter { $0.displayName.lowercased().contains("spotify") || $0.displayName.lowercased().contains("scdn") }
                store.removeData(ofTypes: types, for: spotifyRecords) {
                    MainActor.assumeIsolatedIfPossible { completion() }
                }
            }
        }

        // MARK: - WebKit

        nonisolated func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolatedIfPossible {
                guard let text = message.body as? String else { return }
                self.messageHandler?(text)
            }
        }

        // Sign-in pages from Google, Apple or Facebook open in new windows: show them in this one.
        func webView(_ webView: WKWebView, createWebViewWith _: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            spotifyDebugLog("web content process ended, reloading")
            webView.reload()
        }

        private func reportLoadFailure(_ error: Error) {
            let nsError = error as NSError
            // A page replaced by another load isn't a failure.
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
            failureHandler?(nsError.localizedDescription)
        }
    }
#endif
