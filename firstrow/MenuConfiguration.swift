import SwiftUI

enum MenuConfiguration {
    private static let catalog = MenuCatalog(features: [
        MoviesMenuFeature(),
        MusicMenuFeature(),
        PhotosMenuFeature(),
        DVDMenuFeature(),
    ])
    static var rootItems: [RootMenuItemConfig] {
        catalog.rootItems
    }

    static let defaultArrowAppearance = ArrowAppearance(
        symbolName: "chevron.right",
        color: .white,
        fontSize: 36,
        fontWeight: .heavy,
        xOffset: -4,
        glowPrimaryRadius: 1.8,
        glowSecondaryRadius: 3.8,
        glowPrimaryOpacity: 0.9,
        glowSecondaryOpacity: 0.65,
    )
    static func rootItem(withID id: String) -> RootMenuItemConfig? {
        catalog.rootItem(withID: id)
    }

    static func submenuItems(forRootID id: String) -> [SubmenuItemConfig] {
        catalog.submenuItems(forRootID: id)
    }

    static func defaultSubmenuSelectedIndex(forRootID id: String) -> Int {
        catalog.defaultSubmenuSelectedIndex(forRootID: id)
    }

    static func imageName(forRootID id: String) -> String? {
        catalog.imageName(forRootID: id)
    }

    static func performRootAction(for item: RootMenuItemConfig) {
        guard let actionID = item.actionID else {
            return
        }
        if let handler = catalog.rootActionHandler(forActionID: actionID) {
            handler(item)
            return
        }
    }

    static func performSubmenuAction(for item: SubmenuItemConfig) {
        if let handler = catalog.submenuActionHandler(forActionID: item.actionID) {
            handler(item)
            return
        }
    }
}
