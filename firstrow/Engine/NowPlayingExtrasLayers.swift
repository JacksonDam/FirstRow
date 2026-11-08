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

    /// The side panel's width plus its margins, in canvas points (0 with nothing beside it).
    static func reserve(menu: MenuView, size: CGSize) -> CGFloat {
        if menu.isNowPlayingQueueVisible { return queueWidth(size) + 70 }
        if menu.isNowPlayingLyricsVisible { return lyricsFrame(size).width + 90 }
        return 0
    }

    static func lyricsFrame(_ size: CGSize) -> CGRect {
        let width = (size.width * 0.44).rounded()
        // Touch mode's buttons along the bottom keep the words above them.
        #if os(iOS)
            let height = AppSettings.isTouchEnabled ? size.height * 0.8 : size.height
        #else
            let height = size.height
        #endif
        return CGRect(x: size.width - width - 70, y: 0, width: width, height: height)
    }

    /// The move and scale, about the middle of the screen, for what stays.
    static func shift(menu: MenuView, size: CGSize) -> (dx: CGFloat, scale: CGFloat) {
        let reserve = reserve(menu: menu, size: size)
        guard reserve > 0 else { return (0, 1) }
        let scale = min(1, max(0.5, (size.width - reserve - 50) / (size.width * 0.86)))
        return (-reserve / 2, scale)
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
}

/// A faint bar that says something can be pulled out from where it sits. It fades very slowly
/// out and back in, every six seconds, so it never stays lit on one spot of the screen.
@MainActor
final class HintBarLayer {
    let layer = SceneLayer()
    private let bar = SceneLayer()
    private var isShown = false

    init() {
        layer.addSublayer(bar)
        layer.opacity = 0
        layer.isHidden = true
        bar.backgroundColor = CGColor(gray: 1, alpha: 1)
    }

    func update(frame: CGRect, shown: Bool, alpha: CGFloat = 0.36) {
        layer.place(frame)
        bar.frame = CGRect(origin: .zero, size: frame.size)
        bar.cornerRadius = min(frame.width, frame.height) / 2
        bar.backgroundColor = CGColor(gray: 1, alpha: alpha)
        guard shown != isShown else { return }
        isShown = shown
        if shown {
            layer.isHidden = false
            layer.setOpacity(1, .smooth(duration: 0.8))
            let breathe = CAKeyframeAnimation(keyPath: "opacity")
            breathe.values = [1, 1, 0, 0, 1, 1]
            breathe.keyTimes = [0, 0.12, 0.45, 0.55, 0.88, 1]
            breathe.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 5)
            breathe.duration = 6
            breathe.repeatCount = .infinity
            breathe.isRemovedOnCompletion = false
            breathe.beginTime = CACurrentMediaTime() + 1
            breathe.fillMode = .backwards
            bar.add(breathe, forKey: "breathe")
        } else {
            layer.setOpacity(0, .smoothInOut(duration: 0.3))
            bar.removeAnimation(forKey: "breathe")
        }
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
    private let edgeBar = HintBarLayer()

    private final class Row {
        let layer = SceneLayer()
        let capsule = SceneLayer()
        let title = SceneLayer()
        let detail = SceneLayer()
        let speaker = SceneLayer()
        var key = ""

        init() {
            for sublayer in [capsule, title, detail, speaker] {
                layer.addSublayer(sublayer)
            }
        }
    }

    private var rows: [Int: Row] = [:]
    private var spare: [Row] = []
    private var lastScroll: CGFloat?
    private var lastHeaderKey = ""

    /// In canvas points: the panel, where rows show, the first row's top, how far it scrolls,
    /// and the strip along the right edge that pulls it out.
    private(set) var panelFrame: CGRect = .zero
    private(set) var viewport: CGRect = .zero
    private(set) var listTop: CGFloat = 0
    private(set) var scrollLimit: CGFloat = 0
    private(set) var isAvailable = false

    init() {
        layer.addSublayer(edgeBar.layer)
        layer.addSublayer(panel)
        panel.addSublayer(header)
        panel.addSublayer(clip)
        clip.masksToBounds = true
        clip.addSublayer(rowsContainer)
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
        let shown = isAvailable && menu.isNowPlayingQueueVisible

        // The hint along the right edge, while the list is away.
        let barHeight: CGFloat = 130
        edgeBar.update(
            frame: CGRect(x: size.width - 24, y: (size.height - barHeight) / 2, width: 8, height: barHeight),
            shown: isAvailable && !menu.isNowPlayingQueueVisible && !menu.isNowPlayingLyricsVisible && !menu.isMusicSongTransitioning,
        )

        let width = NowPlayingSideLayout.queueWidth(size)
        panelFrame = CGRect(x: size.width - width - 40, y: 70, width: width, height: size.height - 140)
        panel.place(panelFrame)
        panel.backgroundColor = isModern ? CGColor(gray: 0.06, alpha: 0.72) : CGColor(gray: 0, alpha: 0.82)
        panel.cornerRadius = isModern ? 36 : 18
        panel.borderWidth = isModern ? 0 : 1.5
        panel.borderColor = CGColor(gray: 1, alpha: 0.22)
        panel.shadowColor = CGColor(gray: 0, alpha: 1)
        panel.shadowOpacity = 0.5
        panel.shadowRadius = 30
        panel.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: panelFrame.size), cornerWidth: panel.cornerRadius, cornerHeight: panel.cornerRadius, transform: nil)
        if shown { panel.isHidden = false }
        panel.setOpacity(shown ? 1 : 0, pass.animation)
        panel.setTransform(shown ? CATransform3DIdentity : CATransform3DMakeTranslation(width * 0.6, 0, 0), pass.animation)
        guard !panel.isHidden else { return }
        if !shown, pass.animation == nil { panel.isHidden = true }

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
        rowsContainer.setPosition(CGPoint(x: 0, y: padding - scroll), scrollAnimation)
        lastScroll = scroll

        // Rows near the view.
        let first = max(0, Int(floor(scroll / pitch)) - 2)
        let last = min(count - 1, Int(ceil((scroll + clipFrame.height) / pitch)) + 2)
        let range = first <= last ? first ... last : 1 ... 0
        for (index, row) in rows where !range.contains(index) {
            row.layer.isHidden = true
            spare.append(row)
            rows[index] = nil
        }
        let active = menu.nowPlayingQueueActiveIndex
        let hover = menu.nowPlayingQueueHoverIndex
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
            let rowFrame = CGRect(x: 12, y: CGFloat(index) * pitch, width: width - 24, height: pitch - 8)
            row.layer.frame = rowFrame
            let isHovered = hover == index
            let isPlaying = active == index
            let key = "\(index)|\(content.title)|\(content.detail)|\(isHovered)|\(isPlaying)|\(isModern)|\(scale)|\(width)"
            guard key != row.key else { continue }
            row.key = key
            row.capsule.frame = CGRect(origin: .zero, size: rowFrame.size)
            row.capsule.cornerRadius = isModern ? rowFrame.height / 2 : 10
            let focused = isHovered && isModern
            row.capsule.backgroundColor = isHovered
                ? (isModern ? ModernTheme.focusFill.cgColor : CGColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 0.55))
                : CGColor(gray: 1, alpha: isPlaying ? 0.14 : 0)
            let primary = focused ? ModernTheme.focusedText : RGBA(white: 1, alpha: 0.95)
            let secondary = focused ? ModernTheme.focusedSecondaryText : RGBA(white: 1, alpha: 0.55)
            var right = rowFrame.width - 26
            if isPlaying {
                let glyph = SymbolRenderer.render("speaker.wave.3.fill", pointSize: 24, weight: .semibold, color: primary, scale: scale)
                row.speaker.isHidden = false
                row.speaker.show(glyph, at: CGPoint(x: right - glyph.size.width, y: ((rowFrame.height - glyph.size.height) / 2).rounded()))
                right -= glyph.size.width + 16
            } else {
                row.speaker.isHidden = true
            }
            let textWidth = max(40, right - 26)
            let titleGraphic = TextRenderer.render(TextSpec(text: content.title, fontName: isModern ? ModernTheme.mediumFontName : firstRowBoldFontName, size: 27, color: primary, maxWidth: textWidth), scale: scale)
            let detailGraphic = TextRenderer.render(TextSpec(text: content.detail, fontName: isModern ? ModernTheme.regularFontName : firstRowRegularFontName, size: 20, color: secondary, maxWidth: textWidth), scale: scale)
            let block = titleGraphic.size.height + 2 + detailGraphic.size.height
            let top = ((rowFrame.height - block) / 2).rounded()
            row.title.show(titleGraphic, at: CGPoint(x: 26, y: top))
            row.detail.show(detailGraphic, at: CGPoint(x: 26, y: top + titleGraphic.size.height + 2))
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
        let area = NowPlayingSideLayout.lyricsFrame(size)
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
