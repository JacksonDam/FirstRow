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
        .init(id: "photos_library", title: "Library", leadsToMenu: true),
        .init(id: "photos_last_12_months", title: "Last 12 Months", leadsToMenu: true),
        .init(id: "photos_last_import", title: "Last Import", leadsToMenu: true),
    ]
    let defaultSubmenuSelectedIndex = 0
}
