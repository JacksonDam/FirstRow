import Foundation

struct PodcastsMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "podcasts", title: L("Podcasts"), iconAssetName: "podcasts")
    let submenuItems: [SubmenuItemConfig] = []
}
