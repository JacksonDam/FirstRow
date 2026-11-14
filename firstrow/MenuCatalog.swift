import Foundation

struct MenuCatalog {
    private let features: [any MenuFeatureConfiguration]
    private let rootItemsByID: [String: RootMenuItemConfig]
    private let submenuItemsByRootID: [String: [SubmenuItemConfig]]
    private let defaultSubmenuSelectedIndexByRootID: [String: Int]
    private let rootActionHandlersByID: [String: RootMenuActionHandler]
    private let submenuActionHandlersByID: [String: SubmenuMenuActionHandler]
    init(features: [any MenuFeatureConfiguration]) {
        self.features = features
        rootItemsByID = Dictionary(
            uniqueKeysWithValues: features.map { ($0.rootItem.id, $0.rootItem) },
        )
        submenuItemsByRootID = Dictionary(
            uniqueKeysWithValues: features.map { ($0.rootItem.id, $0.submenuItems) },
        )
        defaultSubmenuSelectedIndexByRootID = Dictionary(
            uniqueKeysWithValues: features.map { ($0.rootItem.id, $0.defaultSubmenuSelectedIndex) },
        )
        var rootHandlers: [String: RootMenuActionHandler] = [:]
        var submenuHandlers: [String: SubmenuMenuActionHandler] = [:]
        for feature in features {
            for (actionID, handler) in feature.rootActionHandlers {
                rootHandlers[actionID] = handler
            }
            for (actionID, handler) in feature.submenuActionHandlers {
                submenuHandlers[actionID] = handler
            }
        }
        rootActionHandlersByID = rootHandlers
        submenuActionHandlersByID = submenuHandlers
    }

    var rootItems: [RootMenuItemConfig] {
        features.map(\.rootItem)
    }

    func rootItem(withID id: String) -> RootMenuItemConfig? {
        rootItemsByID[id]
    }

    func submenuItems(forRootID rootID: String) -> [SubmenuItemConfig] {
        submenuItemsByRootID[rootID] ?? []
    }

    func defaultSubmenuSelectedIndex(forRootID rootID: String) -> Int {
        defaultSubmenuSelectedIndexByRootID[rootID] ?? 0
    }

    func imageName(forRootID rootID: String) -> String? {
        rootItemsByID[rootID]?.iconAssetName
    }

    func rootActionHandler(forActionID actionID: String) -> RootMenuActionHandler? {
        rootActionHandlersByID[actionID]
    }

    func submenuActionHandler(forActionID actionID: String) -> SubmenuMenuActionHandler? {
        submenuActionHandlersByID[actionID]
    }
}
