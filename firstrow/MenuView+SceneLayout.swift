import CoreGraphics
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

enum MenuVirtualScenePreset {
    static let widescreen = CGSize(width: 1920, height: 1080)
    static let iPad = CGSize(width: 1440, height: 1080)

    static func scaledX(_ value: CGFloat, for virtualSize: CGSize) -> CGFloat {
        guard widescreen.width > 0 else { return value }
        return value * (virtualSize.width / widescreen.width)
    }

    static func additionalMenuGapX(for virtualSize: CGSize) -> CGFloat {
        virtualSize == iPad ? 56 : 0
    }
}

/// How the fixed-size menu scene fits the screen: scaled to fit and centred.
struct MenuVirtualSceneLayout {
    let virtualSize: CGSize
    let scale: CGFloat
    let offset: CGSize
    let fittedSize: CGSize

    init(containerSize: CGSize, virtualSize: CGSize) {
        self.virtualSize = virtualSize
        guard containerSize.width > 0, containerSize.height > 0, virtualSize.width > 0, virtualSize.height > 0 else {
            scale = 1
            offset = .zero
            fittedSize = virtualSize
            return
        }
        scale = min(containerSize.width / virtualSize.width, containerSize.height / virtualSize.height)
        fittedSize = CGSize(width: virtualSize.width * scale, height: virtualSize.height * scale)
        offset = CGSize(width: (containerSize.width - fittedSize.width) * 0.5, height: (containerSize.height - fittedSize.height) * 0.5)
    }
}

/// A foldable standing upright and open, flat or part way like a laptop. The screen is then
/// tall with the fold across its middle, so what a menu shows (the carousel, a preview, the
/// card) goes above the fold and the menu itself below it, and the full-screen things split the
/// same way.
struct UprightStance: Equatable {
    /// As wide as a landscape scene is tall, so everything keeps its size as the screen turns.
    static let sceneWidth: CGFloat = 1080
    static let menuWidth: CGFloat = 720

    /// 1080 wide and as tall as the screen makes it (about 1535 on an iPhone Duo).
    let sceneSize: CGSize
    /// The strip around the fold that nothing sits across, in scene points from the top.
    let foldTop: CGFloat
    let foldBottom: CGFloat
    /// Room the system keeps at the top and bottom edges, in scene points.
    let topInset: CGFloat
    let bottomInset: CGFloat

    /// `fold` is the strip the fold takes up, in the screen's points from its top (the middle
    /// tenth of an inch or so when the system doesn't say).
    init(screenSize: CGSize, fold: ClosedRange<CGFloat>?, safeTop: CGFloat, safeBottom: CGFloat) {
        let scale = Self.sceneWidth / max(1, screenSize.width)
        let fold = fold ?? (screenSize.height * 0.5 - 20) ... (screenSize.height * 0.5 + 20)
        sceneSize = CGSize(width: Self.sceneWidth, height: (screenSize.height * scale).rounded())
        foldTop = (fold.lowerBound * scale).rounded()
        foldBottom = (fold.upperBound * scale).rounded()
        topInset = (safeTop * scale).rounded()
        bottomInset = (safeBottom * scale).rounded()
    }

    /// The part above the fold.
    var upperPane: CGRect {
        CGRect(x: 0, y: topInset, width: sceneSize.width, height: max(0, foldTop - topInset))
    }

    /// The part below the fold.
    var lowerPane: CGRect {
        CGRect(x: 0, y: foldBottom, width: sceneSize.width, height: max(0, sceneSize.height - bottomInset - foldBottom))
    }

    /// The menu rows that fit below the fold under a title.
    var visibleRowCount: Int {
        min(9, max(4, Int((lowerPane.height - 118) / 80)))
    }

    /// A movie's controls sit together in the middle of the lower pane: its buttons, and under
    /// them its transport bar, laid out as if the screen ended here.
    var movieControlsFloor: CGFloat { lowerPane.midY + 222 }

    /// The middle of a movie's row of buttons.
    var movieButtonsCenter: CGPoint {
        CGPoint(x: sceneSize.width / 2, y: lowerPane.midY - 86)
    }
}

/// What the show (the carousel, and whatever a section puts in its place) has to work with
/// standing upright, in the carousel box's own space.
struct UprightShow: Equatable {
    /// The part of the screen above the fold.
    let pane: CGRect
    /// Where a sideways screen would be, for pieces that keep the place they have on one.
    let sidewaysScreen: CGRect

    /// The transform that brings `rect`, a piece as it is drawn on a sideways screen, to the
    /// middle of the pane, as large as fits up to `limit`. For a layer that covers the box.
    func fit(_ rect: CGRect, limit: CGFloat = 1.9) -> CATransform3D {
        // Room is left under the piece for the start of its reflection.
        let room = CGRect(x: pane.minX + 90, y: pane.minY + 56, width: pane.width - 180, height: pane.height - 140)
        guard rect.width > 0, rect.height > 0, room.width > 0, room.height > 0 else { return CATransform3DIdentity }
        let scale = min(limit, room.width / rect.width, room.height / rect.height)
        return moving(CGPoint(x: rect.midX, y: rect.midY), to: CGPoint(x: room.midX, y: room.midY), scale: scale)
    }

    /// The transform that keeps a piece where it is on a sideways screen: that screen's left edge
    /// on the pane's and its height the pane's.
    func sidewaysFit() -> CATransform3D {
        guard sidewaysScreen.height > 0 else { return CATransform3DIdentity }
        return moving(
            CGPoint(x: sidewaysScreen.minX, y: sidewaysScreen.midY),
            to: CGPoint(x: pane.minX, y: pane.midY),
            scale: pane.height / sidewaysScreen.height,
        )
    }

    /// Scales a layer covering the box (from its top left, where scene layers are held) and
    /// moves it so `from` lands on `to`.
    private func moving(_ from: CGPoint, to: CGPoint, scale: CGFloat) -> CATransform3D {
        CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(to.x - scale * from.x, to.y - scale * from.y, 0),
        )
    }
}

/// Where the main parts of the menu scene sit, in scene points (origin top left).
struct MenuSceneFrames {
    let sceneSize: CGSize
    let headerTop: CGFloat
    /// The carousel's box (the root carousel, the section's icon and its preview content).
    let carouselFrame: CGRect
    /// The box the menu lists hang from.
    let menuFrame: CGRect
    /// The carousel's box is drawn this much smaller or larger, about its top left corner.
    var carouselScale: CGFloat = 1
    /// Standing upright: what the show has to work with.
    var show: UprightShow?

    /// Gap between the title line and the row below it in the column.
    static let titleToRowSpacing: CGFloat = 35.3046875
    /// Minimum gap between the carousel and the menu list in the row.
    static let carouselToMenuSpacing: CGFloat = 8
}

extension MenuView {
    var selectionMovementAnimation: Animation {
        if useLinearSelectionSweepAnimation {
            return .linear(duration: selectionAnimationDuration)
        }
        return .easeInOut(duration: selectionAnimationDuration)
    }

    /// Where the scene's parts go; `classicLayout` asks for the classic look's whatever the
    /// look is (the first-launch screen's picture of it).
    func sceneFrames(sceneSize: CGSize, classicLayout: Bool = false) -> MenuSceneFrames {
        if let upright {
            return uprightSceneFrames(upright, classicLayout: classicLayout)
        }
        let carouselLaneWidth = carouselWidth(sceneSize: sceneSize)
        let menuLaneWidth = menuWidthConstrained(sceneSize: sceneSize)
        let carouselBoxHeight = iconSize * selectedCarouselAdjustedSizeMultiplier + 100
        let rowHeight = max(carouselBoxHeight, stableMenuListLayoutHeight)
        let titleHeight = FontMetrics.lineHeight(fontName: firstRowBoldFontName, size: 60)
        let columnHeight = titleHeight + MenuSceneFrames.titleToRowSpacing + rowHeight
        let titleTop = (sceneSize.height - columnHeight) * 0.5
        let rowTop = titleTop + titleHeight + MenuSceneFrames.titleToRowSpacing

        let rowContentWidth = carouselLaneWidth + MenuSceneFrames.carouselToMenuSpacing + menuLaneWidth
        let carouselX: CGFloat
        let menuX: CGFloat
        if rowContentWidth > sceneSize.width {
            let start = (sceneSize.width - rowContentWidth) * 0.5
            carouselX = start
            menuX = start + carouselLaneWidth + MenuSceneFrames.carouselToMenuSpacing
        } else {
            carouselX = 0
            menuX = sceneSize.width - menuLaneWidth
        }
        // The row is shifted down by the cluster compensation, and the carousel back up by it.
        let carouselY = rowTop + (rowHeight - carouselBoxHeight) * 0.5 + carouselOffsetY()
        if ModernTheme.isActive, !classicLayout {
            // A card on the left and the list on the right, with the title over the list as in
            // the classic look. The carousel keeps its place for when the classic look comes back.
            let modern = ModernTheme.layout(sceneSize: sceneSize, menuHeight: stableMenuListLayoutHeight)
            let modernTitleHeight = FontMetrics.lineHeight(fontName: ModernTheme.boldFontName, size: ModernTheme.titleSize)
            return MenuSceneFrames(
                sceneSize: sceneSize,
                headerTop: modern.menuFrame.minY - modernTitleHeight - MenuSceneFrames.titleToRowSpacing + menuHeaderVerticalOffset,
                carouselFrame: CGRect(x: carouselX + carouselSceneOffsetX, y: carouselY, width: carouselLaneWidth, height: carouselBoxHeight),
                menuFrame: modern.menuFrame,
            )
        }
        return MenuSceneFrames(
            sceneSize: sceneSize,
            headerTop: titleTop + menuHeaderVerticalOffset + menuClusterVerticalCompensation,
            carouselFrame: CGRect(
                x: carouselX + carouselSceneOffsetX,
                y: carouselY,
                width: carouselLaneWidth,
                height: carouselBoxHeight,
            ),
            menuFrame: CGRect(
                x: menuX + rightMenuSceneOffsetX,
                y: rowTop + menuClusterVerticalCompensation,
                width: menuLaneWidth,
                height: stableMenuListLayoutHeight,
            ),
        )
    }

    /// Standing upright: the carousel (and whatever a section shows in its place) above the fold,
    /// the title and its list below it.
    private func uprightSceneFrames(_ stance: UprightStance, classicLayout: Bool) -> MenuSceneFrames {
        let sceneSize = stance.sceneSize
        let isModern = ModernTheme.isActive && !classicLayout
        let titleHeight = isModern
            ? FontMetrics.lineHeight(fontName: ModernTheme.boldFontName, size: ModernTheme.titleSize)
            : FontMetrics.lineHeight(fontName: firstRowBoldFontName, size: 60)
        // The title and its rows, together in the middle of the lower part.
        let lower = stance.lowerPane
        let titleGap = MenuSceneFrames.titleToRowSpacing - menuHeaderVerticalOffset
        let blockHeight = titleHeight + titleGap + menuViewportHeight(for: defaultVisibleMenuRowCount)
        let headerTop = (lower.minY + max(0, (lower.height - blockHeight) * 0.5)).rounded()
        let menuWidth = UprightStance.menuWidth
        let menuFrame = CGRect(
            x: (sceneSize.width - menuWidth) * 0.5,
            y: headerTop + titleHeight + titleGap,
            width: menuWidth,
            height: stableMenuListLayoutHeight,
        )
        // The carousel's front icon sits in the middle of the upper part, a little above centre
        // so its reflection runs out under the title.
        let upper = stance.upperPane
        let boxSize = CGSize(width: carouselWidth(sceneSize: sceneSize), height: iconSize * selectedCarouselAdjustedSizeMultiplier + 100)
        let scale = min(0.9, upper.height / 816)
        let front = CGPoint(x: sceneSize.width * 0.5, y: upper.minY + upper.height * 0.48)
        let frontInBox = CGPoint(
            x: boxSize.width * 0.5 + restingSelectedHorizontalOffset - selectedCarouselEntryOffset,
            y: boxSize.height * 0.5 - 50 + restingSelectedVerticalOffset + selectedCarouselEntryOffset,
        )
        let boxOrigin = CGPoint(x: (front.x - frontInBox.x * scale).rounded(), y: (front.y - frontInBox.y * scale).rounded())
        // The box's place on a sideways screen, for the pieces that keep theirs.
        let sideways = MenuVirtualScenePreset.iPad
        let sidewaysTitleHeight = FontMetrics.lineHeight(fontName: firstRowBoldFontName, size: 60)
        let sidewaysBoxTop = (sideways.height - sidewaysTitleHeight - MenuSceneFrames.titleToRowSpacing - boxSize.height) * 0.5
            + sidewaysTitleHeight + MenuSceneFrames.titleToRowSpacing + carouselOffsetY()
        let sidewaysRow = boxSize.width + MenuSceneFrames.carouselToMenuSpacing + menuWidthConstrained(sceneSize: sideways)
        let sidewaysBoxLeft = min(0, (sideways.width - sidewaysRow) * 0.5) + MenuVirtualScenePreset.scaledX(40, for: sideways)
        return MenuSceneFrames(
            sceneSize: sceneSize,
            headerTop: headerTop,
            carouselFrame: CGRect(origin: boxOrigin, size: boxSize),
            menuFrame: menuFrame,
            carouselScale: scale,
            show: UprightShow(
                pane: CGRect(
                    x: (upper.minX - boxOrigin.x) / scale,
                    y: (upper.minY - boxOrigin.y) / scale,
                    width: upper.width / scale,
                    height: upper.height / scale,
                ),
                sidewaysScreen: CGRect(x: -sidewaysBoxLeft, y: -sidewaysBoxTop, width: sideways.width, height: sideways.height),
            ),
        )
    }

    /// Where the section's icon lands beside its title when standing upright, as an offset in the
    /// carousel's (scaled) box. It keeps the place it has beside the title in landscape.
    private func uprightLandedOffset(_ stance: UprightStance) -> CGPoint {
        let frames = uprightSceneFrames(stance, classicLayout: true)
        let titleHeight = FontMetrics.lineHeight(fontName: firstRowBoldFontName, size: 60)
        let titleWidth = FontMetrics.width(submenuHeaderTitleText, fontName: firstRowBoldFontName, size: 60)
        let titleLeading = frames.menuFrame.midX + landedIconWidth * 0.6 - titleWidth * 0.5
        let landing = CGPoint(x: titleLeading - landedIconWidth * 0.525, y: frames.headerTop + titleHeight - 37.7)
        let scale = max(frames.carouselScale, 0.0001)
        return CGPoint(
            x: (landing.x - frames.carouselFrame.minX) / scale - frames.carouselFrame.width * 0.5,
            y: (landing.y - frames.carouselFrame.minY) / scale - iconSize * selectedCarouselAdjustedSizeMultiplier * 0.5,
        )
    }

    /// The landed icon's place, from the middle of the carousel's box across and from the top of
    /// the front icon's box down.
    func landedSelectedOffset(sceneSize: CGSize) -> CGPoint {
        if let upright {
            return uprightLandedOffset(upright)
        }
        return CGPoint(x: landedSelectedHorizontalOffset(sceneSize: sceneSize), y: landedSelectedVerticalOffset)
    }

    /// The landed icon's scale, which undoes the scale its box is drawn at so it is the same
    /// size beside every title.
    func landedIconScale(in frames: MenuSceneFrames) -> CGFloat {
        landedIconScale / max(frames.carouselScale, 0.0001)
    }

    func baselineLayoutWidth(sceneSize: CGSize) -> CGFloat {
        // Standing upright the carousel keeps the box it has on its side.
        if upright != nil { return MenuVirtualScenePreset.iPad.width }
        return min(1920, sceneSize.width)
    }

    var shouldShowTVShowsSortPill: Bool {
        activeRootItemID == "tv_shows" &&
            isInSubmenu &&
            !isInThirdMenu &&
            submenuOpacity > 0.001
    }

    // MARK: - Layout geometry

    func carouselWidth(sceneSize: CGSize) -> CGFloat {
        min(
            iconSize * CGFloat(menuItems.count) + iconSpacing * CGFloat(menuItems.count - 1),
            baselineLayoutWidth(sceneSize: sceneSize) * 0.67,
        )
    }

    func carouselOffsetY() -> CGFloat {
        -arcRadius * 0.3 * 1.5
    }

    func landedSelectedHorizontalOffset(sceneSize: CGSize) -> CGFloat {
        let titleLeadingX = submenuHeaderTitleLeadingGlobalX(sceneSize: sceneSize)
        let iconHalfWidth = landedIconWidth * 0.5
        let desiredGap: CGFloat = -50
        let baselineWidth = baselineLayoutWidth(sceneSize: sceneSize)
        let carouselLaneWidth = carouselWidth(sceneSize: sceneSize)
        let carouselContainerOffsetX = MenuVirtualScenePreset.scaledX(20, for: activeMenuVirtualSceneSize)
        let carouselCenterX = (-baselineWidth * 0.5) + (carouselLaneWidth * 0.5) + carouselContainerOffsetX
        return titleLeadingX - desiredGap - iconHalfWidth - carouselCenterX
    }

    /// The title the section's icon lands beside: the section's own while the icon is on its way.
    var submenuHeaderTitleText: String {
        if isEnteringSubmenu, !isReturningToRoot {
            rootMenuTitle(for: activeRootItemID)
        } else {
            headerText
        }
    }

    func submenuHeaderTitleLeadingGlobalX(sceneSize: CGSize) -> CGFloat {
        let titleText = submenuHeaderTitleText
        let titleWidth = FontMetrics.width(titleText, fontName: firstRowBoldFontName, size: 60)
        let titleCenterX = firstRowHeaderOffsetX(sceneSize: sceneSize) + (landedIconWidth * 0.6)
        return titleCenterX - (titleWidth * 0.5)
    }

    func firstRowHeaderOffsetX(sceneSize: CGSize) -> CGFloat {
        rootMenuHeaderOffsetX(sceneSize: sceneSize)
    }

    /// The main menu's title sits over the middle of the menu list's selection.
    func rootMenuHeaderOffsetX(sceneSize: CGSize) -> CGFloat {
        let menuFrame = sceneFrames(sceneSize: sceneSize).menuFrame
        return menuFrame.midX - (sceneSize.width * 0.5)
    }

    func menuWidthConstrained(sceneSize: CGSize) -> CGFloat {
        min(menuWidth, baselineLayoutWidth(sceneSize: sceneSize) * 0.35 + 100)
    }

    func menuViewportHeight(for visibleRowCount: Int) -> CGFloat {
        let rowPitch = selectionBoxHeight + menuRowSpacing
        return CGFloat(max(1, visibleRowCount)) * rowPitch
    }

    func menuListLayoutHeight(for visibleRowCount: Int) -> CGFloat {
        menuViewportHeight(for: visibleRowCount) + menuListBottomInset
    }

    func menuViewportHeight() -> CGFloat {
        menuViewportHeight(for: activeVisibleMenuRowCount)
    }

    func menuListLayoutHeight() -> CGFloat {
        menuListLayoutHeight(for: activeVisibleMenuRowCount)
    }

    func effectiveDividerSectionGap(forSelectionBoxHeightScale scale: CGFloat) -> CGFloat {
        dividerSectionGapAfterLine + max(0, ((selectionBoxHeight * scale) - selectionBoxHeight) * 0.35)
    }

    func effectiveRowPitch(forSelectionBoxHeightScale scale: CGFloat) -> CGFloat {
        let effectiveSpacing = (activeRootItemID == "photos" && scale > 1) ? (menuRowSpacing * 2) : menuRowSpacing
        return (selectionBoxHeight * max(1, scale)) + effectiveSpacing
    }

    func menuRowOffsets(
        for items: [MenuListItemConfig],
        dividerGap: CGFloat = 0,
        rowPitch: CGFloat = 0,
        normalHeightIndices: Set<Int> = [],
    ) -> [CGFloat] {
        var offsets: [CGFloat] = []
        offsets.reserveCapacity(items.count)
        var y: CGFloat = 0
        let resolvedDividerGap = dividerGap > 0 ? dividerGap : dividerSectionGapAfterLine
        let resolvedRowPitch = rowPitch > 0 ? rowPitch : (selectionBoxHeight + menuRowSpacing)
        let normalPitch = selectionBoxHeight + menuRowSpacing
        for (index, item) in items.enumerated() {
            if item.showsTopDivider {
                y += resolvedDividerGap
            }
            offsets.append(y)
            y += normalHeightIndices.contains(index) ? normalPitch : resolvedRowPitch
        }
        return offsets
    }

    func menuContentHeight(
        for items: [MenuListItemConfig],
        rowOffsets: [CGFloat],
        rowHeight: CGFloat = 0,
    ) -> CGFloat {
        guard let lastRowOffset = rowOffsets.last, !items.isEmpty else { return 0 }
        let resolvedRowHeight = rowHeight > 0 ? rowHeight : selectionBoxHeight
        return lastRowOffset + resolvedRowHeight
    }

    func menuScrollOffset(
        contentHeight: CGFloat,
        selectedIndex: Int,
        rowOffsets: [CGFloat],
        viewportHeight: CGFloat,
    ) -> CGFloat {
        guard contentHeight > viewportHeight else { return 0 }
        guard rowOffsets.indices.contains(selectedIndex) else { return 0 }
        let anchorIndex = min(max(0, stickySelectionRowIndex), max(0, rowOffsets.count - 1))
        let anchorY = rowOffsets[anchorIndex]
        let selectedY = rowOffsets[selectedIndex]
        let offset = anchorY - selectedY
        let minOffset = viewportHeight - contentHeight
        return max(minOffset, min(0, offset))
    }

    func visibleMenuRowIndices(
        rowOffsets: [CGFloat],
        rowHeight: CGFloat,
        scrollOffset: CGFloat,
        viewportHeight: CGFloat,
        prefersWiderOverscan: Bool = false,
    ) -> [Int] {
        guard !rowOffsets.isEmpty else { return [] }
        let overscanPadding = max(80, rowHeight * (prefersWiderOverscan ? 4.0 : 2.0))
        let minVisibleY = -scrollOffset - overscanPadding
        let maxVisibleY = -scrollOffset + viewportHeight + overscanPadding
        return rowOffsets.enumerated().compactMap { index, rowOffset in
            rowOffset + rowHeight < minVisibleY || rowOffset > maxVisibleY ? nil : index
        }
    }

    // MARK: - Carousel

    func rootCarouselConfiguration(sceneSize: CGSize) -> RootCarouselConfiguration {
        let frames = sceneFrames(sceneSize: sceneSize, classicLayout: true)
        let boxScale = max(frames.carouselScale, 0.0001)
        return RootCarouselConfiguration(
            images: menuItems.map { menuImage(forRootID: $0.id) },
            selectedIndex: selectedIndex,
            isIconAnimated: isIconAnimated,
            isEnteringSubmenu: isEnteringSubmenu,
            isReturningToRoot: isReturningToRoot,
            isInSubmenu: isInSubmenu,
            showsSettledLandedIcon: showsSettledLandedIcon,
            iconSize: iconSize,
            scaleReduction: scaleReduction,
            landedIconScale: landedIconScale(in: frames),
            selectedSizeMultiplier: selectedCarouselAdjustedSizeMultiplier,
            arcRadius: arcRadius,
            restingOffset: CGPoint(x: restingSelectedHorizontalOffset, y: restingSelectedVerticalOffset),
            landedOffset: landedSelectedOffset(sceneSize: sceneSize),
            entryOffset: selectedCarouselEntryOffset,
            // In the box's own points, which are the scene's unless the box is drawn smaller.
            sceneWidth: sceneSize.width / boxScale,
            boxOriginInScene: CGPoint(x: frames.carouselFrame.minX / boxScale, y: frames.carouselFrame.minY / boxScale),
            selectionDuration: selectionAnimationDuration,
            usesLinearSweep: useLinearSelectionSweepAnimation,
            iconFlightDuration: iconFlightAnimationDuration,
            backgroundTransitionDuration: submenuBackgroundIconTransitionDuration,
            backgroundReturnDuration: submenuBackgroundIconReturnDuration,
        )
    }

    // MARK: - Measuring rows

    func measuredMenuRowTitleWidth(_ title: String) -> CGFloat {
        if let cached = MenuRowMeasureCache.titleWidthByTitle[title] {
            return cached
        }
        let measured = FontMetrics.width(title, fontName: firstRowBoldFontName, size: 40)
        if MenuRowMeasureCache.titleWidthByTitle.count > 20000 { MenuRowMeasureCache.titleWidthByTitle.removeAll() }
        MenuRowMeasureCache.titleWidthByTitle[title] = measured
        return measured
    }

    func measuredMenuRowTrailingTextWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        let cacheKey = "\(Int((fontSize * 10).rounded())):\(text)"
        if let cached = MenuRowMeasureCache.trailingWidthByTextAndFont[cacheKey] {
            return cached
        }
        let measured = FontMetrics.width(text, fontName: firstRowRegularFontName, size: fontSize)
        if MenuRowMeasureCache.trailingWidthByTextAndFont.count > 20000 { MenuRowMeasureCache.trailingWidthByTextAndFont.removeAll() }
        MenuRowMeasureCache.trailingWidthByTextAndFont[cacheKey] = measured
        return measured
    }

    func cachedMenuRowLeadingImage(named assetName: String) -> NSImage? {
        if let cached = MenuRowMeasureCache.imageByAssetName[assetName] {
            return cached
        }
        guard let image = NSImage(named: assetName) else { return nil }
        MenuRowMeasureCache.imageByAssetName[assetName] = image
        return image
    }
}

@MainActor
private enum MenuRowMeasureCache {
    static var titleWidthByTitle: [String: CGFloat] = [:]
    static var trailingWidthByTextAndFont: [String: CGFloat] = [:]
    static var imageByAssetName: [String: NSImage] = [:]
}

extension MenuView {
    var landedIconWidth: CGFloat {
        iconSize * selectedCarouselAdjustedSizeMultiplier * landedIconScale
    }

    var activeVisibleMenuRowCount: Int {
        isInThirdMenu ? thirdLevelVisibleMenuRowCount : defaultVisibleMenuRowCount
    }

    var stableMenuListLayoutHeight: CGFloat {
        let rowPitch = selectionBoxHeight + menuRowSpacing
        return (CGFloat(defaultVisibleMenuRowCount) * rowPitch) + menuListBottomInset
    }

    var menuClusterVerticalCompensation: CGFloat {
        let rowPitch = selectionBoxHeight + menuRowSpacing
        let extraRows = max(0, defaultVisibleMenuRowCount - baselineVisibleMenuRowCount)
        return CGFloat(extraRows) * rowPitch * 0.5
    }

    var showsSettledLandedIcon: Bool {
        isInSubmenu && !isEnteringSubmenu && !isReturningToRoot
    }

    var restingSelectedHorizontalOffset: CGFloat {
        iconSize * 0.75
    }

    var restingSelectedVerticalOffset: CGFloat {
        -(0.1 * iconSize)
    }

    var landedSelectedVerticalOffset: CGFloat {
        (-selectionBoxHeight * landedIconVerticalMultiplier) + landedFinalYOffsetAdjustment + menuHeaderVerticalOffset
    }

    var gapContentHorizontalOffset: CGFloat {
        restingSelectedHorizontalOffset - selectedCarouselEntryOffset
    }

    var gapContentVerticalOffset: CGFloat {
        0.85 * (restingSelectedVerticalOffset + selectedCarouselEntryOffset)
    }

    var gapContentAdjustedIconSize: CGFloat {
        iconSize * selectedCarouselAdjustedSizeMultiplier
    }

    var carouselSceneOffsetX: CGFloat {
        MenuVirtualScenePreset.scaledX(40, for: activeMenuVirtualSceneSize)
    }

    var rightMenuSceneOffsetX: CGFloat {
        MenuVirtualScenePreset.scaledX(-214, for: activeMenuVirtualSceneSize) +
            MenuVirtualScenePreset.additionalMenuGapX(for: activeMenuVirtualSceneSize)
    }

    #if os(iOS)
        var activeWindowScreen: UIScreen? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let foreground = scenes.first(where: { $0.activationState == .foregroundActive }) {
                return foreground.screen
            }
            return scenes.first?.screen
        }

        var activeFullscreenContainerSize: CGSize {
            guard let screenBounds = activeWindowScreen?.bounds else { return .zero }
            return CGSize(
                width: max(screenBounds.width, screenBounds.height),
                height: min(screenBounds.width, screenBounds.height),
            )
        }
    #endif

    var activeMenuVirtualSceneSize: CGSize {
        if let upright { return upright.sceneSize }
        #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                return MenuVirtualScenePreset.iPad
            }
            // Near-square phone screens (a foldable opened out) get the iPad's 4:3 layout.
            let screen = activeFullscreenContainerSize
            if screen.width > 0, screen.height > 0, screen.width / screen.height < 1.6 {
                return MenuVirtualScenePreset.iPad
            }
            return MenuVirtualScenePreset.widescreen
        #else
            // Test copies can lay out as an iPad does (or a foldable on its side), to check
            // that layout on a Mac.
            if FirstRowHarness.isActive, ["ipad", "duo"].contains(ProcessInfo.processInfo.environment["FIRSTROW_HARNESS_SCENE"] ?? "") {
                return MenuVirtualScenePreset.iPad
            }
            return MenuVirtualScenePreset.widescreen
        #endif
    }
}
