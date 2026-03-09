import Foundation

struct PodcastsMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "podcasts", title: "Podcasts", iconAssetName: "podcasts")
    let submenuItems: [SubmenuItemConfig] = []
}
