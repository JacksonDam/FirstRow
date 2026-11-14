import Foundation

struct MoviesMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "movies", title: L("Movies"), iconAssetName: "movies")
    let submenuItems: [SubmenuItemConfig] = [
        .init(id: "movies_itunes_top", title: L("iTunes Top Movies"), leadsToMenu: true, trailingText: "•••"),
        .init(id: "movies_folder", title: L("Movies Folder"), leadsToMenu: true),
    ]
    let defaultSubmenuSelectedIndex = 0
}
