#if os(macOS)
    import AppKit
    import Carbon.HIToolbox
    import ObjectiveC.runtime

    class AppDelegate: NSObject, NSApplicationDelegate {
        private static let commandEscapeHotKeySignature: OSType = 0x4652_5154 // 'FRQT'
        private static let commandEscapeHotKeyIdentifier: UInt32 = 1
        private static var originalCanBecomeKeyIMP: IMP?
        private static var originalCanBecomeMainIMP: IMP?
        private static var didInstallBorderlessKeySwizzle = false

        private var commandEscapeMonitor: Any?
        private var immersivePresentationObserver: Any?
        private var windowLockObservers: [Any] = []
        private var pendingWindowLockIDs: Set<ObjectIdentifier> = []
        private var isCommandKeyDown = false
        private var isAdjustingWindowFrame = false
        private var commandEscapeHotKeyRef: EventHotKeyRef?
        private var commandEscapeHotKeyHandlerRef: EventHandlerRef?
        private var isImmersivePresentationEnabled = false

        func applicationDidFinishLaunching(_: Notification) {
            installBorderlessKeyabilitySwizzleIfNeeded()
            prepareWindowsForLaunch()
            for window in NSApplication.shared.windows { window.alphaValue = 0 }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.installWindowLockObservers()
                self.scheduleLockForAllWindows()
                self.prepareWindowsForLaunch()
                await Task.yield()
                for window in NSApplication.shared.windows { window.alphaValue = 1 }
                self.activateAndFocusAppWindow()
            }
            activateAndFocusAppWindow()
            NSCursor.hide()
            immersivePresentationObserver = NotificationCenter.default.addObserver(
                forName: .firstRowImmersivePresentationRequested,
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                self?.enableImmersivePresentation()
            }
            commandEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .flagsChanged {
                    isCommandKeyDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
                    return event
                }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let isCommandEscape =
                    (modifiers.contains(.command) || isCommandKeyDown) &&
                    (event.keyCode == KeyCode.escape.rawValue || event.charactersIgnoringModifiers == "\u{1b}")
                if isCommandEscape {
                    NotificationCenter.default.post(name: .firstRowCommandEscapeRequested, object: nil)
                    return nil
                }
                return event
            }
            registerCommandEscapeHotKey()
        }

        func applicationDidBecomeActive(_: Notification) {
            applyImmersivePresentationOptionsIfNeeded()
            activateAndFocusAppWindow()
        }

        func applicationWillResignActive(_: Notification) {
            NSApplication.shared.presentationOptions = []
        }

        func applicationWillTerminate(_: Notification) {
            if let monitor = commandEscapeMonitor {
                NSEvent.removeMonitor(monitor)
                commandEscapeMonitor = nil
            }
            if let observer = immersivePresentationObserver {
                NotificationCenter.default.removeObserver(observer)
                immersivePresentationObserver = nil
            }
            for observer in windowLockObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            windowLockObservers.removeAll()
            unregisterCommandEscapeHotKey()
            NSApplication.shared.presentationOptions = []
            NSCursor.unhide()
        }

        private func installWindowLockObservers() {
            windowLockObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeMainNotification,
                    object: nil,
                    queue: .main,
                ) { [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    self?.scheduleWindowLock(for: window)
                },
            )
            windowLockObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeScreenNotification,
                    object: nil,
                    queue: .main,
                ) { [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    self?.scheduleWindowLock(for: window)
                },
            )
            windowLockObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main,
                ) { [weak self] _ in
                    self?.scheduleLockForAllWindows()
                },
            )
        }

        private func lockAllWindowsToScreenFrame() {
            for window in NSApplication.shared.windows {
                lockWindowToScreenFrame(window)
            }
        }

        private func scheduleLockForAllWindows() {
            for window in NSApplication.shared.windows {
                scheduleWindowLock(for: window)
            }
        }

        private func scheduleWindowLock(for window: NSWindow) {
            let windowID = ObjectIdentifier(window)
            guard pendingWindowLockIDs.insert(windowID).inserted else { return }
            Task { @MainActor [weak self, weak window] in
                guard let self else { return }
                defer { self.pendingWindowLockIDs.remove(windowID) }
                await Task.yield()
                guard let window else { return }
                self.lockWindowToScreenFrame(window)
            }
        }

        private func installBorderlessKeyabilitySwizzleIfNeeded() {
            guard !Self.didInstallBorderlessKeySwizzle else { return }
            Self.didInstallBorderlessKeySwizzle = true

            let keySelector = #selector(getter: NSWindow.canBecomeKey)
            let mainSelector = #selector(getter: NSWindow.canBecomeMain)

            guard
                let keyMethod = class_getInstanceMethod(NSWindow.self, keySelector),
                let mainMethod = class_getInstanceMethod(NSWindow.self, mainSelector)
            else {
                return
            }

            Self.originalCanBecomeKeyIMP = method_getImplementation(keyMethod)
            Self.originalCanBecomeMainIMP = method_getImplementation(mainMethod)

            let keyBlock: @convention(block) (NSWindow) -> Bool = { window in
                if window.styleMask.contains(.borderless) {
                    return true
                }
                if let original = Self.originalCanBecomeKeyIMP {
                    typealias OriginalFn = @convention(c) (AnyObject, Selector) -> Bool
                    let fn = unsafeBitCast(original, to: OriginalFn.self)
                    return fn(window, keySelector)
                }
                return true
            }

            let mainBlock: @convention(block) (NSWindow) -> Bool = { window in
                if window.styleMask.contains(.borderless) {
                    return true
                }
                if let original = Self.originalCanBecomeMainIMP {
                    typealias OriginalFn = @convention(c) (AnyObject, Selector) -> Bool
                    let fn = unsafeBitCast(original, to: OriginalFn.self)
                    return fn(window, mainSelector)
                }
                return true
            }

            method_setImplementation(keyMethod, imp_implementationWithBlock(keyBlock))
            method_setImplementation(mainMethod, imp_implementationWithBlock(mainBlock))
        }

        private func applyImmersivePresentationOptionsIfNeeded() {
            guard isImmersivePresentationEnabled else { return }
            applyImmersivePresentationOptions()
        }

        private func enableImmersivePresentation() {
            isImmersivePresentationEnabled = true
            applyImmersivePresentationOptions()
            activateAndFocusAppWindow()
        }

        private func applyImmersivePresentationOptions() {
            NSApplication.shared.presentationOptions = [.hideDock, .hideMenuBar]
        }

        private func activateAndFocusAppWindow() {
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let keyWindow = NSApplication.shared.windows.first {
                keyWindow.makeKeyAndOrderFront(nil)
            }
        }

        private func prepareWindowsForLaunch() {
            for window in NSApplication.shared.windows {
                window.animationBehavior = .none
            }
        }

        private func lockWindowToScreenFrame(_ window: NSWindow) {
            guard let screenFrame = (window.screen ?? NSScreen.main)?.frame else { return }

            if #available(macOS 13.0, *) {
                if window.styleMask != [.borderless] {
                    window.styleMask = [.borderless]
                }
            }
            // macOS 12 and earlier does not appear to like setStyleMask: (crashes...)
            window.collectionBehavior = [.fullScreenNone]
            window.level = .normal
            window.isOpaque = false
            window.backgroundColor = .clear
            window.animationBehavior = .none
            window.hasShadow = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.tabbingMode = .disallowed
            window.isMovable = false
            window.isMovableByWindowBackground = false
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            if window.minSize != screenFrame.size {
                window.minSize = screenFrame.size
            }
            if window.maxSize != screenFrame.size {
                window.maxSize = screenFrame.size
            }
            if window.contentMinSize != screenFrame.size {
                window.contentMinSize = screenFrame.size
            }
            if window.contentMaxSize != screenFrame.size {
                window.contentMaxSize = screenFrame.size
            }

            guard !isAdjustingWindowFrame else { return }
            if window.frame.equalTo(screenFrame) { return }
            isAdjustingWindowFrame = true
            window.setFrame(screenFrame, display: false, animate: false)
            isAdjustingWindowFrame = false
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
                    NotificationCenter.default.post(name: .firstRowCommandEscapeRequested, object: nil)
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
            if registerStatus != noErr, let ref = commandEscapeHotKeyHandlerRef {
                RemoveEventHandler(ref)
                commandEscapeHotKeyHandlerRef = nil
            }
        }

        private func unregisterCommandEscapeHotKey() {
            if let ref = commandEscapeHotKeyRef {
                UnregisterEventHotKey(ref)
                commandEscapeHotKeyRef = nil
            }
            if let ref = commandEscapeHotKeyHandlerRef {
                RemoveEventHandler(ref)
                commandEscapeHotKeyHandlerRef = nil
            }
        }
    }
#endif
