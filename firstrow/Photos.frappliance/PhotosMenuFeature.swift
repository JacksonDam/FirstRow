import Foundation

struct PhotosMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(
        id: "photos",
        title: "Photos",
        iconAssetName: "photos",
        mainMenuSelectionSoundName: "MainPhotosSelection",
    )
    let submenuItems: [SubmenuItemConfig] = [
        .init(id: "photos_shared", title: "Shared Photos", leadsToMenu: true),
        .init(id: "photos_library", title: "Photos", leadsToMenu: true, leadingImageAssetName: "photos"),
        .init(id: "photos_last_12_months", title: "Last 12 Months", leadingImageAssetName: "photos", trailingText: "(0)"),
        .init(id: "photos_last_import", title: "Last Import", leadingImageAssetName: "Alert!", trailingText: "(0)"),
    ]
    let defaultSubmenuSelectedIndex = 1
}
