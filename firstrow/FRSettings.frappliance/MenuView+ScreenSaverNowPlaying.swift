import AVFoundation
import AVFoundation
import Foundation
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif
import Darwin

extension MenuView {
    func queueScreenSaverMusicTrackSwitch(direction: Int) {
        guard direction != 0 else { return }
        screenSaverPendingMusicTrackSwitchDelta += direction
        screenSaverPendingMusicTrackSwitchWorkItem?.cancel()
        screenSaverPendingMusicTrackSwitchWorkItem = Task {
            try? await firstRowSleep(screenSaverMusicTrackSwitchCoalesceDelay)
            guard !Task.isCancelled else { return }
            let pendingDelta = screenSaverPendingMusicTrackSwitchDelta
            screenSaverPendingMusicTrackSwitchDelta = 0
            screenSaverPendingMusicTrackSwitchWorkItem = nil
            guard activeFullscreenScene?.key == screenSaverFullscreenKey else { return }
            switchMusicNowPlayingTrack(direction: pendingDelta)
        }
    }

    func cancelScreenSaverMusicTrackSwitchQueue() {
        screenSaverPendingMusicTrackSwitchWorkItem?.cancel()
        screenSaverPendingMusicTrackSwitchWorkItem = nil
        screenSaverPendingMusicTrackSwitchDelta = 0
    }

    func dismissScreenSaverForUserInteraction() {
        registerUserInteractionForScreenSaver()
        endDirectionalHoldSession()
        cancelScreenSaverMusicTrackSwitchQueue()
        dismissFullscreenScene(preserveMusicPlayback: true)
    }

    func handleScreenSaverInput(_ key: KeyCode, isRepeat: Bool) {
        _ = isRepeat
        switch key {
        case .upArrow:
            queueScreenSaverMusicTrackSwitch(direction: -1)
        case .downArrow:
            queueScreenSaverMusicTrackSwitch(direction: 1)
        default:
            dismissFullscreenScene(preserveMusicPlayback: true)
        }
    }

    func triggerScreenSaverNowPlayingToastIfNeeded() {
        guard activeFullscreenScene?.key == screenSaverFullscreenKey else { return }
        guard hasActiveMusicPlaybackSession() else { return }
        screenSaverNowPlayingToastHideWorkItem?.cancel()
        screenSaverNowPlayingToastHideWorkItem = nil
        withAnimation(.easeInOut(duration: screenSaverNowPlayingToastFadeDuration)) {
            screenSaverNowPlayingToastOpacity = 1
        }
        screenSaverNowPlayingToastHideWorkItem = Task {
            try? await firstRowSleep(screenSaverNowPlayingToastVisibleDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: screenSaverNowPlayingToastFadeDuration)) {
                screenSaverNowPlayingToastOpacity = 0
            }
            screenSaverNowPlayingToastHideWorkItem = nil
        }
    }

    func clearScreenSaverNowPlayingToast() {
        cancelScreenSaverMusicTrackSwitchQueue()
        screenSaverNowPlayingToastHideWorkItem?.cancel()
        screenSaverNowPlayingToastHideWorkItem = nil
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            screenSaverNowPlayingToastOpacity = 0
        }
    }

    func normalizedScreenSaverToastText(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
