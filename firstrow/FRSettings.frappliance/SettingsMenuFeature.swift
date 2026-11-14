import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// First Row's version, as Settings shows it and Jellyfin is told.
enum FirstRowVersion {
    /// Kept the same as MARKETING_VERSION, for Linux and Windows, whose builds have no Info.plist.
    static let number = "2.4.4"

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? number
    }
}

struct SettingsMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "settings", title: L("Settings"), iconAssetName: "settings")
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
            .init(id: "settings_name", title: L("Name"), trailingText: deviceName),
            .init(id: "settings_swversion", title: L("SW Version"), trailingText: FirstRowVersion.current),
            .init(id: "settings_screensaver", title: L("Screen Saver"), leadsToMenu: true, trailingText: L("1 Minute")),
            .init(id: "settings_soundeffects", title: L("Sound Effects"), trailingText: L("On")),
            .init(id: "settings_theme", title: L("Theme"), trailingText: L("Classic")),
            .init(id: "settings_intromovie", title: L("Intro Movie"), trailingText: L("On")),
            .init(id: "settings_youtube", title: L("YouTube"), trailingText: L("Off")),
        ]
        #if os(macOS) || FIRSTROW_PORTABLE
            submenuItems.append(.init(id: "settings_media_folders", title: L("Media Folders"), trailingText: "..."))
        #endif
    }
}
