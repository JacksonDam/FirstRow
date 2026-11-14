import Foundation
import QuartzCore
#if os(macOS)
    import AppKit
#endif

/// Where the main menu's icons stand: on a tilted ring, the section in front largest.
@MainActor
enum TigerRing {
    struct Placement {
        var x: CGFloat
        var y: CGFloat
        var depth: CGFloat
        var scale: CGFloat
    }

    /// The icon's side at rest, before the ring's perspective scales it.
    static let iconSide = TigerTheme.iconSize * TigerTheme.ringBaseSizeMultiplier
    /// The side of the picture the icon in front is drawn from as it flies to the title bar.
    static let flightSide = TigerTheme.iconSize * TigerTheme.selectedIconSizeMultiplier
    static let landedIconWidth = flightSide * TigerTheme.landedIconScale

    /// The offset from the ring's middle of the icon `index`, with the ring turned to `selection`.
    static func placement(index: Int, selection: Double, count: Int, radius: CGFloat) -> Placement {
        let visible = max(1, min(count, 4))
        let angle = (Double(index) - selection) * (2 * Double.pi / Double(visible))
        let tilt = TigerTheme.ringTiltDegrees * .pi / 180
        // The icons at the sides stand a little out and up from the true circle.
        let side = max(0, 1 - abs(CGFloat(cos(angle))))
        let depth = radius * CGFloat(cos(angle))
        let projected = depth * CGFloat(cos(tilt))
        return Placement(
            x: radius * CGFloat(sin(angle)) + (sin(angle) < 0 ? -18 : 18) * side,
            y: TigerTheme.ringCenterYOffset + depth * CGFloat(sin(tilt)) - 60 * side,
            depth: projected,
            scale: TigerTheme.ringPerspectiveDistance / max(1, TigerTheme.ringPerspectiveDistance - projected),
        )
    }

    /// How far below its place the whole ring is part way through the opening.
    static func stageYOffset(intro: CGFloat, sceneHeight: CGFloat) -> CGFloat {
        tigerMix(max(TigerTheme.introStageStartYOffset, sceneHeight * 1.45), TigerTheme.stageRestingYOffset, tigerUnit(intro))
    }

    /// The middle of the ring's own space in the scene, before the opening's offset.
    static func stageCenter(sceneSize: CGSize) -> CGPoint {
        CGPoint(x: sceneSize.width * 0.5, y: sceneSize.height * 0.5 - TigerTheme.stageLift)
    }

    // MARK: - The title bar

    static func titleWidth(_ title: String) -> CGFloat {
        ceil(FontMetrics.width(title, fontName: firstRowBoldFontName, size: TigerTheme.titleSize))
    }

    /// The middle of a section's icon where it lands beside its title, the two centred together.
    static func landedIconCenter(rootID: String?, title: String, sceneSize: CGSize) -> CGPoint {
        let total = landedIconWidth + TigerTheme.headerIconTitleSpacing + titleWidth(title)
        let center = stageCenter(sceneSize: sceneSize)
        let landedY = -(sceneSize.height * 0.5 - TigerTheme.headerTopInset - landedIconWidth * 0.5) + TigerTheme.landedFinalYOffsetAdjustment
        return CGPoint(
            x: center.x - total * 0.5 + landedIconWidth * 0.5,
            y: center.y + TigerTheme.stageRestingYOffset + landedY + TigerTheme.headerIconOpticalYOffset
                + TigerTheme.iconOpticalYOffset(forRootID: rootID) * TigerTheme.landedIconScale,
        )
    }

    static func landedTitleCenter(rootID: String?, title: String, sceneSize: CGSize) -> CGPoint {
        let icon = landedIconCenter(rootID: rootID, title: title, sceneSize: sceneSize)
        return CGPoint(x: icon.x + landedIconWidth * 0.5 + TigerTheme.headerIconTitleSpacing + titleWidth(title) * 0.5, y: icon.y)
    }

    /// The middle of the title under the ring.
    static func rootLabelCenter(sceneSize: CGSize) -> CGPoint {
        CGPoint(x: sceneSize.width * 0.5, y: sceneSize.height - 40 - TigerTheme.titleSize * 0.5)
    }

    // MARK: - Pictures

    private static var reflections: [String: CGImage] = [:]

    /// An icon as the floor shows it: fainter, and fainter still further from the icon.
    static func reflectionImage(forRootID id: String, of icon: CGImage) -> CGImage? {
        if let made = reflections[id] { return made }
        let width = icon.width, height = icon.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ScreenColorSpace.current ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(icon, in: bounds)
        // (Bitmap rows run upwards: the icon's foot, which the reflection starts at, is at 0.)
        context.setBlendMode(.destinationIn)
        let colors = [CGColor(gray: 0, alpha: 0.88 * 0.34), CGColor(gray: 0, alpha: 0.44 * 0.34), CGColor(gray: 0, alpha: 0.44 * 0.34)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 0.75, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: CGFloat(height)), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let image = context.makeImage()
        reflections[id] = image
        return image
    }
}
