import SwiftUI

private let musicSongsMenuListItemsCache = BoundedCache<String, [MenuListItemConfig]>(maxEntryCount: 24)

extension MenuView {
    var shouldExposeMusicNowPlayingMenuItem: Bool {
        ((hasActiveMusicPlaybackSession() && !isPodcastAudioNowPlaying) ||
            holdNowPlayingMenuItemDuringExitFade ||
            hasPendingExternalMusicRestore) &&
            !deferNowPlayingMenuItemUntilAfterFadeOut
    }

    func musicSongsMenuListItemsCacheKey() -> String {
        let storageAddress = musicSongsThirdMenuItems.withUnsafeBufferPointer { buffer -> UInt in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return UInt(bitPattern: baseAddress)
        }
        return "\(storageAddress)|\(musicSongsThirdMenuItems.count)|\(musicSongsShowsShuffleAction)"
    }

    func cachedMusicSongsThirdMenuListItems() -> [MenuListItemConfig] {
        let cacheKey = musicSongsMenuListItemsCacheKey()
        if let cached = musicSongsMenuListItemsCache.value(for: cacheKey) {
            return cached
        }
        var songsItems: [MenuListItemConfig] = musicSongsThirdMenuItems.map {
            plainMenuListItem(id: $0.id, title: $0.title)
        }
        if shouldShowMusicSongsShuffleActionItem() {
            songsItems.insert(
                plainMenuListItem(
                    id: musicSongsShuffleActionItemID,
                    title: "Shuffle Songs",
                    trailingSymbolName: "shuffle",
                ),
                at: 0,
            )
        }
        musicSongsMenuListItemsCache.store(songsItems, for: cacheKey)
        return songsItems
    }

    func currentSubmenuItems() -> [SubmenuItemConfig] {
        guard let activeRootItemID else { return [] }
        var items = MenuConfiguration.submenuItems(forRootID: activeRootItemID)
        if activeRootItemID == "music",
           shouldExposeMusicNowPlayingMenuItem
        {
            items.insert(
                SubmenuItemConfig(
                    id: "music_now_playing",
                    title: "Now Playing",
                    actionID: "music_now_playing",
                    leadsToMenu: true,
                ),
                at: 0,
            )
        }
        return items
    }

    var isMusicActivelyPlaying: Bool {
        hasActiveMusicPlaybackSession()
    }

    var shouldHideThirdMenuListUntilLoadCompletes: Bool {
        switch thirdMenuMode {
        case .moviesITunesTop:
            isLoadingITunesTop(.movies) &&
                iTunesTopMovies.isEmpty &&
                currentITunesTopLoadError(.movies) == nil
        case .tvEpisodesITunesTop:
            isLoadingITunesTop(.tvEpisodes) &&
                iTunesTopTVEpisodes.isEmpty &&
                currentITunesTopLoadError(.tvEpisodes) == nil
        case .videoPodcastSeries:
            isLoadingPodcasts &&
                filteredPodcastSeriesItems(for: .video).isEmpty &&
                podcastsLoadError == nil
        case .videoPodcastEpisodes:
            isLoadingPodcasts &&
                podcastEpisodesThirdMenuItems.isEmpty &&
                podcastsLoadError == nil
        case .musicITunesTopSongs:
            isLoadingITunesTop(.songs) &&
                iTunesTopSongs.isEmpty &&
                currentITunesTopLoadError(.songs) == nil
        case .musicITunesTopMusicVideos:
            isLoadingITunesTop(.musicVideos) &&
                iTunesTopMusicVideos.isEmpty &&
                currentITunesTopLoadError(.musicVideos) == nil
        case .audioPodcastSeries:
            isLoadingPodcasts &&
                filteredPodcastSeriesItems(for: .audio).isEmpty &&
                podcastsLoadError == nil
        case .audioPodcastEpisodes:
            isLoadingPodcasts &&
                podcastEpisodesThirdMenuItems.isEmpty &&
                podcastsLoadError == nil
        case .musicCategories:
            isLoadingMusicSongs &&
                musicCategoryThirdMenuItems.isEmpty &&
                musicSongsLoadError == nil
        case .musicSongs:
            isLoadingMusicSongs &&
                musicSongsThirdMenuItems.isEmpty &&
                musicSongsLoadError == nil
        case .photosDateAlbums:
            isLoadingPhotoLibrary &&
                photosDateAlbums.isEmpty &&
                photoLibraryLoadError == nil
        default:
            false
        }
    }

    func rootMenuTitle(for rootID: String?) -> String {
        guard let rootID, let rootItem = MenuConfiguration.rootItem(withID: rootID) else {
            return "First Row"
        }
        return rootItem.title
    }

    func rootListItems() -> [MenuListItemConfig] {
        menuItems.map { .init(
            id: $0.id,
            title: $0.title,
            leadsToMenu: $0.leadsToMenu,
            leadingImageAssetName: nil,
            leadingImage: nil,
            trailingText: nil,
            trailingSymbolName: nil,
            showsTopDivider: false,
            showsBlueDot: false,
            showsLightRowBackground: false,
            alignsTextToDividerStart: false,
        ) }
    }

    func submenuListItems() -> [MenuListItemConfig] {
        currentSubmenuItems().map {
            .init(
                id: $0.id,
                title: $0.title,
                leadsToMenu: $0.leadsToMenu,
                leadingImageAssetName: $0.leadingImageAssetName,
                leadingImage: nil,
                trailingText: $0.trailingText,
                trailingSymbolName: $0.trailingSymbolName,
                showsTopDivider: $0.showsTopDivider,
                showsBlueDot: $0.showsBlueDot,
                showsLightRowBackground: $0.showsLightRowBackground,
                alignsTextToDividerStart: $0.alignsTextToDividerStart,
            )
        }
    }

    func thirdMenuListItems() -> [MenuListItemConfig] {
        switch thirdMenuMode {
        case .moviesFolder:
            if isLoadingMoviesFolderEntries, thirdMenuItems.isEmpty {
                return []
            }
            if thirdMenuItems.isEmpty {
                return []
            }
            return thirdMenuItems.map {
                plainMenuListItem(id: $0.id, title: $0.title, leadsToMenu: $0.isDirectory)
            }
        case .moviesITunesTop:
            return iTunesTopThirdMenuListItems(for: .movies)
        case .tvEpisodesITunesTop:
            return iTunesTopThirdMenuListItems(for: .tvEpisodes)
        case .videoPodcastSeries:
            let seriesItems = filteredPodcastSeriesItems(for: .video)
            if isLoadingPodcasts, seriesItems.isEmpty {
                return []
            }
            if let podcastsLoadError, seriesItems.isEmpty {
                return [menuMessageItem(id: "video_podcasts_error", title: podcastsLoadError)]
            }
            if seriesItems.isEmpty {
                return [menuMessageItem(id: "video_podcasts_empty", title: "No Video Podcasts")]
            }
            return seriesItems.map { series in
                plainMenuListItem(
                    id: series.id,
                    title: series.title,
                    leadsToMenu: true,
                    showsBlueDot: podcastSeriesHasRecentEpisode(series),
                )
            }
        case .videoPodcastEpisodes:
            if isLoadingPodcasts, podcastEpisodesThirdMenuItems.isEmpty {
                return []
            }
            if let podcastsLoadError, podcastEpisodesThirdMenuItems.isEmpty {
                return [menuMessageItem(id: "video_podcast_episodes_error", title: podcastsLoadError)]
            }
            if podcastEpisodesThirdMenuItems.isEmpty {
                return [menuMessageItem(id: "video_podcast_episodes_empty", title: "No Downloaded Episodes")]
            }
            return podcastEpisodesThirdMenuItems.enumerated().map { index, episode in
                let trailingText = isPodcastAudioNowPlaying && activePodcastPlaybackEpisodeID == episode.id
                    ? podcastTrackPositionText(trackIndex: index, trackCount: podcastEpisodesThirdMenuItems.count)
                    : podcastEpisodeAiredText(for: episode.airedDate)
                return plainMenuListItem(
                    id: episode.id,
                    title: episode.title,
                    trailingText: trailingText,
                )
            }
        case .musicITunesTopSongs:
            return iTunesTopThirdMenuListItems(for: .songs)
        case .musicITunesTopMusicVideos:
            return iTunesTopThirdMenuListItems(for: .musicVideos)
        case .audioPodcastSeries:
            let seriesItems = filteredPodcastSeriesItems(for: .audio)
            if isLoadingPodcasts, seriesItems.isEmpty {
                return []
            }
            if let podcastsLoadError, seriesItems.isEmpty {
                return [menuMessageItem(id: "podcasts_error", title: podcastsLoadError)]
            }
            if seriesItems.isEmpty {
                return [menuMessageItem(id: "podcasts_empty", title: "No Podcasts")]
            }
            return seriesItems.map { series in
                plainMenuListItem(
                    id: series.id,
                    title: series.title,
                    leadsToMenu: true,
                    showsBlueDot: podcastSeriesHasRecentEpisode(series),
                )
            }
        case .audioPodcastEpisodes:
            if isLoadingPodcasts, podcastEpisodesThirdMenuItems.isEmpty {
                return []
            }
            if let podcastsLoadError, podcastEpisodesThirdMenuItems.isEmpty {
                return [menuMessageItem(id: "podcast_episodes_error", title: podcastsLoadError)]
            }
            if podcastEpisodesThirdMenuItems.isEmpty {
                return [menuMessageItem(id: "podcast_episodes_empty", title: "No Downloaded Episodes")]
            }
            return podcastEpisodesThirdMenuItems.enumerated().map { index, episode in
                let trailingText = isPodcastAudioNowPlaying && activePodcastPlaybackEpisodeID == episode.id
                    ? podcastTrackPositionText(trackIndex: index, trackCount: podcastEpisodesThirdMenuItems.count)
                    : podcastEpisodeAiredText(for: episode.airedDate)
                return plainMenuListItem(
                    id: episode.id,
                    title: episode.title,
                    trailingText: trailingText,
                )
            }
        case .musicCategories:
            if isLoadingMusicSongs, musicCategoryThirdMenuItems.isEmpty {
                return []
            }
            if let musicSongsLoadError {
                return [
                    menuMessageItem(id: "music_library_error", title: musicSongsLoadError),
                ]
            }
            if musicCategoryThirdMenuItems.isEmpty {
                return []
            }
            return musicCategoryThirdMenuItems.map {
                plainMenuListItem(id: $0.id, title: $0.title, leadsToMenu: true)
            }
        case .musicSongs:
            if isLoadingMusicSongs, musicSongsThirdMenuItems.isEmpty {
                return []
            }
            if let musicSongsLoadError {
                return [
                    menuMessageItem(id: "music_library_error", title: musicSongsLoadError),
                ]
            }
            if musicSongsThirdMenuItems.isEmpty {
                return []
            }
            return cachedMusicSongsThirdMenuListItems()
        case .movieResumePrompt:
            return [
                plainMenuListItem(id: "movie_resume_resume", title: "Resume Playing"),
                plainMenuListItem(id: "movie_resume_start", title: "Start from Beginning"),
            ]
        case .musicNowPlaying, .errorPage:
            return []
        case .photosDateAlbums:
            if isLoadingPhotoLibrary, photosDateAlbums.isEmpty {
                return []
            }
            if let photoLibraryLoadError, photosDateAlbums.isEmpty {
                return [
                    menuMessageItem(id: "photos_library_error", title: photoLibraryLoadError),
                ]
            }
            if photosDateAlbums.isEmpty {
                return []
            }
            return photosDateAlbumMenuItems
        case .none:
            return []
        }
    }

    func plainMenuListItem(
        id: String,
        title: String,
        leadsToMenu: Bool = false,
        leadingImageAssetName: String? = nil,
        leadingImage: NSImage? = nil,
        trailingText: String? = nil,
        trailingSymbolName: String? = nil,
        showsTopDivider: Bool = false,
        showsBlueDot: Bool = false,
        showsLightRowBackground: Bool = false,
        alignsTextToDividerStart: Bool = false,
    ) -> MenuListItemConfig {
        .init(
            id: id,
            title: title,
            leadsToMenu: leadsToMenu,
            leadingImageAssetName: leadingImageAssetName,
            leadingImage: leadingImage,
            trailingText: trailingText,
            trailingSymbolName: trailingSymbolName,
            showsTopDivider: showsTopDivider,
            showsBlueDot: showsBlueDot,
            showsLightRowBackground: showsLightRowBackground,
            alignsTextToDividerStart: alignsTextToDividerStart,
        )
    }

    func menuMessageItem(id: String, title: String) -> MenuListItemConfig {
        plainMenuListItem(id: id, title: title)
    }

    func iTunesTopThirdMenuListItems(for kind: ITunesTopCarouselKind) -> [MenuListItemConfig] {
        let entries = iTunesTopRankedTitles(for: kind)
        let kindToken = iTunesTopKindToken(kind)
        if isLoadingITunesTopCarousel(kind), entries.isEmpty {
            return []
        }
        if let loadError = iTunesTopLoadErrorText(for: kind) {
            return [menuMessageItem(id: "itunes_top_\(kindToken)_error", title: loadError)]
        }
        if entries.isEmpty {
            return [menuMessageItem(id: "itunes_top_\(kindToken)_empty", title: kind.emptyLoadMessage)]
        }
        return entries.map { entry in
            let rankText = entry.rank < 10 ? "  \(entry.rank)" : "\(entry.rank)"
            return plainMenuListItem(
                id: entry.id,
                title: "\(rankText)  \(entry.title)",
            )
        }
    }

    func iTunesTopKindToken(_ kind: ITunesTopCarouselKind) -> String {
        switch kind {
        case .movies:
            "movies"
        case .tvEpisodes:
            "tv_episodes"
        case .songs:
            "songs"
        case .musicVideos:
            "music_videos"
        }
    }

    func iTunesTopLoadErrorText(for kind: ITunesTopCarouselKind) -> String? {
        currentITunesTopLoadError(kind)
    }

    func iTunesTopRankedTitles(for kind: ITunesTopCarouselKind) -> [(id: String, rank: Int, title: String)] {
        switch kind {
        case .movies:
            iTunesTopMovies.map { ($0.id, $0.rank, $0.title) }
        case .tvEpisodes:
            iTunesTopTVEpisodes.map { ($0.id, $0.rank, $0.title) }
        case .songs:
            iTunesTopSongs.map { ($0.id, $0.rank, $0.title) }
        case .musicVideos:
            iTunesTopMusicVideos.map { ($0.id, $0.rank, $0.title) }
        }
    }
}
