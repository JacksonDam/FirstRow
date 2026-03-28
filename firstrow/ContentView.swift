import AVKit
import SwiftUI

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
    @State private var launchToggleWindowWorkItem: Task<Void, Never>?
    @State private var launchBackHoldWorkItem: Task<Void, Never>?
    @State private var launchMenuRevealWorkItem: Task<Void, Never>?
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
            ZStack {
                Group {
                    if showMenu {
                        MenuView().opacity(didSkipIntroAtLaunch ? launchMenuOpacity : 1)
                    } else if let player {
                        VideoPlayerView(player: player, videoGravity: .resizeAspect)
                            .onAppear { player.play() }
                            .ignoresSafeArea()
                    } else {
                        Color.black.ignoresSafeArea()
                    }
                }
                Color.black.opacity(appQuitOverlayOpacity).ignoresSafeArea().allowsHitTesting(false).zIndex(10000)
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .center,
            )
            .background(Color.black)
        }
        .onKeyEvents(
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
            scheduleLaunchMenuRevealIfNeeded()
        }.onChange(of: showMenu) { _ in
            scheduleLaunchMenuRevealIfNeeded()
        }.onChange(of: didSkipIntroAtLaunch) { _ in
            scheduleLaunchMenuRevealIfNeeded()
        }.onReceive(NotificationCenter.default.publisher(for: .firstRowQuitRequested)) { _ in
            triggerAppQuitTransition()
        }.onDisappear {
            launchMenuRevealWorkItem?.cancel()
            launchMenuRevealWorkItem = nil
            removeVideoCompletionObserver()
            endLaunchToggleWindow()
        }
        .ignoresSafeArea()
        .background(Color.black)
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
        launchToggleWindowWorkItem = Task {
            try? await firstRowSleep(launchToggleWindowDuration)
            guard !Task.isCancelled else { return }
            endLaunchToggleWindow()
        }
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
        launchBackHoldWorkItem = Task {
            try? await firstRowSleep(launchBackHoldDuration)
            guard !Task.isCancelled else { return }
            guard isLaunchToggleWindowActive, isLaunchBackPressActive, !didToggleIntroMovieInLaunchWindow else { return }
            introMovieEnabled.toggle()
            didToggleIntroMovieInLaunchWindow = true
        }
    }

    private func handleLaunchBackPressEnded() {
        isLaunchBackPressActive = false
        launchBackHoldWorkItem?.cancel()
        launchBackHoldWorkItem = nil
    }

    private func startWithoutIntroMovie() {
        didSkipIntroAtLaunch = true
        launchMenuRevealWorkItem?.cancel()
        launchMenuRevealWorkItem = nil
        launchMenuOpacity = 0
        player = nil
        removeVideoCompletionObserver()
        showMenu = true
    }

    private func scheduleLaunchMenuRevealIfNeeded() {
        guard showMenu, didSkipIntroAtLaunch, launchMenuOpacity < 0.999 else { return }
        launchMenuRevealWorkItem = Task { @MainActor in
            try? await firstRowSleep(0.01)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: launchMenuRevealDuration)) {
                launchMenuOpacity = 1
            }
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
            let quitDelay = appQuitFadeDuration + appQuitHoldDuration
            Task {
                try? await firstRowSleep(quitDelay)
                NSApplication.shared.terminate(nil)
            }
        #endif
    }
}
