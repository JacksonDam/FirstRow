import AVFoundation
import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

extension Notification.Name {
    static let firstRowQuitRequested = Notification.Name("firstRowQuitRequested")
    /// Posted when the remote changes the volume. `userInfo["volume"]` is 0...1, 0 when muted.
    static let firstRowVolumeChanged = Notification.Name("firstRowVolumeChanged")
}

/// Runs First Row in its window: the intro movie, the menus, key handling and the quit fade.
@MainActor
final class FirstRowAppController {
    let hostView = SceneHostView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
    private(set) var menu: MenuView?
    private var renderer: MenuSceneRenderer?
    private let menuContainer = SceneLayer()
    private let introLayer = AVPlayerLayer()
    private let quitOverlay = SceneLayer()
    private var introPlayer: AVPlayer?
    private var introEndObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?
    private var textEntryObservers: [NSObjectProtocol] = []
    private var isQuitting = false
    private var launchToggleTask: Task<Void, Never>?
    private var launchBackHoldTask: Task<Void, Never>?
    private var isLaunchToggleWindowActive = false
    private var isLaunchBackPressActive = false
    private var didToggleIntroMovie = false
    private var containerSize: CGSize = .zero
    private var backingScale: CGFloat = 2
    private var gameControllers: GameControllerInput?
    #if os(iOS)
        private var touchInput: TouchNavigationInputView?
        private var launchHoldInput: LaunchBackTouchHoldView?
        private var folderPickerObservation: Any?
        private var isPresentingFolderPicker = false
    #endif
    #if os(tvOS)
        private var remoteInput: RemotePressCapturingView?
        private var launchRemoteInput: LaunchBackRemoteCapturingView?
    #endif

    private static let appQuitFadeDuration: Double = 1.0
    private static let appQuitHoldDuration: Double = 0.5
    private static let launchToggleWindowDuration: Double = 3.0
    private static let launchBackHoldDuration: Double = 0.35
    private static let launchMenuRevealDuration: Double = 1.0

    private var introMovieEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "introMovieEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "introMovieEnabled") }
    }

    init() {
        let root = hostView.sceneLayer
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.addSublayer(menuContainer)
        introLayer.videoGravity = .resizeAspect
        introLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        introLayer.isHidden = true
        root.addSublayer(introLayer)
        quitOverlay.backgroundColor = CGColor(gray: 0, alpha: 1)
        quitOverlay.opacity = 0
        root.addSublayer(quitOverlay)
        hostView.onLayout = { [weak self] size, scale in
            self?.layout(size: size, scale: scale)
        }
        #if os(macOS)
            hostView.onKeyDown = { [weak self] event in self?.handleKeyDown(event) }
            hostView.onKeyUp = { [weak self] event in self?.handleKeyUp(event) }
        #endif
        quitObserver = NotificationCenter.default.addObserver(forName: .firstRowQuitRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible { self?.beginQuitTransition() }
        }
        if FirstRowHarness.isActive {
            textEntryObservers.append(NotificationCenter.default.addObserver(forName: .firstRowHarnessTypeText, object: nil, queue: .main) { [weak self] note in
                guard let text = note.userInfo?["text"] as? String else { return }
                MainActor.assumeIsolatedIfPossible { self?.menu?.handleTypedText(text) }
            })
        }
        #if os(tvOS)
            // After the system's text field closes, the remote's presses come back here.
            textEntryObservers.append(NotificationCenter.default.addObserver(forName: .firstRowTextEntryDidEnd, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible { self?.remoteInput?.makePrimaryResponderIfPossible() }
            })
        #endif
    }

    func start() {
        beginLaunchToggleWindow()
        if introMovieEnabled, let url = bundledResourceURL("Intro", "mov") {
            playIntro(url)
        } else {
            showMenu(fadingIn: true)
        }
    }

    private func layout(size: CGSize, scale: CGFloat) {
        containerSize = size
        backingScale = scale
        withoutLayerActions {
            let bounds = CGRect(origin: .zero, size: size)
            menuContainer.frame = bounds
            introLayer.frame = bounds
            quitOverlay.frame = bounds
        }
        renderer?.layout(containerSize: size, backingScale: scale)
        #if os(iOS)
            touchInput?.frame = hostView.bounds
            launchHoldInput?.frame = hostView.bounds
        #endif
    }

    // MARK: - Intro and menus

    private func playIntro(_ url: URL) {
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let player = AVPlayer(url: url)
        player.isMuted = FirstRowHarness.isActive
        introPlayer = player
        introLayer.player = player
        introLayer.isHidden = false
        introEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible { self?.showMenu(fadingIn: false) }
        }
        player.play()
    }

    private func showMenu(fadingIn: Bool) {
        guard menu == nil else { return }
        if let introEndObserver {
            NotificationCenter.default.removeObserver(introEndObserver)
            self.introEndObserver = nil
        }
        introPlayer?.pause()
        introPlayer = nil
        introLayer.player = nil
        introLayer.isHidden = true

        let menu = MenuView()
        let renderer = MenuSceneRenderer(menu: menu)
        self.menu = menu
        self.renderer = renderer
        menuContainer.addSublayer(renderer.rootLayer)
        if containerSize != .zero {
            renderer.layout(containerSize: containerSize, backingScale: backingScale)
        }
        installMenuInput(menu)
        menu.start()
        if fadingIn {
            menuContainer.opacity = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                guard let self else { return }
                self.menuContainer.setOpacity(1, .easeInOut(duration: Self.launchMenuRevealDuration))
            }
        }
    }

    private func installMenuInput(_ menu: MenuView) {
        menu.pointer.hitTester = renderer
        #if os(macOS)
            hostView.onPointer = { [weak menu] event in menu?.handlePointerEvent(event) }
        #endif
        FirstRowHarness.pointerEventSink = { [weak menu] event in menu?.handlePointerEvent(event) }
        let controllers = GameControllerInput(
            onArrowKeyDown: { [weak menu] key in menu?.handleDirectionalPressBegan(key) },
            onArrowKeyUp: { [weak menu] key in menu?.handleDirectionalPressEnded(key) },
            onEnter: { [weak menu] in menu?.handleKeyDown(.enter) },
            onBackspace: { [weak menu] in menu?.handleKeyDown(.delete) },
            onSpace: { [weak menu] in menu?.handleKeyDown(.space) },
        )
        controllers.startMonitoringControllersIfNeeded()
        gameControllers = controllers
        #if !FIRSTROW_PORTABLE
            SystemMediaControls.shared.attach(menu)
        #endif
        #if os(macOS)
            AppleRemoteInput.shared.tapsChangeSong = { [weak menu] in
                guard let menu else { return false }
                return menu.activeFullscreenScene?.key == menu.musicNowPlayingFullscreenKey
            }
            AppleRemoteInput.shared.plusMinusChangeVolume = { [weak menu] in
                guard let menu, !menu.isMovieResumePromptVisible else { return false }
                if let scene = menu.activeFullscreenScene {
                    return scene.key == menu.musicNowPlayingFullscreenKey || scene.key == menu.photoSlideshowFullscreenKey
                }
                return menu.isMoviePlaybackVisible
            }
        #endif
        #if os(iOS)
            let touch = TouchNavigationInputView(frame: hostView.bounds)
            touch.onArrowKeyDown = { [weak menu] key in menu?.handleDirectionalPressBegan(key) }
            touch.onArrowKeyUp = { [weak menu] key in menu?.handleDirectionalPressEnded(key) }
            touch.onEnter = { [weak menu] in menu?.handleKeyDown(.enter) }
            touch.onBackspace = { [weak menu] in menu?.handleKeyDown(.delete) }
            touch.onSpace = { [weak menu] in menu?.handleKeyDown(.space) }
            touch.onSingleFingerTap = { [weak menu] in
                guard let menu, menu.activeFullscreenScene?.key == menu.screenSaverFullscreenKey else { return false }
                menu.dismissScreenSaverForUserInteraction()
                return true
            }
            hostView.insertSubview(touch, at: 0)
            touchInput = touch
            folderPickerObservation = menu.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolatedIfPossible { self?.presentFolderPickerIfNeeded() } }
            }
        #endif
        #if os(tvOS)
            let remote = RemotePressCapturingView(frame: hostView.bounds)
            remote.onKeyDown = { [weak menu] key in
                if [.upArrow, .downArrow, .leftArrow, .rightArrow].contains(key) {
                    menu?.handleDirectionalPressBegan(key)
                } else {
                    menu?.handleKeyDown(key)
                }
            }
            remote.onKeyUp = { [weak menu] key in menu?.handleDirectionalPressEnded(key) }
            remote.claimsFirstResponder = !isLaunchToggleWindowActive
            hostView.addSubview(remote)
            remoteInput = remote
            remote.makePrimaryResponderIfPossible()
        #endif
    }

    #if os(iOS)
        private func presentFolderPickerIfNeeded() {
            guard let menu, menu.isMoviesFolderPickerPresented, !isPresentingFolderPicker,
                  let presenter = hostView.window?.rootViewController else { return }
            isPresentingFolderPicker = true
            IOSFolderPicker.present(from: presenter, onPick: { [weak self, weak menu] url in
                self?.isPresentingFolderPicker = false
                menu?.isMoviesFolderPickerPresented = false
                menu?.handleMoviesFolderPickedFromFiles(url)
            }, onCancel: { [weak self, weak menu] in
                self?.isPresentingFolderPicker = false
                menu?.isMoviesFolderPickerPresented = false
                menu?.hasPromptedMoviesFolderPickerThisSession = false
            })
        }
    #endif

    // MARK: - Keys (Mac)

    #if os(macOS)
        func handleKeyDown(_ event: NSEvent) {
            NSCursor.setHiddenUntilMouseMoves(true)
            let key = KeyCode(rawValue: event.keyCode) ?? .none
            if isLaunchToggleWindowActive, key == .delete, !event.isARepeat {
                handleLaunchBackPressBegan()
            }
            let modifiers = event.modifierFlags
            if modifiers.intersection(.deviceIndependentFlagsMask).contains(.command),
               key == .escape || event.charactersIgnoringModifiers == "\u{1b}"
            {
                // Quitting is the app's job; the menus only see a plain Escape.
                return
            }
            // Letters, digits and spaces go to a text field when one is open.
            if let menu, menu.textEntry != nil, key == .none || key == .space,
               !modifiers.intersection(.deviceIndependentFlagsMask).contains(.command),
               let characters = event.characters, !characters.isEmpty
            {
                menu.handleTypedText(characters)
                return
            }
            menu?.handleKeyDown(key, isRepeat: event.isARepeat, modifiers: modifiers)
        }

        func handleKeyUp(_ event: NSEvent) {
            let key = KeyCode(rawValue: event.keyCode) ?? .none
            if key == .delete { handleLaunchBackPressEnded() }
            menu?.handleKeyUp(key)
        }
    #elseif FIRSTROW_PORTABLE
        func handleKeyDown(_ key: KeyCode, isRepeat: Bool) {
            if isLaunchToggleWindowActive, key == .delete, !isRepeat {
                handleLaunchBackPressBegan()
            }
            menu?.handleKeyDown(key, isRepeat: isRepeat)
        }

        func handleKeyUp(_ key: KeyCode) {
            if key == .delete { handleLaunchBackPressEnded() }
            menu?.handleKeyUp(key)
        }
    #endif

    // MARK: - Intro switch at launch

    private func beginLaunchToggleWindow() {
        isLaunchToggleWindowActive = true
        isLaunchBackPressActive = false
        didToggleIntroMovie = false
        #if os(iOS)
            let hold = LaunchBackTouchHoldView(frame: hostView.bounds)
            hold.onHoldBegan = { [weak self] in self?.handleLaunchBackPressBegan() }
            hold.onHoldEnded = { [weak self] in self?.handleLaunchBackPressEnded() }
            hostView.addSubview(hold)
            launchHoldInput = hold
        #endif
        #if os(tvOS)
            let remote = LaunchBackRemoteCapturingView(frame: hostView.bounds)
            remote.onBackPressed = { [weak self] in self?.handleLaunchBackPressBegan() }
            remote.onBackReleased = { [weak self] in self?.handleLaunchBackPressEnded() }
            hostView.addSubview(remote)
            launchRemoteInput = remote
        #endif
        launchToggleTask = Task { @MainActor [weak self] in
            try? await firstRowSleep(Self.launchToggleWindowDuration)
            guard !Task.isCancelled else { return }
            self?.endLaunchToggleWindow()
        }
    }

    private func endLaunchToggleWindow() {
        launchToggleTask?.cancel()
        launchBackHoldTask?.cancel()
        isLaunchToggleWindowActive = false
        isLaunchBackPressActive = false
        #if os(iOS)
            launchHoldInput?.removeFromSuperview()
            launchHoldInput = nil
        #endif
        #if os(tvOS)
            launchRemoteInput?.removeFromSuperview()
            launchRemoteInput = nil
            remoteInput?.claimsFirstResponder = true
            remoteInput?.makePrimaryResponderIfPossible()
        #endif
    }

    private func handleLaunchBackPressBegan() {
        guard isLaunchToggleWindowActive, !isLaunchBackPressActive else { return }
        isLaunchBackPressActive = true
        launchBackHoldTask?.cancel()
        launchBackHoldTask = Task { @MainActor [weak self] in
            try? await firstRowSleep(Self.launchBackHoldDuration)
            guard let self, !Task.isCancelled else { return }
            guard self.isLaunchToggleWindowActive, self.isLaunchBackPressActive, !self.didToggleIntroMovie else { return }
            self.introMovieEnabled.toggle()
            self.didToggleIntroMovie = true
        }
    }

    private func handleLaunchBackPressEnded() {
        isLaunchBackPressActive = false
        launchBackHoldTask?.cancel()
        launchBackHoldTask = nil
    }

    // MARK: - Quitting

    private func beginQuitTransition() {
        guard !isQuitting else { return }
        isQuitting = true
        quitOverlay.setOpacity(1, .easeInOut(duration: Self.appQuitFadeDuration))
        #if os(macOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.appQuitFadeDuration + Self.appQuitHoldDuration) {
                NSApplication.shared.terminate(nil)
            }
        #elseif FIRSTROW_PORTABLE
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.appQuitFadeDuration + Self.appQuitHoldDuration) {
                PortableApplication.quit()
            }
        #endif
    }
}

extension FirstRowAppController {
    /// A mouse or trackpad event from the window.
    func handlePointer(_ event: PointerEvent) {
        menu?.handlePointerEvent(event)
    }

    /// Settings > Media Folders (Command-comma on the Mac).
    func showMediaFolders() {
        menu?.showMediaFoldersFromShortcut()
    }
}
