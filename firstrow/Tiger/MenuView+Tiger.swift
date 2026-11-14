import Foundation
import QuartzCore
#if os(macOS)
    import AppKit
#endif

/// What the Tiger look keeps of its own beside the menus' state: the ring's turn, how far a
/// section has opened, the title under the ring, and the page that is being held while the
/// next one gets ready.
struct TigerMenuState {
    /// Which section the ring has in front, counted in sections (it keeps counting as it turns).
    var ring = TigerMovingValue(Double(TigerMenuState.openingRootIndex - TigerMenus.features.count))
    /// The opening: 0 with the ring still below the screen, 1 once it has risen into place.
    var intro = TigerMovingValue(0)
    /// The desktop's picture drawing back as First Row opens (0 full screen, 1 gone).
    var introBackdrop = TigerMovingValue(0)
    /// How far a section has opened from the ring (0 the ring, 1 the section's page).
    var section = TigerMovingValue(0)
    /// How far the section's icon has flown from the ring to its place beside the title.
    var flight = TigerMovingValue(0)

    var isIntroRunning = true
    var isExitRunning = false
    var hasStartedIntro = false
    var introBackdropImage: NSImage?

    var rootLabelText = ""
    var rootLabelOpacity: Double = 0
    var isRootLabelVisible = false

    /// The page on screen stays as it is while the next one gets ready (its list being read, say).
    var holdsPage = false
    /// A section with nothing to list says so on its page (DVD, with no disc in).
    var sectionMessage: TigerMessage?
    /// The row that is getting something ready shows a spinner meanwhile.
    var isLoadingTrailers = false
    var isStartingMovie = false
    /// The movie's picture has come up behind the question about where to start it.
    var showsResumeBackdrop = false
    var resumeRequestID = 0
    /// The Photos preview has slid in beside the list.
    var isPhotosPreviewIn = false
    /// The cover of the album that is chosen in Photos, once it has been read.
    var photosPreviewImage: NSImage?
    var photosPreviewAlbumID: String?
    var photosPreviewRequestID = 0

    var trailersRequestID = 0
    var movieStartRequestID = 0
    var labelSwapTask: Task<Void, Never>?
    var introTasks: [Task<Void, Never>] = []
    var exitTask: Task<Void, Never>?
    /// Until when keys are left alone because a page is sliding across.
    var pageSlideEnd: CFTimeInterval = 0

    static var openingRootIndex: Int {
        TigerMenus.features.firstIndex { $0.rootItem.id == "music" } ?? 0
    }
}

struct TigerMessage: Equatable {
    var header: String
    var subcaption: String
}

/// One page of a section, as the Tiger look draws it: a title, and under it a list, the song
/// that is playing, or a message.
struct TigerPage {
    enum Content {
        case list
        case nowPlaying
        case message(TigerMessage)
    }

    /// Two pages with the same key are the same page, redrawn in place; a change of key slides
    /// the new page in.
    var key: String
    /// How far down the menus the page is, to tell going in from coming back.
    var depth: Int
    var rootID: String?
    var title: String
    var content: Content
    var items: [MenuListItemConfig] = []
    var selectedIndex = 0
    /// A preview stands to the left of the list, which is narrower for it.
    var isCompact = false
    var showsMoviePreview = false
    var showsPhotosPreview = false
    var isPodcastEpisodes = false
}

extension MenuView {
    // MARK: - Starting up

    /// The ring opens on Music.
    func tigerPrepare() {
        guard TigerTheme.isActive else { return }
        selectedIndex = TigerMenuState.openingRootIndex
        tiger.rootLabelText = menuItems.indices.contains(selectedIndex) ? menuItems[selectedIndex].title : ""
    }

    /// Called once the menus are on screen: the ring rises into place as the desktop draws back.
    func tigerStart(backdrop: NSImage?, skipsOpening: Bool) {
        SoundEffectPlayer.shared.warmUp(soundNames: TigerTheme.soundNames)
        guard !tiger.hasStartedIntro else { return }
        tiger.hasStartedIntro = true
        tiger.isExitRunning = false
        tigerCancelIntroTasks()
        if skipsOpening {
            tiger.ring.set(Double(selectedIndex))
            tiger.intro.set(1)
            tiger.introBackdrop.set(1)
            tiger.isIntroRunning = false
            tiger.isRootLabelVisible = true
            tiger.rootLabelOpacity = 1
            return
        }
        tiger.introBackdropImage = backdrop
        tiger.introBackdrop.set(0)
        tiger.intro.set(0)
        tiger.isIntroRunning = true
        tiger.isRootLabelVisible = false
        tiger.rootLabelOpacity = 0
        let completion = max(TigerTheme.introDuration, TigerTheme.introBackdropDuration)
        tiger.introTasks.append(Task {
            try? await firstRowSleep(TigerTheme.introStartDelay + TigerTheme.introLabelStartDelay)
            guard !Task.isCancelled else { return }
            self.tiger.isRootLabelVisible = true
            withAnimation(.easeInOut(duration: TigerTheme.introLabelFadeDuration)) {
                self.tiger.rootLabelOpacity = 1
            }
        })
        tiger.introTasks.append(Task {
            try? await firstRowSleep(TigerTheme.introStartDelay)
            guard !Task.isCancelled else { return }
            self.playSound(named: "Begin")
            self.tiger.introBackdrop.move(to: 1, duration: TigerTheme.introBackdropDuration, curve: TigerTheme.introCurve)
            self.tiger.ring.move(to: Double(self.selectedIndex), duration: TigerTheme.introDuration, curve: TigerTheme.introCurve)
            self.tiger.intro.move(to: 1, duration: TigerTheme.introDuration, curve: TigerTheme.introCurve)
        })
        tiger.introTasks.append(Task {
            try? await firstRowSleep(TigerTheme.introStartDelay + completion)
            guard !Task.isCancelled else { return }
            self.tiger.isExitRunning = false
            self.tiger.isIntroRunning = false
            self.tiger.isRootLabelVisible = true
            self.tiger.rootLabelOpacity = 1
        })
    }

    private func tigerCancelIntroTasks() {
        tiger.introTasks.forEach { $0.cancel() }
        tiger.introTasks.removeAll()
    }

    /// The ring alone is on screen (no section open or opening).
    var tigerIsRootVisible: Bool {
        !isInSubmenu && !isEnteringSubmenu && !isReturningToRoot
    }

    /// Quitting from the ring plays the opening backwards: the ring sinks away as the desktop
    /// comes back. Returns false anywhere else, where First Row fades out as ever.
    func tigerBeginExit(then finish: @escaping () -> Void) -> Bool {
        guard TigerTheme.isActive, tigerIsRootVisible, activeFullscreenScene == nil, !isMoviePlaybackVisible else { return false }
        guard !tiger.isExitRunning else { return true }
        endDirectionalHoldSession()
        resetNavigationAccelerationState()
        tiger.isExitRunning = true
        tiger.isIntroRunning = true
        tigerCancelIntroTasks()
        tiger.labelSwapTask?.cancel()
        tiger.isRootLabelVisible = false
        tiger.rootLabelOpacity = 0
        if isUISoundEffectsEnabled {
            SoundEffectPlayer.shared.play(named: "End")
        }
        tiger.introBackdrop.move(to: 0, duration: TigerTheme.introBackdropDuration, curve: TigerTheme.introCurve)
        tiger.ring.move(to: tiger.ring.target - Double(max(1, menuItems.count)), duration: TigerTheme.introDuration, curve: TigerTheme.introCurve)
        tiger.intro.move(to: 0, duration: TigerTheme.introDuration, curve: TigerTheme.introCurve)
        tiger.exitTask = Task {
            try? await firstRowSleep(max(TigerTheme.introDuration, TigerTheme.introBackdropDuration))
            guard !Task.isCancelled else { return }
            finish()
        }
        return true
    }

    // MARK: - Keys

    /// The keys the Tiger look answers its own way. Returns false for the rest, which the
    /// menus take as ever.
    func tigerHandleKeyInput(_ key: KeyCode, isRepeat: Bool) -> Bool {
        if tiger.isExitRunning { return true }
        // A page still sliding across isn't acted on.
        if CACurrentMediaTime() < tiger.pageSlideEnd || tiger.holdsPage { return true }
        if let scene = activeFullscreenScene {
            if isFullscreenSceneTransitioning { return true }
            if scene.key == musicNowPlayingFullscreenKey {
                tigerHandleNowPlayingKey(key, isRepeat: isRepeat)
                return true
            }
            return false
        }
        if isMovieResumePromptVisible || isMovieTransitioning || isMoviePlaybackVisible || isMenuFolderSwapTransitioning { return false }
        if isReturningToRoot { return true }
        guard !isInSubmenu, !isInThirdMenu else {
            // In a section's lists Left and Right do nothing, and the rest is the menus'.
            return false
        }
        // The ring.
        if tiger.isIntroRunning, !isEnteringSubmenu { return true }
        switch key {
        case .leftArrow where !isEnteringSubmenu:
            tigerTurnRing(by: -1, isRepeat: isRepeat)
            return true
        case .rightArrow where !isEnteringSubmenu:
            tigerTurnRing(by: 1, isRepeat: isRepeat)
            return true
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            resetNavigationAccelerationState()
            return true
        default:
            return false
        }
    }

    /// Now Playing as a page: Back leaves it (the song plays on), Up and Down change the song,
    /// Left and Right move through it, Space pauses.
    private func tigerHandleNowPlayingKey(_ key: KeyCode, isRepeat: Bool) {
        hidesMusicLeadingGlyph = false
        switch key {
        case .delete, .escape:
            stopMusicScrubbing(showPauseGlyph: false)
            clearMusicSongSwitchTransitionState()
            dismissFullscreenScene(preserveMusicPlayback: true)
            playSound(named: "Exit")
        case .space:
            handleMusicSpacebarPressed()
        case .upArrow:
            switchMusicNowPlayingTrack(direction: -1)
        case .downArrow:
            switchMusicNowPlayingTrack(direction: 1)
        case .leftArrow:
            beginMusicScrubbing(direction: -1, isRepeat: isRepeat)
        case .rightArrow:
            beginMusicScrubbing(direction: 1, isRepeat: isRepeat)
        default:
            break
        }
    }

    private func tigerTurnRing(by direction: Int, isRepeat: Bool) {
        guard !menuItems.isEmpty else { return }
        guard prepareNavigationTiming(direction: direction, isRepeat: isRepeat) else { return }
        let next = (selectedIndex + direction + menuItems.count) % menuItems.count
        didPlayLimitForCurrentHold = false
        markSelectionAsMoving()
        playSound(named: "MainLeft")
        tigerChangeRootLabel(to: menuItems[next].title)
        selectedIndex = next
        tiger.ring.move(to: tiger.ring.target + Double(direction), duration: selectionAnimationDuration * TigerTheme.ringTurnDurationMultiplier)
    }

    /// The title under the ring fades out, changes, and fades back in.
    private func tigerChangeRootLabel(to title: String) {
        tiger.labelSwapTask?.cancel()
        withAnimation(.easeOut(duration: TigerTheme.labelFadeOutDuration)) {
            tiger.rootLabelOpacity = 0
        }
        tiger.labelSwapTask = Task {
            try? await firstRowSleep(TigerTheme.labelFadeOutDuration)
            guard !Task.isCancelled else { return }
            self.tiger.rootLabelText = title
            withAnimation(.easeIn(duration: TigerTheme.labelFadeInDuration)) {
                self.tiger.rootLabelOpacity = 1
            }
        }
    }

    // MARK: - Opening and closing a section

    /// A section starts to open from the ring: its icon flies up to the title bar as the other
    /// three draw back, and its page rises with the bar's line.
    func tigerSectionWillOpen(_ rootItem: RootMenuItemConfig) {
        tiger.sectionMessage = nil
        tiger.isLoadingTrailers = false
        tiger.trailersRequestID &+= 1
        tiger.isStartingMovie = false
        tiger.movieStartRequestID &+= 1
        if rootItem.id == "dvd" {
            tiger.sectionMessage = TigerMessage(header: L("Please Insert a DVD"), subcaption: "")
        }
        tiger.labelSwapTask?.cancel()
        tiger.rootLabelText = rootItem.title
        tiger.rootLabelOpacity = 1
        tiger.section.set(0)
        tiger.flight.set(0)
        tiger.section.move(to: 1, duration: TigerTheme.iconFlightDuration)
        tiger.flight.move(to: 1, duration: TigerTheme.iconFlightDuration)
        if rootItem.id == "photos" {
            tiger.isPhotosPreviewIn = false
            withAnimation(.easeInOut(duration: 1.0)) {
                tiger.isPhotosPreviewIn = true
            }
        }
    }

    /// The way back to the ring starts.
    func tigerSectionWillClose() {
        tiger.isLoadingTrailers = false
        tiger.trailersRequestID &+= 1
        tiger.isStartingMovie = false
        tiger.movieStartRequestID &+= 1
        tiger.holdsPage = false
        if activeRootItemID == "photos" {
            withAnimation(.easeInOut(duration: 0.85)) {
                tiger.isPhotosPreviewIn = false
            }
        }
        tiger.section.move(to: 0, duration: TigerTheme.backgroundIconReturnDuration)
        tiger.flight.move(to: 0, duration: TigerTheme.iconFlightDuration)
    }

    /// Back at the ring.
    func tigerSectionDidClose() {
        tiger.sectionMessage = nil
        tiger.section.set(0)
        tiger.flight.set(0)
        tiger.isPhotosPreviewIn = false
        tiger.photosPreviewRequestID &+= 1
        tiger.photosPreviewAlbumID = nil
        tiger.photosPreviewImage = nil
        tiger.labelSwapTask?.cancel()
        if menuItems.indices.contains(selectedIndex) {
            tiger.rootLabelText = menuItems[selectedIndex].title
        }
        tiger.isRootLabelVisible = true
        tiger.rootLabelOpacity = 1
    }

    // MARK: - Pages

    /// Changes the menus and slides the new page in: from the right going deeper, from the
    /// left coming back. The page on screen stays put until the new one has what it shows.
    func swapTigerMenu(revealWhen: @escaping () -> Bool, maxRevealWait: TimeInterval, _ update: @escaping () -> Void) {
        isMenuFolderSwapTransitioning = true
        tiger.holdsPage = true
        withTransaction(.instant) {
            update()
        }
        let deadline = Date().addingTimeInterval(max(0, maxRevealWait))
        Task { @MainActor in
            await Task.yield()
            try? await firstRowSleep(0.02)
            while self.isMenuFolderSwapTransitioning, self.tiger.holdsPage, !revealWhen(), Date() < deadline {
                try? await firstRowSleep(0.05)
            }
            guard self.isMenuFolderSwapTransitioning, self.tiger.holdsPage else {
                // (Something else took over: a message's page, or Now Playing.)
                self.tiger.holdsPage = false
                return
            }
            self.tiger.holdsPage = false
            try? await firstRowSleep(TigerTheme.pageSlideDuration)
            self.isMenuFolderSwapTransitioning = false
        }
    }

    /// Now Playing and the screens that say something couldn't be done are pages of the
    /// section they are reached from, not screens of their own.
    func tigerIsPageScene(_ key: String?) -> Bool {
        TigerTheme.isActive && isInSubmenu && (key == musicNowPlayingFullscreenKey || key == featureErrorFullscreenKey)
    }

    func presentTigerPageScene(key: String, payload: [String: String]) {
        guard activeFullscreenScene == nil else { return }
        guard !isMovieTransitioning, !isMoviePlaybackVisible else { return }
        if key == musicNowPlayingFullscreenKey {
            clearMusicSongSwitchTransitionState()
            resetNowPlayingExtras()
            revealDeferredNowPlayingMenuItemIfNeeded()
        }
        // (A page that was being held for its list gives way to this one.)
        isMenuFolderSwapTransitioning = false
        tiger.holdsPage = false
        isFullscreenSceneTransitioning = true
        withTransaction(.instant) {
            activeFullscreenScene = FullscreenScenePresentation(key: key, payload: payload)
            fullscreenSceneOpacity = 0
            fullscreenTransitionOverlayOpacity = 0
            menuFolderSwapOverlayOpacity = 0
            menuSceneOpacity = 1
        }
        Task {
            try? await firstRowSleep(TigerTheme.pageSlideDuration)
            self.isFullscreenSceneTransitioning = false
        }
    }

    func dismissTigerPageScene(preserveMusicPlayback: Bool) {
        guard let dismissedKey = activeFullscreenScene?.key else { return }
        guard !isFullscreenSceneTransitioning else { return }
        let keepsMusic = preserveMusicPlayback && dismissedKey == musicNowPlayingFullscreenKey
        if dismissedKey == musicNowPlayingFullscreenKey {
            clearMusicSongSwitchTransitionState()
            if !keepsMusic {
                stopMusicPlaybackSession(clearDisplayState: false)
            }
        }
        isFullscreenSceneTransitioning = true
        withTransaction(.instant) {
            activeFullscreenScene = nil
        }
        Task {
            try? await firstRowSleep(TigerTheme.pageSlideDuration)
            if dismissedKey == self.musicNowPlayingFullscreenKey, !keepsMusic {
                self.clearMusicNowPlayingDisplayState()
            }
            self.isFullscreenSceneTransitioning = false
        }
    }

    // MARK: - The sections' lists

    func tigerSubmenuItems() -> [SubmenuItemConfig] {
        guard let activeRootItemID else { return [] }
        var items = MenuConfiguration.submenuItems(forRootID: activeRootItemID)
        if activeRootItemID == "music", shouldExposeMusicNowPlayingMenuItem {
            items.insert(SubmenuItemConfig(id: "music_now_playing", title: L("Now Playing"), actionID: "music_now_playing", leadsToMenu: true), at: 0)
        }
        return items
    }

    /// The rows of a section's own list that only the Tiger look has. Returns false for a
    /// row the menus know.
    func tigerTriggerSubmenuItem(_ item: SubmenuItemConfig) -> Bool {
        switch (activeRootItemID, item.id) {
        case ("movies", "movies_shared_videos"), ("music", "music_shared"):
            // (Nothing is shared with First Row; the row is there as it always was.)
            playSound(named: "Selection")
            return true
        case ("movies", "movies_theatrical_trailers"):
            playSound(named: "Selection")
            tigerLoadTrailers()
            return true
        case ("movies", "movies_itunes_top_music_videos"):
            playSound(named: "Selection")
            enterITunesTopMenu(.musicVideos, title: item.title)
            return true
        case ("movies", "movies_itunes_top_tv_episodes"):
            playSound(named: "Selection")
            enterITunesTopMenu(.tvEpisodes, title: item.title)
            return true
        case ("photos", "photos_last_12_months"), ("photos", "photos_last_roll"):
            guard let album = tigerPhotoAlbum(forSubmenuItemID: item.id), album.isPlayable else {
                playLimitSoundOnceForCurrentHold()
                return true
            }
            playSound(named: "Selection")
            startPhotoAlbumSlideshow(for: album)
            return true
        default:
            return false
        }
    }

    /// (There is no last roll of film to show: its row is there as it always was.)
    func tigerPhotoAlbum(forSubmenuItemID id: String) -> PhotoLibraryAlbumEntry? {
        id == "photos_last_12_months" ? photosLastTwelveMonthsAlbum : nil
    }

    /// Movie Trailers turns for a moment and then says it couldn't be done: there is nowhere
    /// left to get them from.
    private func tigerLoadTrailers() {
        guard !tiger.isLoadingTrailers else { return }
        tiger.trailersRequestID &+= 1
        let requestID = tiger.trailersRequestID
        tiger.isLoadingTrailers = true
        Task {
            try? await firstRowSleep(0.5)
            guard !Task.isCancelled, self.tiger.trailersRequestID == requestID else { return }
            withTransaction(.instant) {
                self.tiger.isLoadingTrailers = false
            }
            self.presentFullscreenScene(key: self.featureErrorFullscreenKey, payload: [
                "header": L("First Row cannot complete this request."),
                "subcaption": "",
            ])
        }
    }

    // MARK: - Movies

    /// A movie chosen in a list turns for a moment before it starts. Returns false for
    /// anything else, which the menus act on as ever.
    func tigerTriggerThirdMenuItem() -> Bool {
        guard thirdMenuMode == .moviesFolder, tvShowListing == nil, thirdMenuItems.indices.contains(selectedThirdIndex) else { return false }
        let item = thirdMenuItems[selectedThirdIndex]
        guard !item.isDirectory else { return false }
        playSound(named: "Selection")
        guard !tiger.isStartingMovie else { return true }
        tiger.movieStartRequestID &+= 1
        let requestID = tiger.movieStartRequestID
        tiger.isStartingMovie = true
        Task {
            try? await firstRowSleep(0.1)
            guard !Task.isCancelled, self.tiger.movieStartRequestID == requestID else { return }
            withTransaction(.instant) {
                self.tiger.isStartingMovie = false
            }
            self.startMoviePlayback(from: item.url)
        }
        return true
    }

    /// The question about where to start a movie is a page of two rows, which slides in; the
    /// movie's picture comes up behind it a moment later.
    func tigerEnterResumePage(for url: URL) {
        guard !isEnteringSubmenu, !isReturningToRoot else { return }
        isMovieTransitioning = true
        tiger.resumeRequestID &+= 1
        let requestID = tiger.resumeRequestID
        withTransaction(.instant) {
            tiger.showsResumeBackdrop = false
            presentMovieResumePrompt(for: url)
        }
        // The picture behind the question is the movie where it was left.
        let seconds = movieResumePromptResumeSeconds
        let pictureID = incrementRequestID(&movieResumePromptBackdropRequestID)
        movieResumePromptBackdropImage = nil
        Task.detached(priority: .userInitiated) { [url] in
            let image = await self.generateMovieThumbnail(for: url, preferredSeconds: seconds)
            await MainActor.run {
                guard self.movieResumePromptBackdropRequestID == pictureID, self.isMovieResumePromptVisible else { return }
                self.movieResumePromptBackdropImage = image
            }
        }
        Task {
            try? await firstRowSleep(TigerTheme.pageSlideDuration)
            self.isMovieTransitioning = false
        }
        Task {
            try? await firstRowSleep(1.0)
            guard self.tiger.resumeRequestID == requestID, self.isMovieResumePromptVisible else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                self.tiger.showsResumeBackdrop = true
            }
        }
    }

    func tigerLeaveResumePage() {
        isMovieTransitioning = true
        tiger.resumeRequestID &+= 1
        withAnimation(.easeInOut(duration: 0.5)) {
            tiger.showsResumeBackdrop = false
        }
        withTransaction(.instant) {
            dismissMovieResumePrompt()
        }
        Task {
            try? await firstRowSleep(TigerTheme.pageSlideDuration)
            self.isMovieTransitioning = false
        }
    }

    /// The movie comes up over the page, from where it was left or from its beginning.
    func tigerStartMovieFromResumePage(_ url: URL) {
        let resumes = movieResumePromptSelectedIndex == 0
        let startSeconds = resumes ? movieResumePromptResumeSeconds : 0
        isMovieResumePromptConfirming = true
        playSound(named: "Selection")
        clearMoviePlaybackControlState()
        isMovieTransitioning = true
        tiger.resumeRequestID &+= 1
        withTransaction(.instant) {
            movieSceneOpacity = 0
        }
        activateMoviePlayback(from: url, startSeconds: startSeconds, showsPlayGlyphOnStart: false)
        withAnimation(.easeInOut(duration: 1.0)) {
            movieSceneOpacity = 1
            menuSceneOpacity = 0
        }
        Task {
            try? await firstRowSleep(1.0)
            if startSeconds > 0.01 {
                self.showMovieControlsInstantly()
                self.scheduleMovieControlsAutoHide()
            }
            withTransaction(.instant) {
                self.dismissMovieResumePrompt()
                self.tiger.showsResumeBackdrop = false
            }
            self.isMovieTransitioning = false
        }
    }

    // MARK: - Previews

    /// The movie the list rests on, to play beside it (nil on a folder's row).
    func tigerMoviePreviewURL() -> URL? {
        guard isInSubmenu, isInThirdMenu, thirdMenuMode == .moviesFolder, !isLoadingMoviesFolderEntries else { return nil }
        guard thirdMenuItems.indices.contains(selectedThirdIndex) else { return nil }
        let entry = thirdMenuItems[selectedThirdIndex]
        return entry.isDirectory ? nil : entry.url.standardizedFileURL
    }

    /// Reads the cover of the album Photos rests on, for the preview beside its list.
    func tigerRefreshPhotosPreview() {
        let album: PhotoLibraryAlbumEntry? = if isInThirdMenu, thirdMenuMode == .photosDateAlbums {
            photosDateAlbums.indices.contains(selectedThirdIndex) ? photosDateAlbums[selectedThirdIndex] : nil
        } else if !isInThirdMenu {
            selectedPhotoAlbumForCarousel
        } else {
            nil
        }
        guard let album else {
            tiger.photosPreviewRequestID &+= 1
            tiger.photosPreviewAlbumID = nil
            tiger.photosPreviewImage = nil
            return
        }
        guard album.id != tiger.photosPreviewAlbumID else { return }
        tiger.photosPreviewRequestID &+= 1
        let requestID = tiger.photosPreviewRequestID
        tiger.photosPreviewAlbumID = album.id
        tiger.photosPreviewImage = nil
        guard let cover = album.coverAssetLocalIdentifier else { return }
        requestPhotoImage(localIdentifier: cover, targetSize: CGSize(width: 800, height: 800), contentMode: .aspectFill, deliveryMode: .highQualityFormat) { image in
            guard self.tiger.photosPreviewRequestID == requestID, let image else { return }
            self.tiger.photosPreviewImage = image
        }
    }

    /// Whether the selected row shows a spinner in place of its arrow.
    func tigerRowIsBusy(_ itemID: String) -> Bool {
        if itemID == "movies_theatrical_trailers" { return tiger.isLoadingTrailers }
        if thirdMenuMode == .moviesFolder || thirdMenuMode == .podcastsEpisodes { return tiger.isStartingMovie }
        return false
    }

    // MARK: - The page on screen

    /// The page the menus' state amounts to, or nil at the ring.
    func tigerCurrentPage() -> TigerPage? {
        guard let rootID = activeRootItemID, isInSubmenu || isEnteringSubmenu || isReturningToRoot else { return nil }
        let rootTitle = rootMenuTitle(for: rootID)
        var depth = modernMenuDepth
        if !isInSubmenu { depth += 1 }
        if let scene = activeFullscreenScene, tigerIsPageScene(scene.key) {
            if scene.key == musicNowPlayingFullscreenKey {
                return TigerPage(key: "\(rootID)|now playing", depth: depth + 10, rootID: rootID, title: L("Now Playing"), content: .nowPlaying)
            }
            let copy = FeatureErrorCopy.resolve(from: scene.payload)
            let message = TigerMessage(header: copy.headerText, subcaption: copy.subcaptionText)
            let title = isInSubmenu ? headerText : rootTitle
            return TigerPage(key: "\(rootID)|message|\(message.header)", depth: depth + 10, rootID: rootID, title: title, content: .message(message))
        }
        if isMovieResumePromptVisible {
            let items = [
                plainMenuListItem(id: "movie_resume_resume", title: L("Resume Playing")),
                plainMenuListItem(id: "movie_resume_start", title: L("Start from Beginning")),
            ]
            return TigerPage(
                key: "\(rootID)|resume|\(movieResumePromptTargetURL?.path ?? "")", depth: depth + 5, rootID: rootID, title: headerText,
                content: .list, items: items, selectedIndex: movieResumePromptSelectedIndex,
            )
        }
        if isInThirdMenu, thirdMenuMode != .none, thirdMenuOpacity > 0.5 {
            let items = tigerThirdMenuItems()
            var page = TigerPage(
                key: "\(rootID)|\(thirdMenuMode)|\(headerText)|\(thirdMenuCurrentURL?.path ?? "")|\(isMusicSongsCategoryScoped)|\(musicArtistsReturn != nil)",
                depth: depth, rootID: rootID, title: headerText, content: .list,
                items: items, selectedIndex: min(selectedThirdIndex, max(0, items.count - 1)),
            )
            page.showsMoviePreview = thirdMenuMode == .moviesFolder
            page.isPodcastEpisodes = thirdMenuMode == .podcastsEpisodes
            page.showsPhotosPreview = rootID == "photos"
            page.isCompact = page.showsMoviePreview || page.showsPhotosPreview
            return page
        }
        if let message = tiger.sectionMessage {
            return TigerPage(key: "\(rootID)|section message", depth: 1, rootID: rootID, title: rootTitle, content: .message(message))
        }
        let items = tigerSubmenuListItems()
        var page = TigerPage(
            key: "\(rootID)|section", depth: 1, rootID: rootID, title: rootTitle, content: .list,
            items: items, selectedIndex: min(selectedSubIndex, max(0, items.count - 1)),
        )
        page.showsPhotosPreview = rootID == "photos"
        page.isCompact = page.showsPhotosPreview
        return page
    }

    /// A section's own rows: their names and where they lead, nothing more.
    private func tigerSubmenuListItems() -> [MenuListItemConfig] {
        currentSubmenuItems().map {
            plainMenuListItem(id: $0.id, title: $0.title, leadsToMenu: $0.leadsToMenu, trailingSymbolName: $0.trailingSymbolName)
        }
    }

    private func tigerThirdMenuItems() -> [MenuListItemConfig] {
        switch thirdMenuMode {
        case .podcastsEpisodes:
            // (As the menus have them, without the dot for a new episode.)
            return thirdMenuListItems().map {
                plainMenuListItem(id: $0.id, title: $0.title, trailingText: $0.trailingText)
            }
        case .moviesFolder:
            return thirdMenuListItems().map {
                plainMenuListItem(id: $0.id, title: $0.title, leadsToMenu: $0.leadsToMenu)
            }
        case .photosDateAlbums:
            // (Each album leads to its photos; no counts or little pictures on the rows.)
            return thirdMenuListItems().map {
                plainMenuListItem(id: $0.id, title: $0.title, leadsToMenu: !$0.id.hasSuffix("_error"))
            }
        default:
            return thirdMenuListItems()
        }
    }
}
