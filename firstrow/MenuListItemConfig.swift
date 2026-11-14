import Foundation
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// The extra lines of a row that shows a video: who it's from, how long it is and how many
/// have watched it.
struct MenuRowMedia: Equatable {
    var byline: String
    var length: String
    var count: String
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
    /// Set for a video's row (its picture is the leading image).
    var media: MenuRowMedia?
    /// On the first row of a list that grows at its end as it's gone down: what the list is
    /// known by, which stays what it was as rows are added (see `MenuListLayer.identity`).
    var listKey: String?
    static func == (lhs: MenuListItemConfig, rhs: MenuListItemConfig) -> Bool {
        lhs.id == rhs.id &&
            lhs.listKey == rhs.listKey &&
            lhs.media == rhs.media &&
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
