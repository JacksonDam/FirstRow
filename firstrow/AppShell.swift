import AVKit
import SwiftUI
#if os(macOS)
    import Carbon.HIToolbox
    import ObjectiveC.runtime
#else
    import UIKit
#endif
extension Notification.Name {
    static let firstRowQuitRequested = Notification.Name("firstRowQuitRequested")
}

@main
struct FullscreenVideoApp: App {
    #if os(macOS)
        @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #elseif os(iOS)
        @UIApplicationDelegateAdaptor(IOSAppDelegate.self) var appDelegate
    #endif
    var body: some Scene {
        WindowGroup {
            ContentView()
            #if os(iOS)
                .statusBar(hidden: true)
            #endif
                .ignoresSafeArea()
        }
        #if os(macOS)
        .windowStyle(HiddenTitleBarWindowStyle()).commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .windowSize) {}
            CommandGroup(replacing: .windowArrangement) {}
            CommandGroup(after: .appTermination) {
                Button("Quit First Row") {
                    NotificationCenter.default.post(name: .firstRowQuitRequested, object: nil)
                }.keyboardShortcut(.escape, modifiers: [.command])
            }
        }
        #endif
    }
}

#if os(macOS)
    class AppDelegate: NSObject, NSApplicationDelegate {
        private static let commandEscapeHotKeySignature: OSType = 0x4652_5154 // 'FRQT'
        private static let commandEscapeHotKeyIdentifier: UInt32 = 1
        private static var originalCanBecomeKeyIMP: IMP?
        private static var originalCanBecomeMainIMP: IMP?
        private static var didInstallBorderlessKeySwizzle = false
        private var commandEscapeMonitor: Any?
        private var windowLockObservers: [Any] = []
        private var isCommandKeyDown = false
        private var isAdjustingWindowFrame = false
        private var commandEscapeHotKeyRef: EventHotKeyRef?
        private var commandEscapeHotKeyHandlerRef: EventHandlerRef?
        func applicationDidFinishLaunching(_: Notification) {
            installBorderlessKeyabilitySwizzleIfNeeded()
            installWindowLockObservers()
            lockAllWindowsToScreenFrame()
            DispatchQueue.main.async { [weak self] in
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
                window.styleMask = [.borderless]
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
#if os(iOS)
    final class IOSAppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _: UIApplication,
            supportedInterfaceOrientationsFor _: UIWindow?,
        ) -> UIInterfaceOrientationMask {
            .landscape
        }
    }
#endif
struct ContentView: View {
    @AppStorage("introMovieEnabled") private var introMovieEnabled = false
    @State private var player: AVPlayer? = nil
    @State private var showMenu = false
    @State private var videoCompletionObserver: NSObjectProtocol?
    @State private var appQuitOverlayOpacity: Double = 0
    @State private var isAppQuitTransitioning = false
    @State private var didInitializeLaunchFlow = false
    @State private var didSkipIntroAtLaunch = false
    @State private var launchMenuOpacity: Double = 1
    @State private var isLaunchToggleWindowActive = false
    @State private var isLaunchBackPressActive = false
    @State private var didToggleIntroMovieInLaunchWindow = false
    @State private var launchToggleWindowWorkItem: DispatchWorkItem?
    @State private var launchBackHoldWorkItem: DispatchWorkItem?
    #if os(macOS)
        @State private var launchBackKeyDownMonitor: Any?
        @State private var launchBackKeyUpMonitor: Any?
    #endif
    private let appQuitFadeDuration: Double = 1.0
    private let appQuitHoldDuration: Double = 0.5
    private let launchToggleWindowDuration: Double = 3.0
    private let launchBackHoldDuration: Double = 0.35
    private let launchMenuRevealDuration: Double = 1.0
    var body: some View {
        GeometryReader { geometry in
            let renderSize = geometry.size
            let center = CGPoint(x: geometry.size.width * 0.5, y: geometry.size.height * 0.5)
            ZStack {
                Group {
                    if showMenu {
                        MenuView().opacity(didSkipIntroAtLaunch ? launchMenuOpacity : 1)
                    } else if let player {
                        VideoPlayerView(player: player, videoGravity: .resizeAspect).onAppear { player.play() }.ignoresSafeArea()
                    } else {
                        Color.black.ignoresSafeArea()
                    }
                }
                Color.black.opacity(appQuitOverlayOpacity).ignoresSafeArea().allowsHitTesting(false).zIndex(10000)
            }.frame(width: renderSize.width, height: renderSize.height).position(x: center.x, y: center.y).background(Color.black).onKeyEvents(
                onKeyDown: { key, isRepeat, _ in
                    guard key == .delete, !isRepeat else { return }
                    handleLaunchBackPressBegan()
                },
                onKeyUp: { key, _ in
                    guard key == .delete else { return }
                    handleLaunchBackPressEnded()
                },
            )
            #if os(iOS)
            .overlay {
                if isLaunchToggleWindowActive {
                    LaunchBackTouchHoldOverlay(
                        onHoldBegan: { handleLaunchBackPressBegan() },
                        onHoldEnded: { handleLaunchBackPressEnded() },
                    ).ignoresSafeArea()
                }
            }
            #endif
            #if os(tvOS)
            .overlay {
                if isLaunchToggleWindowActive {
                    LaunchBackRemoteOverlay(
                        onBackPressed: { handleLaunchBackPressBegan() },
                        onBackReleased: { handleLaunchBackPressEnded() },
                    ).ignoresSafeArea()
                }
            }
            #endif
            .onAppear {
                initializeLaunchFlowIfNeeded()
            }.onReceive(NotificationCenter.default.publisher(for: .firstRowQuitRequested)) { _ in
                triggerAppQuitTransition()
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
        #if os(macOS)
            installLaunchBackKeyMonitorsIfNeeded()
        #endif
        let workItem = DispatchWorkItem { endLaunchToggleWindow() }
        launchToggleWindowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + launchToggleWindowDuration, execute: workItem)
    }

    private func endLaunchToggleWindow() {
        launchToggleWindowWorkItem?.cancel(); launchToggleWindowWorkItem = nil
        launchBackHoldWorkItem?.cancel(); launchBackHoldWorkItem = nil
        isLaunchBackPressActive = false
        isLaunchToggleWindowActive = false
        #if os(macOS)
            removeLaunchBackKeyMonitors()
        #endif
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
        didSkipIntroAtLaunch = true
        launchMenuOpacity = 0
        player = nil
        removeVideoCompletionObserver()
        showMenu = true
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: launchMenuRevealDuration)) { launchMenuOpacity = 1 }
        }
    }

    private func loadVideo() {
        guard let url = Bundle.main.url(forResource: "Intro", withExtension: "mov") else {
            startWithoutIntroMovie()
            return
        }
        #if os(iOS)
            configureIntroAudioSession()
            requestLandscapeIfPossible()
        #endif
        let p = AVPlayer(url: url)
        p.isMuted = false
        player = p
        observeVideoCompletion(player: p)
    }

    #if os(iOS)
        private func configureIntroAudioSession() {
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setCategory(.playback, mode: .moviePlayback, options: [])
                try audioSession.setActive(true)
            } catch {
                #if DEBUG
                    print("Failed to configure intro audio session: \(error)")
                #endif
            }
        }

        private func requestLandscapeIfPossible() {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            if #available(iOS 16.0, *) {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
            }
        }
    #endif
    private func observeVideoCompletion(player: AVPlayer) {
        removeVideoCompletionObserver()
        videoCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main,
        ) { _ in showMenu = true }
    }

    private func removeVideoCompletionObserver() {
        if let token = videoCompletionObserver { NotificationCenter.default.removeObserver(token); videoCompletionObserver = nil }
    }

    #if os(macOS)
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
    #endif
    private func triggerAppQuitTransition() {
        guard !isAppQuitTransitioning else { return }
        isAppQuitTransitioning = true
        withAnimation(.easeInOut(duration: appQuitFadeDuration)) { appQuitOverlayOpacity = 1 }
        #if os(macOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + appQuitFadeDuration + appQuitHoldDuration) {
                NSApplication.shared.terminate(nil)
            }
        #endif
    }
}

#if os(iOS)
    struct LaunchBackTouchHoldOverlay: UIViewRepresentable {
        let onHoldBegan: () -> Void
        let onHoldEnded: () -> Void
        func makeCoordinator() -> Coordinator {
            Coordinator(onHoldBegan: onHoldBegan, onHoldEnded: onHoldEnded)
        }

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isMultipleTouchEnabled = true
            view.backgroundColor = .clear
            let threeFingerHold = UILongPressGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleThreeFingerHold(_:)),
            )
            threeFingerHold.minimumPressDuration = 0.01
            threeFingerHold.numberOfTouchesRequired = 3
            threeFingerHold.cancelsTouchesInView = false
            view.addGestureRecognizer(threeFingerHold)
            return view
        }

        func updateUIView(_: UIView, context: Context) {
            context.coordinator.onHoldBegan = onHoldBegan
            context.coordinator.onHoldEnded = onHoldEnded
        }

        final class Coordinator: NSObject {
            var onHoldBegan: () -> Void
            var onHoldEnded: () -> Void
            init(onHoldBegan: @escaping () -> Void, onHoldEnded: @escaping () -> Void) {
                self.onHoldBegan = onHoldBegan
                self.onHoldEnded = onHoldEnded
            }

            @objc
            func handleThreeFingerHold(_ gesture: UILongPressGestureRecognizer) {
                switch gesture.state {
                case .began: onHoldBegan()
                case .ended, .failed, .cancelled: onHoldEnded()
                default: break
                }
            }
        }
    }
#endif
#if os(tvOS)
    struct LaunchBackRemoteOverlay: UIViewRepresentable {
        let onBackPressed: () -> Void
        let onBackReleased: () -> Void
        func makeUIView(context _: Context) -> LaunchBackRemoteCapturingView {
            let view = LaunchBackRemoteCapturingView()
            view.backgroundColor = .clear
            view.onBackPressed = onBackPressed
            view.onBackReleased = onBackReleased
            return view
        }

        func updateUIView(_ uiView: LaunchBackRemoteCapturingView, context _: Context) {
            uiView.onBackPressed = onBackPressed
            uiView.onBackReleased = onBackReleased
            uiView.makePrimaryResponderIfPossible()
        }
    }

    final class LaunchBackRemoteCapturingView: UIView {
        var onBackPressed: (() -> Void)?
        var onBackReleased: (() -> Void)?
        override var canBecomeFirstResponder: Bool {
            true
        }

        override func didMoveToWindow() {
            super.didMoveToWindow(); makePrimaryResponderIfPossible()
        }

        override func layoutSubviews() {
            super.layoutSubviews(); makePrimaryResponderIfPossible()
        }

        func makePrimaryResponderIfPossible() {
            guard window != nil, !isFirstResponder else { return }
            _ = becomeFirstResponder()
        }

        private func handleMenuPresses(_ presses: Set<UIPress>, handler: (() -> Void)?, fallback: () -> Void) {
            if presses.contains(where: { $0.type == .menu }) { handler?() } else { fallback() }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            handleMenuPresses(presses, handler: onBackPressed) { super.pressesBegan(presses, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            handleMenuPresses(presses, handler: onBackReleased) { super.pressesEnded(presses, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            handleMenuPresses(presses, handler: onBackReleased) { super.pressesCancelled(presses, with: event) }
        }
    }
#endif
#if os(macOS)
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
#else
    final class PlayerLayerContainerView: UIView {
        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }

    struct VideoPlayerView: UIViewRepresentable {
        let player: AVPlayer
        var videoGravity: AVLayerVideoGravity = .resizeAspect
        func makeUIView(context _: Context) -> PlayerLayerContainerView {
            let view = PlayerLayerContainerView()
            view.backgroundColor = .black
            view.playerLayer.player = player
            view.playerLayer.videoGravity = videoGravity
            return view
        }

        func updateUIView(_ uiView: PlayerLayerContainerView, context _: Context) {
            uiView.playerLayer.player = player
            uiView.playerLayer.videoGravity = videoGravity
        }
    }
#endif
