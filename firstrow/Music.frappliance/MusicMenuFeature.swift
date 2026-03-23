import Foundation

struct MusicMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(
        id: "music",
        title: "Music",
        iconAssetName: "music",
        mainMenuSelectionSoundName: "MainMusicSelection",
    )
    let submenuItems: [SubmenuItemConfig] = [
        // Now Playing is inserted dynamically at index 0 by currentSubmenuItems() when active.
        .init(id: "music_shuffle_songs", title: "Shuffle Songs", trailingSymbolName: "shuffle"),
        .init(id: "music_shared", title: "Shared Music", leadsToMenu: true),
        .init(id: "music_playlists", title: "Playlists", leadsToMenu: true),
        .init(id: "music_artists", title: "Artists", leadsToMenu: true),
        .init(id: "music_albums", title: "Albums", leadsToMenu: true),
        .init(id: "music_songs", title: "Songs", leadsToMenu: true),
        .init(id: "music_podcasts", title: "Podcasts", leadsToMenu: true),
        .init(id: "music_genres", title: "Genres", leadsToMenu: true),
        .init(id: "music_composers", title: "Composers", leadsToMenu: true),
        .init(id: "music_audiobooks", title: "Audiobooks", leadsToMenu: true),
        .init(id: "music_itunes_top_songs", title: "iTunes Top Songs", leadsToMenu: true),
    ]
    let defaultSubmenuSelectedIndex = 0
}
