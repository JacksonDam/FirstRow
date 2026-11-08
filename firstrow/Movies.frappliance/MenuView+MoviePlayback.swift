import AVFoundation
import AVFoundation
#if canImport(Darwin)
    import Darwin
#endif
import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

extension MenuView {
    func startMoviePlayback(from url: URL) {
        guard !isMovieTransitioning else { return }
        resetScreenSaverIdleTimer()
        let normalizedURL = url.standardizedFileURL
        if shouldTreatAsAudioOnlyPlayback(url: normalizedURL) {
            clearActivePodcastAudioPlaybackContext()
            startAudioOnlyPlayback(
                from: normalizedURL,
                title: normalizedURL.deletingPathExtension().lastPathComponent,
                artist: "Unknown Artist",
                album: "",
                artwork: musicFallbackImage,
            )
            return
        }
        if shouldForceExternalMoviePlayback(for: normalizedURL) {
            handleProtectedMoviePlaybackAttempt(for: normalizedURL)
            return
        }
        let requestID = incrementRequestID(&moviePlaybackValidationRequestID)
        resolveMovieProtectedContentFlag(for: normalizedURL) { isProtected in
            guard self.moviePlaybackValidationRequestID == requestID else { return }
            guard !self.isMovieTransitioning else { return }
            if isProtected {
                self.handleProtectedMoviePlaybackAttempt(for: normalizedURL)
                return
            }
            self.beginMoviePlayback(for: normalizedURL)
        }
    }

    func beginMoviePlayback(for normalizedURL: URL) {
        isCurrentMoviePlaybackEphemeralPreview = false
        removeCurrentMoviePlaybackTemporaryFileIfNeeded()
        if shouldPresentMovieResumePrompt(for: normalizedURL) {
            startMovieResumePromptTransition(for: normalizedURL)
            return
        }
        startMoviePlaybackWithStandardTransition(from: normalizedURL)
    }

    func resolveMovieProtectedContentFlag(for url: URL, completion: @escaping (Bool) -> Void) {
        let asset = AVURLAsset(url: url)
        let key = "hasProtectedContent"
        asset.loadValuesAsynchronously(forKeys: [key]) {
            var error: NSError?
            _ = asset.statusOfValue(forKey: key, error: &error)
            let isProtected = asset.hasProtectedContent
            Task { @MainActor in completion(isProtected) }
        }
    }

    func handleProtectedMoviePlaybackAttempt(for url: URL) {
        #if os(macOS)
            if NSWorkspace.shared.open(url) {
                return
            }
        #elseif canImport(UIKit)
            if Thread.isMainThread {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else {
                Task { @MainActor in UIApplication.shared.open(url, options: [:], completionHandler: nil) }
            }
        #endif
        playSound(named: "Limit")
        presentFeatureErrorScreen(.protectedVideoUnsupported)
    }

    func startMovieResumePromptTransition(for url: URL) {
        guard !isMovieTransitioning else { return }
        isMovieTransitioning = true
        movieResumePromptOpacity = 0
        withAnimation(.easeInOut(duration: movieEntryFadeDuration)) {
            menuSceneOpacity = 0
        }
        let revealDelay = movieEntryFadeDuration + movieResumePromptRevealDelay
        Task {
            try? await firstRowSleep(revealDelay)
            guard !Task.isCancelled else { return }
            presentMovieResumePrompt(for: url)
            withAnimation(.easeInOut(duration: movieResumePromptFadeDuration)) {
                movieResumePromptOpacity = 1
            }
            try? await firstRowSleep(movieResumePromptFadeDuration)
            guard !Task.isCancelled else { return }
            isMovieTransitioning = false
        }
    }

    func startMoviePlaybackWithStandardTransition(from url: URL) {
        clearMoviePlaybackControlState()
        isMovieTransitioning = true
        let isModern = ModernTheme.isActive
        withAnimation(.easeInOut(duration: movieEntryFadeDuration)) {
            movieTransitionOverlayOpacity = 1
            menuSceneOpacity = 0
            // The modern look's menu recedes as it goes.
            if isModern { menuSceneScale = ModernTheme.sceneRecedeScale }
        }
        Task {
            try? await firstRowSleep(movieEntryFadeDuration + movieEntryBlackHoldDuration)
            guard !Task.isCancelled else { return }
            var instant = Transaction()
            instant.animation = nil
            if isModern {
                withTransaction(instant) {
                    menuSceneScale = 1
                    movieSceneScale = ModernTheme.sceneNearScale
                    movieSceneOpacity = 0
                }
            }
            activateMoviePlayback(from: url, startSeconds: 0, showsPlayGlyphOnStart: false)
            withTransaction(instant) {
                movieTransitionOverlayOpacity = 0
            }
            if isModern {
                // And the movie comes in from a little nearer.
                withAnimation(.smooth(duration: 0.5)) {
                    movieSceneScale = 1
                    movieSceneOpacity = 1
                }
            }
            isMovieTransitioning = false
        }
    }

    func shouldPresentMovieResumePrompt(for url: URL) -> Bool {
        movieResumeSeconds(for: url) > 0.05
    }

    /// Where `url` was stopped: this session's last movie, or any file stopped in an earlier one.
    func movieResumeSeconds(for url: URL) -> Double {
        if let lastClosedMovieURL, lastClosedMovieURL.standardizedFileURL == url.standardizedFileURL, lastClosedMovieTimestamp > 0.05 {
            return lastClosedMovieTimestamp
        }
        return MovieResumeStore.seconds(for: url) ?? 0
    }

    func presentMovieResumePrompt(for url: URL) {
        movieResumePromptTargetURL = url.standardizedFileURL
        movieResumePromptResumeSeconds = max(0, movieResumeSeconds(for: url))
        movieResumePromptSelectedIndex = 0
        movieResumePromptHideUnselected = false
        movieResumePromptSolidBlackSelected = false
        isMovieResumePromptConfirming = false
        movieResumePromptBackdropImage = nil
        movieResumePromptOpacity = 0
        isMovieResumePromptVisible = true
        let cacheKey = url.standardizedFileURL.path
        if let cached = movieResumePromptBackdropCache[cacheKey] {
            movieResumePromptBackdropImage = cached
            return
        }
        let requestID = incrementRequestID(&movieResumePromptBackdropRequestID)
        Task.detached(priority: .userInitiated) { [url] in
            let image = await self.generateMovieThumbnail(for: url, preferredSeconds: 0)
            await MainActor.run {
                guard self.movieResumePromptBackdropRequestID == requestID else { return }
                guard self.isMovieResumePromptVisible else { return }
                guard self.movieResumePromptTargetURL?.standardizedFileURL == url.standardizedFileURL else { return }
                if let image {
                    self.movieResumePromptBackdropCache[cacheKey] = image
                    self.movieResumePromptBackdropImage = image
                }
            }
        }
    }

    func dismissMovieResumePrompt() {
        isMovieResumePromptVisible = false
        isMovieResumePromptConfirming = false
        movieResumePromptHideUnselected = false
        movieResumePromptSolidBlackSelected = false
        movieResumePromptTargetURL = nil
        movieResumePromptResumeSeconds = 0
        movieResumePromptBackdropImage = nil
        _ = incrementRequestID(&movieResumePromptBackdropRequestID)
        movieResumePromptOpacity = 0
        lastArrowNavigationInputTime = nil
    }

    func dismissMovieResumePromptToMenu() {
        guard isMovieResumePromptVisible else { return }
        guard !isMovieTransitioning else { return }
        isMovieTransitioning = true
        withAnimation(.easeInOut(duration: movieResumePromptFadeDuration)) {
            movieResumePromptOpacity = 0
        }
        Task {
            try? await firstRowSleep(movieResumePromptFadeDuration)
            guard !Task.isCancelled else { return }
            dismissMovieResumePrompt()
            withAnimation(.easeInOut(duration: movieResumePromptFadeDuration)) {
                menuSceneOpacity = 1
            }
            try? await firstRowSleep(movieResumePromptFadeDuration)
            guard !Task.isCancelled else { return }
            isMovieTransitioning = false
        }
    }

    func handleMovieResumePromptInput(_ key: KeyCode, isRepeat: Bool) {
        guard isMovieResumePromptVisible, !isMovieResumePromptConfirming, !isMovieTransitioning else { return }
        _ = isRepeat
        switch key {
        case .upArrow, .downArrow:
            let now = Date()
            if let lastArrowNavigationInputTime,
               now.timeIntervalSince(lastArrowNavigationInputTime) < arrowInputDebounceInterval
            {
                return
            }
            lastArrowNavigationInputTime = now
            let delta = (key == .upArrow) ? -1 : 1
            let next = max(0, min(1, movieResumePromptSelectedIndex + delta))
            guard next != movieResumePromptSelectedIndex else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                movieResumePromptSelectedIndex = next
            }
            playSound(named: "SelectionChange")
        case .enter:
            triggerMovieResumePromptSelection()
        case .delete, .escape:
            dismissMovieResumePromptToMenu()
            playSound(named: "Exit")
        default:
            break
        }
    }

    func triggerMovieResumePromptSelection() {
        guard let targetURL = movieResumePromptTargetURL else { return }
        isMovieResumePromptConfirming = true
        playSound(named: "Selection")
        var instant = Transaction()
        instant.animation = nil
        withTransaction(instant) {
            movieResumePromptHideUnselected = true
            movieResumePromptSolidBlackSelected = true
        }
        withAnimation(.linear(duration: movieResumePromptLaunchFadeDuration)) {
            movieTransitionOverlayOpacity = 1
            movieResumePromptOpacity = 0
        }
        Task {
            try? await firstRowSleep(movieResumePromptLaunchFadeDuration)
            guard !Task.isCancelled else { return }
            let resumeFromSavedPosition = (movieResumePromptSelectedIndex == 0)
            let startSeconds = resumeFromSavedPosition ? movieResumePromptResumeSeconds : 0
            dismissMovieResumePrompt()
            clearMoviePlaybackControlState()
            isMovieTransitioning = true
            var instant = Transaction()
            instant.animation = nil
            withTransaction(instant) {
                menuSceneOpacity = 0
            }
            activateMoviePlayback(
                from: targetURL,
                startSeconds: startSeconds,
                showsPlayGlyphOnStart: true,
            )
            withTransaction(instant) {
                movieTransitionOverlayOpacity = 0
            }
            isMovieTransitioning = false
        }
    }

    func activateMoviePlayback(
        from url: URL,
        startSeconds: Double,
        showsPlayGlyphOnStart: Bool,
    ) {
        // Ensure movie/video playback never overlaps with an existing audio session.
        if hasActiveMusicPlaybackSession() {
            stopMusicPlaybackSession(clearDisplayState: false)
        }
        let player = AVPlayer(url: url)
        player.isMuted = FirstRowHarness.isActive
        configureMoviePlaybackObservation(for: player)
        currentMoviePlaybackURL = url.standardizedFileURL
        moviePlayer = player
        isMoviePlaybackVisible = true
        pendingMovieControlsRevealOnDurationReady = false
        let clampedStart = max(0, startSeconds.isFinite ? startSeconds : 0)
        if clampedStart > 0.001 {
            moviePlaybackCurrentSeconds = clampedStart
            player.seek(
                to: CMTime(seconds: clampedStart, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero,
            ) { _ in
                player.play()
            }
        } else {
            player.play()
        }
        if showsPlayGlyphOnStart {
            movieControlsGlyphState = .play
            showMovieControlsInstantly()
            scheduleMovieControlsAutoHide()
        }
        jellyfinMoviePlaybackDidActivate(url: url, startSeconds: clampedStart)
    }

    func captureLastClosedMoviePlaybackPosition() {
        guard let currentMoviePlaybackURL else {
            lastClosedMovieURL = nil
            lastClosedMovieTimestamp = 0
            return
        }
        var closedAt = moviePlaybackCurrentSeconds
        if let playerSeconds = moviePlayer?.currentTime().seconds, playerSeconds.isFinite {
            closedAt = max(closedAt, playerSeconds)
        }
        if closedAt.isFinite, closedAt > 0.05 {
            lastClosedMovieURL = currentMoviePlaybackURL.standardizedFileURL
            lastClosedMovieTimestamp = closedAt
            MovieResumeStore.record(currentMoviePlaybackURL, seconds: closedAt, duration: moviePlaybackDurationSeconds)
            refreshContinueWatchingIfShown()
        } else {
            lastClosedMovieURL = nil
            lastClosedMovieTimestamp = 0
        }
    }

    func stopMoviePlaybackAndReturnToMenu(captureResumePosition: Bool = true) {
        guard !isMovieTransitioning, isMoviePlaybackVisible else { return }
        movieOptions = nil
        isMovieTransitioning = true
        stopMovieScrubbing(revertToPause: false, scheduleAutoHide: false)
        clearMovieControlsVisibilityInstantly()
        moviePlayer?.pause()
        jellyfinMoviePlaybackWillEnd()
        let shouldCaptureResumePosition = captureResumePosition && !isCurrentMoviePlaybackEphemeralPreview
        if shouldCaptureResumePosition {
            captureLastClosedMoviePlaybackPosition()
        } else {
            lastClosedMovieURL = nil
            lastClosedMovieTimestamp = 0
        }
        if ModernTheme.isActive {
            recedeMovieToMenu()
            return
        }
        Task {
            try? await firstRowSleep(movieExitFreezeHoldDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: movieExitFadeDuration)) {
                movieTransitionOverlayOpacity = 1
            }
            try? await firstRowSleep(movieExitFadeDuration)
            guard !Task.isCancelled else { return }
            tearDownMoviePlayback()
            withAnimation(.easeInOut(duration: 0.24)) {
                menuSceneOpacity = 1
                movieTransitionOverlayOpacity = 0
            }
            try? await firstRowSleep(0.24)
            guard !Task.isCancelled else { return }
            resetScreenSaverIdleTimer()
            isMovieTransitioning = false
        }
    }

    /// The modern look's way out of a movie, with no black between: the movie shrinks back
    /// and fades, and the menu comes in from a little nearer, as full-screen scenes do.
    private func recedeMovieToMenu() {
        let leave = Animation.smoothInOut(duration: 0.36)
        let arrive = Animation.smooth(duration: 0.5)
        var instant = Transaction()
        instant.disablesAnimations = true
        Task {
            // Long enough to see the movie stop where it was.
            try? await firstRowSleep(0.12)
            guard !Task.isCancelled else { return }
            withTransaction(instant) {
                menuSceneScale = ModernTheme.sceneNearScale
            }
            withAnimation(leave) {
                movieSceneOpacity = 0
                movieSceneScale = ModernTheme.sceneRecedeScale
            }
            try? await firstRowSleep(leave.duration * 0.7)
            guard !Task.isCancelled else { return }
            withAnimation(arrive) {
                menuSceneOpacity = 1
                menuSceneScale = 1
            }
            try? await firstRowSleep(leave.duration * 0.3 + 0.02)
            guard !Task.isCancelled else { return }
            tearDownMoviePlayback()
            withTransaction(instant) {
                movieSceneOpacity = 1
                movieSceneScale = 1
            }
            try? await firstRowSleep(max(0, arrive.duration - leave.duration * 0.3))
            guard !Task.isCancelled else { return }
            resetScreenSaverIdleTimer()
            isMovieTransitioning = false
        }
    }

    /// Lets go of the movie once it's out of sight.
    private func tearDownMoviePlayback() {
        removeMoviePlaybackObservation()
        moviePlayer = nil
        isMoviePlaybackVisible = false
        clearMoviePlaybackControlState()
        isCurrentMoviePlaybackEphemeralPreview = false
        removeCurrentMoviePlaybackTemporaryFileIfNeeded()
    }

    func handleMoviePlaybackInput(_ key: KeyCode, isRepeat: Bool) {
        if handleMovieOptionsInput(key) { return }
        switch key {
        case .downArrow:
            if !isRepeat { openMovieOptions() }
        case .delete, .escape:
            playSound(named: "Exit")
            stopMoviePlaybackAndReturnToMenu()
        case .space, .enter:
            handleMovieSpacebarPressed()
        case .leftArrow:
            handleMovieArrow(direction: -1, isRepeat: isRepeat)
        case .rightArrow:
            handleMovieArrow(direction: 1, isRepeat: isRepeat)
        default:
            break
        }
    }

    /// A tap of left or right skips ten seconds; held, it scrubs as before.
    func handleMovieArrow(direction: Int, isRepeat: Bool) {
        if isRepeat || movieScrubDirection != 0 {
            movieArrowPending = nil
            beginMovieScrubbing(direction: direction, isRepeat: isRepeat)
            return
        }
        guard moviePlayer != nil else { return }
        // A new press means the last one was let go: if it was still undecided, it was a tap.
        if let pending = movieArrowPending {
            pending.task.cancel()
            movieArrowPending = nil
            skipMovie(bySeconds: Double(pending.direction) * 10)
        }
        showMovieControlsInstantly()
        let task = Task { @MainActor in
            try? await firstRowSleep(0.3)
            guard !Task.isCancelled, isMoviePlaybackVisible, movieArrowPending?.direction == direction else { return }
            movieArrowPending = nil
            if isHoldingScrubKey(direction: direction) {
                beginMovieScrubbing(direction: direction, isRepeat: false)
            } else {
                skipMovie(bySeconds: Double(direction) * 10)
            }
        }
        movieArrowPending = (direction, task)
    }

    // MARK: - Movie Controls and Scrubbing

    func handleMovieSpacebarPressed() {
        guard let player = moviePlayer else { return }
        showMovieControlsInstantly()
        let isCurrentlyPlaying = player.rate > 0.01
        if isCurrentlyPlaying {
            player.pause()
            stopMovieScrubbing(revertToPause: true, scheduleAutoHide: false)
            movieControlsGlyphState = .pause
            scheduleMovieControlsAutoHide()
            return
        }
        stopMovieScrubbing(revertToPause: false, scheduleAutoHide: false)
        movieControlsGlyphState = .play
        player.play()
        if movieSpeed != 1 { applyMovieSpeed(player) }
        if movieOptions == nil { hideMovieControlsWithFade() }
    }

    func beginMovieScrubbing(direction: Int, isRepeat: Bool) {
        guard let player = moviePlayer else { return }
        guard direction != 0 else { return }
        _ = isRepeat
        showMovieControlsInstantly()
        cancelMovieControlsAutoHide()
        player.pause()
        let now = Date()
        if movieScrubDirection != direction {
            movieScrubDirection = direction
            movieScrubStartDate = now
            movieLastScrubTickDate = now
        } else if movieScrubStartDate == nil {
            movieScrubStartDate = now
            movieLastScrubTickDate = now
        }
        movieLastScrubInputDate = now
        let holdDuration = now.timeIntervalSince(movieScrubStartDate ?? now)
        let level = movieScrubLevel(for: holdDuration)
        movieControlsGlyphState = direction > 0 ? .fastForward(level) : .rewind(level)
        startMovieScrubTimerIfNeeded()
    }

    func movieScrubLevel(for holdDuration: TimeInterval) -> Int {
        if holdDuration >= 1.3 { return 3 }
        if holdDuration >= 0.6 { return 2 }
        return 1
    }

    func movieScrubVelocity(for level: Int, durationSeconds: Double) -> Double {
        let safeDuration = max(10, durationSeconds.isFinite ? durationSeconds : 0)
        let normalizedDuration = max(0.2, safeDuration / 30.0)
        let durationScale = min(32.0, max(0.75, pow(normalizedDuration, 0.6)))
        let baseVelocity = switch level {
        case 3:
            10.5
        case 2:
            4.8
        default:
            1.8
        }
        return baseVelocity * durationScale
    }

    func startMovieScrubTimerIfNeeded() {
        guard movieScrubTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            MainActor.assumeIsolatedIfPossible {
                self.handleMovieScrubTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        movieScrubTimer = timer
    }

    func stopMovieScrubTimer() {
        movieScrubTimer?.invalidate()
        movieScrubTimer = nil
    }

    func handleMovieScrubTick() {
        guard movieScrubDirection != 0 else {
            stopMovieScrubTimer()
            return
        }
        guard let player = moviePlayer else {
            stopMovieScrubbing(revertToPause: true, scheduleAutoHide: false)
            return
        }
        let now = Date()
        guard let lastInput = movieLastScrubInputDate else {
            stopMovieScrubbing(revertToPause: true, scheduleAutoHide: true)
            return
        }
        if !isHoldingScrubKey(direction: movieScrubDirection), now.timeIntervalSince(lastInput) > movieScrubReleaseGracePeriod {
            stopMovieScrubbing(revertToPause: true, scheduleAutoHide: true)
            return
        }
        let delta = now.timeIntervalSince(movieLastScrubTickDate ?? now)
        guard delta > 0 else { return }
        movieLastScrubTickDate = now
        let holdDuration = now.timeIntervalSince(movieScrubStartDate ?? now)
        let level = movieScrubLevel(for: holdDuration)
        movieControlsGlyphState = movieScrubDirection > 0 ? .fastForward(level) : .rewind(level)
        let resolvedDuration = resolvedMovieDurationSeconds(for: player)
        if resolvedDuration > 0 {
            moviePlaybackDurationSeconds = resolvedDuration
        }
        let maxTime = max(0, resolvedDuration > 0 ? resolvedDuration : moviePlaybackDurationSeconds)
        let effectiveDuration = maxTime > 0 ? maxTime : moviePlaybackDurationSeconds
        let velocity = movieScrubVelocity(for: level, durationSeconds: effectiveDuration)
        let unclampedTime = moviePlaybackCurrentSeconds + (Double(movieScrubDirection) * velocity * delta)
        let targetSeconds = max(0, min(maxTime > 0 ? maxTime : unclampedTime, unclampedTime))
        moviePlaybackCurrentSeconds = max(0, targetSeconds)
        player.seek(
            to: CMTime(seconds: moviePlaybackCurrentSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero,
        )
    }

    func stopMovieScrubbing(revertToPause: Bool, scheduleAutoHide: Bool) {
        movieScrubDirection = 0
        movieScrubStartDate = nil
        movieLastScrubInputDate = nil
        movieLastScrubTickDate = nil
        stopMovieScrubTimer()
        if revertToPause {
            movieControlsGlyphState = .pause
        }
        if scheduleAutoHide {
            scheduleMovieControlsAutoHide()
        }
    }

    func showMovieControlsInstantly() {
        cancelMovieControlsAutoHide()
        var instant = Transaction()
        instant.animation = nil
        withTransaction(instant) {
            areMovieControlsVisible = true
            movieControlsOpacity = 1
        }
    }

    func clearMovieControlsVisibilityInstantly() {
        cancelMovieControlsAutoHide()
        var instant = Transaction()
        instant.animation = nil
        withTransaction(instant) {
            areMovieControlsVisible = false
            movieControlsOpacity = 0
        }
    }

    func hideMovieControlsWithFade() {
        cancelMovieControlsAutoHide()
        guard areMovieControlsVisible, movieOptions == nil else { return }
        withAnimation(.easeOut(duration: movieControlsFadeDuration)) {
            movieControlsOpacity = 0
        }
        Task {
            try? await firstRowSleep(movieControlsFadeDuration)
            guard !Task.isCancelled else { return }
            guard movieControlsOpacity <= 0.001 else { return }
            areMovieControlsVisible = false
        }
    }

    func scheduleMovieControlsAutoHide() {
        cancelMovieControlsAutoHide()
        movieControlsHideWorkItem = Task {
            try? await firstRowSleep(movieControlsAutoHideDelay)
            // The controls stay while the options are open; closing them starts the wait again.
            guard !Task.isCancelled, movieOptions == nil else { return }
            hideMovieControlsWithFade()
        }
    }

    func cancelMovieControlsAutoHide() {
        movieControlsHideWorkItem?.cancel()
        movieControlsHideWorkItem = nil
    }

    func configureMoviePlaybackObservation(for player: AVPlayer) {
        removeMoviePlaybackObservation()
        movieOptions = nil
        movieSpeed = 1
        observedMoviePlayer = player
        moviePlaybackCurrentSeconds = max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
        moviePlaybackDurationSeconds = resolvedMovieDurationSeconds(for: player)
        if let currentItem = player.currentItem {
            moviePlaybackDidEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main,
            ) { _ in
                MainActor.assumeIsolatedIfPossible {
                    guard self.observedMoviePlayer === player else { return }
                    guard self.isMoviePlaybackVisible else { return }
                    guard !self.isMovieTransitioning else { return }
                    let resolvedDuration = self.resolvedMovieDurationSeconds(for: player)
                    self.moviePlaybackDurationSeconds = max(self.moviePlaybackDurationSeconds, resolvedDuration)
                    self.moviePlaybackCurrentSeconds = self.moviePlaybackDurationSeconds
                    // Watched to the end: nothing left to resume.
                    if let url = self.currentMoviePlaybackURL {
                        MovieResumeStore.remove(url)
                        self.refreshContinueWatchingIfShown()
                    }
                    if self.jellyfinPlayNextEpisodeAtEnd() { return }
                    self.stopMoviePlaybackAndReturnToMenu(captureResumePosition: false)
                }
            }
        }
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        movieTimeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let currentSeconds = max(0, time.seconds.isFinite ? time.seconds : 0)
            if self.movieScrubDirection == 0 {
                self.moviePlaybackCurrentSeconds = currentSeconds
            }
            let durationSeconds = self.resolvedMovieDurationSeconds(for: player)
            if durationSeconds > 0 {
                self.moviePlaybackDurationSeconds = durationSeconds
                if self.pendingMovieControlsRevealOnDurationReady {
                    self.pendingMovieControlsRevealOnDurationReady = false
                    self.showMovieControlsInstantly()
                    self.scheduleMovieControlsAutoHide()
                }
            }
        }
    }

    func removeMoviePlaybackObservation() {
        if let token = movieTimeObserverToken, let observedMoviePlayer {
            observedMoviePlayer.removeTimeObserver(token)
        }
        movieTimeObserverToken = nil
        if let moviePlaybackDidEndObserver {
            NotificationCenter.default.removeObserver(moviePlaybackDidEndObserver)
        }
        moviePlaybackDidEndObserver = nil
        observedMoviePlayer = nil
    }

    func resolvedMovieDurationSeconds(for player: AVPlayer) -> Double {
        guard let currentItem = player.currentItem else { return 0 }
        let itemDuration = currentItem.duration.seconds
        if itemDuration.isFinite, itemDuration > 0 {
            return itemDuration
        }
        return 0
    }

    func clearMoviePlaybackControlState() {
        cancelMovieControlsAutoHide()
        stopMovieScrubbing(revertToPause: false, scheduleAutoHide: false)
        removeMoviePlaybackObservation()
        clearMovieControlsVisibilityInstantly()
        currentMoviePlaybackURL = nil
        movieControlsGlyphState = .pause
        isMoviePreviewDownloadLoading = false
        moviePreviewDownloadProgress = 0
        moviePlaybackCurrentSeconds = 0
        moviePlaybackDurationSeconds = 0
        pendingMovieControlsRevealOnDurationReady = false
    }
}
