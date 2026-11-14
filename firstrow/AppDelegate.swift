#if os(macOS)
    import Carbon.HIToolbox
    import AppKit

    /// Borderless full-screen window that can still become key and main.
    final class FirstRowWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    final class AppDelegate: NSObject, NSApplicationDelegate {
        private static let commandEscapeHotKeySignature: OSType = 0x4652_5154 // 'FRQT'
        private static let commandEscapeHotKeyIdentifier: UInt32 = 1
        private var window: FirstRowWindow?
        private var appController: FirstRowAppController?
        private var keyMonitor: Any?
        private var screenObservers: [NSObjectProtocol] = []
        /// A nearly clear pixel over a top corner of the window on a ProMotion screen (see `lockWindowToScreen`).
        private var compositingStrip: NSWindow?
        private var isCommandKeyDown = false
        private var commandEscapeHotKeyRef: EventHotKeyRef?
        private var commandEscapeHotKeyHandlerRef: EventHandlerRef?

        func applicationWillFinishLaunching(_: Notification) {
            FirstRowHarness.applicationWillFinishLaunching()
            NSApplication.shared.mainMenu = makeMainMenu()
        }

        @MainActor
        func applicationDidFinishLaunching(_: Notification) {
            let controller = FirstRowAppController()
            appController = controller
            let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            let window = FirstRowWindow(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "First Row"
            window.contentView = controller.windowContentView
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.tabbingMode = .disallowed
            window.collectionBehavior = [.fullScreenNone]
            window.acceptsMouseMovedEvents = true
            self.window = window
            installKeyMonitor()
            window.makeFirstResponder(controller.hostView)

            if FirstRowHarness.isActive {
                window.orderBack(nil)
                FirstRowHarness.applicationDidFinishLaunching()
                controller.start()
                return
            }
            if TigerTheme.isActive { TigerDesktop.capture() }
            lockWindowToScreen()
            installScreenObservers()
            applyImmersivePresentationOptions()
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            lockWindowToScreen()
            // Only until the mouse moves, so the pointer comes back for permission prompts.
            NSCursor.setHiddenUntilMouseMoves(true)
            registerCommandEscapeHotKey()
            controller.start()
        }

        func applicationDidBecomeActive(_: Notification) {
            guard !FirstRowHarness.isActive else { return }
            AppleRemoteInput.shared.start()
            SiriRemoteInput.shared.start()
            // Refocus the window unless a First Row panel, like the folder picker, is in front.
            if let window, NSApplication.shared.keyWindow == nil, !NSApplication.shared.windows.contains(where: { $0 is NSPanel && $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
            }
        }

        func applicationWillResignActive(_: Notification) {
            isCommandKeyDown = false
            AppleRemoteInput.shared.stop()
            SiriRemoteInput.shared.stop()
            // The Dock and menu bar settings only apply while First Row is in front, so they're
            // left alone here: changing them mid-switch got in the way of Command-Tab.
        }

        func applicationWillTerminate(_: Notification) {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            for observer in screenObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            screenObservers.removeAll()
            unregisterCommandEscapeHotKey()
            NSApplication.shared.presentationOptions = []
        }

        func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
            true
        }

        /// Routes keys for First Row's window, or posted with no window, to the menus.
        private func installKeyMonitor() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                guard let self else { return event }
                if event.type == .flagsChanged {
                    isCommandKeyDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
                    return event
                }
                let hasCommand = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) || isCommandKeyDown
                let isEscape = event.keyCode == KeyCode.escape.rawValue || event.charactersIgnoringModifiers == "\u{1b}"
                guard event.window == nil || event.window === window else { return event }
                if hasCommand {
                    if isEscape, event.type == .keyDown {
                        NotificationCenter.default.post(name: .firstRowQuitRequested, object: nil)
                        return nil
                    }
                    return event
                }
                MainActor.runOnMainThread {
                    if event.type == .keyDown {
                        self.appController?.handleKeyDown(event)
                    } else {
                        self.appController?.handleKeyUp(event)
                    }
                }
                return nil
            }
        }

        private func makeMainMenu() -> NSMenu {
            let mainMenu = NSMenu()
            let appItem = NSMenuItem()
            mainMenu.addItem(appItem)
            let appMenu = NSMenu(title: "First Row")
            appMenu.addItem(withTitle: L("About First Row"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            appMenu.addItem(.separator())
            let settings = NSMenuItem(title: L("Settings…"), action: #selector(showSettings(_:)), keyEquivalent: ",")
            settings.target = self
            // (The Tiger look has no settings to show.)
            settings.isHidden = TigerTheme.isActive
            appMenu.addItem(settings)
            appMenu.addItem(.separator())
            appMenu.addItem(withTitle: L("Hide First Row"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let quitWithFade = NSMenuItem(title: L("Quit First Row"), action: #selector(requestQuit(_:)), keyEquivalent: "\u{1b}")
            quitWithFade.keyEquivalentModifierMask = [.command]
            quitWithFade.target = self
            appMenu.addItem(quitWithFade)
            appMenu.addItem(withTitle: L("Quit Now"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appItem.submenu = appMenu
            return mainMenu
        }

        @objc private func showSettings(_: Any?) {
            guard !TigerTheme.isActive else { return }
            MainActor.runOnMainThread {
                appController?.showMediaFolders()
            }
        }

        @objc private func requestQuit(_: Any?) {
            NotificationCenter.default.post(name: .firstRowQuitRequested, object: nil)
        }

        private func installScreenObservers() {
            screenObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.lockWindowToScreen()
            })
            screenObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { [weak self] notification in
                guard notification.object as? NSWindow === self?.window else { return }
                self?.lockWindowToScreen()
            })
        }

        /// The Dock and menu bar stay out of the way, but come in when the pointer goes to their
        /// edge of the screen, and Command-Tab still switches apps.
        private func applyImmersivePresentationOptions() {
            let options: NSApplication.PresentationOptions = [.autoHideDock, .autoHideMenuBar]
            if NSApplication.shared.presentationOptions != options {
                NSApplication.shared.presentationOptions = options
            }
        }

        /// Keeps First Row's window (only) covering its screen.
        private func lockWindowToScreen() {
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let screenFrame = screen.frame
            if window.level != .normal { window.level = .normal }
            window.isMovable = false
            window.minSize = screenFrame.size
            window.maxSize = screenFrame.size
            if !window.frame.equalTo(screenFrame) {
                window.setFrame(screenFrame, display: true, animate: false)
            }
            // A window covering the whole screen with nothing over it can go to the screen without
            // being composited. On a ProMotion screen that left First Row's frames unevenly timed
            // (stutters below 60 fps and stale frames), and it ran smoothly at 120 Hz only while the
            // menu bar was pulled down over it. Another window over any of it does the same as the
            // menu bar (a nearly clear strip along the top edge was what was tried on a ProMotion
            // MacBook Pro; it's now a single pixel), and the window isn't marked opaque either.
            let variable = Self.refreshesAtVariableRate(screen)
            if window.isOpaque == variable {
                window.isOpaque = !variable
            }
            updateCompositingStrip(over: window, on: screen, shown: variable)
        }

        private func updateCompositingStrip(over window: NSWindow, on screen: NSScreen, shown: Bool) {
            guard shown else {
                if let compositingStrip {
                    window.removeChildWindow(compositingStrip)
                    compositingStrip.orderOut(nil)
                }
                compositingStrip = nil
                return
            }
            // A single pixel in the screen's top left corner (under the rounding of a MacBook's
            // own), and as near to clear as a window's pixel goes without being clear: as a
            // strip 24 points tall at 3% black it showed as a band over a bright picture (Now
            // Playing's blurred cover).
            let pixel = 1 / max(1, screen.backingScaleFactor)
            var frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - pixel, width: pixel, height: pixel)
            let strip = compositingStrip ?? {
                let strip = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                strip.isReleasedWhenClosed = false
                strip.isOpaque = false
                strip.backgroundColor = NSColor(white: 0, alpha: 0.01)
                strip.hasShadow = false
                strip.ignoresMouseEvents = true
                strip.collectionBehavior = [.ignoresCycle, .fullScreenNone]
                return strip
            }()
            compositingStrip = strip
            if !strip.frame.equalTo(frame) {
                strip.setFrame(frame, display: false)
            }
            // (Should a window not be allowed to be so small, a point each way does as well.)
            if strip.frame.height < pixel * 0.9 || strip.frame.width < pixel * 0.9 {
                frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - 1, width: 1, height: 1)
                strip.setFrame(frame, display: false)
            }
            // As a child window it stays just above First Row's window, so other apps come in front
            // of it, and it goes with the window. It only comes on screen if the window already is.
            if window.isVisible, strip.parent !== window || !strip.isVisible {
                window.removeChildWindow(strip)
                window.addChildWindow(strip, ordered: .above)
            }
        }

        /// Whether `screen` varies its refresh rate as it goes: a ProMotion screen (unless it is set
        /// to a fixed rate) or an Adaptive-Sync display.
        private static func refreshesAtVariableRate(_ screen: NSScreen) -> Bool {
            guard #available(macOS 12.0, *) else { return false }
            if screen.maximumRefreshInterval > screen.minimumRefreshInterval + 0.0005 {
                return true
            }
            // The only built-in Mac screens faster than 60 Hz are ProMotion ones.
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number.map { CGDisplayIsBuiltin($0.uint32Value) != 0 } == true && screen.maximumFramesPerSecond > 60
        }

        private func registerCommandEscapeHotKey() {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: OSType(kEventHotKeyPressed),
            )
            let handlerStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, eventRef, userData in
                    _ = userData
                    guard let eventRef else { return noErr }
                    var hotKeyID = EventHotKeyID()
                    let parameterStatus = GetEventParameter(
                        eventRef,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID,
                    )
                    guard
                        parameterStatus == noErr,
                        hotKeyID.signature == AppDelegate.commandEscapeHotKeySignature,
                        hotKeyID.id == AppDelegate.commandEscapeHotKeyIdentifier
                    else {
                        return noErr
                    }
                    // Not while First Row's file picker is in front.
                    if !(NSApplication.shared.keyWindow is NSPanel) {
                        NotificationCenter.default.post(name: .firstRowQuitRequested, object: nil)
                    }
                    return noErr
                },
                1,
                &eventType,
                nil,
                &commandEscapeHotKeyHandlerRef,
            )
            guard handlerStatus == noErr else { return }
            let hotKeyID = EventHotKeyID(
                signature: Self.commandEscapeHotKeySignature,
                id: Self.commandEscapeHotKeyIdentifier,
            )
            let registerStatus = RegisterEventHotKey(
                UInt32(kVK_Escape),
                UInt32(cmdKey),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &commandEscapeHotKeyRef,
            )
            if registerStatus != noErr {
                if let ref = commandEscapeHotKeyHandlerRef { RemoveEventHandler(ref); commandEscapeHotKeyHandlerRef = nil }
            }
        }

        private func unregisterCommandEscapeHotKey() {
            if let ref = commandEscapeHotKeyRef { UnregisterEventHotKey(ref); commandEscapeHotKeyRef = nil }
            if let ref = commandEscapeHotKeyHandlerRef { RemoveEventHandler(ref); commandEscapeHotKeyHandlerRef = nil }
        }
    }
#endif
