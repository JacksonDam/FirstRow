import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// A mouse or trackpad event, in window points with the origin at the top left.
enum PointerEvent {
    case moved(CGPoint)
    case pressed(PointerButton, CGPoint)
    case released(PointerButton, CGPoint)
    /// Positive `dy` moves the content down, towards the earlier rows. Precise deltas are in
    /// points (trackpads); the others are wheel notches.
    case scrolled(dx: CGFloat, dy: CGFloat, precise: Bool, at: CGPoint)
}

enum PointerButton {
    case primary
    case secondary
    /// The side button that means back.
    case back
}

/// Which of the menu lists a row is in.
enum MenuListLevel: Hashable {
    case root
    case submenu
    case third
}

/// What is under the pointer.
enum PointerTarget: Equatable {
    case menuRow(MenuListLevel, Int)
    case carouselItem(Int)
    case sortSegment(MenuView.TVShowsSortMode)
    case resumeOption(Int)
    /// A playback progress bar, at this fraction of its length.
    case progressBar(fraction: Double)
    /// One of a movie's option buttons above its bar.
    case movieOptionButton(MenuView.MovieOptionRow.Kind)
    /// A row of the open movie options (-1 between rows), on its "‹" or not.
    case movieOptionRow(Int, backward: Bool)
    case background
}

/// A menu list's scrolling, for pinning it under the pointer and moving it with the wheel.
struct MenuListScrollState {
    let identity: String
    /// Where the list is scrolling to (0 or less).
    let scrollOffset: CGFloat
    let minScrollOffset: CGFloat
    let rowPitch: CGFloat
    /// One row's pitch in window points.
    let rowPitchInWindow: CGFloat
    /// Where the list is on screen right now, part way through a scroll.
    var presentedScrollOffset: CGFloat

    var canScroll: Bool { minScrollOffset < -0.5 }
}

@MainActor
protocol PointerHitTesting: AnyObject {
    func pointerTarget(at windowPoint: CGPoint) -> PointerTarget?
    func menuListScrollState(_ level: MenuListLevel) -> MenuListScrollState?
    /// The row at `windowPoint` were the list scrolled to `scrollOffset`.
    func menuRowIndex(_ level: MenuListLevel, at windowPoint: CGPoint, scrollOffset: CGFloat) -> Int?
    /// How far along the showing progress bar `windowPoint` is, however far above or below it.
    func progressBarFraction(at windowPoint: CGPoint) -> Double?
    /// The movie options panel's row at `windowPoint`: its index, -1 on the panel between rows,
    /// or nil off the panel.
    func movieOptionsRow(at windowPoint: CGPoint) -> (index: Int, backward: Bool)?
    /// The movie option button at `windowPoint`, while they show.
    func movieOptionsButton(at windowPoint: CGPoint) -> MenuView.MovieOptionRow.Kind?
    /// Where Now Playing's list is, when Now Playing could show one.
    var nowPlayingQueueGeometry: NowPlayingQueueGeometry? { get }
    /// The touch mode button at `windowPoint`, if one is showing there.
    func touchControl(at windowPoint: CGPoint) -> TouchControl?
    /// Shows a touch mode button as held down (nil for none).
    func highlightTouchControl(_ control: TouchControl?)
}

/// Where a list's rows were laid out, in the list's box (origin top left, before scrolling).
struct MenuListHitGeometry {
    let identity: String
    let itemCount: Int
    /// Each row's offset, or empty when rows are `uniformRowPitch` apart.
    let rowOffsets: [CGFloat]
    let uniformRowPitch: CGFloat?
    let rowHeight: CGFloat
    let rowYOffset: CGFloat
    let normalRowHeight: CGFloat
    let normalHeightIndices: Set<Int>
    let rowSpacing: CGFloat
    let rowPitch: CGFloat
    let rowXRange: ClosedRange<CGFloat>
    let viewportHeight: CGFloat
    let contentHeight: CGFloat
    let scrollOffset: CGFloat

    var minScrollOffset: CGFloat {
        min(0, viewportHeight - contentHeight)
    }

    private func rowBase(_ index: Int) -> CGFloat {
        if let pitch = uniformRowPitch { return CGFloat(index) * pitch }
        return rowOffsets.indices.contains(index) ? rowOffsets[index] : 0
    }

    private func rowSpan(_ index: Int) -> ClosedRange<CGFloat> {
        let isNormal = normalHeightIndices.contains(index)
        let top = rowBase(index) + (isNormal ? 0 : rowYOffset)
        return top ... (top + (isNormal ? normalRowHeight : rowHeight))
    }

    /// The row at `point` in the list's box with the rows scrolled by `scrollOffset`. The gap
    /// between two rows is shared out between them; divider gaps belong to neither.
    func rowIndex(at point: CGPoint, scrollOffset: CGFloat) -> Int? {
        guard itemCount > 0, point.y >= 0, point.y <= viewportHeight else { return nil }
        guard point.x >= rowXRange.lowerBound - 12, point.x <= rowXRange.upperBound + 12 else { return nil }
        let y = point.y - scrollOffset
        let slack = rowSpacing * 0.5 + 0.5
        var guess: Int
        if let pitch = uniformRowPitch, pitch > 0 {
            guess = Int((y / pitch).rounded(.down))
        } else {
            // The last row starting above the point.
            var low = 0
            var high = rowOffsets.count
            while low < high {
                let mid = (low + high) / 2
                if rowOffsets[mid] + rowYOffset - slack <= y { low = mid + 1 } else { high = mid }
            }
            guess = low - 1
        }
        guess = min(max(0, guess), itemCount - 1)
        for index in max(0, guess - 1) ... min(itemCount - 1, guess + 1) {
            let span = rowSpan(index)
            if y >= span.lowerBound - slack, y < span.upperBound + slack { return index }
        }
        return nil
    }
}

/// The renderer's live layers and transforms that hit testing reads.
@MainActor
struct PointerScene {
    let canvasOrigin: CGPoint
    let canvasScale: CGFloat
    let lists: [MenuListLevel: MenuListLayer]
    let carousel: RootCarouselLayerController
    let sortPillFrame: CGRect
    let resumePrompt: MovieResumePromptLayer
    /// The movie transport's seek track (in either look), in full-screen canvas points.
    let movieSeekTrack: (frame: CGRect, travel: ClosedRange<CGFloat>)?
    let fullscreenScene: FullscreenSceneLayer
    let fullscreenSize: CGSize

    /// A window point in the menu scene's points.
    func scenePoint(_ windowPoint: CGPoint) -> CGPoint {
        let scale = max(canvasScale, 0.0001)
        return CGPoint(x: (windowPoint.x - canvasOrigin.x) / scale, y: (windowPoint.y - canvasOrigin.y) / scale)
    }

    /// A window point in the full-screen canvas's points.
    func fullscreenPoint(_ windowPoint: CGPoint) -> CGPoint {
        let scale = max(FullscreenCanvas(screenSize: fullscreenSize).scale, 0.0001)
        return CGPoint(x: windowPoint.x / scale, y: windowPoint.y / scale)
    }
}

extension MenuSceneRenderer: PointerHitTesting {
    var nowPlayingQueueGeometry: NowPlayingQueueGeometry? {
        let scene = pointerScene
        let queue = scene.fullscreenScene.queue
        guard menu.activeFullscreenScene?.key == menu.musicNowPlayingFullscreenKey, queue.isAvailable else { return nil }
        let scale = max(FullscreenCanvas(screenSize: scene.fullscreenSize).scale, 0.0001)
        func window(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        let size = scene.fullscreenSize
        #if os(iOS)
            let edgeWidth: CGFloat = AppSettings.isTouchEnabled ? 34 : max(24, size.width * 0.03)
        #else
            let edgeWidth = max(24, size.width * 0.03)
        #endif
        return NowPlayingQueueGeometry(
            panel: window(queue.panelFrame),
            edgeZone: CGRect(x: size.width - edgeWidth, y: 0, width: edgeWidth, height: size.height),
            viewport: window(queue.viewport),
            listTop: queue.listTop * scale,
            rowPitch: MenuView.nowPlayingQueueRowPitch * scale,
            canvasPerPoint: 1 / scale,
            scrollLimit: queue.scrollLimit,
            travel: max(1, size.width - window(queue.panelFrame).minX),
        )
    }

    func touchControl(at windowPoint: CGPoint) -> TouchControl? {
        touchControls.control(at: windowPoint)
    }

    func highlightTouchControl(_ control: TouchControl?) {
        touchControls.setPressed(control)
    }

    func pointerTarget(at windowPoint: CGPoint) -> PointerTarget? {
        let scene = pointerScene
        let menu = menu
        if menu.isMoviePlaybackVisible {
            if menu.movieOptions != nil, let hit = movieOptionsRow(at: windowPoint) {
                return .movieOptionRow(hit.index, backward: hit.backward)
            }
            if let kind = movieOptionsButton(at: windowPoint) { return .movieOptionButton(kind) }
            guard menu.areMovieControlsVisible, let track = scene.movieSeekTrack else { return .background }
            let point = scene.fullscreenPoint(windowPoint)
            guard track.frame.insetBy(dx: -6, dy: -18).contains(point) else { return .background }
            return .progressBar(fraction: Self.fraction(point.x, along: track.travel))
        }
        if let fullscreen = menu.activeFullscreenScene {
            if fullscreen.key == menu.musicNowPlayingFullscreenKey, let bar = scene.fullscreenScene.nowPlayingProgressBar {
                let point = scene.fullscreenPoint(windowPoint)
                if bar.insetBy(dx: -6, dy: -16).contains(point) {
                    return .progressBar(fraction: Self.fraction(point.x, along: bar.minX ... bar.maxX))
                }
            }
            return .background
        }
        let point = scene.scenePoint(windowPoint)
        if menu.isMovieResumePromptVisible {
            for (index, frame) in scene.resumePrompt.optionFrames.enumerated() where frame.insetBy(dx: -24, dy: -5).contains(point) {
                return .resumeOption(index)
            }
            return .background
        }
        guard let level = menu.pointerActiveListLevel else { return nil }
        let frames = menu.sceneFrames(sceneSize: menu.activeMenuVirtualSceneSize)
        let menuPoint = CGPoint(x: point.x - frames.menuFrame.minX, y: point.y - frames.menuFrame.minY)
        if level == .submenu, menu.shouldShowTVShowsSortPill, scene.sortPillFrame.contains(menuPoint) {
            return .sortSegment(menuPoint.x < scene.sortPillFrame.midX ? .date : .show)
        }
        if let index = rowIndex(level, scene: scene, menuPoint: menuPoint, scrollOffset: nil) {
            return .menuRow(level, index)
        }
        if level == .root, AppSettings.theme == .classic {
            let box = frames.carouselFrame
            if let index = scene.carousel.iconIndex(at: CGPoint(x: point.x - box.minX, y: point.y - box.minY)) {
                return .carouselItem(index)
            }
        }
        return .background
    }

    func menuListScrollState(_ level: MenuListLevel) -> MenuListScrollState? {
        let scene = pointerScene
        guard let list = scene.lists[level], !list.layer.isHidden, let geometry = list.hitGeometry else { return nil }
        return MenuListScrollState(
            identity: geometry.identity,
            scrollOffset: geometry.scrollOffset,
            minScrollOffset: geometry.minScrollOffset,
            rowPitch: geometry.rowPitch,
            rowPitchInWindow: geometry.rowPitch * scene.canvasScale,
            presentedScrollOffset: list.presentedScrollOffset ?? geometry.scrollOffset,
        )
    }

    func menuRowIndex(_ level: MenuListLevel, at windowPoint: CGPoint, scrollOffset: CGFloat) -> Int? {
        let scene = pointerScene
        let point = scene.scenePoint(windowPoint)
        let frames = menu.sceneFrames(sceneSize: menu.activeMenuVirtualSceneSize)
        let menuPoint = CGPoint(x: point.x - frames.menuFrame.minX, y: point.y - frames.menuFrame.minY)
        return rowIndex(level, scene: scene, menuPoint: menuPoint, scrollOffset: scrollOffset)
    }

    func progressBarFraction(at windowPoint: CGPoint) -> Double? {
        let scene = pointerScene
        let point = scene.fullscreenPoint(windowPoint)
        if menu.isMoviePlaybackVisible {
            guard let track = scene.movieSeekTrack else { return nil }
            return Self.fraction(point.x, along: track.travel)
        }
        if menu.activeFullscreenScene?.key == menu.musicNowPlayingFullscreenKey,
           let bar = scene.fullscreenScene.nowPlayingProgressBar
        {
            return Self.fraction(point.x, along: bar.minX ... bar.maxX)
        }
        return nil
    }

    /// The row under a point in the menu area, scrolled as on screen unless `scrollOffset` says otherwise.
    private func rowIndex(_ level: MenuListLevel, scene: PointerScene, menuPoint: CGPoint, scrollOffset: CGFloat?) -> Int? {
        guard let list = scene.lists[level], !list.layer.isHidden, let geometry = list.hitGeometry else { return nil }
        let listFrame = list.layer.frame
        let listPoint = CGPoint(x: menuPoint.x - listFrame.minX, y: menuPoint.y - listFrame.minY)
        return geometry.rowIndex(at: listPoint, scrollOffset: scrollOffset ?? list.presentedScrollOffset ?? geometry.scrollOffset)
    }

    private static func fraction(_ x: CGFloat, along span: ClosedRange<CGFloat>) -> Double {
        let length = span.upperBound - span.lowerBound
        guard length > 0 else { return 0 }
        return Double(min(1, max(0, (x - span.lowerBound) / length)))
    }
}
