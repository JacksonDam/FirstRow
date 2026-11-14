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

/// The look's intro movie: First Row's name, then stars rushing in as the camera pulls back with
/// the look's own screens falling away past it, all fading to black before the menus come in.
/// (Made in the separate firstrow-intro project: a Blender scene and a sampled score.)
enum IntroMovie {
    /// Seconds into the movie when its picture has gone to black and the menus come in.
    static let revealTime = 5.5
    /// How long a skipped movie takes to fade to black.
    static let skipFadeDuration = 0.35

    /// The look's movie. The Mac app also carries a 4K one of each, which a Mac with Apple silicon
    /// plays; everything else plays the 1080p one.
    static var url: URL? {
        let name = AppSettings.theme == .modern ? "Intro-Modern" : "Intro-Classic"
        #if os(macOS) && arch(arm64)
            if let sharper = bundledResourceURL(name + "-4K", "mp4") { return sharper }
        #endif
        return bundledResourceURL(name, "mp4")
    }
}

/// Runs First Row in its window: the intro movie, the menus, key handling and the quit fade.
@MainActor
final class FirstRowAppController {
    let hostView = SceneHostView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
    #if os(macOS)
        /// What the window shows: the scene, with the system's glass buttons (where there are
        /// some) in a view over it. (The scene's own view hosts layers only, so they can't go in it.)
        let windowContentView: NSView = {
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
            container.wantsLayer = true
            return container
        }()
    #endif
    private(set) var menu: MenuView?
    private var renderer: MenuSceneRenderer?
    private let menuContainer = SceneLayer()
    /// The menus are being drawn out of sight, a moment before they come in after the intro.
    private var isBringingMenusIn = false
    private let introLayer = AVPlayerLayer()
    #if os(macOS)
        private let introMask = CALayer()
    #endif
    private let quitOverlay = SceneLayer()
    private var introPlayer: AVPlayer?
    private var introEndObserver: NSObjectProtocol?
    private var introTimeObserver: Any?
    /// The intro movie is up and the menus wait behind it, taking no input.
    private var isPlayingIntro = false
    private var introFadeTask: Task<Void, Never>?
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
    /// A foldable held upright and open lays its scene out for that; nil is the usual scene.
    private var upright: UprightStance?
    private var gameControllers: GameControllerInput?
    #if os(iOS)
        private var touchInput: TouchNavigationInputView?
        private var launchHoldInput: LaunchBackTouchHold?
        private var folderPickerObservation: Any?
        private var isPresentingFolderPicker = false
    #endif
    #if os(tvOS)
        private var remoteInput: RemotePressCapturingView?
        private var launchRemoteInput: LaunchBackRemoteCapturingView?
        private var remoteSwipes: RemoteSwipeRecognizer?
    #endif

    private static let appQuitFadeDuration: Double = 1.0
    private static let appQuitHoldDuration: Double = 0.5
    private static let launchToggleWindowDuration: Double = 3.0
    private static let launchBackHoldDuration: Double = 0.35
    private static let launchMenuRevealDuration: Double = 1.0

    init() {
        let root = hostView.sceneLayer
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        // The intro movie sits under the menus, which come in once it has faded to black.
        introLayer.videoGravity = .resizeAspectFill
        introLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        introLayer.isHidden = true
        #if os(macOS)
            // The intro has the screen to itself, and its picture is cut at the sides to fill a
            // screen less wide than it. On a MacBook Neo that picture sat to the right of the
            // middle until something else came up on the screen: a movie alone on the screen
            // can be put there by the system without being drawn with the other layers. Under
            // a mask (of all of it, so nothing is hidden) it is always drawn with them.
            introMask.backgroundColor = CGColor(gray: 0, alpha: 1)
            introLayer.mask = introMask
        #endif
        root.addSublayer(introLayer)
        root.addSublayer(menuContainer)
        quitOverlay.backgroundColor = CGColor(gray: 0, alpha: 1)
        quitOverlay.opacity = 0
        root.addSublayer(quitOverlay)
        hostView.onLayout = { [weak self] size, scale in
            self?.layout(size: size, scale: scale)
        }
        #if os(macOS)
            hostView.frame = windowContentView.bounds
            hostView.autoresizingMask = [.width, .height]
            windowContentView.addSubview(hostView)
        #endif
        // The modern look's buttons as the system's Liquid Glass, on systems that have it.
        #if os(iOS) || os(macOS) || os(tvOS)
            if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *), let native = NativeControls.makeIfSupported() {
                #if os(macOS)
                    native.view.frame = windowContentView.bounds
                    native.view.autoresizingMask = [.width, .height]
                    windowContentView.addSubview(native.view)
                #else
                    native.view.frame = hostView.bounds
                    native.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    hostView.addSubview(native.view)
                #endif
            }
        #endif
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
        // After the first-launch screens the intro plays anyway (see MenuView.finishOnboarding).
        // (The Tiger look has an opening of its own: the ring rising as the desktop draws back.)
        let playsIntro = !TigerTheme.isActive && AppSettings.playsIntroMovieAtLaunch && AppSettings.hasCompletedOnboarding && IntroMovie.url != nil && !FirstRowHarness.startsAtMenus
        showMenu(fadingIn: !playsIntro && !TigerTheme.isActive)
        if playsIntro {
            withoutLayerActions { menuContainer.opacity = 0 }
            playIntro()
        }
    }

    /// Lays out again for a new stance (and the host view's size, set by now). With a `glide`
    /// everything moves to its new place in step; without one it is there at once.
    func relayout(upright: UprightStance?, glide: GlideTiming?) {
        self.upright = upright
        menu?.upright = upright
        LayoutGlide.run(glide) { hostView.layoutNow() }
    }

    private func layout(size: CGSize, scale: CGFloat) {
        #if os(macOS)
            // A test window stands in for a foldable's inner screen: upright when taller than wide.
            if FirstRowHarness.isActive, ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_SCENE"] == "duo" {
                UprightStance.screenFolds = true
                upright = size.height > size.width
                    ? UprightStance(screenSize: size, fold: nil, safeTop: 0, safeBottom: 21, isBent: FirstRowHarness.standsBent)
                    : nil
                menu?.upright = upright
            }
        #endif
        containerSize = size
        backingScale = scale
        #if os(macOS)
            ScreenColorSpace.follow(hostView.window)
        #endif
        withoutLayerActions {
            let bounds = CGRect(origin: .zero, size: size)
            menuContainer.frame = bounds
            introLayer.frame = bounds
            #if os(macOS)
                introMask.frame = bounds
            #endif
            quitOverlay.frame = bounds
        }
        renderer?.layout(containerSize: size, backingScale: scale)
        #if os(iOS)
            touchInput?.frame = hostView.bounds
        #endif
    }

    // MARK: - Intro and menus

    /// Plays the look's intro movie over the (hidden) menus, which come in once it has faded to
    /// black. Any key, click, tap or remote press skips to them.
    private func playIntro() {
        guard let url = IntroMovie.url else {
            revealMenusAfterIntro()
            return
        }
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        endIntro()
        let player = AVPlayer(url: url)
        player.isMuted = FirstRowHarness.isActive
        introPlayer = player
        introLayer.player = player
        introLayer.isHidden = false
        isPlayingIntro = true
        menu?.registerUserInteractionForScreenSaver()
        introTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            guard time.seconds >= IntroMovie.revealTime else { return }
            MainActor.assumeIsolatedIfPossible { self?.revealMenusAfterIntro() }
        }
        introEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible {
                self?.revealMenusAfterIntro()
                self?.endIntro()
            }
        }
        player.play()
    }

    /// The menus come in from black (the movie plays on underneath for the last of its sound):
    /// Classic fades them in, Modern brings them in from a little nearer, as its scenes arrive.
    private func revealMenusAfterIntro() {
        guard isPlayingIntro || menuContainer.opacity < 1, !isBringingMenusIn else { return }
        isPlayingIntro = false
        func bringIn() {
            if AppSettings.theme == .modern, let menu {
                menuContainer.setOpacity(1, .smooth(duration: 0.5))
                menu.bringInMenusAfterIntro()
            } else {
                menuContainer.setOpacity(1, .easeInOut(duration: Self.launchMenuRevealDuration))
            }
        }
        #if FIRSTROW_PORTABLE
            // The first frame the menus are drawn in is the one that puts their pictures on
            // the graphics card, and it takes as long as that does. So it is drawn before
            // they start to come in, with them as good as clear over the movie's black, and
            // every frame of their coming in is then on time.
            isBringingMenusIn = true
            withoutLayerActions { menuContainer.opacity = Float(MenuView.asGoodAsClear) }
            Task { @MainActor [weak self] in
                try? await firstRowSleep(0.1)
                self?.isBringingMenusIn = false
                bringIn()
            }
        #else
            bringIn()
        #endif
        menu?.resetScreenSaverIdleTimer()
    }

    /// A key, click, tap or press during the intro: the movie and its sound fade away to black,
    /// then the menus come in.
    private func skipIntro() {
        guard isPlayingIntro, introFadeTask == nil, let player = introPlayer else { return }
        introLayer.setOpacity(0, .easeInOut(duration: IntroMovie.skipFadeDuration))
        introFadeTask = Task { @MainActor [weak self] in
            let start = player.volume
            for step in 1 ... 12 {
                try? await firstRowSleep(IntroMovie.skipFadeDuration / 12)
                guard !Task.isCancelled else { return }
                player.volume = start * Float(12 - step) / 12
            }
            self?.revealMenusAfterIntro()
            self?.endIntro()
        }
    }

    private func endIntro() {
        introFadeTask?.cancel()
        introFadeTask = nil
        if let introEndObserver {
            NotificationCenter.default.removeObserver(introEndObserver)
            self.introEndObserver = nil
        }
        if let introTimeObserver {
            introPlayer?.removeTimeObserver(introTimeObserver)
            self.introTimeObserver = nil
        }
        introPlayer?.pause()
        introPlayer = nil
        introLayer.player = nil
        withoutLayerActions {
            introLayer.isHidden = true
            introLayer.setOpacity(1, nil)
        }
    }

    private func showMenu(fadingIn: Bool) {
        guard menu == nil else { return }
        let menu = MenuView()
        let renderer = MenuSceneRenderer(menu: menu)
        self.menu = menu
        self.renderer = renderer
        menu.upright = upright
        menuContainer.addSublayer(renderer.rootLayer)
        if containerSize != .zero {
            renderer.layout(containerSize: containerSize, backingScale: backingScale)
        }
        installMenuInput(menu)
        // DVD heads the main menu while there is a disc to play.
        DiscWatch.shared.onChange = { [weak menu] in menu?.discDidChange() }
        DiscWatch.shared.start()
        // After Get Started the first-launch screens fade to black and the intro plays.
        menu.onOnboardingFinished = { [weak self] in
            guard let self, IntroMovie.url != nil else { return false }
            self.menuContainer.setOpacity(0, .smoothInOut(duration: 0.6))
            Task { @MainActor [weak self] in
                try? await firstRowSleep(0.75)
                self?.playIntro()
            }
            return true
        }
        FirstRowHarness.introSink = { [weak self] in
            guard let self else { return }
            withoutLayerActions { self.menuContainer.opacity = 0 }
            self.playIntro()
        }
        #if os(macOS)
            FirstRowHarness.stanceSink = { [weak self] portrait in
                guard let self, let window = self.hostView.window else { return }
                let old = window.frame
                let long = max(old.width, old.height), short = min(old.width, old.height)
                let size = portrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
                // Resizing lays the scene out for the new shape; it glides there as a turned screen's does.
                LayoutGlide.run(.easeInOut(duration: 0.4)) {
                    window.setFrame(NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height), display: true)
                    self.hostView.layoutNow()
                }
            }
            FirstRowHarness.foldSink = { [weak self] in
                guard let self else { return }
                LayoutGlide.run(.easeInOut(duration: 0.45)) { self.hostView.layoutNow() }
            }
        #endif
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
        #if os(iOS) || os(macOS) || os(tvOS)
            if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) {
                NativeControls.shared?.onPress = { [weak menu] control in menu?.pressOnScreenControl(control) }
                #if os(iOS)
                    // Kept on top of the touch views added below.
                    if let native = NativeControls.shared { hostView.bringSubviewToFront(native.view) }
                #endif
            }
        #endif
        #if os(macOS)
            hostView.onPointer = { [weak self, weak menu] event in
                if self?.takesIntroInput(event) == true { return }
                menu?.handlePointerEvent(event)
            }
        #endif
        FirstRowHarness.pointerEventSink = { [weak menu] event in menu?.handlePointerEvent(event) }
        FirstRowHarness.harnessMenu = menu
        FirstRowHarness.rubberBandSink = { [weak menu] value in
            withAnimation(.smooth(duration: 0.2)) { menu?.remoteRubberBand = value }
        }
        // Game controllers (and the Siri Remote on Apple TV) count as keys: they put the
        // pointing and touching hints away.
        let controllers = GameControllerInput(
            onArrowKeyDown: { [weak self, weak menu] key in
                if self?.takesIntroPress() == true { return }
                menu?.noteInputSource(.keyboard)
                menu?.handleDirectionalPressBegan(key)
            },
            onArrowKeyUp: { [weak self, weak menu] key in
                if self?.isPlayingIntro == true { return }
                menu?.handleDirectionalPressEnded(key)
            },
            onEnter: { [weak self, weak menu] in
                if self?.takesIntroPress() == true { return }
                menu?.noteInputSource(.keyboard)
                menu?.handleKeyDown(.enter)
            },
            onBackspace: { [weak self, weak menu] in
                if self?.takesIntroPress() == true { return }
                menu?.noteInputSource(.keyboard)
                menu?.handleKeyDown(.delete)
            },
            onSpace: { [weak self, weak menu] in
                if self?.takesIntroPress() == true { return }
                menu?.noteInputSource(.keyboard)
                menu?.handleKeyDown(.space)
            },
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
            SiriRemoteInput.shared.onTVButton = { [weak menu] in menu?.handleRemoteTVButton() }
            SiriRemoteInput.shared.onInput = { [weak menu] in menu?.noteInputSource(.siriRemote) }
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
            touch.onTouch = { [weak self, weak menu] phase, point, time in
                if self?.isPlayingIntro == true {
                    if phase == .ended { self?.skipIntro() }
                    return
                }
                menu?.handleTouch(phase, at: point, time: time)
            }
            #if DEBUG || FIRSTROW_HARNESS_BUILD
                FirstRowHarness.startTouchHarness(menu: menu, touchView: touch)
            #endif
            hostView.insertSubview(touch, at: 0)
            touchInput = touch
            folderPickerObservation = menu.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolatedIfPossible { self?.presentFolderPickerIfNeeded() } }
            }
        #endif
        #if os(tvOS)
            let remote = RemotePressCapturingView(frame: hostView.bounds)
            remote.onKeyDown = { [weak self, weak menu] key in
                if self?.takesIntroPress() == true { return }
                menu?.noteRemotePress()
                if [.upArrow, .downArrow, .leftArrow, .rightArrow].contains(key) {
                    menu?.handleDirectionalPressBegan(key)
                } else if key == .enter, menu?.remoteSelectBegan() == true || menu?.confirmPressBegan() == true {
                    // (Now Playing, and a movie that can be deleted: it acts when Select comes
                    // up, or when it has been held.)
                } else if key == .space, menu?.takesPlayPause(fromRemotePress: true) == false {
                    // (Already acted on, as the system's media command.)
                } else {
                    menu?.handleKeyDown(key)
                }
            }
            remote.onKeyUp = { [weak self, weak menu] key in
                if self?.isPlayingIntro == true { return }
                if key == .enter {
                    menu?.remoteSelectEnded()
                    menu?.confirmPressEnded()
                }
                menu?.handleDirectionalPressEnded(key)
            }
            remote.claimsFirstResponder = !isLaunchToggleWindowActive
            hostView.addSubview(remote)
            remoteInput = remote
            remote.makePrimaryResponderIfPossible()
            // Swipes on the remote's touch surface.
            let swipes = RemoteSwipeRecognizer { [weak menu] state, translation, velocity in
                menu?.handleRemotePan(state, translation: translation, velocity: velocity)
            }
            hostView.addGestureRecognizer(swipes.recognizer)
            remoteSwipes = swipes
        #endif
    }

    #if os(iOS)
        private func presentFolderPickerIfNeeded() {
            guard let menu, menu.isMovieFilesPickerPresented, !isPresentingFolderPicker,
                  let presenter = hostView.window?.rootViewController else { return }
            isPresentingFolderPicker = true
            let kinds = menu.supportedMovieFileExtensions.union(MenuView.subtitleFileExtensions)
            IOSFolderPicker.presentForMovies(ofKinds: kinds, from: presenter, onPick: { [weak self, weak menu] urls in
                self?.isPresentingFolderPicker = false
                menu?.isMovieFilesPickerPresented = false
                menu?.handleMoviesPickedFromFiles(urls)
            }, onCancel: { [weak self, weak menu] in
                self?.isPresentingFolderPicker = false
                menu?.isMovieFilesPickerPresented = false
                // Cancelled: stay where it was asked from. (Movies Folder, with nothing in it
                // yet, asks again the next time it is opened.)
                if menu?.entersMoviesFolderAfterPicking == true {
                    menu?.hasPromptedMoviesFolderPickerThisSession = false
                    menu?.entersMoviesFolderAfterPicking = false
                }
            })
        }
    #endif

    // MARK: - Keys (Mac)

    #if os(macOS)
        func handleKeyDown(_ event: NSEvent) {
            NSCursor.setHiddenUntilMouseMoves(true)
            let key = KeyCode(rawValue: event.keyCode) ?? .none
            if isPlayingIntro {
                if !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) { skipIntro() }
                return
            }
            menu?.noteInputSource(SyntheticKeyEvents.source(of: event))
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
            if let menu, menu.textEntry != nil || menu.youtubeSearchTakesTypedText, key == .none || key == .space,
               !modifiers.intersection(.deviceIndependentFlagsMask).contains(.command),
               let characters = event.characters, !characters.isEmpty
            {
                menu.handleTypedText(characters)
                return
            }
            menu?.handleKeyDown(key, isRepeat: event.isARepeat, modifiers: modifiers, willBeLetGo: true)
        }

        func handleKeyUp(_ event: NSEvent) {
            let key = KeyCode(rawValue: event.keyCode) ?? .none
            if isPlayingIntro { return }
            _ = SyntheticKeyEvents.source(of: event)
            if key == .delete { handleLaunchBackPressEnded() }
            menu?.handleKeyUp(key)
        }
    #elseif FIRSTROW_PORTABLE
        func handleKeyDown(_ key: KeyCode, isRepeat: Bool) {
            if takesIntroPress() { return }
            if isLaunchToggleWindowActive, key == .delete, !isRepeat {
                handleLaunchBackPressBegan()
            }
            menu?.noteInputSource(.keyboard)
            menu?.handleKeyDown(key, isRepeat: isRepeat, willBeLetGo: true)
        }

        func handleKeyUp(_ key: KeyCode) {
            if isPlayingIntro { return }
            if key == .delete { handleLaunchBackPressEnded() }
            menu?.handleKeyUp(key)
        }
    #endif

    /// While the intro plays a press skips it, and nothing reaches the menus behind it.
    private func takesIntroPress() -> Bool {
        guard isPlayingIntro else { return false }
        skipIntro()
        return true
    }

    /// The pointer during the intro: a click skips it; moving does nothing.
    private func takesIntroInput(_ event: PointerEvent) -> Bool {
        guard isPlayingIntro else { return false }
        if case .pressed = event { skipIntro() }
        return true
    }

    // MARK: - Intro switch at launch

    private func beginLaunchToggleWindow() {
        isLaunchToggleWindowActive = true
        isLaunchBackPressActive = false
        didToggleIntroMovie = false
        #if os(iOS)
            let hold = LaunchBackTouchHold()
            hold.onHoldBegan = { [weak self] in self?.handleLaunchBackPressBegan() }
            hold.onHoldEnded = { [weak self] in self?.handleLaunchBackPressEnded() }
            hold.attach(to: hostView)
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
            launchHoldInput?.detach()
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
            guard self.isLaunchToggleWindowActive, self.isLaunchBackPressActive, !self.didToggleIntroMovie, !self.isPlayingIntro else { return }
            AppSettings.playsIntroMovieAtLaunch.toggle()
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
        // From the Tiger look's ring First Row leaves as it came, the desktop coming back.
        if let menu, menu.tigerBeginExit(then: { Self.endApplication() }) { return }
        isQuitting = true
        #if os(iOS) || os(macOS) || os(tvOS)
            if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *) {
                NativeControls.shared?.hideAll(animation: .easeInOut(duration: 0.5))
            }
        #endif
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
    fileprivate static func endApplication() {
        #if os(macOS)
            NSApplication.shared.terminate(nil)
        #elseif FIRSTROW_PORTABLE
            PortableApplication.quit()
        #endif
    }

    /// A mouse or trackpad event from the window.
    func handlePointer(_ event: PointerEvent) {
        if takesIntroInput(event) { return }
        menu?.handlePointerEvent(event)
    }

    /// Settings > Media Folders (Command-comma on the Mac).
    func showMediaFolders() {
        menu?.showMediaFoldersFromShortcut()
    }
}
