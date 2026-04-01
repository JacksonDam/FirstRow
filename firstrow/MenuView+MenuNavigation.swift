import SwiftUI

extension MenuView {
    enum ThirdMenuMode {
        case none
        case moviesFolder
        case moviesITunesTop
        case tvEpisodesITunesTop
        case videoPodcastSeries
        case videoPodcastEpisodes
        case musicITunesTopSongs
        case musicITunesTopMusicVideos
        case audioPodcastSeries
        case audioPodcastEpisodes
        case musicCategories
        case musicSongs
        case musicNowPlaying
        case photosDateAlbums
        case errorPage
        case movieResumePrompt
    }

}

extension MenuView {
    func enterErrorPage(header: String, subcaption: String) {
        guard !isEnteringSubmenu, !isReturningToRoot else { return }

        let returnMode = isInThirdMenu ? thirdMenuMode : .none
        let returnHeader = headerText

        let snapshot = currentMenuTransitionSnapshot()
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            errorPageHeaderText = header
            errorPageSubcaptionText = subcaption
            menuTransitionSnapshot = snapshot
            menuTransitionDirection = .forward
            menuTransitionProgress = 0
            musicNowPlayingReturnThirdMenuMode = returnMode
            musicNowPlayingReturnHeaderText = returnHeader
            isInThirdMenu = true
            thirdMenuMode = .errorPage
        }

        withAnimation(.easeInOut(duration: menuSlideDuration)) {
            menuTransitionProgress = 1
        }

        Task { @MainActor in
            try? await firstRowSleep(menuSlideDuration)
            guard !Task.isCancelled else { return }
            self.menuTransitionSnapshot = nil
        }
    }

    func exitErrorPage() {
        guard thirdMenuMode == .errorPage else { return }

        let returnMode = musicNowPlayingReturnThirdMenuMode
        let returnHeader = musicNowPlayingReturnHeaderText

        transitionMenuForFolderSwap(direction: .backward) {
            if returnMode == .none {
                isInThirdMenu = false
                thirdMenuMode = .none
            } else {
                thirdMenuMode = returnMode
            }
            headerText = returnHeader
        }
    }

    func exitMovieResumePromptPage() {
        guard thirdMenuMode == .movieResumePrompt else { return }

        transitionMenuForFolderSwap(direction: .backward) {
            dismissMovieResumePrompt()
            restoreMovieResumePromptReturnContext()
        }
    }

    func returnToRootMenuViaBlackFade() {
        guard isInSubmenu || isEnteringSubmenu else { return }
        transitionMenuForFolderSwap(
            useOverlayFade: true,
            revealWhen: { !isInSubmenu && activeRootItemID == nil },
        ) {
            returnToRootMenu(playExitSound: false)
        }
    }

    func refreshDetailPreviewForCurrentContext() {
        switch activeRootItemID {
        case "movies":
            refreshMoviePreviewForCurrentContext()
            refreshPodcastsForCurrentContext()
            refreshITunesTopPreviewForCurrentContext(.movies)
            refreshITunesTopCarouselForCurrentContext(.movies)
            refreshITunesTopPreviewForCurrentContext(.tvEpisodes)
            refreshITunesTopCarouselForCurrentContext(.tvEpisodes)
            refreshITunesTopPreviewForCurrentContext(.musicVideos)
            refreshITunesTopCarouselForCurrentContext(.musicVideos)
        case "music":
            refreshPodcastsForCurrentContext()
            refreshMusicPreviewForCurrentContext()
            refreshMusicTopLevelCarouselForCurrentContext()
            refreshITunesTopPreviewForCurrentContext(.songs)
            refreshITunesTopCarouselForCurrentContext(.songs)
        case "photos":
            refreshPhotosForCurrentContext()
        default:
            break
        }
    }

    func exitThirdMenuToSecondLevel() {
        let isExitingMusicThirdMenu = switch thirdMenuMode {
        case .musicSongs, .musicCategories, .musicITunesTopSongs, .musicITunesTopMusicVideos:
            true
        case .moviesFolder, .moviesITunesTop, .tvEpisodesITunesTop, .videoPodcastSeries, .videoPodcastEpisodes, .audioPodcastSeries, .audioPodcastEpisodes, .photosDateAlbums, .musicNowPlaying, .errorPage, .movieResumePrompt, .none:
            false
        }
        transitionMenuForFolderSwap(direction: .backward) {
            if isExitingMusicThirdMenu {
                isMusicSongsShuffleMode = false
                isMusicSongsCategoryScoped = false
                activeMusicCategoryKind = nil
                activeMusicCategoryMenuTitle = ""
                lastSelectedMusicCategoryIndex = 0
                activeMusicLibraryMediaType = .songs
                musicSongsShowsShuffleAction = false
                musicCategoryThirdMenuItems = []
            }
            headerText = rootMenuTitle(for: activeRootItemID)
            isInThirdMenu = false
            thirdMenuMode = .none
            thirdMenuOpacity = 0
            submenuOpacity = 1
            refreshDetailPreviewForCurrentContext()
        }
    }

    func exitMoviesThirdMenuToSecondLevelWithSwap(useOverlayFade: Bool = false) {
        transitionMenuForFolderSwap(useOverlayFade: useOverlayFade, direction: .backward) {
            stopMoviesFolderGapPlayer()
            isInThirdMenu = false
            thirdMenuMode = .none
            thirdMenuOpacity = 0
            submenuOpacity = 1
            headerText = rootMenuTitle(for: activeRootItemID)
            resetThirdMenuDirectoryState()
            moviesFolderSelectionIndexByDirectoryPath = [:]
            resetITunesTopCarouselAndPreviewState(for: [.movies, .tvEpisodes])
            _ = incrementRequestID(&moviePlaybackLoadingRequestID)
            isMoviePlaybackLoading = false
            refreshDetailPreviewForCurrentContext()
        }
    }

    func exitPhotosThirdMenuToSecondLevelWithSwap(useOverlayFade: Bool = false) {
        transitionMenuForFolderSwap(useOverlayFade: useOverlayFade, direction: .backward) {
            isInThirdMenu = false
            thirdMenuMode = .none
            thirdMenuOpacity = 0
            submenuOpacity = 1
            headerText = rootMenuTitle(for: activeRootItemID)
            refreshDetailPreviewForCurrentContext()
        }
    }

    func navigateUpInThirdMenuOrExit() {
        guard menuTransitionSnapshot == nil else { return }
        if thirdMenuMode == .musicSongs, isMusicSongsCategoryScoped {
            playSound(named: "Exit")
            transitionMenuForFolderSwap(direction: .backward) {
                thirdMenuMode = .musicCategories
                isMusicSongsCategoryScoped = false
                isLoadingMusicSongs = false
                musicSongsLoadError = nil
                headerText = activeMusicCategoryMenuTitle.isEmpty
                    ? rootMenuTitle(for: activeRootItemID)
                    : activeMusicCategoryMenuTitle
                selectedThirdIndex = min(
                    lastSelectedMusicCategoryIndex,
                    max(0, musicCategoryThirdMenuItems.count - 1),
                )
                refreshDetailPreviewForCurrentContext()
                submenuOpacity = 0
                thirdMenuOpacity = 1
            }
            return
        }

        switch thirdMenuMode {
        case .musicITunesTopSongs, .musicITunesTopMusicVideos, .musicSongs, .musicCategories:
            playSound(named: "Exit")
            exitMusicThirdMenuToSecondLevelWithSwap()
        case .musicNowPlaying:
            playSound(named: "Exit")
            exitMusicNowPlayingPage()
        case .movieResumePrompt:
            playSound(named: "Exit")
            exitMovieResumePromptPage()
        case .moviesITunesTop, .tvEpisodesITunesTop:
            playSound(named: "Exit")
            exitMoviesThirdMenuToSecondLevelWithSwap()
        case .videoPodcastEpisodes:
            playSound(named: "Exit")
            exitPodcastEpisodesMenuToSeriesMenu(kind: .video)
        case .audioPodcastEpisodes:
            playSound(named: "Exit")
            exitPodcastEpisodesMenuToSeriesMenu(kind: .audio)
        case .videoPodcastSeries, .audioPodcastSeries:
            playSound(named: "Exit")
            exitPodcastSeriesMenuToSecondLevelWithSwap()
        case .photosDateAlbums:
            playSound(named: "Exit")
            exitPhotosThirdMenuToSecondLevelWithSwap(useOverlayFade: true)
        case .moviesFolder:
            guard let currentURL = thirdMenuCurrentURL else {
                exitMoviesThirdMenuToSecondLevelWithSwap()
                return
            }
            playSound(named: "Exit")
            let standardizedCurrent = currentURL.standardizedFileURL
            let standardizedRoot = thirdMenuRootURL?.standardizedFileURL
            if let standardizedRoot, standardizedCurrent != standardizedRoot {
                let parentURL = standardizedCurrent.deletingLastPathComponent()
                rememberCurrentMoviesFolderSelectionIndex()
                transitionMenuForFolderSwap {
                    loadThirdMenuDirectory(parentURL, resetSelection: true)
                }
            } else if !movieLibraryRootURLs.isEmpty {
                rememberCurrentMoviesFolderSelectionIndex()
                #if os(macOS)
                    transitionMenuForFolderSwap {
                        loadMoviesRootSelectorEntries(resetSelection: false)
                    }
                #else
                    exitMoviesThirdMenuToSecondLevelWithSwap()
                #endif
            } else {
                rememberCurrentMoviesFolderSelectionIndex()
                exitMoviesThirdMenuToSecondLevelWithSwap()
            }
        default:
            playSound(named: "Exit")
            exitThirdMenuToSecondLevel()
        }
    }

    func transitionMenuForFolderSwap(
        useOverlayFade: Bool = false,
        direction: MenuTransitionDirection = .forward,
        revealWhen: @escaping () -> Bool = { true },
        maxRevealWait: TimeInterval = 10.0,
        _ update: @escaping () -> Void,
    ) {
        guard !isMenuFolderSwapTransitioning else { return }
        guard !isFullscreenSceneTransitioning else { return }
        guard !isMovieTransitioning else { return }
        isMenuFolderSwapTransitioning = true
        if !useOverlayFade {
            menuTransitionDirection = direction
            menuTransitionSnapshot = currentMenuTransitionSnapshot()
            menuTransitionProgress = menuTransitionSnapshot == nil ? 1 : 0
            var instant = Transaction()
            instant.animation = nil
            withTransaction(instant) {
                update()
            }
            let revealDeadline = Date().addingTimeInterval(max(0, maxRevealWait))
            Task { @MainActor in
                await Task.yield()
                try? await firstRowSleep(0.02)
                guard !Task.isCancelled else { return }
                while isMenuFolderSwapTransitioning {
                    let canRevealNow = revealWhen() || Date() >= revealDeadline
                    guard canRevealNow else {
                        try? await firstRowSleep(0.05)
                        continue
                    }
                    guard menuTransitionSnapshot != nil else {
                        menuTransitionProgress = 1
                        isMenuFolderSwapTransitioning = false
                        return
                    }
                    withAnimation(.easeInOut(duration: menuSlideDuration)) {
                        menuTransitionProgress = 1
                    }
                    try? await firstRowSleep(menuSlideDuration)
                    guard !Task.isCancelled else { return }
                    menuTransitionSnapshot = nil
                    isMenuFolderSwapTransitioning = false
                    return
                }
            }
            return
        }
        if useOverlayFade {
            menuSceneOpacity = 1
            withAnimation(.easeInOut(duration: menuFolderSwapFadeDuration)) {
                menuFolderSwapOverlayOpacity = 1
            }
        } else {
            menuFolderSwapOverlayOpacity = 0
            withAnimation(.easeInOut(duration: menuFolderSwapFadeDuration)) {
                menuSceneOpacity = 0
            }
        }
        let swapUpdateDelay = menuFolderSwapFadeDuration + menuOverlayBlackoutSafetyDuration
        Task { @MainActor in
            try? await firstRowSleep(swapUpdateDelay)
            guard !Task.isCancelled else { return }
            guard isMenuFolderSwapTransitioning else { return }
            var instant = Transaction()
            instant.animation = nil
            withTransaction(instant) {
                if useOverlayFade {
                    menuFolderSwapOverlayOpacity = 1
                } else {
                    menuSceneOpacity = 0
                }
            }
            guard isMenuFolderSwapTransitioning else { return }
            withTransaction(instant) {
                update()
            }
            let revealDeadline = Date().addingTimeInterval(max(0, maxRevealWait))
            try? await firstRowSleep(menuFolderSwapHoldDuration)
            guard !Task.isCancelled else { return }
            while isMenuFolderSwapTransitioning {
                let canRevealNow = revealWhen() || Date() >= revealDeadline
                guard canRevealNow else {
                    try? await firstRowSleep(0.05)
                    continue
                }
                if useOverlayFade {
                    withAnimation(.easeInOut(duration: menuFolderSwapFadeDuration)) {
                        menuFolderSwapOverlayOpacity = 0
                    }
                } else {
                    withAnimation(.easeInOut(duration: menuFolderSwapFadeDuration)) {
                        menuSceneOpacity = 1
                    }
                }
                try? await firstRowSleep(menuFolderSwapFadeDuration)
                guard !Task.isCancelled else { return }
                isMenuFolderSwapTransitioning = false
                return
            }
        }
    }
}
