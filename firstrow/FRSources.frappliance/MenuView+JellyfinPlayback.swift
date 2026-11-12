import AVFoundation
import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// Something playing from a Jellyfin server, and what the server was last told about it.
struct JellyfinPlaybackSession {
    var serverKey: String
    var item: JellyfinItem
    var stream: JellyfinStream?
    var url: URL
    var lastReport = Date.distantPast
    var lastPosition: Double = 0
    var lastPaused = false
    var hasStarted = false
}

/// Playing Jellyfin videos through the movie player and songs through Now Playing, and keeping
/// the server up to date so watched states and resume points follow to other Jellyfin apps.
extension MenuView {
    // MARK: - Video

    func playJellyfinVideo(_ item: JellyfinItem, serverKey key: String) {
        guard !isMovieTransitioning, !isMoviePlaybackVisible, !isStartingJellyfinPlayback,
              let record = JellyfinStore.shared.server(withKey: key), let client = JellyfinClient(record: record)
        else { return }
        isStartingJellyfinPlayback = true
        resetScreenSaverIdleTimer()
        Task { @MainActor in
            defer { self.isStartingJellyfinPlayback = false }
            // The latest resume point, since the list may be older than another device's playback.
            let fresh = (try? await client.item(item.id)) ?? item
            let resumeSeconds = fresh.userData?.played == true ? 0 : fresh.resumeSeconds
            async let backdrop = self.jellyfinBackdrop(for: fresh, client: client)
            let stream: JellyfinStream
            do {
                stream = try await client.videoStream(for: fresh)
            } catch {
                self.playSound(named: "Limit")
                let unreachable = (error as? JellyfinError).map { if case .unreachable = $0 { true } else { false } } ?? false
                self.presentFullscreenScene(key: self.featureErrorFullscreenKey, payload: [
                    "header": "This video can't be played.",
                    "subcaption": unreachable ? "The server can't be reached." : "The server couldn't prepare it for playing here.",
                ])
                return
            }
            let backdropImage = await backdrop
            guard self.thirdMenuMode == .jellyfin, !self.isMovieTransitioning, !self.isMoviePlaybackVisible else { return }
            self.jellyfinVideoSession = JellyfinPlaybackSession(serverKey: key, item: fresh, stream: stream, url: stream.url)
            // The resume prompt reads these, as it does for a movie closed part way through.
            let url = stream.url.standardizedFileURL
            if resumeSeconds > 5, fresh.durationSeconds <= 0 || resumeSeconds < fresh.durationSeconds - 10 {
                self.lastClosedMovieURL = url
                self.lastClosedMovieTimestamp = resumeSeconds
            } else {
                self.lastClosedMovieURL = nil
                self.lastClosedMovieTimestamp = 0
            }
            if let backdropImage {
                self.movieResumePromptBackdropCache[url.path] = backdropImage
            }
            self.beginMoviePlayback(for: url)
        }
    }

    private func jellyfinBackdrop(for item: JellyfinItem, client: JellyfinClient) async -> NSImage? {
        guard let url = client.backdropImageURL(for: item) ?? client.primaryImageURL(for: item) else { return nil }
        return await loadJellyfinImage(url)
    }

    /// Called as the movie player starts a URL.
    func jellyfinMoviePlaybackDidActivate(url: URL, startSeconds: Double) {
        guard var session = jellyfinVideoSession else { return }
        guard session.url.standardizedFileURL == url.standardizedFileURL else {
            jellyfinVideoSession = nil
            return
        }
        session.hasStarted = true
        session.lastReport = Date()
        session.lastPosition = startSeconds
        jellyfinVideoSession = session
        if let client = jellyfinClient(for: session) {
            let itemID = session.item.id
            let stream = session.stream
            Task { await client.reportStart(itemID: itemID, stream: stream, positionSeconds: startSeconds) }
        }
        startJellyfinProgressTimer()
    }

    /// Called as the movie player stops, before it lets go of the player.
    func jellyfinMoviePlaybackWillEnd(atEnd: Bool = false) {
        guard let session = jellyfinVideoSession else { return }
        jellyfinVideoSession = nil
        stopJellyfinProgressTimerIfIdle()
        guard session.hasStarted, let client = jellyfinClient(for: session) else { return }
        var position = moviePlaybackCurrentSeconds
        if let seconds = moviePlayer?.positionSeconds { position = max(position, seconds) }
        if atEnd { position = max(position, session.item.durationSeconds) }
        let itemID = session.item.id
        let stream = session.stream
        Task { @MainActor in
            await client.reportStopped(itemID: itemID, stream: stream, positionSeconds: position)
            self.refreshJellyfinPageAfterPlayback()
        }
    }

    /// At the end of an episode, plays the next one in the series. Returns false when there isn't one.
    func jellyfinPlayNextEpisodeAtEnd() -> Bool {
        guard let session = jellyfinVideoSession, session.item.type == "Episode", session.item.seriesID != nil,
              let client = jellyfinClient(for: session)
        else { return false }
        let key = session.serverKey
        jellyfinMoviePlaybackWillEnd(atEnd: true)
        isMovieTransitioning = true
        stopMovieScrubbing(revertToPause: false, scheduleAutoHide: false)
        clearMovieControlsVisibilityInstantly()
        withAnimation(.easeInOut(duration: movieExitFadeDuration)) {
            movieTransitionOverlayOpacity = 1
        }
        Task { @MainActor in
            async let wait: Void = firstRowSleep(self.movieExitFadeDuration)
            let next = await client.episode(after: session.item)
            var stream: JellyfinStream?
            if let next { stream = try? await client.videoStream(for: next) }
            try? await wait
            guard let next, let stream else {
                self.isMovieTransitioning = false
                self.stopMoviePlaybackAndReturnToMenu(captureResumePosition: false)
                return
            }
            self.removeMoviePlaybackObservation()
            self.moviePlayer?.pause()
            self.moviePlayer = nil
            self.clearMoviePlaybackControlState()
            self.jellyfinVideoSession = JellyfinPlaybackSession(serverKey: key, item: next, stream: stream, url: stream.url)
            self.activateMoviePlayback(from: stream.url, startSeconds: 0, showsPlayGlyphOnStart: false)
            try? await firstRowSleep(0.3)
            withAnimation(.easeInOut(duration: 0.48)) {
                self.movieTransitionOverlayOpacity = 0
            }
            self.isMovieTransitioning = false
        }
        return true
    }

    // MARK: - Music

    /// Called once a song starts.
    func jellyfinMusicPlaybackDidStart(_ song: MusicLibrarySongEntry) {
        endJellyfinMusicReporting()
        guard let reference = song.jellyfin, let url = song.url else { return }
        let item = JellyfinItem(id: reference.itemID, name: song.title, runTimeTicks: Int64(song.durationSeconds * 10_000_000))
        var session = JellyfinPlaybackSession(serverKey: reference.serverKey, item: item, stream: nil, url: url)
        session.hasStarted = true
        session.lastReport = Date()
        jellyfinMusicSession = session
        if let client = jellyfinClient(for: session) {
            Task { await client.reportStart(itemID: reference.itemID, stream: nil, positionSeconds: 0) }
        }
        startJellyfinProgressTimer()
    }

    /// Called as music stops or moves to another song.
    func endJellyfinMusicReporting() {
        guard let session = jellyfinMusicSession else { return }
        jellyfinMusicSession = nil
        stopJellyfinProgressTimerIfIdle()
        guard let client = jellyfinClient(for: session) else { return }
        let position = musicNowPlayingElapsedSeconds
        Task { await client.reportStopped(itemID: session.item.id, stream: nil, positionSeconds: position) }
    }

    // MARK: - Progress

    private func jellyfinClient(for session: JellyfinPlaybackSession) -> JellyfinClient? {
        JellyfinStore.shared.server(withKey: session.serverKey).flatMap { JellyfinClient(record: $0) }
    }

    private func startJellyfinProgressTimer() {
        guard jellyfinProgressTimer == nil else { return }
        let timer = Timer(after: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolatedIfPossible { self?.reportJellyfinProgressIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        jellyfinProgressTimer = timer
    }

    private func stopJellyfinProgressTimerIfIdle() {
        guard jellyfinVideoSession == nil, jellyfinMusicSession == nil else { return }
        jellyfinProgressTimer?.invalidate()
        jellyfinProgressTimer = nil
    }

    /// Every ten seconds, and straight away on a pause, a resume or a jump.
    private func reportJellyfinProgressIfDue() {
        let now = Date()
        func check(_ session: inout JellyfinPlaybackSession, position: Double, paused: Bool) -> Bool {
            let expected = session.lastPosition + (session.lastPaused ? 0 : now.timeIntervalSince(session.lastReport))
            let jumped = abs(position - expected) > 4
            guard paused != session.lastPaused || jumped || now.timeIntervalSince(session.lastReport) >= 10 else { return false }
            session.lastReport = now
            session.lastPosition = position
            session.lastPaused = paused
            return true
        }
        if var session = jellyfinVideoSession, session.hasStarted, isMoviePlaybackVisible {
            let paused = (moviePlayer?.rate ?? 0) < 0.01
            if check(&session, position: moviePlaybackCurrentSeconds, paused: paused) {
                jellyfinVideoSession = session
                if let client = jellyfinClient(for: session) {
                    let position = moviePlaybackCurrentSeconds
                    Task { await client.reportProgress(itemID: session.item.id, stream: session.stream, positionSeconds: position, isPaused: paused) }
                }
            }
        }
        if var session = jellyfinMusicSession {
            let paused = !isMusicPlaybackRunning()
            if check(&session, position: musicNowPlayingElapsedSeconds, paused: paused) {
                jellyfinMusicSession = session
                if let client = jellyfinClient(for: session) {
                    let position = musicNowPlayingElapsedSeconds
                    Task { await client.reportProgress(itemID: session.item.id, stream: nil, positionSeconds: position, isPaused: paused) }
                }
            }
        }
    }
}
