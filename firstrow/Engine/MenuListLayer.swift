import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// One of the menu lists on the right of the scene (main menu, section menu, third level).
/// Rows sit still in one scrolling container, and only rows near the view get layers.
@MainActor
final class MenuListLayer {
    struct Configuration {
        var items: [MenuListItemConfig]
        var selectedIndex: Int
        var menuWidth: CGFloat
        var arrowAppearance: ArrowAppearance
        var showsTopOverflowFade: Bool
        var visibleRowCount: Int
        var selectionBoxWidthScale: CGFloat = 1
        var selectionBoxHeightScale: CGFloat = 1
        var usesUniformRowLayout = false
        var theme: InterfaceTheme = .classic
        /// Fingers in charge with none down: nothing is shown as selected.
        var hidesSelection = false
        var visibility: Visibility = .visible
        /// How far the selected row is pulled past the end of the list (a Siri Remote swipe that
        /// can't go further), in scene points: only that row moves, as on Apple TV.
        var rubberBand: CGFloat = 0
        /// Room above the first row, inside what the list clips: for rows taller than the
        /// room each is centred on, whose tops would otherwise be cut off (the classic look).
        var topRoom: CGFloat = 0
    }

    /// How much of a list is on screen. One on its way out keeps its scroll, whatever happens
    /// to its selection meanwhile, and one out of sight changes without animating.
    enum Visibility {
        case visible
        case leaving
        case hidden
    }

    /// The list's box: the menu width, and as tall as its rows plus the space below them.
    let layer = SceneLayer()
    private let selectionBox = SelectionBoxLayer()
    private let clip = SceneLayer()
    private let rowsContainer = SceneLayer()
    private let topFade = SceneGradientLayer()
    private let bottomFade = SceneGradientLayer()
    /// The modern look fades rows out at the list's edges rather than drawing black over them.
    private let edgeMask = SceneGradientLayer()
    private var rows: [Int: any MenuRowLayering] = [:]
    private var spareRows: [any MenuRowLayering] = []
    private var rowTheme: InterfaceTheme?
    private var lastSelectedIndex: Int?
    private var lastSelectedRowOffset: CGFloat?
    private var lastScrollOffset: CGFloat?
    private var lastScrollingUp: Bool?
    private var lastScrollingDown: Bool?
    private var lastEdgeFades: (top: Bool, bottom: Bool)?
    private var lastIdentity: String?
    /// Room the clip leaves above and below the list (the modern look's focused row grows and
    /// casts a shadow past its own box, which would be cut off at the top and bottom).
    private var clipMargin: CGFloat = 0
    private var lastRubberBand: CGFloat = 0
    /// Where the rows were last laid out, for finding the one under the pointer.
    private(set) var hitGeometry: MenuListHitGeometry?
    private static let clipOverhang: CGFloat = 2500

    init() {
        layer.addSublayer(selectionBox.layer)
        clip.masksToBounds = true
        layer.addSublayer(clip)
        clip.addSublayer(rowsContainer)
        for fade in [topFade, bottomFade] {
            fade.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0.78), CGColor(gray: 0, alpha: 0)]
            fade.opacity = 0
            layer.addSublayer(fade)
        }
        topFade.startPoint = CGPoint(x: 0.5, y: 0)
        topFade.endPoint = CGPoint(x: 0.5, y: 1)
        edgeMask.startPoint = CGPoint(x: 0.5, y: 0)
        edgeMask.endPoint = CGPoint(x: 0.5, y: 1)
        bottomFade.startPoint = CGPoint(x: 0.5, y: 1)
        bottomFade.endPoint = CGPoint(x: 0.5, y: 0)
    }

    /// Forgets the last selection so the list next appears without animating from it.
    func reset() {
        lastSelectedIndex = nil
        lastSelectedRowOffset = nil
        lastScrollOffset = nil
        lastScrollingUp = nil
        lastScrollingDown = nil
        lastEdgeFades = nil
        lastIdentity = nil
        hitGeometry = nil
    }

    func update(_ c: Configuration, menu: MenuView, pass: RenderPass, scale: CGFloat) {
        let items = c.items
        let isModern = c.theme == .modern
        if rowTheme != c.theme {
            // Rows are drawn differently in each look, so start them afresh.
            for row in Array(rows.values) + spareRows { row.layer.removeFromSuperlayer() }
            rows.removeAll()
            spareRows.removeAll()
            rowTheme = c.theme
            reset()
        }
        let menuWidth = c.menuWidth
        let selectedIndex = items.isEmpty ? 0 : min(max(0, c.selectedIndex), items.count - 1)
        let selectionWidth = menuWidth * c.selectionBoxWidthScale
        let selectionHeight = menu.selectionBoxHeight * c.selectionBoxHeightScale
        let usesLargeSelectionTextureSizing = c.selectionBoxWidthScale > 1.001 || c.selectionBoxHeightScale > 1.001
        let selectionTextureLeadingAdjustment = usesLargeSelectionTextureSizing ? menu.photosSelectionTextureLeadingAdjustment : 0
        let selectionTextureTrailingAdjustment = usesLargeSelectionTextureSizing ? menu.photosSelectionTextureTrailingAdjustment : 0
        let selectionTextureHeightAdjustment = usesLargeSelectionTextureSizing ? menu.photosSelectionTextureHeightAdjustment : 0
        let selectionVisualWidth = selectionWidth + (menu.selectionTextureVisualWidthDelta * c.selectionBoxWidthScale) + selectionTextureLeadingAdjustment + selectionTextureTrailingAdjustment
        let selectionVisualHeight = selectionHeight + (menu.selectionTextureVisualHeightDelta * c.selectionBoxHeightScale) + selectionTextureHeightAdjustment
        let selectionXOffset = -((selectionWidth - menuWidth) * 0.5)
        let selectionYOffset = -((selectionHeight - menu.selectionBoxHeight) * 0.5)
        let selectionVisualXOffset = selectionXOffset - ((selectionVisualWidth - selectionWidth) * 0.5) + ((selectionTextureTrailingAdjustment - selectionTextureLeadingAdjustment) * 0.5)
        let selectionVisualYOffset = selectionYOffset - ((selectionVisualHeight - selectionHeight) * 0.5)
        let rowContentWidth = selectionWidth
        let rowContentXOffset = selectionXOffset
        let rowLeadingCompensation = max(0, -rowContentXOffset)
        let dividerGap = menu.effectiveDividerSectionGap(forSelectionBoxHeightScale: c.selectionBoxHeightScale)
        let rowPitch = menu.effectiveRowPitch(forSelectionBoxHeightScale: c.selectionBoxHeightScale)
        let normalHeightIndices: Set<Int> = c.selectionBoxHeightScale > 1.001
            ? Set(items.indices.filter { items[$0].alignsTextToDividerStart })
            : []
        let viewportHeight = menu.menuViewportHeight(for: c.visibleRowCount)
        let rowOffsets: [CGFloat]
        let contentHeight: CGFloat
        let stickyScrollOffset: CGFloat
        let selectedRowOffset: CGFloat
        if c.usesUniformRowLayout {
            rowOffsets = []
            let count = items.count
            contentHeight = count > 0 ? CGFloat(count - 1) * rowPitch + selectionHeight : 0
            if contentHeight > viewportHeight, count > 0 {
                let anchor = CGFloat(min(max(0, menu.stickySelectionRowIndex), count - 1)) * rowPitch
                let selectedY = CGFloat(selectedIndex) * rowPitch
                stickyScrollOffset = max(viewportHeight - contentHeight, min(0, anchor - selectedY))
            } else {
                stickyScrollOffset = 0
            }
            selectedRowOffset = CGFloat(selectedIndex) * rowPitch
        } else {
            rowOffsets = menu.menuRowOffsets(for: items, dividerGap: dividerGap, rowPitch: rowPitch, normalHeightIndices: normalHeightIndices)
            contentHeight = menu.menuContentHeight(for: items, rowOffsets: rowOffsets, rowHeight: selectionHeight)
            stickyScrollOffset = menu.menuScrollOffset(contentHeight: contentHeight, selectedIndex: selectedIndex, rowOffsets: rowOffsets, viewportHeight: viewportHeight)
            selectedRowOffset = rowOffsets.indices.contains(selectedIndex) ? rowOffsets[selectedIndex] : 0
        }
        // While the pointer drives the list, it stays where the pointer left it.
        let identity = Self.identity(of: items)
        if lastScrollOffset == nil || lastIdentity != identity {
            menu.pointer.listAppears(identity: identity)
        }
        let pinnedScrollOffset = menu.pointer.pinnedScrollOffset(
            identity: identity,
            selectedRowTop: selectedRowOffset,
            selectedRowHeight: selectionHeight,
            viewportHeight: viewportHeight,
            contentHeight: contentHeight,
        )
        var scrollOffset = pinnedScrollOffset ?? stickyScrollOffset
        if c.visibility == .leaving, lastIdentity == identity, let lastScrollOffset {
            scrollOffset = lastScrollOffset
        }
        lastIdentity = identity
        let unseen = c.visibility == .hidden

        let selectionMoved = lastSelectedRowOffset != selectedRowOffset || lastScrollOffset != scrollOffset
        let indexChanged = lastSelectedIndex != selectedIndex
        let pinMoved = pinnedScrollOffset != nil && lastScrollOffset != scrollOffset
        // The modern look scrolls with a quadratic ease-out, except while a held arrow sweeps.
        let movement = isModern && !menu.useLinearSelectionSweepAnimation ? Animation.smooth(duration: 0.34) : menu.selectionMovementAnimation
        let selectionAnimation = lastSelectedRowOffset == nil || unseen ? nil : pass.animation(movement, when: selectionMoved)
        let isFreshList = lastScrollOffset == nil
        // A list following a finger moves with it, unanimated.
        let scrollAnimation: Animation?
        if isFreshList || menu.pointer.tracksFinger || unseen {
            scrollAnimation = nil
        } else if pinMoved, let coast = menu.pointer.scrollAnimation {
            // A flick coasting on, or a list springing back from past its end.
            scrollAnimation = coast
            menu.pointer.scrollAnimation = nil
        } else {
            scrollAnimation = pass.animation(movement, when: indexChanged || pinMoved)
        }
        lastSelectedRowOffset = selectedRowOffset
        lastScrollOffset = scrollOffset
        lastSelectedIndex = selectedIndex

        let layoutHeight = menu.menuListLayoutHeight(for: c.visibleRowCount)
        layer.bounds = CGRect(x: 0, y: 0, width: menuWidth, height: layoutHeight)

        // The selection.
        let selectedIsNormalHeight = normalHeightIndices.contains(selectedIndex)
        let compactReduction = (selectedIsNormalHeight && c.selectionBoxHeightScale > 1.001 && selectionVisualWidth > menuWidth)
            ? min(menu.photosCompactSelectionVisualWidthReduction, selectionVisualWidth - menuWidth)
            : 0
        let visualWidth = selectionVisualWidth - compactReduction
        let visualXOffset = selectionVisualXOffset + compactReduction * 0.5
        let visualHeight = selectedIsNormalHeight ? menu.selectionBoxHeight + menu.selectionTextureVisualHeightDelta : selectionVisualHeight
        let visualYOffset = selectedIsNormalHeight ? -(menu.selectionTextureVisualHeightDelta * 0.5) : selectionVisualYOffset
        // Modern rows show focus themselves: it jumps to the row, which grows a little.
        // Shown again (a finger landing), the selection starts where it is,
        // not sliding over from where it was last.
        let revealsSelection = selectionBox.layer.isHidden
        selectionBox.layer.isHidden = items.isEmpty || isModern || c.hidesSelection
        // A held arrow grows each row it reaches too (as on Apple TV), quicker the faster it goes.
        ModernMenuRowLayer.focusAnimation = menu.useLinearSelectionSweepAnimation
            ? .smooth(duration: min(ModernTheme.focusDuration, max(0.12, menu.selectionAnimationDuration * 1.6)))
            : .smooth(duration: ModernTheme.focusDuration)
        if !isModern {
            selectionBox.update(
                frame: CGRect(x: visualXOffset, y: selectedRowOffset + scrollOffset + visualYOffset, width: visualWidth, height: visualHeight),
                selectionBoxHeight: menu.selectionBoxHeight,
                animation: revealsSelection ? nil : selectionAnimation,
            )
        }
        // The selected row (and its bar) pulled a little past the end, alone.
        let bandAnimation: Animation? = c.rubberBand != lastRubberBand ? pass.animation : nil
        let bandTransform = c.rubberBand == 0 ? CATransform3DIdentity : CATransform3DMakeTranslation(0, c.rubberBand, 0)
        selectionBox.layer.setTransform(bandTransform, bandAnimation)

        // Rows scroll inside a box that clips them top and bottom only.
        let bottomMargin: CGFloat = isModern ? 34 : 0
        let margin: CGFloat = isModern ? 34 : c.topRoom
        if margin != clipMargin {
            // Keeps the rows where they are on screen as the room changes.
            rowsContainer.removeAnimation(forKey: "position")
            rowsContainer.position.y += margin - clipMargin
            clipMargin = margin
        }
        clip.frame = CGRect(x: -Self.clipOverhang, y: -margin, width: menuWidth + Self.clipOverhang * 2, height: viewportHeight + margin + bottomMargin)
        rowsContainer.bounds = CGRect(x: 0, y: 0, width: menuWidth, height: max(contentHeight, viewportHeight))
        // Read the on-screen scroll before the new animation replaces the one in flight.
        let presentedOffset: CGFloat = if isFreshList {
            scrollOffset
        } else if rowsContainer.animation(forKey: "position") != nil {
            (rowsContainer.presentation()?.position.y ?? rowsContainer.position.y) - margin
        } else {
            rowsContainer.position.y - margin
        }
        rowsContainer.setPosition(CGPoint(x: Self.clipOverhang, y: scrollOffset + margin), scrollAnimation)

        // Rows that need layers: everything the scroll passes over, plus a margin.
        let renderRange: Range<Int>
        let overscan = max(80, rowPitch * (menu.activeDirectionalHoldKey != .none ? 6.0 : 2.5))
        if c.usesUniformRowLayout, !items.isEmpty {
            let top = min(-scrollOffset, -presentedOffset) - overscan
            let bottom = max(-scrollOffset, -presentedOffset) + viewportHeight + overscan
            let first = max(0, Int(floor(top / rowPitch)))
            let last = min(items.count - 1, Int(ceil(bottom / rowPitch)))
            renderRange = first < last + 1 ? first ..< (last + 1) : 0 ..< 0
        } else if !rowOffsets.isEmpty {
            // Rows sit at increasing offsets: find the first and last near the visible part.
            let top = min(-scrollOffset, -presentedOffset) - overscan
            let bottom = max(-scrollOffset, -presentedOffset) + viewportHeight + overscan
            var low = 0
            var high = rowOffsets.count
            while low < high {
                let mid = (low + high) / 2
                if rowOffsets[mid] + selectionHeight < top { low = mid + 1 } else { high = mid }
            }
            var last = low
            while last + 1 < rowOffsets.count, rowOffsets[last + 1] <= bottom { last += 1 }
            renderRange = low < rowOffsets.count ? low ..< (last + 1) : 0 ..< 0
        } else {
            renderRange = 0 ..< 0
        }

        for (index, row) in rows where !renderRange.contains(index) {
            row.layer.isHidden = true
            spareRows.append(row)
            rows[index] = nil
        }
        for index in renderRange {
            let item = items[index]
            let row: any MenuRowLayering
            if let existing = rows[index] {
                row = existing
            } else {
                row = spareRows.popLast() ?? {
                    let made: any MenuRowLayering = isModern ? ModernMenuRowLayer() : MenuRowLayer()
                    rowsContainer.addSublayer(made.layer)
                    return made
                }()
                row.layer.isHidden = false
                rows[index] = row
            }
            let isNormalHeight = normalHeightIndices.contains(index)
            let rowHeight = isNormalHeight ? menu.selectionBoxHeight : selectionHeight
            let rowYOffset = isNormalHeight ? 0 : selectionYOffset
            let rowYBase = c.usesUniformRowLayout ? CGFloat(index) * rowPitch : rowOffsets[index]
            let showsSpeaker =
                (menu.thirdMenuMode == .musicSongs && menu.activeMusicPlaybackSongID == item.id && menu.hasActiveMusicPlaybackSession()) ||
                (menu.thirdMenuMode == .podcastsEpisodes && menu.isPodcastAudioNowPlaying && menu.activePodcastPlaybackEpisodeID == item.id)
            let spec = MenuRowLayer.Spec(
                item: item,
                isSelected: index == selectedIndex && !c.hidesSelection,
                // Only the selected row cares when the selection settles (for a long title's
                // scrolling); the others needn't redraw for it.
                isSettled: index == selectedIndex ? menu.isSelectionSettled : true,
                rowWidth: rowContentWidth,
                rowHeight: rowHeight,
                leadingCompensation: rowLeadingCompensation,
                showsPlaybackSpeaker: showsSpeaker,
                arrowAppearance: c.arrowAppearance,
                isPhotosRoot: menu.activeRootItemID == "photos",
                isPhotosThirdMenu: menu.isInThirdMenu,
                dynamicLeadingImage: (menu.activeRootItemID == "photos" && menu.isInThirdMenu && menu.thirdMenuMode == .photosDateAlbums)
                    ? menu.photosAlbumCoverImageCache[item.id]
                    : nil,
                scale: scale,
                theme: c.theme,
            )
            row.update(spec, menu: menu)
            row.layer.place(CGRect(x: rowContentXOffset, y: rowYBase + rowYOffset, width: rowContentWidth, height: rowHeight))
            row.layer.setTransform(index == selectedIndex ? bandTransform : CATransform3DIdentity, index == selectedIndex ? bandAnimation : nil)
            row.updateDecorations(
                divider: item.showsTopDivider
                    ? CGRect(x: menu.dividerLineInsetHorizontal, y: -(rowYOffset) - dividerGap + menu.dividerLineYOffsetInGap, width: max(0, rowContentWidth - menu.dividerLineInsetHorizontal * 2), height: 1)
                    : nil,
                background: item.showsLightRowBackground
                    ? CGRect(x: selectionXOffset - rowContentXOffset, y: 0, width: selectionWidth, height: rowHeight)
                    : nil,
            )
        }
        if spareRows.count > 40 {
            for row in spareRows.dropFirst(40) { row.layer.removeFromSuperlayer() }
            spareRows.removeLast(spareRows.count - 40)
        }

        hitGeometry = MenuListHitGeometry(
            identity: identity,
            itemCount: items.count,
            rowOffsets: rowOffsets,
            uniformRowPitch: c.usesUniformRowLayout ? rowPitch : nil,
            rowHeight: selectionHeight,
            rowYOffset: selectionYOffset,
            normalRowHeight: menu.selectionBoxHeight,
            normalHeightIndices: normalHeightIndices,
            rowSpacing: max(0, rowPitch - selectionHeight),
            rowPitch: rowPitch,
            rowXRange: rowContentXOffset ... (rowContentXOffset + rowContentWidth),
            viewportHeight: viewportHeight,
            contentHeight: contentHeight,
            scrollOffset: scrollOffset,
        )

        // The modern look: rows fade to transparent at an edge with more rows past it.
        if isModern, contentHeight > viewportHeight + 1 {
            let attaching = clip.mask !== edgeMask
            if attaching { clip.mask = edgeMask }
            edgeMask.frame = clip.bounds
            let clipHeight = max(1, viewportHeight + margin * 2)
            let fade = min(0.25, 44 / max(1, viewportHeight)) * viewportHeight / clipHeight
            let room = margin / clipHeight
            let fades = (top: scrollOffset < -1, bottom: scrollOffset > viewportHeight - contentHeight + 1)
            // An edge fades in as rows go past it, and out as the last of them comes back. The
            // room past each edge shows only while nothing is scrolled past it.
            if attaching || isFreshList || lastEdgeFades?.top != fades.top || lastEdgeFades?.bottom != fades.bottom {
                let top = CGColor(gray: 0, alpha: fades.top ? 0 : 1)
                let bottom = CGColor(gray: 0, alpha: fades.bottom ? 0 : 1)
                let colors = [top, top, CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), bottom, bottom]
                let animates = !attaching && !isFreshList && lastEdgeFades != nil
                edgeMask.set("colors", to: colors, unchanged: false, animation: animates ? .smoothInOut(duration: 0.28) : nil)
                lastEdgeFades = fades
            }
            edgeMask.locations = [0, room, room + fade, 1 - room - fade, 1 - room, 1].map { NSNumber(value: Double($0)) }
        } else if clip.mask != nil {
            clip.mask = nil
            lastEdgeFades = nil
        }

        // Fades at the edges while the list scrolls past more rows.
        let fadeWidth = max(visualWidth, menuWidth)
        topFade.isHidden = !c.showsTopOverflowFade || isModern
        bottomFade.isHidden = !c.showsTopOverflowFade || isModern
        topFade.frame = CGRect(x: 0, y: isModern ? 0 : -c.topRoom, width: fadeWidth, height: menu.submenuTopFadeHeight)
        bottomFade.frame = CGRect(x: 0, y: viewportHeight - menu.submenuTopFadeHeight, width: fadeWidth, height: menu.submenuTopFadeHeight)
        let fadeAnimation = Animation.easeInOut(duration: 0.12)
        topFade.setOpacity(menu.isMenuOverflowScrollingUp ? 1 : 0, pass.animation(fadeAnimation, when: lastScrollingUp != nil && lastScrollingUp != menu.isMenuOverflowScrollingUp))
        bottomFade.setOpacity(menu.isMenuOverflowScrollingDown ? 1 : 0, pass.animation(fadeAnimation, when: lastScrollingDown != nil && lastScrollingDown != menu.isMenuOverflowScrollingDown))
        lastScrollingUp = menu.isMenuOverflowScrollingUp
        lastScrollingDown = menu.isMenuOverflowScrollingDown
        lastRubberBand = c.rubberBand
    }

    /// The scroll as it is on screen, mid-animation included.
    var presentedScrollOffset: CGFloat? {
        guard hitGeometry != nil else { return nil }
        if rowsContainer.animation(forKey: "position") != nil {
            return (rowsContainer.presentation()?.position.y ?? rowsContainer.position.y) - clipMargin
        }
        return rowsContainer.position.y - clipMargin
    }

    /// Tells lists apart, so a pinned scroll only applies to the list it was pinned in.
    static func identity(of items: [MenuListItemConfig]) -> String {
        "\(items.count)|\(items.first?.id ?? "")|\(items.last?.id ?? "")"
    }

    /// Where the middle of the selection is, from the list's left edge.
    static func selectionCenterX(menuWidth: CGFloat) -> CGFloat {
        menuWidth * 0.5
    }
}

/// The selection bar as one joined image, so no seams show at fractional pixel edges.
@MainActor
final class SelectionBoxLayer {
    let layer = SceneLayer()
    private let texture = SceneLayer()

    private static let joined: (image: CGImage, height: CGFloat, center: CGRect)? = {
        guard let left = LayerImageCache.cgImage(for: NSImage(named: "SelectionEndCapLeft")),
              let middle = LayerImageCache.cgImage(for: NSImage(named: "SelectionMiddle")),
              let right = LayerImageCache.cgImage(for: NSImage(named: "SelectionEndCapRight"))
        else { return nil }
        let height = left.height
        let width = left.width + middle.width + right.width
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: layerBitmapInfo,
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(left, in: CGRect(x: 0, y: 0, width: left.width, height: height))
        context.draw(middle, in: CGRect(x: left.width, y: 0, width: middle.width, height: height))
        context.draw(right, in: CGRect(x: left.width + middle.width, y: 0, width: right.width, height: height))
        guard let image = context.makeImage() else { return nil }
        // Stretch one column at the middle piece's centre, so the caps keep their shape.
        let column = CGFloat(left.width + middle.width / 2)
        return (image, CGFloat(height), CGRect(x: column / CGFloat(width), y: 0, width: 1 / CGFloat(width), height: 1))
    }()

    init() {
        texture.contentsGravity = .resize
        if let joined = Self.joined {
            texture.contents = joined.image
            texture.contentsCenter = joined.center
        }
        layer.addSublayer(texture)
    }

    /// `frame` is the visual box, and the taller glow texture is centred on it.
    func update(frame: CGRect, selectionBoxHeight: CGFloat, animation: Animation?) {
        guard let joined = Self.joined else { return }
        let textureHeight = frame.height * (joined.height / selectionBoxHeight)
        // The caps keep the picture's proportions at this height.
        let pixelsPerPoint = joined.height / max(1, textureHeight)
        if texture.contentsScale != pixelsPerPoint {
            texture.contentsScale = pixelsPerPoint
        }
        layer.setFrame(frame, animation)
        texture.setFrame(CGRect(x: 0, y: (frame.height - textureHeight) * 0.5, width: frame.width, height: textureHeight), animation)
    }
}

/// A row of a menu list, in either look.
@MainActor
protocol MenuRowLayering: AnyObject {
    var layer: SceneLayer { get }
    func update(_ spec: MenuRowLayer.Spec, menu: MenuView)
    func updateDecorations(divider: CGRect?, background: CGRect?)
}

/// One row of a menu list.
@MainActor
final class MenuRowLayer: MenuRowLayering {
    struct Spec: Equatable {
        var item: MenuListItemConfig
        var isSelected: Bool
        var isSettled: Bool
        var rowWidth: CGFloat
        var rowHeight: CGFloat
        var leadingCompensation: CGFloat
        var showsPlaybackSpeaker: Bool
        var arrowAppearance: ArrowAppearance
        var isPhotosRoot: Bool
        var isPhotosThirdMenu: Bool
        var dynamicLeadingImage: NSImage?
        var scale: CGFloat
        var theme: InterfaceTheme = .classic

        static func == (lhs: Spec, rhs: Spec) -> Bool {
            lhs.item == rhs.item && lhs.isSelected == rhs.isSelected && lhs.isSettled == rhs.isSettled && lhs.theme == rhs.theme &&
                lhs.rowWidth == rhs.rowWidth && lhs.rowHeight == rhs.rowHeight &&
                lhs.leadingCompensation == rhs.leadingCompensation && lhs.showsPlaybackSpeaker == rhs.showsPlaybackSpeaker &&
                lhs.isPhotosRoot == rhs.isPhotosRoot && lhs.isPhotosThirdMenu == rhs.isPhotosThirdMenu &&
                lhs.dynamicLeadingImage === rhs.dynamicLeadingImage && lhs.scale == rhs.scale
        }
    }

    let layer = SceneLayer()
    private let divider = SceneLayer()
    private let background = SceneLayer()
    private let leadingImage = SceneLayer()
    /// A video row's lines under its title, made when a row first shows a video.
    private var videoLines: [SceneLayer] = []
    private let titleClip = SceneLayer()
    private let title = SceneLayer()
    private let marquee = MarqueeLayer()
    private let trailingText = SceneLayer()
    private let trailingGlyph = SceneLayer()
    private let blueDot = SceneLayer()
    private var spec: Spec?

    init() {
        divider.backgroundColor = CGColor(gray: 1, alpha: 0.34)
        background.backgroundColor = CGColor(gray: 1, alpha: 0.06)
        background.borderColor = CGColor(gray: 1, alpha: 0.02)
        background.borderWidth = 1
        leadingImage.masksToBounds = true
        leadingImage.contentsGravity = .resizeAspectFill
        titleClip.masksToBounds = true
        for sublayer in [background, divider, leadingImage, titleClip, trailingText, trailingGlyph, blueDot] {
            layer.addSublayer(sublayer)
        }
        titleClip.addSublayer(title)
        titleClip.addSublayer(marquee.layer)
    }

    func updateDecorations(divider dividerFrame: CGRect?, background backgroundFrame: CGRect?) {
        divider.isHidden = dividerFrame == nil
        if let dividerFrame { divider.frame = dividerFrame }
        background.isHidden = backgroundFrame == nil
        if let backgroundFrame { background.frame = backgroundFrame }
    }

    /// A video's row: its picture on the left; beside it the title, who it's from, and on the
    /// last line its length and how many have watched it.
    private func updateVideoRow(_ media: MenuRowMedia, spec: Spec, menu: MenuView) {
        let scale = spec.scale
        let item = spec.item
        let rowHeight = spec.rowHeight
        let isActive = spec.isSelected && spec.isSettled
        trailingText.isHidden = true
        trailingGlyph.isHidden = true
        blueDot.isHidden = true
        let pictureHeight = (rowHeight - 22).rounded()
        let picture = CGRect(x: 34, y: ((rowHeight - pictureHeight) * 0.5).rounded(), width: (pictureHeight * 16 / 9).rounded(), height: pictureHeight)
        leadingImage.isHidden = false
        leadingImage.contents = LayerImageCache.cgImage(for: item.leadingImage)
        leadingImage.contentsGravity = .resizeAspectFill
        leadingImage.masksToBounds = true
        leadingImage.backgroundColor = CGColor(gray: 0.12, alpha: 1)
        leadingImage.frame = picture
        leadingImage.shadowOpacity = 0
        let textX = picture.maxX + 20
        let textWidth = max(1, spec.rowWidth - textX - 30)
        let titleHeight = FontMetrics.lineHeight(fontName: firstRowBoldFontName, size: 32)
        let smallHeight = FontMetrics.lineHeight(fontName: firstRowRegularFontName, size: 25)
        let top = ((rowHeight - (titleHeight + smallHeight * 2 + 4)) * 0.5).rounded()
        titleClip.frame = CGRect(x: textX, y: top, width: textWidth, height: titleHeight)
        let scrollsTitle = isActive && FontMetrics.width(item.title, fontName: firstRowBoldFontName, size: 32) > textWidth + 1
        if scrollsTitle {
            title.isHidden = true
            marquee.show(title: item.title, viewportWidth: max(1, textWidth.rounded(.towardZero)), height: titleHeight, scale: scale, size: 32)
        } else {
            marquee.stop()
            title.isHidden = false
            title.show(TextRenderer.render(TextSpec(text: item.title, fontName: firstRowBoldFontName, size: 32, maxWidth: textWidth), scale: scale), at: .zero)
        }
        if videoLines.isEmpty {
            videoLines = [SceneLayer(), SceneLayer(), SceneLayer()]
            for line in videoLines { layer.addSublayer(line) }
        }
        for line in videoLines { line.isHidden = false }
        let dim = RGBA(white: 1, alpha: 0.82)
        let byline = TextRenderer.render(TextSpec(text: media.byline, fontName: firstRowRegularFontName, size: 25, color: dim, maxWidth: textWidth), scale: scale)
        videoLines[0].show(byline, at: CGPoint(x: textX, y: top + titleHeight + 2))
        let lastTop = top + titleHeight + 2 + smallHeight + 2
        let length = TextRenderer.render(TextSpec(text: media.length, fontName: firstRowBoldFontName, size: 25, color: dim, maxWidth: textWidth * 0.3), scale: scale)
        videoLines[1].show(length, at: CGPoint(x: textX, y: lastTop))
        let count = TextRenderer.render(TextSpec(text: media.count, fontName: firstRowBoldFontName, size: 25, color: dim, maxWidth: textWidth * 0.66), scale: scale)
        videoLines[2].show(count, at: CGPoint(x: textX + textWidth - count.size.width, y: lastTop))
    }

    func update(_ spec: Spec, menu: MenuView) {
        guard spec != self.spec else { return }
        self.spec = spec
        if let media = spec.item.media {
            updateVideoRow(media, spec: spec, menu: menu)
            return
        }
        for line in videoLines { line.isHidden = true }
        leadingImage.backgroundColor = nil
        let scale = spec.scale
        let item = spec.item
        let arrow = spec.arrowAppearance
        let showsArrow = item.leadsToMenu
        let isActive = spec.isSelected && spec.isSettled
        let isArrowGlowing = showsArrow && isActive
        let isTrailingSymbolGlowing = item.trailingSymbolName != nil && isActive
        let isSpeakerGlowing = spec.showsPlaybackSpeaker && isActive
        let trailingOpacity: Float = isActive ? 1 : 0.5
        let hasLeadingImage = item.leadingImage != nil || item.leadingImageAssetName != nil
        let isPhotoAlbumRow = spec.isPhotosRoot && hasLeadingImage
        let horizontalPadding: CGFloat = isPhotoAlbumRow ? 9 : 20
        let innerWidth = max(0, spec.rowWidth - horizontalPadding * 2)
        let textLeadingInset = 14 + (hasLeadingImage ? 0 : spec.leadingCompensation)
        let textStartX = horizontalPadding + textLeadingInset
        let resolvedTrailingText = item.trailingText == "..." ? "•••" : item.trailingText
        let isDotTrail = resolvedTrailingText == "•••"
        let resolvedLeadingImage = spec.dynamicLeadingImage ?? item.leadingImage ?? item.leadingImageAssetName.flatMap { menu.cachedMenuRowLeadingImage(named: $0) }
        let isSharedPhotosDotsRow = spec.isPhotosRoot && !spec.isPhotosThirdMenu && showsArrow && isDotTrail && item.title == "Shared Photos"
        let effectiveArrowXOffset = isSharedPhotosDotsRow ? -10 : arrow.xOffset
        let trailingFontSize: CGFloat = isDotTrail ? 17 : 32
        let trailingToArrowSpacing: CGFloat = isDotTrail ? -0.2 : 6
        let trailingMeasuredWidth: CGFloat = {
            guard let resolvedTrailingText, !isDotTrail else { return 0 }
            return menu.measuredMenuRowTrailingTextWidth(resolvedTrailingText, fontSize: trailingFontSize)
        }()
        let trailingColumnWidth: CGFloat = {
            if spec.showsPlaybackSpeaker || item.trailingSymbolName != nil { return 132 }
            if resolvedTrailingText != nil, showsArrow {
                if isDotTrail { return 112 }
                let arrowWidth = max(22, arrow.fontSize * 0.9)
                let combined = trailingMeasuredWidth + arrowWidth + max(0, trailingToArrowSpacing) + 24
                return max(132, min(220, combined))
            }
            if resolvedTrailingText != nil {
                return max(94, min(min(360, innerWidth * 0.7), trailingMeasuredWidth + 18))
            }
            return showsArrow ? 132 : 0
        }()
        let showsTrailingColumn = spec.showsPlaybackSpeaker || item.trailingSymbolName != nil || resolvedTrailingText != nil || showsArrow
        let leftColumnWidth = max(0, innerWidth - (showsTrailingColumn ? trailingColumnWidth : 0))
        let leadingTextPadding: CGFloat = {
            if hasLeadingImage { return isPhotoAlbumRow ? 0 : 14 }
            if item.alignsTextToDividerStart { return max(0, menu.dividerLineInsetHorizontal - horizontalPadding) }
            return 14 + spec.leadingCompensation
        }()
        let desiredArrowEdgeInset = horizontalPadding + leadingTextPadding
        let currentArrowEdgeInset = horizontalPadding + max(0, -effectiveArrowXOffset)
        let symmetricArrowXOffset = effectiveArrowXOffset - max(0, desiredArrowEdgeInset - currentArrowEdgeInset)
        let usesWordmark = item.leadingImage == nil && item.leadingImageAssetName == "appleTVNameImage"
        let leadingImageDimension: CGFloat = hasLeadingImage ? (usesWordmark ? 96 : (isPhotoAlbumRow ? 72 : 52)) : 0
        let leadingToTitleSpacing: CGFloat = hasLeadingImage ? (isPhotoAlbumRow ? 12 : 14) : 0
        let titleAvailableWidth = max(1, leftColumnWidth - leadingTextPadding - leadingImageDimension - leadingToTitleSpacing)
        let rowHeight = spec.rowHeight
        let leftColumnX = horizontalPadding + leadingTextPadding

        // Leading picture.
        if let resolvedLeadingImage, hasLeadingImage {
            leadingImage.isHidden = false
            leadingImage.contents = LayerImageCache.cgImage(for: resolvedLeadingImage)
            leadingImage.contentsGravity = usesWordmark ? .resizeAspect : .resizeAspectFill
            leadingImage.masksToBounds = !usesWordmark
            let size = usesWordmark ? CGSize(width: 96, height: 52) : CGSize(width: leadingImageDimension, height: leadingImageDimension)
            leadingImage.frame = CGRect(x: leftColumnX, y: (rowHeight - size.height) * 0.5, width: size.width, height: size.height)
            leadingImage.shadowOpacity = 0.45
            leadingImage.shadowRadius = 1.5
            leadingImage.shadowOffset = CGSize(width: 0, height: 1)
            leadingImage.shadowColor = CGColor(gray: 0, alpha: 1)
            leadingImage.shadowPath = usesWordmark ? nil : CGPath(rect: leadingImage.bounds, transform: nil)
        } else {
            leadingImage.isHidden = true
            leadingImage.contents = nil
        }

        // Title (scrolling when it's selected and too long to fit).
        let titleX = leftColumnX + (hasLeadingImage ? leadingImageDimension + leadingToTitleSpacing : 0)
        let titleHeight = FontMetrics.lineHeight(fontName: firstRowBoldFontName, size: 40)
        titleClip.frame = CGRect(x: titleX, y: (rowHeight - titleHeight) * 0.5, width: titleAvailableWidth, height: titleHeight)
        let titleMeasuredWidth = menu.measuredMenuRowTitleWidth(item.title)
        let effectiveTitleWidth = max(1, titleAvailableWidth - (spec.showsPlaybackSpeaker ? 28 : 0))
        let scrollsTitle = isActive &&
            item.title.trimmingCharacters(in: .whitespacesAndNewlines).count > 30 &&
            titleMeasuredWidth > effectiveTitleWidth + 1
        if scrollsTitle {
            title.isHidden = true
            marquee.show(title: item.title, viewportWidth: max(1, titleAvailableWidth.rounded(.towardZero)), height: titleHeight, scale: scale)
        } else {
            marquee.stop()
            title.isHidden = false
            title.show(TextRenderer.render(TextSpec(text: item.title, fontName: firstRowBoldFontName, size: 40, maxWidth: titleAvailableWidth), scale: scale), at: .zero)
        }

        // Trailing column: playback speaker, a symbol, text with an arrow, text, or an arrow.
        let columnRightX = leftColumnX + leftColumnWidth + trailingColumnWidth
        let glow = Self.arrowGlow(arrow)
        trailingText.isHidden = true
        trailingGlyph.isHidden = true
        trailingGlyph.opacity = 1
        trailingText.opacity = 1
        func placeGlyph(_ graphic: RenderedGraphic, rightX: CGFloat, opacity: Float) {
            trailingGlyph.isHidden = false
            trailingGlyph.opacity = opacity
            trailingGlyph.show(graphic, at: CGPoint(x: rightX - graphic.size.width, y: ((rowHeight - graphic.size.height) * 0.5)))
        }
        if spec.showsPlaybackSpeaker {
            let speakerGlow = isSpeakerGlowing
                ? [TextShadow(color: RGBA(white: 1, alpha: 0.9), radius: 4.5), TextShadow(color: RGBA(white: 1, alpha: 0.45), radius: 10)]
                : []
            placeGlyph(SymbolRenderer.render("speaker.wave.3.fill", pointSize: 34, weight: .semibold, shadows: speakerGlow, scale: scale), rightX: columnRightX + arrow.xOffset, opacity: 1)
        } else if let symbolName = item.trailingSymbolName {
            placeGlyph(SymbolRenderer.render(symbolName, pointSize: 34, weight: .semibold, shadows: isTrailingSymbolGlowing ? glow : [], scale: scale), rightX: columnRightX + arrow.xOffset, opacity: trailingOpacity)
        } else if let resolvedTrailingText, showsArrow {
            let arrowGraphic = SymbolRenderer.render(arrow.symbolName, pointSize: arrow.fontSize, weight: arrow.symbolWeight, color: arrow.color, shadows: isArrowGlowing ? glow : [], scale: scale)
            let rightX = columnRightX + symmetricArrowXOffset
            placeGlyph(arrowGraphic, rightX: rightX, opacity: trailingOpacity)
            let textRightX = rightX - arrowGraphic.size.width - trailingToArrowSpacing
            let textGraphic: RenderedGraphic = if isDotTrail {
                Self.dotsGraphic(glowing: isArrowGlowing, glow: glow, scale: scale)
            } else {
                TextRenderer.render(TextSpec(
                    text: resolvedTrailingText,
                    fontName: firstRowRegularFontName,
                    size: trailingFontSize,
                    maxWidth: max(1, trailingColumnWidth - arrowGraphic.size.width - trailingToArrowSpacing),
                    minimumScaleFactor: 0.65,
                ), scale: scale)
            }
            trailingText.isHidden = false
            trailingText.opacity = trailingOpacity
            let dotsNudge = isDotTrail ? CGPoint(x: 8, y: -0.3) : .zero
            trailingText.show(textGraphic, at: CGPoint(x: textRightX - textGraphic.size.width + dotsNudge.x, y: (rowHeight - textGraphic.size.height) * 0.5 + dotsNudge.y))
        } else if let resolvedTrailingText {
            let graphic = TextRenderer.render(TextSpec(text: resolvedTrailingText, fontName: firstRowRegularFontName, size: 32, maxWidth: trailingColumnWidth, minimumScaleFactor: 0.65), scale: scale)
            trailingText.isHidden = false
            trailingText.opacity = trailingOpacity
            trailingText.show(graphic, at: CGPoint(x: columnRightX + arrow.xOffset - graphic.size.width, y: (rowHeight - graphic.size.height) * 0.5))
        } else if showsArrow {
            let arrowGraphic = SymbolRenderer.render(arrow.symbolName, pointSize: arrow.fontSize, weight: arrow.symbolWeight, color: arrow.color, shadows: isArrowGlowing ? glow : [], scale: scale)
            placeGlyph(arrowGraphic, rightX: columnRightX + symmetricArrowXOffset, opacity: trailingOpacity)
        }

        // Blue dot for unwatched items.
        if item.showsBlueDot {
            let dot = Self.blueDotGraphic(scale: scale)
            blueDot.isHidden = false
            let diameter: CGFloat = 16.5
            let centerX = max(diameter * 0.5 + 1, textStartX * 0.5)
            // The dot's left edge, not its centre, sits at centerX, nudged left.
            blueDot.show(dot, at: CGPoint(x: centerX - 6, y: (rowHeight - diameter) * 0.5))
        } else {
            blueDot.isHidden = true
        }
    }

    static func arrowGlow(_ arrow: ArrowAppearance) -> [TextShadow] {
        [
            TextShadow(color: arrow.color.opacity(CGFloat(arrow.glowPrimaryOpacity)), radius: arrow.glowPrimaryRadius),
            TextShadow(color: arrow.color.opacity(CGFloat(arrow.glowSecondaryOpacity)), radius: arrow.glowSecondaryRadius),
        ]
    }

    private static var dotsCache: [String: RenderedGraphic] = [:]

    /// "•••": three small white capsules.
    static func dotsGraphic(glowing: Bool, glow: [TextShadow], scale: CGFloat) -> RenderedGraphic {
        let key = "\(glowing)|\(scale)"
        if let cached = dotsCache[key] { return cached }
        let size = CGSize(width: 6.2 * 3 + 1.3 * 2, height: 4.1)
        let graphic = TextRenderer.draw(size: size, padding: 14, scale: scale, shadows: glowing ? glow : []) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            for index in 0 ..< 3 {
                let rect = CGRect(x: 14 + CGFloat(index) * (6.2 + 1.3), y: 14, width: 6.2, height: 4.1)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 2.05, cornerHeight: 2.05, transform: nil))
            }
            context.fillPath()
        }
        dotsCache[key] = graphic
        return graphic
    }

    private static var blueDotCache: [CGFloat: RenderedGraphic] = [:]

    static func blueDotGraphic(scale: CGFloat) -> RenderedGraphic {
        if let cached = blueDotCache[scale] { return cached }
        let diameter: CGFloat = 16.5
        let shadow = TextShadow(color: RGBA(red: 0.14, green: 0.48, blue: 0.94, alpha: 0.55), radius: 2.2)
        let padding: CGFloat = 8
        let graphic = TextRenderer.draw(size: CGSize(width: diameter, height: diameter), padding: padding, scale: scale, shadows: [shadow]) { context in
            let rect = CGRect(x: padding, y: padding, width: diameter, height: diameter)
            context.saveGState()
            context.addEllipse(in: rect)
            context.clip()
            let colors = [RGBA(red: 0.56, green: 0.83, blue: 1.0).cgColor, RGBA(red: 0.08, green: 0.33, blue: 0.76).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1]) {
                // Top leading to bottom trailing (y up in the bitmap).
                context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
            }
            context.restoreGState()
        }
        blueDotCache[scale] = graphic
        return graphic
    }
}

/// A title too long for its row, scrolling round and round with soft edges.
@MainActor
final class MarqueeLayer {
    let layer = SceneLayer()
    private let strip = SceneLayer()
    private let first = SceneLayer()
    private let second = SceneLayer()
    private let fadeMask = SceneGradientLayer()
    private var current: (title: String, width: CGFloat, scale: CGFloat)?
    private static let gap: CGFloat = 72
    private static let speed: CGFloat = 52
    private static let edgeFade: CGFloat = 34

    init() {
        layer.addSublayer(strip)
        strip.addSublayer(first)
        strip.addSublayer(second)
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fadeMask
        layer.isHidden = true
    }

    func show(title: String, viewportWidth: CGFloat, height: CGFloat, scale: CGFloat, fontName: String = firstRowBoldFontName, size: CGFloat = 40, color: RGBA = .white) {
        let identity = "\(title)|\(fontName)|\(size)|\(color.red),\(color.alpha)"
        if let current, current.title == identity, current.width == viewportWidth, current.scale == scale, !layer.isHidden, strip.animation(forKey: "marquee") != nil {
            return
        }
        current = (identity, viewportWidth, scale)
        layer.isHidden = false
        layer.frame = CGRect(x: 0, y: 0, width: viewportWidth, height: height)
        let fade = min(0.5, max(0, Self.edgeFade / max(1, viewportWidth)))
        fadeMask.frame = layer.bounds
        fadeMask.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        fadeMask.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
        let graphic = TextRenderer.render(TextSpec(text: title, fontName: fontName, size: size, color: color), scale: scale)
        first.show(graphic, at: .zero)
        second.show(graphic, at: CGPoint(x: graphic.size.width + Self.gap, y: 0))
        let cycle = max(1, graphic.size.width + Self.gap)
        strip.frame = CGRect(x: 0, y: 0, width: cycle * 2, height: height)
        strip.removeAllAnimations()
        let scroll = CABasicAnimation(keyPath: "position.x")
        scroll.fromValue = 0
        scroll.toValue = -cycle
        scroll.duration = Double(cycle / Self.speed)
        scroll.repeatCount = .infinity
        scroll.isRemovedOnCompletion = false
        scroll.beginTime = CACurrentMediaTime()
        strip.addAtFullRate(scroll, forKey: "marquee")
    }

    func stop() {
        guard !layer.isHidden else { return }
        layer.isHidden = true
        strip.removeAllAnimations()
        current = nil
    }
}
