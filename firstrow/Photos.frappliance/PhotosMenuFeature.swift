import Foundation

struct PhotosMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "photos", title: "Photos", iconAssetName: "photos")
    let submenuItems: [SubmenuItemConfig] = [
        .init(id: "photos_shared", title: "Shared Photos", leadsToMenu: true, trailingText: "•••", alignsTextToDividerStart: true),
        .init(id: "photos_library", title: "Photos", leadsToMenu: true, leadingImageAssetName: "photos", showsTopDivider: true, showsLightRowBackground: true),
        .init(id: "photos_last_12_months", title: "Last 12 Months", leadingImageAssetName: "photos", trailingText: "(0)", showsLightRowBackground: true),
        .init(id: "photos_last_import", title: "Last Import", leadingImageAssetName: "Alert!", trailingText: "(0)", showsLightRowBackground: true),
    ]
    let defaultSubmenuSelectedIndex = 1
}
