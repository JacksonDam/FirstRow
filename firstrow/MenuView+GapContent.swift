import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

extension MenuView {
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
        isMusicLibraryContext &&
            isInThirdMenu &&
            (thirdMenuMode == .musicSongs || isShowingMusicCategoryCovers || isShowingSpotifyCollectionCovers) &&
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
        // The Albums, Artists and Playlists lists show just the cover.
        guard thirdMenuMode == .musicSongs else { return false }
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

    func musicSongMetadataLines(for song: MusicLibrarySongEntry) -> [MetadataPreviewSpec.Line] {
        var lines: [MetadataPreviewSpec.Line] = [
            .init(label: "Album", value: normalizedMusicMetadataValue(song.album)),
            .init(label: "Artist", value: normalizedMusicMetadataValue(song.artist)),
        ]
        // Spotify doesn't give songs a genre.
        if song.spotify == nil {
            lines.append(.init(label: "Genre", value: normalizedMusicMetadataValue(song.genre)))
        }
        lines.append(.init(label: "Length", value: musicSongMetadataLengthText(song.durationSeconds)))
        return lines
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
        if selectedPhotosDateAlbumID != nil {
            // (The selected row is the album's place in the list: no need to look for it.)
            return photosDateAlbums[selectedThirdIndex]
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

    /// A carousel of these pictures. `asCovers` gives Music's carousel: every picture a
    /// square that it fills, whatever its own shape.
    func gapCarouselItem(key: String, artworks: [NSImage?], exitOpacity: Double, asCovers: Bool = false) -> GapItemSpec? {
        guard !artworks.isEmpty else { return nil }
        return GapItemSpec(key: key, kind: .coverCarousel(CoverCarouselConfiguration(
            source: .images(artworks),
            baseIconSize: iconSize,
            horizontalOffset: musicTopLevelCarouselHorizontalOffset,
            verticalOffset: gapContentVerticalOffset - 34,
            preserveArtworkAspectRatio: !asCovers,
        ), exitOverlayOpacity: exitOpacity))
    }

    func musicGapCarouselItem(exitOpacity: Double) -> GapItemSpec? {
        guard musicTopLevelCarouselLoadedArtworkCount > 0 else { return nil }
        return GapItemSpec(key: "music_carousel", kind: .coverCarousel(CoverCarouselConfiguration(
            source: .dynamic(
                resolvedArtworkCount: musicTopLevelCarouselResolvedArtworkCount,
                loadedArtworkCount: musicTopLevelCarouselLoadedArtworkCount,
                artworkForGlobalIndex: { [weak self] index in self?.musicTopLevelCarouselArtwork(forGlobalIndex: index) },
                prefetchIfNeededForSerial: { [weak self] serial in self?.prefetchMusicTopLevelCarouselIfNeeded(forSerial: serial) },
                phaseResetKey: "music_top_level_carousel",
            ),
            baseIconSize: iconSize,
            horizontalOffset: musicTopLevelCarouselHorizontalOffset,
            verticalOffset: gapContentVerticalOffset - 34,
            preserveArtworkAspectRatio: false,
        ), exitOverlayOpacity: exitOpacity))
    }

    func moviePreviewSpec(_ descriptor: MovieGapPreviewDescriptor, yaw: Double = 36, reflectionYaw: Double = 35.8) -> MoviePreviewSpec {
        MoviePreviewSpec(
            image: descriptor.image,
            aspectRatio: descriptor.aspectRatio,
            sizeScale: descriptor.sizeScale,
            baseIconSize: iconSize,
            offsetX: movieGapPreviewHorizontalOffset,
            offsetY: gapContentVerticalOffset + 8,
            previewYaw: yaw,
            reflectionYaw: reflectionYaw,
        )
    }

    /// The pieces of preview content for the section, back to front (see `GapContentLayer`).
    func gapContentItems(sceneSize _: CGSize, pass: RenderPass, memo: inout GapContentMemo) -> [GapItemSpec] {
        guard let rootID = activeRootItemID, let image = menuImage(forRootID: rootID) else { return [] }
        func icon(opacity: Double, animation: Animation?) -> GapItemSpec {
            GapItemSpec(key: "icon", kind: .icon(image: image, reflected: true), opacity: opacity, animation: animation)
        }
        let fadeAlways = pass.transaction.disablesAnimations ? nil : Animation.easeInOut(duration: 0.22)

        // Jellyfin's song lists under Sources show what Music's do.
        switch isShowingJellyfinSongs ? "music" : rootID {
        case "movies":
            let descriptor = movieGapPreviewDescriptor
            let selectedMovie = resolveITunesTopMoviePreviewTarget()
            let showsSlideshow = shouldShowMoviesFolderSubmenuPreviewSlideshow
            let showsPreview = descriptor != nil || showsSlideshow
            let showsCarousel = shouldShowITunesTopCarouselContent(.movies)
            let usesMetadata = isInThirdMenu && thirdMenuMode == .moviesITunesTop && shouldShowMoviePreviewContent && selectedMovie != nil
            let key = showsSlideshow
                ? "movies_folder_slideshow:\(moviesFolderSubmenuPreviewDescriptors.map(\.id).joined(separator: "|"))"
                : (descriptor?.id ?? "none")
            let animation = pass.animation(.easeInOut(duration: 0.22), when: memo.moviePreviewKey != nil && memo.moviePreviewKey != key)
            memo.moviePreviewKey = key
            var items = [icon(opacity: (showsPreview || shouldUseITunesTopMoviesCarouselSlot) ? 0 : 1, animation: animation)]
            if showsCarousel, let carousel = gapCarouselItem(key: "itunes_movies_carousel", artworks: currentITunesTopCarouselArtworks(.movies), exitOpacity: iTunesTopCarouselExitOverlayOpacity) {
                items.append(carousel)
            }
            if showsSlideshow, !showsCarousel, let first = moviesFolderSubmenuPreviewDescriptors.first {
                items.append(GapItemSpec(
                    key: "movies_folder_slideshow",
                    kind: .movieSlideshow(descriptors: moviesFolderSubmenuPreviewDescriptors, template: moviePreviewSpec(first)),
                    opacity: showsPreview ? 1 : 0,
                    animation: animation,
                    transition: animation,
                    fade: .easeInOut(duration: 0.22),
                ))
            } else if usesMetadata, let selectedMovie, let descriptor, !showsCarousel {
                // One piece for the whole list, so changing movies swaps poster and details with no crossfade.
                items.append(GapItemSpec(
                    key: "itunes_movie_metadata",
                    kind: .metadata(MetadataPreviewSpec(
                        image: descriptor.image,
                        aspectRatio: descriptor.aspectRatio,
                        sizeScale: descriptor.sizeScale,
                        title: selectedMovie.title,
                        description: selectedMovie.summary,
                        baseIconSize: iconSize,
                        offsetX: movieGapPreviewHorizontalOffset,
                        offsetY: gapContentVerticalOffset + 8,
                        identity: selectedMovie.id,
                    )),
                    opacity: showsPreview ? 1 : 0,
                    animation: animation,
                    transition: animation,
                    fade: .easeInOut(duration: 0.22),
                ))
            } else if let descriptor, !showsCarousel {
                let isITunes = isInThirdMenu && thirdMenuMode == .moviesITunesTop
                items.append(GapItemSpec(
                    key: "preview:\(descriptor.id)",
                    kind: .moviePreview(moviePreviewSpec(descriptor, yaw: isITunes ? 10 : 36, reflectionYaw: isITunes ? 9.8 : 35.8)),
                    opacity: showsPreview ? 1 : 0,
                    animation: animation,
                    transition: animation,
                    fade: .easeInOut(duration: 0.22),
                ))
            }
            return items

        case "tv_shows":
            let descriptor = movieGapPreviewDescriptor
            let selectedEpisode = resolveITunesTopTVEpisodePreviewTarget()
            let showsPreview = descriptor != nil
            let showsCarousel = shouldShowITunesTopCarouselContent(.tvEpisodes)
            let usesMetadata = isInThirdMenu && thirdMenuMode == .tvITunesTopEpisodes && shouldShowMoviePreviewContent && selectedEpisode != nil
            let key = descriptor?.id ?? "none"
            let animation = pass.animation(.easeInOut(duration: 0.22), when: memo.episodePreviewKey != nil && memo.episodePreviewKey != key)
            memo.episodePreviewKey = key
            var items = [icon(opacity: (showsPreview || shouldUseITunesTopTVEpisodesCarouselSlot) ? 0 : 1, animation: animation)]
            if showsCarousel, let carousel = gapCarouselItem(key: "itunes_tv_carousel", artworks: currentITunesTopCarouselArtworks(.tvEpisodes), exitOpacity: iTunesTopCarouselExitOverlayOpacity) {
                items.append(carousel)
            }
            if usesMetadata, let selectedEpisode, let descriptor, !showsCarousel {
                items.append(GapItemSpec(
                    key: "itunes_tv_metadata",
                    kind: .metadata(MetadataPreviewSpec(
                        image: descriptor.image,
                        aspectRatio: descriptor.aspectRatio,
                        forcedPreviewAspectRatio: 1.0,
                        sizeScale: descriptor.sizeScale,
                        title: selectedEpisode.title,
                        description: selectedEpisode.summary,
                        baseIconSize: iconSize,
                        offsetX: movieGapPreviewHorizontalOffset,
                        offsetY: gapContentVerticalOffset + 8,
                        identity: selectedEpisode.id,
                    )),
                    opacity: showsPreview ? 1 : 0,
                    animation: animation,
                    transition: animation,
                    fade: .easeInOut(duration: 0.22),
                ))
            } else if let descriptor, !showsCarousel {
                let isITunes = isInThirdMenu && thirdMenuMode == .tvITunesTopEpisodes
                items.append(GapItemSpec(
                    key: "preview:\(descriptor.id)",
                    kind: .moviePreview(moviePreviewSpec(descriptor, yaw: isITunes ? 10 : 36, reflectionYaw: isITunes ? 9.8 : 35.8)),
                    opacity: showsPreview ? 1 : 0,
                    animation: animation,
                    transition: animation,
                    fade: .easeInOut(duration: 0.22),
                ))
            }
            return items

        case "music":
            let showsMusicCarousel = shouldShowMusicTopLevelCarouselContent
            let showsSongsCarousel = shouldShowITunesTopCarouselContent(.songs)
            let showsVideosCarousel = shouldShowITunesTopCarouselContent(.musicVideos)
            let song = selectedMusicSongForPreview
            let showsSongMetadata = shouldUseMusicSongMetadataPreview && song != nil
            let showsClassicPreview = shouldShowITunesTopSongPreviewContent || shouldShowMusicNowPlayingGapPreview || (shouldShowMusicPreviewContent && !showsSongMetadata)
            let showsAnyITunesPreview = shouldShowITunesTopSongPreviewContent || shouldShowITunesTopMusicVideoPreviewContent
            let hidesIcon = shouldShowMusicPreviewContent || shouldShowMusicNowPlayingGapPreview || showsAnyITunesPreview ||
                showsMusicCarousel || shouldUseMusicTopLevelCarouselSlot || shouldUseITunesTopSongsCarouselSlot || shouldUseITunesTopMusicVideosCarouselSlot
            let iconAnimation = pass.animation(hidesIcon ? nil : .easeInOut(duration: 0.18), when: memo.hidesMusicRootIcon != nil && memo.hidesMusicRootIcon != hidesIcon)
            memo.hidesMusicRootIcon = hidesIcon
            var items = [icon(opacity: hidesIcon ? 0 : 1, animation: iconAnimation)]
            if showsSongMetadata, let song {
                let preview = musicPreviewImage ?? musicFallbackImage ?? image
                items.append(GapItemSpec(key: "music_song_metadata", kind: .metadata(MetadataPreviewSpec(
                    image: preview,
                    aspectRatio: aspectRatio(for: preview, fallback: 1.0),
                    forcedPreviewAspectRatio: 1.0,
                    sizeScale: 0.92,
                    title: song.title,
                    description: nil,
                    lines: musicSongMetadataLines(for: song),
                    baseIconSize: iconSize,
                    offsetX: musicGapPreviewHorizontalOffset - 56,
                    offsetY: gapContentVerticalOffset - 8,
                    identity: "music_song_metadata:\(song.id)",
                    transitionDelay: 0,
                    animatesTransition: false,
                ))))
            } else {
                let preview: NSImage? = if shouldShowITunesTopSongPreviewContent {
                    currentITunesTopPreviewImage(.songs) ?? musicFallbackImage
                } else if shouldShowMusicNowPlayingGapPreview {
                    musicNowPlayingArtwork ?? musicFallbackImage ?? image
                } else {
                    musicPreviewImage ?? musicFallbackImage
                }
                items.append(GapItemSpec(
                    key: "music_preview",
                    kind: .musicPreview(image: preview, offsetX: musicGapPreviewHorizontalOffset, offsetY: gapContentVerticalOffset + 8),
                    opacity: showsClassicPreview ? 1 : 0,
                    animation: pass.animation,
                ))
            }
            if shouldShowITunesTopMusicVideoPreviewContent, !showsVideosCarousel,
               let previewImage = currentITunesTopPreviewImage(.musicVideos) ?? moviesFallbackImage ?? musicFallbackImage
            {
                items.append(GapItemSpec(
                    key: "video:\(currentITunesTopPreviewTargetID(.musicVideos) ?? "itunes_top_music_video_preview")",
                    kind: .moviePreview(MoviePreviewSpec(
                        image: previewImage,
                        aspectRatio: aspectRatio(for: previewImage, fallback: 2.0 / 3.0),
                        sizeScale: 0.75,
                        baseIconSize: iconSize,
                        offsetX: movieGapPreviewHorizontalOffset,
                        offsetY: gapContentVerticalOffset + 8,
                        previewYaw: 10,
                        reflectionYaw: 9.8,
                    )),
                    transition: fadeAlways,
                    fade: .easeInOut(duration: 0.22),
                ))
            }
            if showsMusicCarousel {
                if let carousel = musicGapCarouselItem(exitOpacity: musicTopLevelCarouselExitOverlayOpacity) { items.append(carousel) }
            } else if showsSongsCarousel {
                if let carousel = gapCarouselItem(key: "itunes_songs_carousel", artworks: currentITunesTopCarouselArtworks(.songs), exitOpacity: iTunesTopCarouselExitOverlayOpacity) { items.append(carousel) }
            } else if showsVideosCarousel {
                if let carousel = gapCarouselItem(key: "itunes_videos_carousel", artworks: currentITunesTopCarouselArtworks(.musicVideos), exitOpacity: iTunesTopCarouselExitOverlayOpacity) { items.append(carousel) }
            }
            return items

        case "photos":
            let showsCarousel = shouldShowPhotosCarouselContent
            let hidesIcon = showsCarousel || shouldUsePhotosCarouselSlot
            let iconAnimation = pass.animation(hidesIcon ? nil : .easeInOut(duration: 0.18), when: memo.hidesPhotosRootIcon != nil && memo.hidesPhotosRootIcon != hidesIcon)
            memo.hidesPhotosRootIcon = hidesIcon
            var items = [icon(opacity: hidesIcon ? 0 : 1, animation: iconAnimation)]
            if showsCarousel, let carousel = gapCarouselItem(key: "photos_carousel", artworks: photosCarouselArtworks, exitOpacity: photosCarouselExitOverlayOpacity) {
                items.append(carousel)
            }
            return items

        case "podcasts":
            let episode = selectedPodcastEpisodeForPreview
            // (In a show's list of episodes, the show is the episode's: its picture stands in
            // for an episode that has none of its own.)
            let series = selectedPodcastSeriesForPreview ?? episode.flatMap { shown in podcastSeriesItems.first(where: { $0.id == shown.seriesID }) }
            let seriesArtwork = series?.artwork ?? podcastFallbackImage
            let seriesImage = seriesArtwork ?? image
            let episodeImage = episode?.artwork ?? seriesArtwork ?? image
            let showsEpisode = episode != nil
            let showsSeries = series != nil && !showsEpisode
            let hidesIcon = showsSeries || showsEpisode
            let iconAnimation = pass.animation(.easeInOut(duration: 0.18), when: memo.hidesPodcastsRootIcon != nil && memo.hidesPodcastsRootIcon != hidesIcon)
            memo.hidesPodcastsRootIcon = hidesIcon
            var items = [icon(opacity: hidesIcon ? 0 : 1, animation: iconAnimation)]
            if showsSeries, let series {
                let mostRecent = series.episodes.compactMap(\.airedDate).max()
                items.append(GapItemSpec(
                    key: "podcast_series_metadata:\(series.id)",
                    kind: .metadata(MetadataPreviewSpec(
                        image: seriesImage,
                        aspectRatio: aspectRatio(for: seriesImage, fallback: 1.0),
                        forcedPreviewAspectRatio: 1.0,
                        sizeScale: 0.92,
                        title: series.title,
                        description: nil,
                        lines: [
                            .init(label: "Number of Episodes", value: "\(series.episodes.count)"),
                            .init(label: "Most Recent", value: podcastEpisodeAiredText(for: mostRecent)),
                        ],
                        baseIconSize: iconSize,
                        offsetX: musicGapPreviewHorizontalOffset - 56,
                        offsetY: gapContentVerticalOffset - 8,
                        identity: "podcast_series_metadata:\(series.id)",
                    )),
                    transition: pass.transaction.disablesAnimations ? nil : .easeInOut(duration: 0.2),
                    fade: .easeInOut(duration: 0.2),
                ))
            }
            if let episode {
                let description = normalizedPodcastText(episode.description) ?? normalizedPodcastText(series?.description) ?? "No description available."
                let artist = normalizedPodcastText(episode.artist) ?? normalizedPodcastText(series?.artist) ?? "Unknown Artist"
                items.append(GapItemSpec(
                    key: "podcast_episode_metadata:\(episode.id)",
                    kind: .metadata(MetadataPreviewSpec(
                        image: episodeImage,
                        aspectRatio: aspectRatio(for: episodeImage, fallback: 1.0),
                        forcedPreviewAspectRatio: 1.0,
                        sizeScale: 0.92,
                        title: episode.title,
                        description: description,
                        lines: [
                            .init(label: "Artist", value: artist),
                            .init(label: "Length", value: podcastEpisodeLengthText(for: episode.durationSeconds)),
                            .init(label: "Aired", value: podcastEpisodeAiredText(for: episode.airedDate)),
                        ],
                        baseIconSize: iconSize,
                        offsetX: musicGapPreviewHorizontalOffset - 56,
                        offsetY: gapContentVerticalOffset - 8,
                        identity: "podcast_episode_metadata:\(episode.id)",
                        transitionDelay: 0,
                        animatesTransition: false,
                    )),
                    transition: pass.transaction.disablesAnimations ? nil : .easeInOut(duration: 0.18),
                    fade: .easeInOut(duration: 0.18),
                ))
            }
            return items

        case "settings":
            return [GapItemSpec(key: "icon", kind: .icon(image: image, reflected: false))]

        case "sources":
            return jellyfinGapContentItems(icon: { icon(opacity: $0, animation: $1) }, pass: pass, memo: &memo)

        case "youtube":
            return youtubeGapContentItems(icon: { icon(opacity: $0, animation: $1) }, pass: pass, memo: &memo)

        default:
            return [GapItemSpec(key: "icon", kind: .icon(image: image, reflected: true))]
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
        case "youtube":
            youtubeCarouselPictures != nil
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
