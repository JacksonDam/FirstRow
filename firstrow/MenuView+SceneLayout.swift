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

/// Where the main parts of the menu scene sit, in scene points (origin top left).
struct MenuSceneFrames {
    let sceneSize: CGSize
    let headerTop: CGFloat
    /// The carousel's box (the root carousel, the section's icon and its preview content).
    let carouselFrame: CGRect
    /// The box the menu lists hang from.
    let menuFrame: CGRect

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

    func sceneFrames(sceneSize: CGSize) -> MenuSceneFrames {
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

    func baselineLayoutWidth(sceneSize: CGSize) -> CGFloat {
        min(1920, sceneSize.width)
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

    func submenuHeaderTitleLeadingGlobalX(sceneSize: CGSize) -> CGFloat {
        let titleText: String = if isEnteringSubmenu, !isReturningToRoot {
            rootMenuTitle(for: activeRootItemID)
        } else {
            headerText
        }
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
        RootCarouselConfiguration(
            images: menuItems.map { menuImage(forRootID: $0.id) },
            selectedIndex: selectedIndex,
            isIconAnimated: isIconAnimated,
            isEnteringSubmenu: isEnteringSubmenu,
            isReturningToRoot: isReturningToRoot,
            isInSubmenu: isInSubmenu,
            showsSettledLandedIcon: showsSettledLandedIcon,
            iconSize: iconSize,
            scaleReduction: scaleReduction,
            landedIconScale: landedIconScale,
            selectedSizeMultiplier: selectedCarouselAdjustedSizeMultiplier,
            arcRadius: arcRadius,
            restingOffset: CGPoint(x: restingSelectedHorizontalOffset, y: restingSelectedVerticalOffset),
            landedOffset: CGPoint(x: landedSelectedHorizontalOffset(sceneSize: sceneSize), y: landedSelectedVerticalOffset),
            entryOffset: selectedCarouselEntryOffset,
            sceneWidth: sceneSize.width,
            boxOriginInScene: sceneFrames(sceneSize: sceneSize).carouselFrame.origin,
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
            MenuVirtualScenePreset.widescreen
        #endif
    }
}
