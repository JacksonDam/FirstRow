import Foundation

struct YouTubeMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "youtube", title: L("YouTube"), iconAssetName: "youtube")
    /// (Made as the menu opens, from the lists it offers: see `youtubeSubmenuItems`.)
    let submenuItems: [SubmenuItemConfig] = []
}
