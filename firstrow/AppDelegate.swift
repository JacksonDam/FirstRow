#if os(macOS)
    import Carbon.HIToolbox
    import ObjectiveC.runtime
    import SwiftUI

    private let _alwaysTrue: @convention(c) (AnyObject, Selector) -> Bool = { _, _ in true }

    class AppDelegate: NSObject, NSApplicationDelegate {
        private static let commandEscapeHotKeySignature: OSType = 0x4652_5154 // 'FRQT'
        private static let commandEscapeHotKeyIdentifier: UInt32 = 1
        private static var didInstallBorderlessKeySwizzle = false
        private var commandEscapeMonitor: Any?
        private var windowLockObservers: [Any] = []
        private var isCommandKeyDown = false
        private var isAdjustingWindowFrame = false
        private var commandEscapeHotKeyRef: EventHotKeyRef?
        private var commandEscapeHotKeyHandlerRef: EventHandlerRef?
        func applicationDidFinishLaunching(_: Notification) {
            installBorderlessKeyabilitySwizzleIfNeeded()
            Task { @MainActor [weak self] in
                self?.installWindowLockObservers()
                self?.lockAllWindowsToScreenFrame()
                self?.activateAndFocusAppWindow()
            }
            applyImmersivePresentationOptions()
            activateAndFocusAppWindow()
            NSCursor.hide()
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
                    NotificationCenter.default.post(name: .firstRowQuitRequested, object: nil)
                    return nil
                }
                return event
            }
            registerCommandEscapeHotKey()
        }

        func applicationDidBecomeActive(_: Notification) {
            applyImmersivePresentationOptions()
            activateAndFocusAppWindow()
        }

        func applicationWillResignActive(_: Notification) {
            NSApplication.shared.presentationOptions = []
        }

        func applicationWillTerminate(_: Notification) {
            if let m = commandEscapeMonitor { NSEvent.removeMonitor(m); commandEscapeMonitor = nil }
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
                    self?.lockWindowToScreenFrame(window)
                },
            )
            windowLockObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: nil,
                    queue: .main,
                ) { [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    self?.lockWindowToScreenFrame(window)
                },
            )
            windowLockObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: nil,
                    queue: .main,
                ) { [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    self?.lockWindowToScreenFrame(window)
                },
            )
            windowLockObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeScreenNotification,
                    object: nil,
                    queue: .main,
                ) { [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    self?.lockWindowToScreenFrame(window)
                },
            )
            windowLockObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main,
                ) { [weak self] _ in
                    self?.lockAllWindowsToScreenFrame()
                },
            )
        }

        private func lockAllWindowsToScreenFrame() {
            for window in NSApplication.shared.windows {
                lockWindowToScreenFrame(window)
            }
        }

        private func installBorderlessKeyabilitySwizzleIfNeeded() {
            guard !Self.didInstallBorderlessKeySwizzle else { return }
            Self.didInstallBorderlessKeySwizzle = true
            let imp = unsafeBitCast(_alwaysTrue, to: IMP.self)
            if let m = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.canBecomeKey)) {
                method_setImplementation(m, imp)
            }
            if let m = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.canBecomeMain)) {
                method_setImplementation(m, imp)
            }
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

        private func lockWindowToScreenFrame(_ window: NSWindow) {
            guard let screenFrame = (window.screen ?? NSScreen.main)?.frame else { return }

            if window.styleMask != [.borderless] {
                if #available(macOS 13.0, *) {
                    window.styleMask = [.borderless]
                }
                // macOS 12 and earlier does not appear to like setStyleMask: (crashes...)
            }
            window.collectionBehavior = [.fullScreenNone]
            window.level = .normal
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.tabbingMode = .disallowed
            window.isMovable = false
            window.isMovableByWindowBackground = false
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.minSize = screenFrame.size
            window.maxSize = screenFrame.size
            window.contentMinSize = screenFrame.size
            window.contentMaxSize = screenFrame.size

            guard !isAdjustingWindowFrame else { return }
            if window.frame.equalTo(screenFrame) { return }
            isAdjustingWindowFrame = true
            window.setFrame(screenFrame, display: true, animate: false)
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
                    NotificationCenter.default.post(name: .firstRowQuitRequested, object: nil)
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
