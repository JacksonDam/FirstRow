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
        isFullscreenSceneTransitioning = true
        activeFullscreenScene = FullscreenScenePresentation(key: key, payload: payload)
        fullscreenSceneOpacity = 0
        fullscreenTransitionOverlayOpacity = 0
        let fadeOutDuration = 0.28
        let fadeInDuration = 0.24
        if usingExistingBlackout {
            isMenuFolderSwapTransitioning = false
            let totalRevealDelay = max(0, revealDelay)
            DispatchQueue.main.asyncAfter(deadline: .now() + totalRevealDelay) {
                guard self.isFullscreenSceneTransitioning else { return }
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
                    self.isFullscreenSceneTransitioning = false
                }
            }
            return
        }
        withAnimation(.easeInOut(duration: 0.28)) {
            menuSceneOpacity = 0
        }
        let totalRevealDelay = fadeOutDuration + max(0, revealDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + totalRevealDelay) {
            withAnimation(.easeInOut(duration: fadeInDuration)) {
                fullscreenSceneOpacity = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeInDuration) {
                isFullscreenSceneTransitioning = false
            }
        }
    }

    func dismissFullscreenScene() {
        guard activeFullscreenScene != nil else { return }
        guard !isFullscreenSceneTransitioning else { return }
        isFullscreenSceneTransitioning = true
        let fadeOutDuration = 0.28
        let holdDuration: Double = 1.0
        let fadeInDuration = 0.24
        withAnimation(.easeInOut(duration: fadeOutDuration)) {
            fullscreenSceneOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutDuration) {
            activeFullscreenScene = nil
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
