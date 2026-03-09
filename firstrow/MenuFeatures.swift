import Foundation

// MARK: - Typealiases

typealias RootMenuActionHandler = (RootMenuItemConfig) -> Void
typealias SubmenuMenuActionHandler = (SubmenuItemConfig) -> Void

// MARK: - Protocol

protocol MenuFeatureConfiguration {
    var rootItem: RootMenuItemConfig { get }
    var submenuItems: [SubmenuItemConfig] { get }
    var defaultSubmenuSelectedIndex: Int { get }
    var rootActionHandlers: [String: RootMenuActionHandler] { get }
    var submenuActionHandlers: [String: SubmenuMenuActionHandler] { get }
}

extension MenuFeatureConfiguration {
    var defaultSubmenuSelectedIndex: Int {
        0
    }

    var rootActionHandlers: [String: RootMenuActionHandler] {
        [:]
    }

    var submenuActionHandlers: [String: SubmenuMenuActionHandler] {
        [:]
    }
}
