import SwiftUI

extension MenuView {
    func presentTheatricalTrailersLoadingThenError() {
        guard activeFullscreenScene == nil else { return }
        guard !isMovieTransitioning, !isMoviePlaybackVisible else { return }
        guard !isFullscreenSceneTransitioning else { return }
        let requestID = incrementRequestID(&theatricalTrailersLoadingRequestID)
        theatricalTrailersLoadingShowsSpinner = false
        let fadeOutDuration = 0.28
        let fadeInDuration = 0.24
        let spinnerRevealDelay = fadeOutDuration + fadeInDuration
        let errorTransitionDelay = spinnerRevealDelay + 0.5
        presentFullscreenScene(
            key: theatricalTrailersLoadingFullscreenKey,
            payload: ["header": "Loading Theatrical Trailers..."],
        )
        Task {
            try? await firstRowSleep(spinnerRevealDelay)
            guard !Task.isCancelled else { return }
            guard self.theatricalTrailersLoadingRequestID == requestID else { return }
            guard self.activeFullscreenScene?.key == self.theatricalTrailersLoadingFullscreenKey else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                self.theatricalTrailersLoadingShowsSpinner = true
            }
        }
        Task {
            try? await firstRowSleep(errorTransitionDelay)
            guard !Task.isCancelled else { return }
            guard self.theatricalTrailersLoadingRequestID == requestID else { return }
            guard self.activeFullscreenScene?.key == self.theatricalTrailersLoadingFullscreenKey else { return }
            self.transitionActiveFullscreenSceneWithOverlay(
                to: self.featureErrorFullscreenKey,
                payload: FeatureErrorKind.genericOperationFailed.payload,
            )
        }
    }

    func transitionActiveFullscreenSceneWithOverlay(
        to key: String,
        payload: [String: String] = [:],
        fadeDuration: Double = 0.28,
    ) {
        guard activeFullscreenScene != nil else { return }
        guard !isFullscreenSceneTransitioning else { return }
        isFullscreenSceneTransitioning = true
        withAnimation(.easeInOut(duration: fadeDuration)) {
            fullscreenTransitionOverlayOpacity = 1
        }
        let swapDelay = fadeDuration + fullscreenOverlayBlackoutSafetyDuration
        Task {
            try? await firstRowSleep(swapDelay)
            guard !Task.isCancelled else { return }
            guard self.isFullscreenSceneTransitioning else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                self.fullscreenTransitionOverlayOpacity = 1
            }
            guard self.isFullscreenSceneTransitioning else { return }
            withTransaction(instant) {
                self.activeFullscreenScene = FullscreenScenePresentation(key: key, payload: payload)
                self.fullscreenSceneOpacity = 1
            }
            withAnimation(.easeInOut(duration: fadeDuration)) {
                self.fullscreenTransitionOverlayOpacity = 0
            }
            try? await firstRowSleep(fadeDuration)
            guard !Task.isCancelled else { return }
            self.isFullscreenSceneTransitioning = false
        }
    }

    func presentFullscreenScene(
        key: String,
        payload: [String: String] = [:],
        revealDelay: Double = 0,
        usingExistingBlackout: Bool = false,
    ) {
        guard activeFullscreenScene == nil else { return }
        guard !isMovieTransitioning, !isMoviePlaybackVisible else { return }
        if key == musicNowPlayingFullscreenKey {
            clearMusicSongSwitchTransitionState()
        }
        if key == screenSaverFullscreenKey {
            clearScreenSaverNowPlayingToast()
        }
        isFullscreenSceneTransitioning = true
        activeFullscreenScene = FullscreenScenePresentation(key: key, payload: payload)
        fullscreenSceneOpacity = 0
        fullscreenTransitionOverlayOpacity = 0
        let shouldRevealDeferredNowPlaying =
            key == musicNowPlayingFullscreenKey && deferNowPlayingMenuItemUntilAfterFadeOut
        let isScreenSaverTransition = key == screenSaverFullscreenKey
        let fadeOutDuration = isScreenSaverTransition ? 1 : 0.28
        let fadeInDuration = isScreenSaverTransition ? 1 : 0.24
        if usingExistingBlackout {
            isMenuFolderSwapTransitioning = false
            let totalRevealDelay = max(0, revealDelay)
            Task {
                try? await firstRowSleep(totalRevealDelay)
                guard !Task.isCancelled else { return }
                guard self.isFullscreenSceneTransitioning else { return }
                if shouldRevealDeferredNowPlaying {
                    self.revealDeferredNowPlayingMenuItemIfNeeded(compensateSelection: true)
                }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    self.menuSceneOpacity = 0
                }
                withAnimation(.easeInOut(duration: fadeInDuration)) {
                    self.menuFolderSwapOverlayOpacity = 0
                    self.fullscreenSceneOpacity = 1
                }
                try? await firstRowSleep(fadeInDuration)
                guard !Task.isCancelled else { return }
                if key == musicNowPlayingFullscreenKey {
                    self.updateMusicNowPlayingFlipTimerState()
                }
                self.isFullscreenSceneTransitioning = false
            }
            return
        }
        let useOverlayForMenuFade =
            key == screenSaverFullscreenKey ||
            (key == musicNowPlayingFullscreenKey &&
                activeRootItemID == "music" &&
                isInSubmenu &&
                !isInThirdMenu &&
                (shouldShowMusicTopLevelCarouselContent ||
                    shouldShowITunesTopSongsCarouselContent ||
                    shouldShowITunesTopMusicVideosCarouselContent))
        if useOverlayForMenuFade {
            withAnimation(.easeInOut(duration: fadeOutDuration)) {
                fullscreenTransitionOverlayOpacity = 1
            }
            let totalRevealDelay = fadeOutDuration + max(0, revealDelay)
            let swapDelay = totalRevealDelay + fullscreenOverlayBlackoutSafetyDuration
            Task {
                try? await firstRowSleep(fadeOutDuration)
                guard !Task.isCancelled else { return }
                if shouldRevealDeferredNowPlaying {
                    revealDeferredNowPlayingMenuItemIfNeeded(compensateSelection: true)
                }
            }
            Task {
                try? await firstRowSleep(swapDelay)
                guard !Task.isCancelled else { return }
                guard self.isFullscreenSceneTransitioning else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    self.fullscreenTransitionOverlayOpacity = 1
                }
                guard self.isFullscreenSceneTransitioning else { return }
                withTransaction(instant) {
                    self.menuSceneOpacity = 0
                    self.fullscreenSceneOpacity = 1
                }
                withAnimation(.easeInOut(duration: fadeInDuration)) {
                    self.fullscreenTransitionOverlayOpacity = 0
                }
                try? await firstRowSleep(fadeInDuration)
                guard !Task.isCancelled else { return }
                self.isFullscreenSceneTransitioning = false
            }
            return
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            menuSceneOpacity = 0
        }
        let totalRevealDelay = fadeOutDuration + max(0, revealDelay)
        Task {
            try? await firstRowSleep(fadeOutDuration)
            guard !Task.isCancelled else { return }
            if shouldRevealDeferredNowPlaying {
                revealDeferredNowPlayingMenuItemIfNeeded(compensateSelection: true)
            }
        }
        Task {
            try? await firstRowSleep(totalRevealDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: fadeInDuration)) {
                fullscreenSceneOpacity = 1
            }
            try? await firstRowSleep(fadeInDuration)
            guard !Task.isCancelled else { return }
            if key == musicNowPlayingFullscreenKey {
                updateMusicNowPlayingFlipTimerState()
            }
            isFullscreenSceneTransitioning = false
        }
    }

    func dismissFullscreenScene(preserveMusicPlayback: Bool = false) {
        guard activeFullscreenScene != nil else { return }
        guard !isFullscreenSceneTransitioning else { return }
        let dismissedKey = activeFullscreenScene?.key
        if dismissedKey == screenSaverFullscreenKey {
            clearScreenSaverNowPlayingToast()
        }
        let shouldPreserveMusicPlayback = preserveMusicPlayback && dismissedKey == musicNowPlayingFullscreenKey
        if dismissedKey == musicNowPlayingFullscreenKey {
            clearMusicSongSwitchTransitionState()
        }
        if dismissedKey == theatricalTrailersLoadingFullscreenKey {
            theatricalTrailersLoadingShowsSpinner = false
            _ = incrementRequestID(&theatricalTrailersLoadingRequestID)
        }
        if dismissedKey == musicNowPlayingFullscreenKey, !shouldPreserveMusicPlayback {
            stopMusicPlaybackSession(clearDisplayState: false)
        }
        isFullscreenSceneTransitioning = true
        let isScreenSaverTransition = dismissedKey == screenSaverFullscreenKey
        let fadeOutDuration = isScreenSaverTransition ? 1.0 : 0.28
        let holdDuration: Double =
            (isScreenSaverTransition ||
                dismissedKey == featureErrorFullscreenKey ||
                dismissedKey == theatricalTrailersLoadingFullscreenKey) ? 0 : 1.0
        let fadeInDuration = isScreenSaverTransition ? 1.0 : 0.24
        let useOverlayForMenuFade =
            dismissedKey == screenSaverFullscreenKey ||
            (dismissedKey == musicNowPlayingFullscreenKey &&
                activeRootItemID == "music" &&
                isInSubmenu &&
                !isInThirdMenu &&
                (shouldShowMusicTopLevelCarouselContent ||
                    shouldShowITunesTopSongsCarouselContent ||
                    shouldShowITunesTopMusicVideosCarouselContent))
        if useOverlayForMenuFade {
            withAnimation(.easeInOut(duration: fadeOutDuration)) {
                fullscreenTransitionOverlayOpacity = 1
            }
            let sceneSwapDelay = fadeOutDuration + fullscreenOverlayBlackoutSafetyDuration
            Task {
                try? await firstRowSleep(sceneSwapDelay)
                guard !Task.isCancelled else { return }
                guard self.isFullscreenSceneTransitioning else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    self.fullscreenTransitionOverlayOpacity = 1
                    self.activeFullscreenScene = nil
                }
                try? await firstRowSleep(holdDuration)
                guard !Task.isCancelled else { return }
                guard self.isFullscreenSceneTransitioning else { return }
                withTransaction(instant) {
                    self.menuSceneOpacity = 1
                }
                withAnimation(.easeInOut(duration: fadeInDuration)) {
                    self.fullscreenTransitionOverlayOpacity = 0
                }
                try? await firstRowSleep(fadeInDuration)
                guard !Task.isCancelled else { return }
                self.isFullscreenSceneTransitioning = false
            }
            return
        }
        withAnimation(.easeInOut(duration: fadeOutDuration)) {
            fullscreenSceneOpacity = 0
        }
        Task {
            try? await firstRowSleep(fadeOutDuration)
            guard !Task.isCancelled else { return }
            activeFullscreenScene = nil
            if dismissedKey == musicNowPlayingFullscreenKey {
                updateMusicNowPlayingFlipTimerState()
            }
            if dismissedKey == musicNowPlayingFullscreenKey, !shouldPreserveMusicPlayback {
                clearMusicNowPlayingDisplayState()
            }
            try? await firstRowSleep(holdDuration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: fadeInDuration)) {
                menuSceneOpacity = 1
            }
            try? await firstRowSleep(fadeInDuration)
            guard !Task.isCancelled else { return }
            isFullscreenSceneTransitioning = false
        }
    }
}

extension MenuView {
    var itunesIconImage: NSImage? {
        NSImage(named: "itunes")
    }

    @ViewBuilder
    func fullscreenSceneView(for scene: FullscreenScenePresentation) -> some View {
        switch scene.key {
        case musicNowPlayingFullscreenKey:
            musicNowPlayingSceneView()
        case screenSaverFullscreenKey:
            ScreenSaverFullscreenView(onDismiss: { dismissScreenSaverForUserInteraction() })
        case featureErrorFullscreenKey:
            let copy = FeatureErrorCopy.resolve(from: scene.payload)
            FeatureErrorFullscreenView(
                headerText: copy.headerText,
                subcaptionText: copy.subcaptionText,
            )
        case theatricalTrailersLoadingFullscreenKey:
            FeatureLoadingFullscreenView(
                headerText: scene.payload["header"] ?? "Loading Theatrical Trailers...",
                showsSpinner: theatricalTrailersLoadingShowsSpinner,
            )
        case photoSlideshowFullscreenKey:
            PhotoSlideshowFullscreenView(
                imageCount: photoSlideshowAssetLocalIdentifiers.count,
                imageForIndex: { index in photoSlideshowImageCache[index] },
                isPaused: photoSlideshowIsPaused,
                pausedIndex: photoSlideshowPausedIndex,
                playbackStartDate: photoSlideshowPlaybackStartDate,
                playbackElapsedOffset: photoSlideshowPlaybackElapsedOffset,
                displayDuration: photoSlideshowPhotoDisplayDuration,
                crossfadeDuration: photoSlideshowCrossfadeDuration,
                hasAlreadyFinished: photoSlideshowHasFinished,
                onFrameIndicesChanged: { primaryIndex, secondaryIndex in
                    updatePhotoSlideshowVisibleIndices(
                        primaryIndex: primaryIndex,
                        secondaryIndex: secondaryIndex,
                    )
                },
                onFinished: { handlePhotoSlideshowPlaybackFinished() },
            )
        default:
            Color.black
        }
    }
}
