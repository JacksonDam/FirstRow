import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// A row in the modern look: a translucent capsule with the title on the left and its value
/// and chevron on the right. Focused, the list's white capsule sits under it, its text turns
/// dark and it grows a little.
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

    init() {
        capsule.backgroundColor = ModernTheme.rowFill.cgColor
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
        let focusChanged = sameItem && previous?.isSelected != focused
        let height = spec.rowHeight
        let width = spec.rowWidth
        let capsuleHeight = height - ModernTheme.rowCapsuleInset

        capsule.frame = CGRect(x: 0, y: (height - capsuleHeight) * 0.5, width: width, height: capsuleHeight)
        capsule.cornerRadius = capsuleHeight * 0.5
        // Its own capsule comes back once the focus has moved off it.
        capsule.setOpacity(focused ? 0 : 1, focusChanged && !focused ? Animation.easeInOut(duration: 0.14).delay(0.1) : nil)

        content.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let grown = Self.scale(ModernTheme.focusedContentScale, about: CGPoint(x: width * 0.5, y: height * 0.5))
        content.setTransform(focused ? grown : CATransform3DIdentity, focusChanged ? .focus(duration: ModernTheme.focusDuration) : nil)

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

        let fade: Animation? = focusChanged ? .easeInOut(duration: 0.16) : nil
        light.update(spec, focused: false, textStart: textStart, scrollsLongTitle: false)
        light.layer.setOpacity(focused ? 0 : 1, fade)
        // The dark text is only needed while focused or fading out.
        if focused || previous?.isSelected == true {
            dark.layer.isHidden = false
            dark.update(spec, focused: true, textStart: textStart, scrollsLongTitle: focused && spec.isSettled)
        }
        dark.layer.setOpacity(focused ? 1 : 0, fade)
        if !focused, !focusChanged {
            dark.layer.isHidden = true
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
