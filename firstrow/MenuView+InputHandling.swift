import AVFoundation
import AVKit
import SwiftUI
#if os(macOS)
    import AppKit
    import CoreGraphics
#endif
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif
import Darwin

extension MenuView {
    func handleKeyInput(_ key: KeyCode, isRepeat: Bool, modifiers: NSEvent.ModifierFlags = []) {
        let commandPressed = modifiers.contains(.command)
        if key == .escape, commandPressed {
            NotificationCenter.default.post(name: .firstRowCommandEscapeRequested, object: nil)
            return
        }
        guard !isRootExitRunning else { return }
        guard !blocksMenuForStartupMusicLibraryPreload else { return }
        if isFullscreenSceneTransitioning {
            return
        }
        if isMenuFolderSwapTransitioning {
            return
        }
        if let activeFullscreenScene {
            if activeFullscreenScene.key == photoSlideshowFullscreenKey {
                handlePhotoSlideshowInput(key, isRepeat: isRepeat)
                return
            }
            if key == .delete || key == .escape {
                dismissFullscreenScene()
                playSound(named: "Exit")
            }
            return
        }
        if thirdMenuMode == .musicNowPlaying {
            handleMusicNowPlayingPageInput(key, isRepeat: isRepeat)
            return
        }
        if thirdMenuMode == .errorPage {
            if key == .delete || key == .escape, menuTransitionSnapshot == nil {
                exitErrorPage()
                playSound(named: "Exit")
            }
            return
        }
        if isMovieTransitioning {
            return
        }
        if isMoviePlaybackVisible {
            handleMoviePlaybackInput(key, isRepeat: isRepeat)
            return
        }
        if isReturningToRoot {
            return
        }
        if isRootIntroRunning, !isInSubmenu, !isEnteringSubmenu {
            return
        }
        switch key {
        case .downArrow:
            guard !isEnteringSubmenu else { return }
            if isInThirdMenu {
                navigateThirdMenuSelection(direction: 1, isRepeat: isRepeat)
            } else if isInSubmenu {
                navigateSubmenuSelection(direction: 1, isRepeat: isRepeat)
            }
        case .upArrow:
            guard !isEnteringSubmenu else { return }
            if isInThirdMenu {
                navigateThirdMenuSelection(direction: -1, isRepeat: isRepeat)
            } else if isInSubmenu {
                navigateSubmenuSelection(direction: -1, isRepeat: isRepeat)
            }
        case .leftArrow:
            if isInThirdMenu || isInSubmenu {
                resetNavigationAccelerationState()
                return
            }
            navigateRootSelection(direction: -1, key: key, isRepeat: isRepeat)
        case .rightArrow:
            if isInThirdMenu || isInSubmenu {
                resetNavigationAccelerationState()
                return
            }
            navigateRootSelection(direction: 1, key: key, isRepeat: isRepeat)
        case .enter:
            resetNavigationAccelerationState()
            if isInThirdMenu {
                triggerThirdMenuAction()
            } else if isInSubmenu {
                triggerSubmenuAction()
            } else if !isEnteringSubmenu {
                startSubmenuTransition()
            }
        case .delete:
            resetNavigationAccelerationState()
            if isInThirdMenu {
                navigateUpInThirdMenuOrExit()
            } else if isInSubmenu || isEnteringSubmenu {
                returnToRootMenu()
            } else {
                playLimitSoundOnceForCurrentHold()
            }
        default:
            resetNavigationAccelerationState()
        }
    }

    func startSubmenuTransition() {
        guard menuItems.indices.contains(selectedIndex) else { return }
        submenuEntryWorkItem?.cancel()
        submenuEntryWorkItem = nil
        let chosenRootItem = menuItems[selectedIndex]
        if isMusicActivelyPlaying, chosenRootItem.id != "music" {
            stopMusicPlaybackSession(clearDisplayState: true)
        }
        guard chosenRootItem.leadsToMenu else {
            triggerRootAction(chosenRootItem)
            return
        }
        beginSubmenuTransition(for: chosenRootItem)
    }

    func beginSubmenuTransition(for chosenRootItem: RootMenuItemConfig, playSelectionSound: Bool = true) {
        isReturningToRoot = false
        isMenuOverflowScrollingUp = false
        isMenuOverflowScrollingDown = false
        overflowFadeWorkItem?.cancel()
        isInThirdMenu = false
        thirdMenuMode = .none
        thirdMenuOpacity = 0
        isSubmenuErrorPage = false
        errorPageHeaderText = ""
        errorPageSubcaptionText = ""
        _ = incrementRequestID(&theatricalTrailersLoadingRequestID)
        isTheatricalTrailersLoading = false
        _ = incrementRequestID(&moviePlaybackLoadingRequestID)
        isMoviePlaybackLoading = false
        isPhotosAlbumSelectionLoading = false
        stopMoviesFolderGapPlayer()
        resetThirdMenuDirectoryState()
        resetAllITunesTopMenusForNonITunesContext()
        _ = incrementRequestID(&musicTopLevelCarouselRequestID)
        isLoadingMusicTopLevelCarousel = false
        musicTopLevelCarouselLoadOverlayOpacity = 0
        musicTopLevelCarouselPageStartsInFlight.removeAll()
        let shouldPreserveMusicPlaylistForNowPlaying = chosenRootItem.id == "music" && hasActiveMusicPlaybackSession()
        let preservedMusicSongsThirdMenuItems = shouldPreserveMusicPlaylistForNowPlaying
            ? musicSongsThirdMenuItems
            : []
        let preservedMusicSongsShowsShuffleAction = shouldPreserveMusicPlaylistForNowPlaying
            ? musicSongsShowsShuffleAction
            : false
        let preservedMusicSongsShuffleMode = shouldPreserveMusicPlaylistForNowPlaying
            ? isMusicSongsShuffleMode
            : false
        let preservedActiveMusicLibraryMediaType = shouldPreserveMusicPlaylistForNowPlaying
            ? activeMusicLibraryMediaType
            : .songs
        resetMusicCategoryStateForNonMusicITunesTop()
        if shouldPreserveMusicPlaylistForNowPlaying {
            musicSongsThirdMenuItems = preservedMusicSongsThirdMenuItems
            musicSongsShowsShuffleAction = preservedMusicSongsShowsShuffleAction
            isMusicSongsShuffleMode = preservedMusicSongsShuffleMode
            activeMusicLibraryMediaType = preservedActiveMusicLibraryMediaType
        } else {
            activeMusicLibraryMediaType = .songs
            musicSongsShowsShuffleAction = false
        }
        selectedThirdIndex = 0
        activeRootItemID = chosenRootItem.id
        
        if chosenRootItem.id == "dvd" {
            let copy = FeatureErrorKind.noDVDDisc.copy
            errorPageHeaderText = copy.headerText
            errorPageSubcaptionText = copy.subcaptionText
            isSubmenuErrorPage = true
        }

        let submenuItems = MenuConfiguration.submenuItems(forRootID: chosenRootItem.id)
        let shouldDefaultToNowPlayingInMusic =
            chosenRootItem.id == "music" &&
            (isMusicActivelyPlaying || holdNowPlayingMenuItemDuringExitFade || deferNowPlayingMenuItemUntilAfterFadeOut)
        let preferredSubmenuIndex = shouldDefaultToNowPlayingInMusic
            ? 0
            : MenuConfiguration.defaultSubmenuSelectedIndex(forRootID: chosenRootItem.id)
        let maxSubmenuIndex = max(0, submenuItems.count - 1)
        selectedSubIndex = max(0, min(preferredSubmenuIndex, maxSubmenuIndex))
        isEnteringSubmenu = true
        isIconAnimated = true
        submenuTransitionProgress = 0
        if chosenRootItem.id == "photos" {
            isPhotosGapPreviewSlid = false
            withAnimation(.easeInOut(duration: 1.0)) {
                isPhotosGapPreviewSlid = true
            }
        }
        submenuTitleOpacity = 0
        submenuOpacity = 0
        detailContentOpacity = 0
        withAnimation(.easeInOut(duration: iconFlightAnimationDuration)) {
            submenuTransitionProgress = 1
        }
        withAnimation(.easeInOut(duration: 0.32)) {
            rootMenuOpacity = 0
            headerOpacity = 0
        }
        if playSelectionSound {
            playSound(named: chosenRootItem.mainMenuSelectionSoundName ?? "Selection")
        }
        let entryWorkItem = DispatchWorkItem {
            guard isEnteringSubmenu, isIconAnimated, !isReturningToRoot else { return }
            headerText = chosenRootItem.title
            isInSubmenu = true
            isEnteringSubmenu = false
            refreshDetailPreviewForCurrentContext()
            withAnimation(.easeInOut(duration: 0.26)) {
                submenuTitleOpacity = 1
                submenuOpacity = 1
                detailContentOpacity = 1
            }
            submenuEntryWorkItem = nil
        }
        submenuEntryWorkItem = entryWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + iconFlightAnimationDuration,
            execute: entryWorkItem,
        )
    }

    func returnToRootMenu(playExitSound: Bool = true) {
        guard isInSubmenu || isEnteringSubmenu else { return }
        guard !isReturningToRoot else { return }
        let submenuExitFadeDuration = 0.18
        let rootRevealDelay = max(
            iconFlightAnimationDuration,
            submenuBackgroundIconReturnDuration,
        )
        let shouldPreserveMusicPlaybackStateOnRootExit =
            activeRootItemID == "music" && hasActiveMusicPlaybackSession()
        let preservedMusicSongsThirdMenuItems = shouldPreserveMusicPlaybackStateOnRootExit
            ? musicSongsThirdMenuItems
            : []
        let preservedMusicSongsShowsShuffleAction = shouldPreserveMusicPlaybackStateOnRootExit
            ? musicSongsShowsShuffleAction
            : false
        let preservedMusicSongsShuffleMode = shouldPreserveMusicPlaybackStateOnRootExit
            ? isMusicSongsShuffleMode
            : false
        let preservedActiveMusicLibraryMediaType = shouldPreserveMusicPlaybackStateOnRootExit
            ? activeMusicLibraryMediaType
            : .songs
        submenuEntryWorkItem?.cancel()
        submenuEntryWorkItem = nil
        let shouldHoldNowPlayingDuringExitFade =
            activeRootItemID == "music" &&
            !isInThirdMenu &&
            !deferNowPlayingMenuItemUntilAfterFadeOut &&
            currentSubmenuItems().first?.id == "music_now_playing"
        if shouldHoldNowPlayingDuringExitFade {
            holdNowPlayingMenuItemDuringExitFade = true
        }
        if activeRootItemID == "photos" {
            withAnimation(.easeInOut(duration: 0.85)) {
                isPhotosGapPreviewSlid = false
            }
            Task { @MainActor in
                try? await firstRowSleep(0.85)
                _ = incrementRequestID(&photosGapPreviewRequestID)
                photosGapPreviewAlbumID = nil
                photosGapPreviewImage = nil
            }
        }
        var instantStateChange = Transaction()
        instantStateChange.disablesAnimations = true
        withTransaction(instantStateChange) {
            isEnteringSubmenu = true
            isReturningToRoot = true
        }
        isMenuOverflowScrollingUp = false
        isMenuOverflowScrollingDown = false
        overflowFadeWorkItem?.cancel()

        for kind in ITunesTopCarouselKind.allCases {
            _ = nextITunesTopCarouselRequestID(kind)
            _ = nextITunesTopRequestID(kind)
            _ = nextITunesTopPreviewRequestID(kind)
            if kind == .songs || kind == .musicVideos {
                _ = nextITunesTopPlaybackRequestID(kind)
            }
        }
        _ = incrementRequestID(&musicTopLevelCarouselRequestID)
        isLoadingMusicTopLevelCarousel = false
        musicTopLevelCarouselLoadOverlayOpacity = 0
        musicTopLevelCarouselPageStartsInFlight.removeAll()
        _ = incrementRequestID(&musicSongsRequestID)
        _ = incrementRequestID(&moviePreviewRequestID)
        _ = incrementRequestID(&moviesFolderSubmenuPreviewRequestID)
        _ = incrementRequestID(&musicPreviewRequestID)
        _ = incrementRequestID(&theatricalTrailersLoadingRequestID)
        isTheatricalTrailersLoading = false
        _ = incrementRequestID(&moviePlaybackLoadingRequestID)
        isMoviePlaybackLoading = false
        isPhotosAlbumSelectionLoading = false

        DispatchQueue.main.async {
            isIconAnimated = false
        }
        withAnimation(.easeInOut(duration: submenuExitFadeDuration)) {
            submenuTitleOpacity = 0
            submenuOpacity = 0
            detailContentOpacity = 0
            headerOpacity = 0
        }
        withAnimation(.easeInOut(duration: submenuBackgroundIconReturnDuration)) {
            isEnteringSubmenu = false
            submenuTransitionProgress = 0
        }
        if playExitSound {
            playSound(named: "MainTransitionFrom")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + rootRevealDelay) {
            holdNowPlayingMenuItemDuringExitFade = false
            var instantRootLabelState = Transaction()
            instantRootLabelState.disablesAnimations = true
            withTransaction(instantRootLabelState) {
                isInThirdMenu = false
                thirdMenuMode = .none
                thirdMenuOpacity = 0
                isSubmenuErrorPage = false
                errorPageHeaderText = ""
                errorPageSubcaptionText = ""
                resetThirdMenuDirectoryState()
                resetAllITunesTopMenusForNonITunesContext()
                moviePreviewTargetURL = nil
                moviePreviewImage = nil
                moviesFolderSubmenuPreviewDescriptors = []
                moviesFolderSubmenuPreviewIdentity = ""
                stopMoviesFolderGapPlayer()
                movieResumeBackdropOpacity = 0
                movieResumePromptTargetURL = nil
                movieResumePromptResumeSeconds = 0
                movieResumePromptBackdropImage = nil
                _ = incrementRequestID(&movieResumePromptBackdropRequestID)
                musicPreviewTargetSongID = nil
                musicPreviewImage = nil
                resetMusicCategoryStateForNonMusicITunesTop()
                if shouldPreserveMusicPlaybackStateOnRootExit {
                    musicSongsThirdMenuItems = preservedMusicSongsThirdMenuItems
                    musicSongsShowsShuffleAction = preservedMusicSongsShowsShuffleAction
                    isMusicSongsShuffleMode = preservedMusicSongsShuffleMode
                    activeMusicLibraryMediaType = preservedActiveMusicLibraryMediaType
                } else {
                    activeMusicLibraryMediaType = .songs
                    musicSongsShowsShuffleAction = false
                }
                selectedThirdIndex = 0
                headerText = "First Row"
                isInSubmenu = false
                activeRootItemID = nil
                submenuTransitionProgress = 0
                isReturningToRoot = false
                isPhotosGapPreviewSlid = false
                rootLabelSwapWorkItem?.cancel()
                if menuItems.indices.contains(selectedIndex) {
                    rootLabelText = menuItems[selectedIndex].title
                }
                isRootLabelVisible = true
                rootLabelOpacity = 1
            }
            withAnimation(.easeInOut(duration: 0.32)) {
                rootMenuOpacity = 1
                headerOpacity = 1
            }
        }
    }

    func triggerSubmenuAction() {
        let submenuItems = currentSubmenuItems()
        guard !submenuItems.isEmpty else { return }
        let clampedSubIndex = min(max(0, selectedSubIndex), submenuItems.count - 1)
        if clampedSubIndex != selectedSubIndex {
            selectedSubIndex = clampedSubIndex
        }
        let item = submenuItems[clampedSubIndex]
        if activeRootItemID == "music", item.id == "music_now_playing" {
            guard isMusicActivelyPlaying else { return }
            playSound(named: "Selection")
            enterMusicNowPlayingPage()
            return
        }
        if activeRootItemID == "movies", item.id == "movies_folder" {
            playSound(named: "Selection")
            enterMoviesFolderMenu()
            return
        }
        if activeRootItemID == "movies", item.id == "movies_itunes_top" {
            playSound(named: "Selection")
            enterITunesTopMenu(.movies, title: item.title)
            return
        }
        if activeRootItemID == "movies", item.id == "movies_theatrical_trailers" {
            playSound(named: "Selection")
            presentTheatricalTrailersLoading()
            return
        }
        if activeRootItemID == "music", item.id == "music_itunes_top_songs" {
            playSound(named: "Selection")
            enterITunesTopMenu(.songs, title: item.title)
            return
        }
        if activeRootItemID == "music", item.id == "music_itunes_top_music_videos" {
            playSound(named: "Selection")
            enterITunesTopMenu(.musicVideos, title: item.title)
            return
        }
        if activeRootItemID == "music", item.id == "music_songs" {
            playSound(named: "Selection")
            enterMusicSongsMenu(
                title: item.title,
                shuffleMode: false,
                libraryMediaType: .songs,
                showsShuffleAction: true,
            )
            return
        }
        if activeRootItemID == "music", item.id == "music_music_videos" {
            playSound(named: "Selection")
            enterMusicSongsMenu(
                title: item.title,
                shuffleMode: false,
                libraryMediaType: .musicVideos,
                showsShuffleAction: false,
            )
            return
        }
        if activeRootItemID == "music", item.id == "music_audiobooks" {
            playSound(named: "Selection")
            enterMusicSongsMenu(
                title: item.title,
                shuffleMode: false,
                libraryMediaType: .audiobooks,
                showsShuffleAction: false,
            )
            return
        }
        if activeRootItemID == "music", item.id == "music_shuffle_songs" {
            playSound(named: "Selection")
            startMusicShufflePlaybackFromLibrary()
            return
        }
        if activeRootItemID == "music", let musicCategoryKind = musicCategoryKind(forSubmenuItemID: item.id) {
            playSound(named: "Selection")
            enterMusicCategoryMenu(title: item.title, kind: musicCategoryKind)
            return
        }
        if activeRootItemID == "photos", item.id == "photos_shared" {
            playSound(named: "Selection")
            presentFeatureErrorScreen(.noSharedPhotos)
            return
        }
        if activeRootItemID == "photos", item.id == "photos_library" {
            playSound(named: "Selection")
            enterPhotosDateAlbumsMenu(title: item.title)
            return
        }
        if activeRootItemID == "photos", item.id == "photos_last_12_months" {
            guard let album = photoAlbumForSubmenuItemID(item.id), album.isPlayable else {
                playLimitSoundOnceForCurrentHold()
                return
            }
            playSound(named: "Selection")
            startPhotoAlbumSlideshow(for: album)
            return
        }
        if activeRootItemID == "photos", item.id == "photos_last_import" {
            playSound(named: "Selection")
            return
        }
        playSound(named: "Selection")
        performSubmenuAction(item)
    }

    func handleMusicNowPlayingPageInput(_ key: KeyCode, isRepeat: Bool) {
        switch key {
        case .delete, .escape:
            stopMusicScrubbing(showPauseGlyph: false)
            navigateUpInThirdMenuOrExit()
        case .space:
            handleMusicSpacebarPressed()
        case .upArrow, .downArrow:
            guard prepareNavigationTiming(for: key, isRepeat: isRepeat) else { return }
            switchMusicNowPlayingTrack(direction: key == .upArrow ? -1 : 1)
        case .leftArrow:
            beginMusicScrubbing(direction: -1, isRepeat: isRepeat)
        case .rightArrow:
            beginMusicScrubbing(direction: 1, isRepeat: isRepeat)
        default:
            break
        }
    }

    func triggerThirdMenuAction() {
        playSound(named: "Selection")
        switch thirdMenuMode {
        case .moviesFolder:
            guard thirdMenuItems.indices.contains(selectedThirdIndex) else { return }
            guard !isMoviePlaybackLoading else { return }
            let item = thirdMenuItems[selectedThirdIndex]
            if item.isDirectory {
                requestMoviesFolderDirectoryOpenIfNotEmpty(item)
            } else {
                showMoviePlaybackLoadingThen {
                    startMoviePlayback(from: item.url)
                }
            }
        case .moviesITunesTop:
            startSelectedITunesTopThirdMenuItemPlayback(for: .movies)
            return
        case .musicITunesTopSongs:
            startSelectedITunesTopThirdMenuItemPlayback(for: .songs)
            return
        case .musicITunesTopMusicVideos:
            startSelectedITunesTopThirdMenuItemPlayback(for: .musicVideos)
            return
        case .musicCategories:
            enterSongsForSelectedMusicCategory()
        case .musicSongs:
            if shouldShowMusicSongsShuffleActionItem(), selectedThirdIndex == 0 {
                startShufflePlaybackFromCurrentMusicSongsMenu()
                return
            }
            guard let songIndex = musicSongIndex(forThirdMenuSelectionIndex: selectedThirdIndex) else { return }
            let song = musicSongsThirdMenuItems[songIndex]
            if activeMusicPlaybackSongID == song.id, hasActiveMusicPlaybackSession() {
                musicNowPlayingTrackPositionText = musicSongsThirdMenuItems.isEmpty
                    ? ""
                    : "\(songIndex + 1) of \(musicSongsThirdMenuItems.count)"
                musicNowPlayingShowsShuffleGlyph = isMusicSongsShuffleMode
                enterMusicNowPlayingPage()
            } else {
                startPlaybackForMusicLibraryEntry(
                    song,
                    trackIndex: songIndex,
                    trackCount: musicSongsThirdMenuItems.count,
                    playbackQueue: musicSongsThirdMenuItems,
                )
            }
        case .movieResumePrompt:
            triggerMovieResumeFromPage()
        case .musicNowPlaying, .errorPage:
            break
        case .photosDateAlbums:
            guard photosDateAlbums.indices.contains(selectedThirdIndex) else { return }
            let album = photosDateAlbums[selectedThirdIndex]
            guard album.isPlayable else { return }
            isPhotosAlbumSelectionLoading = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    self.isPhotosAlbumSelectionLoading = false
                }
                self.startPhotoAlbumSlideshow(for: album)
            }
        case .none:
            return
        }
    }

    func requestMoviesFolderDirectoryOpenIfNotEmpty(_ directoryEntry: MoviesFolderEntry) {
        guard directoryEntry.isDirectory else { return }
        let selectedDirectory = directoryEntry.url.standardizedFileURL
        let parentDirectory = thirdMenuCurrentURL?.standardizedFileURL
        DispatchQueue.global(qos: .userInitiated).async {
            let hasNavigableContent = self.moviesFolderContainsNavigableContent(in: selectedDirectory)
            DispatchQueue.main.async {
                guard self.thirdMenuMode == .moviesFolder else { return }
                guard self.thirdMenuCurrentURL?.standardizedFileURL == parentDirectory else { return }
                guard self.thirdMenuItems.indices.contains(self.selectedThirdIndex) else { return }
                let currentSelection = self.thirdMenuItems[self.selectedThirdIndex]
                guard currentSelection.isDirectory else { return }
                guard currentSelection.url.standardizedFileURL == selectedDirectory else { return }
                if hasNavigableContent {
                    self.rememberCurrentMoviesFolderSelectionIndex()
                    self.transitionMenuForFolderSwap(revealWhen: { !self.isLoadingMoviesFolderEntries }) {
                        self.loadThirdMenuDirectory(selectedDirectory, resetSelection: true)
                    }
                } else {
                    self.presentFeatureErrorScreen(.noContentFound)
                }
            }
        }
    }

    func startSelectedITunesTopThirdMenuItemPlayback(for kind: ITunesTopCarouselKind) {
        switch kind {
        case .movies:
            guard iTunesTopMovies.indices.contains(selectedThirdIndex) else { return }
            startITunesTopMoviePreviewPlayback(for: iTunesTopMovies[selectedThirdIndex])
        case .songs:
            guard iTunesTopSongs.indices.contains(selectedThirdIndex) else { return }
            let selectedSong = iTunesTopSongs[selectedThirdIndex]
            if activeMusicPlaybackSongID == selectedSong.id, hasActiveMusicPlaybackSession() {
                musicNowPlayingTrackPositionText = "1 of 1"
                musicNowPlayingShowsShuffleGlyph = false
                enterMusicNowPlayingPage()
                return
            }
            startITunesTopSongPreviewPlayback(
                for: selectedSong,
                trackIndex: selectedThirdIndex,
                trackCount: iTunesTopSongs.count,
            )
        case .musicVideos:
            guard iTunesTopMusicVideos.indices.contains(selectedThirdIndex) else { return }
            startITunesTopMusicVideoPreviewPlayback(for: iTunesTopMusicVideos[selectedThirdIndex])
        }
    }

    func triggerRootAction(_ item: RootMenuItemConfig) {
        playSound(named: item.mainMenuSelectionSoundName ?? "Selection")
        MenuConfiguration.performRootAction(for: item)
    }

    func performSubmenuAction(_ item: SubmenuItemConfig) {
        MenuConfiguration.performSubmenuAction(for: item)
    }

    func switchToSubmenuRoot(_ rootID: String) {
        guard let targetRootItem = MenuConfiguration.rootItem(withID: rootID) else { return }

        submenuEntryWorkItem?.cancel()
        submenuEntryWorkItem = nil
        overflowFadeWorkItem?.cancel()
        overflowFadeWorkItem = nil
        isMenuOverflowScrollingUp = false
        isMenuOverflowScrollingDown = false

        if activeRootItemID == "music", rootID != "music", isMusicActivelyPlaying {
            stopMusicPlaybackSession(clearDisplayState: true)
        }

        transitionMenuForFolderSwap {
            isReturningToRoot = false
            isInThirdMenu = false
            thirdMenuMode = .none
            thirdMenuOpacity = 0
            resetThirdMenuDirectoryState()
            resetAllITunesTopMenusForNonITunesContext()
            resetMusicCategoryStateForNonMusicITunesTop()
            activeRootItemID = rootID
            let targetSubmenuItems = MenuConfiguration.submenuItems(forRootID: rootID)
            let defaultSubmenuIndex = MenuConfiguration.defaultSubmenuSelectedIndex(forRootID: rootID)
            selectedSubIndex = max(0, min(defaultSubmenuIndex, max(0, targetSubmenuItems.count - 1)))
            headerText = targetRootItem.title
            submenuTitleOpacity = 1
            submenuOpacity = 1
            detailContentOpacity = 1
            submenuTransitionProgress = 1
            rootMenuOpacity = 0
            headerOpacity = 0
            refreshDetailPreviewForCurrentContext()
        }
    }

    func resolvedNextNavigationIndex(
        direction: Int,
        key: KeyCode,
        isRepeat: Bool,
        currentIndex: Int,
        itemCount: Int,
        rowOffsets: [CGFloat],
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        selectionAnchorY: CGFloat? = nil,
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        guard prepareNavigationTiming(for: key, isRepeat: isRepeat) else { return nil }
        let nextIndex = max(0, min(itemCount - 1, currentIndex + direction))
        guard nextIndex != currentIndex else {
            playLimitSoundOnceForCurrentHold()
            return nil
        }
        let oldScrollOffset = menuScrollOffset(
            contentHeight: contentHeight,
            selectedIndex: currentIndex,
            rowOffsets: rowOffsets,
            viewportHeight: viewportHeight,
            selectionAnchorY: selectionAnchorY,
        )
        let newScrollOffset = menuScrollOffset(
            contentHeight: contentHeight,
            selectedIndex: nextIndex,
            rowOffsets: rowOffsets,
            viewportHeight: viewportHeight,
            selectionAnchorY: selectionAnchorY,
        )
        updateOverflowFadeVisibility(oldOffset: oldScrollOffset, newOffset: newScrollOffset)
        didPlayLimitForCurrentHold = false
        markSelectionAsMoving()
        playSound(named: "SelectionChange")
        return nextIndex
    }

    func navigateRootSelection(direction: Int, key: KeyCode, isRepeat: Bool) {
        guard !menuItems.isEmpty else { return }
        guard prepareNavigationTiming(for: key, isRepeat: isRepeat) else { return }
        let nextIndex = (selectedIndex + direction + menuItems.count) % menuItems.count
        didPlayLimitForCurrentHold = false
        markSelectionAsMoving()
        playSound(named: "MainLeft")
        transitionRootLabel(to: menuItems[nextIndex].title)
        DispatchQueue.main.async {
            selectedIndex = nextIndex
            withAnimation(.easeInOut(duration: selectionAnimationDuration * rootNavigationDurationMultiplier)) {
                rootCarouselSelectionValue += Double(direction)
            }
        }
    }

    func navigateRootSelection(direction: Int, isRepeat: Bool) {
        let rootItems = rootListItems()
        let viewportHeight = menuViewportHeight()
        let rowOffsets = menuRowOffsets(for: rootItems)
        let contentHeight = menuContentHeight(for: rootItems, rowOffsets: rowOffsets)
        guard let nextIndex = resolvedNextNavigationIndex(
            direction: direction,
            key: direction > 0 ? .downArrow : .upArrow,
            isRepeat: isRepeat,
            currentIndex: selectedIndex,
            itemCount: rootItems.count,
            rowOffsets: rowOffsets,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
        ) else { return }

        DispatchQueue.main.async {
            selectedIndex = nextIndex
        }
    }

    func navigateSubmenuSelection(direction: Int, isRepeat: Bool) {
        let submenuItems = submenuListItems()
        let submenuCount = submenuItems.count
        let viewportHeight = activeMenuVirtualSceneSize.height - submenuSelectionBoxTopInset
        let selectionAnchorY: CGFloat = 0
        let submenuSelectionHeightScale: CGFloat = 1.0
        let dividerGap = effectiveDividerSectionGap(
            forSelectionBoxHeightScale: submenuSelectionHeightScale,
        )
        let rowPitch = submenuSelectionRowPitch
        let rowOffsets = menuRowOffsets(for: submenuItems, dividerGap: dividerGap, rowPitch: rowPitch)
        let contentHeight = menuContentHeight(
            for: submenuItems,
            rowOffsets: rowOffsets,
            rowHeight: submenuRowHeight,
        )
        guard let nextIndex = resolvedNextNavigationIndex(
            direction: direction,
            key: direction > 0 ? .downArrow : .upArrow,
            isRepeat: isRepeat,
            currentIndex: selectedSubIndex,
            itemCount: submenuCount,
            rowOffsets: rowOffsets,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            selectionAnchorY: selectionAnchorY,
        ) else { return }

        DispatchQueue.main.async {
            selectedSubIndex = nextIndex
            refreshDetailPreviewForCurrentContext()
        }
    }

    func navigateThirdMenuSelection(direction: Int, isRepeat: Bool) {
        if activeRootItemID == "photos", thirdMenuMode == .photosDateAlbums {
            let thirdMenuCount = photosDateAlbumMenuItems.count
            guard thirdMenuCount > 0 else { return }
            let key: KeyCode = direction > 0 ? .downArrow : .upArrow
            guard prepareNavigationTiming(for: key, isRepeat: isRepeat) else { return }
            let nextIndex = max(0, min(thirdMenuCount - 1, selectedThirdIndex + direction))
            guard nextIndex != selectedThirdIndex else {
                playLimitSoundOnceForCurrentHold()
                return
            }
            didPlayLimitForCurrentHold = false
            markSelectionAsMoving()
            playSound(named: "SelectionChange")

            DispatchQueue.main.async {
                selectedThirdIndex = nextIndex
                rememberCurrentMoviesFolderSelectionIndex()
            }
            return
        }
        let listItems = thirdMenuListItems()
        let thirdMenuCount = listItems.count
        let viewportHeight = activeMenuVirtualSceneSize.height - submenuSelectionBoxTopInset
        let selectionAnchorY: CGFloat = 0
        let submenuSelectionHeightScale: CGFloat = 1.0
        let dividerGap = effectiveDividerSectionGap(
            forSelectionBoxHeightScale: submenuSelectionHeightScale,
        )
        let rowPitch = submenuSelectionRowPitch
        let rowOffsets = menuRowOffsets(for: listItems, dividerGap: dividerGap, rowPitch: rowPitch)
        let contentHeight = menuContentHeight(for: listItems, rowOffsets: rowOffsets, rowHeight: submenuRowHeight)
        guard let nextIndex = resolvedNextNavigationIndex(
            direction: direction,
            key: direction > 0 ? .downArrow : .upArrow,
            isRepeat: isRepeat,
            currentIndex: selectedThirdIndex,
            itemCount: thirdMenuCount,
            rowOffsets: rowOffsets,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            selectionAnchorY: selectionAnchorY,
        ) else { return }

        DispatchQueue.main.async {
            selectedThirdIndex = nextIndex
            rememberCurrentMoviesFolderSelectionIndex()
            if !(activeRootItemID == "photos" && thirdMenuMode == .photosDateAlbums) {
                refreshDetailPreviewForCurrentContext()
            }
        }
    }

    func updateOverflowFadeVisibility(oldOffset: CGFloat, newOffset: CGFloat) {
        overflowFadeWorkItem?.cancel()
        let delta = newOffset - oldOffset
        let isScrolling = abs(delta) > 0.001
        guard isScrolling else {
            isMenuOverflowScrollingUp = false
            isMenuOverflowScrollingDown = false
            return
        }

        isMenuOverflowScrollingUp = true
        isMenuOverflowScrollingDown = true
        let workItem = DispatchWorkItem {
            isMenuOverflowScrollingUp = false
            isMenuOverflowScrollingDown = false
        }
        overflowFadeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + selectionAnimationDuration + 0.02,
            execute: workItem,
        )
    }

    func isDirectionalNavigationKey(_ key: KeyCode) -> Bool {
        key == .upArrow || key == .downArrow || key == .leftArrow || key == .rightArrow
    }

    func handleDirectionalPressBegan(
        _ key: KeyCode,
        modifiers: NSEvent.ModifierFlags = [],
    ) {
        guard !blocksMenuForStartupMusicLibraryPreload else { return }
        guard isDirectionalNavigationKey(key) else {
            handleKeyInput(key, isRepeat: false, modifiers: modifiers)
            return
        }
        if activeDirectionalHoldKey == key {
            return
        }
        endDirectionalHoldSession()
        activeDirectionalHoldKey = key
        directionalHoldPressStartTime = Date()
        handleKeyInput(key, isRepeat: false, modifiers: modifiers)
        let startWorkItem = DispatchWorkItem {
            guard activeDirectionalHoldKey == key else { return }
            directionalHoldRepeatPhaseStartTime = Date()
            scheduleDirectionalHoldTick(for: key, modifiers: modifiers)
        }
        directionalHoldStartWorkItem = startWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + directionalHoldInitialDelay,
            execute: startWorkItem,
        )
    }

    func scheduleDirectionalHoldTick(
        for key: KeyCode,
        modifiers: NSEvent.ModifierFlags = [],
    ) {
        guard activeDirectionalHoldKey == key else { return }
        let phaseStart = directionalHoldRepeatPhaseStartTime ?? Date()
        let elapsedInScrollingState = Date().timeIntervalSince(phaseStart)
        let totalHoldDuration = directionalHoldInitialDelay + elapsedInScrollingState
        let interval = minimumHoldRepeatInterval(for: totalHoldDuration)
        let tickWorkItem = DispatchWorkItem {
            guard activeDirectionalHoldKey == key else { return }
            handleKeyInput(key, isRepeat: true, modifiers: modifiers)
            scheduleDirectionalHoldTick(for: key, modifiers: modifiers)
        }
        directionalHoldTickWorkItem = tickWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: tickWorkItem)
    }

    func handleDirectionalPressEnded(_ key: KeyCode) {
        guard isDirectionalNavigationKey(key) else { return }
        guard activeDirectionalHoldKey == key else { return }
        endDirectionalHoldSession()
    }

    func endDirectionalHoldSession() {
        directionalHoldStartWorkItem?.cancel()
        directionalHoldTickWorkItem?.cancel()
        directionalHoldStartWorkItem = nil
        directionalHoldTickWorkItem = nil
        directionalHoldPressStartTime = nil
        directionalHoldRepeatPhaseStartTime = nil
        guard activeDirectionalHoldKey != .none else { return }
        activeDirectionalHoldKey = .none
        resetNavigationAccelerationState()
    }

    func minimumHoldRepeatInterval(for holdDuration: TimeInterval) -> TimeInterval {
        let accelerationProgress = thirdStageAccelerationProgress(for: holdDuration)
        return directionalHoldBaseRepeatInterval
            - ((directionalHoldBaseRepeatInterval - directionalHoldFastRepeatInterval) * accelerationProgress)
    }

    func thirdStageAccelerationProgress(for holdDuration: TimeInterval) -> Double {
        let thirdStageThreshold = directionalHoldInitialDelay + directionalHoldAccelerationDelay
        let rampDuration = max(0.001, directionalHoldAccelerationRampDuration)
        let raw = min(1, max(0, (holdDuration - thirdStageThreshold) / rampDuration))
        return raw * raw * (3 - (2 * raw))
    }

    func prepareNavigationTiming(for key: KeyCode, isRepeat: Bool) -> Bool {
        let now = Date()

        let isNowPlayingSongSwitch = thirdMenuMode == .musicNowPlaying && (key == .upArrow || key == .downArrow)
        if isNowPlayingSongSwitch {
            lastArrowNavigationInputTime = now
            lastHoldNavigationTime = now
            lastNavigationKey = key
            lastNavigationEventTime = now
            return true
        }

        let isManagedDirectionalHoldRepeat =
            isRepeat &&
            activeDirectionalHoldKey == key &&
            directionalHoldPressStartTime != nil
        if isManagedDirectionalHoldRepeat {
            let holdDuration = now.timeIntervalSince(directionalHoldPressStartTime ?? now)
            lastArrowNavigationInputTime = now
            lastHoldNavigationTime = now
            lastNavigationKey = key
            lastNavigationEventTime = now
            if navigationHoldStartTime == nil {
                navigationHoldStartTime = directionalHoldPressStartTime ?? now
            }
            useLinearSelectionSweepAnimation = holdDuration >= directionalHoldInitialDelay
            selectionAnimationDuration = selectionDuration(for: holdDuration)
            return true
        }

        if let lastTime = lastArrowNavigationInputTime,
           now.timeIntervalSince(lastTime) < arrowInputDebounceInterval
        {
            return false
        }

        if isRepeat {
            let estimatedHoldDuration = now.timeIntervalSince(navigationHoldStartTime ?? now)
            let minHoldRepeatInterval = minimumHoldRepeatInterval(for: estimatedHoldDuration)
            if let lastTime = lastHoldNavigationTime,
               now.timeIntervalSince(lastTime) < minHoldRepeatInterval
            {
                return false
            }
        }
        lastArrowNavigationInputTime = now
        lastHoldNavigationTime = now
        let holdDuration = updatedHoldDuration(for: key, at: now)
        useLinearSelectionSweepAnimation = isRepeat && holdDuration >= directionalHoldInitialDelay
        selectionAnimationDuration = selectionDuration(for: holdDuration)
        return true
    }

    func updatedHoldDuration(for key: KeyCode, at now: Date) -> TimeInterval {
        let continuationThreshold: TimeInterval = max(0.24, directionalHoldBaseRepeatInterval + 0.08)
        let isContinuingHold =
            lastNavigationKey == key &&
            (lastNavigationEventTime.map { now.timeIntervalSince($0) <= continuationThreshold } ?? false)
        if isContinuingHold {
            if navigationHoldStartTime == nil {
                navigationHoldStartTime = lastNavigationEventTime ?? now
            }
        } else {
            navigationHoldStartTime = now
            didPlayLimitForCurrentHold = false
        }
        lastNavigationKey = key
        lastNavigationEventTime = now
        return now.timeIntervalSince(navigationHoldStartTime ?? now)
    }

    func playLimitSoundOnceForCurrentHold() {
        if !didPlayLimitForCurrentHold {
            playSound(named: "Limit")
            didPlayLimitForCurrentHold = true
        }
    }

    func selectionDuration(for holdDuration: TimeInterval) -> Double {
        if holdDuration < directionalHoldInitialDelay {
            return 0.30
        }
        let interval = minimumHoldRepeatInterval(for: holdDuration)
        return interval * directionalHoldSweepOverlapFactor
    }

    func markSelectionAsMoving() {
        var instantStateChange = Transaction()
        instantStateChange.disablesAnimations = true
        withTransaction(instantStateChange) {
            isSelectionSettled = false
        }
        settleWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            isSelectionSettled = true
            if activeRootItemID == "photos", isInSubmenu {
                refreshPhotosForCurrentContext()
            }
        }
        settleWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + selectionAnimationDuration + 0.02,
            execute: workItem,
        )
    }

    func resetNavigationAccelerationState() {
        lastNavigationKey = .none
        navigationHoldStartTime = nil
        lastNavigationEventTime = nil
        didPlayLimitForCurrentHold = false
        useLinearSelectionSweepAnimation = false
        lastHoldNavigationTime = nil
        lastArrowNavigationInputTime = nil
    }

    func syncRootLabelWithSelection() {
        guard menuItems.indices.contains(selectedIndex) else { return }
        rootLabelSwapWorkItem?.cancel()
        rootLabelText = menuItems[selectedIndex].title
        rootLabelOpacity = (isRootIntroRunning || !hasStartedRootIntro || !isRootLabelVisible) ? 0 : 1
    }

    func cancelRootIntroWorkItems() {
        rootIntroStartWorkItem?.cancel()
        rootIntroStartWorkItem = nil
        rootLabelRevealWorkItem?.cancel()
        rootLabelRevealWorkItem = nil
        rootIntroCompletionWorkItem?.cancel()
        rootIntroCompletionWorkItem = nil
    }

    func transitionRootLabel(to title: String) {
        rootLabelSwapWorkItem?.cancel()
        withAnimation(.easeOut(duration: rootLabelFadeOutDuration)) {
            rootLabelOpacity = 0
        }
        let workItem = DispatchWorkItem {
            rootLabelText = title
            withAnimation(.easeIn(duration: rootLabelFadeInDuration)) {
                rootLabelOpacity = 1
            }
        }
        rootLabelSwapWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + rootLabelFadeOutDuration,
            execute: workItem,
        )
    }

    func startRootIntroIfNeeded() {
        guard !hasStartedRootIntro else { return }
        hasStartedRootIntro = true
        isRootExitRunning = false
        rootExitWorkItem?.cancel()
        rootExitWorkItem = nil
        cancelRootIntroWorkItems()
        introBackdropProgress = 0
        introProgress = 0
        isRootIntroRunning = true
        isRootLabelVisible = false
        rootLabelOpacity = 0
        DispatchQueue.main.async {
            if introBackdropImage == nil {
                introBackdropImage = captureBackdropImage()
            }
            let introCompletionTime = max(rootIntroDuration, rootIntroBackdropDuration)
            let labelRevealWorkItem = DispatchWorkItem {
                rootLabelRevealWorkItem = nil
                isRootLabelVisible = true
                withAnimation(.easeInOut(duration: rootIntroLabelFadeDuration)) {
                    rootLabelOpacity = 1
                }
            }
            rootLabelRevealWorkItem = labelRevealWorkItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + rootIntroAnimationStartDelay + rootIntroLabelStartDelay,
                execute: labelRevealWorkItem,
            )
            let introStartWorkItem = DispatchWorkItem {
                rootIntroStartWorkItem = nil
                playSound(named: "Begin")
                withAnimation(.timingCurve(0.45, 0.0, 0.34, 1.0, duration: rootIntroBackdropDuration)) {
                    introBackdropProgress = 1
                }
                withAnimation(.timingCurve(0.45, 0.0, 0.34, 1.0, duration: rootIntroDuration)) {
                    rootCarouselSelectionValue = Double(selectedIndex)
                    introProgress = 1
                }
            }
            rootIntroStartWorkItem = introStartWorkItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + rootIntroAnimationStartDelay,
                execute: introStartWorkItem,
            )
            let introCompletionWorkItem = DispatchWorkItem {
                rootIntroCompletionWorkItem = nil
                isRootExitRunning = false
                isRootIntroRunning = false
                isRootLabelVisible = true
                rootLabelOpacity = 1
            }
            rootIntroCompletionWorkItem = introCompletionWorkItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + rootIntroAnimationStartDelay + introCompletionTime,
                execute: introCompletionWorkItem,
            )
        }
    }

    func handleCommandEscapeRequested() {
        endDirectionalHoldSession()
        resetNavigationAccelerationState()
        guard !isRootExitRunning else { return }
        guard isRootVisible else {
            NotificationCenter.default.post(name: .firstRowQuitRequested, object: nil)
            return
        }

        isRootExitRunning = true
        isRootIntroRunning = true
        cancelRootIntroWorkItems()
        rootExitWorkItem?.cancel()
        rootExitWorkItem = nil
        rootLabelSwapWorkItem?.cancel()
        rootLabelSwapWorkItem = nil
        isRootLabelVisible = false
        rootLabelOpacity = 0

        if introBackdropImage == nil {
            introBackdropImage = captureBackdropImage()
        }

        SoundEffectPlayer.shared.play(named: "End")
        let exitSelectionValue = rootCarouselSelectionValue - 4

        withAnimation(.timingCurve(0.45, 0.0, 0.34, 1.0, duration: rootIntroBackdropDuration)) {
            introBackdropProgress = 0
        }
        withAnimation(.timingCurve(0.45, 0.0, 0.34, 1.0, duration: rootIntroDuration)) {
            rootCarouselSelectionValue = exitSelectionValue
            introProgress = 0
        }

        let exitDuration = max(rootIntroDuration, rootIntroBackdropDuration)
        let exitWorkItem = DispatchWorkItem {
            rootExitWorkItem = nil
            NotificationCenter.default.post(name: .firstRowTerminateRequested, object: nil)
        }
        rootExitWorkItem = exitWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + exitDuration, execute: exitWorkItem)
    }

    func currentMenuTransitionSnapshot() -> MenuTransitionSnapshot? {
        guard isInSubmenu || isEnteringSubmenu else { return nil }
        let items = isInThirdMenu ? thirdMenuListItems() : submenuListItems()
        let selectedIndex = isInThirdMenu ? selectedThirdIndex : selectedSubIndex
        return MenuTransitionSnapshot(
            rootID: activeRootItemID,
            headerText: headerText,
            items: items,
            selectedIndex: selectedIndex,
            isNowPlayingPage: isInThirdMenu && thirdMenuMode == .musicNowPlaying,
            isErrorPage: isInThirdMenu && thirdMenuMode == .errorPage,
            isSubmenuErrorPage: !isInThirdMenu && isSubmenuErrorPage,
            isMoviesFolderPage: isInThirdMenu && thirdMenuMode == .moviesFolder,
            isMovieResumePromptPage: isInThirdMenu && thirdMenuMode == .movieResumePrompt,
            isPhotosDateAlbumsPage: activeRootItemID == "photos",
            photosGapPreviewImage: activeRootItemID == "photos" ? photosGapPreviewImage : nil,
        )
    }

    func playSound(named fileName: String) {
        guard isUISoundEffectsEnabled else { return }
        if isMusicPlaybackRunning() {
            return
        }
        SoundEffectPlayer.shared.play(named: fileName)
    }

    func menuImage(forRootID rootID: String) -> NSImage? {
        MenuConfiguration.imageName(forRootID: rootID).flatMap { NSImage(named: $0) }
    }

    func showMoviePlaybackLoadingThen(_ action: @escaping () -> Void) {
        let requestID = incrementRequestID(&moviePlaybackLoadingRequestID)
        isMoviePlaybackLoading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard self.moviePlaybackLoadingRequestID == requestID else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                self.isMoviePlaybackLoading = false
            }
            action()
        }
    }
}

#if os(macOS)
    func captureBackdropImage(excludingWindowNumber: Int? = nil) -> NSImage? {
        let referenceWindow = NSApplication.shared.windows.first
        let frame = (referenceWindow?.screen ?? NSScreen.main)?.frame ?? NSScreen.main?.frame ?? .zero
        let excludedWindowNumber = excludingWindowNumber ?? referenceWindow?.windowNumber
        let cgImage: CGImage? = if let excludedWindowNumber {
            CGWindowListCreateImage(
                frame,
                .optionOnScreenBelowWindow,
                CGWindowID(excludedWindowNumber),
                [.boundsIgnoreFraming, .bestResolution],
            ) ?? CGDisplayCreateImage(CGMainDisplayID())
        } else {
            CGDisplayCreateImage(CGMainDisplayID())
        }

        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: frame.size)
    }
#else
    func captureBackdropImage(excludingWindowNumber _: Int? = nil) -> NSImage? {
        nil
    }
#endif
