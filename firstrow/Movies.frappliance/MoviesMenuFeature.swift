import Foundation

struct MoviesMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(
        id: "movies",
        title: "Videos",
        iconAssetName: "videos",
        mainMenuSelectionSoundName: "MainVideosSelection",
    )
    let submenuItems: [SubmenuItemConfig] = [
        .init(id: "movies_shared_videos", title: "Shared Videos", leadsToMenu: true),
        .init(id: "movies_theatrical_trailers", title: "Movie Trailers", leadsToMenu: true),
        .init(id: "movies_folder", title: "Movies", leadsToMenu: true),
        .init(id: "movies_itunes_top_music_videos", title: "iTunes Top Music Videos", leadsToMenu: true),
        .init(id: "movies_itunes_top_tv_episodes", title: "iTunes Top TV Episodes", leadsToMenu: true),
        .init(id: "movies_video_podcasts", title: "Video Podcasts", leadsToMenu: true),
        .init(id: "movies_itunes_top", title: "iTunes Top Movies", leadsToMenu: true),
    ]
    let defaultSubmenuSelectedIndex = 0
}
