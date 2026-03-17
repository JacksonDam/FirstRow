import AVFoundation
import AVKit
import SwiftUI
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

    @ViewBuilder
    func screenSaverNowPlayingToastView() -> some View {
        let artwork = musicNowPlayingArtwork ?? musicFallbackImage ?? podcastFallbackImage
        let title = normalizedScreenSaverToastText(musicNowPlayingTitle, fallback: "Unknown Song")
        let album = normalizedScreenSaverToastText(musicNowPlayingAlbum, fallback: "Unknown Album")
        let artist = normalizedScreenSaverToastText(musicNowPlayingArtist, fallback: "Unknown Artist")
        let artworkSize: CGFloat = 130
        HStack(alignment: .center, spacing: 16) {
            Group {
                if let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill().frame(width: artworkSize, height: artworkSize).clipped()
                } else {
                    Rectangle().fill(Color.black.opacity(0.35)).frame(width: artworkSize, height: artworkSize)
                }
            }.frame(width: artworkSize, height: artworkSize).overlay(
                Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1),
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.firstRowBold(size: 30)).foregroundStyleCompat(.white).lineLimit(1).truncationMode(.tail)
                Text(album).font(.firstRowRegular(size: 24)).foregroundStyleCompat(.white.opacity(0.9)).lineLimit(1).truncationMode(.tail)
                Text(artist).font(.firstRowRegular(size: 24)).foregroundStyleCompat(.white.opacity(0.9)).lineLimit(1).truncationMode(.tail)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 18).frame(width: screenSaverNowPlayingToastSize.width, height: screenSaverNowPlayingToastSize.height).background(Color.black.opacity(0.5))
    }

    func normalizedScreenSaverToastText(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
