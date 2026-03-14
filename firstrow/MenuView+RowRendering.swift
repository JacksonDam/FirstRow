import SwiftUI

private extension View {
    func arrowGlow(_ glowing: Bool, _ appearance: ArrowAppearance) -> some View {
        shadow(
            color: glowing ? appearance.color.opacity(appearance.glowPrimaryOpacity) : .clear,
            radius: glowing ? appearance.glowPrimaryRadius : 0,
        ).shadow(
            color: glowing ? appearance.color.opacity(appearance.glowSecondaryOpacity) : .clear,
            radius: glowing ? appearance.glowSecondaryRadius : 0,
        )
    }
}

private enum SelectionBoxTextureCache {
    static let triplet: (left: NSImage, middle: NSImage, right: NSImage)? = {
        guard
            let left = NSImage(named: "SelectionEndCapLeft"),
            let middle = NSImage(named: "SelectionMiddle"),
            let right = NSImage(named: "SelectionEndCapRight")
        else {
            return nil
        }
        return (left: left, middle: middle, right: right)
    }()
}

private enum MenuRowRenderingCache {
    static var titleWidthByTitle: [String: CGFloat] = [:]
    static var trailingWidthByTextAndFont: [String: CGFloat] = [:]
    static var imageByAssetName: [String: NSImage] = [:]
}

private struct RootMenuSelectionCenterPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .nan

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next.isFinite {
            value = next
        }
    }
}

enum MenuVirtualScenePreset {
    static let widescreen = CGSize(width: 1920, height: 1080)

    static func scaledX(_ value: CGFloat, for virtualSize: CGSize) -> CGFloat {
        guard widescreen.width > 0 else { return value }
        return value * (virtualSize.width / widescreen.width)
    }

    static func additionalMenuGapX(for virtualSize: CGSize) -> CGFloat {
        _ = virtualSize
        return 0
    }
}

struct MenuVirtualSceneLayout {
    let virtualSize: CGSize
    let scale: CGFloat
    let offset: CGSize
    let fittedSize: CGSize

    init(containerSize: CGSize, virtualSize: CGSize) {
        self.virtualSize = virtualSize

        guard
            containerSize.width > 0,
            containerSize.height > 0,
            virtualSize.width > 0,
            virtualSize.height > 0
        else {
            scale = 1
            offset = .zero
            fittedSize = virtualSize
            return
        }

        scale = min(
            containerSize.width / virtualSize.width,
            containerSize.height / virtualSize.height,
        )
        fittedSize = CGSize(
            width: virtualSize.width * scale,
            height: virtualSize.height * scale,
        )
        offset = CGSize(
            width: (containerSize.width - fittedSize.width) * 0.5,
            height: (containerSize.height - fittedSize.height) * 0.5,
        )
    }
}

private struct RootStagePlacement {
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let zIndex: CGFloat
    let scale: CGFloat
    let baseSizeMultiplier: CGFloat
    let blurRadius: CGFloat
    let opacity: CGFloat
}

private func interpolatedCGFloat(
    from start: CGFloat,
    to end: CGFloat,
    progress: CGFloat,
) -> CGFloat {
    start + ((end - start) * progress)
}

private func unitProgress(_ raw: CGFloat) -> CGFloat {
    min(max(raw, 0), 1)
}

private func smoothStep(_ raw: CGFloat) -> CGFloat {
    let clamped = unitProgress(raw)
    return clamped * clamped * (3 - (2 * clamped))
}

private func projectedRootStagePlacement(
    for index: Int,
    selectionValue: Double,
    itemCount: Int,
    radius: CGFloat,
    tiltDegrees: Double,
    centerYOffset: CGFloat,
    perspectiveDistance: CGFloat,
    baseSizeMultiplier: CGFloat,
) -> RootStagePlacement {
    let visibleCount = max(1, min(itemCount, 4))
    let angleStep = (2.0 * Double.pi) / Double(visibleCount)
    let angle = (Double(index) - selectionValue) * angleStep
    let tiltRadians = tiltDegrees * (.pi / 180)
    let sideBiasProgress = max(0, 1 - abs(CGFloat(cos(angle))))
    let sideHorizontalBias = CGFloat(sin(angle).sign == .minus ? -18 : 18) * sideBiasProgress
    let sideVerticalBias = -60 * sideBiasProgress
    let depth = radius * CGFloat(cos(angle))
    let projectedDepth = depth * CGFloat(cos(tiltRadians))
    let normalizedDepth = projectedDepth / max(1, radius * CGFloat(cos(tiltRadians)))
    let perspectiveScale =
        perspectiveDistance /
        max(1, perspectiveDistance - projectedDepth)
    let opacity = 0.84 + (0.16 * ((normalizedDepth + 1) * 0.5))
    let blurRadius = max(0, -normalizedDepth) * 0.35

    return RootStagePlacement(
        horizontalOffset: (radius * CGFloat(sin(angle))) + sideHorizontalBias,
        verticalOffset: centerYOffset + (depth * CGFloat(sin(tiltRadians))) + sideVerticalBias,
        zIndex: projectedDepth,
        scale: perspectiveScale,
        baseSizeMultiplier: baseSizeMultiplier,
        blurRadius: blurRadius,
        opacity: opacity,
    )
}

private struct RootOrbitModifier: AnimatableModifier {
    let index: Int
    let itemCount: Int
    let radius: CGFloat
    let tiltDegrees: Double
    let centerYOffset: CGFloat
    let perspectiveDistance: CGFloat
    let baseSizeMultiplier: CGFloat
    let isSelectedRootItem: Bool
    let isEnteringSubmenu: Bool
    let isBackground: Bool
    var selectionValue: Double
    var introProgress: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { .init(selectionValue, introProgress) }
        set {
            selectionValue = newValue.first
            introProgress = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let placement = projectedRootStagePlacement(
            for: index,
            selectionValue: selectionValue,
            itemCount: itemCount,
            radius: radius,
            tiltDegrees: tiltDegrees,
            centerYOffset: centerYOffset,
            perspectiveDistance: perspectiveDistance,
            baseSizeMultiplier: baseSizeMultiplier,
        )
        let opacity: CGFloat = isEnteringSubmenu && isBackground ? 0.06 : 1.0
        let scale = placement.scale * (isEnteringSubmenu && isBackground ? 0.82 : 1.0)
        let verticalOffset = placement.verticalOffset + (isEnteringSubmenu && isBackground ? 240 : 0)

        content
            .scaleEffect(scale)
            .opacity(opacity)
            .offset(x: placement.horizontalOffset, y: verticalOffset)
            .blur(radius: placement.blurRadius)
            .zIndex(Double(placement.zIndex))
    }
}

extension MenuView {
    var selectionMovementAnimation: Animation {
        if useLinearSelectionSweepAnimation {
            return .linear(duration: selectionAnimationDuration)
        }
        return .easeInOut(duration: selectionAnimationDuration)
    }

    func baselineLayoutWidth(geometry: GeometryProxy) -> CGFloat {
        min(1920, geometry.size.width)
    }

    @ViewBuilder
    func headerView(geometry: GeometryProxy) -> some View {
        if isInSubmenu, activeRootItemID != nil {
            Text(headerText).font(.firstRowBold(size: 60)).foregroundColor(.white).opacity(submenuTitleOpacity).offset(x: firstRowHeaderOffsetX(geometry: geometry) + (landedIconWidth * 0.6)).offset(y: menuHeaderVerticalOffset).animation(.easeInOut(duration: 0.25), value: submenuTitleOpacity)
        } else {
            Text(headerText).font(.firstRowBold(size: 60)).foregroundColor(.white).offset(x: rootMenuHeaderOffsetX(geometry: geometry)).offset(y: menuHeaderVerticalOffset).opacity(headerOpacity).animation(.easeInOut(duration: 0.25), value: headerOpacity)
        }
    }

    @ViewBuilder
    func movieResumePromptOverlay(geometry: GeometryProxy) -> some View {
        let options = ["Resume Playing", "Start from Beginning"]
        let optionWidth = min(menuWidthConstrained(geometry: geometry) * 0.88, 860)
        let optionHeight = selectionBoxHeight
        let optionSelectionHeightScale = optionHeight / selectionBoxHeight
        let optionVisualWidth =
            optionWidth +
            selectionTextureVisualWidthDelta +
            movieResumeSelectionTextureLeadingAdjustment +
            movieResumeSelectionTextureTrailingAdjustment
        let optionVisualHeight = optionHeight + (selectionTextureVisualHeightDelta * optionSelectionHeightScale)
        let optionVisualXOffset =
            -((optionVisualWidth - optionWidth) * 0.5) +
            ((movieResumeSelectionTextureTrailingAdjustment - movieResumeSelectionTextureLeadingAdjustment) * 0.5)
        let optionVisualYOffset = -((optionVisualHeight - optionHeight) * 0.5)
        let optionPressedBlackLeftInset: CGFloat = 12
        let optionPressedBlackWidth = max(0, optionWidth - optionPressedBlackLeftInset)
        let optionTextInset: CGFloat = 32
        let optionRowSpacing: CGFloat = 10
        let optionRowPitch = optionHeight + optionRowSpacing
        let selectedRowOffset = CGFloat(movieResumePromptSelectedIndex) * optionRowPitch
        ZStack {
            if let backdrop = movieResumePromptBackdropImage {
                Image(nsImage: backdrop).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped().blur(radius: 28).saturation(0.92)
            } else {
                Color.black
            }
            Color.black.opacity(0.33)
            ZStack(alignment: .topLeading) {
                if movieResumePromptSolidBlackSelected {
                    RoundedRectangle(cornerRadius: 5).fill(Color.black).frame(width: optionPressedBlackWidth, height: optionHeight).offset(x: optionPressedBlackLeftInset, y: selectedRowOffset).animation(.easeInOut(duration: movieResumePromptSelectionSlideDuration), value: movieResumePromptSelectedIndex)
                } else {
                    selectionBox(width: optionVisualWidth, height: optionVisualHeight).offset(x: optionVisualXOffset, y: selectedRowOffset + optionVisualYOffset).animation(.easeInOut(duration: movieResumePromptSelectionSlideDuration), value: movieResumePromptSelectedIndex)
                }
                LazyVStack(spacing: optionRowSpacing) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        let isSelected = (index == movieResumePromptSelectedIndex)
                        let hideSelectedText = movieResumePromptSolidBlackSelected && isSelected
                        let hideUnselectedText = movieResumePromptHideUnselected && !isSelected
                        Text(option).font(.firstRowBold(size: 45)).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.72).allowsTightening(true).frame(width: optionWidth, height: optionHeight, alignment: .leading).padding(.leading, optionTextInset).opacity((hideSelectedText || hideUnselectedText) ? 0 : 1)
                    }
                }
            }.frame(
                width: optionWidth,
                height: (optionHeight * 2) + optionRowSpacing,
                alignment: .topLeading,
            ).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }.ignoresSafeArea()
    }

    func rightMenuArea(geometry: GeometryProxy) -> some View {
        let rootMenuItems = rootListItems()
        let submenuItems = submenuListItems()
        let thirdMenuItems = thirdMenuListItems()
        let rootMenuVisibleRowCount = min(defaultVisibleMenuRowCount, max(1, rootMenuItems.count))
        let isPhotosSubmenu = activeRootItemID == "photos"
        return ZStack(alignment: .topLeading) {
            menuListContainer(
                items: rootMenuItems,
                selectedIndex: selectedIndex,
                geometry: geometry,
                arrowAppearance: menuArrowAppearance,
                showsTopOverflowFade: true,
                visibleRowCount: rootMenuVisibleRowCount,
                selectionBoxWidthScale: 1.0,
                selectionBoxHeightScale: 1.0,
                reportsSelectionCenterX: true,
            ).opacity(rootMenuOpacity)
            if isInSubmenu || isEnteringSubmenu || submenuOpacity > 0.001 {
                menuListContainer(
                    items: submenuItems,
                    selectedIndex: min(selectedSubIndex, max(0, submenuItems.count - 1)),
                    geometry: geometry,
                    arrowAppearance: menuArrowAppearance,
                    showsTopOverflowFade: true,
                    visibleRowCount: defaultVisibleMenuRowCount,
                    selectionBoxWidthScale: isPhotosSubmenu ? photosSelectionBoxWidthScale : 1.0,
                    selectionBoxHeightScale: isPhotosSubmenu ? photosSelectionBoxHeightScale : 1.0,
                ).opacity(submenuOpacity)
            }
            if isInThirdMenu || thirdMenuOpacity > 0.001 {
                let isPhotosThirdMenu = activeRootItemID == "photos" && thirdMenuMode == .photosDateAlbums
                menuListContainer(
                    items: thirdMenuItems,
                    selectedIndex: min(selectedThirdIndex, max(0, thirdMenuItems.count - 1)),
                    geometry: geometry,
                    arrowAppearance: menuArrowAppearance,
                    showsTopOverflowFade: true,
                    visibleRowCount: thirdLevelVisibleMenuRowCount,
                    selectionBoxWidthScale: isPhotosThirdMenu ? photosSelectionBoxWidthScale : 1.0,
                    selectionBoxHeightScale: isPhotosThirdMenu ? photosSelectionBoxHeightScale : 1.0,
                ).opacity(thirdMenuOpacity)
            }
        }.frame(height: stableMenuListLayoutHeight, alignment: .top)
    }

    func menuListContainer(
        items: [MenuListItemConfig],
        selectedIndex: Int,
        geometry: GeometryProxy,
        arrowAppearance: ArrowAppearance,
        showsTopOverflowFade: Bool,
        visibleRowCount: Int,
        selectionBoxWidthScale: CGFloat = 1.0,
        selectionBoxHeightScale: CGFloat = 1.0,
        reportsSelectionCenterX: Bool = false,
    ) -> some View {
        let menuWidth = menuWidthConstrained(geometry: geometry)
        let selectionWidth = menuWidth * selectionBoxWidthScale
        let selectionHeight = selectionBoxHeight * selectionBoxHeightScale
        let usesLargeSelectionTextureSizing =
            (selectionBoxWidthScale > 1.001) || (selectionBoxHeightScale > 1.001)
        let selectionTextureLeadingAdjustment = usesLargeSelectionTextureSizing
            ? photosSelectionTextureLeadingAdjustment
            : 0
        let selectionTextureTrailingAdjustment = usesLargeSelectionTextureSizing
            ? photosSelectionTextureTrailingAdjustment
            : 0
        let selectionTextureHeightAdjustment = usesLargeSelectionTextureSizing
            ? photosSelectionTextureHeightAdjustment
            : 0
        let selectionVisualWidth =
            selectionWidth +
            (selectionTextureVisualWidthDelta * selectionBoxWidthScale) +
            selectionTextureLeadingAdjustment +
            selectionTextureTrailingAdjustment
        let selectionVisualHeight =
            selectionHeight +
            (selectionTextureVisualHeightDelta * selectionBoxHeightScale) +
            selectionTextureHeightAdjustment
        let selectionXOffset = -((selectionWidth - menuWidth) * 0.5)
        let selectionYOffset = -((selectionHeight - selectionBoxHeight) * 0.5)
        let selectionVisualXOffset =
            selectionXOffset -
            ((selectionVisualWidth - selectionWidth) * 0.5) +
            ((selectionTextureTrailingAdjustment - selectionTextureLeadingAdjustment) * 0.5)
        let selectionVisualYOffset =
            selectionYOffset -
            ((selectionVisualHeight - selectionHeight) * 0.5)
        let rowContentWidth = selectionWidth
        let rowContentXOffset = selectionXOffset
        let rowLeadingCompensation = max(0, -rowContentXOffset)
        let dividerGap = effectiveDividerSectionGap(forSelectionBoxHeightScale: selectionBoxHeightScale)
        let rowPitch = effectiveRowPitch(forSelectionBoxHeightScale: selectionBoxHeightScale)
        let normalHeightIndices: Set<Int> = selectionBoxHeightScale > 1.001
            ? Set(items.indices.filter { items[$0].alignsTextToDividerStart })
            : []
        let rowOffsets = menuRowOffsets(for: items, dividerGap: dividerGap, rowPitch: rowPitch, normalHeightIndices: normalHeightIndices)
        let contentHeight = menuContentHeight(
            for: items,
            rowOffsets: rowOffsets,
            rowHeight: selectionHeight,
        )
        let viewportHeight = menuViewportHeight(for: visibleRowCount)
        let scrollOffset = menuScrollOffset(
            contentHeight: contentHeight,
            selectedIndex: selectedIndex,
            rowOffsets: rowOffsets,
            viewportHeight: viewportHeight,
        )
        let selectedRowOffset = rowOffsets.indices.contains(selectedIndex) ? rowOffsets[selectedIndex] : 0
        let selectedIsNormalHeight = normalHeightIndices.contains(selectedIndex)
        let shouldUseCompactPhotosSelectionWidth =
            selectedIsNormalHeight &&
            selectionBoxHeightScale > 1.001 &&
            selectionVisualWidth > menuWidth
        let compactSelectionWidthReduction = shouldUseCompactPhotosSelectionWidth
            ? min(photosCompactSelectionVisualWidthReduction, selectionVisualWidth - menuWidth)
            : 0
        let effectiveSelectionVisualWidth = selectionVisualWidth - compactSelectionWidthReduction
        let effectiveSelectionVisualXOffset = selectionVisualXOffset + (compactSelectionWidthReduction * 0.5)
        let effectiveSelectionVisualHeight = selectedIsNormalHeight
            ? selectionBoxHeight + selectionTextureVisualHeightDelta
            : selectionVisualHeight
        let effectiveSelectionVisualYOffset = selectedIsNormalHeight
            ? -(selectionTextureVisualHeightDelta * 0.5)
            : selectionVisualYOffset
        let selectionVisualCenterXInContainer =
            effectiveSelectionVisualXOffset + (effectiveSelectionVisualWidth * 0.5)
        let visibleRowIndices = visibleMenuRowIndices(
            rowOffsets: rowOffsets,
            rowHeight: selectionHeight,
            scrollOffset: scrollOffset,
            viewportHeight: viewportHeight,
            prefersWiderOverscan: !isSelectionSettled,
        )
        return ZStack(alignment: .topLeading) {
            if !items.isEmpty {
                selectionBox(width: effectiveSelectionVisualWidth, height: effectiveSelectionVisualHeight).offset(
                    x: effectiveSelectionVisualXOffset,
                    y: selectedRowOffset + scrollOffset + effectiveSelectionVisualYOffset,
                ).animation(selectionMovementAnimation, value: selectedIndex)
            }
            ZStack(alignment: .topLeading) {
                ForEach(visibleRowIndices, id: \.self) { index in
                    let item = items[index]
                    let rowIsSelected = index == selectedIndex
                    let rowIsNormalHeight = normalHeightIndices.contains(index)
                    let rowHeight = rowIsNormalHeight ? selectionBoxHeight : selectionHeight
                    let rowYOffset = rowIsNormalHeight ? 0 : selectionYOffset
                    if item.showsTopDivider {
                        Rectangle().fill(Color.white.opacity(0.34)).frame(width: max(0, rowContentWidth - (dividerLineInsetHorizontal * 2)), height: 1).offset(
                            x: rowContentXOffset + dividerLineInsetHorizontal,
                            y: rowOffsets[index] - dividerGap + dividerLineYOffsetInGap,
                        )
                    }
                    if item.showsLightRowBackground {
                        Rectangle().fill(Color.white.opacity(0.06)).overlay(
                            Rectangle().stroke(Color.white.opacity(0.02), lineWidth: 1),
                        ).frame(
                            width: selectionWidth,
                            height: rowHeight,
                        ).offset(
                            x: selectionXOffset,
                            y: rowOffsets[index] + rowYOffset,
                        )
                    }
                    menuItemView(
                        itemID: item.id,
                        title: item.title,
                        isSelected: rowIsSelected,
                        rowWidth: rowContentWidth,
                        leadingCompensation: rowLeadingCompensation,
                        showsArrow: item.leadsToMenu,
                        leadingImageAssetName: item.leadingImageAssetName,
                        leadingImage: item.leadingImage,
                        trailingText: item.trailingText,
                        trailingSymbolName: item.trailingSymbolName,
                        showsPlaybackSpeaker:
                        thirdMenuMode == .musicSongs &&
                            activeMusicPlaybackSongID == item.id &&
                            hasActiveMusicPlaybackSession(),
                        showsBlueDot: item.showsBlueDot,
                        alignsTextToDividerStart: item.alignsTextToDividerStart,
                        arrowAppearance: arrowAppearance,
                    ).frame(width: rowContentWidth, height: rowHeight, alignment: .leading).offset(
                        x: rowContentXOffset,
                        y: rowOffsets[index] + rowYOffset,
                    )
                }
            }.offset(y: scrollOffset).animation(selectionMovementAnimation, value: selectedIndex).frame(height: viewportHeight, alignment: .top).mask(
                Rectangle().frame(width: 5000, height: viewportHeight),
            )
        }.frame(height: viewportHeight, alignment: .top).overlay(Group {
            if showsTopOverflowFade {
                LinearGradient(
                    colors: [.black, .black.opacity(0.78), .clear],
                    startPoint: .top,
                    endPoint: .bottom,
                ).frame(height: submenuTopFadeHeight).opacity(isMenuOverflowScrollingUp ? 1 : 0).animation(.easeInOut(duration: 0.12), value: isMenuOverflowScrollingUp).allowsHitTesting(false)
            }
        }, alignment: .top).overlay(Group {
            if showsTopOverflowFade {
                LinearGradient(
                    colors: [.black, .black.opacity(0.78), .clear],
                    startPoint: .bottom,
                    endPoint: .top,
                ).frame(height: submenuTopFadeHeight).opacity(isMenuOverflowScrollingDown ? 1 : 0).animation(.easeInOut(duration: 0.12), value: isMenuOverflowScrollingDown).allowsHitTesting(false)
            }
        }, alignment: .bottom).frame(width: menuWidth, height: menuListLayoutHeight(for: visibleRowCount), alignment: .topLeading).background(
            Group {
                if reportsSelectionCenterX {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: RootMenuSelectionCenterPreferenceKey.self,
                            value: proxy.frame(in: .named("menuSceneSpace")).minX + selectionVisualCenterXInContainer,
                        )
                    }
                } else {
                    Color.clear
                }
            },
        )
    }

    @ViewBuilder
    func selectionBox(
        width: CGFloat,
        height: CGFloat,
    ) -> some View {
        if let textures = SelectionBoxTextureCache.triplet {
            let sourceCapWidth: CGFloat = 50
            let sourceHeight: CGFloat = 97
            let textureHeight = height * (sourceHeight / selectionBoxHeight)
            let capWidthRatio = sourceCapWidth / sourceHeight
            let capWidth = min(textureHeight * capWidthRatio, width * 0.5)
            let middleWidth = max(0, width - (capWidth * 2))
            ZStack {
                HStack(spacing: 0) {
                    Image(nsImage: textures.left).resizable().frame(width: capWidth, height: textureHeight)
                    Image(nsImage: textures.middle).resizable(resizingMode: .stretch).frame(width: middleWidth, height: textureHeight)
                    Image(nsImage: textures.right).resizable().frame(width: capWidth, height: textureHeight)
                }.frame(width: width, height: textureHeight)
            }.drawingGroup().frame(width: width, height: height)
        } else {
            EmptyView()
        }
    }

    // MARK: - Layout geometry

    func visibleIndices() -> [Int] {
        let visibleCount = min(menuItems.count, 4)
        let indices = Array(0 ..< visibleCount).map { offset in
            (selectedIndex + offset + menuItems.count) % menuItems.count
        }
        return indices.reversed()
    }

    func carouselWidth(geometry: GeometryProxy) -> CGFloat {
        min(1240, baselineLayoutWidth(geometry: geometry) * 0.62)
    }

    func carouselOffsetY() -> CGFloat {
        48
    }

    func landedSelectedHorizontalOffset(geometry _: GeometryProxy) -> CGFloat {
        let font = NSFont(name: firstRowBoldFontName, size: 88)
            ?? NSFont.boldSystemFont(ofSize: 88)
        let titleText: String = {
            if isEnteringSubmenu, !isReturningToRoot {
                return rootMenuTitle(for: activeRootItemID)
            }
            return headerText
        }()
        let titleWidth = ceil((titleText as NSString).size(withAttributes: [.font: font]).width)
        let iconWidth: CGFloat = 92
        let spacing: CGFloat = 20
        let totalWidth = iconWidth + spacing + titleWidth
        return -(totalWidth * 0.5) + (iconWidth * 0.5)
    }

    func submenuHeaderTitleLeadingGlobalX(geometry: GeometryProxy) -> CGFloat {
        let font = NSFont(name: firstRowBoldFontName, size: 60)
            ?? NSFont.boldSystemFont(ofSize: 60)
        let titleText: String = {
            if isEnteringSubmenu, !isReturningToRoot {
                return rootMenuTitle(for: activeRootItemID)
            }
            return headerText
        }()
        let titleWidth = (titleText as NSString).size(withAttributes: [.font: font]).width
        let titleCenterX = firstRowHeaderOffsetX(geometry: geometry) + (landedIconWidth * 0.6)
        return titleCenterX - (titleWidth * 0.5)
    }

    func firstRowHeaderOffsetX(geometry: GeometryProxy) -> CGFloat {
        rootMenuHeaderOffsetX(geometry: geometry)
    }

    func rootMenuHeaderOffsetX(geometry: GeometryProxy) -> CGFloat {
        if let rootMenuSelectionCenterSceneX {
            return rootMenuSelectionCenterSceneX - (geometry.size.width * 0.5)
        }

        let sceneWidth = geometry.size.width
        let menuWidth = menuWidthConstrained(geometry: geometry)
        let carouselLaneWidth = carouselWidth(geometry: geometry)
        let spacerWidth = max(0, sceneWidth - carouselLaneWidth - menuWidth)
        let rightMenuCenterX =
            (-sceneWidth * 0.5) +
            carouselLaneWidth +
            spacerWidth +
            (menuWidth * 0.5)
        return rightMenuCenterX + rightMenuSceneOffsetX
    }

    func settledLandedIconView(image: NSImage, geometry: GeometryProxy) -> some View {
        let adjustedIconSize: CGFloat = iconSize * selectedCarouselAdjustedSizeMultiplier
        return Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: adjustedIconSize, height: adjustedIconSize).scaleEffect(landedIconScale).offset(
            x: landedSelectedHorizontalOffset(geometry: geometry),
            y: landedSelectedVerticalOffset,
        ).padding(.bottom, 100).zIndex(1200).transaction { transaction in
            transaction.disablesAnimations = true
        }
    }

    func menuWidthConstrained(geometry: GeometryProxy) -> CGFloat {
        min(1080, baselineLayoutWidth(geometry: geometry) * 0.52)
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
        let overscanMultiplier: CGFloat = prefersWiderOverscan ? 4.0 : 2.0
        let overscanPadding = max(80, rowHeight * overscanMultiplier)
        let minVisibleY = -scrollOffset - overscanPadding
        let maxVisibleY = -scrollOffset + viewportHeight + overscanPadding
        return rowOffsets.enumerated().compactMap { index, rowOffset in
            let rowMinY = rowOffset
            let rowMaxY = rowOffset + rowHeight
            if rowMaxY < minVisibleY || rowMinY > maxVisibleY {
                return nil
            }
            return index
        }
    }

    func menuTrailingPadding(geometry: GeometryProxy) -> CGFloat {
        max(0, baselineLayoutWidth(geometry: geometry) * 0.05)
    }

    // MARK: - Carousel item views

    var activeRootCarouselRadius: CGFloat {
        let startRadius = isRootExitRunning
            ? rootExitEndCarouselRadius
            : rootIntroStartCarouselRadius
        return interpolatedValue(
            from: startRadius,
            to: rootCarouselRadius,
            progress: unitProgress(introProgress),
        )
    }

    private func rootStagePlacement(for index: Int) -> RootStagePlacement {
        projectedRootStagePlacement(
            for: index,
            selectionValue: rootCarouselSelectionValue,
            itemCount: menuItems.count,
            radius: activeRootCarouselRadius,
            tiltDegrees: rootCarouselTiltDegrees,
            centerYOffset: rootCarouselCenterYOffset,
            perspectiveDistance: rootCarouselPerspectiveDistance,
            baseSizeMultiplier: rootCarouselBaseSizeMultiplier,
        )
    }

    func interpolatedValue(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat,
    ) -> CGFloat {
        start + ((end - start) * progress)
    }

    func carouselItemView(for index: Int, geometry: GeometryProxy) -> some View {
        let placement = rootStagePlacement(for: index)
        let isSelectedRootItem = index == selectedIndex
        let isBackground = !isSelectedRootItem
        let adjustedIconSize = iconSize * placement.baseSizeMultiplier
        let isIncoming = false
        let entryOffset = selectedCarouselEntryOffset
        let reflectionYOffsetOverride: CGFloat = menuItems[index].id == "movies" ? 18 : 0
        let reflectionCompensationX =
            (isSelectedRootItem && (isIconAnimated || isEnteringSubmenu))
                ? (placement.horizontalOffset - restingSelectedHorizontalOffset)
                : 0
        let reflectionCompensationY =
            (isSelectedRootItem && (isIconAnimated || isEnteringSubmenu))
                ? (placement.verticalOffset - restingSelectedVerticalOffset)
                : 0
        return Group {
            if let image = menuImage(forRootID: menuItems[index].id) {
                if isSelectedRootItem, isIconAnimated {
                    standardCarouselIconView(
                        image: image,
                        adjustedIconSize: adjustedIconSize,
                        scale: landedIconScale,
                        opacity: 1,
                        horizontalOffset: landedSelectedHorizontalOffset(geometry: geometry),
                        verticalOffset: landedSelectedVerticalOffset,
                        isIncoming: false,
                        entryOffset: entryOffset,
                        zInd: 1000,
                        isBackground: false,
                        backgroundBlur: 0,
                        showReflection: !(isSelectedRootItem && isInSubmenu && !isEnteringSubmenu && !isReturningToRoot),
                        animateReflection: isSelectedRootItem && (!isInSubmenu || isEnteringSubmenu || isReturningToRoot),
                        reflectionYOffsetOverride: reflectionYOffsetOverride,
                        reflectionCompensationX: reflectionCompensationX,
                        reflectionCompensationY: reflectionCompensationY,
                    )
                } else {
                    standardCarouselIconView(
                        image: image,
                        adjustedIconSize: adjustedIconSize,
                        scale: 1,
                        opacity: 1,
                        horizontalOffset: 0,
                        verticalOffset: 0,
                        isIncoming: isIncoming,
                        entryOffset: entryOffset,
                        zInd: 0,
                        isBackground: isBackground,
                        backgroundBlur: 0,
                        showReflection: !(isSelectedRootItem && isInSubmenu && !isEnteringSubmenu && !isReturningToRoot),
                        animateReflection: isSelectedRootItem && (!isInSubmenu || isEnteringSubmenu || isReturningToRoot),
                        reflectionYOffsetOverride: reflectionYOffsetOverride,
                        reflectionCompensationX: reflectionCompensationX,
                        reflectionCompensationY: reflectionCompensationY,
                    )
                    .modifier(
                        RootOrbitModifier(
                            index: index,
                            itemCount: menuItems.count,
                            radius: activeRootCarouselRadius,
                            tiltDegrees: rootCarouselTiltDegrees,
                            centerYOffset: rootCarouselCenterYOffset,
                            perspectiveDistance: rootCarouselPerspectiveDistance,
                            baseSizeMultiplier: rootCarouselBaseSizeMultiplier,
                            isSelectedRootItem: isSelectedRootItem,
                            isEnteringSubmenu: isEnteringSubmenu,
                            isBackground: isBackground,
                            selectionValue: rootCarouselSelectionValue,
                            introProgress: Double(introProgress),
                        ),
                    )
                }
            }
        }.padding(.bottom, 100)
    }

    func rootIntroStageScaleCompensation() -> CGFloat {
        guard isRootIntroRunning else { return 1 }
        let currentPlacement = projectedRootStagePlacement(
            for: selectedIndex,
            selectionValue: rootCarouselSelectionValue,
            itemCount: menuItems.count,
            radius: activeRootCarouselRadius,
            tiltDegrees: rootCarouselTiltDegrees,
            centerYOffset: rootCarouselCenterYOffset,
            perspectiveDistance: rootCarouselPerspectiveDistance,
            baseSizeMultiplier: rootCarouselBaseSizeMultiplier,
        )
        let finalPlacement = projectedRootStagePlacement(
            for: selectedIndex,
            selectionValue: Double(selectedIndex),
            itemCount: menuItems.count,
            radius: rootCarouselRadius,
            tiltDegrees: rootCarouselTiltDegrees,
            centerYOffset: rootCarouselCenterYOffset,
            perspectiveDistance: rootCarouselPerspectiveDistance,
            baseSizeMultiplier: rootCarouselBaseSizeMultiplier,
        )
        return max(1, finalPlacement.scale / max(0.001, currentPlacement.scale))
    }

    func standardCarouselIconView(
        image: NSImage,
        adjustedIconSize: CGFloat,
        scale: CGFloat,
        opacity: CGFloat,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat,
        isIncoming: Bool,
        entryOffset: CGFloat,
        zInd: CGFloat,
        isBackground: Bool,
        backgroundBlur: CGFloat = 0,
        showReflection: Bool = true,
        animateReflection: Bool = false,
        reflectionYOffsetOverride: CGFloat = 0,
        reflectionCompensationX: CGFloat = 0,
        reflectionCompensationY: CGFloat = 0,
    ) -> some View {
        let baseX = horizontalOffset + (isIncoming ? -entryOffset : 0)
        let baseY = verticalOffset + (isIncoming ? entryOffset : 0)
        let usesDetachedReflection = animateReflection &&
            ((isEnteringSubmenu && !isReturningToRoot) || (isReturningToRoot && isIconAnimated))
        let reflectionYOffsetAdjustment: CGFloat = -38
        let reflectionX = usesDetachedReflection ? 90.0 : 0.0
        let reflectionY =
            (usesDetachedReflection ? 920.0 : (adjustedIconSize * (scale - 1))) +
            reflectionYOffsetAdjustment +
            reflectionYOffsetOverride
        let reflectionOpacity = usesDetachedReflection ? 0.22 : 0.34
        let reflectionBlur = usesDetachedReflection ? 3.0 : 0.0
        let backgroundIconTransitionDuration =
            isReturningToRoot
                ? submenuBackgroundIconReturnDuration
                : submenuBackgroundIconTransitionDuration
        return ZStack {
            if showReflection {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: adjustedIconSize, height: adjustedIconSize).mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white, location: 0.0),
                            .init(color: .white, location: 0.9),
                            .init(color: .clear, location: 1.0),
                        ]),
                        startPoint: .bottom,
                        endPoint: .top,
                    ),
                ).scaleEffect(x: 1.0, y: -1.0, anchor: .bottom).opacity(reflectionOpacity).offset(
                    x: reflectionX - (usesDetachedReflection ? reflectionCompensationX : 0),
                    y: reflectionY - (usesDetachedReflection ? reflectionCompensationY : 0),
                ).blur(radius: reflectionBlur).scaleEffect(usesDetachedReflection ? 1.0 : scale)
            }
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: adjustedIconSize, height: adjustedIconSize).scaleEffect(scale)
        }.opacity(opacity).offset(x: baseX, y: baseY).zIndex(isIncoming ? 1 : zInd).blur(radius: backgroundBlur).animation(.easeInOut(duration: backgroundIconTransitionDuration), value: isEnteringSubmenu && isBackground).animation(.easeInOut(duration: iconFlightAnimationDuration), value: isIconAnimated)
    }

    // MARK: - Menu item row view

    func menuItemView(
        itemID: String,
        title: String,
        isSelected: Bool,
        rowWidth: CGFloat,
        leadingCompensation: CGFloat,
        showsArrow: Bool,
        leadingImageAssetName: String?,
        leadingImage: NSImage?,
        trailingText: String?,
        trailingSymbolName: String?,
        showsPlaybackSpeaker: Bool,
        showsBlueDot: Bool,
        alignsTextToDividerStart: Bool,
        arrowAppearance: ArrowAppearance,
    ) -> some View {
        let isArrowGlowing = showsArrow && isSelected && isSelectionSettled
        let isTrailingSymbolGlowing = trailingSymbolName != nil && isSelected && isSelectionSettled
        let isPlaybackSpeakerGlowing = showsPlaybackSpeaker && isSelected && isSelectionSettled
        let trailingTextOpacity: Double = (isSelected && isSelectionSettled) ? 1.0 : 0.5
        let hasLeadingImage = (leadingImage != nil) || (leadingImageAssetName != nil)
        let isPhotoAlbumRow = activeRootItemID == "photos" && hasLeadingImage
        let rowHorizontalPadding: CGFloat = isPhotoAlbumRow ? 9 : 20
        let rowInnerWidth = max(0, rowWidth - (rowHorizontalPadding * 2))
        let textLeadingInset = 14 + (hasLeadingImage ? 0 : leadingCompensation)
        let textStartX = rowHorizontalPadding + textLeadingInset
        let resolvedTrailingText = trailingText == "..." ? "•••" : trailingText
        let isDotTrail = resolvedTrailingText == "•••"
        let dynamicPhotosLeadingImage = (activeRootItemID == "photos" && isInThirdMenu && thirdMenuMode == .photosDateAlbums)
            ? photosAlbumCoverImageCache[itemID]
            : nil
        let resolvedLeadingImage =
            dynamicPhotosLeadingImage ??
            leadingImage ??
            leadingImageAssetName.flatMap { cachedMenuRowLeadingImage(named: $0) }
        let isSharedPhotosDotsRow =
            activeRootItemID == "photos" &&
            !isInThirdMenu &&
            showsArrow &&
            isDotTrail &&
            title == "Shared Photos"
        let effectiveArrowXOffset = isSharedPhotosDotsRow ? -10 : arrowAppearance.xOffset
        let trailingFontSize: CGFloat = isDotTrail ? 22 : 42
        let trailingVerticalOffset: CGFloat = isDotTrail ? -0.6 : 0
        let trailingToArrowSpacing: CGFloat = isDotTrail ? -0.2 : 6
        let trailingMeasuredTextWidth: CGFloat = {
            guard let resolvedTrailingText, !isDotTrail else { return 0 }
            return measuredMenuRowTrailingTextWidth(
                resolvedTrailingText,
                fontSize: trailingFontSize,
            )
        }()
        let trailingColumnWidth: CGFloat = {
            if showsPlaybackSpeaker {
                return 132
            }
            if trailingSymbolName != nil {
                return 132
            }
            if resolvedTrailingText != nil, showsArrow {
                if isDotTrail {
                    return 112
                }
                let arrowWidth = max(22, arrowAppearance.fontSize * 0.9)
                let padding: CGFloat = 24
                let spacing = max(0, trailingToArrowSpacing)
                let combined = trailingMeasuredTextWidth + arrowWidth + spacing + padding
                return max(132, min(220, combined))
            }
            if resolvedTrailingText != nil {
                let padding: CGFloat = 18
                let maxColumnWidth = min(360, rowInnerWidth * 0.7)
                return max(94, min(maxColumnWidth, trailingMeasuredTextWidth + padding))
            }
            if showsArrow {
                return 132
            }
            return 0
        }()
        let showsTrailingColumn =
            showsPlaybackSpeaker ||
            trailingSymbolName != nil ||
            resolvedTrailingText != nil ||
            showsArrow
        let leftColumnWidth = max(0, rowInnerWidth - (showsTrailingColumn ? trailingColumnWidth : 0))
        let leadingTextPadding: CGFloat = {
            if hasLeadingImage {
                if isPhotoAlbumRow {
                    return 0
                }
                return 14
            }
            if alignsTextToDividerStart {
                return max(0, dividerLineInsetHorizontal - rowHorizontalPadding)
            }
            return 14 + leadingCompensation
        }()
        let desiredArrowEdgeInset = rowHorizontalPadding + leadingTextPadding
        let currentArrowEdgeInset = rowHorizontalPadding + max(0, -effectiveArrowXOffset)
        let arrowEdgeCompensation = max(0, desiredArrowEdgeInset - currentArrowEdgeInset)
        let symmetricArrowXOffset = effectiveArrowXOffset - arrowEdgeCompensation
        let shouldUseAppleTVWordmarkStyle = leadingImage == nil && leadingImageAssetName == "appleTVNameImage"
        let leadingImageDimension: CGFloat = {
            guard hasLeadingImage else { return 0 }
            if shouldUseAppleTVWordmarkStyle {
                return 96
            }
            return isPhotoAlbumRow ? 72 : 52
        }()
        let leadingToTitleSpacing: CGFloat = hasLeadingImage ? (isPhotoAlbumRow ? 12 : 14) : 0
        let titleAvailableWidth = max(
            1,
            leftColumnWidth - leadingTextPadding - leadingImageDimension - leadingToTitleSpacing,
        )
        let titleMeasuredWidth = measuredMenuRowTitleWidth(title)
        let marqueeCharacterThreshold = 30
        let normalizedTitleLength = title.trimmingCharacters(in: .whitespacesAndNewlines).count
        let effectiveTitleAvailableWidth = max(1, titleAvailableWidth - (showsPlaybackSpeaker ? 28 : 0))
        let shouldScrollTitle =
            isSelected &&
            isSelectionSettled &&
            normalizedTitleLength > marqueeCharacterThreshold &&
            titleMeasuredWidth > effectiveTitleAvailableWidth + 1
        return HStack(spacing: 0) {
            HStack(spacing: hasLeadingImage ? leadingToTitleSpacing : 0) {
                if let resolvedLeadingImage {
                    if shouldUseAppleTVWordmarkStyle {
                        Image(nsImage: resolvedLeadingImage).resizable().aspectRatio(contentMode: .fit).frame(width: 96, height: 52).shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 1)
                    } else {
                        Image(nsImage: resolvedLeadingImage).resizable().aspectRatio(contentMode: .fill).frame(width: leadingImageDimension, height: leadingImageDimension).clipped().shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 1)
                    }
                }
                menuRowTitleView(
                    title: title,
                    availableWidth: titleAvailableWidth,
                    shouldScroll: shouldScrollTitle,
                )
            }.frame(width: leftColumnWidth > 0 ? leftColumnWidth : nil, alignment: .leading).padding(.leading, leadingTextPadding)
            if showsPlaybackSpeaker {
                Image(systemName: "speaker.wave.3.fill").foregroundColor(.white).font(.system(size: 42, weight: .semibold)).shadow(
                    color: isPlaybackSpeakerGlowing ? .white.opacity(0.9) : .clear,
                    radius: isPlaybackSpeakerGlowing ? 4.5 : 0,
                ).shadow(
                    color: isPlaybackSpeakerGlowing ? .white.opacity(0.45) : .clear,
                    radius: isPlaybackSpeakerGlowing ? 10 : 0,
                ).frame(width: trailingColumnWidth, alignment: .trailing).offset(x: arrowAppearance.xOffset)
            } else if let trailingSymbolName {
                Image(systemName: trailingSymbolName).foregroundColor(.white).font(.system(size: 42, weight: .semibold)).opacity(trailingTextOpacity).arrowGlow(isTrailingSymbolGlowing, arrowAppearance).frame(width: trailingColumnWidth, alignment: .trailing).offset(x: arrowAppearance.xOffset)
            } else if let resolvedTrailingText, showsArrow {
                HStack(spacing: trailingToArrowSpacing) {
                    if isDotTrail {
                        LazyHStack(spacing: 1.3) {
                            ForEach(0 ..< 3, id: \.self) { _ in
                                Capsule(style: .continuous).fill(Color.white).frame(width: 6.2, height: 4.1)
                            }
                        }.opacity(trailingTextOpacity).offset(x: 8, y: -0.3).arrowGlow(isArrowGlowing, arrowAppearance)
                    } else {
                        Text(resolvedTrailingText).font(.firstRowRegular(size: trailingFontSize)).foregroundColor(.white).opacity(trailingTextOpacity).lineLimit(1).minimumScaleFactor(0.65).allowsTightening(true).offset(y: trailingVerticalOffset)
                    }
                    Image(systemName: arrowAppearance.symbolName).foregroundColor(arrowAppearance.color).font(.system(size: arrowAppearance.fontSize, weight: arrowAppearance.fontWeight)).opacity(trailingTextOpacity).arrowGlow(isArrowGlowing, arrowAppearance)
                }.frame(width: trailingColumnWidth, alignment: .trailing).offset(x: symmetricArrowXOffset)
            } else if let resolvedTrailingText {
                Text(resolvedTrailingText).font(.firstRowRegular(size: 42)).foregroundColor(.white).opacity(trailingTextOpacity).lineLimit(1).minimumScaleFactor(0.65).allowsTightening(true).frame(width: trailingColumnWidth, alignment: .trailing).offset(x: arrowAppearance.xOffset)
            } else if showsArrow {
                Image(systemName: arrowAppearance.symbolName).foregroundColor(arrowAppearance.color).font(.system(size: arrowAppearance.fontSize, weight: arrowAppearance.fontWeight)).opacity(trailingTextOpacity).arrowGlow(isArrowGlowing, arrowAppearance).frame(width: trailingColumnWidth, alignment: .trailing).offset(x: symmetricArrowXOffset)
            }
        }.frame(width: rowInnerWidth, alignment: .leading).padding(.horizontal, rowHorizontalPadding).overlay(Group {
            if showsBlueDot {
                let dotDiameter: CGFloat = 16.5
                let dotRadius = dotDiameter * 0.5
                let dotCenterX = max(dotRadius + 1, textStartX * 0.5)
                Circle().fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.56, green: 0.83, blue: 1.0),
                            Color(red: 0.08, green: 0.33, blue: 0.76),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing,
                    ),
                ).frame(width: dotDiameter, height: dotDiameter).shadow(
                    color: Color(red: 0.14, green: 0.48, blue: 0.94).opacity(0.55),
                    radius: 2.2,
                    x: 0,
                    y: 0,
                ).offset(x: dotCenterX - 6)
            }
        }, alignment: .leading)
    }

    func measuredMenuRowTitleWidth(_ title: String) -> CGFloat {
        if let cached = MenuRowRenderingCache.titleWidthByTitle[title] {
            return cached
        }
        let font = NSFont(name: firstRowBoldFontName, size: 54) ?? NSFont.boldSystemFont(ofSize: 54)
        let measured = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        MenuRowRenderingCache.titleWidthByTitle[title] = measured
        return measured
    }

    func measuredMenuRowTrailingTextWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        let roundedFontSize = Int((fontSize * 10).rounded())
        let cacheKey = "\(roundedFontSize):\(text)"
        if let cached = MenuRowRenderingCache.trailingWidthByTextAndFont[cacheKey] {
            return cached
        }
        let font = NSFont(name: firstRowRegularFontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        MenuRowRenderingCache.trailingWidthByTextAndFont[cacheKey] = measured
        return measured
    }

    func cachedMenuRowLeadingImage(named assetName: String) -> NSImage? {
        if let cached = MenuRowRenderingCache.imageByAssetName[assetName] {
            return cached
        }
        guard let image = NSImage(named: assetName) else {
            return nil
        }
        MenuRowRenderingCache.imageByAssetName[assetName] = image
        return image
    }

    func menuRowTitleView(title: String, availableWidth: CGFloat, shouldScroll: Bool) -> some View {
        ZStack(alignment: .leading) {
            Text(title)
                .font(.firstRowBold(size: 54))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .opacity(shouldScroll ? 0 : 1)
            if shouldScroll {
                MenuRowMarqueeText(
                    title: title,
                    viewportWidth: max(1, availableWidth.rounded(.towardZero)),
                ).transition(.identity)
            }
        }
        .frame(width: max(1, availableWidth), alignment: .leading)
        .clipped()
        .animation(nil, value: shouldScroll)
    }
}

private struct MenuRowMarqueeText: View {
    let title: String
    let viewportWidth: CGFloat
    private let gap: CGFloat = 72
    private let scrollSpeed: CGFloat = 52
    private let edgeFadeWidth: CGFloat = 34
    @State private var xOffset: CGFloat = 0
    @State private var animationGeneration = 0
    private var measuredWidth: CGFloat {
        let font = NSFont(name: firstRowBoldFontName, size: 54) ?? NSFont.boldSystemFont(ofSize: 54)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    var body: some View {
        let safeViewportWidth = max(1, viewportWidth)
        let edgeFadeFraction = min(0.5, max(0, edgeFadeWidth / safeViewportWidth))
        HStack(spacing: gap) {
            Text(title).font(.firstRowBold(size: 54)).foregroundColor(.white).lineLimit(1).allowsTightening(true).fixedSize(horizontal: true, vertical: false)
            Text(title).font(.firstRowBold(size: 54)).foregroundColor(.white).lineLimit(1).allowsTightening(true).fixedSize(horizontal: true, vertical: false)
        }.offset(x: xOffset).frame(width: safeViewportWidth, alignment: .leading).clipped().mask(LinearGradient(
            gradient: Gradient(stops: [.init(color: .clear, location: 0.0), .init(color: .white, location: edgeFadeFraction), .init(color: .white, location: 1.0 - edgeFadeFraction), .init(color: .clear, location: 1.0)]),
            startPoint: .leading,
            endPoint: .trailing,
        )).onAppear {
            restartMarqueeAnimation()
        }.onChange(of: title, perform: { _ in
            restartMarqueeAnimation()
        }).onChange(of: viewportWidth, perform: { _ in
            restartMarqueeAnimation()
        })
    }

    private func restartMarqueeAnimation() {
        let cycleDistance = max(CGFloat(1), measuredWidth + gap)
        let duration = Double(cycleDistance / max(CGFloat(1), scrollSpeed))
        animationGeneration &+= 1
        let generation = animationGeneration
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            xOffset = 0
        }
        DispatchQueue.main.async {
            guard generation == animationGeneration else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                xOffset = -cycleDistance
            }
        }
    }
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
        0
    }

    var restingSelectedVerticalOffset: CGFloat {
        rootCarouselCenterYOffset +
            (rootCarouselRadius * CGFloat(sin(rootCarouselTiltDegrees * (.pi / 180))))
    }

    var landedSelectedVerticalOffset: CGFloat {
        -392
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
        MenuVirtualScenePreset.scaledX(12, for: activeMenuVirtualSceneSize)
    }

    var rightMenuSceneOffsetX: CGFloat {
        MenuVirtualScenePreset.scaledX(-154, for: activeMenuVirtualSceneSize) +
            MenuVirtualScenePreset.additionalMenuGapX(for: activeMenuVirtualSceneSize)
    }

    var activeMenuVirtualSceneSize: CGSize {
        MenuVirtualScenePreset.widescreen
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                menuLayoutContainer(in: geometry).onKeyEvents(
                    onKeyDown: { key, isRepeat, modifiers in
                        if key == .upArrow || key == .downArrow || key == .leftArrow || key == .rightArrow {
                            if isRepeat { return }
                            handleDirectionalPressBegan(key, modifiers: modifiers)
                            return
                        }
                        endDirectionalHoldSession()
                        handleKeyInput(key, isRepeat: isRepeat, modifiers: modifiers)
                    },
                    onKeyUp: { key, _ in
                        handleDirectionalPressEnded(key)
                    },
                )
                .overlay(
                    GameControllerInputOverlay(
                        onArrowKeyDown: { key in
                            handleDirectionalPressBegan(key)
                        },
                        onArrowKeyUp: { key in
                            handleDirectionalPressEnded(key)
                        },
                        onEnter: {
                            endDirectionalHoldSession()
                            handleKeyInput(.enter, isRepeat: false, modifiers: [])
                        },
                        onBackspace: {
                            endDirectionalHoldSession()
                            handleKeyInput(.delete, isRepeat: false, modifiers: [])
                        },
                        onSpace: {
                            endDirectionalHoldSession()
                            handleKeyInput(.space, isRepeat: false, modifiers: [])
                        },
                    ).allowsHitTesting(false),
                )
                .onAppear {
                    beginStartupMusicLibraryPreloadIfNeeded()
                    syncRootLabelWithSelection()
                    SoundEffectPlayer.shared.warmUp(soundNames: [
                        "Selection",
                        "SelectionChange",
                        "Exit",
                        "Limit",
                        "Begin",
                        "End",
                        "MainLeft",
                        "MainTransitionFrom",
                        "MainDVDSelection",
                        "MainMusicSelection",
                        "MainPhotosSelection",
                        "MainVideosSelection",
                    ])
                }.onReceive(NotificationCenter.default.publisher(for: .firstRowIntroBegin)) { _ in
                    startRootIntroIfNeeded()
                }.onReceive(NotificationCenter.default.publisher(for: .firstRowCommandEscapeRequested)) { _ in
                    handleCommandEscapeRequested()
                }.onDisappear {
                    endDirectionalHoldSession()
                    rootLabelSwapWorkItem?.cancel()
                    cancelRootIntroWorkItems()
                    rootExitWorkItem?.cancel()
                }
            }
            if startupMusicLibraryPreloadOverlayOpacity > 0.001 {
                Color.black
                    .opacity(startupMusicLibraryPreloadOverlayOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(true)
            }
        }.ignoresSafeArea()
    }

    @ViewBuilder
    func menuLayoutContainer(in geometry: GeometryProxy) -> some View {
        let layout = MenuVirtualSceneLayout(
            containerSize: geometry.size,
            virtualSize: MenuVirtualScenePreset.widescreen,
        )
        ZStack {
            GeometryReader { virtualGeometry in
                menuScene(geometry: virtualGeometry)
            }
            .frame(width: layout.virtualSize.width, height: layout.virtualSize.height)
            .scaleEffect(layout.scale, anchor: .topLeading)
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading,
            )
            .offset(x: layout.offset.width, y: layout.offset.height)
            fullscreenPresentationLayers(containerSize: geometry.size)
            menuDisplayFadeOverlays(containerSize: geometry.size)
        }
    }

    @ViewBuilder
    func menuDisplayFadeOverlays(containerSize: CGSize) -> some View {
        Color.black.opacity(menuFolderSwapOverlayOpacity)
            .frame(width: containerSize.width, height: containerSize.height)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .zIndex(6000)
        Color.black.opacity(movieTransitionOverlayOpacity)
            .frame(width: containerSize.width, height: containerSize.height)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .zIndex(6001)
        Color.black.opacity(fullscreenTransitionOverlayOpacity)
            .frame(width: containerSize.width, height: containerSize.height)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .zIndex(6002)
    }

    @ViewBuilder
    func fullscreenPresentationLayers(containerSize: CGSize) -> some View {
        if isMoviePlaybackVisible, let moviePlayer {
            VideoPlayerView(player: moviePlayer)
                .frame(width: containerSize.width, height: containerSize.height)
                .ignoresSafeArea()
                .zIndex(4300)
        }
        if isMoviePlaybackVisible, areMovieControlsVisible {
            MoviePlaybackControlsOverlay(
                glyphState: movieControlsGlyphState,
                currentTimeSeconds: moviePlaybackCurrentSeconds,
                durationSeconds: moviePlaybackDurationSeconds,
                isLoading: isMoviePreviewDownloadLoading,
                loadingProgress: moviePreviewDownloadProgress,
            )
            .frame(width: containerSize.width, height: containerSize.height)
            .opacity(movieControlsOpacity)
            .ignoresSafeArea()
            .zIndex(4500)
        }
        if let activeFullscreenScene {
            FullscreenSceneHost(
                scene: activeFullscreenScene,
                builders: fullscreenSceneBuilders,
            )
            .frame(width: containerSize.width, height: containerSize.height)
            .opacity(fullscreenSceneOpacity)
            .ignoresSafeArea()
            .zIndex(5000)
        }
    }

    @ViewBuilder
    func rootBackdropView(geometry: GeometryProxy) -> some View {
        let stageOpacity = (isInSubmenu || isEnteringSubmenu) ? 0.72 : 1.0
        ZStack {
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.54),
                    .init(color: Color(white: 0.13).opacity(0.96 * stageOpacity), location: 0.76),
                    .init(color: Color(white: 0.32).opacity(0.8 * stageOpacity), location: 1.0),
                ]),
                startPoint: .top,
                endPoint: .bottom,
            )
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.white.opacity(0.12 * stageOpacity), location: 0.0),
                    .init(color: Color.white.opacity(0.05 * stageOpacity), location: 0.2),
                    .init(color: .clear, location: 0.72),
                ]),
                center: .init(x: 0.5, y: 0.86),
                startRadius: 0,
                endRadius: max(geometry.size.width, geometry.size.height) * 0.52,
            )
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: Color.white.opacity(0.03 * stageOpacity), location: 0.62),
                    .init(color: Color.white.opacity(0.12 * stageOpacity), location: 0.82),
                    .init(color: .clear, location: 1.0),
                ]),
                startPoint: .top,
                endPoint: .bottom,
            )
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.28), value: isInSubmenu)
    }

    var isRootVisible: Bool {
        !isInSubmenu && !isEnteringSubmenu && !isReturningToRoot
    }

    @ViewBuilder
    func introBackdropView(geometry: GeometryProxy) -> some View {
        if let image = introBackdropImage,
           isRootVisible || isRootIntroRunning
        {
            let progress = max(0, min(1, introBackdropProgress))
            let fadeProgress = unitProgress(
                (progress - rootIntroBackdropFadeStartProgress) /
                    max(0.001, 1 - rootIntroBackdropFadeStartProgress),
            )
            let scale = interpolatedValue(
                from: 1.0,
                to: rootIntroBackdropMinimumScale,
                progress: progress,
            )
            let yOffset = interpolatedValue(
                from: 0,
                to: rootIntroBackdropFinalYOffset,
                progress: progress,
            )
            let opacity = interpolatedValue(
                from: 1.0,
                to: 0.0,
                progress: smoothStep(fadeProgress),
            )
            let reflectionOpacity = opacity * 0.5
            let reflectionYOffset = yOffset + (geometry.size.height * scale)

            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(scale)
                    .offset(y: yOffset)
                    .clipped()
                    .opacity(Double(opacity))

                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(x: scale, y: -scale)
                    .offset(y: reflectionYOffset)
                    .mask(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .white, location: 0.0),
                                .init(color: .white, location: 0.8),
                                .init(color: .clear, location: 1.0),
                            ]),
                            startPoint: .top,
                            endPoint: .bottom,
                        ),
                    )
                    .clipped()
                    .opacity(Double(reflectionOpacity))
            }
            .onAppear {
                guard !hasAnnouncedIntroBackdropAppearance else { return }
                hasAnnouncedIntroBackdropAppearance = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    NotificationCenter.default.post(name: .firstRowIntroReady, object: nil)
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    func rootStageView(geometry: GeometryProxy) -> some View {
        let progress = max(0, min(1, introProgress))
        let stageStartYOffset = max(
            rootIntroStageStartYOffset,
            geometry.size.height * 1.45,
        )
        let introYOffset = interpolatedValue(
            from: stageStartYOffset,
            to: -6,
            progress: progress,
        )
        let introScale =
            rootIntroStageScaleCompensation() *
            interpolatedValue(
                from: rootIntroStageStartScale,
                to: 1,
                progress: progress,
            )
        ZStack {
            ForEach(visibleIndices(), id: \.self) { index in
                carouselItemView(for: index, geometry: geometry)
                    .opacity(
                        (isInSubmenu && !isEnteringSubmenu && !isReturningToRoot)
                            ? 0
                            : 1,
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(introScale, anchor: .bottom)
        .offset(y: introYOffset)
        .opacity(1)
    }

    @ViewBuilder
    func rootLabelView(geometry _: GeometryProxy) -> some View {
        if isRootVisible, isRootLabelVisible || !isRootIntroRunning {
            Text(rootLabelText)
                .font(.firstRowBold(size: 92))
                .foregroundColor(.white)
                .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
                .opacity(rootLabelOpacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .offset(y: -40)
        }
    }

    @ViewBuilder
    func menuColumnView(
        rootID: String?,
        headerText: String,
        items: [MenuListItemConfig],
        selectedIndex: Int,
        geometry: GeometryProxy,
    ) -> some View {
        let clampedSelectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        let isPhotosMenu = rootID == "photos"
        let selectionWidthScale = isPhotosMenu
            ? max(menuSelectionWidthScale, photosSelectionBoxWidthScale)
            : menuSelectionWidthScale
        let selectionHeightScale = isPhotosMenu
            ? max(menuSelectionHeightScale, photosSelectionBoxHeightScale)
            : menuSelectionHeightScale
        VStack(spacing: 20) {
            HStack(spacing: 20) {
                if let rootID, let image = menuImage(forRootID: rootID) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 92, height: 92)
                }
                Text(headerText)
                    .font(.firstRowBold(size: 88))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Rectangle()
                .fill(Color.white.opacity(0.9))
                .frame(width: min(1500, geometry.size.width * 0.86), height: 3)
            menuListContainer(
                items: items,
                selectedIndex: clampedSelectedIndex,
                geometry: geometry,
                arrowAppearance: menuArrowAppearance,
                showsTopOverflowFade: true,
                visibleRowCount: 6,
                selectionBoxWidthScale: selectionWidthScale,
                selectionBoxHeightScale: selectionHeightScale,
            )
            .frame(height: menuListLayoutHeight(for: 6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 44)
    }

    @ViewBuilder
    func submenuStageView(geometry: GeometryProxy) -> some View {
        let liveItems = isInThirdMenu ? thirdMenuListItems() : submenuListItems()
        let liveSelectedIndex = isInThirdMenu ? selectedThirdIndex : selectedSubIndex
        let liveOpacity = isInThirdMenu ? thirdMenuOpacity : submenuOpacity
        ZStack {
            if let snapshot = menuTransitionSnapshot {
                menuColumnView(
                    rootID: snapshot.rootID,
                    headerText: snapshot.headerText,
                    items: snapshot.items,
                    selectedIndex: snapshot.selectedIndex,
                    geometry: geometry,
                )
                .offset(x: -menuSlideDistance * menuTransitionProgress)
                .opacity(1 - (0.15 * Double(menuTransitionProgress)))
            }
            menuColumnView(
                rootID: activeRootItemID,
                headerText: headerText,
                items: liveItems,
                selectedIndex: liveSelectedIndex,
                geometry: geometry,
            )
            .offset(
                x: menuTransitionSnapshot == nil
                    ? 0
                    : menuSlideDistance * (1 - menuTransitionProgress),
            )
            .opacity(
                (menuTransitionSnapshot == nil ? 1 : (0.82 + (0.18 * menuTransitionProgress))) *
                    liveOpacity,
            )
        }
        .animation(.easeInOut(duration: 0.2), value: liveOpacity)
    }

    func menuScene(geometry: GeometryProxy) -> some View {
        ZStack {
            rootBackdropView(geometry: geometry)
            introBackdropView(geometry: geometry)
            rootStageView(geometry: geometry)
            rootLabelView(geometry: geometry)
            if isInSubmenu || isEnteringSubmenu || isReturningToRoot {
                submenuStageView(geometry: geometry)
                    .opacity(menuSceneOpacity)
            }
            if isMovieResumePromptVisible {
                movieResumePromptOverlay(geometry: geometry).frame(width: geometry.size.width, height: geometry.size.height).opacity(movieResumePromptOpacity).zIndex(4200)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        .coordinateSpace(name: "menuSceneSpace")
    }
}
