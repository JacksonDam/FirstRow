import SwiftUI
#if os(iOS)
    import UIKit
#endif

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
    static let iPad = CGSize(width: 1440, height: 1080)

    static func scaledX(_ value: CGFloat, for virtualSize: CGSize) -> CGFloat {
        guard widescreen.width > 0 else { return value }
        return value * (virtualSize.width / widescreen.width)
    }

    static func additionalMenuGapX(for virtualSize: CGSize) -> CGFloat {
        virtualSize == iPad ? 56 : 0
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
            let effectiveSubmenuTitleOpacity = shouldHidePodcastsSubmenuChromeUntilLoadCompletes
                ? 0
                : submenuTitleOpacity
            Text(headerText).font(.firstRowBold(size: 60)).foregroundStyleCompat(.white).opacity(effectiveSubmenuTitleOpacity).offset(x: firstRowHeaderOffsetX(geometry: geometry) + (landedIconWidth * 0.6)).offset(y: menuHeaderVerticalOffset).animation(.easeInOut(duration: 0.25), value: submenuTitleOpacity).animation(.easeInOut(duration: 0.22), value: shouldHidePodcastsSubmenuChromeUntilLoadCompletes)
        } else {
            Text(headerText).font(.firstRowBold(size: 60)).foregroundStyleCompat(.white).offset(x: rootMenuHeaderOffsetX(geometry: geometry)).offset(y: menuHeaderVerticalOffset).opacity(headerOpacity).animation(.easeInOut(duration: 0.25), value: headerOpacity)
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
                        Text(option).font(.firstRowBold(size: 45)).foregroundStyleCompat(.white).lineLimit(1).minimumScaleFactor(0.72).allowsTightening(true).frame(width: optionWidth, height: optionHeight, alignment: .leading).padding(.leading, optionTextInset).opacity((hideSelectedText || hideUnselectedText) ? 0 : 1)
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
        let isPhotosSubmenu = activeRootItemID == "photos"
        let tvShowsSubmenuListTopInset: CGFloat =
            (activeRootItemID == "tv_shows" && (isInSubmenu || isEnteringSubmenu)) ? 91 : 0
        let effectiveSubmenuOpacity = shouldHideSubmenuListUntilLoadCompletes ? 0 : submenuOpacity
        let effectiveThirdMenuOpacity = shouldHideThirdMenuListUntilLoadCompletes ? 0 : thirdMenuOpacity
        return ZStack(alignment: .topLeading) {
            menuListContainer(
                items: rootMenuItems,
                selectedIndex: selectedIndex,
                geometry: geometry,
                arrowAppearance: menuArrowAppearance,
                showsTopOverflowFade: true,
                visibleRowCount: defaultVisibleMenuRowCount,
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
                ).opacity(effectiveSubmenuOpacity).offset(y: tvShowsSubmenuListTopInset).animation(.none, value: tvShowsSubmenuListTopInset).animation(.easeInOut(duration: 0.18), value: shouldHideSubmenuListUntilLoadCompletes)
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
                    usesUniformRowLayout: thirdMenuMode == .musicSongs,
                ).opacity(effectiveThirdMenuOpacity).animation(.easeInOut(duration: 0.18), value: shouldHideThirdMenuListUntilLoadCompletes)
            }
            if shouldShowTVShowsSortPill {
                tvShowsSortPillView().frame(width: menuWidthConstrained(geometry: geometry), alignment: .center).offset(y: 6).transition(.opacity).animation(.easeInOut(duration: 0.2), value: shouldShowTVShowsSortPill)
            }
        }.frame(height: stableMenuListLayoutHeight, alignment: .top)
    }

    var shouldShowTVShowsSortPill: Bool {
        activeRootItemID == "tv_shows" &&
            isInSubmenu &&
            !isInThirdMenu &&
            submenuOpacity > 0.001
    }

    @ViewBuilder
    func tvShowsSortPillView() -> some View {
        let pillWidth: CGFloat = 209
        let pillHeight: CGFloat = 28
        let segmentWidth = pillWidth * 0.5
        let selectedX = tvShowsSortMode == .date ? -(segmentWidth * 0.5) : (segmentWidth * 0.5)
        let usesDateSelection = tvShowsSortMode == .date
        ZStack {
            Capsule(style: .continuous).fill(
                LinearGradient(
                    gradient: Gradient(stops: [.init(color: Color(red: 30 / 255, green: 45 / 255, blue: 60 / 255), location: 0.0), .init(color: Color(red: 2 / 255, green: 6 / 255, blue: 8 / 255), location: 1.0)]),
                    startPoint: .top,
                    endPoint: .bottom,
                ),
            ).overlay(LinearGradient(
                gradient: Gradient(stops: [.init(color: .white.opacity(0.30), location: 0.0), .init(color: .white.opacity(0.12), location: 0.34), .init(color: .clear, location: 0.92)]),
                startPoint: .top,
                endPoint: .bottom,
            ).mask(
                TVShowsSortPillUpperGlossMask().fill(Color.white).blur(radius: 0.45),
            ))
            TVShowsSortPillSelectionShape(
                roundsLeftSide: usesDateSelection,
                roundsRightSide: !usesDateSelection,
            ).fill(
                LinearGradient(
                    gradient: Gradient(stops: [.init(color: Color(red: 70 / 255, green: 120 / 255, blue: 180 / 255), location: 0.0), .init(color: Color(red: 70 / 255, green: 112 / 255, blue: 165 / 255), location: 1.0)]),
                    startPoint: .top,
                    endPoint: .bottom,
                ),
            ).overlay(LinearGradient(
                gradient: Gradient(stops: [.init(color: .white.opacity(0.30), location: 0.0), .init(color: .white.opacity(0.12), location: 0.34), .init(color: .clear, location: 0.9)]),
                startPoint: .top,
                endPoint: .bottom,
            ).mask(
                TVShowsSortPillUpperGlossMask().fill(Color.white).blur(radius: 0.45),
            ).clipShape(
                TVShowsSortPillSelectionShape(
                    roundsLeftSide: usesDateSelection,
                    roundsRightSide: !usesDateSelection,
                ),
            )).frame(width: segmentWidth, height: pillHeight).offset(x: selectedX)
            Rectangle().fill(Color.black.opacity(0.34)).frame(width: 1, height: pillHeight - 10)
            HStack(spacing: 0) {
                Text("Date").font(.custom("Lucida Grande", size: 20)).foregroundStyleCompat(tvShowsSortMode == .date ? .white : Color.white.opacity(0.56)).frame(width: segmentWidth, height: pillHeight, alignment: .center)
                Text("Show").font(.custom("Lucida Grande", size: 20)).foregroundStyleCompat(tvShowsSortMode == .show ? .white : Color.white.opacity(0.56)).frame(width: segmentWidth, height: pillHeight, alignment: .center)
            }
        }.frame(width: pillWidth, height: pillHeight).clipShape(Capsule(style: .continuous)).overlay(
            Capsule(style: .continuous).stroke(Color(red: 82 / 255, green: 147 / 255, blue: 221 / 255).opacity(0.96), lineWidth: 2),
        ).accessibilityHidden(true)
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
        usesUniformRowLayout: Bool = false,
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
        let rowOffsets: [CGFloat]
        let contentHeight: CGFloat
        let viewportHeight = menuViewportHeight(for: visibleRowCount)
        let scrollOffset: CGFloat
        let selectedRowOffset: CGFloat
        if usesUniformRowLayout {
            rowOffsets = []
            let n = items.count
            contentHeight = n > 0 ? CGFloat(n - 1) * rowPitch + selectionHeight : 0
            if contentHeight > viewportHeight, n > 0 {
                let clampedAnchor = min(max(0, stickySelectionRowIndex), n - 1)
                let anchorY = CGFloat(clampedAnchor) * rowPitch
                let selectedY = CGFloat(max(0, min(selectedIndex, n - 1))) * rowPitch
                let rawOffset = anchorY - selectedY
                let minOffset = viewportHeight - contentHeight
                scrollOffset = max(minOffset, min(0, rawOffset))
            } else {
                scrollOffset = 0
            }
            selectedRowOffset = CGFloat(max(0, min(selectedIndex, items.count - 1))) * rowPitch
        } else {
            rowOffsets = menuRowOffsets(for: items, dividerGap: dividerGap, rowPitch: rowPitch, normalHeightIndices: normalHeightIndices)
            contentHeight = menuContentHeight(for: items, rowOffsets: rowOffsets, rowHeight: selectionHeight)
            scrollOffset = menuScrollOffset(contentHeight: contentHeight, selectedIndex: selectedIndex, rowOffsets: rowOffsets, viewportHeight: viewportHeight)
            selectedRowOffset = rowOffsets.indices.contains(selectedIndex) ? rowOffsets[selectedIndex] : 0
        }
        let renderRange: Range<Int>
        if usesUniformRowLayout, !items.isEmpty {
            let overscanPadding = max(80, rowPitch * (activeDirectionalHoldKey != .none ? 6.0 : 2.5))
            let minVisibleY = -scrollOffset - overscanPadding
            let maxVisibleY = -scrollOffset + viewportHeight + overscanPadding
            let minIdx = max(0, Int(floor(minVisibleY / rowPitch)))
            let maxIdx = min(items.count - 1, Int(ceil(maxVisibleY / rowPitch)))
            renderRange = minIdx..<(maxIdx + 1)
        } else {
            renderRange = 0..<items.count
        }
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
        return ZStack(alignment: .topLeading) {
            if !items.isEmpty {
                selectionBox(width: effectiveSelectionVisualWidth, height: effectiveSelectionVisualHeight).offset(
                    x: effectiveSelectionVisualXOffset,
                    y: selectedRowOffset + scrollOffset + effectiveSelectionVisualYOffset,
                ).animation(selectionMovementAnimation, value: selectedRowOffset).animation(selectionMovementAnimation, value: scrollOffset)
            }
            ZStack(alignment: .topLeading) {
                ForEach(renderRange, id: \.self) { index in
                    let item = items[index]
                    let rowIsSelected = index == selectedIndex
                    let rowIsNormalHeight = normalHeightIndices.contains(index)
                    let rowHeight = rowIsNormalHeight ? selectionBoxHeight : selectionHeight
                    let rowYOffset = rowIsNormalHeight ? 0 : selectionYOffset
                    let rowYBase = usesUniformRowLayout ? CGFloat(index) * rowPitch : rowOffsets[index]

                    if item.showsTopDivider {
                        Rectangle()
                            .fill(Color.white.opacity(0.34))
                            .frame(width: max(0, rowContentWidth - (dividerLineInsetHorizontal * 2)), height: 1)
                            .offset(
                                x: rowContentXOffset + dividerLineInsetHorizontal,
                                y: rowYBase - dividerGap + dividerLineYOffsetInGap,
                            )
                    }

                    if item.showsLightRowBackground {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                Rectangle().stroke(Color.white.opacity(0.02), lineWidth: 1),
                            )
                            .frame(
                                width: selectionWidth,
                                height: rowHeight,
                            )
                            .offset(
                                x: selectionXOffset,
                                y: rowYBase + rowYOffset,
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
                            (thirdMenuMode == .musicSongs &&
                             activeMusicPlaybackSongID == item.id &&
                             hasActiveMusicPlaybackSession()) ||
                            (thirdMenuMode == .podcastsEpisodes &&
                             isPodcastAudioNowPlaying &&
                             activePodcastPlaybackEpisodeID == item.id),
                        showsBlueDot: item.showsBlueDot,
                        alignsTextToDividerStart: item.alignsTextToDividerStart,
                        arrowAppearance: arrowAppearance,
                    )
                    .frame(width: rowContentWidth, height: rowHeight, alignment: .leading)
                    .offset(
                        x: rowContentXOffset,
                        y: rowYBase + rowYOffset,
                    )
                }
            }
            .offset(y: scrollOffset)
            .animation(selectionMovementAnimation, value: selectedIndex)
            .frame(height: viewportHeight, alignment: .top)
            .mask(
                Rectangle().frame(width: 5000, height: viewportHeight),
            )
        }.frame(height: viewportHeight, alignment: .top)
            .overlay(
                Group {
                    if showsTopOverflowFade {
                        LinearGradient(
                            colors: [.black, .black.opacity(0.78), .clear],
                            startPoint: .top,
                            endPoint: .bottom,
                        ).frame(height: submenuTopFadeHeight).opacity(isMenuOverflowScrollingUp ? 1 : 0).animation(.easeInOut(duration: 0.12), value: isMenuOverflowScrollingUp).allowsHitTesting(false)
                    }
                },
                alignment: .top,
            )
            .overlay(
                Group {
                    if showsTopOverflowFade {
                        LinearGradient(
                            colors: [.black, .black.opacity(0.78), .clear],
                            startPoint: .bottom,
                            endPoint: .top,
                        ).frame(height: submenuTopFadeHeight).opacity(isMenuOverflowScrollingDown ? 1 : 0).animation(.easeInOut(duration: 0.12), value: isMenuOverflowScrollingDown).allowsHitTesting(false)
                    }
                },
                alignment: .bottom,
            )
            .frame(width: menuWidth, height: menuListLayoutHeight(for: visibleRowCount), alignment: .topLeading)
            .background(
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
            }.frame(width: width, height: height)
        } else {
            EmptyView()
        }
    }
    // MARK: - Layout geometry

    func visibleIndices() -> [Int] {
        let indices = [0, 1, 2, 3, 4, 5, 6].map { offset in
            (selectedIndex + offset + menuItems.count) % menuItems.count
        }
        return indices.reversed()
    }

    func carouselWidth(geometry: GeometryProxy) -> CGFloat {
        min(
            iconSize * CGFloat(menuItems.count) + iconSpacing * CGFloat(menuItems.count - 1),
            baselineLayoutWidth(geometry: geometry) * 0.67,
        )
    }

    func carouselOffsetY() -> CGFloat {
        -arcRadius * 0.3 * 1.5
    }

    func landedSelectedHorizontalOffset(geometry: GeometryProxy) -> CGFloat {
        let titleLeadingX = submenuHeaderTitleLeadingGlobalX(geometry: geometry)
        let iconHalfWidth = landedIconWidth * 0.5
        let desiredGap: CGFloat = -50
        let baselineWidth = baselineLayoutWidth(geometry: geometry)
        let carouselLaneWidth = carouselWidth(geometry: geometry)
        let carouselContainerOffsetX = MenuVirtualScenePreset.scaledX(
            20,
            for: activeMenuVirtualSceneSize,
        )
        let carouselCenterX = (-baselineWidth * 0.5) + (carouselLaneWidth * 0.5) + carouselContainerOffsetX
        return titleLeadingX - desiredGap - iconHalfWidth - carouselCenterX
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
        min(menuWidth, baselineLayoutWidth(geometry: geometry) * 0.35 + 100)
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

    func carouselItemView(for index: Int, geometry: GeometryProxy) -> some View {
        let position = CGFloat(index - selectedIndex)
        let angle = position * .pi / 6
        var horizontalOffset: CGFloat
        var verticalOffset: CGFloat
        var zInd: CGFloat
        let scale = position == 0 && isIconAnimated ? landedIconScale : (1.0 - (abs(position) * scaleReduction))
        if position == 0 && isIconAnimated {
            horizontalOffset = landedSelectedHorizontalOffset(geometry: geometry)
            verticalOffset = landedSelectedVerticalOffset
            zInd = 1000
        } else if position == 0 {
            horizontalOffset = -1.25 * arcRadius * sin(angle) * 1.5 + restingSelectedHorizontalOffset
            verticalOffset = restingSelectedVerticalOffset
            zInd = 0
        } else if position == 1 || position == 2 || position == 3 {
            horizontalOffset = -1.25 * arcRadius * sin(angle) * 0.9 - (0.1 * iconSize)
            verticalOffset = -arcRadius * (1 - cos(angle)) * 0.025 + (position < 2 ? (0.2 * iconSize) : (0.15 * iconSize))
            zInd = 0
        } else {
            horizontalOffset = -1920
            verticalOffset = 1280
            zInd = 1000
        }
        if isEnteringSubmenu && position != 0 {
            horizontalOffset -= max(geometry.size.width * 1.15, iconSize * 3.0)
        }
        let baseOpacity: CGFloat = position == 0 ? 1.0 : (abs(position) <= 2 ? 1.0 : 1.0 - (abs(position) * 0.4))
        let opacity = isEnteringSubmenu && position != 0 ? max(0.0, baseOpacity - 0.95) : baseOpacity
        let isIncoming = position == 0 && !isIconAnimated
        let entryOffset = selectedCarouselEntryOffset
        let isBackground = abs(position) > 0
        let adjustedIconSize: CGFloat =
            abs(position) == 1 || abs(position) == 2 ? iconSize * 1 : iconSize * selectedCarouselAdjustedSizeMultiplier
        let reflectionCompensationX =
            (position == 0 && (isIconAnimated || isEnteringSubmenu))
                ? (horizontalOffset - restingSelectedHorizontalOffset)
                : 0
        let reflectionCompensationY =
            (position == 0 && (isIconAnimated || isEnteringSubmenu))
                ? (verticalOffset - restingSelectedVerticalOffset)
                : 0
        return Group {
            if let image = menuImage(forRootID: menuItems[index].id) {
                standardCarouselIconView(
                    image: image,
                    adjustedIconSize: adjustedIconSize,
                    scale: scale,
                    opacity: opacity,
                    horizontalOffset: horizontalOffset,
                    verticalOffset: verticalOffset,
                    isIncoming: isIncoming,
                    entryOffset: entryOffset,
                    zInd: zInd,
                    isBackground: isBackground,
                    showReflection: !(position == 0 && isInSubmenu && !isEnteringSubmenu && !isReturningToRoot),
                    animateReflection: position == 0 && (!isInSubmenu || isEnteringSubmenu || isReturningToRoot),
                    reflectionCompensationX: reflectionCompensationX,
                    reflectionCompensationY: reflectionCompensationY,
                )
            }
        }.padding(.bottom, 100)
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
        showReflection: Bool = true,
        animateReflection: Bool = false,
        reflectionCompensationX: CGFloat = 0,
        reflectionCompensationY: CGFloat = 0,
    ) -> some View {
        let baseX = horizontalOffset + (isIncoming ? -entryOffset : 0)
        let baseY = verticalOffset + (isIncoming ? entryOffset : 0)
        let usesDetachedReflection = animateReflection &&
            ((isEnteringSubmenu && !isReturningToRoot) || (isReturningToRoot && isIconAnimated))
        let reflectionX = usesDetachedReflection ? 90.0 : 0.0
        let reflectionY = usesDetachedReflection ? 920.0 : -(adjustedIconSize * 0.215)
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
                        gradient: Gradient(stops: [.init(color: .white, location: 0.0), .init(color: .clear, location: 0.6)]),
                        startPoint: .bottom,
                        endPoint: .top,
                    ),
                ).scaleEffect(x: 1.0, y: -1.0, anchor: .bottom).opacity(reflectionOpacity).offset(
                    x: reflectionX - (usesDetachedReflection ? reflectionCompensationX : 0),
                    y: reflectionY - (usesDetachedReflection ? reflectionCompensationY : 0),
                ).blur(radius: reflectionBlur).scaleEffect(usesDetachedReflection ? 1.0 : scale)
            }
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: adjustedIconSize, height: adjustedIconSize).scaleEffect(scale)
        }.opacity(opacity).offset(x: baseX, y: baseY).zIndex(isIncoming ? 1 : zInd).blur(radius: isBackground ? 10 : 0).animation(.easeInOut(duration: selectionAnimationDuration * 0.85), value: selectedIndex).animation(.easeInOut(duration: backgroundIconTransitionDuration), value: isEnteringSubmenu && isBackground).animation(.easeInOut(duration: iconFlightAnimationDuration), value: isIconAnimated)
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
        let trailingFontSize: CGFloat = isDotTrail ? 17 : 32
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
                Image(systemName: "speaker.wave.3.fill").foregroundStyleCompat(.white).font(.system(size: 34, weight: .semibold)).shadow(
                    color: isPlaybackSpeakerGlowing ? .white.opacity(0.9) : .clear,
                    radius: isPlaybackSpeakerGlowing ? 4.5 : 0,
                ).shadow(
                    color: isPlaybackSpeakerGlowing ? .white.opacity(0.45) : .clear,
                    radius: isPlaybackSpeakerGlowing ? 10 : 0,
                ).frame(width: trailingColumnWidth, alignment: .trailing).offset(x: arrowAppearance.xOffset)
            } else if let trailingSymbolName {
                Image(systemName: trailingSymbolName).foregroundStyleCompat(.white).font(.system(size: 34, weight: .semibold)).opacity(trailingTextOpacity).arrowGlow(isTrailingSymbolGlowing, arrowAppearance).frame(width: trailingColumnWidth, alignment: .trailing).offset(x: arrowAppearance.xOffset)
            } else if let resolvedTrailingText, showsArrow {
                HStack(spacing: trailingToArrowSpacing) {
                    if isDotTrail {
                        LazyHStack(spacing: 1.3) {
                            ForEach(0 ..< 3, id: \.self) { _ in
                                Capsule(style: .continuous).fill(Color.white).frame(width: 6.2, height: 4.1)
                            }
                        }.opacity(trailingTextOpacity).offset(x: 8, y: -0.3).arrowGlow(isArrowGlowing, arrowAppearance)
                    } else {
                        Text(resolvedTrailingText).font(.firstRowRegular(size: trailingFontSize)).foregroundStyleCompat(.white).opacity(trailingTextOpacity).lineLimit(1).minimumScaleFactor(0.65).allowsTightening(true).offset(y: trailingVerticalOffset)
                    }
                    Image(systemName: arrowAppearance.symbolName).foregroundStyleCompat(arrowAppearance.color).font(.system(size: arrowAppearance.fontSize, weight: arrowAppearance.fontWeight)).opacity(trailingTextOpacity).arrowGlow(isArrowGlowing, arrowAppearance)
                }.frame(width: trailingColumnWidth, alignment: .trailing).offset(x: symmetricArrowXOffset)
            } else if let resolvedTrailingText {
                Text(resolvedTrailingText).font(.firstRowRegular(size: 32)).foregroundStyleCompat(.white).opacity(trailingTextOpacity).lineLimit(1).minimumScaleFactor(0.65).allowsTightening(true).frame(width: trailingColumnWidth, alignment: .trailing).offset(x: arrowAppearance.xOffset)
            } else if showsArrow {
                Image(systemName: arrowAppearance.symbolName).foregroundStyleCompat(arrowAppearance.color).font(.system(size: arrowAppearance.fontSize, weight: arrowAppearance.fontWeight)).opacity(trailingTextOpacity).arrowGlow(isArrowGlowing, arrowAppearance).frame(width: trailingColumnWidth, alignment: .trailing).offset(x: symmetricArrowXOffset)
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
        let font = NSFont(name: firstRowBoldFontName, size: 40) ?? NSFont.boldSystemFont(ofSize: 40)
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
                .font(.firstRowBold(size: 40))
                .foregroundStyleCompat(.white)
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

private struct TVShowsSortPillUpperGlossMask: Shape {
    func path(in rect: CGRect) -> Path {
        let sideCurveWidth = rect.width * 0.085
        let topEdgeY = rect.minY + rect.height * 0.03
        let sideBottomY = rect.minY + rect.height * 0.12
        let flatBottomY = rect.minY + rect.height * 0.57
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: topEdgeY))
        path.addLine(to: CGPoint(x: rect.maxX, y: topEdgeY))
        path.addLine(to: CGPoint(x: rect.maxX, y: sideBottomY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - sideCurveWidth, y: flatBottomY),
            control: CGPoint(x: rect.maxX - (sideCurveWidth * 0.12), y: flatBottomY),
        )
        path.addLine(to: CGPoint(x: rect.minX + sideCurveWidth, y: flatBottomY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: sideBottomY),
            control: CGPoint(x: rect.minX + (sideCurveWidth * 0.12), y: flatBottomY),
        )
        path.closeSubpath()
        return path
    }
}

private struct TVShowsSortPillSelectionShape: Shape {
    let roundsLeftSide: Bool
    let roundsRightSide: Bool
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.height * 0.5, rect.width * 0.5)
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        var path = Path()
        path.move(to: CGPoint(x: roundsLeftSide ? minX + radius : minX, y: minY))
        path.addLine(to: CGPoint(x: roundsRightSide ? maxX - radius : maxX, y: minY))
        if roundsRightSide {
            path.addArc(
                center: CGPoint(x: maxX - radius, y: minY + radius),
                radius: radius,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false,
            )
            path.addLine(to: CGPoint(x: maxX, y: maxY - radius))
            path.addArc(
                center: CGPoint(x: maxX - radius, y: maxY - radius),
                radius: radius,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false,
            )
        } else {
            path.addLine(to: CGPoint(x: maxX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: maxY))
        }
        path.addLine(to: CGPoint(x: roundsLeftSide ? minX + radius : minX, y: maxY))
        if roundsLeftSide {
            path.addArc(
                center: CGPoint(x: minX + radius, y: maxY - radius),
                radius: radius,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false,
            )
            path.addLine(to: CGPoint(x: minX, y: minY + radius))
            path.addArc(
                center: CGPoint(x: minX + radius, y: minY + radius),
                radius: radius,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false,
            )
        } else {
            path.addLine(to: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: minX, y: minY))
        }
        path.closeSubpath()
        return path
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
    @State private var marqueeRestartWorkItem: Task<Void, Never>?
    private var measuredWidth: CGFloat {
        let font = NSFont(name: firstRowBoldFontName, size: 40) ?? NSFont.boldSystemFont(ofSize: 40)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    var body: some View {
        let safeViewportWidth = max(1, viewportWidth)
        let edgeFadeFraction = min(0.5, max(0, edgeFadeWidth / safeViewportWidth))
        HStack(spacing: gap) {
            Text(title).font(.firstRowBold(size: 40)).foregroundStyleCompat(.white).lineLimit(1).allowsTightening(true).fixedSize(horizontal: true, vertical: false)
            Text(title).font(.firstRowBold(size: 40)).foregroundStyleCompat(.white).lineLimit(1).allowsTightening(true).fixedSize(horizontal: true, vertical: false)
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
        }).onDisappear {
            marqueeRestartWorkItem?.cancel()
            marqueeRestartWorkItem = nil
        }
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
        marqueeRestartWorkItem?.cancel()
        marqueeRestartWorkItem = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
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

    var activeMenuVirtualSceneSize: CGSize {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom == .pad
                ? MenuVirtualScenePreset.iPad
                : MenuVirtualScenePreset.widescreen
        #else
            MenuVirtualScenePreset.widescreen
        #endif
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
                #if os(iOS)
                .overlay {
                    TouchNavigationInputOverlay(
                        onArrowKeyDown: { key in handleDirectionalPressBegan(key) },
                        onArrowKeyUp: { key in handleDirectionalPressEnded(key) },
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
                        onSingleFingerTap: {
                            guard activeFullscreenScene?.key == screenSaverFullscreenKey else { return false }
                            dismissScreenSaverForUserInteraction()
                            return true
                        },
                    ).ignoresSafeArea()
                }
                #endif
                #if os(tvOS)
                .overlay {
                    TVRemoteInputOverlay(
                        onKeyDown: { key in
                            if key == .upArrow || key == .downArrow || key == .leftArrow || key == .rightArrow {
                                handleDirectionalPressBegan(key)
                            } else {
                                endDirectionalHoldSession()
                                handleKeyInput(key, isRepeat: false, modifiers: [])
                            }
                        },
                        onKeyUp: { key in
                            handleDirectionalPressEnded(key)
                        },
                    ).ignoresSafeArea()
                }
                #endif
                #if os(iOS) || os(tvOS)
                .overlay {
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
                    ).ignoresSafeArea().allowsHitTesting(false)
                }
                #endif
                #if os(macOS)
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
                #endif
                .onAppear {
                    beginStartupMusicLibraryPreloadIfNeeded()
                    registerUserInteractionForScreenSaver()
                    startScreenSaverIdleMonitor()
                    startupSoundWarmUpWorkItem?.cancel()
                    startupSoundWarmUpWorkItem = Task {
                        try? await firstRowSleep(0.75)
                        guard !Task.isCancelled else { return }
                        SoundEffectPlayer.shared.warmUp(soundNames: ["Selection", "SelectionChange", "Exit", "Limit"])
                    }
                }.onDisappear {
                    startupSoundWarmUpWorkItem?.cancel()
                    startupSoundWarmUpWorkItem = nil
                    endDirectionalHoldSession()
                    stopScreenSaverIdleMonitor()
                }
            }
            if startupMusicLibraryPreloadOverlayOpacity > 0.001 {
                Color.black
                    .opacity(startupMusicLibraryPreloadOverlayOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(true)
            }
        }.ignoresSafeArea()
        #if os(iOS)
            .sheet(isPresented: $isMoviesFolderPickerPresented) {
                IOSFolderPicker(
                    onPick: { selectedURL in
                        handleMoviesFolderPickedFromFiles(selectedURL)
                    },
                    onCancel: {
                        hasPromptedMoviesFolderPickerThisSession = false
                    },
                ).ignoresSafeArea()
            }
        #endif
    }

    @ViewBuilder
    func menuLayoutContainer(in geometry: GeometryProxy) -> some View {
        #if os(iOS)
            let virtualSize = activeMenuVirtualSceneSize
            let scale = geometry.size.height / virtualSize.height
            let screenBounds = activeWindowScreen?.bounds ?? .zero
            let deviceLandscapeWidth = max(screenBounds.width, screenBounds.height)
            let horizontalCompensation = max(0, (deviceLandscapeWidth - geometry.size.width) * 0.5)
            let fullscreenContainerSize = {
                let resolved = activeFullscreenContainerSize
                guard resolved.width > 0, resolved.height > 0 else { return geometry.size }
                return resolved
            }()
            ZStack {
                GeometryReader { virtualGeometry in
                    menuScene(geometry: virtualGeometry)
                }.frame(width: virtualSize.width, height: virtualSize.height).scaleEffect(scale, anchor: .center).frame(width: geometry.size.width, height: geometry.size.height).offset(x: -horizontalCompensation)
                fullscreenPresentationLayers(containerSize: fullscreenContainerSize)
                menuDisplayFadeOverlays(containerSize: fullscreenContainerSize)
            }
        #elseif os(tvOS) || os(macOS)
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
        #else
            menuScene(geometry: geometry)
        #endif
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
            FullscreenSceneHost(scene: activeFullscreenScene) { scene in
                fullscreenSceneView(for: scene)
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .opacity(fullscreenSceneOpacity)
            .ignoresSafeArea()
            .zIndex(5000)
        }
        if activeFullscreenScene?.key == screenSaverFullscreenKey {
            screenSaverNowPlayingToastView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 42)
                .padding(.bottom, 36)
                .opacity(screenSaverNowPlayingToastOpacity)
                .allowsHitTesting(false)
                .zIndex(5105)
        }
    }

    func menuScene(geometry: GeometryProxy) -> some View {
        ZStack {
            VStack {
                Spacer()
                headerView(geometry: geometry).offset(y: menuClusterVerticalCompensation)
                HStack(spacing: 0) {
                    ZStack {
                        if showsSettledLandedIcon, let activeRootItemID, let image = menuImage(forRootID: activeRootItemID) {
                            settledLandedIconView(image: image, geometry: geometry)
                        }
                        ForEach(visibleIndices(), id: \.self) { index in
                            carouselItemView(for: index, geometry: geometry).opacity(
                                showsSettledLandedIcon
                                    ? 0
                                    : (isInSubmenu && !isReturningToRoot && index != selectedIndex ? 0 : 1),
                            )
                        }
                    }.background(Group {
                        if isInSubmenu {
                            detailContentView(sceneSize: geometry.size).opacity(detailContentVisibilityOpacity).animation(.easeInOut(duration: 0.22),
                                                                                                                          value: shouldHidePodcastsSubmenuChromeUntilLoadCompletes)
                        }
                    }).frame(width: carouselWidth(geometry: geometry)).offset(x: carouselSceneOffsetX).offset(y: carouselOffsetY()).offset(y: -menuClusterVerticalCompensation)
                    Spacer()
                    rightMenuArea(geometry: geometry).frame(
                        width: menuWidthConstrained(geometry: geometry),
                        height: stableMenuListLayoutHeight,
                        alignment: .top,
                    )
                    .offset(x: rightMenuSceneOffsetX)
                }.frame(width: geometry.size.width, alignment: .center).offset(y: menuClusterVerticalCompensation)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center).opacity(menuSceneOpacity)
            if isMovieResumePromptVisible {
                movieResumePromptOverlay(geometry: geometry).frame(width: geometry.size.width, height: geometry.size.height).opacity(movieResumePromptOpacity).zIndex(4200)
            }
        }.onPreferenceChange(RootMenuSelectionCenterPreferenceKey.self) { centerX in
            guard centerX.isFinite else { return }
            rootMenuSelectionCenterSceneX = centerX
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        .coordinateSpace(name: "menuSceneSpace")
    }
}
