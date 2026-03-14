import Foundation

struct MusicMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(
        id: "music",
        title: "Music",
        iconAssetName: "music",
        mainMenuSelectionSoundName: "MainMusicSelection",
    )
    let submenuItems: [SubmenuItemConfig] = [
        .init(id: "music_shuffle_songs", title: "Shuffle Songs", trailingSymbolName: "shuffle"),
        .init(id: "music_music_videos", title: "Music Videos", leadsToMenu: true),
        .init(id: "music_playlists", title: "Playlists", leadsToMenu: true),
        .init(id: "music_artists", title: "Artists", leadsToMenu: true),
        .init(id: "music_albums", title: "Albums", leadsToMenu: true),
        .init(id: "music_songs", title: "Songs", leadsToMenu: true),
        .init(id: "music_genres", title: "Genres", leadsToMenu: true),
        .init(id: "music_composers", title: "Composers", leadsToMenu: true),
        .init(id: "music_audiobooks", title: "Audiobooks", leadsToMenu: true),
        .init(
            id: "music_itunes_top_songs",
            title: "iTunes Top Songs",
            leadsToMenu: true,
            trailingText: "•••",
            showsTopDivider: true,
        ),
        .init(id: "music_itunes_top_music_videos", title: "iTunes Top Music Videos", leadsToMenu: true, trailingText: "•••"),
    ]
    let defaultSubmenuSelectedIndex = 0
}
