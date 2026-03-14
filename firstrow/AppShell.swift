import AppKit
import AVKit
import Carbon.HIToolbox
import CoreGraphics
import ObjectiveC.runtime
import SwiftUI

extension Notification.Name {
    static let firstRowCommandEscapeRequested = Notification.Name("firstRowCommandEscapeRequested")
    static let firstRowQuitRequested = Notification.Name("firstRowQuitRequested")
    static let firstRowTerminateRequested = Notification.Name("firstRowTerminateRequested")
    static let firstRowImmersivePresentationRequested = Notification.Name("firstRowImmersivePresentationRequested")
    static let firstRowIntroReady = Notification.Name("firstRowIntroReady")
    static let firstRowIntroBegin = Notification.Name("firstRowIntroBegin")
}

@main
struct FullscreenVideoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
        }
        .windowStyle(HiddenTitleBarWindowStyle()).commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .windowSize) {}
            CommandGroup(replacing: .windowArrangement) {}
            CommandGroup(after: .appTermination) {
                Button("Quit First Row") {
                    NotificationCenter.default.post(name: .firstRowCommandEscapeRequested, object: nil)
                }.keyboardShortcut(.escape, modifiers: [.command])
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let commandEscapeHotKeySignature: OSType = 0x4652_5154 // 'FRQT'
    private static let commandEscapeHotKeyIdentifier: UInt32 = 1
    private static var originalCanBecomeKeyIMP: IMP?
    private static var originalCanBecomeMainIMP: IMP?
    private static var didInstallBorderlessKeySwizzle = false
    private var commandEscapeMonitor: Any?
    private var immersivePresentationObserver: Any?
    private var windowLockObservers: [Any] = []
    private var isCommandKeyDown = false
    private var isAdjustingWindowFrame = false
    private var commandEscapeHotKeyRef: EventHotKeyRef?
    private var commandEscapeHotKeyHandlerRef: EventHandlerRef?
    func applicationDidFinishLaunching(_: Notification) {
        installBorderlessKeyabilitySwizzleIfNeeded()
        installWindowLockObservers()
        lockAllWindowsToScreenFrame()
        prepareWindowsForLaunch()
        DispatchQueue.main.async { [weak self] in
            self?.lockAllWindowsToScreenFrame()
            self?.prepareWindowsForLaunch()
            self?.activateAndFocusAppWindow()
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
        if let m = commandEscapeMonitor { NSEvent.removeMonitor(m); commandEscapeMonitor = nil }
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

        let windowClass: AnyClass = NSWindow.self
        let keySelector = #selector(getter: NSWindow.canBecomeKey)
        let mainSelector = #selector(getter: NSWindow.canBecomeMain)

        guard
            let keyMethod = class_getInstanceMethod(windowClass, keySelector),
            let mainMethod = class_getInstanceMethod(windowClass, mainSelector)
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

    private var isImmersivePresentationEnabled = false

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

        if window.styleMask != [.borderless] {
            window.styleMask = [.borderless]
        }
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
        if registerStatus != noErr {
            if let ref = commandEscapeHotKeyHandlerRef { RemoveEventHandler(ref); commandEscapeHotKeyHandlerRef = nil }
        }
    }

    private func unregisterCommandEscapeHotKey() {
        if let ref = commandEscapeHotKeyRef { UnregisterEventHotKey(ref); commandEscapeHotKeyRef = nil }
        if let ref = commandEscapeHotKeyHandlerRef { RemoveEventHandler(ref); commandEscapeHotKeyHandlerRef = nil }
    }
}

struct ContentView: View {
    @AppStorage("introMovieEnabled") private var introMovieEnabled = false
    @State private var player: AVPlayer? = nil
    @State private var showMenu = false
    @State private var launchBackdropImage: NSImage? = nil
    @State private var holdLaunchBackdropOverMenu = false
    @State private var videoCompletionObserver: NSObjectProtocol?
    @State private var appQuitOverlayOpacity: Double = 0
    @State private var isAppQuitTransitioning = false
    @State private var didInitializeLaunchFlow = false
    @State private var isLaunchToggleWindowActive = false
    @State private var isLaunchBackPressActive = false
    @State private var didToggleIntroMovieInLaunchWindow = false
    @State private var launchToggleWindowWorkItem: DispatchWorkItem?
    @State private var launchBackHoldWorkItem: DispatchWorkItem?
    @State private var launchBackKeyDownMonitor: Any?
    @State private var launchBackKeyUpMonitor: Any?
    private let appQuitFadeDuration: Double = 1.0
    private let appQuitHoldDuration: Double = 0.5
    private let launchToggleWindowDuration: Double = 3.0
    private let launchBackHoldDuration: Double = 0.35
    var body: some View {
        GeometryReader { geometry in
            let renderSize = geometry.size
            let center = CGPoint(x: geometry.size.width * 0.5, y: geometry.size.height * 0.5)
            ZStack {
                Group {
                    if showMenu {
                        MenuView(initialBackdropImage: launchBackdropImage)
                    } else if let player {
                        VideoPlayerView(player: player, videoGravity: .resizeAspect).onAppear { player.play() }.ignoresSafeArea()
                    } else if let launchBackdropImage {
                        Image(nsImage: launchBackdropImage)
                            .resizable()
                            .scaledToFill()
                            .ignoresSafeArea()
                    } else {
                        Color.clear.ignoresSafeArea()
                    }
                }
                if showMenu, holdLaunchBackdropOverMenu, let launchBackdropImage {
                    Image(nsImage: launchBackdropImage)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .transition(.identity)
                        .zIndex(9000)
                }
                Color.black.opacity(appQuitOverlayOpacity).ignoresSafeArea().allowsHitTesting(false).zIndex(10000)
            }.frame(width: renderSize.width, height: renderSize.height).position(x: center.x, y: center.y).background(
                (showMenu || player != nil || launchBackdropImage != nil) ? Color.black : Color.clear,
            ).onKeyEvents(
                onKeyDown: { key, isRepeat, _ in
                    guard key == .delete, !isRepeat else { return }
                    handleLaunchBackPressBegan()
                },
                onKeyUp: { key, _ in
                    guard key == .delete else { return }
                    handleLaunchBackPressEnded()
                },
            )
            .onAppear {
                initializeLaunchFlowIfNeeded()
            }.onReceive(NotificationCenter.default.publisher(for: .firstRowCommandEscapeRequested)) { _ in
                guard !showMenu else { return }
                triggerAppQuitTransition()
            }.onReceive(NotificationCenter.default.publisher(for: .firstRowIntroReady)) { _ in
                holdLaunchBackdropOverMenu = false
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .firstRowIntroBegin, object: nil)
                }
            }.onReceive(NotificationCenter.default.publisher(for: .firstRowQuitRequested)) { _ in
                triggerAppQuitTransition()
            }.onReceive(NotificationCenter.default.publisher(for: .firstRowTerminateRequested)) { _ in
                NSApplication.shared.terminate(nil)
            }.onDisappear {
                removeVideoCompletionObserver()
                endLaunchToggleWindow()
            }
        }.ignoresSafeArea().background(Color.black)
    }

    private func initializeLaunchFlowIfNeeded() {
        guard !didInitializeLaunchFlow else { return }
        didInitializeLaunchFlow = true
        beginLaunchToggleWindow()
        guard introMovieEnabled else {
            startWithoutIntroMovie()
            return
        }
        loadVideo()
    }

    private func beginLaunchToggleWindow() {
        launchToggleWindowWorkItem?.cancel(); launchToggleWindowWorkItem = nil
        launchBackHoldWorkItem?.cancel(); launchBackHoldWorkItem = nil
        isLaunchBackPressActive = false
        didToggleIntroMovieInLaunchWindow = false
        isLaunchToggleWindowActive = true
        installLaunchBackKeyMonitorsIfNeeded()
        let workItem = DispatchWorkItem { endLaunchToggleWindow() }
        launchToggleWindowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + launchToggleWindowDuration, execute: workItem)
    }

    private func endLaunchToggleWindow() {
        launchToggleWindowWorkItem?.cancel(); launchToggleWindowWorkItem = nil
        launchBackHoldWorkItem?.cancel(); launchBackHoldWorkItem = nil
        isLaunchBackPressActive = false
        isLaunchToggleWindowActive = false
        removeLaunchBackKeyMonitors()
    }

    private func handleLaunchBackPressBegan() {
        guard isLaunchToggleWindowActive, !isLaunchBackPressActive else { return }
        isLaunchBackPressActive = true
        launchBackHoldWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            guard isLaunchToggleWindowActive, isLaunchBackPressActive, !didToggleIntroMovieInLaunchWindow else { return }
            introMovieEnabled.toggle()
            didToggleIntroMovieInLaunchWindow = true
        }
        launchBackHoldWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + launchBackHoldDuration, execute: workItem)
    }

    private func handleLaunchBackPressEnded() {
        isLaunchBackPressActive = false
        launchBackHoldWorkItem?.cancel()
        launchBackHoldWorkItem = nil
    }

    private func startWithoutIntroMovie() {
        player = nil
        removeVideoCompletionObserver()
        presentMenuFromLaunch(hidesWindowUntilReady: true)
    }

    private func loadVideo() {
        guard let url = Bundle.main.url(forResource: "Intro", withExtension: "mov") else {
            startWithoutIntroMovie()
            return
        }
        let p = AVPlayer(url: url)
        p.isMuted = false
        player = p
        setLaunchWindowHidden(false)
        observeVideoCompletion(player: p)
    }

    private func observeVideoCompletion(player: AVPlayer) {
        removeVideoCompletionObserver()
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main,
        ) { _ in
            player.pause()
            presentMenuFromLaunch(hidesWindowUntilReady: false)
        }
    }

    private func removeVideoCompletionObserver() {
        if let token = videoCompletionObserver { NotificationCenter.default.removeObserver(token); videoCompletionObserver = nil }
    }

    private func presentMenuFromLaunch(hidesWindowUntilReady: Bool) {
        let excludedWindowNumber = NSApplication.shared.windows.first?.windowNumber
        launchBackdropImage = captureBackdropImage(excludingWindowNumber: excludedWindowNumber)
        holdLaunchBackdropOverMenu = true
        if hidesWindowUntilReady {
            setLaunchWindowHidden(false)
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .firstRowImmersivePresentationRequested, object: nil)
            NSApplication.shared.presentationOptions = [.hideDock, .hideMenuBar]
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            setLaunchWindowHidden(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                showMenu = true
            }
        }
    }

    private func setLaunchWindowHidden(_ isHidden: Bool) {
        guard let window = NSApplication.shared.windows.first else { return }
        window.alphaValue = isHidden ? 0 : 1
    }

    private func installLaunchBackKeyMonitorsIfNeeded() {
        guard launchBackKeyDownMonitor == nil else { return }
        launchBackKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            if KeyCode(rawValue: event.keyCode) == .delete, !event.isARepeat { handleLaunchBackPressBegan() }
            return event
        }
        launchBackKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [self] event in
            if KeyCode(rawValue: event.keyCode) == .delete { handleLaunchBackPressEnded() }
            return event
        }
    }

    private func removeLaunchBackKeyMonitors() {
        if let m = launchBackKeyDownMonitor { NSEvent.removeMonitor(m); launchBackKeyDownMonitor = nil }
        if let m = launchBackKeyUpMonitor { NSEvent.removeMonitor(m); launchBackKeyUpMonitor = nil }
    }

    private func triggerAppQuitTransition() {
        guard !isAppQuitTransitioning else { return }
        isAppQuitTransitioning = true
        withAnimation(.easeInOut(duration: appQuitFadeDuration)) { appQuitOverlayOpacity = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + appQuitFadeDuration + appQuitHoldDuration) {
            NSApplication.shared.terminate(nil)
        }
    }
}

struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = videoGravity
        playerLayer.frame = view.bounds
        view.layer = playerLayer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        if let layer = nsView.layer as? AVPlayerLayer {
            layer.player = player
            layer.videoGravity = videoGravity
            layer.frame = nsView.bounds
        }
    }
}
