import SwiftUI

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
