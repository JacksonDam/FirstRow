import Foundation

// The Tiger look's main menu: four sections on the ring, each with its own list.

struct TigerVideosMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "movies", title: L("Videos"), iconAssetName: "videos")
    let submenuItems: [SubmenuItemConfig] = [
        .init(id: "movies_shared_videos", title: L("Shared Videos"), leadsToMenu: true),
        .init(id: "movies_theatrical_trailers", title: L("Movie Trailers"), leadsToMenu: true),
        .init(id: "movies_folder", title: L("Movies"), leadsToMenu: true),
        .init(id: "movies_itunes_top_music_videos", title: L("iTunes Top Music Videos"), leadsToMenu: true),
        .init(id: "movies_itunes_top_tv_episodes", title: L("iTunes Top TV Episodes"), leadsToMenu: true),
        .init(id: "movies_video_podcasts", title: L("Video Podcasts"), leadsToMenu: true),
        .init(id: "movies_itunes_top", title: L("iTunes Top Movies"), leadsToMenu: true),
    ]
    let defaultSubmenuSelectedIndex = 0
}

struct TigerMusicMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "music", title: L("Music"), iconAssetName: "tiger_music")
    // (Now Playing heads the list while something plays: see `tigerSubmenuItems`.)
    let submenuItems: [SubmenuItemConfig] = [
        .init(id: "music_shuffle_songs", title: L("Shuffle Songs"), trailingSymbolName: "shuffle"),
        .init(id: "music_shared", title: L("Shared Music"), leadsToMenu: true),
        .init(id: "music_playlists", title: L("Playlists"), leadsToMenu: true),
        .init(id: "music_artists", title: L("Artists"), leadsToMenu: true),
        .init(id: "music_albums", title: L("Albums"), leadsToMenu: true),
        .init(id: "music_songs", title: L("Songs"), leadsToMenu: true),
        .init(id: "music_podcasts", title: L("Podcasts"), leadsToMenu: true),
        .init(id: "music_genres", title: L("Genres"), leadsToMenu: true),
        .init(id: "music_composers", title: L("Composers"), leadsToMenu: true),
        .init(id: "music_audiobooks", title: L("Audiobooks"), leadsToMenu: true),
        .init(id: "music_itunes_top_songs", title: L("iTunes Top Songs"), leadsToMenu: true),
    ]
    let defaultSubmenuSelectedIndex = 0
}

struct TigerPhotosMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "photos", title: L("Photos"), iconAssetName: "tiger_photos")
    let submenuItems: [SubmenuItemConfig] = [
        .init(id: "photos_shared", title: L("Shared Photos"), leadsToMenu: true),
        .init(id: "photos_library", title: L("Library"), leadsToMenu: true),
        .init(id: "photos_last_12_months", title: L("Last 12 Months"), leadsToMenu: true),
        .init(id: "photos_last_roll", title: L("Last Roll"), leadsToMenu: true),
    ]
    let defaultSubmenuSelectedIndex = 0
}

struct TigerDVDMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "dvd", title: L("DVD"), iconAssetName: "dvd")
    let submenuItems: [SubmenuItemConfig] = []
}

enum TigerMenus {
    /// The ring's sections, in the order they stand on it.
    static let features: [any MenuFeatureConfiguration] = [
        TigerVideosMenuFeature(),
        TigerMusicMenuFeature(),
        TigerPhotosMenuFeature(),
        TigerDVDMenuFeature(),
    ]

    /// The look's own words in German (the rest are in `German`).
    static let german: [String: String] = [
        "Videos": "Videos",
        "Shared Videos": "Geteilte Videos",
        "Movie Trailers": "Filmtrailer",
        "Video Podcasts": "Videopodcasts",
        "Shared Music": "Geteilte Musik",
        "Library": "Mediathek",
        "Last Roll": "Letzter Film",
        "Please Insert a DVD": "Bitte eine DVD einlegen",
        "No Video Podcasts": "Keine Videopodcasts",
        "No Podcasts": "Keine Podcasts",
    ]
}
