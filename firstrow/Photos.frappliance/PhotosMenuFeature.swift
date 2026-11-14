import Foundation

struct PhotosMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "photos", title: L("Photos"), iconAssetName: "photos")
    let submenuItems: [SubmenuItemConfig] = [
        .init(id: "photos_shared", title: L("Shared Photos"), leadsToMenu: true, trailingText: "•••", alignsTextToDividerStart: true),
        .init(id: "photos_library", title: L("Photos"), leadsToMenu: true, leadingImageAssetName: "photos", showsTopDivider: true, showsLightRowBackground: true),
        .init(id: "photos_last_12_months", title: L("Last 12 Months"), leadingImageAssetName: "photos", trailingText: "(0)", showsLightRowBackground: true),
        .init(id: "photos_last_import", title: L("Last Import"), leadingImageAssetName: "Alert!", trailingText: "(0)", showsLightRowBackground: true),
    ]
    let defaultSubmenuSelectedIndex = 1
}
