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
        DispatchQueue.main.asyncAfter(deadline: .now() + spinnerRevealDelay) {
            guard self.theatricalTrailersLoadingRequestID == requestID else { return }
            guard self.activeFullscreenScene?.key == self.theatricalTrailersLoadingFullscreenKey else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                self.theatricalTrailersLoadingShowsSpinner = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + errorTransitionDelay) {
            guard self.theatricalTrailersLoadingRequestID == requestID else { return }
            guard self.activeFullscreenScene?.key == self.theatricalTrailersLoadingFullscreenKey else { return }
            self.transitionActiveFullscreenSceneWithOverlay(
                to: self.featureErrorFullscreenKey,
                payload: [
                    "header": "An error occurred.",
                    "subcaption": "",
                ],
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
        DispatchQueue.main.asyncAfter(deadline: .now() + swapDelay) {
            guard self.isFullscreenSceneTransitioning else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                self.fullscreenTransitionOverlayOpacity = 1
            }
            DispatchQueue.main.async {
                guard self.isFullscreenSceneTransitioning else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    self.activeFullscreenScene = FullscreenScenePresentation(key: key, payload: payload)
                    self.fullscreenSceneOpacity = 1
                }
                withAnimation(.easeInOut(duration: fadeDuration)) {
                    self.fullscreenTransitionOverlayOpacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration) {
                    self.isFullscreenSceneTransitioning = false
                }
            }
        }
    }

    func presentFullscreenScene(
        key: String,
        payload: [String: String] = [:],
        revealDelay: Double = 0,
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
        let isScreenSaverTransition = key == screenSaverFullscreenKey
        let fadeOutDuration = isScreenSaverTransition ? 1 : 0.28
        let fadeInDuration = isScreenSaverTransition ? 1 : 0.24
        let useOverlayForMenuFade =
            key == screenSaverFullscreenKey ||
            (key == musicNowPlayingFullscreenKey &&
                activeRootItemID == "music" &&
                isInSubmenu &&
                !isInThirdMenu &&
                (shouldShowMusicTopLevelCarouselContent ||
                    shouldShowITunesTopSongsCarouselContent ||
                    shouldShowITunesTopMusicVideosCarouselContent))
        let shouldRevealDeferredNowPlaying =
            key == musicNowPlayingFullscreenKey && deferNowPlayingMenuItemUntilAfterFadeOut
        if useOverlayForMenuFade {
            withAnimation(.easeInOut(duration: fadeOutDuration)) {
                fullscreenTransitionOverlayOpacity = 1
            }
            let totalRevealDelay = fadeOutDuration + max(0, revealDelay)
            let swapDelay = totalRevealDelay + fullscreenOverlayBlackoutSafetyDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutDuration) {
                if shouldRevealDeferredNowPlaying {
                    revealDeferredNowPlayingMenuItemIfNeeded(compensateSelection: true)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + swapDelay) {
                guard self.isFullscreenSceneTransitioning else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    self.fullscreenTransitionOverlayOpacity = 1
                }
                DispatchQueue.main.async {
                    guard self.isFullscreenSceneTransitioning else { return }
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        self.menuSceneOpacity = 0
                        self.fullscreenSceneOpacity = 1
                    }
                    withAnimation(.easeInOut(duration: fadeInDuration)) {
                        self.fullscreenTransitionOverlayOpacity = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + fadeInDuration) {
                        self.isFullscreenSceneTransitioning = false
                    }
                }
            }
            return
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            menuSceneOpacity = 0
        }
        let totalRevealDelay = fadeOutDuration + max(0, revealDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutDuration) {
            if shouldRevealDeferredNowPlaying {
                revealDeferredNowPlayingMenuItemIfNeeded(compensateSelection: true)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + totalRevealDelay) {
            withAnimation(.easeInOut(duration: fadeInDuration)) {
                fullscreenSceneOpacity = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeInDuration) {
                if key == musicNowPlayingFullscreenKey {
                    updateMusicNowPlayingFlipTimerState()
                }
                isFullscreenSceneTransitioning = false
            }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + sceneSwapDelay) {
                guard self.isFullscreenSceneTransitioning else { return }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    self.fullscreenTransitionOverlayOpacity = 1
                    self.activeFullscreenScene = nil
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) {
                    guard self.isFullscreenSceneTransitioning else { return }
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        self.menuSceneOpacity = 1
                    }
                    withAnimation(.easeInOut(duration: fadeInDuration)) {
                        self.fullscreenTransitionOverlayOpacity = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + fadeInDuration) {
                        self.isFullscreenSceneTransitioning = false
                    }
                }
            }
            return
        }
        withAnimation(.easeInOut(duration: fadeOutDuration)) {
            fullscreenSceneOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutDuration) {
            activeFullscreenScene = nil
            if dismissedKey == musicNowPlayingFullscreenKey {
                updateMusicNowPlayingFlipTimerState()
            }
            if dismissedKey == musicNowPlayingFullscreenKey, !shouldPreserveMusicPlayback {
                clearMusicNowPlayingDisplayState()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) {
                withAnimation(.easeInOut(duration: fadeInDuration)) {
                    menuSceneOpacity = 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + fadeInDuration) {
                    isFullscreenSceneTransitioning = false
                }
            }
        }
    }
}

extension MenuView {
    var itunesIconImage: NSImage? {
        NSImage(named: "itunes")
    }

    var fullscreenSceneBuilders: [String: FullscreenSceneBuilder] {
        [
            musicNowPlayingFullscreenKey: { _ in
                AnyView(
                    musicNowPlayingSceneView(),
                )
            },
            screenSaverFullscreenKey: { _ in
                AnyView(
                    ScreenSaverFullscreenView(
                        onDismiss: {
                            dismissScreenSaverForUserInteraction()
                        },
                    ),
                )
            },
            featureErrorFullscreenKey: { scene in
                AnyView(
                    FeatureErrorFullscreenView(
                        headerText: scene.payload["header"] ?? "First Row cannot complete this request.",
                        subcaptionText: scene.payload["subcaption"] ?? "",
                    ),
                )
            },
            theatricalTrailersLoadingFullscreenKey: { scene in
                AnyView(
                    FeatureLoadingFullscreenView(
                        headerText: scene.payload["header"] ?? "Loading Theatrical Trailers...",
                        showsSpinner: theatricalTrailersLoadingShowsSpinner,
                    ),
                )
            },
            photoSlideshowFullscreenKey: { _ in
                AnyView(
                    PhotoSlideshowFullscreenView(
                        imageCount: photoSlideshowAssetLocalIdentifiers.count,
                        imageForIndex: { index in
                            photoSlideshowImageCache[index]
                        },
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
                        onFinished: {
                            handlePhotoSlideshowPlaybackFinished()
                        },
                    ),
                )
            },
        ]
    }
}
