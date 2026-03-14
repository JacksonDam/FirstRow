import SwiftUI

extension MenuView {
    enum ThirdMenuMode {
        case none
        case moviesFolder
        case moviesITunesTop
        case musicITunesTopSongs
        case musicITunesTopMusicVideos
        case musicCategories
        case musicSongs
        case photosDateAlbums
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
        case "music":
            refreshMusicPreviewForCurrentContext()
            refreshMusicTopLevelCarouselForCurrentContext()
            refreshITunesTopPreviewForCurrentContext(.songs)
            refreshITunesTopCarouselForCurrentContext(.songs)
            refreshITunesTopPreviewForCurrentContext(.musicVideos)
            refreshITunesTopCarouselForCurrentContext(.musicVideos)
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
        case .moviesFolder, .moviesITunesTop, .photosDateAlbums, .none:
            false
        }
        transitionMenuForFolderSwap {
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
        transitionMenuForFolderSwap(useOverlayFade: useOverlayFade) {
            isInThirdMenu = false
            thirdMenuMode = .none
            thirdMenuOpacity = 0
            submenuOpacity = 1
            headerText = rootMenuTitle(for: activeRootItemID)
            resetThirdMenuDirectoryState()
            moviesFolderSelectionIndexByDirectoryPath = [:]
            resetITunesTopCarouselAndPreviewState(for: [.movies])
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
            exitMusicThirdMenuToSecondLevelWithSwap()
        case .moviesITunesTop:
            playSound(named: "Exit")
            exitMoviesThirdMenuToSecondLevelWithSwap()
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
        if !useOverlayFade {
            menuTransitionSnapshot = currentMenuTransitionSnapshot()
            menuTransitionProgress = menuTransitionSnapshot == nil ? 1 : 0
            var instant = Transaction()
            instant.animation = nil
            withTransaction(instant) {
                update()
            }
            let revealDeadline = Date().addingTimeInterval(max(0, maxRevealWait))
            func revealWhenReady() {
                guard isMenuFolderSwapTransitioning else { return }
                let canRevealNow = revealWhen() || Date() >= revealDeadline
                guard canRevealNow else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        revealWhenReady()
                    }
                    return
                }
                guard menuTransitionSnapshot != nil else {
                    menuTransitionProgress = 1
                    isMenuFolderSwapTransitioning = false
                    return
                }
                withAnimation(.easeInOut(duration: menuSlideDuration)) {
                    menuTransitionProgress = 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + menuSlideDuration) {
                    menuTransitionSnapshot = nil
                    isMenuFolderSwapTransitioning = false
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                revealWhenReady()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + swapUpdateDelay) {
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
            DispatchQueue.main.async {
                guard isMenuFolderSwapTransitioning else { return }
                var instant = Transaction()
                instant.animation = nil
                withTransaction(instant) {
                    update()
                }
                let revealDeadline = Date().addingTimeInterval(max(0, maxRevealWait))
                func revealWhenReady() {
                    guard isMenuFolderSwapTransitioning else { return }
                    let canRevealNow = revealWhen() || Date() >= revealDeadline
                    guard canRevealNow else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            revealWhenReady()
                        }
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + menuFolderSwapFadeDuration) {
                        isMenuFolderSwapTransitioning = false
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + menuFolderSwapHoldDuration) {
                    revealWhenReady()
                }
            }
        }
    }
}
