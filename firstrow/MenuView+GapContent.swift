import SwiftUI

extension MenuView {
    func detailContentView(sceneSize: CGSize) -> some View {
        let selectedImage = activeRootItemID.flatMap { menuImage(forRootID: $0) }
        return defaultDetailContent(image: selectedImage, sceneSize: sceneSize)
    }

    var selectedMoviesFolderEntry: MoviesFolderEntry? {
        guard activeRootItemID == "movies",
              isInThirdMenu,
              thirdMenuMode == .moviesFolder,
              thirdMenuItems.indices.contains(selectedThirdIndex)
        else {
            return nil
        }
        return thirdMenuItems[selectedThirdIndex]
    }

    var shouldShowMoviePreviewContent: Bool {
        if activeRootItemID == "movies" {
            if isInThirdMenu, thirdMenuMode == .moviesITunesTop {
                return currentITunesTopPreviewTargetID(.movies) != nil &&
                    currentITunesTopPreviewImage(.movies) != nil
            }
            return moviePreviewTargetURL != nil && moviePreviewImage != nil
        }
        if activeRootItemID == "tv_shows",
           isInThirdMenu,
           thirdMenuMode == .tvITunesTopEpisodes
        {
            return currentITunesTopPreviewTargetID(.tvEpisodes) != nil &&
                currentITunesTopPreviewImage(.tvEpisodes) != nil
        }
        return false
    }

    var shouldShowMoviesFolderSubmenuPreviewSlideshow: Bool {
        activeRootItemID == "movies" &&
            isInSubmenu &&
            !isInThirdMenu &&
            selectedMoviesSubmenuItemID == "movies_folder" &&
            !moviesFolderSubmenuPreviewDescriptors.isEmpty
    }

    func shouldShowITunesTopCarouselContent(_ kind: ITunesTopCarouselKind) -> Bool {
        shouldUseITunesTopCarouselSlot(kind) &&
            !currentITunesTopCarouselArtworks(kind).isEmpty
    }

    var shouldShowITunesTopSongsCarouselContent: Bool {
        shouldShowITunesTopCarouselContent(.songs)
    }

    var shouldShowITunesTopMusicVideosCarouselContent: Bool {
        shouldShowITunesTopCarouselContent(.musicVideos)
    }

    func aspectRatio(for image: NSImage, fallback: CGFloat = 16.0 / 9.0) -> CGFloat {
        let width = image.size.width
        let height = image.size.height
        guard width > 1, height > 1 else { return fallback }
        let raw = width / height
        return max(0.4, min(3.0, raw))
    }

    var movieGapPreviewDescriptor: MovieGapPreviewDescriptor? {
        if activeRootItemID == "movies",
           isInThirdMenu,
           thirdMenuMode == .moviesITunesTop,
           shouldShowMoviePreviewContent,
           let iTunesTopMoviePreviewImage = currentITunesTopPreviewImage(.movies)
        {
            let previewID = currentITunesTopPreviewTargetID(.movies) ?? "itunes_movie_preview"
            return MovieGapPreviewDescriptor(
                id: "itunes:\(previewID)",
                image: iTunesTopMoviePreviewImage,
                aspectRatio: aspectRatio(for: iTunesTopMoviePreviewImage, fallback: 2.0 / 3.0),
                sizeScale: 0.75,
            )
        }
        if activeRootItemID == "tv_shows",
           isInThirdMenu,
           thirdMenuMode == .tvITunesTopEpisodes,
           shouldShowMoviePreviewContent,
           let iTunesTopTVEpisodePreviewImage = currentITunesTopPreviewImage(.tvEpisodes)
        {
            let previewID = currentITunesTopPreviewTargetID(.tvEpisodes) ?? "itunes_tv_episode_preview"
            return MovieGapPreviewDescriptor(
                id: "itunes_tv:\(previewID)",
                image: iTunesTopTVEpisodePreviewImage,
                aspectRatio: aspectRatio(for: iTunesTopTVEpisodePreviewImage, fallback: 2.0 / 3.0),
                sizeScale: 0.75,
            )
        }
        if shouldShowMoviePreviewContent,
           let moviePreviewImage
        {
            let previewID = moviePreviewTargetURL?.standardizedFileURL.path ?? "movie_preview"
            return MovieGapPreviewDescriptor(
                id: "movie:\(previewID)",
                image: moviePreviewImage,
                aspectRatio: 16.0 / 9.0,
                sizeScale: 1.0,
            )
        }
        if activeRootItemID == "movies",
           isInSubmenu,
           !isInThirdMenu,
           selectedMoviesSubmenuItemID == "movies_folder",
           let slideshowDescriptor = moviesFolderSubmenuPreviewDescriptors.first
        {
            return slideshowDescriptor
        }
        guard let moviesFallbackImage else { return nil }
        if let selectedMoviesFolderEntry,
           selectedMoviesFolderEntry.isDirectory
        {
            return MovieGapPreviewDescriptor(
                id: "folder:\(selectedMoviesFolderEntry.id)",
                image: moviesFallbackImage,
                aspectRatio: aspectRatio(for: moviesFallbackImage),
                sizeScale: 0.5,
            )
        }

        if activeRootItemID == "movies",
           isInThirdMenu,
           thirdMenuMode == .moviesFolder,
           thirdMenuItems.indices.contains(selectedThirdIndex),
           !thirdMenuItems[selectedThirdIndex].isDirectory,
           moviePreviewTargetURL != nil,
           moviePreviewImage == nil
        {
            let entry = thirdMenuItems[selectedThirdIndex]
            return MovieGapPreviewDescriptor(
                id: "loading:\(entry.id)",
                image: moviesFallbackImage,
                aspectRatio: aspectRatio(for: moviesFallbackImage),
                sizeScale: 0.5,
            )
        }

        if activeRootItemID == "movies",
           isInThirdMenu,
           thirdMenuMode == .moviesITunesTop,
           currentITunesTopPreviewTargetID(.movies) != nil,
           currentITunesTopPreviewImage(.movies) == nil
        {
            let previewID = currentITunesTopPreviewTargetID(.movies) ?? "itunes_loading"
            return MovieGapPreviewDescriptor(
                id: "itunes_loading:\(previewID)",
                image: moviesFallbackImage,
                aspectRatio: aspectRatio(for: moviesFallbackImage),
                sizeScale: 0.5,
            )
        }

        if activeRootItemID == "tv_shows",
           isInThirdMenu,
           thirdMenuMode == .tvITunesTopEpisodes,
           currentITunesTopPreviewTargetID(.tvEpisodes) != nil,
           currentITunesTopPreviewImage(.tvEpisodes) == nil
        {
            let previewID = currentITunesTopPreviewTargetID(.tvEpisodes) ?? "itunes_tv_loading"
            return MovieGapPreviewDescriptor(
                id: "itunes_tv_loading:\(previewID)",
                image: moviesFallbackImage,
                aspectRatio: aspectRatio(for: moviesFallbackImage),
                sizeScale: 0.5,
            )
        }
        return nil
    }

    var shouldShowMusicPreviewContent: Bool {
        activeRootItemID == "music" &&
            isInThirdMenu &&
            thirdMenuMode == .musicSongs &&
            musicPreviewTargetSongID != nil
    }

    var shouldShowMusicNowPlayingGapPreview: Bool {
        activeRootItemID == "music" &&
            isInSubmenu &&
            !isInThirdMenu &&
            selectedMusicSubmenuItemID == "music_now_playing" &&
            hasActiveMusicPlaybackSession() &&
            !isPodcastAudioNowPlaying
    }

    var selectedMusicSongForPreview: MusicLibrarySongEntry? {
        guard shouldShowMusicPreviewContent else { return nil }
        return musicPreviewDisplayedSong
    }

    var shouldUseMusicSongMetadataPreview: Bool {
        guard shouldShowMusicPreviewContent else { return false }
        guard activeMusicLibraryMediaType == .songs else { return false }
        if !isMusicSongsCategoryScoped {
            // Songs submenu
            return true
        }
        guard let categoryKind = activeMusicCategoryKind else { return false }
        switch categoryKind {
        case .playlists, .artists, .albums, .genres, .composers:
            return true
        }
    }

    func normalizedMusicMetadataValue(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        let unknownTokens: Set<String> = [
            "unknown",
            "unknown artist",
            "unknown album",
            "unknown genre",
            "unknown composer",
        ]
        if unknownTokens.contains(trimmed.lowercased()) {
            return "Unknown"
        }
        return trimmed
    }

    func musicSongMetadataLengthText(_ durationSeconds: Double) -> String {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return "Unknown" }
        return formatfirstRowPlaybackTime(durationSeconds)
    }

    var shouldShowITunesTopSongPreviewContent: Bool {
        activeRootItemID == "music" &&
            isInThirdMenu &&
            thirdMenuMode == .musicITunesTopSongs &&
            currentITunesTopPreviewTargetID(.songs) != nil
    }

    var shouldShowITunesTopMusicVideoPreviewContent: Bool {
        activeRootItemID == "music" &&
            isInThirdMenu &&
            thirdMenuMode == .musicITunesTopMusicVideos &&
            currentITunesTopPreviewTargetID(.musicVideos) != nil
    }

    var musicTopLevelCarouselEligibleSubmenuIDs: Set<String> {
        [
            "music_shuffle_songs",
            "music_artists",
            "music_albums",
            "music_genres",
            "music_songs",
            "music_composers",
        ]
    }

    func selectedSubmenuItemID(for rootID: String) -> String? {
        guard activeRootItemID == rootID, isInSubmenu, !isInThirdMenu else { return nil }
        let submenuItems = currentSubmenuItems()
        guard submenuItems.indices.contains(selectedSubIndex) else { return nil }
        return submenuItems[selectedSubIndex].id
    }

    var selectedMoviesSubmenuItemID: String? {
        selectedSubmenuItemID(for: "movies")
    }

    var shouldUseITunesTopMoviesCarouselSlot: Bool {
        selectedMoviesSubmenuItemID == "movies_itunes_top"
    }

    var selectedTVShowsSubmenuItemID: String? {
        selectedSubmenuItemID(for: "tv_shows")
    }

    var shouldUseITunesTopTVEpisodesCarouselSlot: Bool {
        selectedTVShowsSubmenuItemID == "tv_itunestopepisodes"
    }

    var selectedMusicSubmenuItemID: String? {
        selectedSubmenuItemID(for: "music")
    }

    var selectedTopLevelMusicCarouselSubmenuID: String? {
        guard let selectedMusicSubmenuItemID else { return nil }
        guard musicTopLevelCarouselEligibleSubmenuIDs.contains(selectedMusicSubmenuItemID) else { return nil }
        return selectedMusicSubmenuItemID
    }

    var shouldUseITunesTopSongsCarouselSlot: Bool {
        selectedMusicSubmenuItemID == "music_itunes_top_songs"
    }

    var shouldUseITunesTopMusicVideosCarouselSlot: Bool {
        selectedMusicSubmenuItemID == "music_itunes_top_music_videos"
    }

    var shouldShowMusicTopLevelCarouselContent: Bool {
        guard let selectedTopLevelMusicCarouselSubmenuID else { return false }
        guard musicTopLevelCarouselActiveSubmenuID == selectedTopLevelMusicCarouselSubmenuID else { return false }
        return musicTopLevelCarouselLoadedArtworkCount > 0
    }

    var shouldUseMusicTopLevelCarouselSlot: Bool {
        selectedTopLevelMusicCarouselSubmenuID != nil
    }

    var musicTopLevelCarouselExitOverlayOpacity: Double {
        let backspaceExitOverlay = isReturningToRoot ? (1 - detailContentOpacity) : 0
        let forwardTransitioning = isMenuFolderSwapTransitioning || isFullscreenSceneTransitioning
        let forwardExitOverlay = (shouldShowMusicTopLevelCarouselContent && forwardTransitioning)
            ? (1 - menuSceneOpacity)
            : 0
        return min(
            1,
            max(0, max(backspaceExitOverlay, max(forwardExitOverlay, musicTopLevelCarouselLoadOverlayOpacity))),
        )
    }

    var iTunesTopCarouselExitOverlayOpacity: Double {
        let backspaceExitOverlay = isReturningToRoot ? (1 - detailContentOpacity) : 0
        return min(1, max(0, backspaceExitOverlay))
    }

    var selectedPhotosSubmenuItemID: String? {
        selectedSubmenuItemID(for: "photos")
    }

    var selectedPhotosDateAlbumID: String? {
        guard activeRootItemID == "photos", isInSubmenu, isInThirdMenu, thirdMenuMode == .photosDateAlbums else {
            return nil
        }
        guard photosDateAlbums.indices.contains(selectedThirdIndex) else { return nil }
        return photosDateAlbums[selectedThirdIndex].id
    }

    var selectedPhotoAlbumForCarousel: PhotoLibraryAlbumEntry? {
        if let selectedPhotosDateAlbumID {
            return photosDateAlbums.first(where: { $0.id == selectedPhotosDateAlbumID })
        }
        guard let selectedPhotosSubmenuItemID else { return nil }
        return photoAlbumForSubmenuItemID(selectedPhotosSubmenuItemID)
    }

    var shouldUsePhotosCarouselSlot: Bool {
        selectedPhotoAlbumForCarousel?.isPlayable == true
    }

    var shouldShowPhotosCarouselContent: Bool {
        shouldUsePhotosCarouselSlot && !photosCarouselArtworks.isEmpty
    }

    var photosCarouselExitOverlayOpacity: Double {
        let backspaceExitOverlay = isReturningToRoot ? (1 - detailContentOpacity) : 0
        let forwardTransitioning = isMenuFolderSwapTransitioning || isFullscreenSceneTransitioning
        let forwardExitOverlay = (shouldShowPhotosCarouselContent && forwardTransitioning)
            ? (1 - menuSceneOpacity)
            : 0
        return min(1, max(0, max(backspaceExitOverlay, max(forwardExitOverlay, photosCarouselLoadOverlayOpacity))))
    }

    var selectedPodcastsSubmenuItemID: String? {
        selectedSubmenuItemID(for: "podcasts")
    }

    var selectedPodcastSeriesForPreview: PodcastSeriesEntry? {
        podcastSeriesForSubmenuItemID(selectedPodcastsSubmenuItemID)
    }

    var selectedPodcastEpisodeForPreview: PodcastEpisodeEntry? {
        selectedPodcastEpisodeFromThirdMenuSelection()
    }

    /// Movie and music previews have different projected width/yaw, so they need
    /// separate horizontal anchors after removing the old menu-scene HStack padding.
    var movieGapPreviewHorizontalOffset: CGFloat {
        gapContentHorizontalOffset - 62
    }

    var musicGapPreviewHorizontalOffset: CGFloat {
        gapContentHorizontalOffset - 32
    }

    var musicTopLevelCarouselHorizontalOffset: CGFloat {
        gapContentHorizontalOffset - 450
    }

    func defaultGapIcon(_ image: NSImage, opacity: Double = 1) -> some View {
        ReflectedGapContentIconView(
            image: image,
            adjustedIconSize: gapContentAdjustedIconSize,
            horizontalOffset: gapContentHorizontalOffset,
            verticalOffset: gapContentVerticalOffset,
        ).opacity(opacity)
    }

    func gapCarousel(artworks: [NSImage?], preserveAspect: Bool = false, exitOpacity: Double) -> some View {
        MusicTopLevelCarouselGapContentView(
            artworkImages: artworks,
            baseIconSize: iconSize,
            horizontalOffset: musicTopLevelCarouselHorizontalOffset,
            verticalOffset: gapContentVerticalOffset - 34,
            preserveArtworkAspectRatio: preserveAspect,
            exitOverlayOpacity: exitOpacity,
        )
    }

    func musicGapCarousel(exitOpacity: Double) -> some View {
        MusicTopLevelCarouselGapContentView(
            artworkCount: musicTopLevelCarouselResolvedArtworkCount,
            initialLoadedArtworkCount: musicTopLevelCarouselLoadedArtworkCount,
            artworkForGlobalIndex: musicTopLevelCarouselArtwork(forGlobalIndex:),
            prefetchIfNeededForSerial: prefetchMusicTopLevelCarouselIfNeeded(forSerial:),
            baseIconSize: iconSize,
            horizontalOffset: musicTopLevelCarouselHorizontalOffset,
            verticalOffset: gapContentVerticalOffset - 34,
            exitOverlayOpacity: exitOpacity,
            phaseResetKey: "music_top_level_carousel",
        )
    }

    func defaultDetailContent(image: NSImage?, sceneSize: CGSize) -> some View {
        Group {
            if let image {
                if activeRootItemID == "movies" {
                    let activeMoviePreviewDescriptor = movieGapPreviewDescriptor
                    let selectedITunesTopMovie = resolveITunesTopMoviePreviewTarget()
                    let shouldShowMoviesFolderSlideshow = shouldShowMoviesFolderSubmenuPreviewSlideshow
                    let shouldShowMovieGapPreviewContent =
                        activeMoviePreviewDescriptor != nil || shouldShowMoviesFolderSlideshow
                    let shouldShowITunesTopMoviesCarousel = shouldShowITunesTopCarouselContent(.movies)
                    let shouldReserveITunesTopMoviesCarouselSlot = shouldUseITunesTopMoviesCarouselSlot
                    let shouldUseITunesTopMovieMetadataPreview =
                        isInThirdMenu &&
                        thirdMenuMode == .moviesITunesTop &&
                        shouldShowMoviePreviewContent &&
                        selectedITunesTopMovie != nil
                    let moviePreviewAnimationKey: String = {
                        if shouldShowMoviesFolderSlideshow {
                            let descriptorIDs = moviesFolderSubmenuPreviewDescriptors.map(\.id).joined(separator: "|")
                            return "movies_folder_slideshow:\(descriptorIDs)"
                        }
                        return activeMoviePreviewDescriptor?.id ?? "none"
                    }()
                    ZStack {
                        defaultGapIcon(image, opacity: (shouldShowMovieGapPreviewContent || shouldReserveITunesTopMoviesCarouselSlot) ? 0 : 1)
                        if shouldShowITunesTopMoviesCarousel {
                            gapCarousel(artworks: currentITunesTopCarouselArtworks(.movies), preserveAspect: true, exitOpacity: iTunesTopCarouselExitOverlayOpacity)
                        }
                        if shouldShowMoviesFolderSlideshow, !shouldShowITunesTopMoviesCarousel {
                            MoviePreviewSlideshowGapContentView(
                                descriptors: moviesFolderSubmenuPreviewDescriptors,
                                baseIconSize: iconSize,
                                horizontalOffset: movieGapPreviewHorizontalOffset,
                                verticalOffset: gapContentVerticalOffset + 8,
                                previewYawDegrees: 36,
                                reflectionYawDegrees: 35.8,
                                cycleDuration: 3.0,
                            ).transition(.opacity).opacity(shouldShowMovieGapPreviewContent ? 1 : 0)
                        } else if shouldUseITunesTopMovieMetadataPreview,
                                  let selectedITunesTopMovie,
                                  let activeMoviePreviewDescriptor,
                                  !shouldShowITunesTopMoviesCarousel
                        {
                            AnimatedMetadataGapContentView(
                                image: activeMoviePreviewDescriptor.image,
                                aspectRatio: activeMoviePreviewDescriptor.aspectRatio,
                                sizeScale: activeMoviePreviewDescriptor.sizeScale,
                                titleText: selectedITunesTopMovie.title,
                                descriptionText: selectedITunesTopMovie.summary,
                                baseIconSize: iconSize,
                                horizontalOffset: movieGapPreviewHorizontalOffset,
                                verticalOffset: gapContentVerticalOffset + 8,
                                transitionIdentity: selectedITunesTopMovie.id,
                                sceneSize: sceneSize,
                            ).id("itunes_movie_metadata:\(selectedITunesTopMovie.id)").transition(.opacity).opacity(shouldShowMovieGapPreviewContent ? 1 : 0)
                        } else if let activeMoviePreviewDescriptor, !shouldShowITunesTopMoviesCarousel {
                            MoviePreviewGapContentView(
                                image: activeMoviePreviewDescriptor.image,
                                aspectRatio: activeMoviePreviewDescriptor.aspectRatio,
                                sizeScale: activeMoviePreviewDescriptor.sizeScale,
                                baseIconSize: iconSize,
                                horizontalOffset: movieGapPreviewHorizontalOffset,
                                verticalOffset: gapContentVerticalOffset + 8,
                                previewYawDegrees:
                                isInThirdMenu && thirdMenuMode == .moviesITunesTop
                                    ? 10
                                    : 36,
                                reflectionYawDegrees:
                                isInThirdMenu && thirdMenuMode == .moviesITunesTop
                                    ? 9.8
                                    : 35.8,
                            ).id(activeMoviePreviewDescriptor.id).transition(.opacity).opacity(shouldShowMovieGapPreviewContent ? 1 : 0)
                        }
                    }.animation(.easeInOut(duration: 0.22), value: moviePreviewAnimationKey)
                } else if activeRootItemID == "tv_shows" {
                    let activeEpisodePreviewDescriptor = movieGapPreviewDescriptor
                    let selectedITunesTopTVEpisode = resolveITunesTopTVEpisodePreviewTarget()
                    let shouldShowEpisodeGapPreviewContent = activeEpisodePreviewDescriptor != nil
                    let shouldShowITunesTopTVEpisodesCarousel = shouldShowITunesTopCarouselContent(.tvEpisodes)
                    let shouldReserveITunesTopTVEpisodesCarouselSlot = shouldUseITunesTopTVEpisodesCarouselSlot
                    let shouldUseITunesTopTVEpisodeMetadataPreview =
                        isInThirdMenu &&
                        thirdMenuMode == .tvITunesTopEpisodes &&
                        shouldShowMoviePreviewContent &&
                        selectedITunesTopTVEpisode != nil
                    let episodePreviewAnimationKey = activeEpisodePreviewDescriptor?.id ?? "none"
                    ZStack {
                        defaultGapIcon(image, opacity: (shouldShowEpisodeGapPreviewContent || shouldReserveITunesTopTVEpisodesCarouselSlot) ? 0 : 1)
                        if shouldShowITunesTopTVEpisodesCarousel {
                            gapCarousel(artworks: currentITunesTopCarouselArtworks(.tvEpisodes), preserveAspect: true, exitOpacity: iTunesTopCarouselExitOverlayOpacity)
                        }
                        if shouldUseITunesTopTVEpisodeMetadataPreview,
                           let selectedITunesTopTVEpisode,
                           let activeEpisodePreviewDescriptor,
                           !shouldShowITunesTopTVEpisodesCarousel
                        {
                            AnimatedMetadataGapContentView(
                                image: activeEpisodePreviewDescriptor.image,
                                aspectRatio: activeEpisodePreviewDescriptor.aspectRatio,
                                forcedPreviewAspectRatio: 1.0,
                                sizeScale: activeEpisodePreviewDescriptor.sizeScale,
                                titleText: selectedITunesTopTVEpisode.title,
                                descriptionText: selectedITunesTopTVEpisode.summary,
                                baseIconSize: iconSize,
                                horizontalOffset: movieGapPreviewHorizontalOffset,
                                verticalOffset: gapContentVerticalOffset + 8,
                                transitionIdentity: selectedITunesTopTVEpisode.id,
                                sceneSize: sceneSize,
                            ).id("itunes_tv_metadata:\(selectedITunesTopTVEpisode.id)").transition(.opacity).opacity(shouldShowEpisodeGapPreviewContent ? 1 : 0)
                        } else if let activeEpisodePreviewDescriptor, !shouldShowITunesTopTVEpisodesCarousel {
                            MoviePreviewGapContentView(
                                image: activeEpisodePreviewDescriptor.image,
                                aspectRatio: activeEpisodePreviewDescriptor.aspectRatio,
                                sizeScale: activeEpisodePreviewDescriptor.sizeScale,
                                baseIconSize: iconSize,
                                horizontalOffset: movieGapPreviewHorizontalOffset,
                                verticalOffset: gapContentVerticalOffset + 8,
                                previewYawDegrees:
                                isInThirdMenu && thirdMenuMode == .tvITunesTopEpisodes
                                    ? 10
                                    : 36,
                                reflectionYawDegrees:
                                isInThirdMenu && thirdMenuMode == .tvITunesTopEpisodes
                                    ? 9.8
                                    : 35.8,
                            ).id(activeEpisodePreviewDescriptor.id).transition(.opacity).opacity(shouldShowEpisodeGapPreviewContent ? 1 : 0)
                        }
                    }.animation(.easeInOut(duration: 0.22), value: episodePreviewAnimationKey)
                } else if activeRootItemID == "music" {
                    let shouldShowMusicTopLevelCarousel = shouldShowMusicTopLevelCarouselContent
                    let shouldShowITunesTopSongsCarousel = shouldShowITunesTopCarouselContent(.songs)
                    let shouldShowITunesTopMusicVideosCarousel = shouldShowITunesTopCarouselContent(.musicVideos)
                    let selectedMusicSong = selectedMusicSongForPreview
                    let shouldShowMusicSongMetadataPreview =
                        shouldUseMusicSongMetadataPreview &&
                        selectedMusicSong != nil
                    let shouldShowClassicMusicPreview =
                        shouldShowITunesTopSongPreviewContent ||
                        shouldShowMusicNowPlayingGapPreview ||
                        (shouldShowMusicPreviewContent && !shouldShowMusicSongMetadataPreview)
                    let shouldShowAnyMusicITunesTopPreview =
                        shouldShowITunesTopSongPreviewContent || shouldShowITunesTopMusicVideoPreviewContent
                    let shouldHideMusicRootIcon =
                        shouldShowMusicPreviewContent ||
                        shouldShowMusicNowPlayingGapPreview ||
                        shouldShowAnyMusicITunesTopPreview ||
                        shouldShowMusicTopLevelCarousel ||
                        shouldUseMusicTopLevelCarouselSlot ||
                        shouldUseITunesTopSongsCarouselSlot ||
                        shouldUseITunesTopMusicVideosCarouselSlot
                    ZStack {
                        ReflectedGapContentIconView(
                            image: image,
                            adjustedIconSize: gapContentAdjustedIconSize,
                            horizontalOffset: gapContentHorizontalOffset,
                            verticalOffset: gapContentVerticalOffset,
                        ).opacity(shouldHideMusicRootIcon ? 0 : 1).animation(
                            shouldHideMusicRootIcon ? nil : .easeInOut(duration: 0.18),
                            value: shouldHideMusicRootIcon,
                        )
                        if shouldShowMusicSongMetadataPreview,
                           let selectedMusicSong
                        {
                            let metadataPreviewImage = musicPreviewImage ?? musicFallbackImage ?? image
                            AnimatedMetadataGapContentView(
                                image: metadataPreviewImage,
                                aspectRatio: aspectRatio(for: metadataPreviewImage, fallback: 1.0),
                                forcedPreviewAspectRatio: 1.0,
                                sizeScale: 0.92,
                                titleText: selectedMusicSong.title,
                                descriptionText: nil,
                                metadataLines: [.init(label: "Album", value: normalizedMusicMetadataValue(selectedMusicSong.album)), .init(label: "Artist", value: normalizedMusicMetadataValue(selectedMusicSong.artist)), .init(label: "Genre", value: normalizedMusicMetadataValue(selectedMusicSong.genre)), .init(label: "Length", value: musicSongMetadataLengthText(selectedMusicSong.durationSeconds))],
                                baseIconSize: iconSize,
                                horizontalOffset: musicGapPreviewHorizontalOffset - 56,
                                verticalOffset: gapContentVerticalOffset - 8,
                                transitionIdentity: "music_song_metadata:\(selectedMusicSong.id)",
                                transitionDelay: 0,
                                animatePreviewTransition: false,
                                sceneSize: sceneSize,
                            ).transaction { transaction in
                                transaction.animation = nil
                            }
                        } else {
                            MusicPreviewGapContentView(
                                image:
                                shouldShowITunesTopSongPreviewContent
                                    ? (currentITunesTopPreviewImage(.songs) ?? musicFallbackImage)
                                    : shouldShowMusicNowPlayingGapPreview
                                    ? (musicNowPlayingArtwork ?? musicFallbackImage ?? image)
                                    : (musicPreviewImage ?? musicFallbackImage),
                                baseIconSize: iconSize,
                                horizontalOffset: musicGapPreviewHorizontalOffset,
                                verticalOffset: gapContentVerticalOffset + 8,
                            ).opacity(shouldShowClassicMusicPreview ? 1 : 0)
                        }
                        if shouldShowITunesTopMusicVideoPreviewContent,
                           !shouldShowITunesTopMusicVideosCarousel,
                           let previewImage = currentITunesTopPreviewImage(.musicVideos) ?? moviesFallbackImage ?? musicFallbackImage
                        {
                            MoviePreviewGapContentView(
                                image: previewImage,
                                aspectRatio: aspectRatio(for: previewImage, fallback: 2.0 / 3.0),
                                sizeScale: 0.75,
                                baseIconSize: iconSize,
                                horizontalOffset: movieGapPreviewHorizontalOffset,
                                verticalOffset: gapContentVerticalOffset + 8,
                                previewYawDegrees: 10,
                                reflectionYawDegrees: 9.8,
                            ).id(currentITunesTopPreviewTargetID(.musicVideos) ?? "itunes_top_music_video_preview").transition(.opacity.animation(.easeInOut(duration: 0.22))).opacity(1)
                        }
                        if shouldShowMusicTopLevelCarousel {
                            musicGapCarousel(exitOpacity: musicTopLevelCarouselExitOverlayOpacity)
                        } else if shouldShowITunesTopSongsCarousel {
                            gapCarousel(artworks: currentITunesTopCarouselArtworks(.songs), preserveAspect: true, exitOpacity: iTunesTopCarouselExitOverlayOpacity)
                        } else if shouldShowITunesTopMusicVideosCarousel {
                            gapCarousel(artworks: currentITunesTopCarouselArtworks(.musicVideos), preserveAspect: true, exitOpacity: iTunesTopCarouselExitOverlayOpacity)
                        }
                    }
                } else if activeRootItemID == "photos" {
                    let shouldShowCarousel = shouldShowPhotosCarouselContent
                    let shouldReserveCarouselSlot = shouldUsePhotosCarouselSlot
                    let shouldHidePhotosRootIcon = shouldShowCarousel || shouldReserveCarouselSlot
                    ZStack {
                        defaultGapIcon(image, opacity: shouldHidePhotosRootIcon ? 0 : 1).animation(
                            shouldHidePhotosRootIcon ? nil : .easeInOut(duration: 0.18),
                            value: shouldHidePhotosRootIcon,
                        )
                        if shouldShowCarousel {
                            gapCarousel(artworks: photosCarouselArtworks, preserveAspect: true, exitOpacity: photosCarouselExitOverlayOpacity)
                        }
                    }
                } else if activeRootItemID == "podcasts" {
                    let selectedSeries = selectedPodcastSeriesForPreview
                    let selectedEpisode = selectedPodcastEpisodeForPreview
                    let selectedSeriesArtwork = selectedSeries?.artwork ?? podcastFallbackImage
                    let selectedSeriesPreviewImage = selectedSeriesArtwork ?? image
                    let selectedEpisodePreviewImage = selectedEpisode?.artwork ?? selectedSeriesArtwork ?? image
                    let shouldShowEpisodePreview = selectedEpisode != nil
                    let shouldShowSeriesPreview = selectedSeries != nil && !shouldShowEpisodePreview
                    let shouldHidePodcastsRootIcon = shouldShowSeriesPreview || shouldShowEpisodePreview
                    let selectedSeriesMostRecentDate = selectedSeries?.episodes.compactMap(\.airedDate).max()
                    let resolvedEpisodeDescription = normalizedPodcastText(selectedEpisode?.description)
                        ?? normalizedPodcastText(selectedSeries?.description)
                        ?? "No description available."
                    let resolvedEpisodeArtist = normalizedPodcastText(selectedEpisode?.artist)
                        ?? normalizedPodcastText(selectedSeries?.artist)
                        ?? "Unknown Artist"
                    ZStack {
                        defaultGapIcon(image, opacity: shouldHidePodcastsRootIcon ? 0 : 1).animation(.easeInOut(duration: 0.18), value: shouldHidePodcastsRootIcon)
                        if shouldShowSeriesPreview, let selectedSeries {
                            AnimatedMetadataGapContentView(
                                image: selectedSeriesPreviewImage,
                                aspectRatio: aspectRatio(for: selectedSeriesPreviewImage, fallback: 1.0),
                                forcedPreviewAspectRatio: 1.0,
                                sizeScale: 0.92,
                                titleText: selectedSeries.title,
                                descriptionText: nil,
                                metadataLines: [.init(
                                    label: "Number of Episodes",
                                    value: "\(selectedSeries.episodes.count)",
                                ), .init(
                                    label: "Most Recent",
                                    value: podcastEpisodeAiredText(for: selectedSeriesMostRecentDate),
                                )],
                                baseIconSize: iconSize,
                                horizontalOffset: musicGapPreviewHorizontalOffset - 56,
                                verticalOffset: gapContentVerticalOffset - 8,
                                transitionIdentity: "podcast_series_metadata:\(selectedSeries.id)",
                                sceneSize: sceneSize,
                            ).id("podcast_series_metadata:\(selectedSeries.id)").transition(.opacity.animation(.easeInOut(duration: 0.2)))
                        }
                        if let selectedEpisode {
                            AnimatedMetadataGapContentView(
                                image: selectedEpisodePreviewImage,
                                aspectRatio: aspectRatio(for: selectedEpisodePreviewImage, fallback: 1.0),
                                forcedPreviewAspectRatio: 1.0,
                                sizeScale: 0.92,
                                titleText: selectedEpisode.title,
                                descriptionText: resolvedEpisodeDescription,
                                metadataLines: [.init(label: "Artist", value: resolvedEpisodeArtist), .init(
                                    label: "Length",
                                    value: podcastEpisodeLengthText(for: selectedEpisode.durationSeconds),
                                ), .init(
                                    label: "Aired",
                                    value: podcastEpisodeAiredText(for: selectedEpisode.airedDate),
                                )],
                                baseIconSize: iconSize,
                                horizontalOffset: musicGapPreviewHorizontalOffset - 56,
                                verticalOffset: gapContentVerticalOffset - 8,
                                transitionIdentity: "podcast_episode_metadata:\(selectedEpisode.id)",
                                transitionDelay: 0,
                                animatePreviewTransition: false,
                                sceneSize: sceneSize,
                            ).id("podcast_episode_metadata:\(selectedEpisode.id)").transition(.opacity.animation(.easeInOut(duration: 0.18)))
                        }
                    }
                } else if activeRootItemID == "settings" {
                    PlainGapContentIconView(image: image, adjustedIconSize: gapContentAdjustedIconSize, horizontalOffset: gapContentHorizontalOffset, verticalOffset: gapContentVerticalOffset)
                } else {
                    defaultGapIcon(image)
                }
            }
        }
    }

    var shouldKeepDetailContentFullyOpaqueForCarousel: Bool {
        switch activeRootItemID {
        case "movies":
            shouldUseITunesTopMoviesCarouselSlot || shouldShowITunesTopCarouselContent(.movies)
        case "tv_shows":
            shouldUseITunesTopTVEpisodesCarouselSlot || shouldShowITunesTopCarouselContent(.tvEpisodes)
        case "music":
            shouldUseMusicTopLevelCarouselSlot ||
                shouldUseITunesTopSongsCarouselSlot ||
                shouldUseITunesTopMusicVideosCarouselSlot ||
                shouldShowMusicTopLevelCarouselContent ||
                shouldShowITunesTopCarouselContent(.songs) ||
                shouldShowITunesTopCarouselContent(.musicVideos)
        case "photos":
            shouldUsePhotosCarouselSlot || shouldShowPhotosCarouselContent
        default:
            false
        }
    }

    var detailContentVisibilityOpacity: Double {
        if shouldHidePodcastsSubmenuChromeUntilLoadCompletes {
            return 0
        }
        return shouldKeepDetailContentFullyOpaqueForCarousel ? 1 : detailContentOpacity
    }
}
