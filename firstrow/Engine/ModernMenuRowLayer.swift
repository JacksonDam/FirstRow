import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// A row in the modern look: a translucent capsule with the title on the left and its value
/// and chevron on the right. Focus jumps straight to a row, which turns white with dark text and
/// grows a little; only the growing and shrinking animate.
@MainActor
final class ModernMenuRowLayer: MenuRowLayering {
    let layer = SceneLayer()
    private let shadow = ModernRowShadow()
    private let capsule = SceneLayer()
    private let content = SceneLayer()
    private let leadingImage = SceneLayer()
    private let light = ModernRowInk()
    private let dark = ModernRowInk()
    private let blueDot = SceneLayer()
    private var spec: MenuRowLayer.Spec?

    /// How focus growth animates for the rows being updated (nil while a held arrow sweeps
    /// through a list, so rows don't trail behind it). Set by the list before each update.
    static var focusAnimation: Animation? = .smooth(duration: ModernTheme.focusDuration)
    /// Focus leaving: a quick fade, quicker still while a held arrow races along.
    private static var unfocusAnimation: Animation {
        .smooth(duration: min(0.22, focusAnimation?.duration ?? 0.22))
    }

    init() {
        capsule.backgroundColor = ModernTheme.rowFill.cgColor
        leadingImage.masksToBounds = true
        layer.addSublayer(shadow.layer)
        layer.addSublayer(capsule)
        layer.addSublayer(content)
        for sublayer in [leadingImage, light.layer, dark.layer, blueDot] {
            content.addSublayer(sublayer)
        }
    }

    /// Modern rows draw their own capsule, and sections are set apart by space alone.
    func updateDecorations(divider _: CGRect?, background _: CGRect?) {}

    func update(_ spec: MenuRowLayer.Spec, menu: MenuView) {
        guard spec != self.spec else { return }
        let previous = self.spec
        self.spec = spec
        let item = spec.item
        let focused = spec.isSelected
        let sameItem = previous?.item.id == item.id
        let wasFocused = previous?.isSelected ?? false
        let growth = sameItem && wasFocused != focused ? Self.focusAnimation : nil
        // Focus arrives at once, and leaves with a quick fade, so a row the selection only
        // passed through still shows that it was there.
        let unfocus = sameItem && wasFocused && !focused && Self.focusAnimation != nil ? Self.unfocusAnimation : nil
        let focusChanged = previous == nil || !sameItem || wasFocused != focused
        let height = spec.rowHeight
        let width = spec.rowWidth
        let capsuleHeight = height - ModernTheme.rowCapsuleInset
        let restFrame = CGRect(x: 0, y: (height - capsuleHeight) * 0.5, width: width, height: capsuleHeight)
        let grow = ModernTheme.focusGrowth
        let capsuleFrame = focused ? restFrame.insetBy(dx: -grow.width, dy: -grow.height) : restFrame

        // The size eases; the colour changes at once, or fades on the way out.
        if focusChanged {
            capsule.set("backgroundColor", to: (focused ? ModernTheme.focusFill : ModernTheme.rowFill).cgColor, unchanged: false, animation: unfocus)
            shadow.setPickedOut(focused, unfocus ?? growth)
        }
        shadow.place(under: restFrame)
        capsule.setFrame(capsuleFrame, growth)
        capsule.set("cornerRadius", to: capsuleFrame.height * 0.5, unchanged: capsule.cornerRadius == capsuleFrame.height * 0.5, animation: growth)

        content.place(CGRect(x: 0, y: 0, width: width, height: height))
        let grown = Self.scale(ModernTheme.focusedContentScale, about: CGPoint(x: width * 0.5, y: height * 0.5))
        content.setTransform(focused ? grown : CATransform3DIdentity, growth)

        // A picture before the title (photo albums and the like).
        var textStart = ModernTheme.rowTextInset
        let image = spec.dynamicLeadingImage ?? item.leadingImage
            ?? ModernTheme.rowSymbol(forItemID: item.id, assetName: item.leadingImageAssetName).flatMap { ModernTheme.rowIcon(symbol: $0) }
            ?? item.leadingImageAssetName.flatMap { menu.cachedMenuRowLeadingImage(named: $0) }
        if let image {
            let usesWordmark = item.leadingImage == nil && item.leadingImageAssetName == "appleTVNameImage"
            let side = min(capsuleHeight - 12, 64)
            // (A video's picture keeps its shape.)
            let size = usesWordmark ? CGSize(width: side * 1.8, height: side) : CGSize(width: item.media == nil ? side : (side * 16 / 9).rounded(), height: side)
            leadingImage.isHidden = false
            leadingImage.contents = LayerImageCache.cgImage(for: image)
            leadingImage.contentsGravity = usesWordmark ? .resizeAspect : .resizeAspectFill
            leadingImage.cornerRadius = usesWordmark ? 0 : 9
            leadingImage.frame = CGRect(x: 18, y: (height - size.height) * 0.5, width: size.width, height: size.height)
            textStart = 18 + size.width + 18
        } else {
            leadingImage.isHidden = true
            leadingImage.contents = nil
        }

        if item.showsBlueDot {
            let dot = MenuRowLayer.blueDotGraphic(scale: spec.scale)
            blueDot.isHidden = false
            let diameter: CGFloat = 16.5
            blueDot.show(dot, at: CGPoint(x: max(8, textStart - diameter - 8), y: (height - diameter) * 0.5))
        } else {
            blueDot.isHidden = true
        }

        if focused {
            light.layer.isHidden = true
            dark.layer.isHidden = false
            if focusChanged { dark.layer.setOpacity(1, nil) }
            dark.update(spec, focused: true, textStart: textStart, scrollsLongTitle: spec.isSettled)
        } else {
            light.layer.isHidden = false
            light.update(spec, focused: false, textStart: textStart, scrollsLongTitle: false)
            if let unfocus {
                // The dark title, as last drawn, fades out over the light one fading in.
                light.layer.setOpacity(0, nil)
                light.layer.setOpacity(1, unfocus)
                dark.layer.setOpacity(0, unfocus)
            } else if focusChanged {
                light.layer.setOpacity(1, nil)
                dark.layer.isHidden = true
            }
        }
    }

    private static func scale(_ factor: CGFloat, about center: CGPoint) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        return CATransform3DTranslate(transform, -center.x, -center.y, 0)
    }
}

/// The soft shadow all round a capsule of the modern look, centred under it. It's cast by a
/// layer of its own, cut out where the capsule is, so it doesn't darken the see-through capsule
/// from inside.
@MainActor
final class ModernRowShadow {
    let layer = SceneLayer()
    private let cutout = CAShapeLayer()
    private var size: CGSize = .zero

    init() {
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        layer.shadowRadius = 14
        layer.shadowOffset = .zero
        layer.shadowOpacity = 0.6
        cutout.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        cutout.fillRule = .evenOdd
        cutout.fillColor = CGColor(gray: 0, alpha: 1)
        layer.mask = cutout
    }

    /// Under a capsule that is at rest in `restFrame`. (Picked out, the capsule has grown a
    /// little and is opaque: it hides the edge of the cut-out.)
    func place(under restFrame: CGRect) {
        if restFrame.size != size {
            size = restFrame.size
            let radius = restFrame.height / 2
            let shape = CGRect(origin: .zero, size: restFrame.size)
            layer.shadowPath = CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let reach: CGFloat = 48
            cutout.frame = shape.insetBy(dx: -reach, dy: -reach)
            let path = CGMutablePath()
            path.addRect(CGRect(x: 0, y: 0, width: shape.width + reach * 2, height: shape.height + reach * 2))
            let hole = CGRect(x: reach + 0.5, y: reach + 0.5, width: shape.width - 1, height: shape.height - 1)
            path.addPath(CGPath(roundedRect: hole, cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil))
            cutout.path = path
        }
        layer.frame = restFrame
    }

    /// A little darker under the capsule that is picked out.
    func setPickedOut(_ isPickedOut: Bool, _ animation: Animation?) {
        layer.set("shadowOpacity", to: Float(isPickedOut ? 0.75 : 0.6), unchanged: false, animation: animation)
    }
}

/// A row's text and trailing marks in one colour: light on the row's own capsule, dark on the
/// focus capsule.
@MainActor
final class ModernRowInk {
    let layer = SceneLayer()
    private let titleClip = SceneLayer()
    private let title = SceneLayer()
    private let marquee = MarqueeLayer()
    private let trailingText = SceneLayer()
    private let trailingGlyph = SceneLayer()
    private let chevron = SceneLayer()

    init() {
        titleClip.masksToBounds = true
        titleClip.addSublayer(title)
        titleClip.addSublayer(marquee.layer)
        for sublayer in [titleClip, trailingText, trailingGlyph, chevron] {
            layer.addSublayer(sublayer)
        }
    }

    func update(_ spec: MenuRowLayer.Spec, focused: Bool, textStart: CGFloat, scrollsLongTitle: Bool) {
        let item = spec.item
        let scale = spec.scale
        let height = spec.rowHeight
        let width = spec.rowWidth
        layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let primary = focused ? ModernTheme.focusedText : ModernTheme.text
        let secondary = focused ? ModernTheme.focusedSecondaryText : ModernTheme.secondaryText
        var rightX = width - ModernTheme.rowTextInset + 6

        func place(_ target: CALayer, _ graphic: RenderedGraphic) {
            target.isHidden = false
            target.show(graphic, at: CGPoint(x: rightX - graphic.size.width, y: ((height - graphic.size.height) * 0.5).rounded()))
            rightX -= graphic.size.width + 14
        }

        if item.leadsToMenu {
            place(chevron, SymbolRenderer.render("chevron.right", pointSize: 25, weight: .semibold, color: secondary, scale: scale))
        } else {
            chevron.isHidden = true
        }
        if spec.showsPlaybackSpeaker {
            place(trailingGlyph, SymbolRenderer.render("speaker.wave.3.fill", pointSize: 27, weight: .semibold, color: primary, scale: scale))
        } else if let symbol = item.trailingSymbolName {
            place(trailingGlyph, SymbolRenderer.render(symbol, pointSize: 27, weight: .semibold, color: symbol == "checkmark" ? primary : secondary, scale: scale))
        } else {
            trailingGlyph.isHidden = true
        }
        // "..." and "•••" mean more is to come; the chevron says that already.
        let isEllipsis = item.trailingText == "..." || item.trailingText == "•••"
        if let text = item.trailingText, !text.isEmpty, !(isEllipsis && item.leadsToMenu) {
            let graphic = TextRenderer.render(TextSpec(
                text: isEllipsis ? "…" : text,
                fontName: ModernTheme.regularFontName,
                size: ModernTheme.trailingTextSize,
                color: secondary,
                maxWidth: min(340, width * 0.42),
                minimumScaleFactor: 0.7,
            ), scale: scale)
            place(trailingText, graphic)
        } else {
            trailingText.isHidden = true
        }

        let available = max(1, rightX - textStart + 6)
        let lineHeight = FontMetrics.lineHeight(fontName: ModernTheme.mediumFontName, size: ModernTheme.rowTitleSize)
        titleClip.frame = CGRect(x: textStart, y: ((height - lineHeight) * 0.5).rounded(), width: available, height: lineHeight)
        let measured = FontMetrics.width(item.title, fontName: ModernTheme.mediumFontName, size: ModernTheme.rowTitleSize)
        if scrollsLongTitle, measured > available + 1 {
            title.isHidden = true
            marquee.show(title: item.title, viewportWidth: available.rounded(.towardZero), height: lineHeight, scale: scale, fontName: ModernTheme.mediumFontName, size: ModernTheme.rowTitleSize, color: primary)
        } else {
            marquee.stop()
            title.isHidden = false
            title.show(TextRenderer.render(TextSpec(text: item.title, fontName: ModernTheme.mediumFontName, size: ModernTheme.rowTitleSize, color: primary, maxWidth: available), scale: scale), at: .zero)
        }
    }
}
