import AVFoundation
import AVFoundation
import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif
#if canImport(Darwin)
    import Darwin
#endif

extension MenuView {
    func resetScreenSaverIdleTimer() {
        lastUserInteractionAt = Date()
    }

    func registerUserInteractionForScreenSaver() {
        resetScreenSaverIdleTimer()
    }

    func startScreenSaverIdleMonitor() {
        stopScreenSaverIdleMonitor()
        let timer = Timer(after: screenSaverIdleCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible { self?.evaluateScreenSaverIdleActivation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        screenSaverIdleMonitorTimer = timer
    }

    func stopScreenSaverIdleMonitor() {
        screenSaverIdleMonitorTimer?.invalidate()
        screenSaverIdleMonitorTimer = nil
    }

    /// Time spent in the background doesn't count: the idle count stops when First Row leaves
    /// the front and starts again from nothing when it comes back.
    func pauseScreenSaverIdleWhileInBackground() {
        guard appActivityObservers.isEmpty else { return }
        #if os(macOS)
            let resign = NSApplication.willResignActiveNotification
            let active = NSApplication.didBecomeActiveNotification
        #elseif canImport(UIKit)
            let resign = UIApplication.willResignActiveNotification
            let active = UIApplication.didBecomeActiveNotification
        #else
            return
        #endif
        #if os(macOS) || canImport(UIKit)
            appActivityObservers.append(NotificationCenter.default.addObserver(forName: resign, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible { self?.stopScreenSaverIdleMonitor() }
            })
            appActivityObservers.append(NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible {
                    guard let self else { return }
                    self.resetScreenSaverIdleTimer()
                    self.startScreenSaverIdleMonitor()
                }
            })
        #endif
    }

    func evaluateScreenSaverIdleActivation() {
        guard shouldAutoActivateScreenSaver else { return }
        let elapsedIdleTime = Date().timeIntervalSince(lastUserInteractionAt)
        guard elapsedIdleTime >= screenSaverIdleActivationDelay else { return }
        resetScreenSaverIdleTimer()
        presentFullscreenScene(key: screenSaverFullscreenKey)
    }

    var isScreenSaverIdleFrozenForActiveMedia: Bool {
        if activeFullscreenScene?.key == photoSlideshowFullscreenKey {
            return true
        }
        return false
    }

    var shouldAutoActivateScreenSaver: Bool {
        guard isScreenSaverEnabled else { return false }
        guard !isScreenSaverIdleFrozenForActiveMedia else { return false }
        guard activeFullscreenScene == nil else { return false }
        guard !isFullscreenSceneTransitioning else { return false }
        guard !isMoviePlaybackVisible else { return false }
        guard !isMovieResumePromptVisible else { return false }
        guard !isMovieTransitioning else { return false }
        guard !isMenuFolderSwapTransitioning else { return false }
        return true
    }
}
