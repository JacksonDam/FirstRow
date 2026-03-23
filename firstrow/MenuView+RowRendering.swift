import AVFoundation
import AVKit
import SwiftUI


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

private class AVPlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

private struct MovieGapPlayerView: NSViewRepresentable {
    let player: AVQueuePlayer
    func makeNSView(context: Context) -> AVPlayerLayerView {
        let view = AVPlayerLayerView()
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ nsView: AVPlayerLayerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

private enum MenuRowRenderingCache {
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

    static func virtualSize(for containerSize: CGSize) -> CGSize {
        guard containerSize.width > 0, containerSize.height > 0 else { return widescreen }
        let widescreenAspect = widescreen.width / widescreen.height
        let containerAspect = containerSize.width / containerSize.height
        guard containerAspect < widescreenAspect else { return widescreen }
        let virtualHeight = ceil(widescreen.width * containerSize.height / containerSize.width)
        return CGSize(width: widescreen.width, height: virtualHeight)
    }

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

private enum CarouselIconLayer {
    case reflection
    case icon
}

func interpolatedCGFloat(
    from start: CGFloat,
    to end: CGFloat,
    progress: CGFloat,
) -> CGFloat {
    start + ((end - start) * progress)
}

private func unitProgress(_ raw: CGFloat) -> CGFloat {
    min(max(raw, 0), 1)
}

func smoothStep(_ raw: CGFloat) -> CGFloat {
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
    let blurRadius = max(0, -normalizedDepth) * 0.35

    return RootStagePlacement(
        horizontalOffset: (radius * CGFloat(sin(angle))) + sideHorizontalBias,
        verticalOffset: centerYOffset + (depth * CGFloat(sin(tiltRadians))) + sideVerticalBias,
        zIndex: projectedDepth,
        scale: perspectiveScale,
        baseSizeMultiplier: baseSizeMultiplier,
        blurRadius: blurRadius,
        opacity: 1,
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
    let isBackground: Bool
    let backgroundGroupLift: CGFloat
    let backgroundZDepth: CGFloat
    var submenuTransitionProgress: CGFloat
    var selectionValue: Double
    var introProgress: Double

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, CGFloat> {
        get { .init(.init(selectionValue, introProgress), submenuTransitionProgress) }
        set {
            selectionValue = newValue.first.first
            introProgress = newValue.first.second
            submenuTransitionProgress = newValue.second
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
        let transitionProgress = smoothStep(submenuTransitionProgress)
        let metrics: (opacity: CGFloat, scale: CGFloat, horizontalOffset: CGFloat, verticalOffset: CGFloat, blurRadius: CGFloat) = {
            if isBackground {
                let focalLength: CGFloat = 1000
                let zOffset = backgroundZDepth * transitionProgress
                let depthScale = focalLength / (focalLength + zOffset)
                return (
                    opacity: interpolatedCGFloat(
                        from: placement.opacity,
                        to: 0.18,
                        progress: transitionProgress,
                    ),
                    scale: placement.scale * depthScale,
                    horizontalOffset: placement.horizontalOffset * depthScale,
                    verticalOffset: placement.verticalOffset * depthScale + interpolatedCGFloat(
                        from: 0,
                        to: backgroundGroupLift,
                        progress: transitionProgress,
                    ),
                    blurRadius: 0,
                )
            }

            return (
                opacity: 1,
                scale: interpolatedCGFloat(
                    from: placement.scale,
                    to: 1,
                    progress: transitionProgress,
                ),
                horizontalOffset: interpolatedCGFloat(
                    from: placement.horizontalOffset,
                    to: 0,
                    progress: transitionProgress,
                ),
                verticalOffset: interpolatedCGFloat(
                    from: placement.verticalOffset,
                    to: 0,
                    progress: transitionProgress,
                ),
                blurRadius: interpolatedCGFloat(
                    from: placement.blurRadius,
                    to: 0,
                    progress: transitionProgress,
                ),
            )
        }()

        content
            .scaleEffect(metrics.scale)
            .opacity(metrics.opacity)
            .offset(x: metrics.horizontalOffset, y: metrics.verticalOffset)
            .blur(radius: metrics.blurRadius)
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
            Text(headerText).font(.firstRowBold(size: 60)).foregroundStyleCompat(.white).opacity(submenuTitleOpacity).offset(x: firstRowHeaderOffsetX(geometry: geometry) + (landedIconWidth * 0.6)).offset(y: menuHeaderVerticalOffset).animation(.easeInOut(duration: 0.25), value: submenuTitleOpacity)
        } else {
            Text(headerText).font(.firstRowBold(size: 60)).foregroundStyleCompat(.white).offset(x: rootMenuHeaderOffsetX(geometry: geometry)).offset(y: menuHeaderVerticalOffset).opacity(headerOpacity).animation(.easeInOut(duration: 0.25), value: headerOpacity)
        }
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
        contentWidthOverride: CGFloat? = nil,
        selectionVisualWidthOverride: CGFloat? = nil,
        selectionVisualHeightOverride: CGFloat? = nil,
        selectionAnchorY: CGFloat? = nil,
        viewportHeightOverride: CGFloat? = nil,
        containerHeightOverride: CGFloat? = nil,
        rowPitchOverride: CGFloat? = nil,
        scaledRowVerticalOffsetOverride: CGFloat? = nil,
        contentVerticalOffsetOverride: CGFloat = 0,
        isPodcastEpisodesPage: Bool = false,
    ) -> some View {
        let rowSelectionAnimation: Animation? = isMenuFolderSwapTransitioning ? nil : selectionMovementAnimation
        let menuWidth = contentWidthOverride ?? menuWidthConstrained(geometry: geometry)
        let selectionWidth = contentWidthOverride ?? (menuWidth * selectionBoxWidthScale)
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
            selectionVisualWidthOverride ??
            (selectionWidth +
                (selectionTextureVisualWidthDelta * selectionBoxWidthScale) +
                selectionTextureLeadingAdjustment +
                selectionTextureTrailingAdjustment)
        let selectionVisualHeight =
            selectionVisualHeightOverride ??
            (selectionHeight +
                (selectionTextureVisualHeightDelta * selectionBoxHeightScale) +
                selectionTextureHeightAdjustment)
        let selectionXOffset = -((selectionWidth - menuWidth) * 0.5)
        let selectionYOffset =
            scaledRowVerticalOffsetOverride ??
            (-((selectionHeight - selectionBoxHeight) * 0.5))
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
        let rowPitch = rowPitchOverride ?? effectiveRowPitch(forSelectionBoxHeightScale: selectionBoxHeightScale)
        let normalHeightIndices: Set<Int> = []
        let rowOffsets = menuRowOffsets(for: items, dividerGap: dividerGap, rowPitch: rowPitch, normalHeightIndices: normalHeightIndices)
        let contentHeight = menuContentHeight(
            for: items,
            rowOffsets: rowOffsets,
            rowHeight: selectionHeight,
        )
        let viewportHeight = viewportHeightOverride ?? menuViewportHeight(for: visibleRowCount)
        let containerHeight = containerHeightOverride ?? menuListLayoutHeight(for: visibleRowCount)
        let scrollOffset = menuScrollOffset(
            contentHeight: contentHeight,
            selectedIndex: selectedIndex,
            rowOffsets: rowOffsets,
            viewportHeight: viewportHeight,
            selectionAnchorY: selectionAnchorY,
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
        let containerFrameWidth = max(menuWidth, effectiveSelectionVisualWidth)
        let visibleRowIndices = visibleMenuRowIndices(
            rowOffsets: rowOffsets,
            rowHeight: selectionHeight,
            scrollOffset: scrollOffset,
            viewportHeight: viewportHeight,
            prefersWiderOverscan: !isSelectionSettled,
        )
        return ZStack(alignment: .topLeading) {
            if !items.isEmpty {
                selectionBox(width: effectiveSelectionVisualWidth, height: effectiveSelectionVisualHeight)
                    .offset(
                        x: effectiveSelectionVisualXOffset,
                        y: selectedRowOffset + scrollOffset + effectiveSelectionVisualYOffset,
                    )
                    .animation(rowSelectionAnimation, value: selectedRowOffset)
                    .animation(rowSelectionAnimation, value: scrollOffset)
            }
            ZStack(alignment: .topLeading) {
                ForEach(visibleRowIndices, id: \.self) { index in
                    let item = items[index]
                    let rowIsSelected = index == selectedIndex
                    let rowIsNormalHeight = normalHeightIndices.contains(index)
                    let rowHeight = rowIsNormalHeight ? selectionBoxHeight : selectionHeight
                    let rowYOffset = rowIsNormalHeight ? 0 : selectionYOffset
                    if item.showsTopDivider {
                        Rectangle()
                            .fill(Color.white.opacity(0.34))
                            .frame(width: max(0, rowContentWidth - (dividerLineInsetHorizontal * 2)), height: 1)
                            .offset(
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
                        showsBlueDot: item.showsBlueDot,
                        alignsTextToDividerStart: item.alignsTextToDividerStart,
                        arrowAppearance: arrowAppearance,
                        isPodcastEpisodesPage: isPodcastEpisodesPage,
                    ).frame(width: rowContentWidth, height: rowHeight, alignment: .leading).offset(
                        x: rowContentXOffset,
                        y: rowOffsets[index] + rowYOffset,
                    )
                }
            }
            .offset(y: scrollOffset + contentVerticalOffsetOverride)
            .animation(rowSelectionAnimation, value: selectedIndex)
            .animation(rowSelectionAnimation, value: scrollOffset)
            .frame(height: viewportHeight, alignment: .top)
            .mask(
                Rectangle().frame(width: 5000, height: viewportHeight),
            )
        }.frame(height: viewportHeight, alignment: .top).frame(width: containerFrameWidth, height: containerHeight, alignment: .topLeading).background(
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
            let sourceCapWidth: CGFloat = 83
            let sourceHeight: CGFloat = 122
            let textureHeight = height
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

    var displayedSubmenuTitle: String {
        rootLabelText
    }

    func submenuHeaderTitleWidth(for title: String) -> CGFloat {
        let font = NSFont(name: firstRowBoldFontName, size: 92)
            ?? NSFont.boldSystemFont(ofSize: 92)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    func submenuHeaderTitleWidth() -> CGFloat {
        submenuHeaderTitleWidth(for: displayedSubmenuTitle)
    }

    func submenuHeaderCenterYOffset() -> CGFloat {
        -((activeMenuVirtualSceneSize.height * 0.5) - submenuHeaderTopInset - (landedIconWidth * 0.5))
    }

    func selectedCarouselIconOpticalYOffset(for rootID: String?) -> CGFloat {
        rootID == "movies" ? 18 : 0
    }

    func selectedCarouselReflectionRootOffset(for rootID: String?) -> CGFloat {
        rootID == "movies" ? 18 : 0
    }

    func landedSelectedHorizontalOffset(
        geometry _: GeometryProxy,
        title: String,
    ) -> CGFloat {
        let titleWidth = submenuHeaderTitleWidth(for: title)
        let iconWidth = landedIconWidth
        let spacing: CGFloat = 24
        let totalWidth = iconWidth + spacing + titleWidth
        return -(totalWidth * 0.5) + (iconWidth * 0.5)
    }

    func landedSelectedHorizontalOffset(geometry: GeometryProxy) -> CGFloat {
        landedSelectedHorizontalOffset(geometry: geometry, title: displayedSubmenuTitle)
    }

    func submenuHeaderTitleLeadingGlobalX(geometry: GeometryProxy) -> CGFloat {
        let titleWidth = submenuHeaderTitleWidth()
        let titleCenterX = firstRowHeaderOffsetX(geometry: geometry) + (landedIconWidth * 0.6)
        return titleCenterX - (titleWidth * 0.5)
    }

    private func submenuHeaderIconCenter(
        geometry: GeometryProxy,
        rootID: String?,
        title: String,
    ) -> CGPoint {
        let baseCenter = selectedOverlayBaseCenter(geometry: geometry)
        let opticalYOffset = selectedCarouselIconOpticalYOffset(for: rootID)
        return CGPoint(
            x: baseCenter.x + landedSelectedHorizontalOffset(geometry: geometry, title: title),
            y: baseCenter.y + landedSelectedVerticalOffset + submenuHeaderIconOpticalYOffset +
                (opticalYOffset * landedIconScale),
        )
    }

    private func submenuHeaderLabelCenter(
        geometry: GeometryProxy,
        rootID: String?,
        title: String,
    ) -> CGPoint {
        let iconCenter = submenuHeaderIconCenter(
            geometry: geometry,
            rootID: rootID,
            title: title,
        )
        return CGPoint(
            x: iconCenter.x + (landedIconWidth * 0.5) + 24 + (submenuHeaderTitleWidth(for: title) * 0.5),
            y: iconCenter.y,
        )
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
        let opticalYOffset = selectedCarouselIconOpticalYOffset(for: activeRootItemID)
        return Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: landedIconWidth, height: landedIconWidth).offset(
            x: landedSelectedHorizontalOffset(geometry: geometry),
            y: landedSelectedVerticalOffset + (opticalYOffset * landedIconScale),
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
        selectionAnchorY: CGFloat? = nil,
    ) -> CGFloat {
        guard rowOffsets.indices.contains(selectedIndex) else { return 0 }
        if let selectionAnchorY {
            return selectionAnchorY - rowOffsets[selectedIndex]
        }
        guard contentHeight > viewportHeight else { return 0 }
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
        let overscanMultiplier: CGFloat = prefersWiderOverscan ? 6.0 : 3.0
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

    private func carouselItemView(
        for index: Int,
        geometry: GeometryProxy,
        layer: CarouselIconLayer,
    ) -> some View {
        let placement = rootStagePlacement(for: index)
        let isSelectedRootItem = index == selectedIndex
        let isBackground = !isSelectedRootItem
        let selectedTransitionProgress = smoothStep(submenuTransitionProgress)
        let selectedAdjustedIconSize = iconSize * selectedCarouselAdjustedSizeMultiplier
        let selectedRestingScale = placement.baseSizeMultiplier / selectedCarouselAdjustedSizeMultiplier
        let adjustedIconSize = isSelectedRootItem
            ? selectedAdjustedIconSize
            : (iconSize * placement.baseSizeMultiplier)
        let iconScale = isSelectedRootItem
            ? interpolatedCGFloat(
                from: selectedRestingScale,
                to: landedIconScale,
                progress: selectedTransitionProgress,
            )
            : 1
        let horizontalOffset = isSelectedRootItem
            ? interpolatedCGFloat(
                from: 0,
                to: landedSelectedHorizontalOffset(geometry: geometry),
                progress: selectedTransitionProgress,
            )
            : 0
        let opticalYOffset = selectedCarouselIconOpticalYOffset(for: menuItems[index].id)
        let verticalOffset = isSelectedRootItem
            ? interpolatedCGFloat(
                from: 0,
                to: landedSelectedVerticalOffset + (opticalYOffset * landedIconScale),
                progress: selectedTransitionProgress,
            )
            : 0
        let isIncoming = false
        let entryOffset = selectedCarouselEntryOffset
        let reflectionRootOffset = selectedCarouselReflectionRootOffset(for: menuItems[index].id)
        let reflectionYOffsetOverride: CGFloat = isSelectedRootItem
            ? interpolatedCGFloat(
                from: reflectionRootOffset + selectedCarouselReflectionYOffset,
                to: (reflectionRootOffset * landedIconScale) + selectedCarouselReflectionYOffset,
                progress: selectedTransitionProgress,
            )
            : reflectionRootOffset + (isSelectedRootItem ? selectedCarouselReflectionYOffset : 0)
        let currentOrbitHorizontalOffset = interpolatedCGFloat(
            from: placement.horizontalOffset,
            to: 0,
            progress: selectedTransitionProgress,
        )
        let currentOrbitVerticalOffset = interpolatedCGFloat(
            from: placement.verticalOffset,
            to: 0,
            progress: selectedTransitionProgress,
        )
        let detachedReflectionCompensationX =
            isSelectedRootItem
                ? (currentOrbitHorizontalOffset + horizontalOffset)
                : 0
        let detachedReflectionCompensationY =
            isSelectedRootItem
                ? (currentOrbitVerticalOffset + verticalOffset)
                : 0
        return Group {
            if let image = menuImage(forRootID: menuItems[index].id) {
                standardCarouselIconView(
                    image: image,
                    adjustedIconSize: adjustedIconSize,
                    scale: iconScale,
                    opacity: 1,
                    horizontalOffset: horizontalOffset,
                    verticalOffset: verticalOffset,
                    isIncoming: isIncoming,
                    entryOffset: entryOffset,
                    zInd: isSelectedRootItem ? 1000 : 0,
                    isBackground: isBackground,
                    backgroundBlur: 0,
                    layer: layer,
                    showReflection: !(isSelectedRootItem && isInSubmenu && !isEnteringSubmenu && !isReturningToRoot),
                    animateReflection: isSelectedRootItem && (!isInSubmenu || isEnteringSubmenu || isReturningToRoot),
                    reflectionYOffsetOverride: reflectionYOffsetOverride,
                    detachedReflectionXOffset: selectedCarouselDetachedReflectionXOffset - geometry.size.width * 0.05,
                    detachedReflectionCompensationX: detachedReflectionCompensationX,
                    detachedReflectionCompensationY: detachedReflectionCompensationY,
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
                        isBackground: isBackground,
                        backgroundGroupLift: backgroundCarouselGroupLift,
                        backgroundZDepth: backgroundCarouselZDepth,
                        submenuTransitionProgress: submenuTransitionProgress,
                        selectionValue: rootCarouselSelectionValue,
                        introProgress: Double(introProgress),
                    ),
                )
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

    private func standardCarouselIconView(
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
        layer: CarouselIconLayer,
        showReflection: Bool = true,
        animateReflection: Bool = false,
        reflectionYOffsetOverride: CGFloat = 0,
        detachedReflectionXOffset: CGFloat? = nil,
        detachedReflectionCompensationX: CGFloat = 0,
        detachedReflectionCompensationY: CGFloat = 0,
    ) -> some View {
        let baseX = horizontalOffset + (isIncoming ? -entryOffset : 0)
        let baseY = verticalOffset + (isIncoming ? entryOffset : 0)
        let usesDetachedReflection = animateReflection &&
            ((isEnteringSubmenu && !isReturningToRoot) || (isReturningToRoot && isIconAnimated))
        let reflectionYOffsetAdjustment: CGFloat = -38
        let effectiveDetachedReflectionX = detachedReflectionXOffset ?? selectedCarouselDetachedReflectionXOffset
        let reflectionX = usesDetachedReflection ? effectiveDetachedReflectionX : 0.0
        let reflectionY =
            (usesDetachedReflection ? selectedCarouselDetachedReflectionYOffset : 0.0) +
            reflectionYOffsetAdjustment +
            reflectionYOffsetOverride
        let reflectionOpacity = usesDetachedReflection ? 0.22 : 0.34
        let reflectionBlur = usesDetachedReflection ? 3.0 : 0.0
        let backgroundIconTransitionDuration =
            isReturningToRoot
                ? submenuBackgroundIconReturnDuration
                : submenuBackgroundIconTransitionDuration
        let layerZIndex = layer == .reflection ? (zInd - 10_000) : zInd
        return Group {
            if layer == .reflection, showReflection {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: adjustedIconSize, height: adjustedIconSize).mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white.opacity(0.88), location: 0.0),
                            .init(color: .white.opacity(0.44), location: 0.75),
                            .init(color: .white.opacity(0.44), location: 1.0),
                        ]),
                        startPoint: .bottom,
                        endPoint: .top,
                    ),
                ).scaleEffect(x: 1.0, y: -1.0, anchor: .bottom).scaleEffect(scale).opacity(reflectionOpacity).offset(
                    x: reflectionX - (usesDetachedReflection ? detachedReflectionCompensationX : 0),
                    y: reflectionY - (usesDetachedReflection ? detachedReflectionCompensationY : 0),
                ).blur(radius: reflectionBlur)
            }
            if layer == .icon {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: adjustedIconSize, height: adjustedIconSize).scaleEffect(scale)
            }
        }.opacity(opacity).offset(x: baseX, y: baseY).zIndex(isIncoming ? 1 : layerZIndex).blur(radius: backgroundBlur).animation(.easeInOut(duration: backgroundIconTransitionDuration), value: isEnteringSubmenu && isBackground).animation(.easeInOut(duration: iconFlightAnimationDuration), value: isIconAnimated)
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
        showsBlueDot: Bool,
        alignsTextToDividerStart: Bool,
        arrowAppearance: ArrowAppearance,
        isPodcastEpisodesPage: Bool = false,
    ) -> some View {
        let showsLoadingSpinner = (itemID == "movies_theatrical_trailers" && isTheatricalTrailersLoading && isSelected)
            || (activeRootItemID == "movies" && itemID == PodcastBrowserKind.video.submenuItemID && isLoadingPodcasts && isSelected)
            || (activeRootItemID == "music" && itemID == PodcastBrowserKind.audio.submenuItemID && isLoadingPodcasts && isSelected)
            || (thirdMenuMode == .moviesFolder && isMoviePlaybackLoading && isSelected)
            || (thirdMenuMode == .videoPodcastEpisodes && isMoviePlaybackLoading && isSelected)
            || (thirdMenuMode == .photosDateAlbums && isPhotosAlbumSelectionLoading && isSelected)
        let trailingBaseFontSize = submenuRowTrailingFontSize
        let arrowFontSize = submenuArrowFontSize
        let hasLeadingImage = (leadingImage != nil) || (leadingImageAssetName != nil)
        let isPhotoAlbumRow = activeRootItemID == "photos" && hasLeadingImage
        let rowHorizontalPadding: CGFloat = isPhotoAlbumRow ? 9 : 20
        let rowInnerWidth = max(0, rowWidth - (rowHorizontalPadding * 2))
        let textLeadingInset = 14 + (hasLeadingImage ? 0 : leadingCompensation)
        let textStartX = rowHorizontalPadding + textLeadingInset
        let isSubmenuListRow = activeRootItemID != nil && (isInSubmenu || isEnteringSubmenu || isReturningToRoot)
        let resolvedTrailingText: String? = {
            guard let trailingText else { return nil }
            if trailingText == "..." || trailingText == "•••" {
                return nil
            }
            return trailingText
        }()
        let dynamicPhotosLeadingImage = (activeRootItemID == "photos" && isInThirdMenu && thirdMenuMode == .photosDateAlbums)
            ? photosAlbumCoverImageCache[itemID]
            : nil
        let isPodcastEpisodeRow = isPodcastEpisodesPage || (
            isInThirdMenu &&
                (thirdMenuMode == .audioPodcastEpisodes || thirdMenuMode == .videoPodcastEpisodes)
        )
        let trailingTextOpacity: Double = isPodcastEpisodeRow ? 1.0 : ((isSelected && isSelectionSettled) ? 1.0 : 0.5)
        let resolvedLeadingImage =
            dynamicPhotosLeadingImage ??
            leadingImage ??
            leadingImageAssetName.flatMap { cachedMenuRowLeadingImage(named: $0) }
        let effectiveArrowXOffset = arrowAppearance.xOffset
        let submenuTrailingSymbolXOffset = -(submenuTrailingSymbolRightInset - rowHorizontalPadding)
        let trailingFontSize: CGFloat = isPodcastEpisodeRow ? max(30, trailingBaseFontSize - 2) : trailingBaseFontSize
        let trailingVerticalOffset: CGFloat = 0
        let trailingToArrowSpacing: CGFloat = 6
        let trailingTextXOffset =
            isPodcastEpisodeRow && trailingSymbolName == nil && !showsArrow
            ? (arrowAppearance.xOffset - 60)
            : arrowAppearance.xOffset
        let trailingMeasuredTextWidth: CGFloat = {
            guard let resolvedTrailingText else { return 0 }
            return measuredMenuRowTrailingTextWidth(
                resolvedTrailingText,
                fontSize: trailingFontSize,
            )
        }()
        let trailingColumnWidth: CGFloat = {
            if trailingSymbolName != nil {
                return 180
            }
            if resolvedTrailingText != nil, showsArrow {
                let arrowWidth = max(30, arrowFontSize * 0.9)
                let padding: CGFloat = 32
                let spacing = max(0, trailingToArrowSpacing)
                let combined = trailingMeasuredTextWidth + arrowWidth + spacing + padding
                return max(180, min(320, combined))
            }
            if resolvedTrailingText != nil {
                let padding: CGFloat = 24
                let maxColumnWidth = min(360, rowInnerWidth * 0.7)
                return max(150, min(maxColumnWidth, trailingMeasuredTextWidth + padding))
            }
            if showsArrow {
                return 180
            }
            return 0
        }()
        let showsTrailingColumn =
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
            if isSubmenuListRow {
                return max(14 + leadingCompensation, submenuTextLeadingInset - rowHorizontalPadding)
            }
            return 14 + leadingCompensation
        }()
        let desiredArrowEdgeInset = rowHorizontalPadding + leadingTextPadding
        let currentArrowEdgeInset = rowHorizontalPadding + max(0, -effectiveArrowXOffset)
        let arrowEdgeCompensation = max(0, desiredArrowEdgeInset - currentArrowEdgeInset)
        let symmetricArrowXOffset = effectiveArrowXOffset - arrowEdgeCompensation
        let trailingSymbolXOffset = isSubmenuListRow ? submenuTrailingSymbolXOffset : arrowAppearance.xOffset
        let standaloneArrowXOffset = isSubmenuListRow ? submenuTrailingSymbolXOffset : symmetricArrowXOffset
        let inlineArrowAdditionalXOffset = isSubmenuListRow
            ? (submenuTrailingSymbolXOffset - symmetricArrowXOffset)
            : 0
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
                )
            }.frame(width: leftColumnWidth > 0 ? leftColumnWidth : nil, alignment: .leading).padding(.leading, leadingTextPadding)
            if let trailingSymbolName {
                Image(systemName: trailingSymbolName).foregroundStyleCompat(.white).font(.system(size: trailingBaseFontSize, weight: .semibold)).shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4).frame(width: trailingColumnWidth, alignment: .trailing).offset(x: trailingSymbolXOffset)
            } else if let resolvedTrailingText, showsArrow {
                HStack(spacing: trailingToArrowSpacing) {
                    Text(resolvedTrailingText).font(.firstRowRegular(size: trailingFontSize)).foregroundStyleCompat(.white).opacity(trailingTextOpacity).lineLimit(1).minimumScaleFactor(0.65).allowsTightening(true).offset(y: trailingVerticalOffset)
                    Image(systemName: arrowAppearance.symbolName).foregroundStyleCompat(arrowAppearance.color).font(.system(size: arrowFontSize, weight: arrowAppearance.fontWeight)).shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4).offset(x: inlineArrowAdditionalXOffset)
                }.frame(width: trailingColumnWidth, alignment: .trailing).offset(x: symmetricArrowXOffset)
            } else if let resolvedTrailingText {
                Text(resolvedTrailingText).font(.firstRowRegular(size: trailingFontSize)).foregroundStyleCompat(.white).opacity(trailingTextOpacity).lineLimit(1).minimumScaleFactor(0.65).allowsTightening(true).frame(width: trailingColumnWidth, alignment: .trailing).offset(x: trailingTextXOffset)
            } else if showsArrow {
                Image(systemName: arrowAppearance.symbolName).foregroundStyleCompat(arrowAppearance.color).font(.system(size: arrowFontSize, weight: arrowAppearance.fontWeight)).shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4).frame(width: trailingColumnWidth, alignment: .trailing).offset(x: standaloneArrowXOffset)
            }
        }.frame(width: rowInnerWidth, alignment: .leading).padding(.horizontal, rowHorizontalPadding).overlay(Group {
            if showsBlueDot {
                let badgeSize: CGFloat = 56
                let badgeCenterX = max(15, textStartX * 0.5) + 27
                Image("PodcastRecentBadge")
                    .resizable()
                    .frame(width: badgeSize, height: badgeSize)
                    .offset(x: badgeCenterX - (badgeSize * 0.5))
            }
        }, alignment: .leading)
        .overlay(Group {
            if showsLoadingSpinner {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(2.0)
                    .frame(width: 60, height: 60)
                    .offset(x: -50)
            }
        }, alignment: .trailing)
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

    func menuRowTitleView(title: String, availableWidth: CGFloat) -> some View {
        Text(title)
            .font(.firstRowBold(size: submenuRowTitleFontSize))
            .foregroundStyleCompat(.white)
            .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
            .lineLimit(1)
            .truncationMode(.tail)
            .allowsTightening(true)
        .frame(width: max(1, availableWidth), alignment: .leading)
        .clipped()
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
        submenuHeaderCenterYOffset() + landedFinalYOffsetAdjustment
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
        MenuVirtualScenePreset.virtualSize(for: menuContainerSize)
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
                    menuContainerSize = geometry.size
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
                }.onChange(of: geometry.size) {
                    menuContainerSize = $0
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
                    .allowsHitTesting(false)
            }
        }.ignoresSafeArea()
    }

    @ViewBuilder
    func menuLayoutContainer(in geometry: GeometryProxy) -> some View {
        let virtualSize = MenuVirtualScenePreset.virtualSize(for: geometry.size)
        let layout = MenuVirtualSceneLayout(
            containerSize: geometry.size,
            virtualSize: virtualSize,
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
        if isMoviePlaybackVisible {
            Color.black
                .frame(width: containerSize.width, height: containerSize.height)
                .opacity(moviePlaybackEntryOpacity)
                .ignoresSafeArea()
                .zIndex(4299)
        }
        if isMoviePlaybackVisible, let moviePlayer {
            VideoPlayerView(player: moviePlayer)
                .frame(width: containerSize.width, height: containerSize.height)
                .opacity(moviePlaybackEntryOpacity)
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
        ZStack {
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.5),
                    .init(color: Color(red: 100 / 255, green: 100 / 255, blue: 96 / 255), location: 1.0),
                ]),
                startPoint: .top,
                endPoint: .bottom,
            )
            if let backdropImage = movieResumePromptBackdropImage, movieResumeBackdropOpacity > 0 {
                Image(nsImage: backdropImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .blur(radius: 28)
                    .saturation(0.92)
                    .overlay(Color.black.opacity(0.33))
                    .opacity(movieResumeBackdropOpacity)
                    .animation(.easeInOut(duration: 0.5), value: movieResumeBackdropOpacity)
            }
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
                Task {
                    try? await firstRowSleep(0.03)
                    guard !Task.isCancelled else { return }
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
            ZStack {
                ForEach(visibleIndices(), id: \.self) { index in
                    carouselItemView(for: index, geometry: geometry, layer: .reflection)
                        .opacity(
                            (
                                isInSubmenu && !isEnteringSubmenu && !isReturningToRoot
                            ) ||
                                (
                                    showsHeaderTransitionOverlay && index == selectedIndex
                                )
                                ? 0
                                : 1,
                        )
                }
            }
            .zIndex(0)
            ZStack {
                ForEach(visibleIndices(), id: \.self) { index in
                    carouselItemView(for: index, geometry: geometry, layer: .icon)
                        .opacity(
                            (
                                (isInSubmenu && !isEnteringSubmenu && !isReturningToRoot) ||
                                    (showsHeaderTransitionOverlay && index == selectedIndex)
                            )
                                ? 0
                                : 1,
                        )
                }
            }
            .zIndex(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(introScale, anchor: .bottom)
        .offset(y: introYOffset)
        .opacity(1)
    }

    @ViewBuilder
    func rootLabelView(geometry: GeometryProxy) -> some View {
        if !isInSubmenu && !showsHeaderTransitionOverlay && (isRootLabelVisible || !isRootIntroRunning) {
            let titleHeight: CGFloat = 92
            let startCenterX = geometry.size.width * 0.5
            let startCenterY = geometry.size.height - 40 - (titleHeight * 0.5)
            Text(rootLabelText)
                .font(.firstRowBold(size: 92))
                .foregroundStyleCompat(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
                .opacity(rootLabelOpacity)
                .id("settled-root-label")
                .position(
                    x: startCenterX,
                    y: startCenterY,
                )
                .zIndex(3200)
        }
    }

    var showsHeaderTransitionOverlay: Bool {
        activeRootItemID != nil && (isEnteringSubmenu || isReturningToRoot)
    }

    func currentRootStageYOffset(geometry: GeometryProxy) -> CGFloat {
        let progress = max(0, min(1, introProgress))
        let stageStartYOffset = max(
            rootIntroStageStartYOffset,
            geometry.size.height * 1.45,
        )
        return interpolatedValue(
            from: stageStartYOffset,
            to: -6,
            progress: progress,
        )
    }

    private func selectedOverlayBaseCenter(geometry: GeometryProxy) -> CGPoint {
        CGPoint(
            x: geometry.size.width * 0.5,
            y: (geometry.size.height * 0.5) - 50 + currentRootStageYOffset(geometry: geometry),
        )
    }

    private func selectedOverlayIconCenter(
        geometry: GeometryProxy,
        progress: CGFloat,
    ) -> CGPoint {
        let placement = rootStagePlacement(for: selectedIndex)
        let orbitHorizontalOffset = interpolatedCGFloat(
            from: placement.horizontalOffset,
            to: 0,
            progress: progress,
        )
        let orbitVerticalOffset = interpolatedCGFloat(
            from: placement.verticalOffset,
            to: 0,
            progress: progress,
        )
        let localHorizontalOffset = interpolatedCGFloat(
            from: 0,
            to: landedSelectedHorizontalOffset(geometry: geometry),
            progress: progress,
        )
        let opticalYOffset = selectedCarouselIconOpticalYOffset(for: activeRootItemID ?? menuItems[selectedIndex].id)
        let localVerticalOffset =
            interpolatedCGFloat(
                from: 0,
                to: landedSelectedVerticalOffset + (opticalYOffset * landedIconScale),
                progress: progress,
            ) +
            (submenuHeaderIconOpticalYOffset * progress)
        let baseCenter = selectedOverlayBaseCenter(geometry: geometry)
        return CGPoint(
            x: baseCenter.x + orbitHorizontalOffset + localHorizontalOffset,
            y: baseCenter.y + orbitVerticalOffset + localVerticalOffset,
        )
    }

    private func selectedOverlayRootLabelCenter(geometry: GeometryProxy) -> CGPoint {
        let titleHeight: CGFloat = 92
        return CGPoint(
            x: geometry.size.width * 0.5,
            y: geometry.size.height - 40 - (titleHeight * 0.5),
        )
    }

    private func selectedOverlayHeaderLabelCenter(
        geometry: GeometryProxy,
        title: String,
    ) -> CGPoint {
        let headerIconCenter = selectedOverlayIconCenter(geometry: geometry, progress: 1)
        return CGPoint(
            x: headerIconCenter.x + (landedIconWidth * 0.5) + 24 + (submenuHeaderTitleWidth(for: title) * 0.5),
            y: headerIconCenter.y,
        )
    }

    @ViewBuilder
    func headerTransitionOverlayView(geometry: GeometryProxy) -> some View {
        if showsHeaderTransitionOverlay,
           let activeRootItemID,
           let image = menuImage(forRootID: activeRootItemID),
           menuItems.indices.contains(selectedIndex)
        {
            let progress = smoothStep(selectedOverlayTransitionProgress)
            let labelProgress = smoothStep(submenuTransitionProgress)
            let placement = rootStagePlacement(for: selectedIndex)
            let overlayIconSize = iconSize * selectedCarouselAdjustedSizeMultiplier
            let orbitScale = interpolatedCGFloat(
                from: placement.scale,
                to: 1,
                progress: progress,
            )
            let rootIconScale = placement.baseSizeMultiplier / selectedCarouselAdjustedSizeMultiplier
            let headerIconScale = landedIconScale
            let localIconScale = interpolatedCGFloat(
                from: rootIconScale,
                to: headerIconScale,
                progress: progress,
            )
            let iconScale = orbitScale * localIconScale
            let orbitHorizontalOffset = interpolatedCGFloat(
                from: placement.horizontalOffset,
                to: 0,
                progress: progress,
            )
            let orbitVerticalOffset = interpolatedCGFloat(
                from: placement.verticalOffset,
                to: 0,
                progress: progress,
            )
            let localHorizontalOffset = interpolatedCGFloat(
                from: 0,
                to: landedSelectedHorizontalOffset(geometry: geometry),
                progress: progress,
            )
            let opticalYOffset = selectedCarouselIconOpticalYOffset(for: activeRootItemID)
            let localVerticalOffset =
                interpolatedCGFloat(
                    from: 0,
                    to: landedSelectedVerticalOffset + (opticalYOffset * landedIconScale),
                    progress: progress,
                ) +
                (submenuHeaderIconOpticalYOffset * progress)
            let iconHorizontalOffset = orbitHorizontalOffset + localHorizontalOffset
            let iconVerticalOffset = orbitVerticalOffset + localVerticalOffset
            let reflectionHorizontalOffset = interpolatedCGFloat(
                from: orbitHorizontalOffset,
                to: selectedCarouselDetachedReflectionXOffset - geometry.size.width * 0.05,
                progress: progress,
            )
            let reflectionVerticalOffset = interpolatedCGFloat(
                from: orbitVerticalOffset,
                to: selectedCarouselDetachedReflectionYOffset,
                progress: progress,
            )
            let reflectionScale = iconScale
            let rootStageYOffset = currentRootStageYOffset(geometry: geometry)
            let rootLabelCenter = selectedOverlayRootLabelCenter(geometry: geometry)
            let headerLabelCenter = selectedOverlayHeaderLabelCenter(
                geometry: geometry,
                title: rootLabelText,
            )
            let overlayLabelCenter = CGPoint(
                x: interpolatedCGFloat(
                    from: rootLabelCenter.x,
                    to: headerLabelCenter.x,
                    progress: labelProgress,
                ),
                y: interpolatedCGFloat(
                    from: rootLabelCenter.y,
                    to: headerLabelCenter.y,
                    progress: labelProgress,
                ),
            )
            let reflectionOpacity = max(0, 1 - (progress * 1.2))
            let reflectionRootOffset = selectedCarouselReflectionRootOffset(for: activeRootItemID)
            let carouselReflectionYOffset = reflectionRootOffset + selectedCarouselReflectionYOffset
            let landedReflectionYOffset = (reflectionRootOffset * landedIconScale) + selectedCarouselReflectionYOffset
            let baseReflectionYOffsetOverride = interpolatedCGFloat(from: carouselReflectionYOffset, to: landedReflectionYOffset, progress: progress)
            let reflectionYOffsetAdjustmentConst: CGFloat = -38
            let reflectionYOffsetOverride =
                baseReflectionYOffsetOverride +
                (reflectionYOffsetAdjustmentConst + baseReflectionYOffsetOverride) * (orbitScale - 1)

            ZStack {
                submenuDividerTransitionView(geometry: geometry)

                standardCarouselIconView(
                    image: image,
                    adjustedIconSize: overlayIconSize,
                    scale: reflectionScale,
                    opacity: 1,
                    horizontalOffset: reflectionHorizontalOffset,
                    verticalOffset: reflectionVerticalOffset,
                    isIncoming: false,
                    entryOffset: selectedCarouselEntryOffset,
                    zInd: 3090,
                    isBackground: false,
                    layer: .reflection,
                    showReflection: true,
                    animateReflection: false,
                    reflectionYOffsetOverride: reflectionYOffsetOverride,
                )
                .animation(nil, value: isIconAnimated)
                .padding(.bottom, 100)
                .offset(y: rootStageYOffset)
                .opacity(reflectionOpacity)
                .zIndex(3090)

                standardCarouselIconView(
                    image: image,
                    adjustedIconSize: overlayIconSize,
                    scale: iconScale,
                    opacity: 1,
                    horizontalOffset: iconHorizontalOffset,
                    verticalOffset: iconVerticalOffset,
                    isIncoming: false,
                    entryOffset: selectedCarouselEntryOffset,
                    zInd: 3100,
                    isBackground: false,
                    layer: .icon,
                    showReflection: false,
                    animateReflection: false,
                    reflectionYOffsetOverride: reflectionYOffsetOverride,
                )
                .animation(nil, value: isIconAnimated)
                .padding(.bottom, 100)
                .offset(y: rootStageYOffset)
                .zIndex(3100)

                Text(rootLabelText)
                    .font(.firstRowBold(size: 92))
                    .foregroundStyleCompat(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
                    .id("overlay-root-label")
                    .position(
                        x: overlayLabelCenter.x,
                        y: overlayLabelCenter.y,
                    )
                    .zIndex(3200)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    func submenuHeaderTransitionView(geometry _: GeometryProxy) -> some View {
        EmptyView()
    }

    @ViewBuilder
    func submenuDividerTransitionView(geometry: GeometryProxy) -> some View {
        let progress = smoothStep(submenuTransitionProgress)
        let startBottomOffset = submenuDividerThickness
        let finalBottomOffset = submenuDividerTopInset + submenuDividerThickness - geometry.size.height
        let dividerBottomOffset = interpolatedCGFloat(
            from: startBottomOffset,
            to: finalBottomOffset,
            progress: progress,
        )

        Rectangle()
            .fill(Color.white.opacity(0.96))
            .frame(width: geometry.size.width, height: submenuDividerThickness)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .offset(y: dividerBottomOffset)
    }

    @ViewBuilder
    func settledSubmenuDividerView(geometry: GeometryProxy) -> some View {
        if isInSubmenu, activeRootItemID != nil, !showsHeaderTransitionOverlay {
            Rectangle()
                .fill(Color.white.opacity(0.96))
                .frame(width: geometry.size.width, height: submenuDividerThickness)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, submenuDividerTopInset)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    func submenuPageHeaderView(
        rootID: String?,
        title: String,
        geometry: GeometryProxy,
    ) -> some View {
        if !title.isEmpty {
            let headerLabelCenter = submenuHeaderLabelCenter(
                geometry: geometry,
                rootID: rootID,
                title: title,
            )
            ZStack {
                if let rootID,
                   let image = menuImage(forRootID: rootID)
                {
                    let headerIconCenter = submenuHeaderIconCenter(
                        geometry: geometry,
                        rootID: rootID,
                        title: title,
                    )
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: landedIconWidth, height: landedIconWidth)
                        .position(
                            x: headerIconCenter.x,
                            y: headerIconCenter.y,
                        )
                }

                Text(title)
                    .font(.firstRowBold(size: 92))
                    .foregroundStyleCompat(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .shadow(color: Color.black.opacity(0.55), radius: 5, x: 0, y: 4)
                    .position(
                        x: headerLabelCenter.x,
                        y: headerLabelCenter.y,
                    )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .allowsHitTesting(false)
        }
    }

    func submenuPageView(
        rootID: String?,
        headerText: String,
        items: [MenuListItemConfig],
        selectedIndex: Int,
        geometry: GeometryProxy,
        showsEmbeddedHeader: Bool,
        isMoviesFolderPage: Bool = false,
        isPodcastEpisodesPage: Bool = false,
        isVideoPodcastEpisodesPage: Bool = false,
        isPhotosDateAlbumsPage: Bool = false,
    ) -> some View {
        let pageIdentity =
            "\(rootID ?? "none")::\(headerText)::\(items.count)::\(items.first?.id ?? "nil")::\(items.last?.id ?? "nil")"
        return ZStack(alignment: .topLeading) {
            if isMoviesFolderPage || isVideoPodcastEpisodesPage {
                moviesFolderGapContentView(geometry: geometry)
            }
            menuColumnView(
                rootID: rootID,
                headerText: headerText,
                items: items,
                selectedIndex: selectedIndex,
                geometry: geometry,
                isMoviesFolderPage: isMoviesFolderPage,
                isPodcastEpisodesPage: isPodcastEpisodesPage,
                isVideoPodcastEpisodesPage: isVideoPodcastEpisodesPage,
                isPhotosDateAlbumsPage: isPhotosDateAlbumsPage,
            )
            if showsEmbeddedHeader {
                submenuPageHeaderView(
                    rootID: rootID,
                    title: headerText,
                    geometry: geometry,
                )
            }
        }
        .id(pageIdentity)
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
    }

    @ViewBuilder
    func moviesFolderGapContentView(geometry: GeometryProxy) -> some View {
        let hasContent = moviesFolderGapPlayer != nil
        if hasContent {
            let w = geometry.size.width
            let h = geometry.size.height
            let previewW: CGFloat = 548
            let previewH = previewW / (16.0 / 9.0)
            let reflectionH: CGFloat = 168
            let perspective: CGFloat = 0.75
            let yawDegrees: Double = 23.8
            let imageCenterX: CGFloat = 390
            let imageCenterY = h / 2
            let reflectionGradient = LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            ZStack {
                VStack(spacing: 0) {
                    Group {
                        if let gapPlayer = moviesFolderGapPlayer,
                           let gapPlayerURL = moviesFolderGapPlayerURL
                        {
                            MovieGapPlayerView(player: gapPlayer)
                                .id("movies_gap_main:\(gapPlayerURL.path)")
                                .frame(width: previewW, height: previewH)
                        }
                    }
                    .clipped()
                    Group {
                        if let gapPlayer = moviesFolderGapPlayer,
                           let gapPlayerURL = moviesFolderGapPlayerURL
                        {
                            MovieGapPlayerView(player: gapPlayer)
                                .id("movies_gap_reflection:\(gapPlayerURL.path)")
                                .frame(width: previewW, height: previewH)
                        }
                    }
                    .clipped()
                    .scaleEffect(x: 1, y: -1)
                    .frame(width: previewW, height: reflectionH, alignment: .top)
                    .clipped()
                    .mask(reflectionGradient)
                    .opacity(0.5)
                }
                .rotation3DEffect(.degrees(yawDegrees), axis: (x: 0, y: 1, z: 0), perspective: perspective)
                .position(x: imageCenterX, y: imageCenterY + reflectionH / 2)
            }
            .frame(width: w, height: h)
        }
    }

    @ViewBuilder
    func photosDateAlbumsGapContentView(image: NSImage?, geometry: GeometryProxy) -> some View {
        let w = geometry.size.width
        let h = geometry.size.height
        let imageCenterX: CGFloat = 390
        let imageCenterY = h / 2
        let reflectionH: CGFloat = 168
        ZStack {
            if let image {
                let previewW: CGFloat = 548
                let previewH: CGFloat = previewW * 3.0 / 4.0
                let perspective: CGFloat = 0.75
                let yawDegrees: Double = 23.8
                let reflectionGradient = LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(spacing: 0) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: previewW, height: previewH)
                        .clipped()
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: previewW, height: previewH)
                        .clipped()
                        .scaleEffect(x: 1, y: -1)
                        .frame(width: previewW, height: reflectionH, alignment: .top)
                        .clipped()
                        .mask(reflectionGradient)
                        .opacity(0.5)
                }
                .rotation3DEffect(.degrees(yawDegrees), axis: (x: 0, y: 1, z: 0), perspective: perspective)
                .position(x: imageCenterX, y: imageCenterY + reflectionH / 2)
            } else if let placeholder = NSImage(named: "PhotosSharedPreview") {
                Image(nsImage: placeholder)
                    .resizable()
                    .frame(width: 495, height: 685)
                    .position(x: imageCenterX - 30, y: imageCenterY + reflectionH / 2)
            }
        }
        .frame(width: w, height: h)
    }

    func menuColumnView(
        rootID: String?,
        headerText: String,
        items: [MenuListItemConfig],
        selectedIndex: Int,
        geometry: GeometryProxy,
        isMoviesFolderPage: Bool = false,
        isPodcastEpisodesPage: Bool = false,
        isVideoPodcastEpisodesPage: Bool = false,
        isPhotosDateAlbumsPage: Bool = false,
    ) -> some View {
        _ = rootID
        _ = headerText
        let usesCompactSelectionWidth = isMoviesFolderPage || isVideoPodcastEpisodesPage || isPhotosDateAlbumsPage
        let columnWidth: CGFloat = usesCompactSelectionWidth ? 1225 : submenuSelectionVisualWidth
        let columnLeading: CGFloat = usesCompactSelectionWidth ? 628 : submenuSelectionBoxLeading
        let clampedSelectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        let visibleRowCount = submenuVisibleMenuRowCount
        let transitionProgress = smoothStep(submenuTransitionProgress)

        let listGapBelowDivider = submenuListClipTopInset - (submenuDividerTopInset + submenuDividerThickness)
        let dividerTopEdge = interpolatedCGFloat(
            from: geometry.size.height,
            to: submenuDividerTopInset,
            progress: transitionProgress,
        )
        let listTopInset = dividerTopEdge + submenuDividerThickness + listGapBelowDivider
        let submenuSelectionBoxHeightScale = submenuRowHeight / selectionBoxHeight
        let selectionAnchorY =
            submenuSelectionBoxTopInset -
            submenuListClipTopInset +
            ((submenuSelectionVisualHeight - submenuRowHeight) * 0.5)
        let viewportHeight = min(
            geometry.size.height - submenuListClipTopInset,
            selectionAnchorY +
                (CGFloat(visibleRowCount) * submenuSelectionRowPitch) +
                submenuRowContentVerticalOffset,
        )
        return menuListContainer(
            items: items,
            selectedIndex: clampedSelectedIndex,
            geometry: geometry,
            arrowAppearance: menuArrowAppearance,
            showsTopOverflowFade: false,
            visibleRowCount: visibleRowCount,
            selectionBoxHeightScale: submenuSelectionBoxHeightScale,
            contentWidthOverride: columnWidth,
            selectionVisualWidthOverride: columnWidth,
            selectionVisualHeightOverride: submenuSelectionVisualHeight,
            selectionAnchorY: selectionAnchorY,
            viewportHeightOverride: viewportHeight,
            containerHeightOverride: viewportHeight,
            rowPitchOverride: submenuSelectionRowPitch,
            scaledRowVerticalOffsetOverride: submenuSelectedRowContentYOffset,
            contentVerticalOffsetOverride: submenuRowContentVerticalOffset,
            isPodcastEpisodesPage: isPodcastEpisodesPage,
        )
        .frame(width: columnWidth, height: viewportHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, columnLeading)
        .padding(.top, listTopInset)
    }

    @ViewBuilder
    func submenuStageView(geometry: GeometryProxy) -> some View {
        let liveItems = isInThirdMenu ? thirdMenuListItems() : submenuListItems()
        let liveSelectedIndex = isInThirdMenu ? selectedThirdIndex : selectedSubIndex
        let liveOpacity = isInThirdMenu ? thirdMenuOpacity : submenuOpacity
        let transitionOpacity = Double(smoothStep(submenuTransitionProgress))
        let swapTransitionProgress = smoothStep(menuTransitionProgress)
        let menuSwapTravelDistance = geometry.size.width
        let snapshotOffsetX: CGFloat = {
            switch menuTransitionDirection {
            case .forward:
                return -menuSwapTravelDistance * swapTransitionProgress
            case .backward:
                return menuSwapTravelDistance * swapTransitionProgress
            }
        }()
        let liveOffsetX: CGFloat = {
            switch menuTransitionDirection {
            case .forward:
                return menuSwapTravelDistance * (1 - swapTransitionProgress)
            case .backward:
                return -menuSwapTravelDistance * (1 - swapTransitionProgress)
            }
        }()
        let showsEmbeddedHeader = !showsHeaderTransitionOverlay
        let isLiveNowPlaying = isInThirdMenu && thirdMenuMode == .musicNowPlaying
        let isLiveErrorPage = isInThirdMenu && thirdMenuMode == .errorPage
        let isLiveSubmenuErrorPage = !isInThirdMenu && isSubmenuErrorPage
        let isLiveMoviesFolder = isInThirdMenu && thirdMenuMode == .moviesFolder
        let isLiveVideoPodcastEpisodes = isInThirdMenu && thirdMenuMode == .videoPodcastEpisodes
        ZStack {
            settledSubmenuDividerView(geometry: geometry)
            if let snapshot = menuTransitionSnapshot {
                if snapshot.isNowPlayingPage {
                    ZStack(alignment: .topLeading) {
                        musicNowPlayingMenuPageView(geometry: geometry)
                        if showsEmbeddedHeader {
                            submenuPageHeaderView(
                                rootID: snapshot.rootID,
                                title: snapshot.headerText,
                                geometry: geometry,
                            )
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .offset(x: snapshotOffsetX)
                } else if snapshot.isErrorPage || snapshot.isSubmenuErrorPage {
                    ZStack(alignment: .topLeading) {
                        errorPageMenuView(geometry: geometry)
                        if showsEmbeddedHeader {
                            submenuPageHeaderView(
                                rootID: snapshot.rootID,
                                title: snapshot.headerText,
                                geometry: geometry,
                            )
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .offset(x: snapshotOffsetX)
                } else {
                    submenuPageView(
                        rootID: snapshot.rootID,
                        headerText: snapshot.headerText,
                        items: snapshot.items,
                        selectedIndex: snapshot.selectedIndex,
                        geometry: geometry,
                        showsEmbeddedHeader: showsEmbeddedHeader,
                        isMoviesFolderPage: snapshot.isMoviesFolderPage,
                        isPodcastEpisodesPage: snapshot.isPodcastEpisodesPage,
                        isVideoPodcastEpisodesPage: snapshot.isVideoPodcastEpisodesPage,
                        isPhotosDateAlbumsPage: snapshot.isPhotosDateAlbumsPage,
                    )
                    .offset(x: snapshotOffsetX)
                }
            }
            if isLiveNowPlaying {
                ZStack(alignment: .topLeading) {
                    musicNowPlayingMenuPageView(geometry: geometry)
                    if showsEmbeddedHeader {
                        submenuPageHeaderView(
                            rootID: activeRootItemID,
                            title: headerText,
                            geometry: geometry,
                        )
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .offset(x: menuTransitionSnapshot == nil ? 0 : liveOffsetX)
                .opacity(
                    menuTransitionSnapshot == nil
                        ? max(liveOpacity, transitionOpacity)
                        : 1,
                )
            } else if isLiveErrorPage || isLiveSubmenuErrorPage {
                ZStack(alignment: .topLeading) {
                    errorPageMenuView(geometry: geometry)
                    if showsEmbeddedHeader {
                        submenuPageHeaderView(
                            rootID: activeRootItemID,
                            title: headerText,
                            geometry: geometry,
                        )
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .offset(x: menuTransitionSnapshot == nil ? 0 : liveOffsetX)
                .opacity(
                    menuTransitionSnapshot == nil
                        ? (isEnteringSubmenu || isReturningToRoot ? 1 : max(liveOpacity, transitionOpacity))
                        : 1,
                )
            } else {
                submenuPageView(
                    rootID: activeRootItemID,
                    headerText: headerText,
                    items: liveItems,
                    selectedIndex: liveSelectedIndex,
                    geometry: geometry,
                    showsEmbeddedHeader: showsEmbeddedHeader,
                    isMoviesFolderPage: isLiveMoviesFolder,
                    isPodcastEpisodesPage: isInThirdMenu &&
                        (thirdMenuMode == .audioPodcastEpisodes || thirdMenuMode == .videoPodcastEpisodes),
                    isVideoPodcastEpisodesPage: isLiveVideoPodcastEpisodes,
                    isPhotosDateAlbumsPage: activeRootItemID == "photos",
                )
                .offset(x: menuTransitionSnapshot == nil ? 0 : liveOffsetX)
                .opacity(
                    menuTransitionSnapshot == nil
                        ? (isEnteringSubmenu || isReturningToRoot ? 1 : max(liveOpacity, transitionOpacity))
                        : 1,
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: liveOpacity)
    }

    @ViewBuilder
    func photosGapPreviewOverlayView(geometry: GeometryProxy) -> some View {
        if isInSubmenu || isEnteringSubmenu || isReturningToRoot {
            let swapTransitionProgress = smoothStep(menuTransitionProgress)
            let travelDistance = geometry.size.width
            let snapshotOffsetX: CGFloat = menuTransitionDirection == .forward
                ? -travelDistance * swapTransitionProgress
                : travelDistance * swapTransitionProgress
            let liveOffsetX: CGFloat = menuTransitionDirection == .forward
                ? travelDistance * (1 - swapTransitionProgress)
                : -travelDistance * (1 - swapTransitionProgress)
            if let snapshot = menuTransitionSnapshot, snapshot.isPhotosDateAlbumsPage,
               !snapshot.isSubmenuErrorPage, !snapshot.isErrorPage {
                photosDateAlbumsGapContentView(image: snapshot.photosGapPreviewImage, geometry: geometry)
                    .offset(x: snapshotOffsetX)
            }
            if activeRootItemID == "photos", !isSubmenuErrorPage, !(isInThirdMenu && thirdMenuMode == .errorPage) {
                if menuTransitionSnapshot != nil {
                    photosDateAlbumsGapContentView(image: photosGapPreviewImage, geometry: geometry)
                        .offset(x: liveOffsetX)
                } else {
                    photosDateAlbumsGapContentView(image: photosGapPreviewImage, geometry: geometry)
                        .offset(x: isPhotosGapPreviewSlid ? 0 : -(390 + 548))
                        .animation(.easeInOut(duration: 1.0), value: isPhotosGapPreviewSlid)
                }
            }
        }
    }

    func menuScene(geometry: GeometryProxy) -> some View {
        ZStack {
            rootBackdropView(geometry: geometry)
            introBackdropView(geometry: geometry)
            rootStageView(geometry: geometry)
            if isInSubmenu || isEnteringSubmenu || isReturningToRoot {
                submenuStageView(geometry: geometry)
                    .opacity(menuSceneOpacity)
            }
            headerTransitionOverlayView(geometry: geometry)
            rootLabelView(geometry: geometry)
            photosGapPreviewOverlayView(geometry: geometry)
                .opacity(menuSceneOpacity)
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        .coordinateSpace(name: "menuSceneSpace")
    }
}
