import SwiftUI

extension MenuView {
    enum ThirdMenuMode {
        case none
        case moviesFolder
        case moviesITunesTop
        case tvITunesTopEpisodes
        case musicITunesTopSongs
        case musicITunesTopMusicVideos
        case musicCategories
        case musicSongs
        case photosDateAlbums
        case podcastsEpisodes
    }
}

extension MenuView {
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
            refreshITunesTopPreviewForCurrentContext(.movies)
            refreshITunesTopCarouselForCurrentContext(.movies)
        case "tv_shows":
            refreshITunesTopPreviewForCurrentContext(.tvEpisodes)
            refreshITunesTopCarouselForCurrentContext(.tvEpisodes)
        case "music":
            refreshMusicPreviewForCurrentContext()
            refreshMusicTopLevelCarouselForCurrentContext()
            refreshITunesTopPreviewForCurrentContext(.songs)
            refreshITunesTopCarouselForCurrentContext(.songs)
            refreshITunesTopPreviewForCurrentContext(.musicVideos)
            refreshITunesTopCarouselForCurrentContext(.musicVideos)
        case "podcasts":
            refreshPodcastsForCurrentContext()
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
        case .moviesFolder, .moviesITunesTop, .tvITunesTopEpisodes, .photosDateAlbums, .podcastsEpisodes, .none:
            false
        }
        if isExitingMusicThirdMenu {
            isMusicSongsShuffleMode = false
            isMusicSongsCategoryScoped = false
            activeMusicCategoryKind = nil
            activeMusicCategoryMenuTitle = ""
            lastSelectedMusicCategoryIndex = 0
            activeMusicLibraryMediaType = .songs
            musicSongsShowsShuffleAction = false
            musicCategoryThirdMenuItems = []
            headerText = rootMenuTitle(for: activeRootItemID)
        } else {
            headerText = rootMenuTitle(for: activeRootItemID)
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            thirdMenuOpacity = 0
            submenuOpacity = 1
        }
        Task {
            try? await firstRowSleep(0.2)
            guard !Task.isCancelled else { return }
            isInThirdMenu = false
            thirdMenuMode = .none
            syncPodcastSubmenuSelectionForActiveSeries()
            refreshDetailPreviewForCurrentContext()
        }
    }

    func exitMoviesThirdMenuToSecondLevelWithSwap(useOverlayFade: Bool = false) {
        transitionMenuForFolderSwap(useOverlayFade: useOverlayFade) {
            isInThirdMenu = false
            thirdMenuMode = .none
            thirdMenuOpacity = 0
            submenuOpacity = 1
            headerText = rootMenuTitle(for: activeRootItemID)
            resetThirdMenuDirectoryState()
            moviesFolderSelectionIndexByDirectoryPath = [:]
            resetITunesTopCarouselAndPreviewState(for: [.movies, .tvEpisodes])
            refreshDetailPreviewForCurrentContext()
        }
    }

    func exitPodcastsThirdMenuToSecondLevelWithSwap(useOverlayFade: Bool = false) {
        transitionMenuForFolderSwap(useOverlayFade: useOverlayFade) {
            isInThirdMenu = false
            thirdMenuMode = .none
            thirdMenuOpacity = 0
            submenuOpacity = 1
            headerText = rootMenuTitle(for: activeRootItemID)
            syncPodcastSubmenuSelectionForActiveSeries()
            refreshDetailPreviewForCurrentContext()
        }
    }

    func exitPhotosThirdMenuToSecondLevelWithSwap(useOverlayFade: Bool = false) {
        transitionMenuForFolderSwap(useOverlayFade: useOverlayFade) {
            isInThirdMenu = false
            thirdMenuMode = .none
            thirdMenuOpacity = 0
            submenuOpacity = 1
            headerText = rootMenuTitle(for: activeRootItemID)
            refreshDetailPreviewForCurrentContext()
        }
    }

    func navigateUpInThirdMenuOrExit() {
        if thirdMenuMode == .musicSongs, isMusicSongsCategoryScoped {
            playSound(named: "Exit")
            transitionMenuForFolderSwap {
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
            exitMusicThirdMenuToSecondLevelWithSwap(useOverlayFade: true)
        case .moviesITunesTop, .tvITunesTopEpisodes:
            playSound(named: "Exit")
            exitMoviesThirdMenuToSecondLevelWithSwap(useOverlayFade: true)
        case .podcastsEpisodes:
            playSound(named: "Exit")
            exitPodcastsThirdMenuToSecondLevelWithSwap(useOverlayFade: true)
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
        revealWhen: @escaping () -> Bool = { true },
        maxRevealWait: TimeInterval = 10.0,
        _ update: @escaping () -> Void,
    ) {
        guard !isMenuFolderSwapTransitioning else { return }
        guard !isFullscreenSceneTransitioning else { return }
        guard !isMovieTransitioning else { return }
        isMenuFolderSwapTransitioning = true
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
            @MainActor func revealWhenReady() async {
                guard isMenuFolderSwapTransitioning else { return }
                let canRevealNow = revealWhen() || Date() >= revealDeadline
                guard canRevealNow else {
                    try? await firstRowSleep(0.05)
                    await revealWhenReady()
                    return
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
                isMenuFolderSwapTransitioning = false
            }
            await revealWhenReady()
        }
    }
}
