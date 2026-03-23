import AppKit
import AVKit
import SwiftUI

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
    @State private var pendingLaunchWindowRevealOnIntroReady = false
    @State private var pendingLaunchImmersivePresentationOnReveal = false

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
                        VideoPlayerView(player: player, videoGravity: .resizeAspect)
                            .onAppear { player.play() }
                            .ignoresSafeArea()
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
                Color.black.opacity(appQuitOverlayOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .zIndex(10000)
            }
            .frame(width: renderSize.width, height: renderSize.height)
            .position(x: center.x, y: center.y)
            .background((showMenu || player != nil || launchBackdropImage != nil) ? Color.black : Color.clear)
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
            .onAppear {
                initializeLaunchFlowIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .firstRowCommandEscapeRequested)) { _ in
                guard !showMenu else { return }
                triggerAppQuitTransition()
            }
            .onReceive(NotificationCenter.default.publisher(for: .firstRowIntroReady)) { _ in
                holdLaunchBackdropOverMenu = false
                if pendingLaunchWindowRevealOnIntroReady {
                    pendingLaunchWindowRevealOnIntroReady = false
                    revealLaunchWindowForMenuIfNeeded()
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .firstRowIntroBegin, object: nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .firstRowQuitRequested)) { _ in
                triggerAppQuitTransition()
            }
            .onReceive(NotificationCenter.default.publisher(for: .firstRowTerminateRequested)) { _ in
                NSApplication.shared.terminate(nil)
            }
            .onDisappear {
                removeVideoCompletionObserver()
                endLaunchToggleWindow()
            }
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
        launchToggleWindowWorkItem?.cancel()
        launchToggleWindowWorkItem = nil
        launchBackHoldWorkItem?.cancel()
        launchBackHoldWorkItem = nil
        isLaunchBackPressActive = false
        didToggleIntroMovieInLaunchWindow = false
        isLaunchToggleWindowActive = true
        installLaunchBackKeyMonitorsIfNeeded()
        let workItem = DispatchWorkItem { endLaunchToggleWindow() }
        launchToggleWindowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + launchToggleWindowDuration, execute: workItem)
    }

    private func endLaunchToggleWindow() {
        launchToggleWindowWorkItem?.cancel()
        launchToggleWindowWorkItem = nil
        launchBackHoldWorkItem?.cancel()
        launchBackHoldWorkItem = nil
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
        let player = AVPlayer(url: url)
        player.isMuted = false
        self.player = player
        pendingLaunchWindowRevealOnIntroReady = false
        setLaunchWindowHidden(false)
        observeVideoCompletion(player: player)
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
        if let token = videoCompletionObserver {
            NotificationCenter.default.removeObserver(token)
            videoCompletionObserver = nil
        }
    }

    private func presentMenuFromLaunch(hidesWindowUntilReady: Bool) {
        let excludedWindowNumber = NSApplication.shared.windows.first?.windowNumber
        launchBackdropImage = captureBackdropImage(excludingWindowNumber: excludedWindowNumber)
        holdLaunchBackdropOverMenu = true
        pendingLaunchWindowRevealOnIntroReady = hidesWindowUntilReady && launchBackdropImage != nil
        pendingLaunchImmersivePresentationOnReveal = true
        setLaunchWindowHidden(pendingLaunchWindowRevealOnIntroReady)

        DispatchQueue.main.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                showMenu = true
                if !pendingLaunchWindowRevealOnIntroReady {
                    revealLaunchWindowForMenuIfNeeded()
                }
            }
        }
    }

    private func revealLaunchWindowForMenuIfNeeded() {
        setLaunchWindowHidden(false)
        guard pendingLaunchImmersivePresentationOnReveal else { return }
        pendingLaunchImmersivePresentationOnReveal = false
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .firstRowImmersivePresentationRequested, object: nil)
        }
    }

    private func setLaunchWindowHidden(_ isHidden: Bool) {
        guard let window = NSApplication.shared.windows.first else { return }
        window.alphaValue = isHidden ? 0 : 1
    }

    private func installLaunchBackKeyMonitorsIfNeeded() {
        guard launchBackKeyDownMonitor == nil else { return }
        launchBackKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            if KeyCode(rawValue: event.keyCode) == .delete, !event.isARepeat {
                handleLaunchBackPressBegan()
            }
            return event
        }
        launchBackKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [self] event in
            if KeyCode(rawValue: event.keyCode) == .delete {
                handleLaunchBackPressEnded()
            }
            return event
        }
    }

    private func removeLaunchBackKeyMonitors() {
        if let monitor = launchBackKeyDownMonitor {
            NSEvent.removeMonitor(monitor)
            launchBackKeyDownMonitor = nil
        }
        if let monitor = launchBackKeyUpMonitor {
            NSEvent.removeMonitor(monitor)
            launchBackKeyUpMonitor = nil
        }
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
