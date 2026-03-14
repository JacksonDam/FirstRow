import Foundation

struct DVDMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(
        id: "dvd",
        title: "DVD",
        iconAssetName: "dvd",
        mainMenuSelectionSoundName: "MainDVDSelection",
    )
    let submenuItems: [SubmenuItemConfig] = [
        .init(id: "dvd_no_disc", title: "Please Insert a DVD"),
    ]
}
