import Foundation

struct MusicMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "music", title: L("Music"), iconAssetName: "music")
    var submenuItems: [SubmenuItemConfig] {
        var items = Self.libraryItems
        if SpotifySessionSupport.isAvailable {
            items.append(.init(id: "music_spotify", title: L("Spotify"), leadsToMenu: true, showsTopDivider: true))
        }
        return items
    }

    private static let libraryItems: [SubmenuItemConfig] = [
        .init(id: "music_itunes_top_songs", title: L("iTunes Top Songs"), leadsToMenu: true, trailingText: "•••"),
        .init(id: "music_itunes_top_music_videos", title: L("iTunes Top Music Videos"), leadsToMenu: true, trailingText: "•••"),
        .init(id: "music_shuffle_songs", title: L("Shuffle Songs"), trailingSymbolName: "shuffle", showsTopDivider: true),
        .init(id: "music_music_videos", title: L("Music Videos"), leadsToMenu: true),
        .init(id: "music_playlists", title: L("Playlists"), leadsToMenu: true),
        .init(id: "music_artists", title: L("Artists"), leadsToMenu: true),
        .init(id: "music_albums", title: L("Albums"), leadsToMenu: true),
        .init(id: "music_songs", title: L("Songs"), leadsToMenu: true),
        .init(id: "music_genres", title: L("Genres"), leadsToMenu: true),
        .init(id: "music_composers", title: L("Composers"), leadsToMenu: true),
        .init(id: "music_audiobooks", title: L("Audiobooks"), leadsToMenu: true),
    ]
    let defaultSubmenuSelectedIndex = 2
}
