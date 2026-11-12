import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// First Row's version, as Settings shows it and Jellyfin is told.
enum FirstRowVersion {
    /// Kept the same as MARKETING_VERSION, for Linux and Windows, whose builds have no Info.plist.
    static let number = "2.4.0"

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? number
    }
}

struct SettingsMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "settings", title: "Settings", iconAssetName: "settings")
    var submenuItems: [SubmenuItemConfig]
    init() {
        #if os(macOS)
            let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #elseif FIRSTROW_PORTABLE
            let deviceName = portableDeviceName
        #else
            let deviceName = UIDevice.current.name
        #endif
        submenuItems = [
            .init(id: "settings_name", title: "Name", trailingText: deviceName),
            .init(id: "settings_swversion", title: "SW Version", trailingText: FirstRowVersion.current),
            .init(id: "settings_screensaver", title: "Screen Saver", leadsToMenu: true, trailingText: "1 Minute"),
            .init(id: "settings_soundeffects", title: "Sound Effects", trailingText: "On"),
            .init(id: "settings_theme", title: "Theme", trailingText: "Classic"),
            .init(id: "settings_intromovie", title: "Intro Movie", trailingText: "On"),
            .init(id: "settings_youtube", title: "YouTube", trailingText: "Off"),
        ]
        #if os(macOS) || FIRSTROW_PORTABLE
            submenuItems.append(.init(id: "settings_media_folders", title: "Media Folders", trailingText: "..."))
        #endif
    }
}
