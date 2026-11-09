import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

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
        case mediaFolders
        case screenSaverSettings
        case spotify
        case jellyfin
    }
}

extension MenuView {
    func returnToRootMenuViaBlackFade() {
        guard isInSubmenu || isEnteringSubmenu else { return }
        transitionMenuForFolderSwap(
            useOverlayFade: true,
            revealWhen: { !self.isInSubmenu && self.activeRootItemID == nil },
        ) {
            self.returnToRootMenu(playExitSound: false)
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
        case "sources":
            refreshJellyfinPreviewForCurrentContext()
        default:
            break
        }
    }

    func exitThirdMenuToSecondLevel() {
        let isExitingMusicThirdMenu = switch thirdMenuMode {
        case .musicSongs, .musicCategories, .musicITunesTopSongs, .musicITunesTopMusicVideos, .spotify:
            true
        case .moviesFolder, .moviesITunesTop, .tvITunesTopEpisodes, .photosDateAlbums, .podcastsEpisodes, .mediaFolders, .screenSaverSettings, .jellyfin, .none:
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
            self.isInThirdMenu = false
            self.thirdMenuMode = .none
            self.thirdMenuOpacity = 0
            self.submenuOpacity = 1
            self.headerText = self.rootMenuTitle(for: self.activeRootItemID)
            self.resetThirdMenuDirectoryState()
            self.moviesFolderSelectionIndexByDirectoryPath = [:]
            self.resetITunesTopCarouselAndPreviewState(for: [.movies, .tvEpisodes])
            self.refreshDetailPreviewForCurrentContext()
        }
    }

    func exitPodcastsThirdMenuToSecondLevelWithSwap(useOverlayFade: Bool = false) {
        transitionMenuForFolderSwap(useOverlayFade: useOverlayFade) {
            self.isInThirdMenu = false
            self.thirdMenuMode = .none
            self.thirdMenuOpacity = 0
            self.submenuOpacity = 1
            self.headerText = self.rootMenuTitle(for: self.activeRootItemID)
            self.syncPodcastSubmenuSelectionForActiveSeries()
            self.refreshDetailPreviewForCurrentContext()
        }
    }

    func exitPhotosThirdMenuToSecondLevelWithSwap(useOverlayFade: Bool = false) {
        transitionMenuForFolderSwap(useOverlayFade: useOverlayFade) {
            self.isInThirdMenu = false
            self.thirdMenuMode = .none
            self.thirdMenuOpacity = 0
            self.submenuOpacity = 1
            self.headerText = self.rootMenuTitle(for: self.activeRootItemID)
            self.refreshDetailPreviewForCurrentContext()
        }
    }

    func navigateUpInThirdMenuOrExit() {
        if thirdMenuMode == .musicSongs, spotifySongsReturnPages != nil {
            playSound(named: "Exit")
            returnFromSpotifySongs()
            return
        }
        if thirdMenuMode == .musicSongs, jellyfin.songsReturnPages != nil {
            playSound(named: "Exit")
            returnFromJellyfinSongs()
            return
        }
        if thirdMenuMode == .musicSongs, isMusicSongsCategoryScoped {
            playSound(named: "Exit")
            transitionMenuForFolderSwap {
                self.thirdMenuMode = .musicCategories
                self.isMusicSongsCategoryScoped = false
                self.isLoadingMusicSongs = false
                self.musicSongsLoadError = nil
                self.headerText = self.activeMusicCategoryMenuTitle.isEmpty
                    ? self.rootMenuTitle(for: self.activeRootItemID)
                    : self.activeMusicCategoryMenuTitle
                self.selectedThirdIndex = min(
                    self.lastSelectedMusicCategoryIndex,
                    max(0, self.musicCategoryThirdMenuItems.count - 1),
                )
                self.refreshDetailPreviewForCurrentContext()
                self.submenuOpacity = 0
                self.thirdMenuOpacity = 1
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
        case .mediaFolders:
            playSound(named: "Exit")
            navigateUpInMediaFolders()
        case .screenSaverSettings:
            playSound(named: "Exit")
            exitScreenSaverSettings()
        case .spotify:
            playSound(named: "Exit")
            navigateUpInSpotifyMenu()
        case .jellyfin:
            playSound(named: "Exit")
            navigateUpInJellyfinMenu()
        case .moviesFolder:
            if isShowingContinueWatching {
                playSound(named: "Exit")
                exitMoviesThirdMenuToSecondLevelWithSwap()
                return
            }
            guard let currentURL = thirdMenuCurrentURL else {
                // The list of places movies come from (more than one folder or drive).
                playSound(named: "Exit")
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
                    self.loadThirdMenuDirectory(parentURL, resetSelection: true)
                }
            } else if !movieLibraryRootURLs.isEmpty {
                rememberCurrentMoviesFolderSelectionIndex()
                #if os(macOS) || FIRSTROW_PORTABLE
                    transitionMenuForFolderSwap {
                        self.loadMoviesRootSelectorEntries(resetSelection: false)
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
        if ModernTheme.isActive {
            swapModernMenu(revealWhen: revealWhen, maxRevealWait: maxRevealWait, update)
            return
        }
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

/// The modern look changes menus without going through black: the title and list fade out,
/// change, and ease back in from the side the move went (from the right going deeper, from the
/// left coming back), while the card and background stay.
extension MenuView {
    /// Roughly how deep the menus are, to tell going in from coming back.
    var modernMenuDepth: Int {
        var depth = (isInSubmenu ? 1 : 0) + (isInThirdMenu ? 1 : 0)
        depth += max(0, spotifyMenuPages.count - 1) + max(0, mediaFoldersPages.count - 1) + max(0, jellyfin.pages.count - 1)
        if isMusicSongsCategoryScoped { depth += 1 }
        if let current = thirdMenuCurrentURL, let root = thirdMenuRootURL {
            depth += max(0, current.standardizedFileURL.pathComponents.count - root.standardizedFileURL.pathComponents.count)
        }
        if spotifySongsReturnPages != nil { depth += 1 }
        return depth
    }

    func swapModernMenu(revealWhen: @escaping () -> Bool, maxRevealWait: TimeInterval, _ update: @escaping () -> Void) {
        isMenuFolderSwapTransitioning = true
        let depthBefore = modernMenuDepth
        let leave = Animation.smoothInOut(duration: 0.16)
        withAnimation(leave) {
            modernSwapOpacity = 0
        }
        Task { @MainActor in
            try? await firstRowSleep(leave.duration + 0.02)
            guard !Task.isCancelled, isMenuFolderSwapTransitioning else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                update()
            }
            guard isMenuFolderSwapTransitioning else { return }
            let goesDeeper = modernMenuDepth >= depthBefore
            withTransaction(instant) {
                modernSwapOffset = goesDeeper ? ModernTheme.listSlideDistance : -ModernTheme.listSlideDistance
            }
            let deadline = Date().addingTimeInterval(max(0, maxRevealWait))
            while isMenuFolderSwapTransitioning, !revealWhen(), Date() < deadline {
                try? await firstRowSleep(0.05)
            }
            guard isMenuFolderSwapTransitioning else { return }
            let arrive = Animation.smooth(duration: 0.36)
            withAnimation(arrive) {
                modernSwapOpacity = 1
                modernSwapOffset = 0
            }
            try? await firstRowSleep(arrive.duration)
            isMenuFolderSwapTransitioning = false
        }
    }
}
