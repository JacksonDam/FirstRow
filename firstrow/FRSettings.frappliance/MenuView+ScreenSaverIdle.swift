import AVFoundation
import AVKit
import SwiftUI
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif
import Darwin

extension MenuView {
    func resetScreenSaverIdleTimer() {
        lastUserInteractionAt = Date()
    }

    func registerUserInteractionForScreenSaver() {
        resetScreenSaverIdleTimer()
    }

    func startScreenSaverIdleMonitor() {
        stopScreenSaverIdleMonitor()
        let timer = Timer(timeInterval: screenSaverIdleCheckInterval, repeats: true) { _ in
            evaluateScreenSaverIdleActivation()
        }
        RunLoop.main.add(timer, forMode: .common)
        screenSaverIdleMonitorTimer = timer
    }

    func stopScreenSaverIdleMonitor() {
        screenSaverIdleMonitorTimer?.invalidate()
        screenSaverIdleMonitorTimer = nil
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
