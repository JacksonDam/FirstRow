import Foundation
import QuartzCore
#if os(macOS)
    import AppKit
#endif

/// The Tiger look: four icons on a turning ring for the main menu, and each section's lists
/// as full pages that slide across under a title bar. This build has no other look, so it is
/// always on; the rest of First Row asks here wherever the Tiger look does something its own way.
enum TigerTheme {
    static var isActive: Bool { true }

    // MARK: - The ring

    static let iconSize: CGFloat = 400
    static let ringRadius: CGFloat = 480
    static let ringIntroStartRadius: CGFloat = 280
    static let ringExitEndRadius: CGFloat = 680
    static let ringTiltDegrees: Double = 26
    static let ringCenterYOffset: CGFloat = -26
    static let ringPerspectiveDistance: CGFloat = 2000
    static let ringBaseSizeMultiplier: CGFloat = 0.8
    /// The icon in front is drawn from a picture this much larger than the others', scaled down.
    static let selectedIconSizeMultiplier: CGFloat = 1.65
    /// The size the icon in front lands at beside its section's title, as a share of that picture.
    static let landedIconScale: CGFloat = 0.1512
    static let landedFinalYOffsetAdjustment: CGFloat = 30
    static let backgroundGroupLift: CGFloat = -820
    static let backgroundZDepth: CGFloat = 960
    static let detachedReflectionXOffset: CGFloat = -54
    static let detachedReflectionYOffset: CGFloat = 1140
    /// How far the ring sits above the middle of the scene.
    static let stageLift: CGFloat = 50
    static let stageRestingYOffset: CGFloat = -6

    // MARK: - The opening

    static let introStageStartYOffset: CGFloat = 2325
    static let introStageStartScale: CGFloat = 1.85
    static let introBackdropMinimumScale: CGFloat = 0.25
    static let introBackdropFinalYOffset: CGFloat = -512
    static let introDuration: Double = 2.325
    static let introBackdropDuration: Double = 2.75
    static let introStartDelay: Double = 0.05
    static let introLabelStartDelay: Double = 1.5
    static let introLabelFadeDuration: Double = 0.25
    static let introCurve = TimingCurve(c1: CGPoint(x: 0.45, y: 0), c2: CGPoint(x: 0.34, y: 1))

    // MARK: - Titles and pages

    static let titleSize: CGFloat = 92
    static let headerTopInset: CGFloat = 40
    static let headerIconOpticalYOffset: CGFloat = 10
    static let headerIconTitleSpacing: CGFloat = 24
    static let dividerTopInset: CGFloat = 160
    static let dividerThickness: CGFloat = 6
    static let listClipTopInset: CGFloat = 206
    static let selectionTopInset: CGFloat = 560
    static let selectionHeight: CGFloat = 140
    static let rowHeight: CGFloat = 128
    static let rowPitch: CGFloat = 115
    static let rowContentVerticalOffset: CGFloat = -5
    static let visibleRowCount = 4
    static let rowTitleSize: CGFloat = 69
    static let rowTrailingSize: CGFloat = 53
    static let rowArrowSize: CGFloat = 65
    static let rowTextLeadingInset: CGFloat = 72
    static let rowTrailingSymbolRightInset: CGFloat = 206
    static let columnWidth: CGFloat = 1440
    static let columnLeading: CGFloat = 405
    /// A page with a preview on its left has a narrower list.
    static let compactColumnWidth: CGFloat = 1225
    static let compactColumnLeading: CGFloat = 628

    // MARK: - Timings

    static let iconFlightDuration: Double = 1.0
    static let backgroundIconReturnDuration: Double = 1.1
    static let pageSlideDuration: Double = 0.6
    static let ringTurnDurationMultiplier: Double = 1.7
    static let labelFadeOutDuration: Double = 0.12
    static let labelFadeInDuration: Double = 0.18

    /// The shadow under the look's lettering.
    static let textShadow = [TextShadow(color: RGBA(white: 0, alpha: 0.55), radius: 5, offset: CGSize(width: 0, height: 4))]

    /// The sound a section makes as it opens from the ring.
    static func selectionSound(forRootID id: String) -> String {
        switch id {
        case "dvd": "MainDVDSelection"
        case "music": "MainMusicSelection"
        case "photos": "MainPhotosSelection"
        case "movies": "MainVideosSelection"
        default: "Selection"
        }
    }

    static let soundNames = [
        "Selection", "SelectionChange", "Exit", "Limit", "Begin", "End", "MainLeft", "MainTransitionFrom",
        "MainDVDSelection", "MainMusicSelection", "MainPhotosSelection", "MainVideosSelection",
    ]

    /// The picture each section's icon is drawn from.
    static func iconAssetName(forRootID id: String) -> String {
        switch id {
        case "music": "tiger_music"
        case "photos": "tiger_photos"
        case "movies": "videos"
        default: "dvd"
        }
    }

    /// A little lower for the clapperboard, which sits high in its picture.
    static func iconOpticalYOffset(forRootID id: String?) -> CGFloat {
        id == "movies" ? 18 : 0
    }
}

/// The desktop as it was just before First Row covered it, which draws back as the ring rises.
@MainActor
enum TigerDesktop {
    static var picture: NSImage?
}

#if os(macOS)
    extension TigerDesktop {
        /// Takes the screen's picture as it is now, before First Row's window comes up over it.
        static func capture() {
            let frame = NSScreen.main?.frame ?? .zero
            guard frame.width > 0, let image = CGWindowListCreateImage(.infinite, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else { return }
            picture = NSImage(cgImage: image, size: frame.size)
        }
    }
#endif
