import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// How Now Playing makes room on its right for the list it came from or the lyrics: what's
/// left of it moves left and shrinks a little to fit.
@MainActor
enum NowPlayingSideLayout {
    static func queueWidth(_ size: CGSize) -> CGFloat {
        min(600, size.width * 0.4)
    }

    /// The side panel's width plus its margins, in canvas points (0 with nothing beside it),
    /// and how far out it is.
    static func reserve(menu: MenuView, size: CGSize) -> (width: CGFloat, amount: CGFloat) {
        if menu.nowPlayingQueueReveal > 0 { return (queueWidth(size) + 70, menu.nowPlayingQueueReveal) }
        if menu.isNowPlayingLyricsVisible { return (lyricsFrame(size).width + 90, 1) }
        return (0, 0)
    }

    /// The list's sheet in canvas points: down the right side or, standing upright, across the
    /// part under the fold.
    static func queuePanel(_ size: CGSize, upright: UprightStance?) -> CGRect {
        if let pane = upright?.lowerPane {
            return CGRect(x: 40, y: pane.minY + 14, width: size.width - 80, height: pane.height - 28)
        }
        let width = queueWidth(size)
        return CGRect(x: size.width - width - 40, y: 70, width: width, height: size.height - 140)
    }

    static func lyricsFrame(_ size: CGSize, upright: UprightStance? = nil) -> CGRect {
        if let pane = upright?.lowerPane {
            // Standing upright the words have the part under the fold to themselves.
            return CGRect(x: 70, y: pane.minY, width: size.width - 140, height: pane.height)
        }
        let width = (size.width * 0.44).rounded()
        // On iPhone and iPad the buttons along the bottom keep the words above them.
        #if os(iOS)
            #if os(iOS)
                let height = size.height * 0.8
            #else
                let height = size.height
            #endif
        #else
            let height = size.height
        #endif
        return CGRect(x: size.width - width - 70, y: 0, width: width, height: height)
    }

    /// The move and scale, about the middle of the screen, for what stays.
    /// A list only part way out moves the rest only part of the way.
    static func shift(menu: MenuView, size: CGSize) -> (dx: CGFloat, scale: CGFloat) {
        // Standing upright nothing moves aside: see `tuck`.
        guard menu.upright == nil else { return (0, 1) }
        let reserve = reserve(menu: menu, size: size)
        guard reserve.width > 0, reserve.amount > 0 else { return (0, 1) }
        let scale = min(1, max(0.5, (size.width - reserve.width - 50) / (size.width * 0.86)))
        return (-reserve.width / 2 * reserve.amount, 1 - (1 - scale) * reserve.amount)
    }

    static func transform(_ shift: (dx: CGFloat, scale: CGFloat), size: CGSize) -> CATransform3D {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var transform = CATransform3DMakeTranslation(center.x + shift.dx, center.y, 0)
        transform = CATransform3DScale(transform, shift.scale, shift.scale, 1)
        return CATransform3DTranslate(transform, -center.x, -center.y, 0)
    }

    /// A rectangle of what stays, where it shows once moved.
    static func map(_ rect: CGRect, _ shift: (dx: CGFloat, scale: CGFloat), size: CGSize) -> CGRect {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGRect(
            x: center.x + shift.dx + (rect.minX - center.x) * shift.scale,
            y: center.y + (rect.minY - center.y) * shift.scale,
            width: rect.width * shift.scale,
            height: rect.height * shift.scale,
        )
    }

    /// Standing upright the list and the words come out under the fold, where the song's
    /// details are, and the details tuck up beside the cover above it, both smaller. How far
    /// that has gone: 0 with nothing out, 1 with the list or the words all the way out.
    static func tuck(menu: MenuView) -> CGFloat {
        guard menu.upright != nil else { return 0 }
        return max(min(max(menu.nowPlayingQueueReveal, 0), 1), menu.isNowPlayingLyricsVisible ? 1 : 0)
    }

    /// Where one part of the panel (the cover, or the details) shows: at `scale`, with its own
    /// point `anchor` at `center`.
    struct Place {
        var anchor: CGPoint
        var scale: CGFloat
        var center: CGPoint

        /// Part of the way from one place to another, in a straight line.
        static func between(_ from: Place, _ to: Place, _ amount: CGFloat) -> Place {
            let amount = min(max(amount, 0), 1)
            return Place(
                anchor: from.anchor,
                scale: from.scale + (to.scale - from.scale) * amount,
                center: CGPoint(x: from.center.x + (to.center.x - from.center.x) * amount, y: from.center.y + (to.center.y - from.center.y) * amount),
            )
        }

        /// For a layer anchored at its top left and placed at the origin.
        var transform: CATransform3D {
            var transform = CATransform3DMakeTranslation(center.x, center.y, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            return CATransform3DTranslate(transform, -anchor.x, -anchor.y, 0)
        }

        func map(_ rect: CGRect) -> CGRect {
            CGRect(
                x: center.x + (rect.minX - anchor.x) * scale,
                y: center.y + (rect.minY - anchor.y) * scale,
                width: rect.width * scale,
                height: rect.height * scale,
            )
        }
    }
}

/// A faint bar that says something can be pulled out from where it sits. When it first
/// shows it brightens, drifts a little the way to pull and back, and settles faint and still.
@MainActor
final class HintBarLayer {
    let layer = SceneLayer()
    private let bar = SceneLayer()
    private var isShown = false
    private var introducedSession: Int?
    /// How bright it rests, against its brightest.
    private static let resting: Float = 0.15

    init() {
        layer.addSublayer(bar)
        layer.opacity = 0
        layer.isHidden = true
        bar.backgroundColor = CGColor(gray: 1, alpha: 1)
    }

    /// `drift` is the way to pull it, in the layer's own points; `session` changes each time
    /// what it belongs to opens, and it introduces itself once per session.
    func update(frame: CGRect, shown: Bool, drift: CGSize, session: Int, alpha: CGFloat = 0.55) {
        layer.place(frame)
        bar.frame = CGRect(origin: .zero, size: frame.size)
        bar.cornerRadius = min(frame.width, frame.height) / 2
        bar.backgroundColor = CGColor(gray: 1, alpha: alpha)
        guard shown != isShown else { return }
        isShown = shown
        guard shown else {
            layer.setOpacity(0, .smoothInOut(duration: 0.3))
            return
        }
        layer.isHidden = false
        guard introducedSession != session else {
            layer.setOpacity(Double(Self.resting), .smooth(duration: 0.6))
            return
        }
        introducedSession = session
        layer.removeAllAnimations()
        bar.removeAllAnimations()
        layer.opacity = Self.resting
        let duration: CFTimeInterval = 2.8
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, Self.resting]
        fade.keyTimes = [0, 0.14, 0.42, 1]
        fade.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
        fade.duration = duration
        layer.addAtFullRate(fade, forKey: "introduce")
        let float = CAKeyframeAnimation(keyPath: "transform")
        float.values = [CATransform3DIdentity, CATransform3DMakeTranslation(drift.width, drift.height, 0), CATransform3DIdentity].map { NSValue(caTransform3D: $0) }
        float.keyTimes = [0.1, 0.45, 0.85]
        float.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        float.duration = duration
        bar.addAtFullRate(float, forKey: "introduce")
    }
}

// MARK: - The list beside Now Playing

/// The songs Now Playing came from, in a panel that slides in over the right of the screen,
/// with the one playing marked. Only rows near the view get layers.
@MainActor
final class NowPlayingQueueLayer {
    let layer = SceneLayer()
    private let panel = SceneLayer()
    private let header = SceneLayer()
    private let clip = SceneLayer()
    private let fade = SceneGradientLayer()
    private let rowsContainer = SceneLayer()

    /// One song in the list, drawn as the menus' rows are: in the modern look a translucent
    /// capsule that turns white, grows and casts its shadow when picked out; in the classic look
    /// plain text over the menus' selection bar.
    private final class Row {
        let layer = SceneLayer()
        let shadowCaster = SceneLayer()
        let shadowCutout = CAShapeLayer()
        var shadowSize: CGSize = .zero
        let capsule = SceneLayer()
        let content = SceneLayer()
        let light = Ink()
        let dark = Ink()
        var contentKey = ""
        var index = -1
        var isFocused = false

        final class Ink {
            let layer = SceneLayer()
            let title = SceneLayer()
            let detail = SceneLayer()
            let speaker = SceneLayer()

            init() {
                for sublayer in [title, detail, speaker] {
                    layer.addSublayer(sublayer)
                }
            }
        }

        init() {
            capsule.backgroundColor = ModernTheme.rowFill.cgColor
            shadowCaster.shadowColor = CGColor(gray: 0, alpha: 1)
            shadowCaster.shadowRadius = 14
            shadowCaster.shadowOffset = .zero
            shadowCaster.shadowOpacity = 0.6
            shadowCutout.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
            shadowCutout.fillRule = .evenOdd
            shadowCutout.fillColor = CGColor(gray: 0, alpha: 1)
            shadowCaster.mask = shadowCutout
            layer.addSublayer(shadowCaster)
            layer.addSublayer(capsule)
            layer.addSublayer(content)
            content.addSublayer(light.layer)
            content.addSublayer(dark.layer)
        }
    }

    private var rows: [Int: Row] = [:]
    private var spare: [Row] = []
    private var lastScroll: CGFloat?
    /// How strongly each edge fades (top, bottom), as last set.
    private var lastFade: (CGFloat, CGFloat)?
    private var lastHeaderKey = ""
    /// The classic look's selection bar, behind the row picked out.
    private let selection = SelectionBoxLayer()
    private var lastSelectionIndex: Int?

    /// In canvas points: the panel, where rows show, the first row's top, how far it scrolls,
    /// and the strip along the right edge that pulls it out.
    private(set) var panelFrame: CGRect = .zero
    private(set) var viewport: CGRect = .zero
    private(set) var listTop: CGFloat = 0
    private(set) var scrollLimit: CGFloat = 0
    private(set) var isAvailable = false

    init() {
        layer.addSublayer(panel)
        panel.addSublayer(header)
        panel.addSublayer(clip)
        clip.masksToBounds = true
        clip.addSublayer(rowsContainer)
        rowsContainer.addSublayer(selection.layer)
        selection.layer.isHidden = true
        clip.mask = fade
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        panel.opacity = 0
        panel.isHidden = true
    }

    func update(menu: MenuView, pass: RenderPass, size: CGSize, scale: CGFloat) {
        layer.frame = CGRect(origin: .zero, size: size)
        let isModern = ModernTheme.isActive
        isAvailable = menu.canShowNowPlayingQueue
        let reveal = isAvailable ? menu.nowPlayingQueueReveal : 0

        // (The hint along the right edge is drawn with the on-screen buttons, in screen points,
        // so it matches the transport's.)

        panelFrame = NowPlayingSideLayout.queuePanel(size, upright: menu.upright)
        let width = panelFrame.width
        panel.place(panelFrame)
        panel.backgroundColor = isModern ? CGColor(gray: 0.06, alpha: 0.72) : CGColor(gray: 0, alpha: 0.82)
        panel.cornerRadius = isModern ? 36 : 18
        panel.borderWidth = isModern ? 0 : 1.5
        panel.borderColor = CGColor(gray: 1, alpha: 0.22)
        panel.shadowColor = CGColor(gray: 0, alpha: 1)
        panel.shadowOpacity = 0.5
        panel.shadowRadius = 30
        panel.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: panelFrame.size), cornerWidth: panel.cornerRadius, cornerHeight: panel.cornerRadius, transform: nil)
        // One sheet that slides: away, it waits just past the right edge, shadow and all.
        let travel = size.width - panelFrame.minX + 60
        panel.isHidden = false
        panel.opacity = 1
        panel.setTransform(CATransform3DMakeTranslation(travel * (1 - reveal), 0, 0), pass.animation)
        // Away, its rows needn't be kept up to date.
        guard reveal > 0 else { return }

        // The list's name.
        let title = menu.nowPlayingQueueTitle
        let headerKey = "\(title)|\(isModern)|\(scale)|\(width)"
        let headerTop: CGFloat = 34
        if headerKey != lastHeaderKey {
            lastHeaderKey = headerKey
            let graphic = TextRenderer.render(TextSpec(
                text: title,
                fontName: isModern ? ModernTheme.boldFontName : firstRowBoldFontName,
                size: 40,
                color: RGBA(white: 1, alpha: 0.96),
                maxWidth: width - 80,
                minimumScaleFactor: 0.7,
            ), scale: scale)
            header.show(graphic, at: CGPoint(x: 40, y: headerTop))
        }

        let pitch = MenuView.nowPlayingQueueRowPitch
        let count = menu.nowPlayingQueueCount
        let clipFrame = CGRect(x: 0, y: headerTop + 74, width: width, height: panelFrame.height - headerTop - 74 - 18)
        clip.frame = clipFrame
        fade.frame = CGRect(origin: .zero, size: clipFrame.size)
        let edge = 26 / max(1, clipFrame.height)
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        let padding: CGFloat = 14
        viewport = CGRect(x: panelFrame.minX, y: panelFrame.minY + clipFrame.minY, width: width, height: clipFrame.height)
        listTop = viewport.minY + padding
        scrollLimit = max(0, CGFloat(count) * pitch + padding * 2 - clipFrame.height)
        let scroll = max(0, min(scrollLimit, menu.nowPlayingQueueScroll))
        rowsContainer.bounds = CGRect(x: 0, y: 0, width: width, height: max(clipFrame.height, CGFloat(count) * pitch + padding * 2))
        let scrollAnimation = lastScroll == nil ? nil : pass.animation
        // Where it shows now, part way through a scroll, as well as where it's going: a quick
        // flick of the wheel mustn't leave it empty on the way.
        let shownScroll = padding - (rowsContainer.presentation()?.position.y ?? rowsContainer.position.y)
        rowsContainer.setPosition(CGPoint(x: 0, y: padding - scroll), scrollAnimation)
        lastScroll = scroll
        // Each edge fades only with something scrolled past it: at the top of the list the first
        // song shows whole, and at the bottom the last one does.
        let fadeReach: CGFloat = 26
        let topFade = min(1, max(0, scroll / fadeReach))
        let bottomFade = min(1, max(0, (scrollLimit - scroll) / fadeReach))
        let fadeColors = [
            CGColor(gray: 0, alpha: 1 - topFade), CGColor(gray: 0, alpha: 1),
            CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1 - bottomFade),
        ]
        let fadeKey = (topFade, bottomFade)
        if lastFade.map({ $0 != fadeKey }) ?? true {
            fade.set("colors", to: fadeColors, unchanged: false, animation: lastFade == nil ? nil : scrollAnimation)
            lastFade = fadeKey
        }

        // Rows near the view, all the way along a scroll under way.
        let first = max(0, Int(floor(min(scroll, shownScroll) / pitch)) - 2)
        let last = min(count - 1, Int(ceil((max(scroll, shownScroll) + clipFrame.height) / pitch)) + 2)
        let range = first <= last ? first ... last : 1 ... 0
        for (index, row) in rows where !range.contains(index) {
            row.layer.isHidden = true
            row.index = -1
            spare.append(row)
            rows[index] = nil
        }
        let active = menu.nowPlayingQueueActiveIndex
        let focus = menu.nowPlayingQueueHoverIndex
        // Rows leave room each side for the classic bar's glow, or the modern capsule's growth.
        let rowInset: CGFloat = isModern ? 16 : 40
        func rowFrame(_ index: Int) -> CGRect {
            CGRect(x: rowInset, y: CGFloat(index) * pitch, width: width - rowInset * 2, height: pitch - 8)
        }

        // The classic bar slides from row to row, as the menus' does.
        if !isModern, let focus, focus >= 0, focus < count {
            let frame = rowFrame(focus)
            let spill = frame.height / 75
            let appearing = selection.layer.isHidden || lastSelectionIndex == nil
            selection.layer.isHidden = false
            selection.update(
                frame: frame.insetBy(dx: -40 * spill, dy: -29 * spill),
                selectionBoxHeight: frame.height,
                // On the list's own curve, so when the list scrolls under it, it stays still.
                animation: appearing ? nil : (lastSelectionIndex != focus ? (pass.animation ?? .easeInOut(duration: 0.2)) : nil),
            )
            lastSelectionIndex = focus
        } else {
            selection.layer.isHidden = true
            lastSelectionIndex = nil
        }

        for index in range {
            guard let content = menu.nowPlayingQueueRow(index) else { continue }
            let row = rows[index] ?? {
                let made = spare.popLast() ?? {
                    let fresh = Row()
                    rowsContainer.addSublayer(fresh.layer)
                    return fresh
                }()
                made.layer.isHidden = false
                rows[index] = made
                return made
            }()
            update(row, index: index, content: content, frame: rowFrame(index), isPlaying: active == index, isFocused: focus == index, isModern: isModern, scale: scale)
        }
    }

    private static let focusAnimation = Animation.smooth(duration: ModernTheme.focusDuration)
    private static let unfocusAnimation = Animation.smooth(duration: 0.22)

    private func update(_ row: Row, index: Int, content: (title: String, detail: String), frame: CGRect, isPlaying: Bool, isFocused focused: Bool, isModern: Bool, scale: CGFloat) {
        let sameRow = row.index == index
        let wasFocused = sameRow && row.isFocused
        row.index = index
        row.layer.frame = frame
        let size = frame.size

        // Both inks drawn once per song, size and look.
        let key = "\(content.title)|\(content.detail)|\(isPlaying)|\(isModern)|\(scale)|\(size.width)"
        if key != row.contentKey {
            row.contentKey = key
            let titleFont = isModern ? ModernTheme.mediumFontName : firstRowBoldFontName
            let detailFont = isModern ? ModernTheme.regularFontName : firstRowRegularFontName
            let inks: [(Row.Ink, RGBA, RGBA)] = [
                (row.light, isModern ? ModernTheme.text : RGBA(white: 1, alpha: 0.96), isModern ? ModernTheme.secondaryText : RGBA(white: 1, alpha: 0.6)),
                (row.dark, ModernTheme.focusedText, ModernTheme.focusedSecondaryText),
            ]
            for (ink, primary, secondary) in inks {
                ink.layer.frame = CGRect(origin: .zero, size: size)
                var right = size.width - 26
                if isPlaying {
                    let glyph = SymbolRenderer.render("speaker.wave.3.fill", pointSize: 24, weight: .semibold, color: primary, scale: scale)
                    ink.speaker.isHidden = false
                    ink.speaker.show(glyph, at: CGPoint(x: right - glyph.size.width, y: ((size.height - glyph.size.height) / 2).rounded()))
                    right -= glyph.size.width + 16
                } else {
                    ink.speaker.isHidden = true
                }
                let textWidth = max(40, right - 26)
                let titleGraphic = TextRenderer.render(TextSpec(text: content.title, fontName: titleFont, size: 27, color: primary, maxWidth: textWidth), scale: scale)
                let detailGraphic = TextRenderer.render(TextSpec(text: content.detail, fontName: detailFont, size: 20, color: secondary, maxWidth: textWidth), scale: scale)
                let block = titleGraphic.size.height + 2 + detailGraphic.size.height
                let top = ((size.height - block) / 2).rounded()
                ink.title.show(titleGraphic, at: CGPoint(x: 26, y: top))
                ink.detail.show(detailGraphic, at: CGPoint(x: 26, y: top + titleGraphic.size.height + 2))
            }
        }

        guard isModern else {
            // Classic: plain text; the bar behind does the picking out.
            row.shadowCaster.isHidden = true
            row.capsule.isHidden = true
            row.dark.layer.isHidden = true
            row.light.layer.isHidden = false
            row.light.layer.setOpacity(1, nil)
            row.content.setTransform(CATransform3DIdentity, nil)
            row.content.place(CGRect(origin: .zero, size: size))
            row.isFocused = focused
            return
        }
        row.shadowCaster.isHidden = false
        row.capsule.isHidden = false

        // As the menus' rows: focus arrives at once and grows; it leaves with a quick fade.
        let changed = sameRow && wasFocused != focused
        let growth: Animation? = changed ? Self.focusAnimation : nil
        let unfocus: Animation? = changed && !focused ? Self.unfocusAnimation : nil
        let focusChanged = !sameRow || wasFocused != focused
        row.isFocused = focused
        let rest = CGRect(origin: .zero, size: size)
        let grow = ModernTheme.focusGrowth
        let capsuleFrame = focused ? rest.insetBy(dx: -grow.width, dy: -grow.height) : rest
        if focusChanged {
            row.capsule.set("backgroundColor", to: (focused ? ModernTheme.focusFill : ModernTheme.rowFill).cgColor, unchanged: false, animation: unfocus)
            row.shadowCaster.set("shadowOpacity", to: Float(focused ? 0.75 : 0.6), unchanged: false, animation: unfocus ?? growth)
        }
        if size != row.shadowSize {
            row.shadowSize = size
            let radius = size.height / 2
            row.shadowCaster.shadowPath = CGPath(roundedRect: rest, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let reach: CGFloat = 48
            row.shadowCutout.frame = rest.insetBy(dx: -reach, dy: -reach)
            let cutout = CGMutablePath()
            cutout.addRect(CGRect(x: 0, y: 0, width: size.width + reach * 2, height: size.height + reach * 2))
            let hole = CGRect(x: reach + 0.5, y: reach + 0.5, width: size.width - 1, height: size.height - 1)
            cutout.addPath(CGPath(roundedRect: hole, cornerWidth: radius - 0.5, cornerHeight: radius - 0.5, transform: nil))
            row.shadowCutout.path = cutout
        }
        row.shadowCaster.frame = rest
        row.capsule.setFrame(capsuleFrame, growth)
        row.capsule.set("cornerRadius", to: capsuleFrame.height / 2, unchanged: row.capsule.cornerRadius == capsuleFrame.height / 2, animation: growth)
        row.content.place(rest)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var grown = CATransform3DMakeTranslation(center.x, center.y, 0)
        grown = CATransform3DScale(grown, ModernTheme.focusedContentScale, ModernTheme.focusedContentScale, 1)
        grown = CATransform3DTranslate(grown, -center.x, -center.y, 0)
        row.content.setTransform(focused ? grown : CATransform3DIdentity, growth)
        if focused {
            row.light.layer.isHidden = true
            row.dark.layer.isHidden = false
            if focusChanged { row.dark.layer.setOpacity(1, nil) }
        } else {
            row.light.layer.isHidden = false
            if let unfocus {
                // The dark text, as it was, fades out over the light text fading in.
                row.light.layer.setOpacity(0, nil)
                row.light.layer.setOpacity(1, unfocus)
                row.dark.layer.setOpacity(0, unfocus)
            } else if focusChanged {
                row.light.layer.setOpacity(1, nil)
                row.dark.layer.isHidden = true
            }
        }
    }
}

// MARK: - Lyrics

/// The song's words beside Now Playing, large: with times, the line being sung is bright and
/// held a third of the way down as the others go by; without, they scroll along with the song.
@MainActor
final class NowPlayingLyricsLayer {
    let layer = SceneLayer()
    private let clip = SceneLayer()
    private let fade = SceneGradientLayer()
    private let column = SceneLayer()
    private var lineLayers: [SceneLayer] = []
    private var lineTops: [CGFloat] = []
    private var contentHeight: CGFloat = 0
    private var builtKey = ""
    private var lastLine: Int?

    init() {
        layer.addSublayer(clip)
        clip.masksToBounds = true
        clip.addSublayer(column)
        clip.mask = fade
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        fade.locations = [0, 0.14, 0.84, 1]
        layer.opacity = 0
        layer.isHidden = true
    }

    func update(menu: MenuView, pass: RenderPass, size: CGSize, scale: CGFloat) {
        layer.frame = CGRect(origin: .zero, size: size)
        let shown = menu.isNowPlayingLyricsVisible && menu.hasNowPlayingLyrics
        if shown { layer.isHidden = false }
        layer.setOpacity(shown ? 1 : 0, pass.animation)
        guard shown || !layer.isHidden, let lyrics = menu.nowPlayingLyrics else {
            if !shown, pass.animation == nil { layer.isHidden = true }
            return
        }
        let area = NowPlayingSideLayout.lyricsFrame(size, upright: menu.upright)
        clip.frame = area
        fade.frame = CGRect(origin: .zero, size: area.size)
        let isModern = ModernTheme.isActive

        // Every line drawn once per song (and size), each its own layer.
        let key = "\(menu.nowPlayingLyricsSongID ?? "")|\(lyrics.lines.count)|\(area.width)|\(scale)|\(isModern)"
        if key != builtKey {
            builtKey = key
            lastLine = nil
            for line in lineLayers { line.removeFromSuperlayer() }
            lineLayers = []
            lineTops = []
            var y: CGFloat = 0
            for line in lyrics.lines {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                let lineLayer = SceneLayer()
                if text.isEmpty {
                    // A break between verses.
                    lineTops.append(y)
                    y += 34
                } else {
                    let graphic = TextRenderer.render(TextSpec(
                        text: text,
                        fontName: isModern ? ModernTheme.boldFontName : firstRowBoldFontName,
                        size: 50,
                        color: .white,
                        wrapWidth: area.width,
                        lineSpacing: 4,
                    ), scale: scale)
                    lineLayer.show(graphic, at: CGPoint(x: 0, y: y))
                    lineTops.append(y)
                    y += graphic.size.height + 26
                }
                column.addSublayer(lineLayer)
                lineLayers.append(lineLayer)
            }
            contentHeight = y
            column.bounds = CGRect(x: 0, y: 0, width: area.width, height: max(y, 1))
        }

        let elapsed = menu.musicNowPlayingElapsedSeconds
        let anchor = area.height * 0.34
        if lyrics.isSynced {
            let current = lyrics.currentLineIndex(at: elapsed + 0.2)
            if current != lastLine || pass.animation == nil {
                let changed = lastLine != nil && current != lastLine
                lastLine = current
                let move: Animation? = changed ? .smooth(duration: 0.55) : nil
                let top = current.flatMap { lineTops.indices.contains($0) ? lineTops[$0] : nil } ?? -anchor * 0.5
                column.setPosition(CGPoint(x: 0, y: anchor - top), move)
                for (index, line) in lineLayers.enumerated() {
                    line.setOpacity(index == current ? 1 : 0.3, move)
                }
            }
        } else {
            // Without times, the words move up through the song at its pace.
            let duration = max(1, menu.musicNowPlayingDurationSeconds)
            let progress = CGFloat(min(1, max(0, elapsed / duration)))
            let travel = max(0, contentHeight - area.height * 0.5)
            column.setPosition(CGPoint(x: 0, y: anchor - travel * progress), lastLine == nil ? nil : .linear(duration: 0.5))
            if lastLine == nil {
                for line in lineLayers { line.setOpacity(0.85, nil) }
            }
            lastLine = -1
        }
    }
}
