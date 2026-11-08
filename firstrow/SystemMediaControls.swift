#if !FIRSTROW_PORTABLE
    import AVFoundation
    import MediaPlayer
    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// Tells the system what First Row is playing and takes its commands back: the keyboard's
    /// media keys, Control Center, headphone buttons and, on iPhone and iPad, the Lock Screen.
    @MainActor
    final class SystemMediaControls {
        static let shared = SystemMediaControls()

        private weak var menu: MenuView?
        private var timer: Timer?
        private var published: (key: String, date: Date)?
        private var artworkSource: NSImage?
        private var artwork: MPMediaItemArtwork?

        func attach(_ menu: MenuView) {
            // Test copies leave the media keys to whatever the person at the Mac is using.
            guard !FirstRowHarness.isActive, self.menu == nil else { return }
            self.menu = menu
            let center = MPRemoteCommandCenter.shared()
            func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MenuView, MPRemoteCommandEvent) -> Bool) {
                command.isEnabled = true
                command.addTarget { [weak self] event in
                    // Commands normally arrive on the main thread; anything else is passed there.
                    guard Thread.isMainThread else {
                        DispatchQueue.main.async {
                            MainActor.runOnMainThread {
                                guard let menu = self?.menu else { return }
                                _ = action(menu, event)
                                self?.publish(force: true)
                            }
                        }
                        return .success
                    }
                    var handled = false
                    MainActor.runOnMainThread {
                        guard let menu = self?.menu else { return }
                        handled = action(menu, event)
                        self?.publish(force: true)
                    }
                    return handled ? .success : .noActionableNowPlayingItem
                }
            }
            handle(center.togglePlayPauseCommand) { menu, _ in menu.systemTogglePlayback() }
            handle(center.playCommand) { menu, _ in menu.systemSetPlaying(true) }
            handle(center.pauseCommand) { menu, _ in menu.systemSetPlaying(false) }
            handle(center.nextTrackCommand) { menu, _ in menu.systemChangeTrack(1) }
            handle(center.previousTrackCommand) { menu, _ in menu.systemChangeTrack(-1) }
            center.skipForwardCommand.preferredIntervals = [10]
            center.skipBackwardCommand.preferredIntervals = [10]
            handle(center.skipForwardCommand) { menu, _ in menu.systemSkip(by: 10) }
            handle(center.skipBackwardCommand) { menu, _ in menu.systemSkip(by: -10) }
            handle(center.changePlaybackPositionCommand) { menu, event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return false }
                return menu.systemSeek(to: event.positionTime)
            }
            let timer = Timer(after: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible { self?.publish(force: false) }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        /// Publishes the current item when it changes, and the position every few seconds (the
        /// system carries the clock on from the rate in between).
        private func publish(force: Bool) {
            guard let menu else { return }
            let info = menu.systemNowPlaying
            let center = MPNowPlayingInfoCenter.default()
            guard let info else {
                if published != nil {
                    center.nowPlayingInfo = nil
                    #if os(macOS)
                        center.playbackState = .stopped
                    #endif
                    published = nil
                }
                return
            }
            let key = "\(info.title)|\(info.artist)|\(info.album)|\(Int(info.duration))|\(info.isPlaying)"
            if !force, let published, published.key == key, Date().timeIntervalSince(published.date) < 5 {
                return
            }
            var values: [String: Any] = [
                MPMediaItemPropertyTitle: info.title,
                MPMediaItemPropertyPlaybackDuration: info.duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
                MPNowPlayingInfoPropertyPlaybackRate: info.isPlaying ? 1.0 : 0.0,
                MPNowPlayingInfoPropertyMediaType: NSNumber(value: (info.isVideo ? MPNowPlayingInfoMediaType.video : MPNowPlayingInfoMediaType.audio).rawValue),
            ]
            if !info.artist.isEmpty { values[MPMediaItemPropertyArtist] = info.artist }
            if !info.album.isEmpty { values[MPMediaItemPropertyAlbumTitle] = info.album }
            if let image = info.artwork {
                if image !== artworkSource {
                    artworkSource = image
                    artwork = Self.artwork(for: image)
                }
                if let artwork { values[MPMediaItemPropertyArtwork] = artwork }
            }
            center.nowPlayingInfo = values
            #if os(macOS)
                center.playbackState = info.isPlaying ? .playing : .paused
            #endif
            published = (key, Date())
        }

        private static func artwork(for image: NSImage) -> MPMediaItemArtwork? {
            let size = image.size
            guard size.width > 0, size.height > 0 else { return nil }
            // The system asks from any thread, so hand it a copy it can keep.
            let picture = image
            return MPMediaItemArtwork(boundsSize: size) { _ in picture }
        }
    }

    /// What the system is told is playing.
    struct SystemNowPlayingInfo {
        var title: String
        var artist: String = ""
        var album: String = ""
        var duration: Double
        var elapsed: Double
        var isPlaying: Bool
        var isVideo: Bool
        var artwork: NSImage?
    }

    extension MenuView {
        /// The movie or song First Row itself is playing, if any. Songs the Music app or the
        /// system music player play are left to them to announce.
        var systemNowPlaying: SystemNowPlayingInfo? {
            if isMoviePlaybackVisible, let player = moviePlayer {
                return SystemNowPlayingInfo(
                    title: currentMoviePlaybackDisplayTitle,
                    duration: max(0, moviePlaybackDurationSeconds.isFinite ? moviePlaybackDurationSeconds : 0),
                    elapsed: max(0, moviePlaybackCurrentSeconds),
                    isPlaying: player.rate > 0.01,
                    isVideo: true,
                )
            }
            guard hasActiveMusicPlaybackSession(), musicAudioPlayer != nil || isCurrentMusicPlaybackUsingSpotify else { return nil }
            return SystemNowPlayingInfo(
                title: musicNowPlayingTitle,
                artist: musicNowPlayingArtist,
                album: musicNowPlayingAlbum,
                duration: max(0, musicNowPlayingDurationSeconds),
                elapsed: max(0, musicNowPlayingElapsedSeconds),
                isPlaying: isMusicPlaybackRunning(),
                isVideo: false,
                artwork: musicNowPlayingArtwork,
            )
        }

        /// A movie's name as shown to the system: the file's name without its extension.
        var currentMoviePlaybackDisplayTitle: String {
            guard let url = currentMoviePlaybackURL else { return "Movie" }
            return url.deletingPathExtension().lastPathComponent
        }

        func systemTogglePlayback() -> Bool {
            if isMoviePlaybackVisible, moviePlayer != nil {
                handleMovieSpacebarPressed()
                return true
            }
            guard hasActiveMusicPlaybackSession() else { return false }
            handleMusicSpacebarPressed()
            return true
        }

        func systemSetPlaying(_ playing: Bool) -> Bool {
            if isMoviePlaybackVisible, let player = moviePlayer {
                if (player.rate > 0.01) != playing { handleMovieSpacebarPressed() }
                return true
            }
            guard hasActiveMusicPlaybackSession() else { return false }
            if isMusicPlaybackRunning() != playing { handleMusicSpacebarPressed() }
            return true
        }

        func systemChangeTrack(_ direction: Int) -> Bool {
            if isMoviePlaybackVisible {
                skipMovie(bySeconds: Double(direction) * 30)
                return true
            }
            guard hasActiveMusicPlaybackSession() else { return false }
            switchMusicNowPlayingTrack(direction: direction)
            return true
        }

        func systemSkip(by seconds: Double) -> Bool {
            if isMoviePlaybackVisible {
                skipMovie(bySeconds: seconds)
                return true
            }
            guard hasActiveMusicPlaybackSession() else { return false }
            return systemSeek(to: musicNowPlayingElapsedSeconds + seconds)
        }

        func systemSeek(to seconds: Double) -> Bool {
            if isMoviePlaybackVisible, let player = moviePlayer {
                let target = max(0, min(seconds, max(0, moviePlaybackDurationSeconds - 0.5)))
                moviePlaybackCurrentSeconds = target
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                return true
            }
            guard hasActiveMusicPlaybackSession() else { return false }
            let target = max(0, min(seconds, max(0, musicNowPlayingDurationSeconds - 0.5)))
            if let player = musicAudioPlayer {
                musicNowPlayingElapsedSeconds = target
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                return true
            }
            if isCurrentMusicPlaybackUsingSpotify {
                musicNowPlayingElapsedSeconds = target
                seekSpotify(toSeconds: target)
                return true
            }
            return false
        }
    }
#endif
