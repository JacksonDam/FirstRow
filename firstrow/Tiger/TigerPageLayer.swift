import AVFoundation
import QuartzCore
#if os(macOS)
    import AppKit
#endif

/// One page of a section: the section's icon and the page's title at the top, and under the
/// title bar's line a list, the song that is playing, or a message.
@MainActor
final class TigerPageLayer {
    let layer = SceneLayer()
    /// What is under the title bar (it rides up with the bar's line as a section opens).
    let content = SceneLayer()
    let key: String
    let depth: Int

    private let header = SceneLayer()
    private let headerIcon = StillLayer()
    private let headerTitle = StillLayer()
    private var list: TigerListLayer?
    private var message: TigerMessageLayer?
    private var nowPlaying: TigerNowPlayingLayer?
    private var moviePreview: TigerMoviePreviewLayer?
    private var photosPreview: TigerPhotosPreviewLayer?
    private var isFrozen = false
    private var headerMemo: String?

    init(key: String, depth: Int) {
        self.key = key
        self.depth = depth
        headerIcon.contentsGravity = .resizeAspect
        header.addSublayer(headerIcon)
        header.addSublayer(headerTitle)
        layer.addSublayer(content)
        layer.addSublayer(header)
    }

    /// The page is on its way out: it stays as it is.
    func freeze() {
        isFrozen = true
        moviePreview?.pause()
    }

    func remove() {
        tearDown()
        layer.removeFromSuperlayer()
    }

    func tearDown() {
        moviePreview?.tearDown()
        list?.tearDown()
    }

    func updateBusyRow(menu: MenuView) {
        list?.updateBusyRow(menu: menu)
    }

    func update(_ page: TigerPage, menu: MenuView, pass: RenderPass, sceneSize: CGSize, scale: CGFloat, showsHeader: Bool) {
        guard !isFrozen else { return }
        let bounds = CGRect(origin: .zero, size: sceneSize)
        layingOut {
            layer.bounds = bounds
            content.bounds = bounds
            header.place(bounds)
        }
        updateHeader(page, sceneSize: sceneSize, scale: scale, shows: showsHeader)

        // A preview to the left of the list.
        if page.showsMoviePreview {
            let preview = moviePreview ?? {
                let made = TigerMoviePreviewLayer()
                layer.insertSublayer(made.layer, below: content)
                moviePreview = made
                return made
            }()
            preview.update(menu: menu, sceneSize: sceneSize)
        } else if let preview = moviePreview {
            preview.tearDown()
            preview.layer.removeFromSuperlayer()
            moviePreview = nil
        }
        if page.showsPhotosPreview {
            let preview = photosPreview ?? {
                let made = TigerPhotosPreviewLayer()
                layer.insertSublayer(made.layer, below: content)
                photosPreview = made
                return made
            }()
            preview.update(menu: menu, pass: pass, sceneSize: sceneSize)
        } else if let preview = photosPreview {
            preview.layer.removeFromSuperlayer()
            photosPreview = nil
        }

        switch page.content {
        case .list:
            let list = self.list ?? {
                let made = TigerListLayer()
                content.addSublayer(made.layer)
                self.list = made
                return made
            }()
            list.update(page, menu: menu, pass: pass, sceneSize: sceneSize, scale: scale)
            message?.layer.isHidden = true
            nowPlaying?.layer.isHidden = true
        case let .message(text):
            let message = self.message ?? {
                let made = TigerMessageLayer()
                content.addSublayer(made.layer)
                self.message = made
                return made
            }()
            message.layer.isHidden = false
            message.update(text, sceneSize: sceneSize, scale: scale)
            list?.layer.isHidden = true
            nowPlaying?.layer.isHidden = true
        case .nowPlaying:
            let nowPlaying = self.nowPlaying ?? {
                let made = TigerNowPlayingLayer()
                content.addSublayer(made.layer)
                self.nowPlaying = made
                return made
            }()
            nowPlaying.layer.isHidden = false
            nowPlaying.update(menu: menu, sceneSize: sceneSize, scale: scale)
            list?.layer.isHidden = true
            message?.layer.isHidden = true
        }
        if case .list = page.content { list?.layer.isHidden = false }
    }

    private func updateHeader(_ page: TigerPage, sceneSize: CGSize, scale: CGFloat, shows: Bool) {
        header.isHidden = !shows || page.title.isEmpty
        let memo = "\(page.rootID ?? "")|\(page.title)|\(sceneSize.width)x\(sceneSize.height)|\(scale)"
        guard memo != headerMemo else { return }
        headerMemo = memo
        let side = TigerRing.landedIconWidth
        withoutLayerActions {
            if let rootID = page.rootID {
                headerIcon.contents = LayerImageCache.cgImage(for: NSImage(named: TigerTheme.iconAssetName(forRootID: rootID)))
            }
            headerIcon.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            headerIcon.position = TigerRing.landedIconCenter(rootID: page.rootID, title: page.title, sceneSize: sceneSize)
            let graphic = TextRenderer.render(TextSpec(text: page.title, fontName: firstRowBoldFontName, size: TigerTheme.titleSize, maxWidth: sceneSize.width, minimumScaleFactor: 0.7, shadows: TigerTheme.textShadow), scale: scale)
            headerTitle.show(graphic, at: .zero)
            headerTitle.position = TigerRing.landedTitleCenter(rootID: page.rootID, title: page.title, sceneSize: sceneSize)
        }
    }
}

// MARK: - Lists

/// A page's list: the row chosen stays in the bar, and the rows move through it.
@MainActor
final class TigerListLayer {
    let layer = SceneLayer()
    private let selection = SceneLayer()
    private var selectionMemo: String?
    private let clip = SceneLayer()
    private let rows = SceneLayer()
    private var rowLayers: [Int: TigerRowLayer] = [:]
    private var shownSelection: Int?
    private var columnWidth: CGFloat = 0
    private var itemCount = 0

    /// Rows kept drawn either side of the one chosen (four show; the rest are for a held arrow).
    private static let overscan = 12

    init() {
        clip.masksToBounds = true
        clip.addSublayer(rows)
        layer.addSublayer(selection)
        layer.addSublayer(clip)
    }

    func tearDown() {
        rowLayers.values.forEach { $0.tearDown() }
    }

    /// The bar the chosen row stands in: two caps and a stretch between them, drawn as one
    /// picture so that no seam shows where they meet.
    private static func drawBar(width: CGFloat, scale: CGFloat) -> RenderedGraphic {
        let height = TigerTheme.selectionHeight
        let cap = min(height * 83 / 122, width * 0.5)
        let pictures = ["TigerSelectionEndCapLeft", "TigerSelectionMiddle", "TigerSelectionEndCapRight"].map { LayerImageCache.cgImage(for: NSImage(named: $0)) }
        return TextRenderer.draw(size: CGSize(width: width, height: height), padding: 0, scale: scale, shadows: []) { context in
            // (Whole pixels for the caps, so the stretch between them starts on one.)
            let capWidth = (cap * scale).rounded() / scale
            if let left = pictures[0] { context.draw(left, in: CGRect(x: 0, y: 0, width: capWidth, height: height)) }
            if let middle = pictures[1] { context.draw(middle, in: CGRect(x: capWidth, y: 0, width: max(0, width - capWidth * 2), height: height)) }
            if let right = pictures[2] { context.draw(right, in: CGRect(x: width - capWidth, y: 0, width: capWidth, height: height)) }
        }
    }

    func updateBusyRow(menu: MenuView) {
        guard let shownSelection, let row = rowLayers[shownSelection] else { return }
        row.updateBusy(menu: menu)
    }

    func update(_ page: TigerPage, menu: MenuView, pass: RenderPass, sceneSize: CGSize, scale: CGFloat) {
        let width = page.isCompact ? TigerTheme.compactColumnWidth : TigerTheme.columnWidth
        let leading = page.isCompact ? TigerTheme.compactColumnLeading : TigerTheme.columnLeading
        let items = page.items
        let selected = min(max(0, page.selectedIndex), max(0, items.count - 1))
        // Where the chosen row's top is, down from the top of the list's window.
        let anchor = TigerTheme.selectionTopInset - TigerTheme.listClipTopInset + (TigerTheme.selectionHeight - TigerTheme.rowHeight) * 0.5
        let windowHeight = min(sceneSize.height - TigerTheme.listClipTopInset, anchor + CGFloat(TigerTheme.visibleRowCount) * TigerTheme.rowPitch + TigerTheme.rowContentVerticalOffset)

        layingOut {
            layer.place(CGRect(origin: .zero, size: sceneSize))
            selection.isHidden = items.isEmpty
            let barKey = "\(width)|\(scale)"
            if barKey != selectionMemo {
                selectionMemo = barKey
                let bar = Self.drawBar(width: width, scale: scale)
                selection.show(bar, at: CGPoint(x: leading - 1.5, y: TigerTheme.selectionTopInset))
            }
            clip.place(CGRect(x: 0, y: TigerTheme.listClipTopInset, width: sceneSize.width, height: windowHeight))
            rows.bounds = CGRect(x: 0, y: 0, width: width, height: TigerTheme.rowHeight)
        }

        // The rows near the one chosen.
        let low = max(0, selected - Self.overscan), high = min(items.count - 1, selected + Self.overscan)
        let wanted = low <= high ? Set(low ... high) : []
        for (index, row) in rowLayers where !wanted.contains(index) || columnWidth != width {
            row.tearDown()
            row.layer.removeFromSuperlayer()
            rowLayers[index] = nil
        }
        columnWidth = width
        for index in wanted.sorted() {
            let row = rowLayers[index] ?? {
                let made = TigerRowLayer()
                rows.addSublayer(made.layer)
                rowLayers[index] = made
                return made
            }()
            withoutLayerActions {
                row.layer.place(CGRect(x: 0, y: CGFloat(index) * TigerTheme.rowPitch, width: width, height: TigerTheme.rowHeight))
            }
            row.update(items[index], menu: menu, isSelected: index == selected, width: width, isPodcastEpisode: page.isPodcastEpisodes, scale: scale)
        }

        // The rows slide so that the chosen one is in the bar.
        let place = CGPoint(x: leading, y: anchor + TigerTheme.rowContentVerticalOffset - CGFloat(selected) * TigerTheme.rowPitch)
        let moves = shownSelection != nil && shownSelection != selected && itemCount > 0 && !menu.isMenuFolderSwapTransitioning
        // (At the pace the change itself asks for, or the pace the arrows are moving at.)
        let glide: Animation? = moves
            ? pass.animation ?? (menu.useLinearSelectionSweepAnimation ? .linear(duration: menu.selectionAnimationDuration) : .easeInOut(duration: menu.selectionAnimationDuration))
            : nil
        rows.setPosition(place, glide)
        shownSelection = selected
        itemCount = items.count
    }
}

/// One row: its name, and at its right an arrow, a symbol or a few words.
@MainActor
final class TigerRowLayer {
    let layer = SceneLayer()
    private let title = SceneLayer()
    private let trailing = SceneLayer()
    private let badge = SceneLayer()
    private var spinner: SpinnerLayer?
    private var memo: Memo?
    private var itemID = ""
    private var width: CGFloat = 0

    private struct Memo: Equatable {
        var item: MenuListItemConfig
        var width: CGFloat
        var scale: CGFloat
        var dimsTrailing: Bool
        var isPodcastEpisode: Bool
    }

    init() {
        layer.addSublayer(title)
        layer.addSublayer(trailing)
        badge.isHidden = true
        layer.addSublayer(badge)
    }

    func tearDown() {
        spinner?.stop()
    }

    func update(_ item: MenuListItemConfig, menu: MenuView, isSelected: Bool, width: CGFloat, isPodcastEpisode: Bool, scale: CGFloat) {
        itemID = item.id
        self.width = width
        // A few words at the right are fainter except on the row that is chosen and at rest.
        let dimsTrailing = !isPodcastEpisode && !(isSelected && menu.isSelectionSettled)
        let memo = Memo(item: item, width: width, scale: scale, dimsTrailing: dimsTrailing, isPodcastEpisode: isPodcastEpisode)
        if memo != self.memo {
            self.memo = memo
            draw(item, width: width, dimsTrailing: dimsTrailing, isPodcastEpisode: isPodcastEpisode, scale: scale)
        }
        setBusy(isSelected && menu.tigerRowIsBusy(item.id))
    }

    func updateBusy(menu: MenuView) {
        setBusy(menu.tigerRowIsBusy(itemID))
    }

    private func draw(_ item: MenuListItemConfig, width: CGFloat, dimsTrailing: Bool, isPodcastEpisode: Bool, scale: CGFloat) {
        let height = TigerTheme.rowHeight
        let padding: CGFloat = 20
        let innerWidth = max(0, width - padding * 2)
        let trailingText: String? = item.trailingText.flatMap { $0 == "..." || $0 == "•••" ? nil : $0 }
        let trailingSize = isPodcastEpisode ? max(30, TigerTheme.rowTrailingSize - 2) : TigerTheme.rowTrailingSize
        // The room kept at the right for what stands there.
        var trailingColumn: CGFloat = 0
        if item.trailingSymbolName != nil || item.leadsToMenu {
            trailingColumn = 180
        }
        if let trailingText, item.trailingSymbolName == nil, !item.leadsToMenu {
            let measured = ceil(FontMetrics.width(trailingText, fontName: firstRowRegularFontName, size: trailingSize))
            trailingColumn = max(150, min(min(360, innerWidth * 0.7), measured + 24))
        }
        let leftColumn = max(0, innerWidth - trailingColumn)
        let textInset = TigerTheme.rowTextLeadingInset
        let titleWidth = max(1, leftColumn - (textInset - padding))
        // (What is at the right is laid out past the row's own right edge, and drawn back from there.)
        let columnRight = textInset + innerWidth

        withoutLayerActions {
            let graphic = TextRenderer.render(TextSpec(text: item.title, fontName: firstRowBoldFontName, size: TigerTheme.rowTitleSize, maxWidth: titleWidth, shadows: TigerTheme.textShadow), scale: scale)
            title.show(graphic, at: CGPoint(x: textInset, y: ((height - graphic.size.height) * 0.5).rounded()))

            let symbolRight = columnRight - (TigerTheme.rowTrailingSymbolRightInset - padding)
            var shown: RenderedGraphic?
            var right = symbolRight
            trailing.opacity = 1
            if let symbol = item.trailingSymbolName {
                shown = SymbolRenderer.render(symbol, pointSize: TigerTheme.rowTrailingSize, weight: .semibold, shadows: TigerTheme.textShadow, scale: scale)
            } else if item.leadsToMenu {
                shown = SymbolRenderer.render("chevron.right", pointSize: TigerTheme.rowArrowSize, weight: .heavy, shadows: TigerTheme.textShadow, scale: scale)
            } else if let trailingText {
                shown = TextRenderer.render(TextSpec(text: trailingText, fontName: firstRowRegularFontName, size: trailingSize, maxWidth: trailingColumn, minimumScaleFactor: 0.65), scale: scale)
                right = columnRight + (isPodcastEpisode ? -64 : -4)
                trailing.opacity = dimsTrailing ? 0.5 : 1
            }
            if let shown {
                trailing.isHidden = false
                trailing.show(shown, at: CGPoint(x: right - shown.size.width, y: ((height - shown.size.height) * 0.5).rounded()))
            } else {
                trailing.isHidden = true
                trailing.contents = nil
            }

            // A series with something new has a dot before its name.
            badge.isHidden = !item.showsBlueDot
            if item.showsBlueDot {
                badge.contents = LayerImageCache.cgImage(for: NSImage(named: "PodcastRecentBadge"))
                badge.place(CGRect(x: 16, y: (height - 56) * 0.5, width: 56, height: 56))
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        if busy {
            let spinner = self.spinner ?? {
                let made = SpinnerLayer()
                layer.addSublayer(made.layer)
                self.spinner = made
                return made
            }()
            withoutLayerActions {
                spinner.layer.isHidden = false
                spinner.layer.place(CGRect(x: width - 50 - 60, y: (TigerTheme.rowHeight - 60) * 0.5, width: 60, height: 60))
            }
            spinner.start()
        } else if let spinner, !spinner.layer.isHidden {
            spinner.stop()
            spinner.layer.isHidden = true
        }
    }
}

// MARK: - Messages

/// A page that says something in place of a list: there is no disc, nothing could be found.
@MainActor
final class TigerMessageLayer {
    let layer = SceneLayer()
    private let header = SceneLayer()
    private let subcaption = SceneLayer()
    private var memo: String?

    init() {
        layer.addSublayer(header)
        layer.addSublayer(subcaption)
    }

    func update(_ message: TigerMessage, sceneSize: CGSize, scale: CGFloat) {
        let key = "\(message.header)|\(message.subcaption)|\(sceneSize.width)x\(sceneSize.height)|\(scale)"
        guard key != memo else { return }
        memo = key
        let width = sceneSize.width, height = sceneSize.height
        let settledTop = TigerTheme.dividerTopInset + TigerTheme.dividerThickness
        let centerY = TigerTheme.dividerTopInset + TigerTheme.dividerThickness + (height - settledTop) * 0.45
        withoutLayerActions {
            layer.place(CGRect(origin: .zero, size: sceneSize))
            let headerGraphic = TextRenderer.render(TextSpec(text: message.header, fontName: firstRowBoldFontName, size: 72, wrapWidth: width * 0.8, alignment: .center, shadows: TigerTheme.textShadow), scale: scale)
            let subcaptionGraphic = message.subcaption.isEmpty ? RenderedGraphic.empty : TextRenderer.render(
                TextSpec(text: message.subcaption, fontName: firstRowBoldFontName, size: 38, color: RGBA(white: 1, alpha: 0.9), wrapWidth: width * 0.7, alignment: .center, shadows: TigerTheme.textShadow),
                scale: scale,
            )
            let total = headerGraphic.size.height + (subcaptionGraphic.isEmpty ? 0 : 40 + subcaptionGraphic.size.height)
            let top = centerY - total * 0.5
            header.show(headerGraphic, at: CGPoint(x: ((width - headerGraphic.size.width) * 0.5).rounded(), y: top.rounded()))
            subcaption.isHidden = subcaptionGraphic.isEmpty
            if !subcaptionGraphic.isEmpty {
                subcaption.show(subcaptionGraphic, at: CGPoint(x: ((width - subcaptionGraphic.size.width) * 0.5).rounded(), y: (top + headerGraphic.size.height + 40).rounded()))
            }
        }
    }
}

// MARK: - Now Playing

/// The song that is playing: its cover on the left over its reflection, what it is beside
/// that, and along the bottom how far through it is.
@MainActor
final class TigerNowPlayingLayer {
    let layer = SceneLayer()
    private let art = SceneLayer()
    private let artStandIn = SceneGradientLayer()
    private let artNote = SceneLayer()
    private let reflectionBox = SceneLayer()
    private let reflection = SceneLayer()
    private let reflectionStandIn = SceneGradientLayer()
    private let reflectionMask = StillGradientLayer()
    private let glyph = SceneLayer()
    private let title = SceneLayer()
    private let artist = SceneLayer()
    private let album = SceneLayer()
    private let scrubber = TigerScrubberLayer()

    init() {
        art.contentsGravity = .resizeAspectFill
        art.masksToBounds = true
        artStandIn.colors = [CGColor(srgbRed: 0.12, green: 0.13, blue: 0.17, alpha: 1), CGColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1)]
        artStandIn.startPoint = .zero
        artStandIn.endPoint = CGPoint(x: 1, y: 1)
        art.addSublayer(artStandIn)
        art.addSublayer(artNote)
        // The reflection: the cover upside down under itself, its first few rows fading out.
        reflectionBox.masksToBounds = true
        reflectionBox.opacity = 0.5
        reflection.contentsGravity = .resizeAspectFill
        reflection.masksToBounds = true
        reflectionStandIn.colors = artStandIn.colors
        reflectionStandIn.startPoint = .zero
        reflectionStandIn.endPoint = CGPoint(x: 1, y: 1)
        reflection.addSublayer(reflectionStandIn)
        reflectionBox.addSublayer(reflection)
        reflectionMask.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        reflectionMask.startPoint = CGPoint(x: 0.5, y: 0)
        reflectionMask.endPoint = CGPoint(x: 0.5, y: 1)
        reflectionBox.mask = reflectionMask
        for part in [reflectionBox, art, glyph, title, artist, album, scrubber.layer] {
            layer.addSublayer(part)
        }
    }

    func update(menu: MenuView, sceneSize: CGSize, scale: CGFloat) {
        let width = sceneSize.width, height = sceneSize.height
        let contentTop = TigerTheme.dividerTopInset + TigerTheme.dividerThickness
        let artSide = min(width * (675.0 / 1920.0), 675)
        let artLeading: CGFloat = 80
        let artTop = contentTop + 100
        let reflectionHeight: CGFloat = 60
        let metaLeading = artLeading + artSide + width * 0.042 - 13
        let metaWidth = width * 0.42
        let metaCenterY = artTop + artSide * 0.41
        let titleSize = min(max(height * 0.067, 50), 76)
        let artistSize = min(max(height * 0.056, 42), 64)

        let seconds = max(0, menu.musicNowPlayingElapsedSeconds.isFinite ? menu.musicNowPlayingElapsedSeconds : 0)
        let duration = max(0, menu.musicNowPlayingDurationSeconds.isFinite ? menu.musicNowPlayingDurationSeconds : 0)
        let clamped = duration > 0 ? min(seconds, duration) : seconds
        let shownElapsed = duration > 0 && duration - clamped <= 0.02 ? duration : clamped
        let shownRemaining = max(0, duration - shownElapsed)
        let progress = CGFloat(duration > 0 ? min(1, max(0, shownElapsed / duration)) : 0)

        scrubber.update(elapsedSeconds: shownElapsed, remainingSeconds: shownRemaining, progress: progress, size: sceneSize, scale: scale)

        withoutLayerActions {
            layer.place(CGRect(origin: .zero, size: sceneSize))
            // The cover, or a note on grey where the song has none.
            let cover = LayerImageCache.cgImage(for: menu.musicNowPlayingArtwork)
            let artFrame = CGRect(x: artLeading, y: artTop, width: artSide, height: artSide)
            art.place(artFrame)
            art.contents = cover
            artStandIn.isHidden = cover != nil
            artStandIn.place(CGRect(origin: .zero, size: artFrame.size))
            artNote.isHidden = cover != nil
            if cover == nil {
                let note = SymbolRenderer.render("music.note", pointSize: artSide * 0.28, weight: .regular, color: RGBA(white: 1, alpha: 0.72), scale: scale)
                artNote.show(note, at: CGPoint(x: ((artSide - note.size.width) * 0.5).rounded(), y: ((artSide - note.size.height) * 0.5).rounded()))
            }
            reflectionBox.place(CGRect(x: artLeading, y: artTop + artSide, width: artSide, height: reflectionHeight))
            reflectionMask.frame = CGRect(x: 0, y: 0, width: artSide, height: reflectionHeight)
            reflection.bounds = CGRect(origin: .zero, size: artFrame.size)
            reflection.anchorPoint = CGPoint(x: 0, y: 0)
            reflection.position = CGPoint(x: 0, y: artSide)
            reflection.transform = CATransform3DMakeScale(1, -1, 1)
            reflection.contents = cover
            reflectionStandIn.isHidden = cover != nil
            reflectionStandIn.place(CGRect(origin: .zero, size: artFrame.size))

            // Playing, or paused.
            let isPaused = menu.musicNowPlayingLeadingGlyphState == .pause
            let symbol = SymbolRenderer.render(isPaused ? "pause.fill" : "play.fill", pointSize: 90, weight: .bold, scale: scale)
            glyph.show(symbol, at: CGPoint(x: (width - 42 - 45 - symbol.size.width * 0.5).rounded(), y: (36 + 45 - symbol.size.height * 0.5).rounded()))

            // The song, who it's by and what it's from, one under the other.
            let titleGraphic = TextRenderer.render(TextSpec(text: menu.musicNowPlayingTitle, fontName: firstRowBoldFontName, size: titleSize, maxWidth: metaWidth, minimumScaleFactor: 0.65, shadows: TigerTheme.textShadow), scale: scale)
            let artistGraphic = TextRenderer.render(TextSpec(text: menu.musicNowPlayingArtist, fontName: firstRowBoldFontName, size: artistSize, maxWidth: metaWidth, minimumScaleFactor: 0.65, shadows: TigerTheme.textShadow), scale: scale)
            let albumGraphic = menu.musicNowPlayingAlbum.isEmpty ? RenderedGraphic.empty : TextRenderer.render(
                TextSpec(text: menu.musicNowPlayingAlbum, fontName: firstRowBoldFontName, size: artistSize, maxWidth: metaWidth, minimumScaleFactor: 0.65, shadows: TigerTheme.textShadow),
                scale: scale,
            )
            let lines = [(title, titleGraphic), (artist, artistGraphic), (album, albumGraphic)]
            let shownLines = lines.filter { !$0.1.isEmpty }
            let total = shownLines.reduce(CGFloat(0)) { $0 + $1.1.size.height } + CGFloat(max(0, shownLines.count - 1)) * 50
            var top = metaCenterY - total * 0.5
            for (part, graphic) in lines {
                part.isHidden = graphic.isEmpty
                guard !graphic.isEmpty else { continue }
                part.show(graphic, at: CGPoint(x: metaLeading.rounded(), y: top.rounded()))
                top += graphic.size.height + 50
            }
        }
    }
}
