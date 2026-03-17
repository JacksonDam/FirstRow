import SwiftUI

extension MenuView {
    func presentTheatricalTrailersLoading() {
        guard !isTheatricalTrailersLoading else { return }
        let requestID = incrementRequestID(&theatricalTrailersLoadingRequestID)
        isTheatricalTrailersLoading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.theatricalTrailersLoadingRequestID == requestID else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                self.isTheatricalTrailersLoading = false
            }
            self.presentFeatureErrorScreen(.genericOperationFailed)
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
        isFullscreenSceneTransitioning = true
        activeFullscreenScene = FullscreenScenePresentation(key: key, payload: payload)
        fullscreenSceneOpacity = 0
        fullscreenTransitionOverlayOpacity = 0
        let shouldRevealDeferredNowPlaying =
            key == musicNowPlayingFullscreenKey && deferNowPlayingMenuItemUntilAfterFadeOut
        let fadeOutDuration = 0.28
        let fadeInDuration = 0.24
        if usingExistingBlackout {
            isMenuFolderSwapTransitioning = false
            let totalRevealDelay = max(0, revealDelay)
            DispatchQueue.main.asyncAfter(deadline: .now() + totalRevealDelay) {
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
                DispatchQueue.main.asyncAfter(deadline: .now() + fadeInDuration) {
                    if key == musicNowPlayingFullscreenKey {
                        self.updateMusicNowPlayingFlipTimerState()
                    }
                    self.isFullscreenSceneTransitioning = false
                }
            }
            return
        }
        let useOverlayForMenuFade =
            key == musicNowPlayingFullscreenKey &&
            activeRootItemID == "music" &&
            isInSubmenu &&
            !isInThirdMenu &&
            (shouldShowMusicTopLevelCarouselContent ||
                shouldShowITunesTopSongsCarouselContent ||
                shouldShowITunesTopMusicVideosCarouselContent)
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
        let shouldPreserveMusicPlayback = preserveMusicPlayback && dismissedKey == musicNowPlayingFullscreenKey
        if dismissedKey == musicNowPlayingFullscreenKey {
            clearMusicSongSwitchTransitionState()
        }
        if dismissedKey == musicNowPlayingFullscreenKey, !shouldPreserveMusicPlayback {
            stopMusicPlaybackSession(clearDisplayState: false)
        }
        isFullscreenSceneTransitioning = true
        let fadeOutDuration = 0.28
        let holdDuration: Double = 1.0
        let fadeInDuration = 0.24
        let useOverlayForMenuFade =
            dismissedKey == musicNowPlayingFullscreenKey &&
            activeRootItemID == "music" &&
            isInSubmenu &&
            !isInThirdMenu &&
            (shouldShowMusicTopLevelCarouselContent ||
                shouldShowITunesTopSongsCarouselContent ||
                shouldShowITunesTopMusicVideosCarouselContent)
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
