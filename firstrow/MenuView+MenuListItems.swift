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
        if activeRootItemID == "podcasts" {
            return podcastsSubmenuItems()
        }
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
        isMusicPlaybackRunning() && !isPodcastAudioNowPlaying
    }

    var shouldHideSubmenuListUntilLoadCompletes: Bool {
        activeRootItemID == "podcasts" &&
            isLoadingPodcasts &&
            podcastSeriesItems.isEmpty &&
            podcastsLoadError == nil
    }

    var shouldHidePodcastsSubmenuChromeUntilLoadCompletes: Bool {
        shouldHideSubmenuListUntilLoadCompletes
    }

    var shouldHideThirdMenuListUntilLoadCompletes: Bool {
        switch thirdMenuMode {
        case .moviesITunesTop:
            isLoadingITunesTop(.movies) &&
                iTunesTopMovies.isEmpty &&
                currentITunesTopLoadError(.movies) == nil
        case .tvITunesTopEpisodes:
            isLoadingITunesTop(.tvEpisodes) &&
                iTunesTopTVEpisodes.isEmpty &&
                currentITunesTopLoadError(.tvEpisodes) == nil
        case .musicITunesTopSongs:
            isLoadingITunesTop(.songs) &&
                iTunesTopSongs.isEmpty &&
                currentITunesTopLoadError(.songs) == nil
        case .musicITunesTopMusicVideos:
            isLoadingITunesTop(.musicVideos) &&
                iTunesTopMusicVideos.isEmpty &&
                currentITunesTopLoadError(.musicVideos) == nil
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
        case .podcastsEpisodes:
            isLoadingPodcasts &&
                podcastEpisodesThirdMenuItems.isEmpty &&
                podcastsLoadError == nil
        default:
            false
        }
    }

    func rootMenuTitle(for rootID: String?) -> String {
        guard let rootID, let rootItem = menuItems.first(where: { $0.id == rootID }) else {
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
            let resolvedTrailingText: String?
            var resolvedLeadingImageAssetName = $0.leadingImageAssetName
            var resolvedLeadingImage: NSImage?
            if activeRootItemID == "settings", $0.id == "settings_soundeffects" {
                resolvedTrailingText = isUISoundEffectsEnabled ? "On" : "Off"
            } else if activeRootItemID == "settings", $0.id == "settings_screensaver" {
                resolvedTrailingText = isScreenSaverEnabled ? "On" : "Off"
            } else if activeRootItemID == "photos", let album = photoAlbumForSubmenuItemID($0.id) {
                resolvedTrailingText = "(\(album.count))"
                resolvedLeadingImage = photoLeadingImage(for: album)
                if resolvedLeadingImage != nil {
                    resolvedLeadingImageAssetName = nil
                }
            } else {
                resolvedTrailingText = $0.trailingText
            }
            return .init(
                id: $0.id,
                title: $0.title,
                leadsToMenu: $0.leadsToMenu,
                leadingImageAssetName: resolvedLeadingImageAssetName,
                leadingImage: resolvedLeadingImage,
                trailingText: resolvedTrailingText,
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
        case .tvITunesTopEpisodes:
            return iTunesTopThirdMenuListItems(for: .tvEpisodes)
        case .musicITunesTopSongs:
            return iTunesTopThirdMenuListItems(for: .songs)
        case .musicITunesTopMusicVideos:
            return iTunesTopThirdMenuListItems(for: .musicVideos)
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
        case .podcastsEpisodes:
            if isLoadingPodcasts, podcastEpisodesThirdMenuItems.isEmpty {
                return []
            }
            if let podcastsLoadError, podcastEpisodesThirdMenuItems.isEmpty {
                return [
                    menuMessageItem(id: "podcasts_episodes_error", title: podcastsLoadError),
                ]
            }
            if podcastEpisodesThirdMenuItems.isEmpty {
                return [
                    menuMessageItem(
                        id: "podcasts_episodes_empty",
                        title: "No Downloaded Episodes",
                    ),
                ]
            }
            return podcastEpisodesThirdMenuItems.enumerated().map { index, episode in
                let isActiveAudioEpisode =
                    isPodcastAudioNowPlaying &&
                    activePodcastPlaybackEpisodeID == episode.id
                let resolvedTrailingText = isActiveAudioEpisode
                    ? podcastTrackPositionText(
                        trackIndex: index,
                        trackCount: podcastEpisodesThirdMenuItems.count,
                    )
                    : podcastEpisodeAiredText(for: episode.airedDate)
                return .init(
                    id: episode.id,
                    title: episode.title,
                    leadsToMenu: false,
                    leadingImageAssetName: nil,
                    leadingImage: nil,
                    trailingText: resolvedTrailingText,
                    trailingSymbolName: nil,
                    showsTopDivider: false,
                    showsBlueDot: podcastEpisodeIsRecent(episode.airedDate),
                    showsLightRowBackground: false,
                    alignsTextToDividerStart: false,
                )
            }
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
