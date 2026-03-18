import AppKit
import AVFoundation
import AVKit
import Darwin
import SwiftUI

extension MenuView {
    func startMoviePlayback(from url: URL) {
        guard !isMovieTransitioning else { return }
        let normalizedURL = url.standardizedFileURL
        if shouldTreatAsAudioOnlyPlayback(url: normalizedURL) {
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
            enterMovieResumePromptPage(for: normalizedURL)
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
            DispatchQueue.main.async {
                completion(isProtected)
            }
        }
    }

    func handleProtectedMoviePlaybackAttempt(for url: URL) {
        if NSWorkspace.shared.open(url) {
            return
        }
        playSound(named: "Limit")
        presentFeatureErrorScreen(.protectedVideoUnsupported)
    }

    func enterMovieResumePromptPage(for url: URL) {
        guard !isEnteringSubmenu, !isReturningToRoot else { return }

        movieResumePromptTargetURL = url.standardizedFileURL
        movieResumePromptResumeSeconds = max(0, lastClosedMovieTimestamp)

        let returnMode = isInThirdMenu ? thirdMenuMode : ThirdMenuMode.none
        let returnHeader = headerText
        let returnSelectedIndex = selectedThirdIndex

        let snapshot = currentMenuTransitionSnapshot()
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            movieResumeReturnSelectedThirdIndex = returnSelectedIndex
            selectedThirdIndex = 0
            movieResumeReturnThirdMenuMode = returnMode
            movieResumeReturnHeaderText = returnHeader
            movieResumeBackdropOpacity = 0
            movieResumePromptBackdropImage = nil
            _ = incrementRequestID(&movieResumePromptBackdropRequestID)
            menuTransitionSnapshot = snapshot
            menuTransitionDirection = .forward
            menuTransitionProgress = 0
            isInThirdMenu = true
            thirdMenuMode = .movieResumePrompt
        }

        withAnimation(.easeInOut(duration: menuSlideDuration)) {
            menuTransitionProgress = 1
        }

        let cacheKey = url.standardizedFileURL.path
        let capturedResumeSeconds = movieResumePromptResumeSeconds
        let capturedURL = url.standardizedFileURL

        DispatchQueue.main.asyncAfter(deadline: .now() + menuSlideDuration) {
            self.menuTransitionSnapshot = nil
            guard self.thirdMenuMode == .movieResumePrompt else { return }

            if let cached = self.movieResumePromptBackdropCache[cacheKey] {
                self.movieResumePromptBackdropImage = cached
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.movieResumeBackdropOpacity = 1
                }
                return
            }

            let fetchRequestID = self.incrementRequestID(&self.movieResumePromptBackdropRequestID)
            Task.detached(priority: .userInitiated) { [capturedURL, capturedResumeSeconds, fetchRequestID, cacheKey] in
                let image = await self.generateMovieThumbnail(for: capturedURL, preferredSeconds: capturedResumeSeconds)
                await MainActor.run {
                    guard self.movieResumePromptBackdropRequestID == fetchRequestID else { return }
                    guard self.thirdMenuMode == .movieResumePrompt else { return }
                    if let image {
                        self.movieResumePromptBackdropCache[cacheKey] = image
                        self.movieResumePromptBackdropImage = image
                    }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.movieResumeBackdropOpacity = 1
                    }
                }
            }
        }
    }

    func startMoviePlaybackWithStandardTransition(from url: URL) {
        clearMoviePlaybackControlState()
        isMovieTransitioning = true
        withAnimation(.easeInOut(duration: movieEntryFadeDuration)) {
            movieTransitionOverlayOpacity = 1
            menuSceneOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + movieEntryFadeDuration + movieEntryBlackHoldDuration) {
            activateMoviePlayback(from: url, startSeconds: 0, showsPlayGlyphOnStart: false)
            var instant = Transaction()
            instant.animation = nil
            withTransaction(instant) {
                movieTransitionOverlayOpacity = 0
            }
            isMovieTransitioning = false
        }
    }

    func shouldPresentMovieResumePrompt(for url: URL) -> Bool {
        guard let lastClosedMovieURL else { return false }
        guard lastClosedMovieURL.standardizedFileURL == url.standardizedFileURL else { return false }
        return lastClosedMovieTimestamp > 0.05
    }

    func dismissMovieResumePrompt() {
        movieResumePromptTargetURL = nil
        movieResumePromptResumeSeconds = 0
        movieResumePromptBackdropImage = nil
        _ = incrementRequestID(&movieResumePromptBackdropRequestID)
        movieResumeBackdropOpacity = 0
        lastArrowNavigationInputTime = nil
    }

    func triggerMovieResumeFromPage() {
        guard let targetURL = movieResumePromptTargetURL else { return }
        let resumeFromSavedPosition = (selectedThirdIndex == 0)
        let startSeconds = resumeFromSavedPosition ? movieResumePromptResumeSeconds : 0

        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            movieResumeBackdropOpacity = 0
            _ = incrementRequestID(&movieResumePromptBackdropRequestID)
            let returnMode = movieResumeReturnThirdMenuMode
            thirdMenuMode = returnMode == .none ? .moviesFolder : returnMode
            if !isInThirdMenu { isInThirdMenu = true }
            headerText = movieResumeReturnHeaderText
            movieResumePromptTargetURL = nil
            movieResumePromptResumeSeconds = 0
            movieResumePromptBackdropImage = nil
        }

        clearMoviePlaybackControlState()
        isCurrentMoviePlaybackEphemeralPreview = false
        removeCurrentMoviePlaybackTemporaryFileIfNeeded()
        isMovieTransitioning = true

        withAnimation(.easeInOut(duration: movieEntryFadeDuration)) {
            movieTransitionOverlayOpacity = 1
            menuSceneOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + movieEntryFadeDuration + movieEntryBlackHoldDuration) {
            self.activateMoviePlayback(
                from: targetURL,
                startSeconds: startSeconds,
                showsPlayGlyphOnStart: startSeconds > 0.01,
            )
            var instant = Transaction()
            instant.animation = nil
            withTransaction(instant) {
                self.movieTransitionOverlayOpacity = 0
            }
            self.isMovieTransitioning = false
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
        } else {
            lastClosedMovieURL = nil
            lastClosedMovieTimestamp = 0
        }
    }

    func stopMoviePlaybackAndReturnToMenu(captureResumePosition: Bool = true) {
        guard !isMovieTransitioning, isMoviePlaybackVisible else { return }
        isMovieTransitioning = true
        stopMovieScrubbing(revertToPause: false, scheduleAutoHide: false)
        clearMovieControlsVisibilityInstantly()
        moviePlayer?.pause()
        let shouldCaptureResumePosition = captureResumePosition && !isCurrentMoviePlaybackEphemeralPreview
        if shouldCaptureResumePosition {
            captureLastClosedMoviePlaybackPosition()
        } else {
            lastClosedMovieURL = nil
            lastClosedMovieTimestamp = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + movieExitFreezeHoldDuration) {
            withAnimation(.easeInOut(duration: movieExitFadeDuration)) {
                movieTransitionOverlayOpacity = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + movieExitFadeDuration) {
                removeMoviePlaybackObservation()
                moviePlayer = nil
                isMoviePlaybackVisible = false
                clearMoviePlaybackControlState()
                isCurrentMoviePlaybackEphemeralPreview = false
                removeCurrentMoviePlaybackTemporaryFileIfNeeded()
                withAnimation(.easeInOut(duration: 0.24)) {
                    menuSceneOpacity = 1
                    movieTransitionOverlayOpacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                    isMovieTransitioning = false
                }
            }
        }
    }

    func handleMoviePlaybackInput(_ key: KeyCode, isRepeat: Bool) {
        switch key {
        case .delete:
            playSound(named: "Exit")
            stopMoviePlaybackAndReturnToMenu()
        case .space:
            handleMovieSpacebarPressed()
        case .leftArrow:
            beginMovieScrubbing(direction: -1, isRepeat: isRepeat)
        case .rightArrow:
            beginMovieScrubbing(direction: 1, isRepeat: isRepeat)
        default:
            break
        }
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
        hideMovieControlsWithFade()
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
            handleMovieScrubTick()
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
        if now.timeIntervalSince(lastInput) > movieScrubReleaseGracePeriod {
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
        guard areMovieControlsVisible else { return }
        withAnimation(.easeOut(duration: movieControlsFadeDuration)) {
            movieControlsOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + movieControlsFadeDuration) {
            guard movieControlsOpacity <= 0.001 else { return }
            areMovieControlsVisible = false
        }
    }

    func scheduleMovieControlsAutoHide() {
        cancelMovieControlsAutoHide()
        let workItem = DispatchWorkItem {
            hideMovieControlsWithFade()
        }
        movieControlsHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + movieControlsAutoHideDelay, execute: workItem)
    }

    func cancelMovieControlsAutoHide() {
        movieControlsHideWorkItem?.cancel()
        movieControlsHideWorkItem = nil
    }

    func configureMoviePlaybackObservation(for player: AVPlayer) {
        removeMoviePlaybackObservation()
        observedMoviePlayer = player
        moviePlaybackCurrentSeconds = max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
        moviePlaybackDurationSeconds = resolvedMovieDurationSeconds(for: player)
        if let currentItem = player.currentItem {
            moviePlaybackDidEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main,
            ) { _ in
                guard self.observedMoviePlayer === player else { return }
                guard self.isMoviePlaybackVisible else { return }
                guard !self.isMovieTransitioning else { return }
                let resolvedDuration = self.resolvedMovieDurationSeconds(for: player)
                self.moviePlaybackDurationSeconds = max(self.moviePlaybackDurationSeconds, resolvedDuration)
                self.moviePlaybackCurrentSeconds = self.moviePlaybackDurationSeconds
                self.stopMoviePlaybackAndReturnToMenu(captureResumePosition: false)
            }
        }
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        movieTimeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let currentSeconds = max(0, time.seconds.isFinite ? time.seconds : 0)
            if movieScrubDirection == 0 {
                moviePlaybackCurrentSeconds = currentSeconds
            }
            let durationSeconds = resolvedMovieDurationSeconds(for: player)
            if durationSeconds > 0 {
                moviePlaybackDurationSeconds = durationSeconds
                if pendingMovieControlsRevealOnDurationReady {
                    pendingMovieControlsRevealOnDurationReady = false
                    showMovieControlsInstantly()
                    scheduleMovieControlsAutoHide()
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
