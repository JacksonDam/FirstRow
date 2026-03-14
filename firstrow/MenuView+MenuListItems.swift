import SwiftUI

extension MenuView {
    func currentSubmenuItems() -> [SubmenuItemConfig] {
        guard let activeRootItemID else { return [] }
        var items = MenuConfiguration.submenuItems(forRootID: activeRootItemID)
        if activeRootItemID == "music",
           isMusicActivelyPlaying || holdNowPlayingMenuItemDuringExitFade,
           !deferNowPlayingMenuItemUntilAfterFadeOut
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
        isMusicPlaybackRunning()
    }

    var shouldHideThirdMenuListUntilLoadCompletes: Bool {
        switch thirdMenuMode {
        case .moviesITunesTop:
            isLoadingITunesTop(.movies) &&
                iTunesTopMovies.isEmpty &&
                currentITunesTopLoadError(.movies) == nil
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
            var resolvedLeadingImageAssetName = $0.leadingImageAssetName
            var resolvedLeadingImage: NSImage?
            let resolvedTrailingText: String?
            if activeRootItemID == "photos", let album = photoAlbumForSubmenuItemID($0.id) {
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
            return songsItems
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
        case .songs:
            iTunesTopSongs.map { ($0.id, $0.rank, $0.title) }
        case .musicVideos:
            iTunesTopMusicVideos.map { ($0.id, $0.rank, $0.title) }
        }
    }
}
