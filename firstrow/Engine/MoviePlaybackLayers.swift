import AVFoundation
#if os(iOS)
    import AVKit
#endif
import CoreImage
import QuartzCore
#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#else
    import FirstRowPortable
#endif

/// Movie playback: the video itself and the transport bar shown over it.
@MainActor
final class MoviePlaybackLayers {
    /// Holds the rest, so the movie can shrink and fade as one.
    let group = SceneLayer()
    /// Black behind the picture, wherever on the screen the picture is.
    private let backdrop = SceneLayer()
    let playerLayer = AVPlayerLayer()
    let controls = MovieControlsLayer()
    let modernControls = ModernMovieControlsLayer()
    let options = MovieOptionsLayer()
    /// A YouTube video's captions and the panel beside its picture (see `YouTubeVideoLayers`).
    let captions = YouTubeCaptionLayer()
    let panel = YouTubePanelLayer()
    #if !FIRSTROW_PORTABLE
        /// Bent at the fold: the picture again, dimly, under it (see `MovieReflectionLayer`).
        private let reflection = MovieReflectionLayer()
    #endif
    #if os(iOS)
        /// A YouTube video goes on playing in the system's picture in picture when First Row
        /// is left while it plays, and comes back to its place here when First Row is opened
        /// again.
        private var pictureInPicture: AVPictureInPictureController?
        private var returnsFromPictureInPicture: NSObjectProtocol?
    #endif

    init() {
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        playerLayer.isHidden = true
        playerLayer.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
        controls.layer.isHidden = true
        backdrop.backgroundColor = CGColor(gray: 0, alpha: 1)
        backdrop.isHidden = true
        for sublayer in [backdrop, playerLayer, captions.layer, controls.layer, modernControls.layer, panel.layer, options.layer] {
            group.addSublayer(sublayer)
        }
        #if !FIRSTROW_PORTABLE
            group.insertSublayer(reflection.layer, above: playerLayer)
        #endif
    }

    func update(menu: MenuView, pass: RenderPass, bounds: CGRect, scale: CGFloat) {
        group.place(bounds)
        let depth = ModernTheme.isActive ? menu.movieSceneScale : 1
        group.setTransform(MenuSceneRenderer.scale(depth, about: CGPoint(x: bounds.midX, y: bounds.midY)), pass.animation)
        group.setOpacity(ModernTheme.isActive ? menu.movieSceneOpacity : 1, pass.animation)
        let showsPlayer = menu.isMoviePlaybackVisible && menu.moviePlayer != nil
        if playerLayer.player !== menu.moviePlayer, showsPlayer || menu.moviePlayer == nil {
            playerLayer.player = menu.moviePlayer
        }
        playerLayer.isHidden = !showsPlayer
        if !showsPlayer, playerLayer.player != nil, !menu.isMoviePlaybackVisible {
            playerLayer.player = nil
        }
        backdrop.isHidden = !showsPlayer
        backdrop.place(bounds)
        // On the full-screen canvas, so the controls keep their proportions at any resolution.
        // Standing upright and bent at the fold, the picture has the screen above the fold and
        // the controls the screen below it, where they stay up. Flat, it's one tall screen.
        let canvas = FullscreenCanvas(screenSize: bounds.size, upright: menu.upright)
        let isBent = canvas.upright?.isBent == true
        placePicture(canvas.upright.map { $0.isBent ? canvas.window($0.moviePicture) : bounds } ?? bounds)
        #if !FIRSTROW_PORTABLE
            // From the foot of the picture itself (of its box, until the picture's shape is
            // known) to the bottom of the screen: the picture stands on what shows it again,
            // with no black between them.
            var underThePicture: CGRect?
            if let upright = canvas.upright, isBent {
                let box = canvas.window(upright.moviePicture)
                let video = playerLayer.videoRect
                let top = video.height > 1 ? min(box.maxY, box.minY + video.maxY) : box.maxY
                underThePicture = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
            }
            reflection.update(player: showsPlayer ? menu.moviePlayer : nil, frame: underThePicture)
        #endif
        #if os(iOS)
            keepPictureInPicture(for: showsPlayer && menu.youtubeSession != nil)
        #endif
        var controlsSize = canvas.size
        if let upright = canvas.upright, isBent { controlsSize.height = upright.movieControlsFloor }
        // A video's panel takes the right of the screen: the controls keep to what it leaves
        // them, the bar narrowing as the panel comes.
        let panelSize = controlsSize
        controlsSize.width -= YouTubePanelLayer.width(in: panelSize) * menu.youtubePanelSpread
        // The bar's dark fade is for a picture that lies under it: not for a bar below the fold
        // of a bent screen, nor on a flat one under a picture that stops short of it.
        var barIsOverPicture = !isBent
        #if !FIRSTROW_PORTABLE
            if barIsOverPicture, canvas.upright != nil {
                let video = playerLayer.videoRect
                barIsOverPicture = video.height > 1 && video.maxY > bounds.height - ModernMovieControlsLayer.fadeHeight * canvas.scale
            }
        #endif

        let showsControls = menu.isMoviePlaybackVisible && menu.showsMovieControls
        let controlsOpacity = menu.shownMovieControlsOpacity
        let isModern = ModernTheme.isActive
        canvas.apply(to: captions.layer)
        captions.update(
            text: showsPlayer ? menu.youtubeCaptionText : nil,
            raised: showsControls && controlsOpacity > 0.5,
            width: controlsSize.width,
            size: controlsSize,
            scale: canvas.pixelScale(backingScale: scale),
            pass: pass,
        )
        canvas.apply(to: panel.layer)
        panel.update(menu: menu, size: panelSize, scale: canvas.pixelScale(backingScale: scale), canvasScale: canvas.scale, pass: pass)
        controls.layer.isHidden = !showsControls || isModern
        modernControls.layer.isHidden = !showsControls || !isModern
        // The options' buttons sit above the right end of the bar, and the panel grows out of them.
        defer {
            canvas.apply(to: options.layer)
            let bar = isModern ? modernControls.barFrame : controls.barFrame
            options.update(
                menu: menu,
                anchor: showsControls && bar.width > 0 ? bar : nil,
                controlsOpacity: controlsOpacity,
                size: controlsSize,
                scale: canvas.pixelScale(backingScale: scale),
                canvasScale: canvas.scale,
                pass: pass,
            )
        }
        guard showsControls else { return }
        if isModern {
            canvas.apply(to: modernControls.layer)
            modernControls.update(
                glyphState: menu.movieControlsGlyphState,
                currentTime: menu.moviePlaybackCurrentSeconds,
                duration: menu.moviePlaybackDurationSeconds,
                isLoading: menu.isMoviePreviewDownloadLoading,
                loadingProgress: menu.moviePreviewDownloadProgress,
                size: controlsSize,
                scale: canvas.pixelScale(backingScale: scale),
                overPicture: barIsOverPicture,
            )
            modernControls.layer.setOpacity(controlsOpacity, pass.animation)
            return
        }
        canvas.apply(to: controls.layer)
        controls.update(
            glyphState: menu.movieControlsGlyphState,
            currentTime: menu.moviePlaybackCurrentSeconds,
            duration: menu.moviePlaybackDurationSeconds,
            isLoading: menu.isMoviePreviewDownloadLoading,
            loadingProgress: menu.moviePreviewDownloadProgress,
            size: controlsSize,
            scale: canvas.pixelScale(backingScale: scale),
        )
        controls.layer.setOpacity(controlsOpacity, pass.animation)
    }

    #if os(iOS)
        /// Has the system's picture in picture ready while a YouTube video plays: it takes the
        /// picture up by itself as First Row goes to the background.
        private func keepPictureInPicture(for isWanted: Bool) {
            guard isWanted else {
                if let controller = pictureInPicture {
                    if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
                    pictureInPicture = nil
                }
                return
            }
            guard pictureInPicture == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
            let controller = AVPictureInPictureController(playerLayer: playerLayer)
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
            pictureInPicture = controller
            guard returnsFromPictureInPicture == nil else { return }
            returnsFromPictureInPicture = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolatedIfPossible {
                    guard let controller = self?.pictureInPicture, controller.isPictureInPictureActive else { return }
                    controller.stopPictureInPicture()
                }
            }
        }
    #endif

    /// Gives the picture its box. As the layout glides, the picture travels from where it was
    /// to where it fits now, keeping its shape: by a transform, since a video's layer takes a
    /// new size at once.
    private func placePicture(_ box: CGRect) {
        let before = playerLayer.frame
        guard before != box else { return }
        #if FIRSTROW_PORTABLE
            // Nothing glides there: its windows have one layout.
            playerLayer.frame = box
        #else
            let video = playerLayer.videoRect
            let shown = playerLayer.presentation()?.transform ?? CATransform3DIdentity
            playerLayer.frame = box
            guard LayoutGlide.isActive, !playerLayer.isHidden, before.width > 0, before.height > 0, box.width > 0, box.height > 0 else { return }
            // The picture's shape: the video's once it's known, the old box's until then.
            let shape = video.width > 1 && video.height > 1 ? video.size : before.size
            func fitted(in box: CGRect) -> CGFloat {
                min(box.width, box.height * shape.width / shape.height)
            }
            let widthNow = fitted(in: box)
            guard widthNow > 0 else { return }
            // Where it was showing (part way through an earlier glide, perhaps).
            let ratio = fitted(in: before) * shown.m11 / widthNow
            let from = CATransform3DScale(
                CATransform3DMakeTranslation(before.midX + shown.m41 - box.midX, before.midY + shown.m42 - box.midY, 0),
                ratio, ratio, 1,
            )
            LayoutGlide.bring(playerLayer, "transform", from: NSValue(caTransform3D: from))
        #endif
    }
}

/// The glossy transport bar: play state on the left, the track with its position diamond,
/// the length on the right and the current time under the diamond.
@MainActor
final class MovieControlsLayer {
    let layer = SceneLayer()
    private let bar = SceneLayer()
    private let base = SceneLayer()
    private let track = SceneLayer()
    private let trackMask = SceneShapeLayer()
    private let trackFill = SceneLayer()
    private let trackFillImage = SceneLayer()
    private let diamond = SceneLayer()
    private let glyph = PlaybackGlyphLayer()
    private let duration = SceneLayer()
    private let currentTime = SceneLayer()
    private var artworkKey: String?
    /// The track the position diamond travels, in canvas points: its box and the stretch the diamond's centre covers.
    private(set) var seekTrack: (frame: CGRect, travel: ClosedRange<CGFloat>)?
    /// The whole bar, in canvas points.
    private(set) var barFrame: CGRect = .zero

    private static let trackTop = RGBA(red: 70 / 255, green: 140 / 255, blue: 205 / 255)
    private static let trackMid = RGBA(red: 55 / 255, green: 165 / 255, blue: 210 / 255)
    private static let trackBottom = RGBA(red: 60 / 255, green: 218 / 255, blue: 235 / 255)
    private static let trackBlend = RGBA(red: 58 / 255, green: 191 / 255, blue: 223 / 255)

    init() {
        layer.addSublayer(bar)
        bar.addSublayer(base)
        bar.addSublayer(track)
        track.mask = trackMask
        track.addSublayer(trackFill)
        trackFill.masksToBounds = true
        trackFill.addSublayer(trackFillImage)
        diamond.backgroundColor = CGColor(gray: 0, alpha: 1)
        diamond.cornerRadius = 1.8
        diamond.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        diamond.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
        bar.addSublayer(diamond)
        bar.addSublayer(glyph.layer)
        bar.addSublayer(duration)
        bar.shadowColor = CGColor(gray: 0, alpha: 1)
        bar.shadowOpacity = 0.8
        bar.shadowRadius = 5
        bar.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(currentTime)
    }

    func update(glyphState: MoviePlaybackGlyphState, currentTime seconds: Double, duration totalSeconds: Double, isLoading: Bool, loadingProgress: Double, size: CGSize, scale: CGFloat) {
        let controlWidth = min(size.width * 0.94, 1600)
        let trackHeight: CGFloat = 38
        let inset: CGFloat = 4
        let laneWidth = max(0, controlWidth - inset * 2)
        let sideWidth = laneWidth * 0.10
        let centerWidth = max(0, laneWidth - sideWidth * 2)
        let centerHeight = max(0, trackHeight - inset * 2)
        let diamondSize: CGFloat = 18
        let hasDuration = totalSeconds.isFinite && totalSeconds > 0.001
        let progress = hasDuration ? max(0, min(1, seconds / totalSeconds)) : 0
        let displayedProgress = isLoading ? max(0, min(1, loadingProgress)) : progress
        let centerStartX = inset + sideWidth
        let travelStartX = centerStartX + min(16, centerWidth * 0.5)
        let travelWidth = max(0, centerWidth - (travelStartX - centerStartX) * 2)
        let diamondCenterX = travelStartX + travelWidth * CGFloat(progress)
        let barFrame = CGRect(x: (size.width - controlWidth) * 0.5, y: size.height - 52 - 28 - trackHeight, width: controlWidth, height: trackHeight)
        self.barFrame = barFrame.insetBy(dx: 24, dy: 0)
        bar.frame = barFrame
        seekTrack = (
            CGRect(x: barFrame.minX + centerStartX, y: barFrame.minY, width: centerWidth, height: trackHeight),
            (barFrame.minX + travelStartX) ... (barFrame.minX + travelStartX + travelWidth),
        )
        bar.shadowPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: controlWidth, height: trackHeight), cornerWidth: trackHeight * 0.5, cornerHeight: trackHeight * 0.5, transform: nil)

        let key = "\(controlWidth)|\(isLoading)|\(scale)"
        if key != artworkKey {
            artworkKey = key
            base.contents = Self.baseImage(width: controlWidth, height: trackHeight, scale: scale)
            base.frame = CGRect(x: 0, y: 0, width: controlWidth, height: trackHeight)
            let trackSize = CGSize(width: centerWidth, height: centerHeight)
            track.frame = CGRect(x: centerStartX, y: inset, width: centerWidth, height: centerHeight)
            trackMask.frame = track.bounds
            trackMask.path = CGPath(roundedRect: track.bounds, cornerWidth: centerHeight * 0.5, cornerHeight: centerHeight * 0.5, transform: nil)
            track.contents = isLoading ? Self.loadingTrackImage(size: trackSize, scale: scale) : Self.trackImage(size: trackSize, scale: scale)
            trackFillImage.contents = Self.trackImage(size: trackSize, scale: scale)
            trackFillImage.frame = CGRect(origin: .zero, size: trackSize)
        }
        track.opacity = (isLoading && displayedProgress >= 0.999) ? 0 : 1
        trackFill.isHidden = !isLoading
        trackFill.frame = CGRect(x: 0, y: 0, width: centerWidth * CGFloat(displayedProgress), height: centerHeight)
        if isLoading, displayedProgress >= 0.999 {
            track.opacity = 1
        }

        diamond.isHidden = isLoading
        diamond.bounds = CGRect(x: 0, y: 0, width: diamondSize, height: diamondSize)
        let diamondLeft = max(inset, min(controlWidth - inset - diamondSize, diamondCenterX - diamondSize * 0.5))
        diamond.position = CGPoint(x: diamondLeft + diamondSize * 0.5, y: trackHeight * 0.5)

        let glow = [TextShadow(color: RGBA(white: 1, alpha: 0.45), radius: 1.8), TextShadow(color: RGBA(white: 1, alpha: 0.2), radius: 3.2)]
        glyph.update(glyphState, pointSize: 23, shadows: glow, scale: scale, showsPlayGlyph: true)
        glyph.layer.frame = CGRect(
            x: inset + (sideWidth - glyph.size.width) * 0.5,
            y: (trackHeight - glyph.size.height) * 0.5,
            width: glyph.size.width,
            height: glyph.size.height,
        )

        let durationText = isLoading || totalSeconds <= 0.001 ? "" : formatfirstRowPlaybackTime(totalSeconds)
        let durationGraphic = TextRenderer.render(TextSpec(text: durationText, fontName: firstRowBoldFontName, size: 30), scale: scale)
        duration.isHidden = durationText.isEmpty
        duration.show(durationGraphic, at: CGPoint(x: inset + laneWidth - sideWidth * 0.5 - durationGraphic.size.width * 0.5, y: (trackHeight - durationGraphic.size.height) * 0.5))

        let timeGraphic = TextRenderer.render(TextSpec(text: formatfirstRowPlaybackTime(seconds), fontName: firstRowBoldFontName, size: 22, shadows: [TextShadow(color: RGBA(white: 0, alpha: 0.8), radius: 2, offset: CGSize(width: 0, height: 1))]), scale: scale)
        currentTime.isHidden = isLoading
        currentTime.show(timeGraphic, at: CGPoint(x: barFrame.minX + diamondCenterX - timeGraphic.size.width * 0.5, y: barFrame.maxY + 16 - timeGraphic.size.height * 0.5))
    }

    // MARK: - Artwork

    private static func baseImage(width: CGFloat, height: CGFloat, scale: CGFloat) -> CGImage? {
        TextRenderer.draw(size: CGSize(width: width, height: height), padding: 0, scale: scale, shadows: []) { context in
            context.translateBy(x: 0, y: height)
            context.scaleBy(x: 1, y: -1)
            let full = CGRect(x: 0, y: 0, width: width, height: height)
            context.addPath(capsule(full))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            let inner = CGRect(x: 1, y: 0.5, width: width - 2, height: height - 2)
            context.saveGState()
            context.addPath(capsule(inner))
            context.clip()
            gradient(context, in: inner, stops: [(.black, 0), (.black, 0.6), (RGBA(red: 20 / 255, green: 30 / 255, blue: 40 / 255, alpha: 0.92), 1)])
            // Upper gloss, inside a mask with curved lower corners.
            let gloss = upperGlossPath(in: inner)
            context.addPath(gloss)
            context.clip()
            let upper = RGBA(red: 20 / 255, green: 36 / 255, blue: 50 / 255)
            gradient(context, in: inner, stops: [(upper.opacity(0.92), 0), (upper.opacity(0.78), 0.5), (.clear, 1)])
            context.restoreGState()
        }.image
    }

    private static func trackImage(size: CGSize, scale: CGFloat) -> CGImage? {
        TextRenderer.draw(size: size, padding: 0, scale: scale, shadows: []) { context in
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            let rect = CGRect(origin: .zero, size: size)
            gradient(context, in: rect, stops: [(trackTop, 0), (trackMid, 0.42), (trackBlend, 0.56), (trackBottom, 1)])
            gradient(context, in: rect, stops: [(RGBA(white: 1, alpha: 0.22), 0), (RGBA(white: 1, alpha: 0.10), 0.24), (.clear, 0.58)])
            let bandHeight = size.height * 0.26
            let band = CGRect(x: 0, y: (size.height - bandHeight) * 0.5, width: size.width, height: bandHeight)
            gradient(context, in: band, stops: [(trackMid.opacity(0.30), 0), (trackBlend.opacity(0.32), 0.5), (trackBottom.opacity(0.24), 1)])
        }.image
    }

    private static func loadingTrackImage(size: CGSize, scale: CGFloat) -> CGImage? {
        TextRenderer.draw(size: size, padding: 0, scale: scale, shadows: []) { context in
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            let rect = CGRect(origin: .zero, size: size)
            gradient(context, in: rect, stops: [(RGBA(white: 0, alpha: 0.52), 0), (RGBA(white: 0, alpha: 0.64), 1)])
            gradient(context, in: rect, stops: [(RGBA(white: 1, alpha: 0.10), 0), (RGBA(white: 1, alpha: 0.03), 0.42), (.clear, 0.80)])
        }.image
    }

    private static func capsule(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: rect.height * 0.5, cornerHeight: rect.height * 0.5, transform: nil)
    }

    /// Top-to-bottom gradient (the context is set up with y down).
    private static func gradient(_ context: CGContext, in rect: CGRect, stops: [(RGBA, CGFloat)]) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: stops.map(\.0.cgColor) as CFArray, locations: stops.map(\.1)) else { return }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    private static func upperGlossPath(in rect: CGRect) -> CGPath {
        let sideCurveWidth = rect.width * 0.016
        let topEdgeY = rect.minY + rect.height * 0.02
        let sideBottomY = rect.minY + rect.height * 0.06
        let flatBottomY = rect.minY + rect.height * 0.50
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: topEdgeY))
        path.addLine(to: CGPoint(x: rect.maxX, y: topEdgeY))
        path.addLine(to: CGPoint(x: rect.maxX, y: sideBottomY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - sideCurveWidth, y: flatBottomY), control: CGPoint(x: rect.maxX - sideCurveWidth * 0.08, y: flatBottomY))
        path.addLine(to: CGPoint(x: rect.minX + sideCurveWidth, y: flatBottomY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: sideBottomY), control: CGPoint(x: rect.minX + sideCurveWidth * 0.08, y: flatBottomY))
        path.closeSubpath()
        return path
    }
}

/// "Resume Playing / Start from Beginning" over a blurred frame of the movie.
@MainActor
final class MovieResumePromptLayer {
    let layer = SceneLayer()
    private let backdrop = SceneLayer()
    private let dim = SceneLayer()
    private let options = SceneLayer()
    private let selection = SelectionBoxLayer()
    private let pressed = SceneLayer()
    private let labels = [SceneLayer(), SceneLayer()]
    private var lastSelectedIndex: Int?
    private var backdropSource: NSImage?
    private var wasVisible = false
    /// The modern look's two options: the menus' own rows, so focus moves between them as it
    /// does in a menu.
    private let modernRows = [ModernMenuRowLayer(), ModernMenuRowLayer()]
    /// The two options' rows in scene points, top first.
    private(set) var optionFrames: [CGRect] = []

    init() {
        layer.opacity = 0
        layer.isHidden = true
        backdrop.contentsGravity = .resizeAspectFill
        backdrop.masksToBounds = true
        backdrop.backgroundColor = CGColor(gray: 0, alpha: 1)
        dim.backgroundColor = CGColor(gray: 0, alpha: 0.33)
        pressed.backgroundColor = CGColor(gray: 0, alpha: 1)
        pressed.cornerRadius = 5
        layer.addSublayer(backdrop)
        layer.addSublayer(dim)
        layer.addSublayer(options)
        options.addSublayer(pressed)
        options.addSublayer(selection.layer)
        for label in labels { options.addSublayer(label) }
        for row in modernRows { options.addSublayer(row.layer) }
    }

    func update(menu: MenuView, pass: RenderPass, sceneSize: CGSize, scale: CGFloat) {
        guard menu.isMovieResumePromptVisible else {
            layer.isHidden = true
            layer.opacity = 0
            wasVisible = false
            lastSelectedIndex = nil
            return
        }
        let appearing = !wasVisible
        wasVisible = true
        layer.isHidden = false
        layer.frame = CGRect(origin: .zero, size: sceneSize)
        backdrop.frame = layer.bounds
        dim.frame = layer.bounds
        if menu.movieResumePromptBackdropImage !== backdropSource {
            backdropSource = menu.movieResumePromptBackdropImage
            backdrop.contents = backdropSource.flatMap { BlurredBackdrop.image(for: $0, size: sceneSize) }
        }
        let isModern = ModernTheme.isActive
        for sublayer in [pressed, selection.layer] + labels { sublayer.isHidden = isModern }
        for row in modernRows { row.layer.isHidden = !isModern }
        if isModern {
            dim.backgroundColor = CGColor(gray: 0, alpha: 0.5)
            updateModern(menu: menu, pass: pass, sceneSize: sceneSize, scale: scale, appearing: appearing)
            layer.setOpacity(menu.movieResumePromptOpacity, appearing ? nil : pass.animation)
            return
        }
        dim.backgroundColor = CGColor(gray: 0, alpha: 0.33)
        let optionWidth = min(menu.menuWidthConstrained(sceneSize: sceneSize) * 0.88, 860)
        let optionHeight = menu.selectionBoxHeight
        let visualWidth = optionWidth + menu.selectionTextureVisualWidthDelta + menu.movieResumeSelectionTextureLeadingAdjustment + menu.movieResumeSelectionTextureTrailingAdjustment
        let visualHeight = optionHeight + menu.selectionTextureVisualHeightDelta
        let visualXOffset = -((visualWidth - optionWidth) * 0.5) + ((menu.movieResumeSelectionTextureTrailingAdjustment - menu.movieResumeSelectionTextureLeadingAdjustment) * 0.5)
        let visualYOffset = -((visualHeight - optionHeight) * 0.5)
        let rowSpacing: CGFloat = 10
        let selectedOffset = CGFloat(menu.movieResumePromptSelectedIndex) * (optionHeight + rowSpacing)
        let stackHeight = optionHeight * 2 + rowSpacing
        options.frame = CGRect(x: (sceneSize.width - optionWidth) * 0.5, y: Self.middle(menu, sceneSize) - stackHeight * 0.5, width: optionWidth, height: stackHeight)
        optionFrames = (0 ..< 2).map { index in
            CGRect(x: options.frame.minX, y: options.frame.minY + CGFloat(index) * (optionHeight + rowSpacing), width: optionWidth, height: optionHeight)
        }
        let moved = lastSelectedIndex != nil && lastSelectedIndex != menu.movieResumePromptSelectedIndex
        let slide = appearing ? nil : pass.animation(.easeInOut(duration: menu.movieResumePromptSelectionSlideDuration), when: moved)
        lastSelectedIndex = menu.movieResumePromptSelectedIndex
        pressed.isHidden = !menu.movieResumePromptSolidBlackSelected
        selection.layer.isHidden = menu.movieResumePromptSolidBlackSelected
        pressed.setFrame(CGRect(x: 12, y: selectedOffset, width: max(0, optionWidth - 12), height: optionHeight), slide)
        selection.update(frame: CGRect(x: visualXOffset, y: selectedOffset + visualYOffset, width: visualWidth, height: visualHeight), selectionBoxHeight: menu.selectionBoxHeight, animation: slide)
        for (index, title) in ["Resume Playing", "Start from Beginning"].enumerated() {
            let isSelected = index == menu.movieResumePromptSelectedIndex
            let hidden = (menu.movieResumePromptSolidBlackSelected && isSelected) || (menu.movieResumePromptHideUnselected && !isSelected)
            let graphic = TextRenderer.render(TextSpec(text: title, fontName: firstRowBoldFontName, size: 45, maxWidth: optionWidth, minimumScaleFactor: 0.72), scale: scale)
            labels[index].show(graphic, at: CGPoint(x: 32, y: CGFloat(index) * (optionHeight + rowSpacing) + (optionHeight - graphic.size.height) * 0.5))
            labels[index].opacity = hidden ? 0 : 1
        }
        layer.setOpacity(menu.movieResumePromptOpacity, appearing ? nil : pass.animation)
    }

    /// The height the two options are centred on: the screen's middle, or standing upright the
    /// middle of the part under the fold, where the menus' rows are.
    private static func middle(_ menu: MenuView, _ sceneSize: CGSize) -> CGFloat {
        menu.upright?.lowerPane.midY ?? sceneSize.height * 0.5
    }

    /// Two of the menus' rows in the middle: focus jumps to the chosen one, which turns white and
    /// grows as a menu row does, the other fading back. Choosing keeps them as they are (the
    /// classic look's blanked bar is its own).
    private func updateModern(menu: MenuView, pass _: RenderPass, sceneSize: CGSize, scale: CGFloat, appearing _: Bool) {
        let width: CGFloat = 760
        let rowHeight = menu.selectionBoxHeight
        let pitch = rowHeight + 5
        options.frame = CGRect(x: (sceneSize.width - width) * 0.5, y: Self.middle(menu, sceneSize) - pitch, width: width, height: pitch * 2)
        optionFrames = (0 ..< 2).map { index in
            CGRect(x: options.frame.minX, y: options.frame.minY + CGFloat(index) * pitch, width: width, height: rowHeight)
        }
        let selected = menu.movieResumePromptSelectedIndex
        lastSelectedIndex = selected
        ModernMenuRowLayer.focusAnimation = .smooth(duration: ModernTheme.focusDuration)
        for (index, title) in ["Resume Playing", "Start from Beginning"].enumerated() {
            let row = modernRows[index]
            row.layer.frame = CGRect(x: 0, y: CGFloat(index) * pitch, width: width, height: rowHeight)
            let item = MenuListItemConfig(
                id: "movie-resume-\(index)", title: title, leadsToMenu: false,
                leadingImageAssetName: nil, leadingImage: nil, trailingText: nil, trailingSymbolName: nil,
                showsTopDivider: false, showsBlueDot: false, showsLightRowBackground: false, alignsTextToDividerStart: false,
            )
            row.update(MenuRowLayer.Spec(
                item: item,
                isSelected: index == selected,
                isSettled: true,
                rowWidth: width,
                rowHeight: rowHeight,
                leadingCompensation: 0,
                showsPlaybackSpeaker: false,
                arrowAppearance: menu.menuArrowAppearance,
                isPhotosRoot: false,
                isPhotosThirdMenu: false,
                dynamicLeadingImage: nil,
                scale: scale,
                theme: .modern,
            ), menu: menu)
        }
    }
}

/// A movie frame blurred and slightly desaturated, for behind the resume prompt.
@MainActor
enum BlurredBackdrop {
    private static var cache: [ObjectIdentifier: (NSImage, CGImage)] = [:]
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func image(for source: NSImage, size: CGSize) -> CGImage? {
        if let cached = cache[ObjectIdentifier(source)], cached.0 === source {
            return cached.1
        }
        guard let cgImage = LayerImageCache.cgImage(for: source) else { return nil }
        // Work at half the scene's size: the result is a soft blur either way.
        let workScale: CGFloat = 0.5
        let target = CGSize(width: size.width * workScale, height: size.height * workScale)
        var image = CIImage(cgImage: cgImage)
        let fill = max(target.width / image.extent.width, target.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        let crop = CGRect(
            x: image.extent.midX - target.width * 0.5,
            y: image.extent.midY - target.height * 0.5,
            width: target.width,
            height: target.height,
        )
        image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.92])
        // Cropped first and blurred without clamping, so the edges soften into the black behind.
        image = image.cropped(to: crop).applyingGaussianBlur(sigma: 28 * workScale).cropped(to: crop)
        guard let blurred = context.createCGImage(image, from: crop, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        if cache.count > 4 { cache.removeAll() }
        cache[ObjectIdentifier(source)] = (source, blurred)
        return blurred
    }
}
