import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// A YouTube video's caption line, over the foot of the picture.
@MainActor
final class YouTubeCaptionLayer {
    let layer = SceneLayer()
    private let line = SceneLayer()

    init() {
        layer.addSublayer(line)
        line.isHidden = true
    }

    /// `raised` while the transport bar is up, so the line clears it; `width` is how much of
    /// the picture's width is clear of the panel beside it.
    func update(text: String?, raised: Bool, width: CGFloat, size: CGSize, scale: CGFloat, pass _: RenderPass) {
        guard let text, !text.isEmpty else {
            line.isHidden = true
            return
        }
        let graphic = TextRenderer.render(TextSpec(
            text: text,
            fontName: ModernTheme.isActive ? ModernTheme.mediumFontName : firstRowBoldFontName,
            size: 44,
            color: .white,
            wrapWidth: width * 0.78,
            alignment: .center,
            lineSpacing: 4,
            shadows: [
                TextShadow(color: RGBA(white: 0, alpha: 0.95), radius: 2.5),
                TextShadow(color: RGBA(white: 0, alpha: 0.85), radius: 6, offset: CGSize(width: 0, height: 2)),
            ],
        ), scale: scale)
        line.isHidden = false
        let foot = size.height - (raised ? 196 : 76)
        line.show(graphic, at: CGPoint(x: ((width - graphic.size.width) / 2).rounded(), y: (foot - graphic.size.height).rounded()))
    }
}

/// The panel over the right of a YouTube video's picture (see `YouTubePanelState`): a title,
/// then rows with one picked out, the list moving under it as up and down go through them.
/// In the classic look it's a dark band down the right of the screen; in the modern look a
/// sheet standing clear of the screen's edges, of the system's glass where there is some, with
/// the row picked out on white as the options' rows are.
@MainActor
final class YouTubePanelLayer {
    let layer = SceneLayer()
    private let panel = SceneLayer()
    private let title = SceneLayer()
    private let count = SceneLayer()
    private let message = SceneLayer()
    private let clip = SceneLayer()
    private let list = SceneLayer()
    private var blocks: [String: Block] = [:]
    /// What the panel last showed, kept while it slides away.
    private var shown: YouTubePanelState?
    private var isOut = false
    private var lastFocus: Int?
    private var lastOffset: CGFloat = 0
    private var lastKind: YouTubePanelState.Kind?
    /// Whether the system's glass has been asked for (it's made the first time it is).
    private var hasUsedGlass = false
    /// The panel in canvas points, while it's out (for clicks and touches).
    private(set) var panelFrame: CGRect?
    /// Where each row that has been laid out shows on the canvas (the gap between two is
    /// shared out between them), and how far apart their tops are.
    private var rowFrames: [CGRect] = []
    private var rowPitches: [CGFloat] = []

    /// The row at a point of the canvas, while the panel is out.
    func row(at point: CGPoint) -> Int? {
        guard panelFrame != nil else { return nil }
        return rowFrames.firstIndex { $0.contains(point) }
    }

    /// From a row's top to the next one's, on the canvas.
    func pitch(ofRow index: Int) -> CGFloat? {
        rowPitches.indices.contains(index) ? rowPitches[index] : nil
    }

    /// Where the panel goes on a canvas of this size.
    static func frame(in size: CGSize) -> CGRect {
        if ModernTheme.isActive {
            let margin: CGFloat = 36
            let width = min(820, (size.width * 0.43).rounded())
            return CGRect(x: size.width - margin - width, y: margin, width: width, height: size.height - margin * 2)
        }
        let width = min(840, (size.width * 0.44).rounded())
        return CGRect(x: size.width - width, y: 0, width: width, height: size.height)
    }

    /// How much of the canvas's width the panel takes, from the right edge.
    static func width(in size: CGSize) -> CGFloat {
        size.width - frame(in: size).minX
    }

    private final class Block {
        let layer = SceneLayer()
        let picture = SceneLayer()
        let heading = SceneLayer()
        let aside = SceneLayer()
        let mark = SceneLayer()
        let body = SceneLayer()
        let footer = SceneLayer()
        var row: YouTubePanelRow?
        var key = ""
        var height: CGFloat = 0

        init() {
            for sublayer in [picture, heading, aside, mark, body, footer] { layer.addSublayer(sublayer) }
            picture.masksToBounds = true
        }
    }

    /// How a row is drawn: the width its words have, how far its box reaches past them (the
    /// modern look's white box under the row picked out), and whether it's that row.
    private struct Look {
        var column: CGFloat
        var pad: CGSize
        var isModern: Bool
        var isFocused: Bool
        var scale: CGFloat

        var bold: String { isModern ? ModernTheme.boldFontName : firstRowBoldFontName }
        var medium: String { isModern ? ModernTheme.mediumFontName : firstRowBoldFontName }
        var regular: String { isModern ? ModernTheme.regularFontName : firstRowRegularFontName }
        /// On the white box the words are dark.
        var isOnWhite: Bool { isModern && isFocused }
        var primary: RGBA { isOnWhite ? ModernTheme.focusedText : RGBA(white: 1, alpha: 0.94) }
        var words: RGBA { isOnWhite ? ModernTheme.focusedText : .white }
        var dim: RGBA { isOnWhite ? ModernTheme.focusedSecondaryText : RGBA(white: 1, alpha: 0.5) }
    }

    init() {
        layer.addSublayer(panel)
        panel.isHidden = true
        panel.masksToBounds = true
        for sublayer in [title, count, message, clip] { panel.addSublayer(sublayer) }
        clip.masksToBounds = true
        clip.addSublayer(list)
    }

    /// The system's Liquid Glass for the sheet, where there is some (the modern look).
    private var nativeGlass: AnyObject? {
        #if os(iOS) || os(macOS) || os(tvOS)
            if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *), ModernTheme.isActive {
                return NativeControls.shared?.sheet
            }
        #endif
        return nil
    }

    private func putGlassAway() {
        #if os(iOS) || os(macOS) || os(tvOS)
            if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *), hasUsedGlass {
                NativeControls.shared?.sheet.hide()
            }
        #endif
    }

    /// `canvasScale` is window points per canvas point (for the system's glass).
    func update(menu: MenuView, size: CGSize, scale: CGFloat, canvasScale: CGFloat, pass: RenderPass) {
        let state = menu.isMoviePlaybackVisible ? menu.youtubePanel : nil
        if let state { shown = state }
        let reveal = state == nil ? 0 : menu.youtubePanelReveal
        guard let content = shown else {
            panel.isHidden = true
            panelFrame = nil
            rowFrames = []
            putGlassAway()
            return
        }
        if state == nil, !isOut {
            // Away and out of sight: let go of its rows.
            shown = nil
            for block in blocks.values { block.layer.removeFromSuperlayer() }
            blocks = [:]
            lastFocus = nil
            lastKind = nil
            panel.isHidden = true
            panelFrame = nil
            rowFrames = []
            putGlassAway()
            return
        }
        let isModern = ModernTheme.isActive
        let frame = Self.frame(in: size)
        let width = frame.width
        let wasHidden = panel.isHidden
        panel.isHidden = false
        isOut = reveal > 0.5
        // It comes in from past the right edge, and goes back there.
        let reach = size.width - frame.minX
        let away = CATransform3DMakeTranslation(reach, 0, 0)
        let move = pass.animation
        var isInGlass = false
        #if os(iOS) || os(macOS) || os(tvOS)
            if #available(macOS 26.0, iOS 26.0, tvOS 26.0, *), let glass = nativeGlass as? NativeGlassSheet {
                // The rows are drawn at canvas size inside the glass, which is in window points.
                isInGlass = true
                hasUsedGlass = true
                if panel.superlayer !== glass.layerHost {
                    panel.removeAllAnimations()
                    glass.layerHost.addSublayer(panel)
                }
                panel.backgroundColor = CGColor(gray: 0, alpha: 0)
                panel.cornerRadius = 0
                panel.bounds = CGRect(origin: .zero, size: frame.size)
                panel.position = .zero
                panel.setTransform(CATransform3DMakeScale(canvasScale, canvasScale, 1), nil)
                panel.setOpacity(1, nil)
                glass.update(
                    frame: CGRect(x: frame.minX * canvasScale, y: frame.minY * canvasScale, width: frame.width * canvasScale, height: frame.height * canvasScale),
                    cornerRadius: Self.modernCornerRadius * canvasScale,
                    shown: isOut,
                    away: CATransform3DMakeTranslation(reach * canvasScale, 0, 0),
                    animation: move,
                )
            } else if panel.superlayer !== layer {
                panel.removeAllAnimations()
                layer.addSublayer(panel)
            }
        #endif
        if !isInGlass {
            panel.place(frame)
            // (The modern look's own dark sheet, as its options panel has without the glass.)
            panel.backgroundColor = CGColor(gray: isModern ? 0.08 : 0, alpha: 0.84)
            panel.cornerRadius = isModern ? Self.modernCornerRadius : 0
            if wasHidden {
                panel.setTransform(away, nil)
                panel.setOpacity(0, nil)
            }
            panel.setTransform(isOut ? CATransform3DIdentity : away, move)
            panel.setOpacity(isOut ? 1 : 0, move)
        }
        panelFrame = isOut ? frame : nil

        let inset: CGFloat = 44
        let column = width - inset * 2
        var look = Look(column: column, pad: isModern ? CGSize(width: 24, height: 16) : .zero, isModern: isModern, isFocused: false, scale: scale)
        let titleTop: CGFloat = isModern ? 38 : 54
        let titleGraphic = TextRenderer.render(TextSpec(text: content.title, fontName: look.bold, size: 44, maxWidth: column), scale: scale)
        title.show(titleGraphic, at: CGPoint(x: inset, y: titleTop))
        // "5,240" beside the title.
        let total = content.countText ?? ""
        let countGraphic = TextRenderer.render(TextSpec(text: total, fontName: look.regular, size: 30, color: RGBA(white: 1, alpha: 0.55)), scale: scale)
        count.isHidden = total.isEmpty
        count.show(countGraphic, at: CGPoint(x: inset + titleGraphic.size.width + 18, y: titleTop + titleGraphic.size.height - countGraphic.size.height - 4))

        let top = titleTop + titleGraphic.size.height + (isModern ? 22 : 30)
        let viewport = CGRect(x: 0, y: top, width: width, height: frame.height - top - (isModern ? 22 : 40))
        clip.place(viewport)

        // The rows from the top to a little past the one picked out are laid out (each one's
        // height is only known once its words are set); the rest wait their turn.
        let focus = min(max(0, content.focused), max(0, content.rows.count - 1))
        // (The modern look's rows have their boxes' room around them already.)
        let gap: CGFloat = isModern ? 4 : 34
        var tops: [CGFloat] = []
        var pitches: [CGFloat] = []
        var y: CGFloat = 0
        var live = Set<String>()
        let kindChanged = lastKind != nil && lastKind != content.kind
        var prepared = 0
        for index in content.rows.indices {
            // Enough to fill the panel under the one picked out, and a few more.
            if index > focus + 4, y > tops[focus] + viewport.height + 200 { break }
            prepared = index + 1
            let row = content.rows[index]
            live.insert(row.id)
            let block: Block
            if let known = blocks[row.id] {
                block = known
            } else {
                block = Block()
                blocks[row.id] = block
                list.addSublayer(block.layer)
            }
            let picture = row.pictureURL.flatMap { menu.youtube.panelPictures[$0] }
            look.isFocused = index == focus
            let key = "\(column)|\(scale)|\(isModern)|\(look.isOnWhite)|\(picture != nil)"
            if block.key != key || block.row != row {
                block.key = key
                block.row = row
                set(block, to: row, picture: picture, look: look)
            }
            tops.append(y)
            pitches.append(block.height + gap)
            block.layer.frame = CGRect(x: inset - look.pad.width, y: y, width: column + look.pad.width * 2, height: block.height)
            if isModern {
                // The one picked out stands on white; focus jumps to it, as in the menus.
                block.layer.backgroundColor = look.isOnWhite ? ModernTheme.focusFill.cgColor : nil
                block.layer.cornerRadius = min(28, block.height / 2)
                block.layer.opacity = 1
            } else {
                block.layer.backgroundColor = nil
                block.layer.setOpacity(index == focus ? 1 : 0.42, pass.animation(.easeInOut(duration: 0.2), when: lastFocus != nil && lastFocus != focus && !kindChanged))
            }
            y += block.height + gap
        }
        for (id, block) in blocks where !live.contains(id) {
            block.layer.removeFromSuperlayer()
            blocks[id] = nil
        }
        let contentHeight = max(0, y - gap)

        // Under the rows (or in their place): that more is on its way, or why there are none.
        let note = content.isLoading ? "Loading..." : (content.rows.isEmpty ? (content.note ?? "") : "")
        message.isHidden = note.isEmpty
        if !note.isEmpty {
            let graphic = TextRenderer.render(TextSpec(text: note, fontName: look.regular, size: 30, color: RGBA(white: 1, alpha: 0.6), wrapWidth: column), scale: scale)
            message.show(graphic, at: CGPoint(x: inset, y: top + (content.rows.isEmpty ? 8 : contentHeight + max(gap, 20))))
        }

        // The one picked out sits at the top of the list, until the list's end comes up.
        let wanted = tops.indices.contains(focus) ? tops[focus] : 0
        let offset = prepared == content.rows.count ? min(wanted, max(0, contentHeight - viewport.height)) : wanted
        let shownViewport = viewport.offsetBy(dx: frame.minX, dy: frame.minY)
        rowPitches = pitches
        rowFrames = tops.indices.map { index in
            CGRect(x: frame.minX, y: shownViewport.minY + tops[index] - offset - gap / 2, width: width, height: pitches[index])
                .intersection(shownViewport)
        }
        let slides = lastFocus != nil && lastFocus != focus && !wasHidden && !kindChanged
        let slide: Animation = isModern ? .smooth(duration: 0.34) : .easeInOut(duration: 0.22)
        list.setFrame(CGRect(x: 0, y: -offset, width: width, height: max(contentHeight, 1)), slides ? slide : (offset == lastOffset || kindChanged ? nil : pass.animation))
        lastFocus = focus
        lastOffset = offset
        lastKind = content.kind
    }

    /// The modern sheet's corners, as its options panel's.
    private static let modernCornerRadius: CGFloat = 34

    /// Sets a row's words (and its picture, tick or arrow) in its block, and the block's height.
    private func set(_ block: Block, to row: YouTubePanelRow, picture: NSImage?, look: Look) {
        let scale = look.scale
        let column = look.column
        let pad = look.pad
        var isComment = false
        if case .comment = row.role { isComment = true }
        // A channel's round picture stands to the left of its lines.
        let pictureSide: CGFloat = 64
        let left: CGFloat = row.pictureURL == nil ? 0 : pictureSide + 18
        block.picture.isHidden = row.pictureURL == nil
        if row.pictureURL != nil {
            block.picture.frame = CGRect(x: pad.width, y: pad.height, width: pictureSide, height: pictureSide)
            block.picture.cornerRadius = pictureSide / 2
            block.picture.backgroundColor = CGColor(gray: look.isOnWhite ? 0 : 1, alpha: 0.12)
            block.picture.contents = LayerImageCache.cgImage(for: picture)
            block.picture.contentsGravity = .resizeAspectFill
        }
        // At the right end: an arrow where pressing leads on.
        var markWidth: CGFloat = 0
        block.mark.isHidden = !row.leadsOn
        var markGraphic: RenderedGraphic?
        if row.leadsOn {
            let color = look.isOnWhite ? RGBA(white: 0.04, alpha: 0.55) : RGBA(white: 1, alpha: 0.6)
            let graphic = SymbolRenderer.render("chevron.right", pointSize: isComment ? 20 : 24, weight: .bold, color: color, scale: scale)
            markGraphic = graphic
            markWidth = graphic.size.width + 16
        }
        let room = column - left - markWidth
        var height: CGFloat = 0
        // The first line: who or what, and beside it when or how many.
        let headingSize: CGFloat = isComment ? 26 : 32
        block.heading.isHidden = row.heading.isEmpty
        block.aside.isHidden = row.aside.isEmpty || row.heading.isEmpty
        if !row.heading.isEmpty {
            // (What's beside the name takes the width it needs, up to a third; the name the rest.)
            let asideGraphic = row.aside.isEmpty ? nil : TextRenderer.render(TextSpec(text: row.aside, fontName: look.regular, size: 22, color: look.dim, maxWidth: room * 0.34), scale: scale)
            let headingRoom = room - (asideGraphic.map { $0.size.width + 14 } ?? 0)
            let headingGraphic = TextRenderer.render(TextSpec(text: row.heading, fontName: look.medium, size: headingSize, color: look.primary, maxWidth: headingRoom), scale: scale)
            block.heading.show(headingGraphic, at: CGPoint(x: pad.width + left, y: pad.height))
            if let asideGraphic {
                block.aside.show(asideGraphic, at: CGPoint(x: pad.width + left + headingGraphic.size.width + 14, y: pad.height + headingGraphic.size.height - asideGraphic.size.height - 2))
            }
            height = headingGraphic.size.height
            if let markGraphic {
                block.mark.show(markGraphic, at: CGPoint(x: pad.width + column - markGraphic.size.width, y: pad.height + ((headingGraphic.size.height - markGraphic.size.height) / 2).rounded()))
            }
        } else if let markGraphic {
            block.mark.show(markGraphic, at: CGPoint(x: pad.width + column - markGraphic.size.width, y: pad.height + 4))
        }
        // The words.
        block.body.isHidden = row.body.isEmpty
        if !row.body.isEmpty {
            let bodyGraphic = TextRenderer.render(TextSpec(
                text: row.body,
                fontName: row.isTitle ? look.bold : look.regular,
                size: row.isTitle ? 36 : 28,
                color: look.words,
                wrapWidth: column - left,
                lineSpacing: 3,
            ), scale: scale)
            let bodyTop = height == 0 ? 0 : height + 8
            block.body.show(bodyGraphic, at: CGPoint(x: pad.width + left, y: pad.height + bodyTop))
            height = bodyTop + bodyGraphic.size.height
        }
        // A dim last line.
        block.footer.isHidden = row.footer.isEmpty
        if !row.footer.isEmpty {
            let footerGraphic = TextRenderer.render(TextSpec(text: row.footer, fontName: look.regular, size: 22, color: look.dim, maxWidth: column - left), scale: scale)
            let footerTop = height == 0 ? 0 : height + 8
            block.footer.show(footerGraphic, at: CGPoint(x: pad.width + left, y: pad.height + footerTop))
            height = footerTop + footerGraphic.size.height
        }
        block.height = max(height, row.pictureURL == nil ? 0 : pictureSide) + pad.height * 2
    }
}

/// The left side of YouTube's search screen: the field with what has been typed, how many
/// videos there are so far, and the grid of keys (see `YouTubeSearchPad`). It takes the place
/// of the carousel and the preview while the search screen shows.
@MainActor
final class YouTubeSearchPadLayer {
    /// Where the pieces go, in scene points. The pointer's clicks are placed with it too.
    struct Geometry {
        let field: CGRect
        let box: CGRect
        /// The keys' frames, by row and column.
        let keys: [[CGRect]]
        /// The middle of the arrow between the keys and the list.
        let arrow: CGPoint

        init(sceneSize: CGSize, menuLeft: CGFloat, rows: [[YouTubeSearchKey]]) {
            let room = max(360, menuLeft - 96 - 64)
            let width = min(648, room)
            let left = (64 + (room - width) / 2).rounded()
            let cellHeight: CGFloat = 78
            let padding: CGFloat = 16
            let boxHeight = CGFloat(rows.count) * cellHeight + padding * 2
            let fieldHeight: CGFloat = 62
            let gap: CGFloat = 26
            let top = ((sceneSize.height - (fieldHeight + gap + boxHeight)) / 2 + 20).rounded()
            let fieldRect = CGRect(x: left, y: top, width: width, height: fieldHeight)
            let boxRect = CGRect(x: left, y: fieldRect.maxY + gap, width: width, height: boxHeight)
            field = fieldRect
            box = boxRect
            let columns = CGFloat(rows.map(\.count).max() ?? 6)
            let cellWidth = (width - padding * 2) / columns
            keys = rows.enumerated().map { rowIndex, row in
                let span = columns / CGFloat(max(1, row.count))
                return row.indices.map { column in
                    CGRect(
                        x: boxRect.minX + padding + CGFloat(column) * span * cellWidth,
                        y: boxRect.minY + padding + CGFloat(rowIndex) * cellHeight,
                        width: span * cellWidth,
                        height: cellHeight,
                    ).insetBy(dx: 5, dy: 6)
                }
            }
            arrow = CGPoint(x: (boxRect.maxX + menuLeft) / 2 - 6, y: boxRect.midY)
        }
    }

    let layer = SceneLayer()
    private let field = SceneLayer()
    private let glass = SceneLayer()
    private let fieldText = SceneLayer()
    private let caret = SceneLayer()
    private let results = SceneLayer()
    private let box = SceneLayer()
    private let selection = SelectionBoxLayer()
    private var labels: [SceneLayer] = []
    /// The modern look's keys (see `ModernKeyTile`), and the one focus was on last.
    private var modernKeys: [ModernKeyTile] = []
    private var modernFocus: ModernKeyTile?
    private let arrow = SceneLayer()
    private var lastFocus: (row: Int, column: Int)?
    private var wasShown = false

    init() {
        layer.isHidden = true
        field.masksToBounds = true
        for sublayer in [results, field, box, selection.layer, arrow] {
            layer.addSublayer(sublayer)
        }
        for sublayer in [glass, fieldText, caret] { field.addSublayer(sublayer) }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0
        blink.duration = 0.55
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.isRemovedOnCompletion = false
        caret.add(blink, forKey: "blink")
    }

    func update(menu: MenuView, pass: RenderPass, sceneSize: CGSize, menuLeft: CGFloat, scale: CGFloat) {
        guard let pad = menu.youtubeSearchPad else {
            layer.isHidden = true
            wasShown = false
            lastFocus = nil
            for key in modernKeys { key.reset() }
            return
        }
        let appearing = !wasShown
        wasShown = true
        layer.isHidden = false
        layer.frame = CGRect(origin: .zero, size: sceneSize)
        layer.setOpacity(menu.thirdMenuOpacity, appearing ? nil : pass.animation)
        let style = TextEntryStyle.current
        let rows = YouTubeSearchKey.rows(showsSymbols: pad.showsSymbols)
        let geometry = Geometry(sceneSize: sceneSize, menuLeft: menuLeft, rows: rows)

        // The field: a magnifying glass, then the end of the text if it's too long to fit.
        field.frame = geometry.field
        field.backgroundColor = style.fieldBackground
        field.borderColor = style.fieldBorder
        field.borderWidth = 2
        field.cornerRadius = min(style.fieldCornerRadius, geometry.field.height / 2)
        let glassGraphic = SymbolRenderer.render("magnifyingglass", pointSize: 27, weight: .semibold, color: style.secondaryText, scale: scale)
        glass.show(glassGraphic, at: CGPoint(x: 18, y: ((geometry.field.height - glassGraphic.size.height) / 2).rounded()))
        let textLeft = 18 + glassGraphic.size.width + 14
        var shown = pad.text
        let room = geometry.field.width - textLeft - 26
        while !shown.isEmpty, FontMetrics.width(shown, fontName: style.fieldFont, size: 36) > room {
            shown.removeFirst()
        }
        let textGraphic = TextRenderer.render(TextSpec(text: shown.isEmpty ? " " : shown, fontName: style.fieldFont, size: 36, color: style.text), scale: scale)
        fieldText.show(textGraphic, at: CGPoint(x: textLeft, y: ((geometry.field.height - textGraphic.size.height) / 2).rounded()))
        // (A space at the end of the text has width too.)
        let textWidth = shown.isEmpty ? 0 : FontMetrics.width(shown, fontName: style.fieldFont, size: 36)
        caret.backgroundColor = style.caret
        caret.frame = CGRect(x: textLeft + textWidth + 2, y: (geometry.field.height - 40) / 2, width: 3, height: 40)

        // How many there are so far, over the field's right end.
        let found = menu.youtubeSearchResultsText
        results.isHidden = found.isEmpty
        if !found.isEmpty {
            let graphic = TextRenderer.render(TextSpec(text: found, fontName: style.bodyFont, size: 25, color: style.secondaryText), scale: scale)
            results.show(graphic, at: CGPoint(x: geometry.field.maxX - graphic.size.width - 4, y: geometry.field.minY - graphic.size.height - 8))
        }

        // The keys, in a box of their own in the classic look.
        box.isHidden = style.keyBackground != nil
        box.frame = geometry.box
        box.backgroundColor = CGColor(gray: 1, alpha: 0.03)
        box.borderColor = CGColor(gray: 1, alpha: 0.4)
        box.borderWidth = 2
        box.cornerRadius = 16
        let count = rows.reduce(0) { $0 + $1.count }
        while labels.count < count {
            let label = SceneLayer()
            layer.addSublayer(label)
            labels.append(label)
        }
        for index in labels.indices where index >= count { labels[index].isHidden = true }
        // The modern look's keys are tiles that show focus themselves, as its menus' rows do.
        let modernFill = style.focusFill
        while modernFill != nil, modernKeys.count < count {
            let key = ModernKeyTile()
            layer.addSublayer(key.layer)
            modernKeys.append(key)
        }
        for (index, key) in modernKeys.enumerated() where modernFill == nil || index >= count { key.layer.isHidden = true }
        // The key the arrows are on shows it: by the glossy box, or in the modern look by
        // turning white. Not while the list has the arrows, or after typing on a keyboard.
        let showsFocus = pad.hasFocus && !pad.lastInputWasTyping
        var focusFrame = CGRect.zero
        var index = 0
        for (rowIndex, row) in rows.enumerated() {
            for (column, key) in row.enumerated() {
                let frame = geometry.keys[rowIndex][column]
                let isFocused = showsFocus && rowIndex == pad.row && column == pad.column
                let isWord: Bool = if case .character = key { false } else { true }
                func lettering(_ color: RGBA) -> RenderedGraphic {
                    TextRenderer.render(TextSpec(
                        text: key.label(showsSymbols: pad.showsSymbols),
                        fontName: style.keyFont,
                        size: isWord ? 31 : 40,
                        color: color,
                        maxWidth: frame.width - 8,
                        minimumScaleFactor: 0.6,
                    ), scale: scale)
                }
                let label = labels[index]
                if let modernFill {
                    label.isHidden = true
                    let tile = modernKeys[index]
                    // (Drawn over its neighbours' shadows.)
                    if isFocused, tile !== modernFocus {
                        modernFocus = tile
                        layer.addSublayer(tile.layer)
                    }
                    tile.update(
                        frame: frame, cornerRadius: style.keyCornerRadius, fill: style.keyBackground, focusFill: modernFill,
                        focused: isFocused, animated: !appearing,
                    ) { lettering($0 ? style.focusedText : style.text) }
                } else {
                    let graphic = lettering(style.text)
                    label.isHidden = false
                    label.show(graphic, at: CGPoint(x: (frame.midX - graphic.size.width / 2).rounded(), y: (frame.midY - graphic.size.height / 2).rounded()))
                }
                if rowIndex == pad.row, column == pad.column { focusFrame = frame }
                index += 1
            }
        }

        let moved = lastFocus.map { $0.row != pad.row || $0.column != pad.column } ?? false
        let slide = appearing ? nil : pass.animation(.easeInOut(duration: 0.14), when: moved)
        lastFocus = (pad.row, pad.column)
        selection.layer.isHidden = !style.usesGlossySelection || !showsFocus
        let boxHeight = focusFrame.height
        selection.update(
            frame: CGRect(x: focusFrame.minX - 46.5, y: focusFrame.midY - boxHeight * 0.5 - 29, width: focusFrame.width + 93, height: boxHeight + 58),
            selectionBoxHeight: boxHeight,
            animation: slide,
        )

        // Between the keys and the list: the way the arrows can go, once something is found.
        let hasResults = !(menu.currentYouTubePage?.videos.isEmpty ?? true)
        arrow.isHidden = !hasResults
        if hasResults {
            let graphic = SymbolRenderer.render(pad.hasFocus ? "chevron.right" : "chevron.left", pointSize: 30, weight: .bold, color: style.text, scale: scale)
            arrow.show(graphic, at: CGPoint(x: (geometry.arrow.x - graphic.size.width / 2).rounded(), y: (geometry.arrow.y - graphic.size.height / 2).rounded()))
        }
    }
}
