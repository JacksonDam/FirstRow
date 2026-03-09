import Foundation
#if canImport(UIKit)
    import UIKit
#endif

struct SettingsMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "settings", title: "Settings", iconAssetName: "settings")
    let submenuItems: [SubmenuItemConfig]
    init() {
        #if os(macOS)
            let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
            let deviceName = UIDevice.current.name
        #endif
        submenuItems = [
            .init(id: "settings_name", title: "Name", trailingText: deviceName),
            .init(id: "settings_swversion", title: "SW Version", trailingText: "2.2.1 (314)"),
            .init(id: "settings_screensaver", title: "Screen Saver", trailingText: "On"),
            .init(id: "settings_soundeffects", title: "Sound Effects", trailingText: "On"),
        ]
    }
}
