import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// How the typing screen looks. Everything it draws takes its colours, fonts and sizes from here.
struct TextEntryStyle {
    var titleFont = firstRowBoldFontName
    var titleSize: CGFloat = 60
    var bodyFont = firstRowRegularFontName
    var promptSize: CGFloat = 30
    var fieldFont = firstRowBoldFontName
    var fieldSize: CGFloat = 44
    var keyFont = firstRowBoldFontName
    var keySize: CGFloat = 40
    var wordKeySize: CGFloat = 30
    var codeSize: CGFloat = 150
    var text = RGBA.white
    var secondaryText = RGBA(white: 1, alpha: 0.6)
    var fieldBackground = CGColor(gray: 1, alpha: 0.06)
    var fieldBorder = CGColor(gray: 1, alpha: 0.45)
    var fieldCornerRadius: CGFloat = 10
    var caret = CGColor(gray: 1, alpha: 0.9)
    /// The glossy bar behind the focused key.
    var usesGlossySelection = true
    /// The modern look's keys: a translucent tile each, the focused one white with dark text.
    var keyBackground: CGColor?
    var focusFill: CGColor?
    var focusedText = RGBA.black
    var keyCornerRadius: CGFloat = 0
    /// The words above a code.
    var codePrompt = RGBA.white
    /// The classic look's code has each character in a box of its own. With no fill there are
    /// no boxes, and the code is one line of text.
    var codeBoxFill: CGColor? = CGColor(gray: 0.1, alpha: 1)
    var codeBoxBorder = CGColor(gray: 0.4, alpha: 1)

    static var current: TextEntryStyle {
        guard ModernTheme.isActive else { return TextEntryStyle() }
        return TextEntryStyle(
            titleFont: ModernTheme.boldFontName,
            titleSize: 54,
            bodyFont: ModernTheme.regularFontName,
            promptSize: 30,
            fieldFont: ModernTheme.mediumFontName,
            fieldSize: 42,
            keyFont: ModernTheme.mediumFontName,
            keySize: 36,
            wordKeySize: 27,
            codeSize: 140,
            text: ModernTheme.text,
            secondaryText: ModernTheme.secondaryText,
            fieldBackground: ModernTheme.rowFill.cgColor,
            fieldBorder: CGColor(gray: 1, alpha: 0),
            fieldCornerRadius: 24,
            caret: CGColor(gray: 1, alpha: 0.9),
            usesGlossySelection: false,
            keyBackground: CGColor(gray: 1, alpha: 0.1),
            focusFill: ModernTheme.focusFill.cgColor,
            focusedText: ModernTheme.focusedText,
            keyCornerRadius: 14,
            codePrompt: ModernTheme.secondaryText,
            codeBoxFill: nil,
        )
    }
}

/// One key of the modern look's keyboards, drawn as a menu's rows are: a translucent tile with
/// a soft shadow all round it. Focus jumps to a key, which turns white with dark lettering and
/// grows a little; only the growing and shrinking ease, and the white fades as focus leaves.
@MainActor
final class ModernKeyTile {
    let layer = SceneLayer()
    /// The shadow is cast by a layer of its own, cut out where the tile is, so it doesn't
    /// darken the see-through tile from inside.
    private let shadowCaster = SceneLayer()
    private let shadowCutout = CAShapeLayer()
    private let tile = SceneLayer()
    private let content = SceneLayer()
    private let light = SceneLayer()
    private let dark = SceneLayer()
    private var shadowKey = ""
    private(set) var isFocused: Bool?

    init() {
        shadowCaster.shadowColor = CGColor(gray: 0, alpha: 1)
        shadowCaster.shadowRadius = 14
        shadowCaster.shadowOffset = .zero
        shadowCaster.shadowOpacity = 0.6
        shadowCutout.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        shadowCutout.fillRule = .evenOdd
        shadowCutout.fillColor = CGColor(gray: 0, alpha: 1)
        shadowCaster.mask = shadowCutout
        for sublayer in [shadowCaster, tile, content] { layer.addSublayer(sublayer) }
        content.addSublayer(light)
        content.addSublayer(dark)
    }

    /// Forgets which way it was, so the next update shows it as it is with nothing easing
    /// (the keyboard has been away).
    func reset() {
        isFocused = nil
    }

    /// `lettering` draws the key's label, dark for the white tile or light. `animated` is
    /// false as the keyboard comes on, so nothing grows as it appears.
    func update(frame: CGRect, cornerRadius: CGFloat, fill: CGColor?, focusFill: CGColor, focused: Bool, animated: Bool, lettering: (_ dark: Bool) -> RenderedGraphic) {
        let was = isFocused
        isFocused = focused
        let changed = was != nil && was != focused
        let growth: Animation? = changed && animated ? .smooth(duration: ModernTheme.focusDuration) : nil
        let unfocus: Animation? = changed && animated && !focused ? .smooth(duration: 0.22) : nil
        layer.isHidden = false
        layer.frame = frame
        let rest = CGRect(origin: .zero, size: frame.size)
        let key = "\(rest.width)x\(rest.height)|\(cornerRadius)"
        if key != shadowKey {
            shadowKey = key
            shadowCaster.shadowPath = CGPath(roundedRect: rest, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            let reach: CGFloat = 48
            shadowCutout.frame = rest.insetBy(dx: -reach, dy: -reach)
            let cutout = CGMutablePath()
            cutout.addRect(CGRect(x: 0, y: 0, width: rest.width + reach * 2, height: rest.height + reach * 2))
            let hole = CGRect(x: reach + 0.5, y: reach + 0.5, width: rest.width - 1, height: rest.height - 1)
            cutout.addPath(CGPath(roundedRect: hole, cornerWidth: cornerRadius - 0.5, cornerHeight: cornerRadius - 0.5, transform: nil))
            shadowCutout.path = cutout
        }
        shadowCaster.frame = rest
        // The size eases; the colour changes at once, or fades on the way out.
        if was != focused {
            tile.set("backgroundColor", to: focused ? focusFill : (fill ?? CGColor(gray: 1, alpha: 0)), unchanged: false, animation: unfocus)
            shadowCaster.set("shadowOpacity", to: Float(focused ? 0.75 : 0.6), unchanged: false, animation: unfocus ?? growth)
        } else if !focused {
            tile.backgroundColor = fill
        }
        let grow = ModernTheme.focusGrowth
        tile.setFrame(focused ? rest.insetBy(dx: -grow.width, dy: -grow.height) : rest, growth)
        let radius = focused ? cornerRadius + 3 : cornerRadius
        tile.set("cornerRadius", to: radius, unchanged: tile.cornerRadius == radius, animation: growth)
        content.place(rest)
        var grown = CATransform3DMakeTranslation(rest.midX, rest.midY, 0)
        grown = CATransform3DScale(grown, ModernTheme.focusedContentScale, ModernTheme.focusedContentScale, 1)
        grown = CATransform3DTranslate(grown, -rest.midX, -rest.midY, 0)
        content.setTransform(focused ? grown : CATransform3DIdentity, growth)

        func show(_ target: SceneLayer, _ graphic: RenderedGraphic) {
            target.show(graphic, at: CGPoint(x: (rest.midX - graphic.size.width * 0.5).rounded(), y: (rest.midY - graphic.size.height * 0.5).rounded()))
        }
        if focused {
            show(dark, lettering(true))
            light.isHidden = true
            dark.isHidden = false
            if was != focused { dark.setOpacity(1, nil) }
        } else {
            show(light, lettering(false))
            light.isHidden = false
            if let unfocus {
                // The dark lettering, as last drawn, fades out over the light fading in.
                light.setOpacity(0, nil)
                light.setOpacity(1, unfocus)
                dark.setOpacity(0, unfocus)
            } else if was != focused {
                light.setOpacity(1, nil)
                dark.isHidden = true
            }
        }
    }
}

/// Draws `MenuView.textEntry` (a field and a grid of keys) or `codeDisplay` (a big code)
/// over the menu scene.
@MainActor
final class TextEntryLayer {
    let layer = SceneLayer()
    private let title = SceneLayer()
    private let prompt = SceneLayer()
    private let field = SceneLayer()
    private let fieldText = SceneLayer()
    private let caret = SceneLayer()
    private let selection = SelectionBoxLayer()
    private var keys: [[SceneLayer]] = []
    /// The modern look's keys, made when they're first shown.
    private var modernKeys: [[ModernKeyTile]] = []
    private var modernFocus: ModernKeyTile?
    private let code = SceneLayer()
    private var codeBoxes: [SceneLayer] = []
    private var codeDigits: [SceneLayer] = []
    private let status = SceneLayer()
    private var wasVisible = false
    private var lastFocus: (row: Int, column: Int)?

    // The key grid, in scene points.
    private static let unit: CGFloat = 92
    private static let gap: CGFloat = 8
    private static let keyHeight: CGFloat = 76
    private static let rowPitch: CGFloat = 92

    // A code's boxes, in scene points, as they're made; they're shown at `codeScale` of that
    // (at full size a code of nine characters ran the whole width of the screen). A dash in
    // a code is a dash between two groups of boxes, in a narrower place of its own.
    private static let codeBoxSize = CGSize(width: 176, height: 196)
    private static let codeBoxGap: CGFloat = 44
    private static let codeScale: CGFloat = 0.55
    private static let codeDashWidth: CGFloat = 70

    private static func codePlaceWidth(_ character: String) -> CGFloat {
        character == "-" ? codeDashWidth : codeBoxSize.width
    }

    init() {
        layer.opacity = 0
        layer.isHidden = true
        field.masksToBounds = true
        for sublayer in [title, prompt, field, selection.layer, code, status] {
            layer.addSublayer(sublayer)
        }
        field.addSublayer(fieldText)
        field.addSublayer(caret)
        for row in TextEntryKey.rows {
            keys.append(row.map { _ in
                let key = SceneLayer()
                layer.addSublayer(key)
                return key
            })
        }
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0
        blink.duration = 0.55
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.isRemovedOnCompletion = false
        caret.add(blink, forKey: "blink")
    }

    func update(menu: MenuView, pass: RenderPass, sceneSize: CGSize, scale: CGFloat) {
        let entry = menu.textEntry
        let display = menu.codeDisplay
        guard entry != nil || display != nil else {
            layer.isHidden = true
            layer.opacity = 0
            wasVisible = false
            lastFocus = nil
            for key in modernKeys.joined() { key.reset() }
            return
        }
        let style = TextEntryStyle.current
        let appearing = !wasVisible
        wasVisible = true
        layer.isHidden = false
        layer.frame = CGRect(origin: .zero, size: sceneSize)
        let centerX = sceneSize.width * 0.5

        func place(_ target: SceneLayer, _ spec: TextSpec, centerX: CGFloat, top: CGFloat) {
            let graphic = TextRenderer.render(spec, scale: scale)
            target.isHidden = false
            target.show(graphic, at: CGPoint(x: centerX - graphic.size.width * 0.5, y: top))
        }

        if let display {
            for key in keys.joined() { key.isHidden = true }
            for key in modernKeys.joined() { key.layer.isHidden = true }
            field.isHidden = true
            selection.layer.isHidden = true
            let wrap = min(1100, sceneSize.width - 160)
            let room = sceneSize.width - 120
            let characters = display.code.map(String.init)
            let lines = [
                (title, TextSpec(text: display.title, fontName: style.titleFont, size: style.titleSize, color: style.text, maxWidth: sceneSize.width - 200)),
                (prompt, TextSpec(text: display.message, fontName: style.bodyFont, size: style.promptSize, color: style.codePrompt, wrapWidth: wrap, alignment: .center)),
                (status, TextSpec(text: display.status, fontName: style.bodyFont, size: style.promptSize, color: style.secondaryText, wrapWidth: wrap, alignment: .center)),
            ].map { ($0.0, TextRenderer.render($0.1, scale: scale)) }
            // The code is a row of boxes with a character in each, or one line of text.
            let boxed = style.codeBoxFill != nil
            let rowWidth = characters.map(Self.codePlaceWidth).reduce(0, +) + CGFloat(characters.count - 1) * Self.codeBoxGap
            let boxUnit = min(Self.codeScale, room / max(1, rowWidth))
            let line = boxed ? nil : TextRenderer.render(TextSpec(
                text: characters.joined(separator: " "),
                fontName: style.titleFont,
                size: (style.codeSize * Self.codeScale).rounded(),
                color: style.text,
                maxWidth: room,
                minimumScaleFactor: 0.5,
            ), scale: scale)
            let codeHeight = line?.size.height ?? (Self.codeBoxSize.height * boxUnit).rounded()
            let codeGap: CGFloat = boxed ? 70 : 60
            // What to do, the code and how it's going, as one block a little above the
            // screen's middle.
            let heights = lines.map(\.1.size.height)
            let blockHeight = heights[0] + 44 + heights[1] + 76 + codeHeight + codeGap + heights[2]
            let blockTop = ((sceneSize.height - blockHeight) / 2 - 36).rounded()
            var codeTop: CGFloat = blockTop + heights[0] + 44 + heights[1] + 76
            var tops: [CGFloat] = [blockTop, blockTop + heights[0] + 44, codeTop + codeHeight + codeGap]
            if let upright = menu.upright {
                // Standing upright: what to do above the fold, the code and how it's going below.
                let upper = upright.upperPane
                let lower = upright.lowerPane
                let headTop = (upper.minY + (upper.height - heights[0] - 48 - heights[1]) / 2).rounded()
                codeTop = (lower.minY + (lower.height - codeHeight - codeGap - heights[2]) / 2).rounded()
                tops = [headTop, headTop + heights[0] + 48, codeTop + codeHeight + codeGap]
            }
            for (index, line) in lines.enumerated() {
                line.0.isHidden = false
                line.0.show(line.1, at: CGPoint(x: centerX - line.1.size.width * 0.5, y: tops[index]))
            }
            code.isHidden = boxed
            if let line {
                code.show(line, at: CGPoint(x: centerX - line.size.width * 0.5, y: codeTop))
            }
            showCodeBoxes(boxed ? characters : [], style: style, unit: boxUnit, centerX: centerX, top: codeTop, scale: scale)
        } else if let entry {
            code.isHidden = true
            status.isHidden = true
            showCodeBoxes([], style: style, unit: 1, centerX: centerX, top: 0, scale: scale)
            place(title, TextSpec(text: entry.title, fontName: style.titleFont, size: style.titleSize, color: style.text, maxWidth: sceneSize.width - 200), centerX: centerX, top: 110)
            place(prompt, TextSpec(text: entry.prompt, fontName: style.bodyFont, size: style.promptSize, color: style.secondaryText, wrapWidth: 1200, alignment: .center), centerX: centerX, top: 200)

            // The field, showing the end of the text when it's too long to fit.
            let fieldWidth: CGFloat = 1100
            let fieldHeight: CGFloat = 84
            field.isHidden = false
            field.frame = CGRect(x: centerX - fieldWidth * 0.5, y: 300, width: fieldWidth, height: fieldHeight)
            field.backgroundColor = style.fieldBackground
            field.borderColor = style.fieldBorder
            field.borderWidth = 2
            field.cornerRadius = style.fieldCornerRadius
            var shown = entry.isSecure ? String(repeating: "•", count: entry.text.count) : entry.text
            let room = fieldWidth - 60
            while !shown.isEmpty, FontMetrics.width(shown, fontName: style.fieldFont, size: style.fieldSize) > room {
                shown.removeFirst()
            }
            let textGraphic = TextRenderer.render(TextSpec(text: shown.isEmpty ? " " : shown, fontName: style.fieldFont, size: style.fieldSize, color: style.text), scale: scale)
            fieldText.show(textGraphic, at: CGPoint(x: 24, y: (fieldHeight - textGraphic.size.height) * 0.5))
            let textWidth = shown.isEmpty ? 0 : textGraphic.size.width
            caret.backgroundColor = style.caret
            caret.frame = CGRect(x: 26 + textWidth, y: (fieldHeight - 50) * 0.5, width: 3, height: 50)

            // The keys.
            let rows = TextEntryKey.rows
            let gridWidth = 13 * Self.unit + 12 * Self.gap
            let gridLeft = centerX - gridWidth * 0.5
            let gridTop: CGFloat = 470
            var focusFrame = CGRect.zero
            // The modern look's keys are tiles that show focus themselves, as its menus' rows do.
            let modernFill = style.focusFill
            if modernFill != nil, modernKeys.isEmpty {
                modernKeys = rows.map { row in
                    row.map { _ in
                        let key = ModernKeyTile()
                        layer.addSublayer(key.layer)
                        return key
                    }
                }
            }
            if modernFill == nil { for key in modernKeys.joined() { key.layer.isHidden = true } }
            // (The key focus is on is drawn over its neighbours' shadows.)
            if modernFill != nil, !entry.lastInputWasTyping, modernKeys.indices.contains(entry.focusRow), modernKeys[entry.focusRow].indices.contains(entry.focusColumn) {
                let focused = modernKeys[entry.focusRow][entry.focusColumn]
                if focused !== modernFocus {
                    modernFocus = focused
                    layer.addSublayer(focused.layer)
                }
            }
            for (rowIndex, row) in rows.enumerated() {
                let total = row.reduce(0) { $0 + $1.units }
                var units = (13 - total) * 0.5
                for (columnIndex, key) in row.enumerated() {
                    let x = gridLeft + units * (Self.unit + Self.gap)
                    let width = key.units * Self.unit + (key.units - 1) * Self.gap
                    let frame = CGRect(x: x, y: gridTop + CGFloat(rowIndex) * Self.rowPitch, width: width, height: Self.keyHeight)
                    units += key.units
                    let isWord: Bool = if case .character = key { false } else { true }
                    let isFocused = rowIndex == entry.focusRow && columnIndex == entry.focusColumn && !entry.lastInputWasTyping
                    func lettering(_ color: RGBA) -> RenderedGraphic {
                        TextRenderer.render(TextSpec(
                            text: key.label(shifted: entry.isShifted),
                            fontName: style.keyFont,
                            size: isWord ? style.wordKeySize : style.keySize,
                            color: color,
                            maxWidth: width - 8,
                            minimumScaleFactor: 0.6,
                        ), scale: scale)
                    }
                    let label = keys[rowIndex][columnIndex]
                    if let modernFill {
                        label.isHidden = true
                        modernKeys[rowIndex][columnIndex].update(
                            frame: frame, cornerRadius: style.keyCornerRadius, fill: style.keyBackground, focusFill: modernFill,
                            focused: isFocused, animated: !appearing,
                        ) { lettering($0 ? style.focusedText : style.text) }
                    } else {
                        let graphic = lettering(style.text)
                        label.isHidden = false
                        label.show(graphic, at: CGPoint(x: frame.midX - graphic.size.width * 0.5, y: frame.midY - graphic.size.height * 0.5))
                    }
                    if rowIndex == entry.focusRow, columnIndex == entry.focusColumn { focusFrame = frame }
                }
            }
            let moved = lastFocus.map { $0.row != entry.focusRow || $0.column != entry.focusColumn } ?? false
            let slide = appearing ? nil : pass.animation(.easeInOut(duration: 0.14), when: moved)
            lastFocus = (entry.focusRow, entry.focusColumn)
            selection.layer.isHidden = !style.usesGlossySelection || entry.lastInputWasTyping
            let boxHeight: CGFloat = 75
            selection.update(
                frame: CGRect(x: focusFrame.minX - 46.5, y: focusFrame.midY - boxHeight * 0.5 - 29, width: focusFrame.width + 93, height: boxHeight + 58),
                selectionBoxHeight: boxHeight,
                animation: slide,
            )
        }
        layer.setOpacity(menu.textEntryOpacity, appearing ? pass.animation(.easeInOut(duration: 0.3), when: true) : pass.animation)
    }

    /// Puts each of `characters` in the middle of a box of its own, in a row centred on
    /// `centerX`, at `unit` times the full size. With no characters the boxes go away.
    private func showCodeBoxes(_ characters: [String], style: TextEntryStyle, unit: CGFloat, centerX: CGFloat, top: CGFloat, scale: CGFloat) {
        // The boxes are kept from pass to pass, so they glide with the rest when the layout turns.
        while codeBoxes.count < characters.count {
            let box = SceneLayer()
            let digit = SceneLayer()
            layer.addSublayer(box)
            layer.addSublayer(digit)
            codeBoxes.append(box)
            codeDigits.append(digit)
        }
        for index in codeBoxes.indices where index >= characters.count {
            codeBoxes[index].isHidden = true
            codeDigits[index].isHidden = true
        }
        guard !characters.isEmpty else { return }
        let height = (Self.codeBoxSize.height * unit).rounded()
        let widths = characters.map { (Self.codePlaceWidth($0) * unit).rounded() }
        let gap = (Self.codeBoxGap * unit).rounded()
        var left = (centerX - (widths.reduce(0, +) + gap * CGFloat(characters.count - 1)) * 0.5).rounded()
        // A digit's middle, halfway up its height, sits on the middle of its box. Each is drawn
        // once at full size and scaled with its box, so the two change size together in a glide.
        let font = FontMetrics.font(style.titleFont, size: style.codeSize)
        let textTop = (Self.codeBoxSize.height + FontMetrics.capHeight(font)) * 0.5 - FontMetrics.baseline(font)
        for (index, character) in characters.enumerated() {
            let frame = CGRect(x: left, y: top, width: widths[index], height: height)
            left += widths[index] + gap
            let box = codeBoxes[index]
            box.isHidden = character == "-"
            box.backgroundColor = style.codeBoxFill
            box.borderColor = style.codeBoxBorder
            box.borderWidth = max(1, (4 * unit).rounded())
            box.cornerRadius = (13 * unit).rounded()
            box.frame = frame
            let graphic = TextRenderer.render(TextSpec(text: character, fontName: style.titleFont, size: style.codeSize, color: style.text), scale: scale)
            let drawn = graphic.imageFrame(at: CGPoint(x: -graphic.size.width * 0.5, y: textTop))
            let digit = codeDigits[index]
            digit.isHidden = false
            digit.contents = graphic.image
            digit.contentsScale = graphic.scale
            digit.bounds = CGRect(origin: .zero, size: drawn.size)
            digit.transform = CATransform3DMakeScale(unit, unit, 1)
            digit.position = CGPoint(x: (frame.midX + drawn.minX * unit).rounded(), y: (top + drawn.minY * unit).rounded())
        }
    }
}
