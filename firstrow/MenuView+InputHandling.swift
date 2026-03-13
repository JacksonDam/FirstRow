import AVFoundation
import AVKit
import SwiftUI
#if canImport(iTunesLibrary)
    import iTunesLibrary
#endif
import Darwin

extension MenuView {
    func handleKeyInput(_ key: KeyCode, isRepeat: Bool, modifiers: NSEvent.ModifierFlags = []) {
        let commandPressed = modifiers.contains(.command)
        if key == .escape, commandPressed {
            NotificationCenter.default.post(name: .firstRowQuitRequested, object: nil)
            return
        }
        registerUserInteractionForScreenSaver()
        if isFullscreenSceneTransitioning {
            return
        }
        if isMovieResumePromptVisible {
            handleMovieResumePromptInput(key, isRepeat: isRepeat)
            return
        }
        if isMenuFolderSwapTransitioning {
            return
        }
        if let activeFullscreenScene {
            if activeFullscreenScene.key == musicNowPlayingFullscreenKey {
                handleMusicPlaybackInput(key, isRepeat: isRepeat)
                return
            }
            if activeFullscreenScene.key == photoSlideshowFullscreenKey {
                handlePhotoSlideshowInput(key, isRepeat: isRepeat)
                return
            }
            if activeFullscreenScene.key == screenSaverFullscreenKey {
                handleScreenSaverInput(key, isRepeat: isRepeat)
                return
            }
            if key == .delete || key == .escape {
                dismissFullscreenScene()
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
        switch key {
        case .downArrow:
            guard !isEnteringSubmenu else { return }
            if isInThirdMenu {
                navigateThirdMenuSelection(direction: 1, isRepeat: isRepeat)
            } else if isInSubmenu {
                navigateSubmenuSelection(direction: 1, isRepeat: isRepeat)
            } else {
                navigateRootSelection(direction: 1, isRepeat: isRepeat)
            }
        case .upArrow:
            guard !isEnteringSubmenu else { return }
            if isInThirdMenu {
                navigateThirdMenuSelection(direction: -1, isRepeat: isRepeat)
            } else if isInSubmenu {
                navigateSubmenuSelection(direction: -1, isRepeat: isRepeat)
            } else {
                navigateRootSelection(direction: -1, isRepeat: isRepeat)
            }
        case .leftArrow:
            if handleTVShowsSortInput(direction: -1) {
                return
            }
            resetNavigationAccelerationState()
        case .rightArrow:
            if handleTVShowsSortInput(direction: 1) {
                return
            }
            resetNavigationAccelerationState()
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

    @discardableResult
    func handleTVShowsSortInput(direction: Int) -> Bool {
        guard activeRootItemID == "tv_shows", isInSubmenu, !isInThirdMenu else { return false }
        let nextMode: TVShowsSortMode = direction < 0 ? .date : .show
        guard nextMode != tvShowsSortMode else {
            return true
        }
        tvShowsSortMode = nextMode
        playSound(named: "SelectionChange")
        return true
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
        if chosenRootItem.id == "podcasts" {
            handlePodcastsRootMenuSelection(chosenRootItem)
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
        activePodcastSeriesID = nil
        podcastEpisodesThirdMenuItems = []
        hasPresentedNoPodcastsErrorInCurrentSession = false
        activeRootItemID = chosenRootItem.id
        if chosenRootItem.id == "tv_shows" {
            tvShowsSortMode = .show
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
        submenuTitleOpacity = 0
        submenuOpacity = 0
        detailContentOpacity = 0
        withAnimation(.easeInOut(duration: 0.32)) {
            rootMenuOpacity = 0
            headerOpacity = 0
        }
        if playSelectionSound {
            playSound(named: "Selection")
        }
        let entryWorkItem = DispatchWorkItem {
            guard isEnteringSubmenu, isIconAnimated, !isReturningToRoot else { return }
            headerText = chosenRootItem.title
            isInSubmenu = true
            isEnteringSubmenu = false
            if chosenRootItem.id == "podcasts" {
                requestPodcastsLibraryLoadIfNeeded()
            }
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
            deadline: .now() + iconFlightAnimationDuration + iconFlightHandoffPadding,
            execute: entryWorkItem,
        )
    }

    func returnToRootMenu(playExitSound: Bool = true) {
        guard isInSubmenu || isEnteringSubmenu else { return }
        guard !isReturningToRoot else { return }
        let submenuExitFadeDuration = 0.18
        let backgroundIconReturnDuration = 0.32
        let rootRevealDelay = max(iconFlightAnimationDuration, submenuExitFadeDuration + backgroundIconReturnDuration)
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
        let shouldStopPodcastAudioAfterExitFade =
            activeRootItemID == "podcasts" && isPodcastAudioNowPlaying
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

        DispatchQueue.main.async {
            isIconAnimated = false
        }
        withAnimation(.easeInOut(duration: submenuExitFadeDuration)) {
            submenuTitleOpacity = 0
            submenuOpacity = 0
            detailContentOpacity = 0
            headerOpacity = 0
        }
        if playExitSound {
            playSound(named: "Exit")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + submenuExitFadeDuration) {
            withAnimation(.easeInOut(duration: backgroundIconReturnDuration)) {
                isEnteringSubmenu = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + rootRevealDelay) {
            if shouldStopPodcastAudioAfterExitFade {
                stopMusicPlaybackSession(clearDisplayState: true)
            }
            holdNowPlayingMenuItemDuringExitFade = false
            isInThirdMenu = false
            thirdMenuMode = .none
            thirdMenuOpacity = 0
            resetThirdMenuDirectoryState()
            resetAllITunesTopMenusForNonITunesContext()
            moviePreviewTargetURL = nil
            moviePreviewImage = nil
            moviesFolderSubmenuPreviewDescriptors = []
            moviesFolderSubmenuPreviewIdentity = ""
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
            activePodcastSeriesID = nil
            podcastEpisodesThirdMenuItems = []
            hasPresentedNoPodcastsErrorInCurrentSession = false
            headerText = "First Row"
            isInSubmenu = false
            activeRootItemID = nil
            withAnimation(.easeInOut(duration: 0.32)) {
                rootMenuOpacity = 1
                headerOpacity = 1
                isReturningToRoot = false
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
            clearMusicSongSwitchTransitionState()
            playSound(named: "Selection")
            presentFullscreenScene(key: musicNowPlayingFullscreenKey)
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
            presentTheatricalTrailersLoadingThenError()
            return
        }
        if activeRootItemID == "tv_shows", item.id == "tv_itunestopepisodes" {
            playSound(named: "Selection")
            enterITunesTopMenu(.tvEpisodes, title: item.title)
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
        if activeRootItemID == "sources", item.id == "sources_this_device" {
            playSound(named: "Selection")
            returnToRootMenuViaBlackFade()
            return
        }
        if activeRootItemID == "podcasts", item.id == podcastsNowPlayingSubmenuItemID {
            guard isPodcastAudioNowPlaying else { return }
            musicNowPlayingTrackPositionText = podcastTrackPositionText(
                forEpisodeID: activePodcastPlaybackEpisodeID,
                inSeriesID: activePodcastPlaybackSeriesID,
            )
            clearMusicSongSwitchTransitionState()
            playSound(named: "Selection")
            presentFullscreenScene(key: musicNowPlayingFullscreenKey)
            return
        }
        if activeRootItemID == "podcasts", let series = podcastSeriesForSubmenuItemID(item.id) {
            guard !series.episodes.isEmpty else {
                playLimitSoundOnceForCurrentHold()
                return
            }
            playSound(named: "Selection")
            enterPodcastEpisodesMenu(for: series)
            return
        }
        if activeRootItemID == "podcasts" {
            if item.id == "podcasts_error" {
                requestPodcastsLibraryLoadIfNeeded(force: true)
            } else {
                playLimitSoundOnceForCurrentHold()
            }
            return
        }
        if activeRootItemID == "settings", item.id == "settings_soundeffects" {
            isUISoundEffectsEnabled.toggle()
            playSound(named: "Selection")
            return
        }
        if activeRootItemID == "settings", item.id == "settings_screensaver" {
            isScreenSaverEnabled.toggle()
            playSound(named: "Selection")
            return
        }
        playSound(named: "Selection")
        performSubmenuAction(item)
    }

    func triggerThirdMenuAction() {
        playSound(named: "Selection")
        switch thirdMenuMode {
        case .moviesFolder:
            guard thirdMenuItems.indices.contains(selectedThirdIndex) else { return }
            let item = thirdMenuItems[selectedThirdIndex]
            if item.isDirectory {
                requestMoviesFolderDirectoryOpenIfNotEmpty(item)
            } else {
                startMoviePlayback(from: item.url)
            }
        case .moviesITunesTop:
            startSelectedITunesTopThirdMenuItemPlayback(for: .movies)
            return
        case .tvITunesTopEpisodes:
            startSelectedITunesTopThirdMenuItemPlayback(for: .tvEpisodes)
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
                clearMusicSongSwitchTransitionState()
                presentFullscreenScene(key: musicNowPlayingFullscreenKey)
            } else {
                startPlaybackForMusicLibraryEntry(
                    song,
                    trackIndex: songIndex,
                    trackCount: musicSongsThirdMenuItems.count,
                )
            }
        case .photosDateAlbums:
            guard photosDateAlbums.indices.contains(selectedThirdIndex) else { return }
            let album = photosDateAlbums[selectedThirdIndex]
            guard album.isPlayable else { return }
            startPhotoAlbumSlideshow(for: album)
        case .podcastsEpisodes:
            guard podcastEpisodesThirdMenuItems.indices.contains(selectedThirdIndex) else { return }
            let episode = podcastEpisodesThirdMenuItems[selectedThirdIndex]
            guard episode.mediaURL != nil else {
                playLimitSoundOnceForCurrentHold()
                return
            }
            if isPodcastAudioNowPlaying, activePodcastPlaybackEpisodeID == episode.id {
                musicNowPlayingTrackPositionText = podcastTrackPositionText(
                    forEpisodeID: episode.id,
                    inSeriesID: episode.seriesID,
                )
                clearMusicSongSwitchTransitionState()
                presentFullscreenScene(key: musicNowPlayingFullscreenKey)
                return
            }
            startPodcastEpisodePlayback(episode)
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
        case .tvEpisodes:
            guard iTunesTopTVEpisodes.indices.contains(selectedThirdIndex) else { return }
            startITunesTopTVEpisodePreviewPlayback(for: iTunesTopTVEpisodes[selectedThirdIndex])
        case .songs:
            guard iTunesTopSongs.indices.contains(selectedThirdIndex) else { return }
            let selectedSong = iTunesTopSongs[selectedThirdIndex]
            if activeMusicPlaybackSongID == selectedSong.id, hasActiveMusicPlaybackSession() {
                musicNowPlayingTrackPositionText = "1 of 1"
                musicNowPlayingShowsShuffleGlyph = false
                clearMusicSongSwitchTransitionState()
                presentFullscreenScene(key: musicNowPlayingFullscreenKey)
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
        playSound(named: "Selection")
        MenuConfiguration.performRootAction(for: item)
    }

    func performSubmenuAction(_ item: SubmenuItemConfig) {
        MenuConfiguration.performSubmenuAction(for: item)
    }

    func resolvedNextNavigationIndex(
        direction: Int,
        isRepeat: Bool,
        currentIndex: Int,
        itemCount: Int,
        rowOffsets: [CGFloat],
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        guard prepareNavigationTiming(direction: direction, isRepeat: isRepeat) else { return nil }
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
        )
        let newScrollOffset = menuScrollOffset(
            contentHeight: contentHeight,
            selectedIndex: nextIndex,
            rowOffsets: rowOffsets,
            viewportHeight: viewportHeight,
        )
        updateOverflowFadeVisibility(oldOffset: oldScrollOffset, newOffset: newScrollOffset)
        didPlayLimitForCurrentHold = false
        markSelectionAsMoving()
        playSound(named: "SelectionChange")
        return nextIndex
    }

    func navigateRootSelection(direction: Int, isRepeat: Bool) {
        let rootItems = rootListItems()
        let viewportHeight = menuViewportHeight()
        let rowOffsets = menuRowOffsets(for: rootItems)
        let contentHeight = menuContentHeight(for: rootItems, rowOffsets: rowOffsets)
        guard let nextIndex = resolvedNextNavigationIndex(
            direction: direction,
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
        let viewportHeight = menuViewportHeight()
        let submenuSelectionHeightScale = activeRootItemID == "photos" ? photosSelectionBoxHeightScale : 1.0
        let dividerGap = effectiveDividerSectionGap(
            forSelectionBoxHeightScale: submenuSelectionHeightScale,
        )
        let rowPitch = effectiveRowPitch(
            forSelectionBoxHeightScale: submenuSelectionHeightScale,
        )
        let rowOffsets = menuRowOffsets(for: submenuItems, dividerGap: dividerGap, rowPitch: rowPitch)
        let contentHeight = menuContentHeight(
            for: submenuItems,
            rowOffsets: rowOffsets,
            rowHeight: selectionBoxHeight * max(1, submenuSelectionHeightScale),
        )
        guard let nextIndex = resolvedNextNavigationIndex(
            direction: direction,
            isRepeat: isRepeat,
            currentIndex: selectedSubIndex,
            itemCount: submenuCount,
            rowOffsets: rowOffsets,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
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
            guard prepareNavigationTiming(direction: direction, isRepeat: isRepeat) else { return }
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
        let viewportHeight = menuViewportHeight()
        let rowOffsets = menuRowOffsets(for: listItems)
        let contentHeight = menuContentHeight(for: listItems, rowOffsets: rowOffsets)
        guard let nextIndex = resolvedNextNavigationIndex(
            direction: direction,
            isRepeat: isRepeat,
            currentIndex: selectedThirdIndex,
            itemCount: thirdMenuCount,
            rowOffsets: rowOffsets,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
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

    func prepareNavigationTiming(direction: Int, isRepeat: Bool) -> Bool {
        let now = Date()
        let keyForDirection: KeyCode = direction > 0 ? .downArrow : .upArrow
        let isManagedDirectionalHoldRepeat =
            isRepeat &&
            activeDirectionalHoldKey == keyForDirection &&
            directionalHoldPressStartTime != nil
        if isManagedDirectionalHoldRepeat {
            let holdDuration = now.timeIntervalSince(directionalHoldPressStartTime ?? now)
            lastArrowNavigationInputTime = now
            lastHoldNavigationTime = now
            lastNavigationKey = keyForDirection
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
        let holdDuration = updatedHoldDuration(for: keyForDirection, at: now)
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
}
