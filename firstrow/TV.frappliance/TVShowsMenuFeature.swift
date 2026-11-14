import Foundation

struct TVShowsMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "tv_shows", title: L("TV Shows"), iconAssetName: "tv_shows")
    let submenuItems: [SubmenuItemConfig] = [
        .init(id: "tv_itunestopepisodes", title: L("iTunes Top TV Episodes"), leadsToMenu: true, trailingText: "•••"),
    ]
}
