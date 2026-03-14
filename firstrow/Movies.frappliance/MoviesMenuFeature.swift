import Foundation

struct MoviesMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(
        id: "movies",
        title: "Videos",
        iconAssetName: "videos",
        mainMenuSelectionSoundName: "MainVideosSelection",
    )
    let submenuItems: [SubmenuItemConfig] = [
        .init(id: "movies_folder", title: "Movies", leadsToMenu: true),
        .init(
            id: "movies_theatrical_trailers",
            title: "Theatrical Trailers",
            leadsToMenu: true,
            trailingText: "•••",
            showsTopDivider: true,
        ),
        .init(id: "movies_itunes_top", title: "iTunes Top Movies", leadsToMenu: true, trailingText: "•••"),
    ]
    let defaultSubmenuSelectedIndex = 0
}
