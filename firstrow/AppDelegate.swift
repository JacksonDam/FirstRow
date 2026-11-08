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
            lockWindowToScreen()
            installScreenObservers()
            applyImmersivePresentationOptions()
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
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
            appMenu.addItem(withTitle: "About First Row", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            appMenu.addItem(.separator())
            let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
            settings.target = self
            appMenu.addItem(settings)
            appMenu.addItem(.separator())
            appMenu.addItem(withTitle: "Hide First Row", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let quitWithFade = NSMenuItem(title: "Quit First Row", action: #selector(requestQuit(_:)), keyEquivalent: "\u{1b}")
            quitWithFade.keyEquivalentModifierMask = [.command]
            quitWithFade.target = self
            appMenu.addItem(quitWithFade)
            appMenu.addItem(withTitle: "Quit Now", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appItem.submenu = appMenu
            return mainMenu
        }

        @objc private func showSettings(_: Any?) {
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
            guard let window, let screenFrame = (window.screen ?? NSScreen.main)?.frame else { return }
            if window.level != .normal { window.level = .normal }
            window.isMovable = false
            window.minSize = screenFrame.size
            window.maxSize = screenFrame.size
            if !window.frame.equalTo(screenFrame) {
                window.setFrame(screenFrame, display: true, animate: false)
            }
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
