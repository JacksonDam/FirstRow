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

    init() {
        capsule.backgroundColor = ModernTheme.rowFill.cgColor
        capsule.shadowColor = CGColor(gray: 0, alpha: 1)
        capsule.shadowRadius = 16
        capsule.shadowOffset = CGSize(width: 0, height: 8)
        leadingImage.masksToBounds = true
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
        let height = spec.rowHeight
        let width = spec.rowWidth
        let capsuleHeight = height - ModernTheme.rowCapsuleInset
        let restFrame = CGRect(x: 0, y: (height - capsuleHeight) * 0.5, width: width, height: capsuleHeight)
        let grow = ModernTheme.focusGrowth
        let capsuleFrame = focused ? restFrame.insetBy(dx: -grow.width, dy: -grow.height) : restFrame

        // The colour changes at once; the size eases.
        capsule.backgroundColor = (focused ? ModernTheme.focusFill : ModernTheme.rowFill).cgColor
        capsule.shadowOpacity = focused ? 0.45 : 0
        capsule.setFrame(capsuleFrame, growth)
        capsule.set("cornerRadius", to: capsuleFrame.height * 0.5, unchanged: capsule.cornerRadius == capsuleFrame.height * 0.5, animation: growth)
        capsule.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: capsuleFrame.size), cornerWidth: capsuleFrame.height * 0.5, cornerHeight: capsuleFrame.height * 0.5, transform: nil)

        // Bounds and position, not frame: a frame set while the content is grown would be
        // measured through its scale and leave it shifted once it shrinks back.
        content.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        content.position = .zero
        let grown = Self.scale(ModernTheme.focusedContentScale, about: CGPoint(x: width * 0.5, y: height * 0.5))
        content.setTransform(focused ? grown : CATransform3DIdentity, growth)

        // A picture before the title (photo albums and the like).
        var textStart = ModernTheme.rowTextInset
        let image = spec.dynamicLeadingImage ?? item.leadingImage ?? item.leadingImageAssetName.flatMap { menu.cachedMenuRowLeadingImage(named: $0) }
        if let image {
            let usesWordmark = item.leadingImage == nil && item.leadingImageAssetName == "appleTVNameImage"
            let side = min(capsuleHeight - 12, 64)
            let size = usesWordmark ? CGSize(width: side * 1.8, height: side) : CGSize(width: side, height: side)
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

        light.layer.isHidden = focused
        dark.layer.isHidden = !focused
        if focused {
            dark.update(spec, focused: true, textStart: textStart, scrollsLongTitle: spec.isSettled)
        } else {
            light.update(spec, focused: false, textStart: textStart, scrollsLongTitle: false)
        }
    }

    private static func scale(_ factor: CGFloat, about center: CGPoint) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        return CATransform3DTranslate(transform, -center.x, -center.y, 0)
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
