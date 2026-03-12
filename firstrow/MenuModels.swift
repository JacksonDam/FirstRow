import SwiftUI

struct RootMenuItemConfig: Identifiable, Equatable {
    let id: String
    let title: String
    let iconAssetName: String
    let leadsToMenu: Bool
    let actionID: String?
}

extension RootMenuItemConfig {
    /// by default, menu items are marked as leading to a menu (with an arrow visible on the option) but do nothing
    init(id: String, title: String, iconAssetName: String) {
        self.init(id: id, title: title, iconAssetName: iconAssetName, leadsToMenu: true, actionID: nil)
    }
}

struct SubmenuItemConfig: Identifiable, Equatable {
    let id: String
    let title: String
    let actionID: String
    let leadsToMenu: Bool
    let leadingImageAssetName: String?
    let trailingText: String?
    let trailingSymbolName: String?
    let showsTopDivider: Bool
    let showsBlueDot: Bool
    let showsLightRowBackground: Bool
    let alignsTextToDividerStart: Bool
    init(
        id: String,
        title: String,
        actionID: String,
        leadsToMenu: Bool = false,
        leadingImageAssetName: String? = nil,
        trailingText: String? = nil,
        trailingSymbolName: String? = nil,
        showsTopDivider: Bool = false,
        showsBlueDot: Bool = false,
        showsLightRowBackground: Bool = false,
        alignsTextToDividerStart: Bool = false,
    ) {
        self.id = id
        self.title = title
        self.actionID = actionID
        self.leadsToMenu = leadsToMenu
        self.leadingImageAssetName = leadingImageAssetName
        self.trailingText = trailingText
        self.trailingSymbolName = trailingSymbolName
        self.showsTopDivider = showsTopDivider
        self.showsBlueDot = showsBlueDot
        self.showsLightRowBackground = showsLightRowBackground
        self.alignsTextToDividerStart = alignsTextToDividerStart
    }

    // Convenience: actionID defaults to id (the common case).
    init(
        id: String,
        title: String,
        leadsToMenu: Bool = false,
        leadingImageAssetName: String? = nil,
        trailingText: String? = nil,
        trailingSymbolName: String? = nil,
        showsTopDivider: Bool = false,
        showsBlueDot: Bool = false,
        showsLightRowBackground: Bool = false,
        alignsTextToDividerStart: Bool = false,
    ) {
        self.init(
            id: id, title: title, actionID: id,
            leadsToMenu: leadsToMenu,
            leadingImageAssetName: leadingImageAssetName,
            trailingText: trailingText,
            trailingSymbolName: trailingSymbolName,
            showsTopDivider: showsTopDivider,
            showsBlueDot: showsBlueDot,
            showsLightRowBackground: showsLightRowBackground,
            alignsTextToDividerStart: alignsTextToDividerStart,
        )
    }
}

struct MenuListItemConfig: Identifiable, Equatable {
    let id: String
    let title: String
    let leadsToMenu: Bool
    let leadingImageAssetName: String?
    let leadingImage: NSImage?
    let trailingText: String?
    let trailingSymbolName: String?
    let showsTopDivider: Bool
    let showsBlueDot: Bool
    let showsLightRowBackground: Bool
    let alignsTextToDividerStart: Bool
    static func == (lhs: MenuListItemConfig, rhs: MenuListItemConfig) -> Bool {
        lhs.id == rhs.id &&
            lhs.title == rhs.title &&
            lhs.leadsToMenu == rhs.leadsToMenu &&
            lhs.leadingImageAssetName == rhs.leadingImageAssetName &&
            lhs.leadingImage === rhs.leadingImage &&
            lhs.trailingText == rhs.trailingText &&
            lhs.trailingSymbolName == rhs.trailingSymbolName &&
            lhs.showsTopDivider == rhs.showsTopDivider &&
            lhs.showsBlueDot == rhs.showsBlueDot &&
            lhs.showsLightRowBackground == rhs.showsLightRowBackground &&
            lhs.alignsTextToDividerStart == rhs.alignsTextToDividerStart
    }
}

struct ArrowAppearance {
    let symbolName: String
    let color: Color
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let xOffset: CGFloat
    let glowPrimaryRadius: CGFloat
    let glowSecondaryRadius: CGFloat
    let glowPrimaryOpacity: Double
    let glowSecondaryOpacity: Double
}
