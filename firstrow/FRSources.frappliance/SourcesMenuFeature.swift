import Foundation
#if canImport(UIKit)
    import UIKit
#endif

struct SourcesMenuFeature: MenuFeatureConfiguration {
    let rootItem = RootMenuItemConfig(id: "sources", title: L("Sources"), iconAssetName: "sources")
    let submenuItems: [SubmenuItemConfig]
    init() {
        #if os(macOS)
            let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #elseif FIRSTROW_PORTABLE
            let deviceName = portableDeviceName
        #else
            let deviceName = UIDevice.current.name
        #endif
        submenuItems = [
            .init(
                id: "sources_this_device",
                title: deviceName,
                leadsToMenu: true,
                trailingText: "...",
            ),
        ]
    }
}
