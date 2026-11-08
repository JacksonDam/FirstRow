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
        )
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
    private var keyTiles: [[SceneLayer]] = []
    private let focusTile = SceneLayer()
    private let code = SceneLayer()
    private let status = SceneLayer()
    private var wasVisible = false
    private var lastFocus: (row: Int, column: Int)?

    // The key grid, in scene points.
    private static let unit: CGFloat = 92
    private static let gap: CGFloat = 8
    private static let keyHeight: CGFloat = 76
    private static let rowPitch: CGFloat = 92

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
            keyTiles.append(row.map { _ in
                let tile = SceneLayer()
                layer.addSublayer(tile)
                return tile
            })
        }
        focusTile.shadowColor = CGColor(gray: 0, alpha: 1)
        focusTile.shadowOpacity = 0.45
        focusTile.shadowRadius = 12
        focusTile.shadowOffset = CGSize(width: 0, height: 6)
        layer.addSublayer(focusTile)
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
            for row in keys + keyTiles { for key in row { key.isHidden = true } }
            focusTile.isHidden = true
            field.isHidden = true
            selection.layer.isHidden = true
            place(title, TextSpec(text: display.title, fontName: style.titleFont, size: style.titleSize, color: style.text, maxWidth: sceneSize.width - 200), centerX: centerX, top: 150)
            place(prompt, TextSpec(text: display.message, fontName: style.bodyFont, size: style.promptSize, color: style.secondaryText, wrapWidth: 1100, alignment: .center), centerX: centerX, top: 270)
            let spaced = display.code.map(String.init).joined(separator: " ")
            place(code, TextSpec(text: spaced, fontName: style.titleFont, size: style.codeSize, color: style.text), centerX: centerX, top: 430)
            place(status, TextSpec(text: display.status, fontName: style.bodyFont, size: style.promptSize, color: style.secondaryText, wrapWidth: 1100, alignment: .center), centerX: centerX, top: 700)
        } else if let entry {
            code.isHidden = true
            status.isHidden = true
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
                    let tile = keyTiles[rowIndex][columnIndex]
                    tile.isHidden = style.keyBackground == nil
                    tile.backgroundColor = style.keyBackground
                    tile.cornerRadius = style.keyCornerRadius
                    tile.frame = frame
                    let graphic = TextRenderer.render(TextSpec(
                        text: key.label(shifted: entry.isShifted),
                        fontName: style.keyFont,
                        size: isWord ? style.wordKeySize : style.keySize,
                        color: isFocused && style.focusFill != nil ? style.focusedText : style.text,
                        maxWidth: width - 8,
                        minimumScaleFactor: 0.6,
                    ), scale: scale)
                    let label = keys[rowIndex][columnIndex]
                    label.isHidden = false
                    label.show(graphic, at: CGPoint(x: frame.midX - graphic.size.width * 0.5, y: frame.midY - graphic.size.height * 0.5))
                    if rowIndex == entry.focusRow, columnIndex == entry.focusColumn { focusFrame = frame }
                }
            }
            let moved = lastFocus.map { $0.row != entry.focusRow || $0.column != entry.focusColumn } ?? false
            let slide = appearing ? nil : pass.animation(.easeInOut(duration: 0.14), when: moved)
            lastFocus = (entry.focusRow, entry.focusColumn)
            selection.layer.isHidden = !style.usesGlossySelection || entry.lastInputWasTyping
            focusTile.isHidden = style.focusFill == nil || entry.lastInputWasTyping
            if let fill = style.focusFill {
                // The focused key grows a little past its tile, as on a TV.
                let grown = focusFrame.insetBy(dx: -5, dy: -5)
                focusTile.backgroundColor = fill
                focusTile.cornerRadius = style.keyCornerRadius + 3
                focusTile.setFrame(grown, appearing ? nil : pass.animation(.focus(duration: 0.26), when: moved))
                focusTile.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: grown.size), cornerWidth: style.keyCornerRadius + 3, cornerHeight: style.keyCornerRadius + 3, transform: nil)
            }
            let boxHeight: CGFloat = 75
            selection.update(
                frame: CGRect(x: focusFrame.minX - 46.5, y: focusFrame.midY - boxHeight * 0.5 - 29, width: focusFrame.width + 93, height: boxHeight + 58),
                selectionBoxHeight: boxHeight,
                animation: slide,
            )
        }
        layer.setOpacity(menu.textEntryOpacity, appearing ? pass.animation(.easeInOut(duration: 0.3), when: true) : pass.animation)
    }
}
